import SwiftUI
import AppKit

// The top of a monitoring window: one tile per subsystem, each a number big
// enough to read from across the room over the trace it has just drawn. The
// cards below a strip of these are for studying a subsystem; the strip is for
// knowing, at a glance and without scrolling, whether there is one to study.
//
// Shared, like the cards, so a server's window in Rex Boing Remote opens on
// the same strip this Mac's does.

// MARK: - Model

/// One headline reading.
public struct Vital: Identifiable, Sendable {
    public var id: String
    public var title: String
    public var symbol: String
    public var value: String
    /// The line under the number: what it is a share of, or what it is made of.
    public var detail: String
    public var accent: Color
    /// The number's colour when the reading is a warning. Calm readings stay
    /// in the label colour, for the reason the menu bar's do.
    public var tint: Color?
    /// Recent history, newest last. Empty for a reading that keeps none.
    public var trace: [Double]
    /// What the trace is drawn against; `nil` autoscales from zero to its peak.
    public var range: ClosedRange<Double>?
    /// A level, 0...1, for a reading with no history worth a trace — a
    /// battery's charge.
    public var level: Double?
    /// Which resource a click breaks down by process; `nil` where no process
    /// owns the reading.
    public var metric: ProcessMetric?

    public init(
        id: String, title: String, symbol: String, value: String, detail: String,
        accent: Color, tint: Color? = nil, trace: [Double] = [],
        range: ClosedRange<Double>? = nil, level: Double? = nil,
        metric: ProcessMetric? = nil
    ) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.value = value
        self.detail = detail
        self.accent = accent
        self.tint = tint
        self.trace = trace
        self.range = range
        self.level = level
        self.metric = metric
    }
}

