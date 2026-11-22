import ALifeClient
import SwiftUI

/// The small panel under the usage panel at the top left with how full the
/// Claude Code session of the character you're talking to is: a ring with
/// how far it is to where Claude Code compacts the conversation by itself
/// (or, if it doesn't, to the end of the window), the tokens, and the model
/// playing it. It follows the character you pick, and fills as it works.
struct ContextPanel: View {
    @Environment(\.shirts) private var shirts
    let session: AgentSession

    var body: some View {
        let context = session.context
        // Laid out as the usage panel is, so the two are the same size: the
        // tokens, then whose they are and the model, on one line.
        TopLeftPanel(
            ring: ShareRing(
                share: context?.share,
                percent: context?.percent,
                band: context?.band,
                placeholder: context == nil ? "–" : "?"
            ),
            headline: tokens(context, narrow: false),
            narrowHeadline: tokens(context, narrow: true)
        ) {
            HStack(spacing: 4) {
                Circle()
                    .fill(shirt)
                    .frame(width: 6, height: 6)
                Text([session.name, context?.modelName].compactMap { $0 }.joined(separator: " · "))
            }
        }
        .animation(.easeInOut, value: context)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(context))
    }

    /// What the tokens come to, to show; shorter on a narrow screen.
    private func tokens(_ context: SessionContext?, narrow: Bool) -> String {
        guard let context else { return "Not started" }
        guard let text = context.tokensText else { return "Starting" }
        let short = text.replacingOccurrences(of: " of ", with: "/")
        switch context.measure {
        case .compaction: return narrow ? short : "\(text) until compacting"
        case .window: return narrow ? short : "\(text), no auto-compact"
        case nil: return text
        }
    }

    /// The character's shirt on the lot.
    private var shirt: Color {
        guard let shirt = shirts[session.id] else { return .secondary }
        #if os(macOS)
        return Color(nsColor: shirt)
        #else
        return Color(uiColor: shirt)
        #endif
    }

    private func accessibilityText(_ context: SessionContext?) -> String {
        guard let context else { return "\(session.name)'s context: not started" }
        var parts = ["\(session.name)'s context"]
        switch (context.measure, context.percent) {
        case (.compaction, let percent?): parts.append("\(percent) percent of the way to compacting")
        case (.window, let percent?): parts.append("\(percent) percent of the window, no auto-compact")
        default: break
        }
        if let tokens = context.spokenTokens { parts.append(tokens) }
        if let model = context.modelName { parts.append(model) }
        return parts.joined(separator: ", ")
    }
}
