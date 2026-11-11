import ManagedAgents
import SwiftUI

/// What the session is doing, and the button that opens the settings.
struct SessionStatusBar: View {
    @Environment(AgentSession.self) private var agentSession
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

    private var statusText: String {
        switch agentSession.phase {
        case .needsAPIKey: return "Add an API key to bring in the agents"
        case .settingUp: return "Setting up the team…"
        case .connecting: return "Connecting…"
        case .reconnecting: return "Reconnecting…"
        case .failed(let message): return message
        case .disconnected: return agentSession.status == .terminated ? "Session ended" : "Disconnected"
        case .live: break
        }
        switch agentSession.status {
        case .running:
            let working = agentSession.agents.filter { $0.status == .running }.count
            return working == 1 ? "1 agent working" : "\(working) agents working"
        case .terminated:
            return "Session ended"
        default:
            switch agentSession.stopReason {
            case "requires_action": return "Waiting for your answer"
            case "budget_reached": return "Session budget reached"
            default: return "Agents are idle"
            }
        }
    }

    private var statusColor: Color {
        switch agentSession.phase {
        case .live: return agentSession.status == .running ? .green : .secondary
        case .failed, .needsAPIKey: return .orange
        default: return .yellow
        }
    }
}

/// The conversation with the team: the latest messages, any tool calls
/// waiting for a yes or no, and a field for the next instruction.
struct AgentPanel: View {
    @Environment(AgentSession.self) private var agentSession
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(agentSession.transcript.suffix(3)) { entry in
                (Text(entry.speaker).bold() + Text("  " + entry.text))
                    .font(.footnote)
                    .foregroundStyle(entry.kind == .error ? Color.red : Color.primary)
                    .lineLimit(3)
            }

            ForEach(agentSession.pendingApprovals) { approval in
                HStack {
                    VStack(alignment: .leading) {
                        Text("\(approval.agentName) wants to use \(approval.toolName)")
                            .font(.footnote.bold())
                        Text(approval.input)
                            .font(.caption.monospaced())
                            .lineLimit(2)
                    }
                    Spacer()
                    Button("Deny") {
                        Task { await agentSession.respond(to: approval, allow: false) }
                    }
                    Button("Allow") {
                        Task { await agentSession.respond(to: approval, allow: true) }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            if let error = agentSession.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            HStack {
                TextField("Tell the team what to do", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                Button("Send", systemImage: "paperplane.fill", action: send)
                    .labelStyle(.iconOnly)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                if agentSession.status == .running {
                    Button("Stop", systemImage: "stop.fill") {
                        Task { await agentSession.interrupt() }
                    }
                    .labelStyle(.iconOnly)
                }
            }
            .disabled(agentSession.phase != .live)
        }
        .padding(12)
        .frame(maxWidth: 520)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func send() {
        let text = draft
        draft = ""
        Task { await agentSession.send(text) }
    }
}
