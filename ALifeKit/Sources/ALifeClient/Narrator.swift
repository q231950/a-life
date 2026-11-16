import Foundation

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
/// close enough to hear them, and keeps quiet otherwise.
///
/// Only what a character says to you is spoken, not your own messages, its
/// tool calls or its errors. A line said out of earshot is let go rather
/// than saved for later. Lines are said one at a time, in the order they
/// came; walking away from a character cuts it off.
@MainActor
public final class Narrator {
    /// One character, as the narrator hears it.
    public struct Speaker: Equatable {
        public let id: String
        /// What was said in its session lately, oldest first.
        public let messages: [Message]

        public init(id: String, messages: [Message]) {
            self.id = id
            self.messages = messages
        }
    }

    /// A line waiting to be said, or being said.
    struct Line: Equatable {
        let speakerID: String
        let voice: Int
        let text: String
    }

    private let engine: any SpeechEngine
    /// The messages already heard (spoken or let go), by speaker.
    private var heard: [String: Set<String>] = [:]
    private(set) var waiting: [Line] = []
    private(set) var speaking: Line?

    public init(engine: any SpeechEngine) {
        self.engine = engine
    }

    /// Takes in what the characters have said lately. Each character's voice
    /// is its place in `speakers`. Its new lines are said if it is in
    /// `inEarshot`, and let go if not.
    public func listen(to speakers: [Speaker], inEarshot: Set<String>) {
        for (voice, speaker) in speakers.enumerated() {
            var heard = heard[speaker.id] ?? []
            for message in speaker.messages where !heard.contains(message.id) {
                heard.insert(message.id)
                guard message.kind == .agent, inEarshot.contains(speaker.id) else { continue }
                let text = SpokenText.from(message.text)
                guard !text.isEmpty else { continue }
                waiting.append(Line(speakerID: speaker.id, voice: voice, text: text))
            }
            // Only the ones still listed can come round again.
            self.heard[speaker.id] = heard.intersection(speaker.messages.map(\.id))
        }
        sayNext()
    }

    /// You or the characters moved: lines from those now out of earshot are
    /// dropped, and one being said is cut off.
    public func listenerMoved(inEarshot: Set<String>) {
        waiting.removeAll { !inEarshot.contains($0.speakerID) }
        if let speaking, !inEarshot.contains(speaking.speakerID) {
            engine.stop()
        }
    }

    /// Stops talking and forgets what was waiting to be said.
    public func hush() {
        waiting = []
        if speaking != nil { engine.stop() }
    }

    private func sayNext() {
        guard speaking == nil, !waiting.isEmpty else { return }
        let line = waiting.removeFirst()
        speaking = line
        let engine = engine
        Task { [weak self] in
            await engine.say(line.text, voice: line.voice)
            self?.speaking = nil
            self?.sayNext()
        }
    }
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
