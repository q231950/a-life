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

/// Who you are talking to, and the conversation with them: the latest
/// messages, any tool calls waiting for a yes or no, and a field for what to
/// say next. Each character has a session of its own.
struct AgentPanel: View {
    @Environment(ServerConnection.self) private var server
    /// The character you are talking to. `nil` means the first one.
    @Binding var selectedID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let session = server.session(selectedBy: selectedID) {
                if server.sessions.count > 1 {
                    CharacterPicker(selectedID: session.id) { selectedID = $0 }
                }
                // A fresh view per character, so a half-typed message can't
                // end up with someone it wasn't meant for.
                ConversationView(session: session)
                    .id(session.id)
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
                Circle()
                    .fill(session.statusColor)
                    .frame(width: 8, height: 8)
                Text("\(session.name) · \(session.statusText)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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

            ForEach(session.transcript.suffix(3)) { entry in
                (Text(entry.speaker).bold() + Text("  " + entry.text))
                    .font(.footnote)
                    .foregroundStyle(entry.kind == .error ? Color.red : Color.primary)
                    .lineLimit(3)
            }

            ForEach(session.pendingApprovals) { approval in
                HStack {
                    VStack(alignment: .leading) {
                        Text("\(session.name) wants to use \(approval.toolName)")
                            .font(.footnote.bold())
                        Text(approval.input)
                            .font(.caption.monospaced())
                            .lineLimit(2)
                    }
                    Spacer()
                    Button("Deny") {
                        Task { await session.respond(to: approval, allow: false) }
                    }
                    Button("Allow") {
                        Task { await session.respond(to: approval, allow: true) }
                    }
                    .buttonStyle(.borderedProminent)
                }
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
