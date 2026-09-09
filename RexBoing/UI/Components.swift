import SwiftUI
import AppKit

/// A mutable box for a value the render produces and a gesture consumes.
/// Held in `@State` for its lifetime, not for its change notifications —
/// writing to it deliberately does not invalidate anything.
private final class SizeBox {
    var value: CGSize = .zero
}

// MARK: - Graph inspection

/// What a graph does when it is clicked.
///
/// Carried in the environment rather than passed down through the cards. The
/// cards take their data by value precisely so they do not observe anything,
/// and threading a closure through all seven of them to reach a control that
/// lives in the eighth would undo that for no gain. Absent — outside the
/// dashboard — the graphs are inert, which is the right default for a trace
/// with nothing behind it.
struct InspectGraphAction: Sendable {
    var handler: (@MainActor @Sendable (ProcessMetric, Date) -> Void)?

    var isAvailable: Bool { handler != nil }

    @MainActor
    func callAsFunction(_ metric: ProcessMetric, at date: Date) {
        handler?(metric, date)
    }
}

private struct InspectGraphKey: EnvironmentKey {
    static let defaultValue = InspectGraphAction(handler: nil)
}

extension EnvironmentValues {
    var inspectGraph: InspectGraphAction {
        get { self[InspectGraphKey.self] }
        set { self[InspectGraphKey.self] = newValue }
    }
}

// MARK: - Sparkline

/// Filled history graph. Values are normalised against either a caller-supplied
/// ceiling (for percentages) or the window's own peak (for open-ended series
/// like throughput, where an absolute scale would flatten everything).
///
/// The area under the trace is filled solid rather than faded away to nothing.
/// A fill that reaches two percent opacity at the baseline is a line graph with
/// extra steps: the eye has to follow a one-point stroke to read the shape, and
/// at this size — a couple of hundred points wide, forty tall, on a card the
/// user glances at — the shape is the whole point. Filling it makes the trace a
/// silhouette that reads at arm's length.
struct Sparkline: View {
    var values: [Double]
    var accent: Color
    /// Fixed upper bound; `nil` autoscales to the visible peak.
    var ceiling: Double? = 1
    var lineWidth: CGFloat = 1.4
    /// Printed in the top-left corner. An autoscaled graph is unreadable
    /// without it — the same shape means 2 KB/s or 2 GB/s.
    var scaleCaption: String?
    /// When each of `values` was sampled, same order and length. Supplied, the
    /// hover readout can say which second the pointer is over as well as what
    /// the reading was.
    var timestamps: [Date] = []
    /// Renders a sample for the hover readout. Defaults to a percentage
    /// because most series here are one.
    var format: (Double) -> String = { Format.percent($0, decimals: 1) }
    /// Which resource the process breakdown should open on. Supplying it is
    /// what makes the graph clickable.
    ///
    /// A few series have no per-process counterpart — there is no per-process
    /// temperature, and `ProcessRow` carries no network figures — so those
    /// graphs open on CPU. That is not a fudge: "what was running when the
    /// network went wild" is the question being asked, and the breakdown
    /// window lets the user switch resource from there anyway.
    var inspectorMetric: ProcessMetric?

    @Environment(\.inspectGraph) private var inspectGraph

    /// Pointer position in the graph's own coordinates, `nil` when away.
    @State private var pointer: CGPoint?
    /// The size the trace was last drawn at.
    ///
    /// A reference box written from inside the render, rather than `@State` or
    /// a `GeometryReader`. Only the click handler needs it, and it needs it
    /// after the fact — routing the size back through the view graph would
    /// invalidate the body on every sample to deliver a number that changes
    /// when the panel is resized, which is never.
    @State private var drawnSize = SizeBox()

    private var isClickable: Bool {
        inspectorMetric != nil && inspectGraph.isAvailable && !timestamps.isEmpty
    }

    private var upperBound: Double {
        if let ceiling { return max(ceiling, 0.0001) }
        return max(values.max() ?? 1, 0.0001)
    }

