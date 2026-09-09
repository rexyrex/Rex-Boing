import SwiftUI
import AppKit
import Darwin

/// Top processes, switchable between CPU, GPU, memory, energy and disk I/O.
///
/// The GPU and disk tabs are the interesting ones: per-process GPU accounting
/// is not something menu bar monitors usually show, and the disk ranking is
/// the fastest answer to "what is hammering the SSD" — real device traffic,
/// not page-cache hits.
struct ProcessesCard: View {
    var snapshot: Snapshot
    var rowCount: Int

    @State private var metric: ProcessMetric = .cpu

    /// Ranking happens on the sampler queue, so this is a slice rather than a
    /// sort. Resolved once here and handed down, because reading it from the
    /// view body per row is what made it expensive in the first place.
    private var rows: [ProcessRow] {
        Array(snapshot.processes.top(by: metric, limit: rowCount))
    }

    private var accent: Color { metric.accent }

    var body: some View {
        let rows = self.rows
        // Bars are scaled against the busiest row rather than an absolute
        // maximum, so the panel stays legible when everything is close to idle.
        let scale = max(rows.first.map { metric.value(of: $0) } ?? 1, 0.0001)

        Card(
            accent: accent, title: "Top Processes", symbol: "list.bullet",
            trailing: "\(snapshot.processes.count) running"
        ) {
            Picker("Rank by", selection: $metric.animation(.easeInOut(duration: 0.15))) {
                ForEach(ProcessMetric.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .accessibilityLabel("Rank processes by")

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
                            accent: accent,
                            fraction: metric.value(of: row) / scale)
                    }
                }
            }
        }
    }

    private var emptyMessage: String {
        if metric == .gpu && !snapshot.processes.gpuAttributionAvailable {
            return "Per-process GPU usage is unavailable for this sample."
        }
        return "Nothing measurable in the last interval."
    }
}

private struct ProcessRowView: View {
    var row: ProcessRow
    var metric: ProcessMetric
    var accent: Color
    var fraction: Double

    @State private var isHovering = false

    var body: some View {
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
        if let path = row.executablePath { text += "\n\(path)" }
        return text
    }
}

/// Right-click actions. Quitting is offered because the whole reason to look at
/// this list is usually to find something to stop, and bouncing out to Activity
/// Monitor to do it is a poor ending.
struct ProcessActions: View {
    var row: ProcessRow

    var body: some View {
        Button("Copy Process Name") { copy(row.name) }
        Button("Copy PID") { copy("\(row.pid)") }

        if let path = row.executablePath {
            Divider()
            Button("Copy Path") { copy(path) }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        }

        Divider()
        Button("Quit") { terminate(force: false) }
        Button("Force Quit") { terminate(force: true) }
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
struct ProcessIcon: View {
    var row: ProcessRow

    var body: some View {
        Image(nsImage: IconCache.shared.icon(for: row))
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .accessibilityHidden(true)
    }
}

@MainActor
private final class IconCache {
    static let shared = IconCache()

    private var cache: [String: NSImage] = [:]
    private var order: [String] = []
    private let limit = 256
    private let fallback = NSWorkspace.shared.icon(for: .unixExecutable)

    func icon(for row: ProcessRow) -> NSImage {
        guard let path = row.executablePath else { return fallback }
        if let cached = cache[path] { return cached }

        // Helper processes live well below the bundle they belong to — a
        // renderer might sit at `Foo.app/Contents/Frameworks/Foo Helper.app/
        // Contents/MacOS/Foo Helper`. Taking the *outermost* `.app` in the path
        // gets the icon a user would recognise, rather than a generic Mach-O
        // one or the helper's own blank icon.
        let icon = NSWorkspace.shared.icon(forFile: outermostBundle(in: path) ?? path)
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

    private func outermostBundle(in path: String) -> String? {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard let index = components.firstIndex(where: { $0.hasSuffix(".app") }) else {
            return nil
        }
        return components[...index].joined(separator: "/")
    }
}
