//
//  ClaudeAgentsWatcher.swift
//  ClaudeIsland
//
//  Keeps SessionStore in step with Claude Code's own view of its sessions, so a
//  session that was already waiting when the app started, or whose hook event was
//  lost, still shows correctly. A session waiting on the user fires no hooks.
//

import CoreServices
import Foundation
import os.log

/// One live session as `claude agents --json` reports it
nonisolated struct ClaudeAgentEntry: Sendable {
    enum Status: String, Sendable {
        case busy, idle, waiting
    }

    let sessionId: String
    let cwd: String
    let pid: Int
    /// nil for a status this app does not know; the session still counts as listed
    let status: Status?
}

nonisolated struct ClaudeAgentsSnapshot: Sendable {
    let entries: [ClaudeAgentEntry]
    /// When the `claude agents` call started; hook changes after this are fresher
    let capturedAt: Date
    /// ClaudePaths.projectsDir, resolved on the main actor
    let projectsDir: String
}

/// Claude Code rewrites `<claude dir>/sessions/<pid>.json` on every status change. Each
/// change (FSEvents, coalesced over 300 ms), launch, and a 60 s safety poll trigger one
/// `claude agents --json` call, the supported way to read those files.
final class ClaudeAgentsWatcher {
    static let shared = ClaudeAgentsWatcher()

    private let logger = Logger(subsystem: "com.claudeisland", category: "AgentsWatcher")
    private var stream: FSEventStreamRef?
    private var safetyTimer: Timer?
    private var isRefreshing = false
    private var refreshRequested = false

    private init() {}

    func start() {
        guard safetyTimer == nil else { return }
        startStream()
        safetyTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    func stop() {
        safetyTimer?.invalidate()
        safetyTimer = nil
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
    }

    private func startStream() {
        let sessionsDir = ClaudePaths.claudeDir.appendingPathComponent("sessions").path
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
            guard let info else { return }
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            // The *.key files there are credentials; never read them, and they are not status
            guard paths.contains(where: { $0.hasSuffix(".json") }) else { return }
            let watcher = Unmanaged<ClaudeAgentsWatcher>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.refresh() }
        }
        guard let stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            [sessionsDir] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        ) else {
            logger.error("Could not watch \(sessionsDir, privacy: .public); relying on the 60 s poll")
            return
        }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func refresh() {
        guard !isRefreshing else {
            refreshRequested = true
            return
        }
        guard let claudePath = HookInstaller.claudeExecutablePath() else {
            logger.error("claude binary not found; cannot reconcile sessions")
            return
        }
        isRefreshing = true
        let capturedAt = Date()
        #if DEBUG
        // Exercise reconciliation without a real waiting session: a fake `claude agents`
        // output and a transcripts root holding a hand-built transcript.
        let environment = Foundation.ProcessInfo.processInfo.environment
        let fakeAgentsJSON = environment["VIBE_NOTCH_FAKE_AGENTS_JSON"]
        let projectsDir = environment["VIBE_NOTCH_FAKE_PROJECTS_DIR"] ?? ClaudePaths.projectsDir.path
        #else
        let projectsDir = ClaudePaths.projectsDir.path
        #endif

        Task {
            #if DEBUG
            let output = if let fakeAgentsJSON {
                FileManager.default.contents(atPath: fakeAgentsJSON)
            } else {
                await Self.runAgentsCommand(claudePath)
            }
            #else
            let output = await Self.runAgentsCommand(claudePath)
            #endif
            if let output, let entries = Self.parseEntries(output) {
                let snapshot = ClaudeAgentsSnapshot(entries: entries, capturedAt: capturedAt, projectsDir: projectsDir)
                await SessionStore.shared.process(.agentsSnapshot(snapshot))
            } else {
                logger.error("claude agents --json failed or returned unreadable output; skipping")
            }
            isRefreshing = false
            if refreshRequested {
                refreshRequested = false
                refresh()
            }
        }
    }

    private nonisolated static func runAgentsCommand(_ claudePath: String) async -> Data? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: runAgentsCommandSync(claudePath))
            }
        }
    }

    private nonisolated static func runAgentsCommandSync(_ claudePath: String) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claudePath)
        process.arguments = ["agents", "--json"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10) {
            if process.isRunning { process.terminate() }
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }

    /// Entries without a pid are background sessions that are not running (some are months
    /// old and still listed as blocked); they are skipped.
    nonisolated static func parseEntries(_ data: Data) -> [ClaudeAgentEntry]? {
        guard let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return items.compactMap { item in
            guard let pid = item["pid"] as? Int,
                  let sessionId = item["sessionId"] as? String,
                  let cwd = item["cwd"] as? String else { return nil }
            // Interactive sessions report `status`; background ones also report `state`
            let status: ClaudeAgentEntry.Status?
            switch (item["status"] as? String) ?? (item["state"] as? String) {
            case "busy", "working": status = .busy
            case "idle": status = .idle
            case "waiting", "blocked": status = .waiting
            default: status = nil
            }
            return ClaudeAgentEntry(sessionId: sessionId, cwd: cwd, pid: pid, status: status)
        }
    }
}