    var body: some View {
        // `Canvas` rather than `GeometryReader` + shapes. The trace is pure
        // drawing with no child views, and routing it through a layout
        // container made every sample relayout the panel's whole view tree.
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            drawnSize.value = size
            let points = coordinates(in: size, bound: upperBound)
            guard points.count > 1 else { return }

            var line = Path()
            line.move(to: points[0])
            for point in points.dropFirst() { line.addLine(to: point) }

            var fill = line
            fill.addLine(to: CGPoint(x: points[points.count - 1].x, y: size.height))
            fill.addLine(to: CGPoint(x: points[0].x, y: size.height))
            fill.closeSubpath()

            // Barely a gradient — the peaks give back a little of the card
            // behind them so a tall trace does not read as a solid block, and
            // everything from mid-height down is the accent at full strength.
            context.fill(fill, with: .linearGradient(
                Gradient(colors: [accent.opacity(0.82), accent]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            // Miter, not round: rounding the joins of a filled silhouette
            // sands the peaks off, and the peaks are the interesting part.
            context.stroke(line, with: .color(accent), style: StrokeStyle(
                lineWidth: lineWidth, lineCap: .butt, lineJoin: .miter))

            // A rule along the baseline, drawn the full width rather than only
            // under the samples. It gives the graph a floor to stand on while
            // the buffer is still filling from the left, and keeps a series
            // sitting at zero — an idle GPU, a quiet network — visible as a
            // flat line instead of an empty rectangle.
            context.fill(
                Path(CGRect(x: 0, y: size.height - 1.5, width: size.width, height: 1.5)),
                with: .color(accent))

            if let pointer, let index = nearestIndex(to: pointer.x, in: points) {
                drawMarker(at: index, points: points, in: size, context: &context)
            }
        }
        .overlay(alignment: .topLeading) {
            // The caption steps aside while the pointer is down: both it and
            // the readout want the top of the graph, and on a 190-point-wide
            // trace they would sit on top of each other.
            if let scaleCaption, pointer == nil {
                Text(scaleCaption)
                    .font(.system(size: 8.5))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    // The caption used to sit over near-empty space. Against a
                    // solid fill it needs something to sit on, or an autoscaled
                    // graph — whose peak always touches the top — hides it.
                    .padding(.horizontal, 3)
                    .padding(.vertical, 0.5)
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(.background.opacity(0.75)))
            }
        }
        // Without this the pointer is only tracked over the trace's own pixels,
        // so the readout blinks out every time the series dips below the
        // cursor — which is most of the graph on a quiet machine.
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let location): pointer = location
            case .ended: pointer = nil
            }
        }
        .onHover { inside in
            guard isClickable else { return }
            // `set` rather than `push`/`pop`: the popover can be torn down
            // while the pointer is still inside the graph, and an unbalanced
            // push leaves the whole system stuck on a pointing hand.
            (inside ? NSCursor.pointingHand : NSCursor.arrow).set()
        }
        .onTapGesture { if isClickable { selectSampleUnderPointer() } }
        .help(isClickable ? "Click to see which processes were responsible" : "")
        // The trace itself is decoration — its numbers are read out by the
        // card around it — but once it opens a window it is a control, and a
        // control has to be reachable without a pointer.
        .accessibilityElement()
        .accessibilityHidden(!isClickable)
        .accessibilityLabel("Process breakdown")
        .accessibilityHint("Opens the processes responsible for this graph")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if let last = timestamps.last { inspect(at: last) } }
    }

    /// Resolves the click to the sample the crosshair was sitting on, so the
    /// window opens on the instant the user was actually pointing at rather
    /// than one rounded differently from the readout they just read.
    private func selectSampleUnderPointer() {
        let size = drawnSize.value
        guard let pointer, size.width > 0 else { return }
        let points = coordinates(in: size, bound: upperBound)
        guard let index = nearestIndex(to: pointer.x, in: points),
              index < timestamps.count
        else { return }
        inspect(at: timestamps[index])
    }

    private func inspect(at date: Date) {
        guard let inspectorMetric else { return }
        // Opening the breakdown window closes the transient popover under the
        // pointer, so the balancing `onHover(false)` that would put the arrow
        // back never arrives — reset before handing off.
        NSCursor.arrow.set()
        inspectGraph(inspectorMetric, at: date)
    }

    // MARK: Hover readout

    /// Crosshair, dot and label for the sample nearest the pointer.
    private func drawMarker(
        at index: Int, points: [CGPoint], in size: CGSize,
        context: inout GraphicsContext
    ) {
        let point = points[index]

        var guide = Path()
        guide.move(to: CGPoint(x: point.x, y: 0))
        guide.addLine(to: CGPoint(x: point.x, y: size.height))
        context.stroke(
            guide, with: .color(Palette.graphMarker.opacity(0.55)),
            style: StrokeStyle(lineWidth: 1))

        // A hole punched out of the fill with the accent in the middle of it.
        // An accent-coloured dot alone would be invisible: it sits on top of a
        // solid block of the same colour.
        let dot = CGRect(x: point.x - 4.5, y: point.y - 4.5, width: 9, height: 9)
        context.fill(Path(ellipseIn: dot), with: .color(Palette.graphMarker))
        context.fill(Path(ellipseIn: dot.insetBy(dx: 2.5, dy: 2.5)), with: .color(accent))

        // Measured against a box it cannot fill, so the width that comes back
        // is the caption's natural one line rather than however many lines it
        // would wrap to inside the graph.
        let unbounded = CGSize(width: 1000, height: 100)
        var label = context.resolve(styled(caption(for: index, form: .full)))
        var text = label.measure(in: unbounded)
        // The throughput graphs are 190 points wide, which a wall-clock time
        // and a long rate do not always both fit into. Rather than wrap or
        // spill over the card, the caption gives up precision a step at a time.
        for form in [CaptionForm.shortTime, .valueOnly] where text.width + 7 > size.width {
            label = context.resolve(styled(caption(for: index, form: form)))
            text = label.measure(in: unbounded)
        }

        let box = CGRect(
            x: min(max(point.x - (text.width + 7) / 2, 0), max(0, size.width - text.width - 7)),
            y: 0, width: text.width + 7, height: text.height + 3)
        context.fill(
            Path(roundedRect: box, cornerRadius: 3, style: .continuous),
            with: .color(Palette.graphMarker.opacity(0.92)))
        context.draw(label, in: box.insetBy(dx: 3.5, dy: 1.5))
    }

    private func styled(_ caption: String) -> Text {
        Text(caption)
            .font(.system(size: 8.5, weight: .medium))
            .monospacedDigit()
    }

    private enum CaptionForm {
        case full
        /// Minutes and seconds only. The window is 90 samples long, so the hour
        /// is never in question and dropping it buys back a third of the width.
        case shortTime
        case valueOnly
    }

    private func caption(for index: Int, form: CaptionForm) -> String {
        let reading = format(values[index])
        guard index < timestamps.count, form != .valueOnly else { return reading }
        let date = timestamps[index]
        let time = form == .full ? Format.clock(date) : Format.clockShort(date)
        return "\(time) · \(reading)"
    }

    /// Index of the plotted sample closest to a horizontal position. Points are
    /// evenly spaced, so this is arithmetic rather than a search — the callback
    /// runs on every pointer move.
    private func nearestIndex(to x: CGFloat, in points: [CGPoint]) -> Int? {
        guard points.count > 1 else { return nil }
        let step = points[1].x - points[0].x
        guard step > 0 else { return nil }
        let offset = (x - points[0].x) / step
        return min(points.count - 1, max(0, Int(offset.rounded())))
    }

    private func coordinates(in size: CGSize, bound: Double) -> [CGPoint] {
        guard values.count > 1 else { return [] }
        // Always plot against the full capacity so a partially filled buffer
        // grows in from the left rather than stretching.
        let slots = max(values.count, MetricsHistory.capacity)
        let step = size.width / CGFloat(slots - 1)
        let leadingOffset = CGFloat(slots - values.count) * step

        return values.enumerated().map { index, value in
            let clamped = min(max(value, 0), bound)
            return CGPoint(
                x: leadingOffset + CGFloat(index) * step,
                y: size.height - CGFloat(clamped / bound) * size.height)
        }
    }

}

