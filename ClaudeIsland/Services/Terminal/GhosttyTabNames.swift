//
//  GhosttyTabNames.swift
//  ClaudeIsland
//
//  Titles the user gave Ghostty tabs, used in place of a session's own title
//

import AppKit
import Combine

@MainActor
final class GhosttyTabNames: ObservableObject {
    static let shared = GhosttyTabNames()

    @Published private(set) var byPid: [Int: String] = [:]
    @Published private(set) var byTTY: [String: String] = [:]

    private var isRefreshing = false

    private init() {}

    func title(for session: SessionState) -> String? {
        session.pid.flatMap { byPid[$0] } ?? session.tty.flatMap { byTTY[$0] }
    }

    /// Asking a Ghostty that is not running would launch it, so this does nothing then.
    func refresh() {
        guard !isRefreshing,
              !NSRunningApplication.runningApplications(withBundleIdentifier: "com.mitchellh.ghostty").isEmpty
        else { return }
        isRefreshing = true
        Task {
            let rows = await GhosttyFocuser.shared.tabNameOverrides()
            byPid = Dictionary(rows.map { ($0.pid, $0.name) }, uniquingKeysWith: { first, _ in first })
            byTTY = Dictionary(rows.map { ($0.tty, $0.name) }, uniquingKeysWith: { first, _ in first })
            isRefreshing = false
        }
    }
}