extension Vital {
    /// The strip for a machine: only the subsystems it actually reports, in
    /// the order the cards below run. A reading the machine has no source for
    /// — no GPU counter, no wattage, no battery — has no tile, rather than a
    /// tile holding a dash.
    public static func headline(
        snapshot: Snapshot, history: MetricsHistory, unit: TemperatureUnit, span: Int
    ) -> [Vital] {
        var vitals: [Vital] = []

        // CPU
        let cores = snapshot.cpu.perCore.isEmpty ? snapshot.host.logicalCores : snapshot.cpu.perCore.count
        var cpuDetail: [String] = []
        if cores > 0 { cpuDetail.append("\(cores) cores") }
        if snapshot.cpu.loadAverage.one > 0 {
            cpuDetail.append(String(format: "load %.2f", snapshot.cpu.loadAverage.one))
        }
        vitals.append(Vital(
            id: "cpu", title: "Processor", symbol: "cpu",
            value: Format.percent(snapshot.cpu.total, decimals: 1),
            detail: cpuDetail.joined(separator: " · "),
            accent: Palette.cpu, tint: warning(.load(snapshot.cpu.total)),
            trace: history.cpu.values(last: span), range: 0...1, metric: .cpu))

        // GPU
        if snapshot.gpu.available {
            var detail: [String] = []
            if let celsius = snapshot.thermal.gpuCelsius {
                detail.append(Format.temperature(celsius, unit: unit))
            }
            if let watts = snapshot.power.gpuWatts { detail.append(Format.watts(watts)) }
            if detail.isEmpty, snapshot.gpu.inUseMemory > 0 {
                detail.append("\(Format.bytes(snapshot.gpu.inUseMemory)) in use")
            }
            vitals.append(Vital(
                id: "gpu", title: "Graphics", symbol: "cube.transparent",
                value: Format.percent(snapshot.gpu.utilization, decimals: 1),
                detail: detail.isEmpty ? snapshot.gpu.name : detail.joined(separator: " · "),
                accent: Palette.gpu, tint: warning(.load(snapshot.gpu.utilization)),
                trace: history.gpu.values(last: span), range: 0...1, metric: .gpu))
        }

        // Memory
        let memory = snapshot.memory
        vitals.append(Vital(
            id: "memory", title: "Memory", symbol: "memorychip",
            value: Format.percent(memory.fractionUsed),
            detail: "\(Format.bytes(memory.used)) of \(Format.bytes(memory.total))",
            accent: Palette.memory, tint: warning(.memory(memory.pressureLevel)),
            trace: history.memory.values(last: span), range: 0...1, metric: .memory))

        // Temperature
        let thermal = snapshot.thermal
        if let celsius = thermal.cpuCelsius ?? thermal.socCelsius ?? thermal.peakCelsius {
            var detail = [thermal.thermalState.label]
            if let rpm = thermal.fans.map(\.rpm).max(), rpm > 0 {
                detail.append("\(Int(rpm)) rpm")
            } else if let peak = thermal.peakCelsius, peak > celsius + 0.5 {
                detail.append("peak \(Format.temperature(peak, unit: unit))")
            }
            let trace = history.cpuTemp.values(last: span)
            // Temperatures live in a band nowhere near zero; against a 0–100
            // scale an afternoon's worth of them is a flat line.
            let low = max(0, (trace.min() ?? celsius) - 6)
            let high = max(low + 12, (trace.max() ?? celsius) + 3)
            vitals.append(Vital(
                id: "thermal", title: "Thermals", symbol: "thermometer.medium",
                value: Format.temperature(celsius, unit: unit),
                detail: detail.joined(separator: " · "),
                accent: Palette.thermal,
                tint: warning(max(Severity.temperature(celsius), .thermal(thermal.thermalState))),
                trace: trace, range: low...high))
        }

        // Power
        if let watts = snapshot.power.totalWatts {
            var detail: [String] = []
            if let cpu = snapshot.power.cpuWatts, !snapshot.power.cpuIsPackage {
                detail.append("CPU \(Format.watts(cpu))")
            }
            if let gpu = snapshot.power.gpuWatts { detail.append("GPU \(Format.watts(gpu))") }
            if detail.isEmpty, let package = snapshot.power.packageWatts, package != watts {
                detail.append("package \(Format.watts(package))")
            }
            vitals.append(Vital(
                id: "power", title: "Power", symbol: "bolt",
                value: Format.watts(watts),
                detail: detail.isEmpty ? "whole machine" : detail.joined(separator: " · "),
                accent: Palette.power,
                trace: history.power.values(last: span), metric: .energy))
        }

        // Network
        let network = snapshot.network
        vitals.append(Vital(
            id: "network", title: "Network", symbol: "network",
            value: Format.rate(network.rxBytesPerSecond + network.txBytesPerSecond),
            detail: "↓ \(Format.rate(network.rxBytesPerSecond))  ↑ \(Format.rate(network.txBytesPerSecond))",
            accent: Palette.network,
            trace: zip(history.networkRx.values(last: span), history.networkTx.values(last: span)).map(+)))

        // Storage
        let disk = snapshot.disk
        vitals.append(Vital(
            id: "disk", title: "Storage", symbol: "internaldrive",
            value: Format.rate(disk.readBytesPerSecond + disk.writeBytesPerSecond),
            detail: disk.capacity > 0
                ? "\(Format.percent(disk.fractionUsed)) of \(Format.diskBytes(disk.capacity)) used"
                : "R \(Format.rate(disk.readBytesPerSecond))  W \(Format.rate(disk.writeBytesPerSecond))",
            accent: Palette.disk,
            tint: disk.capacity > 0 && disk.fractionUsed > 0.9 ? Palette.critical : nil,
            trace: zip(history.diskRead.values(last: span), history.diskWrite.values(last: span)).map(+),
            metric: .disk))

        // Battery
        let battery = snapshot.battery
        if battery.present {
            var detail = battery.isCharging ? "charging" : battery.isPluggedIn ? "on power" : "on battery"
            if let remaining = battery.timeRemainingMinutes, remaining > 0 {
                detail += " · \(Format.minutes(remaining))"
            }
            vitals.append(Vital(
                id: "battery", title: "Battery", symbol: battery.isCharging ? "battery.100.bolt" : "battery.75",
                value: Format.percent(battery.percentage),
                detail: detail,
                accent: Palette.battery,
                tint: battery.percentage < 0.2 && !battery.isCharging ? Palette.critical : nil,
                level: battery.percentage, metric: .energy))
        }

        return vitals
    }

    /// A severity's colour, or nothing while the reading is calm.
    private static func warning(_ severity: Severity) -> Color? {
        severity == .calm ? nil : severity.swiftUIColor
    }
}

extension Severity: Comparable {
    private var rank: Int {
        switch self {
        case .calm: return 0
        case .elevated: return 1
        case .high: return 2
        case .critical: return 3
        }
    }

    public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rank < rhs.rank }
}

// MARK: - Strip

/// The row of headline tiles across the top of a window.
public struct VitalsStrip: View {
    public var vitals: [Vital]
    /// When the readings were taken — the instant a tile's click breaks down.
    public var timestamp: Date

    public init(vitals: [Vital], timestamp: Date) {
        self.vitals = vitals
        self.timestamp = timestamp
    }

    public init(snapshot: Snapshot, history: MetricsHistory, unit: TemperatureUnit, span: Int) {
        self.init(
            vitals: Vital.headline(snapshot: snapshot, history: history, unit: unit, span: span),
            timestamp: snapshot.processes.sampledAt > .distantPast
                ? snapshot.processes.sampledAt : snapshot.timestamp)
    }