// MARK: - Disclosure

/// The chevron row a card puts under its summary to offer the rest.
///
/// Cards lead with the two or three numbers that answer "is anything wrong",
/// and fold the supporting detail behind this. Everything a card knows is still
/// one click away; none of it is in the way of the reading that is taken twenty
/// times a day.
struct ExpandButton: View {
    var title: String
    @Binding var expanded: Bool

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                Spacer()
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(expanded ? "Hide" : "Show") \(title)")
    }
}

// MARK: - Segmented bar

struct BarSegment: Identifiable {
    var id: String { label }
    var label: String
    var bytes: UInt64
    var color: Color
}

/// Proportional stacked bar with a legend, used for the memory breakdown.
struct SegmentedBar: View {
    var segments: [BarSegment]
    var total: UInt64
    var showLegend: Bool = true

    private var visible: [BarSegment] { segments.filter { $0.bytes > 0 } }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                context.clip(to: Path(roundedRect: CGRect(origin: .zero, size: size),
                                      cornerRadius: size.height / 2))
                context.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .color(Palette.trackBackground))

                var x: CGFloat = 0
                for segment in visible {
                    let width = self.width(for: segment, in: size.width)
                    context.fill(
                        Path(CGRect(x: x, y: 0, width: width, height: size.height)),
                        with: .color(segment.color))
                    // A one-point gap keeps adjacent segments distinguishable
                    // where their colours are close.
                    x += width + 1
                    if x >= size.width { break }
                }
            }
            .frame(height: 8)

            if showLegend {
                // Two columns rather than three: at a third of the card's width
                // a label like "Compressed" wraps mid-word.
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 2),
                    alignment: .leading, spacing: 4
                ) {
                    ForEach(visible) { segment in
                        HStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(segment.color)
                                .frame(width: 6, height: 6)
                            Text(segment.label)
                                .font(.system(size: 9.5))
                                .foregroundStyle(.secondary)
                            Text(Format.bytes(segment.bytes))
                                .font(.system(size: 9.5, weight: .medium))
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
    }

    private func width(for segment: BarSegment, in available: CGFloat) -> CGFloat {
        guard total > 0 else { return 0 }
        let fraction = Double(segment.bytes) / Double(total)
        return max(2, available * CGFloat(min(1, fraction)))
    }
}

