import ALifeClient
import SwiftUI

/// The log of what the characters have been up to, newest first. What they
/// did while you were away, and you haven't seen yet, is at the top, picked
/// out; everything else follows. Tap an entry to talk to that character.
/// Opening the log marks everything in it as seen.
struct EventLogView: View {
    @Environment(ServerConnection.self) private var server
    @Environment(\.shirts) private var shirts
    @Environment(\.dismiss) private var dismiss
    /// Talks to the character with this id.
    let select: (String) -> Void
    /// What you hadn't seen when you opened the log, which stays picked out
    /// until you close it.
    @State private var unseenWhenOpened: Set<Int> = []

    var body: some View {
        NavigationStack {
            Group {
                if server.log.entries.isEmpty {
                    ContentUnavailableView(
                        "Nothing yet",
                        systemImage: "list.bullet.rectangle",
                        description: Text("What the characters do shows up here: their replies, the helpers they send off, the jobs they finish and their calls to you.")
                    )
                } else {
                    List {
                        if !whileAway.isEmpty {
                            Section {
                                ForEach(whileAway) { entry in
                                    row(entry)
                                        .listRowBackground(Color.accentColor.opacity(0.15))
                                }
                            } header: {
                                Label("While you were away", systemImage: "moon.zzz.fill")
                            } footer: {
                                Text("Caught up on when the app connected, or finished before you were back. None of it was said out loud or rung about.")
                            }
                        }
                        if !everythingElse.isEmpty {
                            Section(whileAway.isEmpty ? "Everything" : "Everything else") {
                                ForEach(everythingElse) { entry in
                                    row(entry)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Log")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear {
            unseenWhenOpened = Set(server.log.unseen.map(\.id))
            server.log.markSeen()
        }
        .onDisappear {
            server.log.markSeen() // and whatever came in while it was open
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 480)
        #endif
    }

    private var newestFirst: [EventLog.Entry] {
        server.log.entries.reversed()
    }

    /// What happened while you were away that you hadn't seen.
    private var whileAway: [EventLog.Entry] {
        newestFirst.filter { $0.isWhileAway && unseenWhenOpened.contains($0.id) }
    }

    private var everythingElse: [EventLog.Entry] {
        newestFirst.filter { !($0.isWhileAway && unseenWhenOpened.contains($0.id)) }
    }

    private func row(_ entry: EventLog.Entry) -> some View {
        Button {
            select(entry.sessionID)
            dismiss()
        } label: {
            EventLogRow(entry: entry, shirt: shirt(of: entry.sessionID), isNew: unseenWhenOpened.contains(entry.id))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Talks to \(entry.name)")
    }

    /// The character's shirt on the lot, or the accent colour if it isn't
    /// there any more.
    private func shirt(of sessionID: String) -> Color {
        guard let shirt = shirts[sessionID] else { return .accentColor }
        #if os(macOS)
        return Color(nsColor: shirt)
        #else
        return Color(uiColor: shirt)
        #endif
    }
}

/// One thing a character did: a symbol for what it was, in the colour of its
/// shirt, who did it, when, and what happened.
private struct EventLogRow: View {
    let entry: EventLog.Entry
    let shirt: Color
    /// Whether you hadn't seen it before opening the log.
    let isNew: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: entry.kind.systemImage)
                .foregroundStyle(shirt)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.name)
                        .font(.footnote.bold())
                    if isNew {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 6, height: 6)
                            .accessibilityLabel("New")
                    }
                    Spacer(minLength: 8)
                    Text(Self.when(entry.time))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(entry.text)
                    .font(.footnote)
                    .foregroundStyle(entry.kind == .error ? Color.red : Color.primary)
                    .lineLimit(3)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// The time, with the day too if it wasn't today.
    private static func when(_ time: Date) -> String {
        Calendar.current.isDateInToday(time)
            ? time.formatted(date: .omitted, time: .shortened)
            : time.formatted(date: .abbreviated, time: .shortened)
    }
}

extension EventLog.Entry.Kind {
    var systemImage: String {
        switch self {
        case .reply: return "text.bubble.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .helperSent: return "arrow.up.right.circle.fill"
        case .helperBack: return "arrow.down.left.circle.fill"
        case .jobDone: return "checkmark.circle.fill"
        case .stopped: return "stop.circle.fill"
        case .usageLimit: return "hourglass"
        case .continued: return "arrow.clockwise.circle.fill"
        case .waitingForYou: return "exclamationmark.circle.fill"
        case .call: return "phone.fill"
        case .missedCall: return "phone.arrow.down.left.fill"
        }
    }
}
