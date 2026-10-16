import SwiftUI
import AppKit

/// Time frames the process card can rank over besides Live. Bounded above by
/// the ledger's retention — a day — and below by a span long enough that
/// accumulated work says something the live rows do not.
public enum UsageWindow: Double, CaseIterable, Identifiable, Sendable {
    case fiveMinutes = 300
    case twentyMinutes = 1200
    case oneHour = 3600
    case sixHours = 21_600
    case day = 86_400

    public var id: Double { rawValue }

    public var label: String {
        switch self {
        case .fiveMinutes: return "5m"
        case .twentyMinutes: return "20m"
        case .oneHour: return "1h"
        case .sixHours: return "6h"
        case .day: return "24h"
        }
    }

    public var spoken: String {
        switch self {
        case .fiveMinutes: return "the last 5 minutes"
        case .twentyMinutes: return "the last 20 minutes"
        case .oneHour: return "the last hour"
        case .sixHours: return "the last 6 hours"
        case .day: return "the last 24 hours"
        }
    }
}

/// Which apps used the most over a chosen window — the retrospective answer
/// the live table cannot give, drawn from the usage ledger. The process card
/// shows this in place of its live rows whenever a window is picked.
///
/// Work is shown as totals and window-averages: real joules, core-time,
/// bytes moved. The rankings therefore favour sustained use over a lucky
/// instant, which is the point of the windows.
public struct AppUsageList: View {
    /// The latest ledger answer, which may still be for the previous window
    /// for the instant after a switch — showing it beats flashing empty.
    public var report: AppUsageReport?
    public var window: UsageWindow
    public var metric: ProcessMetric
    public var rowCount: Int

