import AppKit

/// One account's pair of readings, as drawn in the menu bar.
struct AccountMeter {
    var initial: String
    var fiveHour: Double?
    var weekly: Double?

    var hottest: Double? { [fiveHour, weekly].compactMap { $0 }.max() }
}

/// Menu bar content: a flame followed by one group of two stacked bars per
/// account — 5-hour on top, 7-day below — each with its percentage.
///
/// Drawn in a real `NSView` rather than a pre-rendered image so the menu bar's
/// light/dark appearance applies automatically. `hitTest` returns nil so clicks
/// fall through to the enclosing `NSStatusBarButton`, which keeps its normal
/// highlight and action handling.
final class StatusBarView: NSView {

    var meters: [AccountMeter] = [] { didSet { needsDisplay = true } }

    /// Track length in points, from Settings.
    var barLength: CGFloat = 28 { didSet { needsDisplay = true } }

    private static let flameWidth: CGFloat = 15
    private static let labelWidth: CGFloat = 27
    private static let initialWidth: CGFloat = 9
    private static let gap: CGFloat = 3
    private static let groupGap: CGFloat = 7
    private let barHeight: CGFloat = 3.5

    /// Initials are only worth the space once there is more than one account.
    private var showsInitials: Bool { meters.count > 1 }

    /// Total width the status item should reserve for the current content.
    static func width(meters: [AccountMeter], barLength: CGFloat) -> CGFloat {
        guard !meters.isEmpty else { return flameWidth + gap + 30 }
        let perGroup = (meters.count > 1 ? initialWidth + gap : 0) + barLength + gap + labelWidth
        return flameWidth + gap
            + perGroup * CGFloat(meters.count)
            + groupGap * CGFloat(meters.count - 1)
            + gap
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.width(meters: meters, barLength: barLength),
               height: NSStatusBar.system.thickness)
    }

    /// Let the status item button handle mouse events.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func color(for fraction: Double?) -> NSColor {
        guard let fraction else { return .tertiaryLabelColor }
        return UsageLevel(fraction: fraction).nsColor
    }

    /// Every tracked account's usage taken together.
    ///
    /// The mean of each account's own hottest limit, not the worst single
    /// reading anywhere. Each account carries its own ceiling, so what matters
    /// when you hold several is how much of the *combined* allowance is gone:
    /// one account at 100% beside a fresh one is half your capacity, not an
    /// emergency, and a flame that went red there would cry wolf every time.
    ///
    /// Accounts with no reading are left out rather than counted as zero, which
    /// would drag the total towards green on the strength of figures the app
    /// does not actually have.
    var summaryFraction: Double? {
        let readings = meters.compactMap(\.hottest)
        guard !readings.isEmpty else { return nil }
        return readings.reduce(0, +) / Double(readings.count)
    }

    /// The flame carries the signal when the bars are too small to read.
    ///
    /// With no account at all there is nothing to signal, so it drops the usage
    /// tint entirely and draws plain — white against a dark menu bar, black
    /// against a light one. That is deliberately distinct from the dimmed grey
    /// used when accounts *are* tracked but none has a reading yet: one means
    /// "nothing to watch", the other "watching, no figures".
    private var flameColor: NSColor {
        guard !meters.isEmpty else { return .labelColor }
        return color(for: summaryFraction)
    }

    override func draw(_ dirtyRect: NSRect) {
        let h = bounds.height
        // Row centres: top row for the 5-hour limit, bottom for the 7-day.
        let topY = h * 0.635
        let bottomY = h * 0.335

        drawFlame(centerY: h / 2)

        var x = Self.flameWidth + Self.gap
        for meter in meters {
            if showsInitials {
                draw(initial: meter.initial, x: x, centerY: h / 2)
                x += Self.initialWidth + Self.gap
            }
            draw(fraction: meter.fiveHour, barX: x, centerY: topY)
            draw(fraction: meter.weekly, barX: x, centerY: bottomY)
            x += barLength + Self.gap + Self.labelWidth + Self.groupGap
        }
    }

    private func drawFlame(centerY: CGFloat) {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        guard let flame = NSImage(systemSymbolName: "flame.fill", accessibilityDescription: "Claude usage")?
            .withSymbolConfiguration(config) else { return }

        let size = flame.size
        let rect = NSRect(
            x: (Self.flameWidth - size.width) / 2,
            y: centerY - size.height / 2,
            width: size.width,
            height: size.height
        )

        let tint = flameColor
        let tinted = NSImage(size: size, flipped: false) { _ in
            flame.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
            tint.set()
            NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: rect)
    }

    private func draw(initial: String, x: CGFloat, centerY: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let size = (initial as NSString).size(withAttributes: attrs)
        (initial as NSString).draw(
            at: NSPoint(x: x + (Self.initialWidth - size.width) / 2, y: centerY - size.height / 2),
            withAttributes: attrs
        )
    }

    private func draw(fraction: Double?, barX: CGFloat, centerY: CGFloat) {
        let track = NSRect(
            x: barX, y: centerY - barHeight / 2,
            width: barLength, height: barHeight
        )
        let radius = barHeight / 2

        NSColor.tertiaryLabelColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()

        let filled = min(max(fraction ?? 0, 0), 1)
        if filled > 0 {
            let fill = NSRect(
                x: track.minX, y: track.minY,
                width: max(track.width * filled, barHeight),
                height: track.height
            )
            color(for: fraction).setFill()
            NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
        }

        let text = fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(
            at: NSPoint(x: track.maxX + Self.gap + Self.labelWidth - size.width,
                        y: centerY - size.height / 2),
            withAttributes: attrs
        )
    }
}
