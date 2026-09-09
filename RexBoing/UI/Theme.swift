import SwiftUI
import AppKit

/// How alarming a value is. Drives the colour ramp everywhere — menu bar
/// readouts, gauge rings, sparklines — so a glance reads the same in every
/// part of the app.
enum Severity {
    case calm
    case elevated
    case high
    case critical

    var swiftUIColor: Color {
        switch self {
        case .calm: return Palette.calm
        case .elevated: return Palette.elevated
        case .high: return Palette.high
        case .critical: return Palette.critical
        }
    }

    /// `nil` for `.calm`, so the menu bar leaves ordinary values in the default
    /// label colour instead of painting everything green.
    ///
    /// Bridged once and held, both to avoid rebuilding an `NSColor` for every
    /// readout on every sample and so that two cells with the same severity
    /// compare equal — the menu bar's frame cache uses cell equality to decide
    /// whether anything needs redrawing.
    var color: NSColor? {
        switch self {
        case .calm: return nil
        case .elevated: return Self.elevatedColor
        case .high: return Self.highColor
        case .critical: return Self.criticalColor
        }
    }

    private static let elevatedColor = NSColor(Palette.elevated)
    private static let highColor = NSColor(Palette.high)
    private static let criticalColor = NSColor(Palette.critical)

    static func load(_ fraction: Double) -> Severity {
        switch fraction {
        case ..<0.6: return .calm
        case ..<0.8: return .elevated
        case ..<0.93: return .high
        default: return .critical
        }
    }

    /// Thresholds sized for Apple silicon, which idles warm and sustains into
    /// the 90s under load without anything being wrong.
    static func temperature(_ celsius: Double) -> Severity {
        switch celsius {
        case ..<70: return .calm
        case ..<85: return .elevated
        case ..<95: return .high
        default: return .critical
        }
    }

    static func memory(_ level: MemoryPressureLevel) -> Severity {
        switch level {
        case .normal: return .calm
        case .warning: return .high
        case .critical: return .critical
        }
    }

    static func thermal(_ state: ProcessInfo.ThermalState) -> Severity {
        switch state {
        case .nominal: return .calm
        case .fair: return .elevated
        case .serious: return .high
        case .critical: return .critical
        @unknown default: return .calm
        }
    }
}

enum Palette {
    // Subsystem accents. Each subsystem keeps its hue across the gauge, the
    // sparkline and the section header so the eye can track one metric down
    // the panel without re-reading labels.
    static let cpu = Color(red: 0.28, green: 0.62, blue: 1.00)
    static let gpu = Color(red: 0.72, green: 0.45, blue: 1.00)
    static let memory = Color(red: 0.25, green: 0.80, blue: 0.60)
    static let swap = Color(red: 1.00, green: 0.72, blue: 0.28)
    static let thermal = Color(red: 1.00, green: 0.50, blue: 0.32)
    static let power = Color(red: 1.00, green: 0.85, blue: 0.30)
    static let network = Color(red: 0.30, green: 0.80, blue: 0.85)
    static let disk = Color(red: 0.55, green: 0.60, blue: 0.95)
    static let battery = Color(red: 0.45, green: 0.85, blue: 0.45)

    static let calm = Color(red: 0.36, green: 0.78, blue: 0.52)
    static let elevated = Color(red: 0.95, green: 0.76, blue: 0.28)
    static let high = Color(red: 0.98, green: 0.56, blue: 0.24)
    static let critical = Color(red: 0.96, green: 0.36, blue: 0.36)

    static let cardBackground = Color.primary.opacity(0.045)
    static let cardStroke = Color.primary.opacity(0.07)
    static let trackBackground = Color.primary.opacity(0.09)

    /// Ink for the sparkline's hover crosshair and readout. Opaque and opposite
    /// the trace in tone, because it is drawn over a solid block of accent — a
    /// translucent marker would take the accent's colour and disappear into it.
    static let graphMarker = Color(nsColor: .textBackgroundColor)
}

extension ProcessMetric {
    /// The subsystem hue this metric shares with its card and its graph, so a
    /// process list ranked by GPU reads as the same thing as the GPU trace.
    var accent: Color {
        switch self {
        case .cpu: return Palette.cpu
        case .memory: return Palette.memory
        case .gpu: return Palette.gpu
        case .energy: return Palette.power
        case .disk: return Palette.disk
        }
    }
}

// MARK: - Visualiser ink

/// The visualiser's colour, as a function of load.
///
/// Below the warning threshold the field keeps the caller's neutral — the menu
/// bar's own label colour — and says everything it has to say about the
/// machine through pace alone. Colour is reserved for the top of the range: a
/// character that is white all day and turns orange is a signal, one that
/// wanders through blue and green on the way there is a mood ring.
///
/// Above the threshold the ramp is continuous rather than stepped, because the
/// load under it glides between samples and a colour that popped from white to
/// orange at exactly seventy percent would flicker across the line all
/// afternoon. The neutral fades into orange over the first ten points, so the
/// field is unmistakably orange by eighty, and the remaining twenty deepen it
/// to red. Orange and red are near neighbours, so a straight component blend
/// between them never passes through a dead grey.
///
/// Rest is the caller's neutral rather than a hue of its own, for the reason
/// `Severity.color` returns nil for `.calm`: an idle menu bar should look like
/// the rest of the menu bar.
enum LoadInk {
    /// The load below which the field is drawn in the neutral, untouched.
    static let threshold = 0.70

