import Foundation
import Observation

/// Something that can say a character's lines out loud. The app's speaks
/// with Phonon; the tests use one that only writes down what it was asked.
@MainActor
public protocol SpeechEngine: AnyObject {
    /// Says `text` in the `voice`th of the engine's voices (whichever it
    /// likes, as long as each number always gets the same one), and returns
    /// once it has been said, or stopped.
    func say(_ text: String, voice: Int) async
    /// Stops whatever is being said, at once.
    func stop()
}

/// How close you have to stand to a character to hear what it says.
public enum Earshot {
    /// Across the grass, in tiles, whatever the height.
    public static let distance: Float = 3

    /// Whether a character standing at `speaker` can be heard by you at
    /// `listener`. Each is a spot on the lot: x across, z down.
    public static func contains(listener: (x: Float, z: Float), speaker: (x: Float, z: Float)) -> Bool {
        let dx = speaker.x - listener.x
        let dz = speaker.z - listener.z
        return (dx * dx + dz * dz).squareRoot() <= distance
    }
}

/// Says the characters' lines out loud, in a voice each, while you stand
/// close enough to hear them, and rings you about the rest.
///
/// Only what a character says to you is spoken, not your own messages, its
/// tool calls or its errors. Lines are said one at a time, in the order they
/// came; walking away from a character cuts it off. What a character says
/// while you are out of earshot, or hadn't heard yet when you walked off, is
/// kept for it, and once its job is done it calls you with it: take the call
/// to hear the lot in its voice, wherever you are, decline it, or hang up.
/// Each call is written down in the log too, so declining or hanging up
/// loses nothing.
///
/// What happened while you were away is never said and never rings: an
/// `AgentSession`'s `newMessages` leave out what was replayed on connecting,
/// and what a character said while finishing a job it had before you came.
/// A character that finished a job while you were away leaves you a missed
/// call instead, without a sound: call it back to hear what it had to say.
/// Which replies you have heard, or let go, is kept between launches, so a
/// job you heard out isn't a missed call the next time.
@MainActor
@Observable
public final class Narrator {
    /// One character, as the narrator hears it.
    public struct Speaker: Equatable {
        public let id: String
        /// Its name, for the log. Its id if it has none.
        public let name: String
        /// What was said in its session lately, oldest first.
        public let messages: [Message]
        /// Whether it is still on the job. Once it isn't, whatever you
        /// missed of what it said turns into a call.
        public let isWorking: Bool
        /// What it said in the job it finished while you were away, oldest
        /// first, for a missed call. Empty if it didn't finish one.
        public let finishedWhileAway: [Message]

        public init(
            id: String,
            name: String? = nil,
            messages: [Message],
            isWorking: Bool = false,
            finishedWhileAway: [Message] = []
        ) {
            self.id = id
            self.name = name ?? id
            self.messages = messages
            self.isWorking = isWorking
            self.finishedWhileAway = finishedWhileAway
        }
    }

    /// A character calling you, because it finished a job while you were too
    /// far away to hear what it had to say, or a missed call, because it
    /// finished one while you were away.
    public struct Call: Equatable, Identifiable {
        /// The character calling, by session.
        public let speakerID: String
        /// What you missed, oldest first, as it will be said.
        public internal(set) var lines: [String]
        /// Whether it is a missed call, left while you were away, rather
        /// than one ringing now. It waits for you to call back.
        public internal(set) var isMissed = false
        let voice: Int
        /// The last of the character's messages in the call, to remember it
        /// as heard once you take it or let it go.
        var lastMessageID: String

        public var id: String { speakerID }
    }

    /// A line waiting to be said, or being said.
    struct Line: Equatable {
        let speakerID: String
        let voice: Int
        let text: String
        /// The message it comes from.
        let messageID: String
        /// Part of a call you took, so said wherever you stand.
        var isCall = false
    }

