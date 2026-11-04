//
//  TranscriptTail.swift
//  ClaudeIsland
//
//  Reads the end of a session transcript without parsing the whole file.
//

import Foundation

nonisolated struct TranscriptTail: Sendable {
    struct ToolUse: Sendable {
        let id: String
        let name: String
        let input: [String: AnyCodable]?
        let timestamp: Date?
    }

    /// Timestamp of the newest record that carries one
    let newestTimestamp: Date?

    /// Newest tool call since the user's last prompt that has no tool_result yet
    let pendingToolUse: ToolUse?

    static func read(projectsDir: String, cwd: String, sessionId: String) -> TranscriptTail? {
        guard let path = transcriptPath(projectsDir: projectsDir, cwd: cwd, sessionId: sessionId) else {
            return nil
        }
        // A pending Write or Edit can carry a large input, so widen once if the first
        // window holds no assistant record at all.
        var last: TranscriptTail?
        for window in [256 * 1024, 4 * 1024 * 1024] {
            guard let (lines, isWholeFile) = readTailLines(path: path, maxBytes: window) else { return nil }
            let (tail, sawAssistant) = parse(lines)
            last = tail
            if sawAssistant || isWholeFile { break }
        }
        return last
    }

    private static func transcriptPath(projectsDir: String, cwd: String, sessionId: String) -> String? {
        let fm = FileManager.default
        let parserStyle = cwd.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
        let everyNonAlphanumeric = String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        for dir in [parserStyle, everyNonAlphanumeric] {
            let path = projectsDir + "/" + dir + "/" + sessionId + ".jsonl"
            if fm.fileExists(atPath: path) { return path }
        }
        return nil
    }

    private static func readTailLines(path: String, maxBytes: Int) -> ([Substring], Bool)? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return nil }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        if offset > 0, !lines.isEmpty {
            lines.removeFirst()  // starts mid-record
        }
        return (lines, offset == 0)
    }

    private static func parse(_ lines: [Substring]) -> (TranscriptTail, sawAssistant: Bool) {
        var newest: Date?
        var toolUses: [ToolUse] = []
        var resolved = Set<String>()
        var sawAssistant = false

        for line in lines {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  json["isSidechain"] as? Bool != true else { continue }

            let timestamp = (json["timestamp"] as? String).flatMap(parseDate)
            if let timestamp, newest.map({ timestamp > $0 }) ?? true {
                newest = timestamp
            }

            guard let type = json["type"] as? String,
                  let message = json["message"] as? [String: Any] else { continue }

            if type == "assistant" {
                sawAssistant = true
                for block in message["content"] as? [[String: Any]] ?? [] where block["type"] as? String == "tool_use" {
                    guard let id = block["id"] as? String, let name = block["name"] as? String else { continue }
                    let input = (block["input"] as? [String: Any])?.mapValues { AnyCodable($0) }
                    toolUses.append(ToolUse(id: id, name: name, input: input, timestamp: timestamp))
                }
            } else if type == "user", json["isMeta"] as? Bool != true {
                let blocks = message["content"] as? [[String: Any]] ?? []
                let results = blocks.filter { $0["type"] as? String == "tool_result" }
                if results.isEmpty {
                    // A new prompt: anything still open before it was abandoned
                    toolUses.removeAll()
                    resolved.removeAll()
                } else {
                    for block in results {
                        if let id = block["tool_use_id"] as? String { resolved.insert(id) }
                    }
                }
            }
        }

        let pending = toolUses.last { !resolved.contains($0.id) }
        return (TranscriptTail(newestTimestamp: newest, pendingToolUse: pending), sawAssistant)
    }

    private static func parseDate(_ string: String) -> Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string))
            ?? (try? Date.ISO8601FormatStyle().parse(string))
    }
}
