import SwiftUI
import AppKit

// `KeyPathComparator` is `Sendable`, and its initializer consequently requires
// a sendable key path under complete concurrency checking. Key paths are
// immutable, but the standard library does not yet declare that conformance.
// Constrain it to sendable roots and values so the table's sort descriptors can
// cross SwiftUI's internal isolation boundary without disabling checks for the
// rest of the app.
extension KeyPath: @retroactive @unchecked Sendable
where Root: Sendable, Value: Sendable {}

/// The window opened by clicking a graph: who was using the machine at that
/// instant, ranked, with every measure side by side.
///
/// The dashboard's own process card answers "what is busy now, by one measure
/// at a time". This answers the question the graphs actually provoke — *that*
/// spike, two minutes ago, what was that? — which needs a moment in the past
/// and all the columns at once.
struct ProcessInspectorView: View {
    @ObservedObject var history: ProcessHistory
    /// The instant the user clicked. Cleared once they scrub, at which point
    /// the window is showing the sample they chose and has nothing to disclaim.
    @State private var requested: Date?

    /// Which resource the window is leading with. Seeded from the graph that
    /// was clicked, then the user's to change — going back to the dashboard and
    /// clicking a different trace to answer the same question about the same
    /// instant is a lot of work for a different sort key.
    @State private var metric: ProcessMetric

    @State private var selection: Date
    @State private var sortOrder: [KeyPathComparator<ProcessRow>]
    /// Whether to ride the newest sample as it arrives. Set while the selection
    /// is the latest one, so a window left open keeps up rather than freezing
    /// on the moment it was opened.
    @State private var follow: Bool

    init(history: ProcessHistory, metric: ProcessMetric, requested: Date) {
        self.history = history
        _metric = State(initialValue: metric)
        _requested = State(initialValue: requested)
        _selection = State(initialValue: requested)
        _sortOrder = State(initialValue: Self.sort(by: metric))
        _follow = State(initialValue: false)
    }

