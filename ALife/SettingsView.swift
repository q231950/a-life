import ALifeClient
import SwiftUI

/// Where the address of the a-life-server is set.
struct SettingsView: View {
    @Environment(AgentSession.self) private var agentSession
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var addressIsInvalid = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://my-mac.my-tailnet.ts.net", text: $address)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                        .onSubmit(save)
                    Button("Connect", action: save)
                        .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Use this machine (localhost:8080)") {
                        address = "http://localhost:8080"
                        save()
                    }
                    if addressIsInvalid {
                        Text("That isn't an http or https address.")
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Server")
                } footer: {
                    Text("The address of your a-life-server. Over Tailscale, that is the https address `tailscale serve` prints on the Mac running it. See a-life-server/README.md.")
                }

                Section {
                    LabeledContent("Connected to", value: agentSession.serverURL?.absoluteString ?? "—")
                    Button("Start a new session") {
                        Task { await agentSession.startNewSession() }
                        dismiss()
                    }
                    .disabled(agentSession.phase != .live)
                    if agentSession.serverURL != nil {
                        Button("Forget this server", role: .destructive) {
                            agentSession.setServerURL("")
                            address = ""
                        }
                    }
                } header: {
                    Text("Session")
                } footer: {
                    Text("The session lives on the server and is shared by every front end connected to it. Starting a new one clears it for all of them.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                address = agentSession.serverURL?.absoluteString ?? ""
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 420)
        #endif
    }

    private func save() {
        addressIsInvalid = !agentSession.setServerURL(address)
        if !addressIsInvalid { dismiss() }
    }
}
