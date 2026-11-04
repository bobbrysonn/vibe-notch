//
//  ClaudeInstancesView.swift
//  ClaudeIsland
//
//  Minimal instances list matching Dynamic Island aesthetic
//

import SwiftUI

struct ClaudeInstancesView: View {
    @ObservedObject var sessionMonitor: ClaudeSessionMonitor
    @ObservedObject private var tabNames = GhosttyTabNames.shared
    @ObservedObject var viewModel: NotchViewModel

    var body: some View {
        if sessionMonitor.instances.isEmpty {
            emptyState
        } else {
            instancesList
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No sessions")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.4))

            Text("Run claude in terminal")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.25))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Instances List

    /// Sections in urgency order; within a section, the most recent state change first
    private var sections: [(group: SessionGroup, sessions: [SessionState])] {
        let grouped = Dictionary(grouping: sessionMonitor.instances, by: { $0.group })
        return SessionGroup.allCases.compactMap { group in
            guard let sessions = grouped[group], !sessions.isEmpty else { return nil }
            let sorted = sessions.sorted { a, b in
                if a.phaseChangedAt != b.phaseChangedAt {
                    return a.phaseChangedAt > b.phaseChangedAt
                }
                return a.sessionId < b.sessionId
            }
            return (group, sorted)
        }
    }

