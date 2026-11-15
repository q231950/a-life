import ALifeClient
import SwiftUI

/// How the server connection is doing, who is busy or waiting for you, and
/// the button that opens the settings.
struct SessionStatusBar: View {
    @Environment(ServerConnection.self) private var server
    @Binding var showsSettings: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.footnote)
                .lineLimit(2)
            Button("Settings", systemImage: "gearshape") {
                showsSettings = true
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: Capsule())
    }

    private var waiting: [String] { server.sessions.filter { $0.isWaitingForYou }.map { $0.name } }
    private var working: [String] { server.sessions.filter { $0.status == .running }.map { $0.name } }

    private var statusText: String {
        switch server.phase {
        case .needsServer: return "Set a server to meet the characters"
        case .connecting: return "Connecting…"
        case .reconnecting(let reason): return "Reconnecting… \(reason)"
        case .disconnected: return "Disconnected"
        case .live: break
        }
        if !waiting.isEmpty {
            return "\(ListFormatter.localizedString(byJoining: waiting)) \(waiting.count == 1 ? "is" : "are") waiting for you"
        }
        if !working.isEmpty {
            return "\(ListFormatter.localizedString(byJoining: working)) \(working.count == 1 ? "is" : "are") working"
        }
        return "Everyone is idle"
    }

    private var statusColor: Color {
        switch server.phase {
        case .live: return !waiting.isEmpty ? .orange : !working.isEmpty ? .green : .secondary
        case .needsServer, .reconnecting: return .orange
        default: return .yellow
        }
    }
}

