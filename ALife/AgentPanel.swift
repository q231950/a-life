import ALifeClient
import SwiftUI

/// How the server connection is doing, who is busy or waiting for you, the
/// button that opens the log, with a badge counting what you haven't seen,
/// and the one that opens the settings.
struct SessionStatusBar: View {
    @Environment(ServerConnection.self) private var server
    @Binding var showsSettings: Bool
    @Binding var showsLog: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.footnote)
                .lineLimit(2)
            Button("Log", systemImage: "list.bullet.rectangle") {
                showsLog = true
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .overlay(alignment: .topTrailing) {
                if unseen > 0 {
                    Text(unseen > 99 ? "99+" : "\(unseen)")
                        .font(.caption2.bold().monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(Color.red, in: Capsule())
                        .offset(x: 10, y: -8)
                        .allowsHitTesting(false)
                }
            }
            .accessibilityValue(unseen == 0 ? "Nothing new" : "\(unseen) new")
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

    /// How many of the log's entries you haven't seen.
    private var unseen: Int { server.log.unseen.count }
    private var waiting: [String] { server.sessions.filter { $0.isWaitingForYou }.map { $0.name } }
    private var working: [String] { server.sessions.filter { $0.status == .running }.map { $0.name } }
    /// Who is waiting for the usage limit to reset, and when the first is back.
    private var resting: [AgentSession] {
        server.sessions.filter { $0.resumesAt != nil }.sorted { $0.resumesAt! < $1.resumesAt! }
    }

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
        if let first = resting.first, let back = first.resumesAt {
            let names = ListFormatter.localizedString(byJoining: resting.map(\.name))
            return "\(names) \(resting.count == 1 ? "is" : "are") waiting for the usage limit, back at \(back.formatted(date: .omitted, time: .shortened))"
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
                IncomingCallBar(take: take(callFrom:))
                HStack(spacing: 6) {
                    if server.sessions.count > 1 {
                        CharacterPicker(selectedID: session.id) { id in
                            // Switch at once. On iOS a button's tap can carry
                            // an animation, which would swap the conversation
                            // with its slide and send the buttons flying as
                            // the panel changes height.
                            var transaction = Transaction(animation: nil)
                            transaction.disablesAnimations = true
                            withTransaction(transaction) {
                                selectedID = id
                                isExpanded = true
                            }
                        }
                    } else if !isExpanded {
                        CharacterStatus(session: session)
                    }
                    AutoApproveToggle(session: session)
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

    /// Answers a character's call, or calls it back: shows its conversation
    /// and plays what you missed in its voice.
    private func take(callFrom id: String) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            selectedID = id
            isExpanded = true
        }
        narrator?.take(callFrom: id)
    }

    @Environment(\.narrator) private var narrator
}

/// Auto approve for the character you're talking to: while it's on, its
/// tool calls go ahead without asking you, and show in the conversation as
/// auto approved. Each character has its own, kept on the server.
private struct AutoApproveToggle: View {
    @Environment(ServerConnection.self) private var server
    let session: AgentSession

    var body: some View {
        Toggle("Auto approve", systemImage: session.autoApprove ? "checkmark.shield.fill" : "checkmark.shield",
               isOn: Binding(
                   get: { session.autoApprove },
                   set: { enabled in Task { await session.setAutoApprove(enabled) } }
               ))
            .toggleStyle(.button)
            .buttonStyle(.bordered)
            .tint(session.autoApprove ? .mint : .gray)
            .font(.footnote)
            .lineLimit(1)
            .fixedSize()
            .disabled(server.phase != .live)
            .accessibilityHint("Lets \(session.name) use its tools without asking you")
    }
}

/// The first character calling you, with a button to take the call, and how
/// many more are holding after it. Once none is ringing, the first missed
/// call, from a character that finished a job while you were away, with a
/// button to call it back.
private struct IncomingCallBar: View {
    @Environment(ServerConnection.self) private var server
    @Environment(\.narrator) private var narrator
    let take: (String) -> Void

    var body: some View {
        if let calls = narrator?.incomingCalls, let first = calls.first {
            let name = server.sessions.first { $0.id == first.speakerID }?.name ?? first.speakerID
            HStack(spacing: 8) {
                Image(systemName: "phone.arrow.down.left.fill")
                    .foregroundStyle(.green)
                    .symbolEffect(.wiggle, options: .repeat(.periodic(delay: 0.6)))
                VStack(alignment: .leading, spacing: 0) {
                    Text("Incoming call from \(name)")
                        .font(.footnote.bold())
                    if calls.count > 1 {
                        Text("\(calls.count - 1) more holding")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Button("Take", systemImage: "phone.fill") {
                    take(first.speakerID)
                }
                .font(.footnote)
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .accessibilityHint("Plays what \(name) said while you were away")
            }
            .padding(8)
            .background(Color.green.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .combine)
        } else if let calls = narrator?.missedCalls, let first = calls.first {
            let name = server.sessions.first { $0.id == first.speakerID }?.name ?? first.speakerID
            HStack(spacing: 8) {
                Image(systemName: "phone.arrow.down.left.fill")
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Missed call from \(name)")
                        .font(.footnote.bold())
                    if calls.count > 1 {
                        Text("\(calls.count - 1) more missed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Button("Call back", systemImage: "phone.arrow.up.right.fill") {
                    take(first.speakerID)
                }
                .font(.footnote)
                .buttonStyle(.bordered)
                .tint(.green)
                .accessibilityHint("Plays what \(name) had to say about the job it finished while you were away")
            }
            .padding(8)
            .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .combine)
        }
    }
}

/// Who you can talk to: a button per character where there's room for them
/// all, and otherwise one button that opens a menu of them, so a long cast
/// still fits on a phone.
private struct CharacterPicker: View {
    let selectedID: String
    let select: (String) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            CharacterButtons(selectedID: selectedID, select: select)
            CompactCharacterPicker(selectedID: selectedID, select: select)
        }
    }
}

/// One button per character, showing whether it is working or waiting for
/// you, and whether it left you a missed call.
private struct CharacterButtons: View {
    @Environment(ServerConnection.self) private var server
    @Environment(\.narrator) private var narrator
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
                        if narrator?.hasMissedCall(session.id) == true {
                            Image(systemName: "phone.arrow.down.left.fill")
                                .foregroundStyle(.red)
                                .accessibilityLabel("Missed call")
                        }
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

/// The character you're talking to, in one button that opens a menu of
/// everyone and what they're up to. Anyone else waiting for you is counted
/// in an orange badge beside it, so they aren't tucked away in the menu.
private struct CompactCharacterPicker: View {
    @Environment(ServerConnection.self) private var server
    @Environment(\.shirts) private var shirts
    let selectedID: String
    let select: (String) -> Void

    /// Everyone but the one you're talking to who is waiting for you.
    private var othersWaiting: [AgentSession] {
        server.sessions.filter { $0.isWaitingForYou && $0.id != selectedID }
    }

    var body: some View {
        HStack(spacing: 6) {
            if let selected = server.session(selectedBy: selectedID) {
                Menu {
                    Picker("Talk to", selection: Binding(get: { selectedID }, set: { select($0) })) {
                        ForEach(Array(server.sessions.enumerated()), id: \.element.id) { slot, session in
                            CharacterMenuItem(
                                session: session,
                                shirt: shirts[session.id] ?? .shirt(hex: session.color, slot: slot)
                            )
                            .tag(session.id)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(selected.statusColor)
                            .frame(width: 8, height: 8)
                        Text(selected.name)
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .imageScale(.small)
                    }
                    .font(.footnote)
                }
                .menuStyle(.button)
                .buttonStyle(.bordered)
                .tint(.accentColor)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Talking to \(selected.name)")
                .accessibilityValue(selected.statusText)
                .accessibilityHint("Shows everyone you can talk to")
            }
            if let first = othersWaiting.first {
                Button("\(othersWaiting.count) waiting") {
                    select(first.id)
                }
                .font(.caption.bold())
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .fixedSize()
                .accessibilityLabel("\(ListFormatter.localizedString(byJoining: othersWaiting.map(\.name))) \(othersWaiting.count == 1 ? "is" : "are") waiting for you")
                .accessibilityHint("Talks to \(first.name)")
            }
        }
    }
}

/// A character in the menu of everyone: its name, what it is up to, and a
/// symbol for its status in the colour of its shirt, so you can tell who is
/// who as you can on the lot.
private struct CharacterMenuItem: View {
    let session: AgentSession
    /// The character's shirt on the lot.
    let shirt: PlatformColor

    var body: some View {
        Label {
            #if os(macOS)
            // A Mac menu item shows a single line.
            Text("\(session.name) · \(session.statusText)")
            #else
            Text(session.name)
            Text(session.statusText)
            #endif
        } icon: {
            Image(symbol: session.statusSymbol, in: shirt)
        }
        .accessibilityLabel(session.name)
        .accessibilityValue(session.statusText)
    }
}

extension EnvironmentValues {
    /// Each character's shirt on the lot, by session, for the panel to show
    /// them in. A character missing from it hasn't reached the lot yet.
    @Entry var shirts: [String: PlatformColor] = [:]
    /// Says the characters' lines out loud, and keeps their calls.
    @Entry var narrator: Narrator? = nil
}

extension Image {
    /// An SF Symbol drawn in `color` and kept that way. A menu draws the
    /// images in its items as templates, in its own colour, and ignores
    /// `foregroundStyle`, so the colour has to be in the image itself.
    init(symbol name: String, in color: PlatformColor) {
        #if os(macOS)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
            self.init(systemName: name)
            return
        }
        let image = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
        self.init(nsImage: image)
        #else
        guard let symbol = UIImage(systemName: name) else {
            self.init(systemName: name)
            return
        }
        self.init(uiImage: symbol.withTintColor(color, renderingMode: .alwaysOriginal))
        #endif
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
    @Environment(\.narrator) private var narrator
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
                // Works while it waits for you, or for the usage limit, too.
                if !server.models.isEmpty {
                    ModelPicker(session: session, options: server.models)
                }
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
        // Something new to do: whatever it rang about can wait.
        narrator?.hangUp(on: session.id)
        Task { await session.send(text) }
    }
}

/// The model the character runs on, to change it, by the text field you
/// talk to it in: Claude Code's simple names, strongest first, each with the
/// version it stands for and what it's good for, and the agents file's to
/// go back to. A change applies at once if the character is working, or
/// else when it next starts, and every front end sees it.
private struct ModelPicker: View {
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    let session: AgentSession
    let options: [ModelOption]

    var body: some View {
        Menu {
            ForEach(options) { option in
                Button {
                    Task { await session.setModel(option.model) }
                } label: {
                    if session.model == option.model {
                        Label(option.displayName, systemImage: "checkmark")
                    } else {
                        Text(option.displayName)
                    }
                    if let description = option.description {
                        Text(description)
                    }
                }
            }
            if session.model != session.fileModel {
                Divider()
                Button("As in the agents file (\(name(of: session.fileModel)))") {
                    Task { await session.setModel(nil) }
                }
            }
        } label: {
            Label(label, systemImage: "cpu")
                .font(.footnote)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Model: \(name(of: session.model))")
    }

    /// The model's name and version, or just its family on a narrow screen.
    private var label: String {
        guard let model = session.model else { return "Default" }
        return isNarrow ? model.name : name(of: model)
    }

    private func name(of model: ClaudeModel?) -> String {
        guard let model else { return "Claude Code's default" }
        return options.first { $0.model == model }?.displayName ?? model.name
    }

    /// Whether there is little room across, as on an iPhone held upright.
    private var isNarrow: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
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
        VStack(alignment: .leading, spacing: 8) {
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
                }
            }
            if outcome == nil {
                // Under the request, so a long one doesn't squeeze them: Allow first, then Deny.
                HStack {
                    Button("Allow") {
                        Task { await session.respond(to: approval, allow: true) }
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Deny") {
                        Task { await session.respond(to: approval, allow: false) }
                    }
                }
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
        case .autoApproved: return "Auto approved"
        case .withdrawn: return "No longer needed"
        case .unknown: return "Answered"
        }
    }

    var systemImage: String {
        switch self {
        case .allowed: return "checkmark.circle.fill"
        case .denied: return "xmark.circle.fill"
        case .autoApproved: return "checkmark.shield.fill"
        case .withdrawn: return "minus.circle"
        case .unknown: return "circle"
        }
    }

    var color: Color {
        switch self {
        case .allowed: return .green
        case .denied: return .red
        case .autoApproved: return .mint
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
    /// Working, or waiting for you in the middle of its work.
    var isOnTheJob: Bool { status == .running || isWaitingForYou }

    var statusText: String {
        if isWaitingForYou { return "Waiting for you" }
        switch status {
        case .running: return activity.map { "Working: \($0)" } ?? "Working"
        case .terminated: return "Session ended"
        default:
            if let resumesAt { return "Back at \(resumesAt.formatted(date: .omitted, time: .shortened))" }
            return stopReason == .interrupted ? "Stopped" : "Idle"
        }
    }

    var statusColor: Color {
        if isWaitingForYou { return .orange }
        return status == .running ? .green : .secondary
    }

    /// A symbol for the status, for menus, where the symbol is drawn in the
    /// character's shirt colour rather than the status's.
    var statusSymbol: String {
        if isWaitingForYou { return "exclamationmark.circle.fill" }
        if resumesAt != nil { return "hourglass.circle" }
        return status == .running ? "circle.fill" : "circle"
    }
}