    @ObservationIgnored private let engine: any SpeechEngine
    /// Where each call is written down.
    @ObservationIgnored private weak var log: EventLog?
    /// Each speaker's name, for the log.
    @ObservationIgnored private var names: [String: String] = [:]
    /// The messages already heard (spoken, kept or let go), by speaker.
    @ObservationIgnored private var heard: [String: Set<String>] = [:]
    /// Who was still on the job when last heard from.
    @ObservationIgnored private var working: Set<String> = []
    /// Where the replies you have heard are kept between launches.
    @ObservationIgnored private let heardStore: any HeardRepliesStoring
    /// The last reply you heard from each speaker, or let go unheard.
    @ObservationIgnored private var lastHeard: [String: String]
    /// The last replies of jobs finished while you were away that have been
    /// a missed call already, so each is one only once.
    @ObservationIgnored private var offered: Set<String> = []
    /// The lines you missed from characters still on the job, by speaker.
    private(set) var missed: [String: [Line]] = [:]
    /// The characters calling you, in the order they rang, one call each.
    public private(set) var calls: [Call] = []
    private(set) var waiting: [Line] = []
    private(set) var speaking: Line?

    /// `heardStore` keeps which replies you have heard between launches.
    /// It is in memory unless you say otherwise; the app keeps them in
    /// `UserDefaults`.
    public init(engine: any SpeechEngine, log: EventLog? = nil, heardStore: any HeardRepliesStoring = InMemoryHeardRepliesStore()) {
        self.engine = engine
        self.log = log
        self.heardStore = heardStore
        lastHeard = heardStore.load()
    }

    /// Takes in what the characters have said lately. Each character's voice
    /// is its place in `speakers`. Its new lines are said if it is in
    /// `inEarshot`, and kept for a call if not.
    public func listen(to speakers: [Speaker], inEarshot: Set<String>) {
        for (voice, speaker) in speakers.enumerated() {
            names[speaker.id] = speaker.name
            var heard = heard[speaker.id] ?? []
            for message in speaker.messages where !heard.contains(message.id) {
                heard.insert(message.id)
                guard message.kind == .agent else { continue }
                let text = SpokenText.from(message.text)
                guard !text.isEmpty else { continue }
                let line = Line(speakerID: speaker.id, voice: voice, text: text, messageID: message.id)
                if inEarshot.contains(speaker.id) {
                    waiting.append(line)
                } else {
                    missed[speaker.id, default: []].append(line)
                }
            }
            // Only the ones still listed can come round again.
            self.heard[speaker.id] = heard.intersection(speaker.messages.map(\.id))
            leaveMissedCall(from: speaker, voice: voice)
        }
        working = Set(speakers.filter(\.isWorking).map(\.id))
        ring()
        sayNext()
    }

    /// You or the characters moved: lines from those now out of earshot are
    /// kept for a call, and one being said is cut off and kept too. A call
    /// you took carries on wherever you go.
    public func listenerMoved(inEarshot: Set<String>) {
        let outOfEarshot = waiting.filter { !$0.isCall && !inEarshot.contains($0.speakerID) }
        guard !outOfEarshot.isEmpty || speaking.map({ !$0.isCall && !inEarshot.contains($0.speakerID) }) == true else { return }
        waiting.removeAll { !$0.isCall && !inEarshot.contains($0.speakerID) }
        var kept = outOfEarshot
        if let speaking, !speaking.isCall, !inEarshot.contains(speaking.speakerID) {
            kept.insert(speaking, at: 0)
            engine.stop()
        }
        for line in kept {
            missed[line.speakerID, default: []].append(line)
        }
        ring()
    }

    /// Answers `speakerID`'s call: what you missed is said next, in its
    /// voice, wherever you stand.
    public func take(callFrom speakerID: String) {
        guard let index = calls.firstIndex(where: { $0.speakerID == speakerID }) else { return }
        let call = calls.remove(at: index)
        markHeard(call.lastMessageID, from: speakerID)
        let lines = call.lines.map { Line(speakerID: speakerID, voice: call.voice, text: $0, messageID: call.lastMessageID, isCall: true) }
        // Ahead of anything else waiting, after any other call you took.
        let place = waiting.lastIndex(where: \.isCall).map { $0 + 1 } ?? 0
        waiting.insert(contentsOf: lines, at: place)
        sayNext()
    }

    /// Hangs up on `speakerID` without hearing it out: its call, and
    /// anything kept for one, are let go, and a call you took stops.
    public func hangUp(on speakerID: String) {
        if let call = calls.first(where: { $0.speakerID == speakerID }) {
            markHeard(call.lastMessageID, from: speakerID)
        }
        if let line = missed[speakerID]?.last {
            markHeard(line.messageID, from: speakerID)
        }
        calls.removeAll { $0.speakerID == speakerID }
        missed[speakerID] = nil
        waiting.removeAll { $0.isCall && $0.speakerID == speakerID }
        if let speaking, speaking.isCall, speaking.speakerID == speakerID {
            engine.stop()
        }
    }