    public var body: some View {
        BalancedRows(minimumWidth: 136, spacing: 10) {
            ForEach(vitals) { vital in
                VitalTile(vital: vital, timestamp: timestamp)
            }
        }
    }
}

/// Lays its children out in rows of equal-width cells, as few rows as fit and
/// each as full as the last: eight tiles in a width that holds seven become
/// four over four, never seven over one. A last row that comes up short —
/// seven as four over three — is justified, its cells widened to the edge,
/// rather than left with a hole at the end of it.
public struct BalancedRows: Layout {
    public var minimumWidth: CGFloat
    public var spacing: CGFloat

    public init(minimumWidth: CGFloat, spacing: CGFloat) {
        self.minimumWidth = minimumWidth
        self.spacing = spacing
    }

    private func columns(for width: CGFloat, count: Int) -> Int {
        guard count > 0 else { return 1 }
        let most = max(1, Int((width + spacing) / (minimumWidth + spacing)))
        let rows = Int((Double(count) / Double(most)).rounded(.up))
        return Int((Double(count) / Double(rows)).rounded(.up))
    }

    private func metrics(
        width: CGFloat, subviews: Subviews
    ) -> (columns: Int, cell: CGSize, rows: Int) {
        let columns = columns(for: width, count: subviews.count)
        let cellWidth = max(0, (width - CGFloat(columns - 1) * spacing) / CGFloat(columns))
        let height = subviews
            .map { $0.sizeThatFits(ProposedViewSize(width: cellWidth, height: nil)).height }
            .max() ?? 0
        let rows = Int((Double(subviews.count) / Double(columns)).rounded(.up))
        return (columns, CGSize(width: cellWidth, height: height), rows)
    }

    public func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let width = proposal.width
            ?? CGFloat(subviews.count) * (minimumWidth + spacing) - spacing
        let layout = metrics(width: width, subviews: subviews)
        return CGSize(
            width: width,
            height: CGFloat(layout.rows) * layout.cell.height
                + CGFloat(max(0, layout.rows - 1)) * spacing)
    }

    public func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        guard !subviews.isEmpty else { return }
        let layout = metrics(width: bounds.width, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            let column = index % layout.columns
            let row = index / layout.columns
            // How many cells this row actually holds: all of them, except
            // possibly in the last.
            let held = min(layout.columns, subviews.count - row * layout.columns)
            let width = max(0, (bounds.width - CGFloat(held - 1) * spacing) / CGFloat(held))
            subview.place(
                at: CGPoint(
                    x: bounds.minX + CGFloat(column) * (width + spacing),
                    y: bounds.minY + CGFloat(row) * (layout.cell.height + spacing)),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: width, height: layout.cell.height))
        }
    }
}

// MARK: - Tile

public struct VitalTile: View {
    public var vital: Vital
    public var timestamp: Date

    public init(vital: Vital, timestamp: Date) {
        self.vital = vital
        self.timestamp = timestamp
    }

    @Environment(\.inspectGraph) private var inspectGraph
    @State private var isHovering = false

    private static let corner: CGFloat = 13
    private static let traceHeight: CGFloat = 30

