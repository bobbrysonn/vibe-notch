//
//  GhosttyFocuser.swift
//  ClaudeIsland
//
//  Brings a session's Ghostty terminal to the front, or opens a tab that reaches it
//

import Darwin
import Foundation
import os.log

/// Drives Ghostty through its AppleScript dictionary (Ghostty 1.4+), where every terminal
/// reports its tty and foreground pid and `focus` raises its window, tab and split.
actor GhosttyFocuser {
    static let shared = GhosttyFocuser()

    private let logger = Logger(subsystem: "com.claudeisland", category: "Ghostty")

    private struct Terminal {
        let id: String
        let tty: String
        let pid: Int
    }

    private struct AgentInfo {
        let kind: String?
        let shortId: String?
        let pid: Int?
    }

    /// `pid` and `tty` are what the hooks reported; `claude agents` is asked first because
    /// it reports the claude process itself. Ghostty reports ttys as /dev/ttysNNN and the
    /// session store keeps them as ttysNNN, so both sides are compared without /dev/.
    func open(sessionId: String, cwd: String, pid: Int?, tty: String?) async {
        let agent = agentInfo(sessionId: sessionId)
        let pids = Set([agent?.pid, pid].compactMap { $0 })
        let ttys = Set(([tty] + pids.map(Self.ttyName(ofPid:))).compactMap { $0.map(Self.bareTTY) })
        let terminals = listTerminals()

        let match = terminals.first { ttys.contains(Self.bareTTY($0.tty)) }
            ?? terminals.first { pids.contains($0.pid) }
            ?? terminals.first { Self.isAttachClient(pid: $0.pid, sessionId: sessionId) }
        let label = sessionId.prefix(8)
        if let match {
            logger.notice("Session \(label, privacy: .public): focusing terminal on \(match.tty, privacy: .public)")
            focus(terminalId: match.id)
            return
        }

        logger.notice("Session \(label, privacy: .public): no match among \(terminals.count) terminals for ttys \(String(describing: ttys.sorted()), privacy: .public) pids \(String(describing: pids.sorted()), privacy: .public)")
        if let agent, agent.kind == "background", let shortId = agent.shortId {
            openTab(cwd: cwd, command: "claude attach \(shortId)")
        } else if agent != nil || pids.contains(where: Self.isAlive) {
            // Running but shown in no Ghostty terminal; resuming would start a second copy.
            runAppleScript("tell application \"Ghostty\" to activate", arguments: [])
        } else {
            openTab(cwd: cwd, command: "claude --resume \(sessionId)")
        }
    }

    private static func bareTTY(_ tty: String) -> String {
        tty.hasPrefix("/dev/") ? String(tty.dropFirst(5)) : tty
    }

    // MARK: - Ghostty

    private func listTerminals() -> [Terminal] {
        // The separator is set outside the tell block: inside it, `tab` names Ghostty's tab class.
        let script = """
        set sep to character id 9
        set out to ""
        with timeout of 30 seconds
            tell application "Ghostty"
                repeat with term in terminals
                    set out to out & (id of term) & sep & (tty of term) & sep & (pid of term) & linefeed
                end repeat
            end tell
        end timeout
        return out
        """
        guard let output = runAppleScript(script, arguments: []) else { return [] }
        return output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 3, let pid = Int(fields[2]) else { return nil }
            return Terminal(id: String(fields[0]), tty: String(fields[1]), pid: pid)
        }
    }

    private func focus(terminalId: String) {
        let script = """
        on run argv
            set terminalId to item 1 of argv
            with timeout of 5 seconds
                tell application "Ghostty"
                    activate
                    focus (first terminal whose id is terminalId)
                end tell
            end timeout
        end run
        """
        runAppleScript(script, arguments: [terminalId])
    }

    private func openTab(cwd: String, command: String) {
        let script = """
        on run argv
            with timeout of 5 seconds
                tell application "Ghostty"
                    activate
                    set cfg to new surface configuration
                    set initial working directory of cfg to (item 1 of argv)
                    set initial input of cfg to (item 2 of argv) & linefeed
                    if (count of windows) > 0 then
                        new tab in front window with configuration cfg
                    else
                        new window with configuration cfg
                    end if
                end tell
            end timeout
        end run
        """
        runAppleScript(script, arguments: [cwd, command])
    }

    /// Runs a script with `osascript`, passing values as arguments so they are never parsed as
    /// AppleScript. The first run triggers macOS's "control Ghostty" consent prompt.
    @discardableResult
    private func runAppleScript(_ script: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-"] + arguments
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            logger.error("osascript failed to start: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        input.fileHandleForWriting.write(Data(script.utf8))
        try? input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            logger.error("osascript exited \(process.terminationStatus): \(errorText, privacy: .public)")
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Processes

    private func agentInfo(sessionId: String) -> AgentInfo? {
        guard let claude = HookInstaller.claudeExecutablePath(),
              let output = Self.run(claude, ["agents", "--json"]),
              let entries = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]],
              let entry = entries.first(where: { $0["sessionId"] as? String == sessionId }) else {
            return nil
        }
        return AgentInfo(kind: entry["kind"] as? String, shortId: entry["id"] as? String, pid: entry["pid"] as? Int)
    }

    private static func ttyName(ofPid pid: Int) -> String? {
        guard let tty = run("/bin/ps", ["-o", "tty=", "-p", String(pid)])?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !tty.isEmpty, tty != "??" else { return nil }
        return tty
    }

    /// A terminal running `claude attach <id>` for this session (the id is a session-id prefix)
    private static func isAttachClient(pid: Int, sessionId: String) -> Bool {
        guard let args = run("/bin/ps", ["-o", "args=", "-p", String(pid)])?
            .split(whereSeparator: \.isWhitespace) else { return false }
        guard args.count >= 3,
              args[0].split(separator: "/").last == "claude",
              args[1] == "attach",
              args[2].count >= 6 else { return false }
        return sessionId.hasPrefix(String(args[2]))
    }

    private static func isAlive(_ pid: Int) -> Bool {
        kill(pid_t(pid), 0) == 0
    }

    private static func run(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil
    }
}
