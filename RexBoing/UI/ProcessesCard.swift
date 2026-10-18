import SwiftUI
import AppKit
import Darwin

/// What the process card ranks over: the newest process table, or the usage
/// ledger's account of a trailing window.
public enum ProcessSpan: Hashable, Identifiable, Sendable {
    case live
    case window(UsageWindow)

    public static let allCases: [ProcessSpan] = [.live] + UsageWindow.allCases.map { .window($0) }

    public var id: Self { self }

    public var label: String {
        switch self {
        case .live: return "Live"
        case .window(let window): return window.label
        }
    }
}

/// Top processes, switchable between CPU, GPU, memory, energy and disk I/O,
/// and between right now and a trailing window.
///
/// Live ranks individual processes on the newest sample — what is busy this
/// second, with a pid to quit. The windows rank apps on the work the usage
/// ledger accumulated, helpers folded into the app they belong to, which is
/// what answers "what has been draining the battery all afternoon". It is one
/// question asked over two time frames, so it is one card with one picker.
///
/// The GPU and disk tabs are the interesting ones: per-process GPU accounting
/// is not something menu bar monitors usually show, and the disk ranking is
/// the fastest answer to "what is hammering the SSD" — real device traffic,
/// not page-cache hits.
public struct ProcessesCard: View {
    /// How to ask the usage ledger about a trailing window — deliberately not
    /// an observed object. Refresh rides on the snapshot, handed down by value
    /// like every other card's data, so this card observes nothing either.
    /// Absent where no ledger exists (a remote machine), and then the card
    /// shows the live table alone.
    public var usage: AppUsageQuery?
    public var snapshot: Snapshot
    public var rowCount: Int

    public init(usage: AppUsageQuery?, snapshot: Snapshot, rowCount: Int) {
        self.usage = usage
        self.snapshot = snapshot
        self.rowCount = rowCount
    }

    @State private var metric: ProcessMetric = .cpu
    @State private var span: ProcessSpan = .live
    @State private var report: AppUsageReport?

