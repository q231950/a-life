import ALifeClient
import SwiftUI

/// The small panel at the top left with how much of Claude's 5-hour usage
/// window is used, as a ring, and how long until it resets. It is only
/// there while the server has a reading of a window that is still going; a
/// reading over half an hour old is dimmed and says when it was taken, as
/// the server only hears while one of its characters is running.
///
/// The context panel goes under it, or in its place while it isn't there,
/// laid out the same way (`TopLeftPanel`), in an `EqualWidthColumn`, so the
/// two are as wide as each other.
struct UsagePanel: View {
    @Environment(ServerConnection.self) private var server

    var body: some View {
        // Brought up to date each minute, for the countdown, and to go
        // once the window resets.
        TimelineView(.everyMinute) { context in
            if let window = server.usage.currentWindow(at: context.date) {
                panel(window, at: context.date)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut, value: server.usage)
    }

    private func panel(_ window: UsageWindow, at date: Date) -> some View {
        let stale = window.isStale(at: date)
        let countdown = window.countdown(at: date) ?? ""
        let asOf = "as of \(window.readAt.formatted(date: .omitted, time: .shortened))"
        return TopLeftPanel(
            ring: UsageRing(window: window),
            headline: "Resets in \(countdown)",
            narrowHeadline: countdown,
            isDimmed: stale
        ) {
            Text(stale ? asOf : "5-hour usage")
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(window, at: date, stale: stale ? asOf : nil))
    }

    private func accessibilityText(_ window: UsageWindow, at date: Date, stale asOf: String?) -> String {
        var text = "Usage: " + (window.percent.map { "\($0) percent" } ?? "unknown")
        if let countdown = window.spokenCountdown(at: date) { text += ", resets in \(countdown)" }
        if let asOf { text += ", \(asOf)" }
        return text
    }
}

/// A column of panels all as wide as the widest, one under the other, as
/// the usage and context panels at the top left are. Each panel is asked
/// how wide it would like to be, and then given the widest of those, so
/// they always match. A panel with nothing to show, such as the usage panel
/// while there's no window, takes no room and leaves no gap.
struct EqualWidthColumn: Layout {
    /// The space between the panels in the column.
    static let spacing: CGFloat = 8

    var spacing: CGFloat = Self.spacing

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let (width, heights) = measure(subviews)
        let shown = heights.compactMap { $0 }
        guard !shown.isEmpty else { return .zero }
        return CGSize(width: width, height: shown.reduce(0, +) + spacing * CGFloat(shown.count - 1))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (width, heights) = measure(subviews)
        var y = bounds.minY
        for (subview, height) in zip(subviews, heights) {
            guard let height else {
                subview.place(at: CGPoint(x: bounds.minX, y: bounds.minY), anchor: .topLeading, proposal: .zero)
                continue
            }
            subview.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: width, height: height))
            y += height + spacing
        }
    }

    /// The width every panel gets, the widest any would like, and how tall
    /// each is at that width, or `nil` for one with nothing to show.
    private func measure(_ subviews: Subviews) -> (width: CGFloat, heights: [CGFloat?]) {
        let ideals = subviews.map { $0.sizeThatFits(.unspecified) }
        let width = ideals.filter { $0.width > 0 && $0.height > 0 }.map(\.width).max() ?? 0
        let heights: [CGFloat?] = zip(subviews, ideals).map { subview, ideal in
            guard ideal.width > 0, ideal.height > 0 else { return nil }
            return subview.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        }
        return (width, heights)
    }
}

/// How the panels at the top left are laid out, the usage and the context,
/// so they look alike whatever they say: a ring, then a headline and the
/// detail in smaller, fainter words (a line, or two for the context panel,
/// whose model has a line of its own), in the same fonts and padding, on
/// the same material. On a narrow screen, such as an iPhone held
/// upright, the lines go under the ring, and the headline can be shorter.
///
/// Each draws its material across the whole width it is given, so in an
/// `EqualWidthColumn` both are as wide as the wider one.
struct TopLeftPanel<Detail: View>: View {
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    let ring: AnyView
    let headline: String
    let narrowHeadline: String
    var isDimmed = false
    @ViewBuilder let detail: () -> Detail

    init(
        ring: some View,
        headline: String,
        narrowHeadline: String? = nil,
        isDimmed: Bool = false,
        @ViewBuilder detail: @escaping () -> Detail
    ) {
        self.ring = AnyView(ring)
        self.headline = headline
        self.narrowHeadline = narrowHeadline ?? headline
        self.isDimmed = isDimmed
        self.detail = detail
    }

    var body: some View {
        let layout = isNarrow
            ? AnyLayout(VStackLayout(spacing: 4))
            : AnyLayout(HStackLayout(spacing: 8))
        layout {
            ring
            VStack(alignment: isNarrow ? .center : .leading, spacing: 1) {
                Text(isNarrow ? narrowHeadline : headline)
                    .font(isNarrow ? .caption : .footnote)
                    .monospacedDigit()
                detail()
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
        }
        .opacity(isDimmed ? 0.55 : 1)
        .padding(.horizontal, isNarrow ? 8 : 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: isNarrow ? .center : .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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

/// A ring whose edge fills clockwise from the top with how much of the
/// window is used, green, amber from 70% and red from 90%, with the
/// percentage in the middle, or a "?" if it isn't known.
struct UsageRing: View {
    let window: UsageWindow

    var body: some View {
        ShareRing(share: window.utilization, percent: window.percent, band: window.band)
    }
}

/// A ring whose edge fills clockwise from the top with a share, from 0 to
/// 1, over a faint track, green, amber or red by its band, with the
/// percentage in the middle, or `placeholder` if the share isn't known.
/// The usage gauge and the context ring both draw with it, so the two are
/// always the same size, on every screen.
struct ShareRing: View {
    /// How wide every ring is across, and its edge.
    static let size: CGFloat = 34
    static let lineWidth: CGFloat = 4

    let share: Double?
    let percent: Int?
    let band: UsageWindow.Band?
    var placeholder = "?"

    private var size: CGFloat { Self.size }
    private var lineWidth: CGFloat { Self.lineWidth }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.25), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: share ?? 0)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(percent.map { "\($0)%" } ?? placeholder)
                .font(.system(size: size * 0.27, weight: .semibold))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .padding(lineWidth)
        }
        .frame(width: size, height: size)
        .fixedSize() // never squeezed by the words beside it
        .animation(.easeInOut, value: share)
    }

    private var color: Color {
        switch band {
        case .plenty, nil: return .green
        case .getting: return .orange
        case .nearlyFull: return .red
        }
    }
}