    private var instancesList: some View {
        let showLastPrompt = sessionMonitor.instances.count <= 5
        return TimelineView(.periodic(from: .now, by: 15)) { context in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(sections, id: \.group) { section in
                        SessionSectionHeader(group: section.group)
                        ForEach(section.sessions) { session in
                            InstanceRow(
                                session: session,
                                title: tabNames.title(for: session) ?? session.displayTitle,
                                now: context.date,
                                showLastPrompt: showLastPrompt,
                                onFocus: { focusSession(session) },
                                onChat: { openChat(session) },
                                onArchive: { archiveSession(session) },
                                onApprove: { approveSession(session) },
                                onReject: { rejectSession(session) }
                            )
                            .id(session.stableId)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .task {
            while !Task.isCancelled {
                tabNames.refresh()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    // MARK: - Actions

    private func focusSession(_ session: SessionState) {
        viewModel.notchClose()
        Task {
            await GhosttyFocuser.shared.open(
                sessionId: session.sessionId, cwd: session.cwd, pid: session.pid, tty: session.tty
            )
        }
    }

    private func openChat(_ session: SessionState) {
        viewModel.showChat(for: session)
    }

    private func approveSession(_ session: SessionState) {
        sessionMonitor.approvePermission(sessionId: session.sessionId)
    }

    private func rejectSession(_ session: SessionState) {
        sessionMonitor.denyPermission(sessionId: session.sessionId, reason: nil)
    }

    private func archiveSession(_ session: SessionState) {
        sessionMonitor.archiveSession(sessionId: session.sessionId)
    }
}

// MARK: - Grouping and Row Text

enum SessionGroup: Int, CaseIterable, Hashable {
    case needsYou, working, idle

    var title: String {
        switch self {
        case .needsYou: return "NEEDS YOU"
        case .working: return "WORKING"
        case .idle: return "IDLE"
        }
    }
}

extension SessionState {
    /// An AskUserQuestion is open; it can arrive as a permission request or only as a running tool
    var hasOpenQuestionTool: Bool {
        if case .waitingForApproval(let ctx) = phase {
            return ctx.toolName == "AskUserQuestion"
        }
        return toolTracker.inProgress.values.contains { $0.name == "AskUserQuestion" }
    }

    var group: SessionGroup {
        switch phase {
        case .waitingForApproval:
            return .needsYou
        case .processing, .compacting:
            return hasOpenQuestionTool ? .needsYou : .working
        case .waitingForInput, .idle:
            return conversationInfo.lastAssistantQuestion != nil ? .needsYou : .idle
        case .ended:
            return .idle
        }
    }

    /// "project · branch", capped so a long branch name cannot push the title out
    var projectLabel: String {
        let label = conversationInfo.gitBranch.map { "\(projectName) · \($0)" } ?? projectName
        guard label.count > 34 else { return label }
        return String(label.prefix(20)) + "…" + String(label.suffix(13))
    }

    /// Line 2: what the session is asking or doing; `isAsk` marks text that needs the user
    var activityLine: (text: String, isAsk: Bool) {
        switch phase {
        case .waitingForApproval(let ctx):
            if ctx.toolName == "AskUserQuestion" {
                return ("Asks: " + (Self.question(in: ctx) ?? "needs your input"), true)
            }
            let detail = Self.permissionDetail(ctx).map { " " + $0 } ?? ""
            return ("Permission: " + MCPToolFormatter.formatToolName(ctx.toolName) + detail, true)
        case .processing, .compacting:
            if hasOpenQuestionTool {
                let question = lastToolName == "AskUserQuestion" ? lastMessage : nil
                return ("Asks: " + (question ?? "needs your input"), true)
            }
            if case .compacting = phase {
                return ("Compacting…", false)
            }
            var text = currentStep
            let running = subagentState.activeTasks.count
            if running > 0 {
                text += " · \(running) agent\(running == 1 ? "" : "s") running"
            }
            return (text, false)
        case .waitingForInput, .idle, .ended:
            if let question = conversationInfo.lastAssistantQuestion {
                return ("Asks: " + question, true)
            }
            if let firstLine = conversationInfo.lastAssistantFirstLine {
                return ("Done: " + firstLine, false)
            }
            return (phase == .ended ? "Ended" : "Idle", false)
        }
    }

    private var currentStep: String {
        switch lastMessageRole {
        case "tool":
            let tool = lastToolName ?? "Tool"
            let detail = lastMessage ?? ""
            switch tool {
            case "Bash":
                return detail.isEmpty ? "Bash" : detail
            case "Task", "Agent":
                return detail.isEmpty ? "Agent" : "Agent: " + detail
            case "Read", "Write", "Edit", "MultiEdit", "NotebookEdit":
                return detail.isEmpty ? tool : "\(tool): \(detail)"
            default:
                let name = MCPToolFormatter.formatToolName(tool)
                return detail.isEmpty ? name : "\(name): \(detail)"
            }
        case "assistant":
            return lastMessage ?? "Working…"
        default:
            return "Thinking…"
        }
    }

    private static func question(in ctx: PermissionContext) -> String? {
        guard let questions = ctx.toolInput?["questions"]?.value as? [Any],
              let first = questions.first as? [String: Any] else { return nil }
        return first["question"] as? String
    }

    private static func permissionDetail(_ ctx: PermissionContext) -> String? {
        if ctx.toolName == "Bash",
           let description = ctx.toolInput?["description"]?.value as? String,
           !description.isEmpty {
            return description
        }
        return ctx.formattedInput
    }

    static func elapsedLabel(since date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86400)d"
    }
}

// MARK: - Section Header

struct SessionSectionHeader: View {
    let group: SessionGroup

    var body: some View {
        Text(group.title)
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.6)
            .foregroundColor(group == .needsYou ? TerminalColors.amber.opacity(0.75) : .white.opacity(0.35))
            .padding(.leading, 12)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }
}

// MARK: - Instance Row

struct InstanceRow: View {
    let session: SessionState
    /// The Ghostty tab name the user set, else the session's own title
    let title: String
    let now: Date
    let showLastPrompt: Bool
    let onFocus: () -> Void
    let onChat: () -> Void
    let onArchive: () -> Void
    let onApprove: () -> Void
    let onReject: () -> Void

    @State private var isHovered = false
    @State private var isSpinnerAnimating = false

    private let claudeOrange = Color(red: 0.85, green: 0.47, blue: 0.34)

    /// Whether we're showing the approval UI
    private var isWaitingForApproval: Bool {
        session.phase.isWaitingForApproval
    }

    /// Whether the pending request must be answered in the terminal: an interactive tool,
    /// or a request found by reconciliation that no hook socket waits on
    private var isInteractiveTool: Bool {
        guard let permission = session.activePermission else { return false }
        return permission.toolName == "AskUserQuestion" || !permission.isAnswerable
    }

    var body: some View {
        let activity = session.activityLine

        HStack(alignment: .center, spacing: 10) {
            stateIndicator
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Text(session.projectLabel)
                        .font(.system(size: 10.5))
                        .foregroundColor(.white.opacity(0.4))
                        .lineLimit(1)
                        .fixedSize()

                    if session.usage.totalTokens > 0 {
                        Text(session.usage.formattedTotal)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.25))
                            .fixedSize()
                    }
                }

                HStack(spacing: 6) {
                    Text(activity.text)
                        .font(.system(size: 11))
                        .foregroundColor(activity.isAsk ? TerminalColors.amber.opacity(0.9) : .white.opacity(0.5))
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Text(SessionState.elapsedLabel(since: session.phaseChangedAt, now: now))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.35))
                        .fixedSize()
                }

                if showLastPrompt, let prompt = session.conversationInfo.lastPrompt {
                    Text("You: " + prompt)
                        .font(.system(size: 10.5))
                        .foregroundColor(.white.opacity(0.28))
                        .lineLimit(1)
                }
            }

