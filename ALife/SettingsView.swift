import ManagedAgents
import SwiftUI

/// Where the Anthropic API key is set, and where the IDs of the server-side
/// objects the app works with can be looked up.
struct SettingsView: View {
    @Environment(AgentSession.self) private var agentSession
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField(agentSession.hasAPIKey ? "Replace the stored key" : "sk-ant-…", text: $apiKey)
                        .autocorrectionDisabled()
                    Button(agentSession.hasAPIKey ? "Replace key" : "Save key") {
                        agentSession.setAPIKey(apiKey)
                        apiKey = ""
                        dismiss()
                    }
                    .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    if agentSession.hasAPIKey {
                        Button("Remove key", role: .destructive) {
                            agentSession.setAPIKey(nil)
                        }
                    }
                } header: {
                    Text("Anthropic API key")
                } footer: {
                    Text("Kept in the Keychain on this device and sent only to api.anthropic.com. The first connection creates an agent, an environment and a session in the key's workspace; using a different key later starts over.")
                }

                Section {
                    LabeledContent("Session", value: agentSession.reference.sessionID ?? "—")
                    LabeledContent("Agent", value: agentSession.reference.agentID ?? "—")
                    LabeledContent("Environment", value: agentSession.reference.environmentID ?? "—")
                    Button("Start a new session") {
                        agentSession.startNewSession()
                        dismiss()
                    }
                    .disabled(agentSession.reference.sessionID == nil)
                } header: {
                    Text("Session")
                } footer: {
                    Text("The session runs on Anthropic's side and keeps going when the app is closed. A new session leaves the old one in place; you can still open it in the Claude Console.")
                }
            }
            .formStyle(.grouped)
            .textSelection(.enabled)
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 420)
        #endif
    }
}
