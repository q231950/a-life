import ALifeAPI
import Foundation

/// What a notification says a character has been working on: a line put
/// together from the job's record, such as
///
/// > Worked on “Add a plan for push notifications” for 12 min: changed
/// > push-notifications.md and README.md, ran 4 commands, sent 2 helpers.
///
/// It is made from what the job did, never from what the character
/// replied, and calls no model, so it is there the moment the job ends.
/// The task is the first line of what you asked, cut short; the files are
/// named, the commands and helpers only counted, since a command can carry
/// anything.
enum JobSummary {
    /// The longest a body may be, so it shows in full on a lock screen.
    static let maxLength = 178
    /// About where the task is cut, at a word.
    static let taskLength = 60
    /// How many files are named before the rest are only counted.
    static let filesNamed = 3

    /// The notification's body for a job that ended as `kind`, with
    /// `record`, after `duration`, by the character called `name`. If
    /// there's nothing to say, `fallback`.
    static func body(of record: JobRecord, duration: TimeInterval?, kind: PushRoute.Kind, name: String) -> String {
        let task = record.task.flatMap(firstLine)
        let didSomething = !record.filesChanged.isEmpty || record.commands > 0 || record.helpers > 0
        guard task != nil || didSomething else { return fallback(kind: kind, name: name) }

        // Shortened, if it must be, the list of files first, then the task.
        var taskLength = Self.taskLength
        var namesFiles = true
        while true {
            let line = compose(
                task: task.map { cut($0, near: taskLength) }, record: record, duration: duration,
                stopped: kind == .error, namesFiles: namesFiles
            )
            if line.count <= maxLength { return line }
            if namesFiles {
                namesFiles = false
            } else if task != nil, taskLength > 12 {
                taskLength -= 8
            } else {
                return String(line.prefix(maxLength - 1)) + "…"
            }
        }
    }

    /// What a notification says when there's nothing more to say, as for a
    /// job that only answered a question.
    static func fallback(kind: PushRoute.Kind, name: String) -> String {
        kind == .error ? "\(name) stopped." : "\(name) finished their work."
    }

    /// The notification's subtitle.
    static func subtitle(for kind: PushRoute.Kind) -> String {
        kind == .error ? "Stopped" : "Finished"
    }

    // MARK: The line

    private static func compose(task: String?, record: JobRecord, duration: TimeInterval?, stopped: Bool, namesFiles: Bool) -> String {
        var head: String
        if stopped {
            head = "Stopped"
            if let duration { head += duration < 60 ? " within a minute" : " after \(length(of: duration))" }
            if let task { head += ", working on “\(task)”" }
        } else {
            head = "Worked"
            if let task { head += " on “\(task)”" }
            if let duration { head += " for \(duration < 60 ? "under a minute" : length(of: duration))" }
        }
        let done = work(of: record, namesFiles: namesFiles)
        guard !done.isEmpty else { return head + "." }
        // Nothing but the work to say: it says so itself.
        if head == "Worked" { return String(done.prefix(1)).uppercased() + String(done.dropFirst()) + "." }
        return head + ": " + done + "."
    }

    /// What the job did, such as "changed README.md, ran 4 commands, sent 2
    /// helpers", or empty.
    private static func work(of record: JobRecord, namesFiles: Bool) -> String {
        var parts: [String] = []
        let files = record.filesChanged
        if !files.isEmpty {
            if namesFiles {
                let names = files.map { ($0 as NSString).lastPathComponent }
                let named = Array(names.prefix(filesNamed))
                let rest = names.count - named.count
                parts.append("changed " + (rest > 0 ? named.joined(separator: ", ") + " and \(rest) more" : list(named)))
            } else {
                parts.append("changed \(count(files.count, "file"))")
            }
        }
        if record.commands > 0 { parts.append("ran \(count(record.commands, "command"))") }
        if record.helpers > 0 { parts.append("sent \(count(record.helpers, "helper"))") }
        return parts.joined(separator: ", ")
    }

    /// "a", "a and b", "a, b and c".
    private static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
    }

    /// "1 file", "4 files".
    private static func count(_ number: Int, _ noun: String) -> String {
        "\(number) \(noun)\(number == 1 ? "" : "s")"
    }

    /// How long a job took, a minute or more: "12 min", "1 h", "1 h 20 min".
    static func length(of duration: TimeInterval) -> String {
        let minutes = max(1, Int(duration / 60))
        guard minutes >= 60 else { return "\(minutes) min" }
        let (hours, rest) = minutes.quotientAndRemainder(dividingBy: 60)
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    // MARK: The task

    /// The first line of `text` with anything in it, as plain text: its
    /// Markdown taken out and its whitespace folded. `nil` if there's none.
    static func firstLine(_ text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let plain = plainText(String(line))
            if !plain.isEmpty { return plain }
        }
        return nil
    }

    /// `line` without its Markdown: headings, quotes and list markers at
    /// its start, emphasis and code marks, and links, which keep their text.
    private static func plainText(_ line: String) -> String {
        var text = line.replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"^\s*(#{1,6}\s+|>\s*|[-*+]\s+|\d+[.)]\s+)"#, with: "", options: .regularExpression)
        text.removeAll { "*`~".contains($0) }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// `text` cut at a word near `length` characters, with "…", if it is
    /// longer.
    static func cut(_ text: String, near length: Int) -> String {
        guard text.count > length else { return text }
        var kept = Substring(text.prefix(length))
        if let space = kept.lastIndex(of: " "), kept.distance(from: kept.startIndex, to: space) >= length / 2 {
            kept = kept[..<space]
        }
        while let last = kept.last, last.isWhitespace || ",;:.-–—".contains(last) {
            kept = kept.dropLast()
        }
        return String(kept) + "…"
    }
}