            // Action icons or approval buttons
            if isWaitingForApproval && isInteractiveTool {
                // Interactive tools like AskUserQuestion are answered in the terminal
                HStack(spacing: 8) {
                    OpenInGhosttyButton(action: onFocus)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            } else if isWaitingForApproval {
                InlineApprovalButtons(
                    onFocus: onFocus,
                    onApprove: onApprove,
                    onReject: onReject
                )
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            } else {
                HStack(spacing: 8) {
                    OpenInGhosttyButton(action: onFocus)

                    // Archive button - only for idle or completed sessions
                    if session.phase == .idle || session.phase == .waitingForInput {
                        IconButton(icon: "archivebox") {
                            onArchive()
                        }
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 14)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            onChat()
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isWaitingForApproval)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isHovered ? Color.white.opacity(0.06) : Color.clear)
        )
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var stateIndicator: some View {
        switch session.group {
        case .needsYou:
            Circle()
                .fill(TerminalColors.amber)
                .frame(width: 7, height: 7)
        case .working:
            Text("✳")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(claudeOrange)
                .rotationEffect(.degrees(isSpinnerAnimating ? 360 : 0))
                .animation(
                    .linear(duration: 1.0).repeatForever(autoreverses: false),
                    value: isSpinnerAnimating
                )
                .onAppear { isSpinnerAnimating = true }
                .onDisappear { isSpinnerAnimating = false }
        case .idle:
            Circle()
                .strokeBorder(Color.white.opacity(0.3), lineWidth: 1)
                .frame(width: 7, height: 7)
        }
    }
}

// MARK: - Open in Ghostty

/// Brings the session's Ghostty terminal to the front (or opens a tab that reaches it)
struct OpenInGhosttyButton: View {
    let action: () -> Void

    var body: some View {
        IconButton(icon: "arrow.up.right", action: action)
            .help("Open in Ghostty")
    }
}

// MARK: - Inline Approval Buttons

/// Compact inline approval buttons with staggered animation
struct InlineApprovalButtons: View {
    let onFocus: () -> Void
    let onApprove: () -> Void
    let onReject: () -> Void

    @State private var showChatButton = false
    @State private var showDenyButton = false
    @State private var showAllowButton = false

    var body: some View {
        HStack(spacing: 6) {
            OpenInGhosttyButton(action: onFocus)
            .opacity(showChatButton ? 1 : 0)
            .scaleEffect(showChatButton ? 1 : 0.8)

            Button {
                onReject()
            } label: {
                Text("Deny")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.1))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .opacity(showDenyButton ? 1 : 0)
            .scaleEffect(showDenyButton ? 1 : 0.8)

            Button {
                onApprove()
            } label: {
                Text("Allow")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.9))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .opacity(showAllowButton ? 1 : 0)
            .scaleEffect(showAllowButton ? 1 : 0.8)
        }
        .onAppear {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.0)) {
                showChatButton = true
            }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.05)) {
                showDenyButton = true
            }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.1)) {
                showAllowButton = true
            }
        }
    }
}

// MARK: - Icon Button

struct IconButton: View {
    let icon: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button {
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isHovered ? .white.opacity(0.8) : .white.opacity(0.4))
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHovered ? Color.white.opacity(0.1) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}


