import ALifeClient
import SwiftUI

/// The small panel at the top left with how much of Claude's 5-hour usage
/// window is used, as a ring, and how long until it resets. It is only
/// there while the server has a reading of a window that is still going; a
/// reading over half an hour old is dimmed and says when it was taken, as
/// the server only hears while one of its characters is running.
struct UsagePanel: View {
    @Environment(ServerConnection.self) private var server
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    /// How wide the panel is while it shows, and 0 while it doesn't, for the
    /// status pill to keep clear of it.
    @Binding var width: CGFloat

    var body: some View {
        // Brought up to date each minute, for the countdown, and to go
        // once the window resets.
        TimelineView(.everyMinute) { context in
            if let window = server.usage.currentWindow(at: context.date) {
                panel(window, at: context.date)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                    .onDisappear { width = 0 }
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut, value: server.usage)
    }

    private func panel(_ window: UsageWindow, at date: Date) -> some View {
        let stale = window.isStale(at: date)
        let countdown = window.countdown(at: date) ?? ""
        let asOf = "as of \(window.readAt.formatted(date: .omitted, time: .shortened))"
        let layout = isNarrow
            ? AnyLayout(VStackLayout(spacing: 4))
            : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            UsageRing(window: window)
            VStack(alignment: isNarrow ? .center : .leading, spacing: 1) {
                Text(isNarrow ? countdown : "Resets in \(countdown)")
                    .font(isNarrow ? .caption2 : .footnote)
                    .monospacedDigit()
                if stale {
                    Text(asOf)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
        }
        .opacity(stale ? 0.55 : 1)
        .padding(.horizontal, isNarrow ? 8 : 10)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(window, at: date, stale: stale ? asOf : nil))
    }

    /// Whether there is little room across, as on an iPhone held upright,
    /// so the countdown goes under the ring.
    private var isNarrow: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    private func accessibilityText(_ window: UsageWindow, at date: Date, stale asOf: String?) -> String {
        var text = "Usage: " + (window.percent.map { "\($0) percent" } ?? "unknown")
        if let countdown = window.spokenCountdown(at: date) { text += ", resets in \(countdown)" }
        if let asOf { text += ", \(asOf)" }
        return text
    }
}

/// A ring whose edge fills clockwise from the top with how much of the
/// window is used, green, amber from 70% and red from 90%, with the
/// percentage in the middle, or a "?" if it isn't known.
struct UsageRing: View {
    let window: UsageWindow
    var size: CGFloat = 34
    var lineWidth: CGFloat = 4

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.25), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: window.utilization ?? 0)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(window.percent.map { "\($0)%" } ?? "?")
                .font(.system(size: size * 0.27, weight: .semibold))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .padding(lineWidth)
        }
        .frame(width: size, height: size)
        .animation(.easeInOut, value: window.utilization)
    }

    private var color: Color {
        switch window.band {
        case .plenty, nil: return .green
        case .getting: return .orange
        case .nearlyFull: return .red
        }
    }
}
