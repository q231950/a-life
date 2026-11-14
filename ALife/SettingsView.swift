import ALifeClient
import SwiftUI

/// Where the address of the a-life-server is set.
struct SettingsView: View {
    @Environment(ServerConnection.self) private var server
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
                    LabeledContent("Connected to", value: server.serverURL?.absoluteString ?? "—")
                    Button("Start every session over") {
                        Task { await server.startEverySessionOver() }
                        dismiss()
                    }
                    .disabled(server.phase != .live || server.sessions.isEmpty)
                    if server.serverURL != nil {
                        Button("Forget this server", role: .destructive) {
                            server.setServerURL("")
                            address = ""
                        }
                    }
                } header: {
                    Text("Sessions")
                } footer: {
                    Text("Each character has a session of its own on the server, shared by every front end connected to it. Starting one over clears its conversation for all of them. To start just one over, use the … button next to its name.")
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
                address = server.serverURL?.absoluteString ?? ""
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 420)
        #endif
    }

    private func save() {
        addressIsInvalid = !server.setServerURL(address)
        if !addressIsInvalid { dismiss() }
    }
}