// MARK: - Core grid

/// One bar per logical core, grouped by cluster. Efficiency and performance
/// cores get different accents because their loads mean different things.
struct CoreGrid: View {
    var loads: [Double]
    var kinds: [CoreKind]

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(loads.enumerated()), id: \.offset) { index, load in
                let kind = index < kinds.count ? kinds[index] : .unknown
                let accent = kind == .efficiency ? Palette.memory : Palette.cpu
                let clamped = min(1, max(0, load))

                VStack(spacing: 2) {
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Palette.trackBackground)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(accent.opacity(0.35 + 0.65 * clamped))
                            .frame(height: max(2, 26 * CGFloat(clamped)))
                    }
                    .frame(height: 26)

                    Text(kind == .unknown ? "\(index)" : kind.rawValue)
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .help("Core \(index) \(kind.description) — \(Format.percent(load))")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Core \(index), \(kind.description)")
                .accessibilityValue(Format.percent(load))
            }
        }
    }
}

// MARK: - Rows

/// Label on the left, value on the right — the workhorse row of the dashboard.
struct StatRow: View {
    var label: String
    var value: String
    var tint: Color?
    var symbol: String?

    var body: some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .frame(width: 12)
            }
            Text(label).metricLabel()
            Spacer(minLength: 6)
            Text(value)
                .metricValue(size: 11)
                .foregroundStyle(tint ?? .primary)
        }
    }
}

/// Compact label-over-value pair, for dense multi-column blocks.
struct StatTile: View {
    var label: String
    var value: String
    var tint: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Text(value)
                .metricValue(size: 11.5, weight: .semibold)
                .foregroundStyle(tint ?? .primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Thin horizontal meter used for per-process rows and fan speeds.
struct MiniBar: View {
    var fraction: Double
    var accent: Color
    var height: CGFloat = 4

    var body: some View {
        // Drawn rather than laid out. There is one of these on every process
        // row, every fan and three more besides, and a GeometryReader each
        // pulled the whole panel into a layout pass on every sample.
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            let track = Path(roundedRect: CGRect(origin: .zero, size: size),
                             cornerRadius: size.height / 2)
            context.fill(track, with: .color(Palette.trackBackground))

            // The two-point floor keeps a small value visible; zero is not a
            // small value. "Swap: not in use" and an idle process row used to
            // draw the same sliver as something genuinely in use.
            let clamped = CGFloat(min(1, max(0, fraction)))
            guard clamped > 0 else { return }
            let width = max(2, size.width * clamped)
            let bar = Path(
                roundedRect: CGRect(x: 0, y: 0, width: width, height: size.height),
                cornerRadius: size.height / 2)
            context.fill(bar, with: .color(accent))
        }
        .frame(height: height)
    }
}