    /// Hue stops above the threshold, ascending. The threshold stop is the
    /// neutral passed in.
    ///
    /// Resolved to components once. These feed a per-frame path, and
    /// `NSColor(Color:)` followed by a colour-space conversion is far too much
    /// work to repeat at that rate.
    private static let stops: [(load: Double, rgb: RGB)] = [
        (0.80, RGB(Palette.high)),
        (1.00, RGB(Palette.critical)),
    ]

    private struct RGB {
        var red: CGFloat
        var green: CGFloat
        var blue: CGFloat

        init(red: CGFloat, green: CGFloat, blue: CGFloat) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        init(_ color: Color) {
            self.init(NSColor(color))
        }

        init(_ color: NSColor) {
            // The fallback must itself be an RGB-space colour: the component
            // accessors raise for anything else, and `.white` is in gray space.
            let rgb = color.usingColorSpace(.deviceRGB)
                ?? NSColor(deviceRed: 1, green: 1, blue: 1, alpha: 1)
            red = rgb.redComponent
            green = rgb.greenComponent
            blue = rgb.blueComponent
        }
    }

    /// - Parameters:
    ///   - load: 0...1, expected already smoothed.
    ///   - neutral: the colour at rest and everywhere below `threshold`.
    ///     Expected already resolved against the appearance it will be drawn
    ///     in — this does pure component maths and cannot resolve a dynamic
    ///     colour itself.
    /// - Returns: an opaque colour. The caller applies the neutral's own
    ///   transparency to the layer instead, so overlapping strokes do not
    ///   compound at every crossing. Below the threshold this is the neutral
    ///   object itself, not a copy through RGB space, so the field matches the
    ///   readouts beside it to the bit.
    static func color(forLoad load: Double, neutral: NSColor) -> NSColor {
        let clamped = min(1, max(0, load))
        guard clamped > threshold else { return neutral }

        var lowLoad = threshold
        var low = RGB(neutral)
        for stop in stops {
            guard clamped > stop.load else {
                let span = stop.load - lowLoad
                let t = span > 0 ? (clamped - lowLoad) / span : 0
                return NSColor(
                    deviceRed: lerp(low.red, stop.rgb.red, t),
                    green: lerp(low.green, stop.rgb.green, t),
                    blue: lerp(low.blue, stop.rgb.blue, t),
                    alpha: 1)
            }
            lowLoad = stop.load
            low = stop.rgb
        }

        return NSColor(deviceRed: low.red, green: low.green, blue: low.blue, alpha: 1)
    }

    private static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat {
        a + (b - a) * CGFloat(t)
    }
}

enum Metrics {
    /// Sized for the headline cards to sit two abreast. Each column keeps
    /// about 242 points of content, which is the narrowest a four-tile stat
    /// row — the thermal card's CPU/GPU/Peak/Battery run — reads at without
    /// the values crowding their labels.
    static let dashboardWidth: CGFloat = 560
    static let cardCorner: CGFloat = 11
    static let cardPadding: CGFloat = 11
    static let sectionSpacing: CGFloat = 9

    /// The panel's preferred height, clipped to what the screen can actually
    /// show. A popover taller than the display does not scroll — it is simply
    /// cut off, taking the lower cards with it, which is easy to miss on a
    /// 13-inch machine with a tall menu bar.
    ///
    /// Takes the screen the popover will open on: the status item is drawn on
    /// every display, and `NSScreen.main` is whichever one holds the key
    /// window — rarely the one that was clicked, for an accessory app.
    @MainActor
    static func dashboardHeight(on screen: NSScreen?) -> CGFloat {
        let available = (screen ?? NSScreen.main)?.visibleFrame.height ?? 800
        return min(640, max(360, available - 40))
    }
}

// MARK: - Shared text styles

extension View {
    /// Small uppercase section label.
    func sectionCaption() -> some View {
        font(.system(size: 9.5, weight: .semibold))
            .kerning(0.6)
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
    }

    /// Numeric readout. Monospaced digits stop values jittering as they change.
    func metricValue(size: CGFloat = 12, weight: Font.Weight = .medium) -> some View {
        font(.system(size: size, weight: weight, design: .rounded))
            .monospacedDigit()
    }

    func metricLabel() -> some View {
        font(.system(size: 10.5))
            .foregroundStyle(.secondary)
    }
}

/// Rounded container used for every section of the dashboard.
struct Card<Content: View>: View {
    var accent: Color
    var title: String
    var symbol: String
    var trailing: String?
    /// The one number the card exists to report, drawn large and in the card's
    /// own hue on a tinted chip.
    ///
    /// This is where the headline gauges went. A ring is a lot of pixels spent
    /// restating a number that is also printed inside it, next to a graph of
    /// the same series — so the number moved to the card it belongs to and got
    /// big enough to read from across the desk.
    var headline: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(accent)
                Text(title).sectionCaption()
                Spacer(minLength: 4)
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 10, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                if let headline {
                    Text(headline)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(
                            Capsule(style: .continuous).fill(accent.opacity(0.16)))
                }
            }
            content
        }
        // Fills whatever cell the layout hands it, content pinned to the top.
        // Alone on a row this resolves to the natural size it always had; in
        // a paired row it is what lets the shorter card's background run the
        // full height of its neighbour instead of stopping partway down.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(Metrics.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: Metrics.cardCorner, style: .continuous)
                .fill(Palette.cardBackground))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.cardCorner, style: .continuous)
                .strokeBorder(Palette.cardStroke, lineWidth: 1))
    }
}
