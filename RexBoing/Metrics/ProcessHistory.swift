import Foundation

/// What the machine as a whole was doing at a sampled instant.
///
/// Kept beside the process rows because the rows alone cannot be added up into
/// it: per-process CPU is a percentage of *one* core and routinely exceeds 100,
/// while the system figure is a fraction of all of them. The total has to be
/// recorded, not derived.
struct SystemTotals {
    /// 0...1 across all cores.
    var cpuFraction: Double = 0
    /// 0...1 device utilisation, meaningful only when `gpuAvailable`.
    var gpuFraction: Double = 0
    var gpuAvailable: Bool = false
    var memoryFraction: Double = 0
    var memoryUsedBytes: UInt64 = 0
    var memoryTotalBytes: UInt64 = 0
    /// Package draw where the SoC reports it, otherwise system draw at the
    /// battery. `nil` on hardware that publishes neither.
    var watts: Double?
    /// Whole-machine disk throughput at the same instant, from the storage
    /// drivers — the total the per-process disk column is a share of.
    var diskReadBytesPerSecond: Double = 0
    var diskWriteBytesPerSecond: Double = 0

    init() {}

    init(_ snapshot: Snapshot) {
        cpuFraction = snapshot.cpu.total
        gpuFraction = snapshot.gpu.utilization
        gpuAvailable = snapshot.gpu.available
        memoryFraction = snapshot.memory.fractionUsed
        memoryUsedBytes = snapshot.memory.used
        memoryTotalBytes = snapshot.memory.total
        watts = snapshot.power.totalWatts
        diskReadBytesPerSecond = snapshot.disk.readBytesPerSecond
        diskWriteBytesPerSecond = snapshot.disk.writeBytesPerSecond
    }
}

/// One instant's ranked process table, kept so the inspector can answer what
/// was running when — not just what is running now.
struct ProcessSample: Identifiable {
    var id: Date { timestamp }
    var timestamp: Date
    /// The window the deltas in `rows` were measured over. Worth showing: a
    /// reading averaged over six idle seconds means something different from
    /// one averaged over the second you were watching.
    var interval: TimeInterval
    /// Every process that placed in any of the rankings, CPU-first.
    var rows: [ProcessRow]
    /// False when the IORegistry walk found no Metal clients, so the GPU column
    /// can say "unavailable" rather than imply everything was idle.
    var gpuAttributionAvailable: Bool
    /// Total process count at that instant, for the window's subtitle.
    var processCount: Int
    /// System-wide readings at the same instant, so the window can lead with
    /// the total the rows below it are shares of.
    var totals: SystemTotals
}

/// Rolling window of ranked process tables, parallel to `MetricsHistory`.
///
/// A reference type with its own `objectWillChange`, rather than another field
/// on the engine's published `MetricsHistory`, so that recording a table does
/// not invalidate the dashboard's cards. Only the inspector observes this, and
/// the inspector is usually not open.
///
/// The cost of keeping it is close to nothing. The expensive part of a process
/// sample — a `proc_pidinfo` and a `proc_pid_rusage` for each of a thousand
/// processes, plus a recursive IORegistry walk — is already paid on every
/// sample and, until now, thrown away a tick later. What is added here is
/// retaining the ranked rows that pass had already produced.
@MainActor
final class ProcessHistory: ObservableObject {
    /// Matched to `MetricsHistory.capacity` so the inspector can reach back at
    /// least as far as the graph that opens it. In practice it reaches much
    /// further: while the dashboard is closed the process table is sampled
    /// roughly every six seconds rather than every tick, so the same number of slots
    /// covers minutes rather than a minute and a half.
    static let capacity = MetricsHistory.capacity

    @Published private(set) var samples: [ProcessSample] = []

    /// A window longer than this is treated as spanning a sleep or a clock
    /// step. The background cadence is roughly six seconds, so anything approaching a
    /// minute is not a sampling interval that happened — it is one the machine
    /// was away for, and averaging a process's CPU across it produces a number
    /// that belongs to no moment the graph shows.
    private static let plausibleInterval: TimeInterval = 30

    /// Takes the whole snapshot rather than just its process table, because the
    /// system-wide totals belong to the same instant and cannot be recovered
    /// from the rows afterwards.
    func record(_ snapshot: Snapshot) {
        let metrics = snapshot.processes

        // A fresh table dated *before* the last recorded one can only mean the
        // wall clock stepped backwards — `sampledAt` is otherwise monotonic.
        // Without winding the mark back, every table would be rejected as
        // already-recorded until wall time re-passed the old mark: a ten-minute
        // backwards step would freeze the inspector for ten minutes.
        if metrics.sampledAt > .distantPast, metrics.sampledAt < lastRecorded {
            // Discard the overlapping old timeline so binary search and the
            // inspector's live/latest selection remain chronological. Keep
            // the mark below this sample so a valid first reading survives.
            samples.removeAll { $0.timestamp >= metrics.sampledAt }
            lastRecorded = samples.last?.timestamp ?? .distantPast
        }

        // The same table is re-attached to every snapshot between process
        // samples, so most calls here are a table that is already recorded.
        guard metrics.sampledAt > lastRecorded else { return }
        guard metrics.interval > 0, metrics.interval <= Self.plausibleInterval else {
            // Still advance the mark: the window was unusable, but leaving it
            // behind would make the next tick re-test the same rejected table.
            lastRecorded = metrics.sampledAt
            return
        }

        lastRecorded = metrics.sampledAt
        samples.append(ProcessSample(
            timestamp: metrics.sampledAt,
            interval: metrics.interval,
            rows: metrics.rankedUnion(),
            gpuAttributionAvailable: metrics.gpuAttributionAvailable,
            processCount: metrics.count,
            totals: SystemTotals(snapshot)))

        if samples.count > Self.capacity {
            samples.removeFirst(samples.count - Self.capacity)
        }
    }

    private var lastRecorded: Date = .distantPast

    // MARK: - Lookup

    /// The retained sample nearest a point in time, and how far off it is.
    ///
    /// Returns the distance as well as the sample because the two can differ by
    /// seconds — the graph is sampled several times more often than the process
    /// table is when nobody is watching — and a window that silently showed the
    /// wrong instant would be worse than one that admits which instant it has.
    func nearest(to date: Date) -> (index: Int, sample: ProcessSample, offset: TimeInterval)? {
        guard !samples.isEmpty else { return nil }

        // Timestamps are appended in order, so this is a binary search for the
        // first sample at or after `date`; the answer is that one or the one
        // before it.
        var low = 0
        var high = samples.count
        while low < high {
            let middle = (low + high) / 2
            if samples[middle].timestamp < date { low = middle + 1 } else { high = middle }
        }

        let candidates = [low - 1, low].filter { samples.indices.contains($0) }
        guard let index = candidates.min(by: {
            abs(samples[$0].timestamp.timeIntervalSince(date))
                < abs(samples[$1].timestamp.timeIntervalSince(date))
        }) else { return nil }

        return (index, samples[index], samples[index].timestamp.timeIntervalSince(date))
    }
}
