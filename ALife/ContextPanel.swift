import ALifeClient
import SwiftUI

/// The small panel under the usage panel at the top left with how full the
/// Claude Code session of the character you're talking to is: a ring with
/// how far it is to where Claude Code compacts the conversation by itself
/// (or, if it doesn't, to the end of the window), the tokens, whose they
/// are, and on a line of its own the model playing it, with its version,
/// such as "Opus 5.5": the one Claude Code says it runs on, or before it
/// has started, the one it will. It follows the character you pick, and
/// fills as it works.
struct ContextPanel: View {
    @Environment(ServerConnection.self) private var server
    @Environment(\.shirts) private var shirts
    let session: AgentSession

    var body: some View {
        let context = session.context
        let model = session.modelName(among: server.models)
        // Laid out as the usage panel is: the tokens, then whose they are,
        // then the model.
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
                Text(session.name)
            }
            Text(model)
        }
        .animation(.easeInOut, value: context)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(context, model: model))
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

    private func accessibilityText(_ context: SessionContext?, model: String) -> String {
        guard let context else { return "\(session.name)'s context: not started, \(model)" }
        var parts = ["\(session.name)'s context"]
        switch (context.measure, context.percent) {
        case (.compaction, let percent?): parts.append("\(percent) percent of the way to compacting")
        case (.window, let percent?): parts.append("\(percent) percent of the window, no auto-compact")
        default: break
        }
        if let tokens = context.spokenTokens { parts.append(tokens) }
        parts.append(model)
        return parts.joined(separator: ", ")
    }
}