    /// Declines `speakerID`'s call, ringing or missed, without hearing it or
    /// opening its conversation: what it said in that call counts as dealt
    /// with, so it isn't a missed call later, nor on the next launch. Unlike
    /// hanging up, what you miss of a job it has started since is kept, and
    /// calls you once that job is done.
    public func decline(callFrom speakerID: String) {
        guard let index = calls.firstIndex(where: { $0.speakerID == speakerID }) else { return }
        let call = calls.remove(at: index)
        markHeard(call.lastMessageID, from: speakerID)
    }

    /// Whether `speakerID` still has something for you: a call, lines kept
    /// for one, or lines waiting to be said or being said. Until it hasn't,
    /// it stays at its desk.
    public func hasSomethingToSay(_ speakerID: String) -> Bool {
        calls.contains { $0.speakerID == speakerID }
            || missed[speakerID]?.isEmpty == false
            || waiting.contains { $0.speakerID == speakerID }
            || speaking?.speakerID == speakerID
    }

    /// Clears `speakerID`'s missed call without calling back, as when you
    /// open its conversation to read what it said. A call ringing now stays.
    public func clearMissedCall(from speakerID: String) {
        guard let index = calls.firstIndex(where: { $0.speakerID == speakerID && $0.isMissed }) else { return }
        let call = calls.remove(at: index)
        markHeard(call.lastMessageID, from: speakerID)
    }

    /// Whether `speakerID` is calling you now. A missed call doesn't ring.
    public func isCalling(_ speakerID: String) -> Bool {
        calls.contains { $0.speakerID == speakerID && !$0.isMissed }
    }

    /// Whether `speakerID` left you a missed call.
    public func hasMissedCall(_ speakerID: String) -> Bool {
        calls.contains { $0.speakerID == speakerID && $0.isMissed }
    }

    /// The calls ringing now, in the order they rang.
    public var incomingCalls: [Call] {
        calls.filter { !$0.isMissed }
    }

    /// The missed calls, in the order they were left.
    public var missedCalls: [Call] {
        calls.filter(\.isMissed)
    }

    /// Stops talking and forgets what was waiting to be said.
    public func hush() {
        waiting = []
        if speaking != nil { engine.stop() }
    }

    /// Each character done with its job, with lines you missed, calls you,
    /// or adds them to the call it has already made, and writes it down in
    /// the log.
    private func ring() {
        let done = missed.filter { !working.contains($0.key) && !$0.value.isEmpty }
        // In the characters' order, when several finish at once.
        for (speakerID, lines) in done.sorted(by: { $0.value[0].voice < $1.value[0].voice }) {
            missed[speakerID] = nil
            log?.record(.call, "Called you: " + lines.map(\.text).joined(separator: " "), sessionID: speakerID, name: names[speakerID] ?? speakerID)
            if let index = calls.firstIndex(where: { $0.speakerID == speakerID }) {
                calls[index].lines += lines.map(\.text)
                calls[index].lastMessageID = lines[lines.count - 1].messageID
                // Something new on top of a missed call rings.
                calls[index].isMissed = false
            } else {
                calls.append(Call(speakerID: speakerID, lines: lines.map(\.text), voice: lines[0].voice, lastMessageID: lines[lines.count - 1].messageID))
            }
        }
    }

    /// Leaves a missed call from `speaker` if it finished a job while you
    /// were away and has something to say about it you haven't heard. It
    /// doesn't ring: it waits for you to call back. Written down in the log
    /// as while you were away.
    private func leaveMissedCall(from speaker: Speaker, voice: Int) {
        let lines = speaker.finishedWhileAway.compactMap { message -> Line? in
            guard message.kind == .agent else { return nil }
            let text = SpokenText.from(message.text)
            return text.isEmpty ? nil : Line(speakerID: speaker.id, voice: voice, text: text, messageID: message.id)
        }
        guard let last = lines.last,
              !offered.contains(last.messageID),
              lastHeard[speaker.id] != last.messageID,
              !calls.contains(where: { $0.speakerID == speaker.id })
        else { return }
        offered.insert(last.messageID)
        calls.append(Call(speakerID: speaker.id, lines: lines.map(\.text), isMissed: true, voice: voice, lastMessageID: last.messageID))
        log?.record(
            .missedCall, "Missed call: " + lines.map(\.text).joined(separator: " "),
            sessionID: speaker.id, name: speaker.name, isWhileAway: true
        )
    }

