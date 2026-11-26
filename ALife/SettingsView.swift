import ALifeClient
import SwiftUI

/// Where the address of the a-life-server is set.
struct SettingsView: View {
    @Environment(ServerConnection.self) private var server
    @Environment(Voices.self) private var voices
    @Environment(\.dismiss) private var dismiss
    /// This device's registration for notifications, on the iPhone and iPad.
    @Environment(PushRegistration.self) private var registration: PushRegistration?
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
                    voicesFooter
                }

                #if os(iOS)
                if let registration {
                    NotificationsSection(registration: registration)
                }
                #endif
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

    private var voicesFooter: some View {
        Text("Each character says what it has to say out loud, in a voice of its own, while you stand within \(Int(Earshot.distance)) tiles of it. If you were further away, it calls you once its job is done, and you can take the call to hear what you missed. What happened while the app was closed, or finished before you came back, is never said or rung about: it is in the log, behind the list button at the top, under While you were away. A character that finished a job while you were away leaves you a missed call instead, without a sound: call it back to hear what it had to say, or open its conversation to read it. Nothing said yet, with the voices ready, means no character has had anything to say near you. The voice model comes from the server once, and speaks on this device. See Voices in a-life-server/README.md.")
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

#if os(iOS)
/// Whether this device hears when a character finishes its work: off until
/// you turn it on, which asks iOS the first time, and what came of it.
private struct NotificationsSection: View {
    let registration: PushRegistration
    @Environment(\.openURL) private var openURL
    @State private var testResult: String?

    var body: some View {
        Section {
            Toggle("Tell me when a character finishes", isOn: Binding(
                get: { registration.isWanted },
                set: { wanted in
                    testResult = nil
                    Task { await PushPermission.set(wanted, for: registration) }
                }
            ))
            if let status {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if registration.status == .notAllowed, let settings = URL(string: UIApplication.openSettingsURLString) {
                Button("Open iOS's settings for a*life") { openURL(settings) }
            }
            if registration.status == .registered {
                Button("Send a test") {
                    testResult = nil
                    Task {
                        testResult = await registration.sendTest() ?? "Sent. It should be here in a moment."
                    }
                }
            }
            if let testResult {
                Text(testResult)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text("When any character finishes its work, the server sends this device a notification saying what it worked on: the first line of what you asked, the files it changed, how many commands it ran and helpers it sent, and how long it took. Never its reply: tap the notification to read that here. It goes through Apple's push notification service, and the server has to be set up for it. See Push notifications in a-life-server/README.md.")
        }
    }

    private var status: String? {
        switch registration.status {
        case .off: return nil
        case .waitingForToken: return "Waiting for iOS to say this device can be reached."
        case .notAllowed: return "Notifications for a*life are off in iOS's settings."
        case .noServer: return "Connect to a server first."
        case .registering: return "Registering with the server…"
        case .registered: return "The server will tell this device when a character finishes."
        case .serverHasNoPush: return "This server isn't set up to send notifications. See Push notifications in a-life-server/README.md."
        case .failed(let reason): return "Couldn't register: \(reason)"
        }
    }
}
#endif