/// Who you are talking to, and the conversation with them: everything said
/// so far, the tools the character used, its requests for a yes or no, and a
/// field for what to say next. Each character has a session of its own.
///
/// It folds down to a bar with each character's status, so the lot can be
/// seen in full.
struct AgentPanel: View {
    @Environment(ServerConnection.self) private var server
    /// The character you are talking to. `nil` means the first one.
    @Binding var selectedID: String?
    /// Whether the conversation is showing. Remembered between launches.
    @AppStorage("agentPanelIsExpanded") private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let session = server.session(selectedBy: selectedID) {
                HStack(spacing: 6) {
                    if server.sessions.count > 1 {
                        CharacterPicker(selectedID: session.id) { id in
                            selectedID = id
                            isExpanded = true
                        }
                    } else if !isExpanded {
                        CharacterStatus(session: session)
                    }
                    Spacer(minLength: 0)
                    Button(isExpanded ? "Hide the conversation" : "Show the conversation",
                           systemImage: isExpanded ? "chevron.down" : "chevron.up") {
                        withAnimation(.snappy) { isExpanded.toggle() }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                }
                if isExpanded {
                    // A fresh view per character, so a half-typed message can't
                    // end up with someone it wasn't meant for.
                    ConversationView(session: session)
                        .id(session.id)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            } else {
                Text(server.phase == .live ? "There's no one on the lot." : "Connect to a server to meet the characters.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: 520)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// One button per character, showing whether it is working or waiting for you.
private struct CharacterPicker: View {
    @Environment(ServerConnection.self) private var server
    let selectedID: String
    let select: (String) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(server.sessions, id: \.id) { session in
                Button {
                    select(session.id)
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(session.statusColor)
                            .frame(width: 8, height: 8)
                        Text(session.name)
                    }
                    .font(.footnote)
                }
                .buttonStyle(.bordered)
                .tint(session.id == selectedID ? Color.accentColor : Color.gray)
                .accessibilityValue(session.statusText)
            }
        }
    }
}

/// A character's name and what it is up to, with a dot in the colour of its
/// status.
private struct CharacterStatus: View {
    let session: AgentSession

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(session.statusColor)
                .frame(width: 8, height: 8)
            Text("\(session.name) · \(session.statusText)")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// The conversation with one character.
private struct ConversationView: View {
    @Environment(ServerConnection.self) private var server
    let session: AgentSession
    @State private var draft = ""

    private var isConnected: Bool { server.phase == .live }

    private var prompt: String {
        session.isWaitingForYou ? "Answer \(session.name) first" : "Talk to \(session.name)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                CharacterStatus(session: session)
                Spacer()
                Menu {
                    Button("Start over", systemImage: "arrow.counterclockwise", role: .destructive) {
                        Task { await session.startOver() }
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(!isConnected)
            }

            if session.conversation.isEmpty {
                Text("Nothing said yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ConversationHistory(session: session)
            }

            if let error = session.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            HStack {
                // Works while the character is busy, too: it answers at its
                // next step. Not while it waits for an answer, though.
                Group {
                    TextField(prompt, text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(send)
                    Button("Send", systemImage: "paperplane.fill", action: send)
                        .labelStyle(.iconOnly)
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .disabled(session.isWaitingForYou)
                // Stopping while it waits withdraws the request, too.
                if session.status == .running || session.isWaitingForYou {
                    Button("Stop", systemImage: "stop.fill") {
                        Task { await session.interrupt() }
                    }
                    .labelStyle(.iconOnly)
                }
            }
            .disabled(!isConnected)
        }
    }

    private func send() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        draft = ""
        Task { await session.send(text) }
    }
}

/// Everything in the conversation so far, oldest first, in a view that
/// scrolls. It follows along as new things arrive, unless you've scrolled up
/// to read, and then offers a way back down.
private struct ConversationHistory: View {
    @Environment(ServerConnection.self) private var server
    let session: AgentSession

    /// How tall the conversation may grow before it scrolls, so the lot
    /// stays in view.
    private let maxHeight: CGFloat = 300
    private let bottomID = "bottom"

    @State private var contentHeight: CGFloat = 0
    @State private var isAtBottom = true

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(session.conversation) { entry in
                        switch entry {
                        case .message(let message):
                            MessageRow(message: message)
                        case .toolUse(let toolUse):
                            ToolUseRow(toolUse: toolUse)
                        case .approval(let approval, let outcome):
                            ApprovalRow(session: session, approval: approval, outcome: outcome, canAnswer: server.phase == .live)
                        }
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(bottomID)
                }
                .padding(.trailing, 4)
            }
            .defaultScrollAnchor(.bottom)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, height in
                contentHeight = height
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.visibleRect.maxY >= geometry.contentSize.height - 24
            } action: { _, atBottom in
                isAtBottom = atBottom
            }
            .onChange(of: session.conversation.last) {
                guard isAtBottom else { return }
                withAnimation { proxy.scrollTo(bottomID, anchor: .bottom) }
            }
            .frame(height: min(max(contentHeight, 20), maxHeight))
            .overlay(alignment: .bottomTrailing) {
                if !isAtBottom {
                    Button(session.isWaitingForYou ? "Answer \(session.name)" : "Latest",
                           systemImage: "arrow.down") {
                        withAnimation { proxy.scrollTo(bottomID, anchor: .bottom) }
                    }
                    .font(.caption)
                    .buttonStyle(.borderedProminent)
                    .tint(session.isWaitingForYou ? .orange : .accentColor)
                    .padding(4)
                }
            }
        }
    }
}

/// Something said in the conversation, in full.
private struct MessageRow: View {
    let message: Message

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(message.speaker)
                .font(.caption.bold())
                .foregroundStyle(message.kind == .user ? Color.accentColor : Color.secondary)
            Text(Self.styled(message.text))
                .font(.footnote)
                .foregroundStyle(message.kind == .error ? Color.red : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The characters write in Markdown. Its bold, italics, code and links
    /// are shown as such; the rest is left as written.
    private static func styled(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

/// A tool the character used, in one line. Tap it to see all of it.
private struct ToolUseRow: View {
    let toolUse: ToolUse
    @State private var showsAll = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "wrench.and.screwdriver")
            Text(toolUse.toolName).bold()
            Text(toolUse.input)
                .font(.caption.monospaced())
                .lineLimit(showsAll ? nil : 1)
                .truncationMode(.middle)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .contentShape(Rectangle())
        .onTapGesture { showsAll.toggle() }
    }
}

/// A tool call that asked for a yes or no: with the buttons to answer while
/// it waits, and what became of it once it was settled.
private struct ApprovalRow: View {
    let session: AgentSession
    let approval: Approval
    /// `nil` while it waits for an answer.
    let outcome: ApprovalOutcome?
    let canAnswer: Bool

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(outcome == nil ? "\(session.name) wants to use \(approval.toolName)" : "\(session.name) asked to use \(approval.toolName)")
                    .font(.footnote.bold())
                Text(approval.input)
                    .font(.caption.monospaced())
                    .lineLimit(outcome == nil ? 6 : 2)
                    .textSelection(.enabled)
            }
            Spacer()
            if let outcome {
                Label(outcome.label, systemImage: outcome.systemImage)
                    .font(.caption.bold())
                    .foregroundStyle(outcome.color)
            } else {
                Button("Deny") {
                    Task { await session.respond(to: approval, allow: false) }
                }
                Button("Allow") {
                    Task { await session.respond(to: approval, allow: true) }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(8)
        .background(
            (outcome == nil ? Color.orange.opacity(0.15) : Color.secondary.opacity(0.08)),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .disabled(outcome == nil && !canAnswer)
    }
}

extension ApprovalOutcome {
    var label: String {
        switch self {
        case .allowed: return "Allowed"
        case .denied: return "Denied"
        case .withdrawn: return "No longer needed"
        case .unknown: return "Answered"
        }
    }

    var systemImage: String {
        switch self {
        case .allowed: return "checkmark.circle.fill"
        case .denied: return "xmark.circle.fill"
        case .withdrawn: return "minus.circle"
        case .unknown: return "circle"
        }
    }

    var color: Color {
        switch self {
        case .allowed: return .green
        case .denied: return .red
        default: return .secondary
        }
    }
}

extension ServerConnection {
    /// The session with `id`, or the first one if there's no such session.
    func session(selectedBy id: String?) -> AgentSession? {
        sessions.first { $0.id == id } ?? sessions.first
    }
}

extension AgentSession {
    var statusText: String {
        if isWaitingForYou { return "Waiting for you" }
        switch status {
        case .running: return activity.map { "Working: \($0)" } ?? "Working"
        case .terminated: return "Session ended"
        default: return stopReason == .interrupted ? "Stopped" : "Idle"
        }
    }

    var statusColor: Color {
        if isWaitingForYou { return .orange }
        return status == .running ? .green : .secondary
    }
}
