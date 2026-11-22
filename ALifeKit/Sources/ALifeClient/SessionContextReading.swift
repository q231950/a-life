import ALifeAPI
import Foundation

/// What a front end reads off how full a character's session is: what the
/// ring measures against, how far along it is, and the words to show.
extension SessionContext {
    /// What the context is measured against.
    public enum Measure: Equatable, Sendable {
        /// The tokens at which Claude Code compacts it by itself.
        case compaction(at: Int)
        /// The whole window, when it isn't compacted by itself, or Claude
        /// Code hasn't said when it would be.
        case window(of: Int)

        /// The tokens it stands for.
        public var tokens: Int {
            switch self {
            case .compaction(let tokens), .window(let tokens): return tokens
            }
        }
    }

    /// What the ring measures against: the compaction point if there is one,
    /// otherwise the window if it is known, otherwise nothing.
    public var measure: Measure? {
        if autoCompact != false, let compactsAt, compactsAt > 0 {
            return .compaction(at: compactsAt)
        }
        if let contextWindow, contextWindow > 0 {
            return .window(of: contextWindow)
        }
        return nil
    }

    /// How far along the measure the context is, from 0 to 1. It can run a
    /// little past the compaction point before Claude Code compacts, so it
    /// is held at 1. `nil` if either isn't known.
    public var share: Double? {
        guard let usedTokens, let measure else { return nil }
        return min(max(Double(usedTokens) / Double(measure.tokens), 0), 1)
    }

    /// The share as a whole percentage, if known.
    public var percent: Int? {
        share.map { Int(($0 * 100).rounded()) }
    }

    /// How full it is, for the ring's colour, with the same bands as the
    /// 5-hour window's.
    public var band: UsageWindow.Band? {
        guard let share else { return nil }
        if share >= 0.9 { return .nearlyFull }
        if share >= 0.7 { return .getting }
        return .plenty
    }

    /// The tokens used and what they're measured against, to show: "84k of
    /// 167k", or "84k" with nothing to measure against. `nil` if nothing is
    /// known.
    public var tokensText: String? {
        guard let usedTokens else { return nil }
        guard let measure else { return Self.short(usedTokens) }
        return "\(Self.short(usedTokens)) of \(Self.short(measure.tokens))"
    }

    /// The same, to be read out: "84 thousand of 167 thousand tokens".
    public var spokenTokens: String? {
        guard let usedTokens else { return nil }
        guard let measure else { return "\(Self.spoken(usedTokens)) tokens" }
        return "\(Self.spoken(usedTokens)) of \(Self.spoken(measure.tokens)) tokens"
    }

    /// The model's name, to show: "Opus 4.7" for `claude-opus-4-7`, "Opus
    /// 4.7, 1M" for `claude-opus-4-7[1m]`, and "Dummy" for the dummy
    /// characters. An id it can't read is shown as it is.
    public var modelName: String? {
        guard let model, !model.isEmpty else { return nil }
        return Self.name(ofModel: model)
    }

    static func name(ofModel model: String) -> String {
        if model == "dummy" { return "Dummy" }
        var id = model
        var suffix: String?
        if let open = id.firstIndex(of: "["), id.hasSuffix("]") {
            suffix = String(id[id.index(after: open)..<id.index(before: id.endIndex)]).uppercased()
            id = String(id[..<open])
        }
        var parts = id.split(separator: "-").map(String.init)
        guard parts.count >= 2, parts[0] == "claude" else { return model }
        parts.removeFirst()
        // A date at the end, such as 20250929, isn't part of the name.
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) { parts.removeLast() }
        guard let family = parts.first, family.allSatisfy(\.isLetter) else { return model }
        let version = parts.dropFirst()
        guard !version.isEmpty, version.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return model }
        var name = family.prefix(1).uppercased() + family.dropFirst() + " " + version.joined(separator: ".")
        if let suffix, !suffix.isEmpty { name += ", " + suffix }
        return name
    }

    /// "84k", "1.2M" or "950".
    static func short(_ tokens: Int) -> String {
        if tokens >= 999_500 {
            let millions = Double(tokens) / 1_000_000
            let rounded = (millions * 10).rounded() / 10
            return rounded == rounded.rounded() ? "\(Int(rounded))M" : "\(rounded)M"
        }
        if tokens >= 1_000 { return "\(Int((Double(tokens) / 1_000).rounded()))k" }
        return "\(tokens)"
    }

    /// "84 thousand", "1.2 million" or "950".
    static func spoken(_ tokens: Int) -> String {
        let text = short(tokens)
        if text.hasSuffix("M") { return text.dropLast() + " million" }
        if text.hasSuffix("k") { return text.dropLast() + " thousand" }
        return text
    }
}