    private var current: (index: Int, sample: ProcessSample, offset: TimeInterval)? {
        history.nearest(to: selection)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let current {
                scrubber(index: current.index)
                Divider()
                table(rows: current.sample.rows, sample: current.sample)
            } else {
                empty
            }
        }
        // Sized so the nine columns' minimum widths all fit without the last
        // ones collapsing behind a horizontal scroll.
        .frame(minWidth: 700, minHeight: 340)
        // Switching resource re-ranks the list by the thing being looked at.
        // Any column the user then clicks still wins until they switch again.
        .onChange(of: metric) { _, new in sortOrder = Self.sort(by: new) }
        // Turning Live on means "show me now", so it jumps straight to the
        // newest sample rather than sitting on a stale one until the next
        // arrives. Both here and below, following retires `requested`: the
        // window is riding the stream, not showing the clicked instant, and
        // the "after the point you clicked" disclaimer would otherwise count
        // upward without bound.
        .onChange(of: follow) { _, isOn in
            guard isOn else { return }
            if let last = history.samples.last { selection = last.timestamp }
            requested = nil
        }
        .onReceive(history.$samples) { samples in
            guard follow, let last = samples.last else { return }
            selection = last.timestamp
            requested = nil
        }
        .onAppear { alignToNearestSample() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Picker("Resource", selection: $metric.animation(.easeInOut(duration: 0.15))) {
                    ForEach(ProcessMetric.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Resource to break down")

                Spacer(minLength: 8)

                if let current, current.sample.processCount > 0 {
                    Text("\(current.sample.processCount) running")
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 9) {
                // The headline the rows are shares of. Recorded rather than
                // summed: per-process CPU is a percentage of one core and the
                // system figure is a fraction of all of them, so adding the
                // list up does not produce this number.
                Text(total.value)
                    .font(.system(size: 26, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(metric.accent)
                    .contentTransition(.numericText())
                    .help(totalExplanation)

                VStack(alignment: .leading, spacing: 1) {
                    Text(total.caption)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 8)

                if let current {
                    Text(Format.clock(current.sample.timestamp))
                        .font(.system(size: 13))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 9)
    }

    /// Why the column below does not add up to the number above it.
    ///
    /// The gap is real and has three parts, and a reader who notices it
    /// deserves the arithmetic rather than being left to assume something is
    /// broken. It is the same relationship Activity Monitor's %CPU column has
    /// with its CPU Load graph.
    private var totalExplanation: String {
        switch metric {
        case .cpu:
            let cores = max(1, HostInfo.current.logicalCores)
            return """
                CPU load across all \(cores) cores.

                The rows below will not add up to it: each row is a percentage \
                of one core, so a process using \(cores) cores fully reads \
                \(cores * 100)%. Divide the column by \(cores) to compare. \
                The rest is kernel and interrupt time, which belongs to no \
                process, plus any process too quiet to be ranked.
                """
        case .gpu:
            return """
                Overall GPU device utilisation.

                Rows below are each process's share of GPU wall time. They can \
                overlap and will not sum exactly to the device figure.
                """
        case .memory:
            return """
                Memory in use system-wide: app, wired and compressed.

                Rows below are each process's physical footprint. Shared and \
                cached pages are counted differently, so they will not sum to \
                the total.
                """
        case .energy:
            return """
                Whole-machine power draw — SoC, display, fans and the rest of \
                the board, from the best source this Mac publishes.

                Rows below are Rex Boing's own energy-impact estimate, a relative \
                figure rather than watts, so they do not sum to this.
                """
        case .disk:
            return """
                Whole-machine disk throughput, reads and writes together, \
                measured at the storage drivers.

                Rows below are each process's real disk I/O — traffic that \
                reached the device, so reads served from memory do not count. \
                Kernel-originated I/O belongs to no process, so the column \
                will not sum exactly to this.
                """
        }
    }

    /// The system-wide reading for the selected resource, in whatever unit that
    /// resource is actually measured in — power is watts, not a percentage of
    /// anything, and pretending otherwise would invent a denominator.
    private var total: (value: String, caption: String) {
        guard let sample = current?.sample else { return ("—", metric.rawValue) }
        let totals = sample.totals

        switch metric {
        case .cpu:
            return (Format.percent(totals.cpuFraction, decimals: 1), "CPU load, all cores")
        case .gpu:
            guard totals.gpuAvailable else { return ("—", "GPU utilisation unavailable") }
            return (Format.percent(totals.gpuFraction, decimals: 1), "GPU utilisation")
        case .memory:
            let caption = totals.memoryTotalBytes > 0
                ? "\(Format.bytes(totals.memoryUsedBytes)) of "
                    + "\(Format.bytes(totals.memoryTotalBytes)) used"
                : "memory used"
            return (Format.percent(totals.memoryFraction, decimals: 1), caption)
        case .energy:
            guard let watts = totals.watts else { return ("—", "power draw unavailable") }
            return (Format.watts(watts), "system power draw")
        case .disk:
            let rate = totals.diskReadBytesPerSecond + totals.diskWriteBytesPerSecond
            return (Format.rate(rate), "disk read + write")
        }
    }

    /// Says plainly which instant is on screen relative to the one that was
    /// clicked. The process table is sampled less often than the graphs are —
    /// roughly every six seconds while nothing is watching — so the two can genuinely
    /// differ, and a window that quietly showed a different moment than the one
    /// pointed at would be worse than one that owns up to it.
    private var subtitle: String {
        guard let current else { return "No samples retained yet." }

        var parts: [String] = []
        if let requested {
            let offset = abs(current.sample.timestamp.timeIntervalSince(requested))
            if offset >= 0.5 {
                let direction = current.sample.timestamp < requested ? "before" : "after"
                parts.append(
                    "nearest sample, \(Format.shortInterval(offset)) \(direction) "
                        + "the point you clicked")
            }
        }
        parts.append("measured over \(Format.shortInterval(current.sample.interval))")
        if !current.sample.gpuAttributionAvailable {
            parts.append("no GPU attribution")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Scrubber

    /// A click lands within a couple of points of its neighbours — ninety
    /// samples across a graph a few inches wide — so the instant the window
    /// opens on is approximate by construction. This is how the user says which
    /// one they actually meant.
    private func scrubber(index: Int) -> some View {
        HStack(spacing: 10) {
            Button {
                step(by: -1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(index == 0)
            .keyboardShortcut(.leftArrow, modifiers: [])
            .help("Earlier sample")

            Slider(
                value: Binding(
                    get: { Double(index) },
                    set: { select(index: Int($0.rounded())) }),
                in: 0...Double(max(1, history.samples.count - 1)),
                step: 1)
            .disabled(history.samples.count < 2)
            .labelsHidden()

            Button {
                step(by: 1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(index >= history.samples.count - 1)
            .keyboardShortcut(.rightArrow, modifiers: [])
            .help("Later sample")

            Toggle("Live", isOn: $follow)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("Follow the newest sample as it arrives")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    private func step(by delta: Int) {
        guard let current else { return }
        select(index: current.index + delta)
    }

    private func select(index: Int) {
        guard history.samples.indices.contains(index) else { return }
        selection = history.samples[index].timestamp
        // The window no longer owes an explanation once the moment on screen is
        // one the user picked themselves.
        requested = nil
        follow = index == history.samples.count - 1
    }

    /// Ranks the table by whichever resource is on show, busiest first.
    private static func sort(by metric: ProcessMetric) -> [KeyPathComparator<ProcessRow>] {
        switch metric {
        case .cpu: return [KeyPathComparator(\ProcessRow.cpuPercent, order: .reverse)]
        case .memory: return [KeyPathComparator(\ProcessRow.memoryBytes, order: .reverse)]
        case .gpu: return [KeyPathComparator(\ProcessRow.gpuPercent, order: .reverse)]
        case .energy: return [KeyPathComparator(\ProcessRow.energyImpact, order: .reverse)]
        case .disk:
            return [KeyPathComparator(\ProcessRow.diskBytesPerSecond, order: .reverse)]
        }
    }

    /// Snaps the initial selection onto a real sample, so the slider and the
    /// arrow keys start from a position that exists.
    private func alignToNearestSample() {
        guard let current else { return }
        selection = current.sample.timestamp
        follow = current.index == history.samples.count - 1
    }

    // MARK: - Table

    private func table(rows: [ProcessRow], sample: ProcessSample) -> some View {
        Table(rows.sorted(using: sortOrder), sortOrder: $sortOrder) {
            TableColumn("Process", value: \.name) { row in
                HStack(spacing: 6) {
                    ProcessIcon(row: row)
                        .frame(width: 16, height: 16)
                    Text(row.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .help(tooltip(for: row))
                .contextMenu { ProcessActions(row: row) }
            }
            .width(min: 140, ideal: 200)

            TableColumn("CPU", value: \.cpuPercent) { row in
                numeric(String(format: "%.1f%%", row.cpuPercent),
                        tint: row.cpuPercent > 0 ? Palette.cpu : nil)
            }
            .width(min: 58, ideal: 70)

            TableColumn("GPU", value: \.gpuPercent) { row in
                numeric(
                    sample.gpuAttributionAvailable
                        ? String(format: "%.1f%%", row.gpuPercent) : "—",
                    tint: row.gpuPercent > 0 ? Palette.gpu : nil)
            }
            .width(min: 58, ideal: 70)

            TableColumn("Memory", value: \.memoryBytes) { row in
                numeric(Format.bytes(row.memoryBytes),
                        tint: row.memoryBytes > 0 ? Palette.memory : nil)
            }
            .width(min: 68, ideal: 82)

            TableColumn("Disk", value: \.diskBytesPerSecond) { row in
                numeric(Format.rate(row.diskBytesPerSecond),
                        tint: row.diskBytesPerSecond > 0 ? Palette.disk : nil)
            }
            .width(min: 70, ideal: 84)

            TableColumn("Energy", value: \.energyImpact) { row in
                numeric(String(format: "%.1f", row.energyImpact),
                        tint: row.energyImpact > 0 ? Palette.power : nil)
            }
            .width(min: 58, ideal: 70)

            // Wakeups ride the energy column rather than getting a tab of
            // their own: they are the *why* behind a surprising energy figure,
            // not a resource with a system-wide total to break down.
            TableColumn("Wakes/s", value: \.wakeupsPerSecond) { row in
                numeric(Self.wakeups(row.wakeupsPerSecond), tint: nil)
            }
            .width(min: 56, ideal: 64)

            TableColumn("Threads", value: \.threadCount) { row in
                numeric("\(row.threadCount)", tint: nil)
            }
            .width(min: 54, ideal: 62)

            TableColumn("PID", value: \.pid) { row in
                numeric("\(row.pid)", tint: nil)
            }
            .width(min: 54, ideal: 62)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
    }

    private func numeric(_ text: String, tint: Color?) -> some View {
        Text(text)
            .monospacedDigit()
            .foregroundStyle(tint ?? .secondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// One decimal while wakeups are scarce — half a wakeup a second is a real
    /// reading over a six-second window — whole numbers once they are not.
    private static func wakeups(_ perSecond: Double) -> String {
        perSecond >= 9.95
            ? String(format: "%.0f", perSecond)
            : String(format: "%.1f", perSecond)
    }

    private func tooltip(for row: ProcessRow) -> String {
        var text = "\(row.name) — pid \(row.pid)"
        if let bundle = row.bundleIdentifier { text += "\n\(bundle)" }
        if let path = row.executablePath { text += "\n\(path)" }
        return text
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock.badge.questionmark")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text("No process samples retained yet.")
                .font(.system(size: 12))
            Text("Leave Rex Boing running for a few seconds and try again.")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Window

/// Hosts the inspector in a single reusable window.
///
/// One window, not one per graph: clicking a second graph retargets this one
/// rather than stacking another, which is what a user comparing two traces
/// expects and what keeps the live-sampling balance simple.
@MainActor
final class ProcessInspectorWindowController: NSObject, NSWindowDelegate {
    static let shared = ProcessInspectorWindowController()

    private var window: NSWindow?
    private var engine: MetricsEngine?
    /// Whether this window is currently holding process sampling at full rate.
    private var holdingSampling = false

    func show(engine: MetricsEngine, metric: ProcessMetric, at date: Date) {
        self.engine = engine
        NSApp.activate(ignoringOtherApps: true)

        // The popover that owns the graph is transient and closes the moment
        // this window takes focus, which would drop process sampling back to
        // its background cadence. Claim it before that happens.
        if !holdingSampling {
            engine.beginLiveProcessSampling()
            holdingSampling = true
        }

        let hosting = NSHostingController(
            rootView: ProcessInspectorView(
                history: engine.processHistory, metric: metric, requested: date)
                .environmentObject(Preferences.shared))

        if let window {
            // Replacing the root view rather than mutating the old one: the
            // selection is `@State` seeded from the clicked instant, and a new
            // click means a new instant. Assigning a fresh controller resizes
            // the window to the new view's fitting size — the SwiftUI minimum
            // — so the frame the user chose has to be put back afterwards.
            let frame = window.frame
            window.contentViewController = hosting
            window.setFrame(frame, display: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        // The title stays put while the resource picker moves, because the
        // window is about the instant, not the column — naming a resource here
        // would go stale the first time the user switched tab.
        let window = NSWindow(contentViewController: hosting)
        window.title = "Process Breakdown"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 900, height: 460))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)

        self.window = window
    }

    func windowWillClose(_ notification: Notification) {
        // The window itself is kept for reuse, but its SwiftUI content must
        // not be: a hosting view keeps observing `ProcessHistory` for as long
        // as it exists, so a closed-but-retained inspector would re-evaluate
        // its table on every process sample forever. `show` builds a fresh
        // controller anyway.
        window?.contentViewController = nil
        guard holdingSampling else { return }
        holdingSampling = false
        engine?.endLiveProcessSampling()
    }
}