    public var body: some View {
        let ranked = rankedApps
        let scale = max(ranked.first?.value ?? 1, .leastNonzeroMagnitude)

        if ranked.isEmpty {
            Text(emptyMessage)
                .metricLabel()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
        } else {
            VStack(spacing: 4) {
                ForEach(ranked) { app in
                    AppUsageRowView(
                        app: app,
                        windowLabel: window.spoken,
                        accent: metric.accent,
                        fraction: app.value / scale)
                }
            }
        }

        if let footnote {
            Text(footnote)
                .metricLabel()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Ranking

    private var rankedApps: [RankedApp] {
        guard let report, report.coveredSeconds > 0 else { return [] }
        let covered = report.coveredSeconds
        return report.rows
            .compactMap { row -> RankedApp? in
                let value = Self.value(of: row.totals, metric: metric, covered: covered)
                guard value > 0 else { return nil }
                return RankedApp(
                    attribution: row.attribution,
                    totals: row.totals,
                    value: value,
                    display: Self.display(of: row.totals, metric: metric, covered: covered),
                    covered: covered)
            }
            .sorted { $0.value > $1.value }
            .prefix(rowCount)
            .map { $0 }
    }

    /// The ranking scalar. Counters rank by total work; memory — a gauge — by
    /// its time-average, so an app that held two gigabytes for a minute does
    /// not outrank one that held one gigabyte all afternoon.
    private static func value(
        of totals: AppUsageTotals, metric: ProcessMetric, covered: Double
    ) -> Double {
        switch metric {
        case .cpu: return Double(totals.cpuNanos)
        case .memory: return Double(totals.memoryByteSeconds) / covered
        case .gpu: return Double(totals.gpuNanos)
        case .energy: return Double(totals.energyNanojoules)
        case .disk: return Double(totals.diskReadBytes) + Double(totals.diskWriteBytes)
        }
    }

    private static func display(
        of totals: AppUsageTotals, metric: ProcessMetric, covered: Double
    ) -> String {
        switch metric {
        case .cpu:
            // Average percent of one core over the window — the same
            // convention as the live rows, so the two read alike.
            return String(
                format: "%.1f%%", Double(totals.cpuNanos) / (covered * 1e9) * 100)
        case .memory:
            return Format.bytes(Double(totals.memoryByteSeconds) / covered)
        case .gpu:
            return String(
                format: "%.1f%%", Double(totals.gpuNanos) / (covered * 1e9) * 100)
        case .energy:
            return Format.energy(Double(totals.energyNanojoules) / 1e9)
        case .disk:
            return Format.bytes(
                Double(totals.diskReadBytes) + Double(totals.diskWriteBytes))
        }
    }

    // MARK: - Messages

    /// Shown only when the window was not fully observed, so a number diluted
    /// by sleep or a recent launch says so instead of just reading low.
    private var footnote: String? {
        guard let report, report.coveredSeconds > 0,
              report.coveredSeconds < window.rawValue * 0.95 else { return nil }
        return "Sampled \(Format.shortInterval(report.coveredSeconds)) of "
            + "\(window.spoken) — history accrues while Rex Boing runs."
    }

    private var emptyMessage: String {
        guard report != nil else { return "Reading the ledger…" }
        return "Nothing recorded in this window yet — history accrues while Rex Boing runs."
    }
}

/// One ranked app, resolved once per render pass so row views compare cheaply.
private struct RankedApp: Identifiable {
    public var id: String { attribution.key }
    public var attribution: AppAttribution
    public var totals: AppUsageTotals
    public var value: Double
    public var display: String
    public var covered: Double
}

private struct AppUsageRowView: View {
    public var app: RankedApp
    public var windowLabel: String
    public var accent: Color
    public var fraction: Double

    @State private var isHovering = false

    public var body: some View {
        HStack(spacing: 7) {
            Image(nsImage: AppUsageIconCache.shared.icon(for: app.attribution))
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 15, height: 15)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(app.attribution.displayName)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(app.display)
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
        .accessibilityLabel(
            "\(app.attribution.displayName), \(app.display) over \(windowLabel)")
        .contextMenu {
            Button("Copy App Name") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    app.attribution.displayName, forType: .string)
            }
            if let anchor = app.attribution.bundlePath ?? app.attribution.executablePath {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: anchor)])
                }
            }
        }
    }

    /// Every measure the row accumulated, whichever one it is ranked by.
    /// This is where the totals behind the headline number live — the card
    /// shows one figure, the hover shows the ledger row.
    private var tooltip: String {
        let totals = app.totals
        let covered = max(app.covered, 0.001)
        var lines = ["\(app.attribution.displayName) — over \(windowLabel)"]
        if totals.cpuNanos > 0 {
            lines.append(
                "CPU time: \(Format.shortInterval(Double(totals.cpuNanos) / 1e9))")
        }
        if totals.energyNanojoules > 0 {
            let joules = Double(totals.energyNanojoules) / 1e9
            lines.append(
                "Energy: \(Format.energy(joules)) · avg "
                + Format.averagePower(joules / covered))
        }
        if totals.gpuNanos > 0 {
            lines.append(
                "GPU time: \(Format.shortInterval(Double(totals.gpuNanos) / 1e9))")
        }
        if totals.diskReadBytes > 0 || totals.diskWriteBytes > 0 {
            lines.append(
                "Disk: \(Format.bytes(totals.diskReadBytes)) read · "
                + "\(Format.bytes(totals.diskWriteBytes)) written")
        }
        if totals.memoryByteSeconds > 0 {
            lines.append(
                "Memory: avg \(Format.bytes(Double(totals.memoryByteSeconds) / covered))"
                + " · peak \(Format.bytes(totals.peakMemoryBytes))")
        }
        if totals.wakeups > 0 {
            lines.append("Wakeups: \(Self.count(totals.wakeups))")
        }
        if let anchor = app.attribution.bundlePath ?? app.attribution.executablePath {
            lines.append(anchor)
        }
        return lines.joined(separator: "\n")
    }

    private static func count(_ value: UInt64) -> String {
        let scaled = Double(value)
        if scaled >= 999_500 { return String(format: "%.1fM", scaled / 1_000_000) }
        if scaled >= 9_995 { return String(format: "%.1fk", scaled / 1_000) }
        return "\(value)"
    }
}

/// Icon per attribution, memoised for the same reason the live rows' is:
/// `NSWorkspace.icon(forFile:)` hits the disk and rows re-render on every
/// fresh sample. Keyed by anchor path, so the two caches never fight.
@MainActor
private final class AppUsageIconCache {
    public static let shared = AppUsageIconCache()

    private var cache: [String: NSImage] = [:]
    private var order: [String] = []
    private let limit = 256
    private let fallback = NSWorkspace.shared.icon(for: .unixExecutable)

    public func icon(for attribution: AppAttribution) -> NSImage {
        guard let anchor = attribution.bundlePath ?? attribution.executablePath else {
            return fallback
        }
        if let cached = cache[anchor] { return cached }

        let icon = NSWorkspace.shared.icon(forFile: anchor)
        icon.size = NSSize(width: 32, height: 32)
        cache[anchor] = icon
        order.append(anchor)
        while order.count > limit {
            cache.removeValue(forKey: order.removeFirst())
        }
        return icon
    }
}
