import ALifeClient
import SwiftUI

/// Where the address of the a-life-server is set.
struct SettingsView: View {
    @Environment(ServerConnection.self) private var server
    @Environment(Voices.self) private var voices
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

                Section {
                    LabeledContent("Voices", value: voicesStatus)
                    if voices.status == .ready {
                        LabeledContent("Last said", value: voices.lastSaid ?? "Nothing yet")
                            .lineLimit(2)
                    }
                    if let problem = voices.problem {
                        LabeledContent("Problem", value: problem)
                    }
                    if case .unavailable = voices.status {
                        Button("Try again") { voices.load(from: server.voiceModelURL) }
                    }
                } header: {
                    Text("Voices")
                } footer: {
                    Text("Each character says what it has to say out loud, in a voice of its own, while you stand within \(Int(Earshot.distance)) tiles of it. If you were further away, it calls you once its job is done, and you can take the call to hear what you missed. What happened while the app was closed, or finished before you came back, is never said or rung about: it is in the log, behind the list button at the top, under While you were away. Nothing said yet, with the voices ready, means no character has had anything to say near you. The voice model comes from the server once, and speaks on this device. See Voices in a-life-server/README.md.")
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

    private var voicesStatus: String {
        switch voices.status {
        case .off: return "Off"
        case .downloading(let fraction): return "Downloading, \(Int(fraction * 100))%"
        case .loading: return "Getting ready"
        case .ready: return "Ready"
        case .unavailable(let reason): return reason
        }
    }

    private func save() {
        addressIsInvalid = !server.setServerURL(address)
        if !addressIsInvalid { dismiss() }
    }
}