    private var isClickable: Bool { vital.metric != nil && inspectGraph.isAvailable }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: vital.symbol)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(vital.accent)
                    .frame(width: 20, height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(vital.accent.opacity(0.16)))
                Text(vital.title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .kerning(0.5)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }

            Text(vital.value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(vital.tint ?? Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
                .padding(.top, 8)

            Text(vital.detail.isEmpty ? " " : vital.detail)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .padding(.top, 1)

            Spacer(minLength: Self.traceHeight + 4)
        }
        .padding(.horizontal, 12)
        .padding(.top, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .bottom) {
            if let level = vital.level {
                LevelTrack(fraction: level, accent: vital.tint ?? vital.accent)
                    .frame(height: 6)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            } else {
                MiniTrace(values: vital.trace, range: vital.range, accent: vital.accent)
                    .frame(height: Self.traceHeight)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                .fill(Palette.cardBackground))
        .clipShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                .strokeBorder(
                    isHovering && isClickable ? vital.accent.opacity(0.55) : Palette.cardStroke,
                    lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { inside in
            isHovering = inside
            guard isClickable else { return }
            (inside ? NSCursor.pointingHand : NSCursor.arrow).set()
        }
        .onTapGesture {
            guard isClickable, let metric = vital.metric else { return }
            NSCursor.arrow.set()
            inspectGraph(metric, at: timestamp)
        }
        .help(isClickable ? "Click to see which processes are responsible" : "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(vital.title)
        .accessibilityValue("\(vital.value), \(vital.detail)")
        .accessibilityAddTraits(isClickable ? .isButton : [])
        .accessibilityAction {
            if isClickable, let metric = vital.metric { inspectGraph(metric, at: timestamp) }
        }
    }
}

/// A tile's history: a soft silhouette along its foot. Decoration with a job —
/// it says which way the number has been heading — so it is drawn faint,
/// carries no scale, and takes no part in hit-testing.
private struct MiniTrace: View {
    var values: [Double]
    var range: ClosedRange<Double>?
    var accent: Color

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            guard values.count > 1 else { return }
            let low = range?.lowerBound ?? 0
            let high = max(range?.upperBound ?? (values.max() ?? 1), low + 0.0001)
            let step = size.width / CGFloat(values.count - 1)
            // The top two points are the stroke's own room, so a trace pinned
            // at its ceiling is still a line and not a clipped edge.
            let usable = size.height - 2

            var line = Path()
            for (index, value) in values.enumerated() {
                let fraction = (min(max(value, low), high) - low) / (high - low)
                let point = CGPoint(
                    x: CGFloat(index) * step,
                    y: size.height - CGFloat(fraction) * usable)
                if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
            }

            var fill = line
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            fill.closeSubpath()

            context.fill(fill, with: .linearGradient(
                Gradient(colors: [accent.opacity(0.34), accent.opacity(0.10)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            context.stroke(line, with: .color(accent.opacity(0.95)), style: StrokeStyle(
                lineWidth: 1.3, lineCap: .round, lineJoin: .round))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct LevelTrack: View {
    var fraction: Double
    var accent: Color

    var body: some View {
        MiniBar(fraction: fraction, accent: accent, height: 6)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - Mascot

/// A mutable box for the mascot's clock, held in `@State` for its lifetime and
/// written from inside the render — advancing it must not invalidate anything.
private final class MascotClock {
    var last: Date?
    var time: Double = 0
    var load: Double = 0
    var primed = false
}

/// The character on duty, running in a window at the pace it runs in the menu
/// bar: the same drawing code, the same load-to-pace line, eased the same way.
///
/// Still under Reduce Motion or when the caller says so, in the same resting
/// pose the menu bar holds.
public struct RexMascot: View {
    public var visualizer: Visualizer
    /// 0...1 — what sets the pace.
    public var load: Double
    public var animated: Bool
    public var color: Color
    /// Multiples of the menu bar's own canvas.
    public var scale: CGFloat

    public init(
        visualizer: Visualizer, load: Double, animated: Bool = true,
        color: Color = Palette.cpu, scale: CGFloat = 1
    ) {
        self.visualizer = visualizer
        self.load = load
        self.animated = animated
        self.color = color
        self.scale = scale
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var clock = MascotClock()

    private static let frameRate = 30.0

    private var moves: Bool { animated && !reduceMotion }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1 / Self.frameRate, paused: !moves)) { timeline in
            Canvas { context, size in
                let frame = moves ? advance(to: timeline.date) : (Visualizer.restingTime, load)
                let ink = NSColor(color)
                context.withCGContext { cg in
                    cg.translateBy(x: 0, y: size.height)
                    cg.scaleBy(x: 1, y: -1)
                    visualizer.draw(
                        in: cg, rect: CGRect(origin: .zero, size: size),
                        time: frame.0, load: frame.1, color: ink)
                }
            }
        }
        .frame(
            width: Visualizer.canvasSize.width * scale,
            height: Visualizer.canvasSize.height * scale)
        .accessibilityHidden(true)
    }

    /// Eases the load towards the latest sample and advances the clock by the
    /// pace that load asks for, clamped to what this view's frame rate can
    /// show — the same pair of steps `StatusItemController.step` takes.
    private func advance(to date: Date) -> (Double, Double) {
        if !clock.primed {
            clock.primed = true
            clock.load = load
        }
        let delta = clock.last.map { min(0.25, max(0, date.timeIntervalSince($0))) } ?? 0
        clock.last = date
        clock.load += (load - clock.load) * (1 - exp(-delta / 0.6))
        let pace = min(
            visualizer.rate(forLoad: clock.load, speedFactor: 1),
            Self.frameRate / Visualizer.minimumFramesPerCycle)
        clock.time += pace * delta
        return (clock.time, clock.load)
    }
}

// MARK: - Columns

/// How many columns of cards a window of a given width shows.
public enum MonitorColumns {
    public static func count(for width: CGFloat) -> Int {
        // A column of cards reads well down to about 330 points — a third
        // wider than the popover's, whose two share 560.
        switch width {
        case ..<700: return 1
        case ..<1060: return 2
        default: return 3
        }
    }
}