    /// Remembers `messageID` as the last you heard from `speakerID`, now
    /// and on later launches.
    private func markHeard(_ messageID: String, from speakerID: String) {
        guard lastHeard[speakerID] != messageID else { return }
        lastHeard[speakerID] = messageID
        heardStore.save(lastHeard)
    }

    private func sayNext() {
        guard speaking == nil, !waiting.isEmpty else { return }
        let line = waiting.removeFirst()
        speaking = line
        markHeard(line.messageID, from: line.speakerID)
        let engine = engine
        Task { [weak self] in
            await engine.say(line.text, voice: line.voice)
            self?.speaking = nil
            self?.sayNext()
        }
    }
}

/// Where the last reply you heard from each character is kept between
/// launches, by session, so a job you heard out isn't a missed call later.
public protocol HeardRepliesStoring: Sendable {
    func load() -> [String: String]
    func save(_ lastHeard: [String: String])
}

public struct UserDefaultsHeardRepliesStore: HeardRepliesStoring {
    private let key: String

    public init(key: String = "ALife.lastHeardReply") {
        self.key = key
    }

    public func load() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    public func save(_ lastHeard: [String: String]) {
        UserDefaults.standard.set(lastHeard, forKey: key)
    }
}

/// Keeps the replies heard in memory only. For tests and previews.
public final class InMemoryHeardRepliesStore: HeardRepliesStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var lastHeard: [String: String]

    public init(_ lastHeard: [String: String] = [:]) { self.lastHeard = lastHeard }

    public func load() -> [String: String] { lock.withLock { lastHeard } }
    public func save(_ lastHeard: [String: String]) { lock.withLock { self.lastHeard = lastHeard } }
}

/// A character's message as it should sound: its Markdown read as plain
/// prose, without code blocks, links' addresses or bare web addresses.
/// Nothing is left of a message that is all code.
public enum SpokenText {
    public static func from(_ markdown: String) -> String {
        var lines: [String] = []
        var isInCode = false
        for line in markdown.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                isInCode.toggle()
                continue
            }
            guard !isInCode else { continue }
            // Table rules, such as |---|---|, say nothing.
            if !trimmed.isEmpty, trimmed.allSatisfy({ "|-: ".contains($0) }) { continue }
            lines.append(stripMarks(from: trimmed))
        }

        // Each line ends a sentence, unless it ends one already.
        var spoken = ""
        for line in lines where !line.isEmpty {
            if !spoken.isEmpty {
                spoken += ".!?:;,".contains(spoken.last!) ? " " : ". "
            }
            spoken += line
        }
        return spoken
    }

    /// One line without its Markdown: headings, quotes, list bullets,
    /// emphasis, code spans, links and web addresses.
    private static func stripMarks(from line: String) -> String {
        var text = line
        // Headings, quotes and bullets at the start of the line.
        text = text.replacingOccurrences(of: #"^(#{1,6}\s+|>\s*|[-*+]\s+|\d+[.)]\s+)"#, with: "", options: .regularExpression)
        // [words](address) says the words.
        text = text.replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"https?://\S*[^\s.,;:!?)]"#, with: "", options: .regularExpression)
        for mark in ["**", "__", "`"] {
            text = text.replacingOccurrences(of: mark, with: "")
        }
        text = text.replacingOccurrences(of: #"\*([^*\s][^*]*)\*"#, with: "$1", options: .regularExpression)
        // Any other star, as in a*life, is a pause rather than "asterisk".
        text = text.replacingOccurrences(of: "*", with: " ")
        // Table cells.
        text = text.replacingOccurrences(of: #"\s*\|\s*"#, with: ", ", options: .regularExpression)
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: ", ").union(.whitespaces))
        text = text.replacingOccurrences(of: #"\s+([,.;:!?])"#, with: "$1", options: .regularExpression)
        return text.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
    }
}