    public var body: some View {
        Card(
            accent: metric.accent, title: "Top Processes", symbol: "list.bullet",
            trailing: trailing
        ) {
            Picker("Rank by", selection: $metric.animation(.easeInOut(duration: 0.15))) {
                ForEach(ProcessMetric.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .accessibilityLabel("Rank by")

            if usage != nil {
                Picker("Over", selection: $span.animation(.easeInOut(duration: 0.15))) {
                    ForEach(ProcessSpan.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel("Time frame")
            }

            switch span {
            case .live:
                LiveProcessList(
                    processes: snapshot.processes, metric: metric, rowCount: rowCount)
            case .window(let window):
                AppUsageList(
                    report: report, window: window, metric: metric, rowCount: rowCount)
            }
        }
        .onChange(of: span) { query() }
        // One re-query per fresh process table, not per engine tick: the
        // ledger only moves when a table lands, and the query answers from
        // memory on the sampler queue either way.
        .onChange(of: snapshot.processes.sampledAt) { query() }
    }

    /// Live reads the snapshot it was handed; only a window needs the ledger,
    /// so nothing is asked of it while Live is on show.
    private func query() {
        guard case .window(let window) = span, let usage else { return }
        usage.run(window.rawValue) { report = $0 }
    }

    private var trailing: String? {
        switch span {
        case .live:
            return "\(snapshot.processes.count) running"
        case .window:
            guard let report, !report.rows.isEmpty else { return nil }
            return "\(report.rows.count) apps"
        }
    }
}

/// How the process card queries the usage ledger: the trailing window in
/// seconds, and a completion delivered on the main actor.
public struct AppUsageQuery {
    public var run: @MainActor (
        _ window: TimeInterval,
        _ completion: @escaping @MainActor @Sendable (AppUsageReport) -> Void
    ) -> Void

    public init(
        _ run: @escaping @MainActor (
            _ window: TimeInterval,
            _ completion: @escaping @MainActor @Sendable (AppUsageReport) -> Void
        ) -> Void
    ) {
        self.run = run
    }
}

/// Whether the processes on screen belong to this Mac. Rows from another
/// machine can be copied, but not revealed in Finder, signalled or given this
/// Mac's icon for a path that only happens to exist here too.
public struct ProcessControl: Sendable {
    public var isLocal: Bool = true

    public init(isLocal: Bool = true) {
        self.isLocal = isLocal
    }
}

private struct ProcessControlKey: EnvironmentKey {
    public static let defaultValue = ProcessControl()
}

extension EnvironmentValues {
    public var processControl: ProcessControl {
        get { self[ProcessControlKey.self] }
        set { self[ProcessControlKey.self] = newValue }
    }
}

/// The newest process table, ranked.
private struct LiveProcessList: View {
    public var processes: ProcessMetrics
    public var metric: ProcessMetric
    public var rowCount: Int

    public var body: some View {
        // Ranking happens on the sampler queue, so this is a slice rather
        // than a sort, resolved once here and handed down — reading it from
        // the body per row is what made it expensive in the first place.
        let rows = Array(processes.top(by: metric, limit: rowCount))
        // Bars are scaled against the busiest row rather than an absolute
        // maximum, so the panel stays legible when everything is close to idle.
        let scale = max(rows.first.map { metric.value(of: $0) } ?? 1, 0.0001)

        if rows.isEmpty {
            Text(emptyMessage)
                .metricLabel()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
        } else {
            VStack(spacing: 4) {
                ForEach(rows) { row in
                    ProcessRowView(
                        row: row,
                        metric: metric,
                        accent: metric.accent,
                        fraction: metric.value(of: row) / scale)
                }
            }
        }
    }

    private var emptyMessage: String {
        if metric == .gpu && !processes.gpuAttributionAvailable {
            return "Per-process GPU usage is unavailable for this sample."
        }
        return "Nothing measurable in the last interval."
    }
}

private struct ProcessRowView: View {
    public var row: ProcessRow
    public var metric: ProcessMetric
    public var accent: Color
    public var fraction: Double

    @State private var isHovering = false

    public var body: some View {
        HStack(spacing: 7) {
            ProcessIcon(row: row)
                .frame(width: 15, height: 15)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(row.name)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(metric.format(row))
                        .metricValue(size: 11, weight: .semibold)
                        .foregroundStyle(accent)
                }
                MiniBar(fraction: fraction, accent: accent, height: 3)
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.primary.opacity(isHovering ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .help(tooltip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.name), \(metric.rawValue) \(metric.format(row))")
        .contextMenu { ProcessActions(row: row) }
    }

    private var tooltip: String {
        var text = "\(row.name) — pid \(row.pid)"
        if row.threadCount > 0 { text += ", \(row.threadCount) threads" }
        // The read/write split and the wakeups have no column of their own on
        // this card; the tooltip is where they wait for whoever wants them.
        if row.diskBytesPerSecond > 0 {
            text += "\ndisk: \(Format.rate(row.diskReadBytesPerSecond)) read · "
                + "\(Format.rate(row.diskWriteBytesPerSecond)) written"
        }
        if row.wakeupsPerSecond >= 0.05 {
            text += String(format: "\n%.1f wakeups/s", row.wakeupsPerSecond)
        }
        if let user = row.user { text += "\nuser: \(user)" }
        if let command = row.commandLine, !command.isEmpty {
            text += "\n\(command)"
        } else if let path = row.executablePath {
            text += "\n\(path)"
        }
        return text
    }
}

/// Right-click actions. Quitting is offered because the whole reason to look at
/// this list is usually to find something to stop, and bouncing out to Activity
/// Monitor to do it is a poor ending.
public struct ProcessActions: View {
    public var row: ProcessRow

    @Environment(\.processControl) private var control

    public init(row: ProcessRow) {
        self.row = row
    }

    public var body: some View {
        Button("Copy Process Name") { copy(row.name) }
        Button("Copy PID") { copy("\(row.pid)") }

        if let command = row.commandLine, !command.isEmpty {
            Button("Copy Command Line") { copy(command) }
        }

        if let path = row.executablePath {
            Divider()
            Button("Copy Path") { copy(path) }
            if control.isLocal {
                Button("Reveal in Finder") {
                    // An app's executable sits inside its bundle; revealing it
                    // would open Finder inside the package. Show the app, as
                    // the row's icon does.
                    let target = IconCache.outermostBundle(in: path) ?? path
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: target)])
                }
            }
        }

        if control.isLocal {
            Divider()
            Button("Quit") { terminate(force: false) }
            Button("Force Quit") { terminate(force: true) }
        }
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    /// Prefers the AppKit path for real apps, which lets them save state and
    /// prompt, and falls back to a signal for daemons and helpers. Neither can
    /// touch a process this user does not own — `kill` simply fails with EPERM.
    ///
    /// The identity check in front is not ceremony. These rows are also shown
    /// by the inspector, where one can be minutes old by the time it is
    /// right-clicked, and pids are recycled — a blind signal would eventually
    /// land on whatever innocent process had inherited the number.
    private func terminate(force: Bool) {
        guard let target = liveTarget else {
            NSSound.beep()
            return
        }
        // Delivery can fail — `kill` returns EPERM for root daemons and other
        // users' processes, roughly a third of the table — and silence there
        // reads as a click that did not register. The beep is the same answer
        // the identity check above gives for a row that is no longer live.
        let delivered: Bool
        switch target {
        case .app(let app):
            delivered = force ? app.forceTerminate() : app.terminate()
        case .process:
            delivered = kill(row.pid, force ? SIGKILL : SIGTERM) == 0
        }
        if !delivered { NSSound.beep() }
    }

    private enum LiveTarget {
        case app(NSRunningApplication)
        case process
    }

    /// The process this row named, if it is still the one holding that pid.
    private var liveTarget: LiveTarget? {
        // The path and bundle below are useful secondary checks, but they are
        // not identities: the same app can relaunch into a recycled pid. The
        // creation timestamp is what makes an old inspector row safe to act on.
        guard row.startTime > 0, currentStartTime == row.startTime else { return nil }

        if let app = NSRunningApplication(processIdentifier: row.pid) {
            // A recycled pid belonging to a *different* app fails here. One
            // that was not an app when the row was captured, and is now, fails
            // too — which is the right answer for the same reason.
            return app.bundleIdentifier == row.bundleIdentifier ? .app(app) : nil
        }
        // Without a path there is nothing to compare against, so there is no
        // way to be sure. Nothing is lost by refusing: a process whose path
        // could not be read is almost always one this user cannot signal.
        guard let path = row.executablePath else { return nil }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(row.pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let livePath = buffer.withUnsafeBytes { raw -> String in
            let bytes = raw.prefix(min(Int(length), raw.count)).prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        return livePath == path ? .process : nil
    }

    private var currentStartTime: UInt64? {
        var info = proc_taskallinfo()
        let size = Int32(MemoryLayout<proc_taskallinfo>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(row.pid, PROC_PIDTASKALLINFO, 0, $0, size)
        }
        guard result == size else { return nil }
        let seconds = UInt64(clamping: info.pbsd.pbi_start_tvsec)
        let microseconds = UInt64(clamping: info.pbsd.pbi_start_tvusec)
        let (scaled, multiplyOverflow) = seconds.multipliedReportingOverflow(by: 1_000_000)
        guard !multiplyOverflow else { return nil }
        let (timestamp, addOverflow) = scaled.addingReportingOverflow(microseconds)
        return addOverflow ? nil : timestamp
    }
}

/// App icon for a process, falling back to a generic executable icon.
///
/// `NSWorkspace.icon(forFile:)` hits the disk, so results are memoised — the
/// list re-renders several times a second while the dashboard is open.
public struct ProcessIcon: View {
    public var row: ProcessRow

    @Environment(\.processControl) private var control

    public var body: some View {
        Image(nsImage: control.isLocal ? IconCache.shared.icon(for: row) : IconCache.shared.genericIcon)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .accessibilityHidden(true)
    }
}

@MainActor
private final class IconCache {
    public static let shared = IconCache()

    private var cache: [String: NSImage] = [:]
    private var order: [String] = []
    private let limit = 256
    private let fallback = NSWorkspace.shared.icon(for: .unixExecutable)

    public var genericIcon: NSImage { fallback }

    public func icon(for row: ProcessRow) -> NSImage {
        guard let path = row.executablePath else { return fallback }
        if let cached = cache[path] { return cached }

        // Helper processes live well below the bundle they belong to — a
        // renderer might sit at `Foo.app/Contents/Frameworks/Foo Helper.app/
        // Contents/MacOS/Foo Helper`. Taking the *outermost* `.app` in the path
        // gets the icon a user would recognise, rather than a generic Mach-O
        // one or the helper's own blank icon.
        let icon = NSWorkspace.shared.icon(forFile: Self.outermostBundle(in: path) ?? path)
        icon.size = NSSize(width: 32, height: 32)

        cache[path] = icon
        order.append(path)
        // Evict oldest-first rather than clearing the lot: dropping every icon
        // at once means the next frame re-reads all of them from disk.
        while order.count > limit {
            cache.removeValue(forKey: order.removeFirst())
        }
        return icon
    }

    static func outermostBundle(in path: String) -> String? {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard let index = components.firstIndex(where: { $0.hasSuffix(".app") }) else {
            return nil
        }
        return components[...index].joined(separator: "/")
    }
}
