import Foundation

/// Identity an app's usage is filed under.
///
/// Keyed by the outermost `.app` bundle when the executable lives inside one,
/// so a browser's dozen renderer helpers land on the browser's row rather than
/// on a dozen of their own. Falls back to the executable path, and then to the
/// bare process name — which is all a GPU-only row (another user's process,
/// read off the IORegistry) has to offer. Keys carry a tier prefix so a name
/// can never collide with a path.
struct AppAttribution: Hashable, Sendable {
    var key: String
    var displayName: String
    /// Outermost bundle when known — the icon and Finder anchor.
    var bundlePath: String?
    /// A representative member executable, for rows without a bundle.
    var executablePath: String?
}

/// One app's work over one sample window, pre-aggregated across its member
/// processes by the sampler.
struct AppWorkDelta: Sendable {
    var attribution: AppAttribution
    var cpuNanos: UInt64 = 0
    var energyNanojoules: UInt64 = 0
    var gpuNanos: UInt64 = 0
    var diskReadBytes: UInt64 = 0
    var diskWriteBytes: UInt64 = 0
    var wakeups: UInt64 = 0
    /// Instantaneous physical footprint summed over member processes — a
    /// gauge, unlike everything above, so the ledger integrates it over time
    /// rather than summing it across samples.
    var memoryBytes: UInt64 = 0

    /// Whether this sample earns a ledger entry.
    ///
    /// The floors bound what a day of buckets retains: without them every
    /// process that woke a timer once lands in every minute, and the ring
    /// grows several-fold for rows that could never place in any ranking.
    /// Work below them cannot move one either — a millisecond of CPU per
    /// six-second sample is ~0.02% of a core. Wakeups deliberately grant no
    /// entry of their own: nearly every process has a few, and they are kept
    /// as colour for rows that qualified on real work.
    var isMeasurable: Bool {
        cpuNanos >= 1_000_000
            || energyNanojoules >= 1_000_000
            || gpuNanos >= 1_000_000
            || diskReadBytes &+ diskWriteBytes >= 65_536
            || memoryBytes >= 33_554_432
    }
}

/// One app's accumulated work over a span.
struct AppUsageTotals: Sendable {
    var cpuNanos: UInt64 = 0
    var energyNanojoules: UInt64 = 0
    var gpuNanos: UInt64 = 0
    var diskReadBytes: UInt64 = 0
    var diskWriteBytes: UInt64 = 0
    var wakeups: UInt64 = 0
    /// Time-integral of footprint (byte·seconds). Divide by the report's
    /// covered seconds for the average the row displays.
    var memoryByteSeconds: UInt64 = 0
    var peakMemoryBytes: UInt64 = 0

    mutating func add(_ delta: AppWorkDelta, interval: TimeInterval) {
        cpuNanos.addSaturating(delta.cpuNanos)
        energyNanojoules.addSaturating(delta.energyNanojoules)
        gpuNanos.addSaturating(delta.gpuNanos)
        diskReadBytes.addSaturating(delta.diskReadBytes)
        diskWriteBytes.addSaturating(delta.diskWriteBytes)
        wakeups.addSaturating(delta.wakeups)
        let byteSeconds = Double(delta.memoryBytes) * max(0, interval)
        memoryByteSeconds.addSaturating(
            byteSeconds >= Double(UInt64.max) ? .max : UInt64(byteSeconds))
        peakMemoryBytes = max(peakMemoryBytes, delta.memoryBytes)
    }

    mutating func merge(_ other: AppUsageTotals) {
        cpuNanos.addSaturating(other.cpuNanos)
        energyNanojoules.addSaturating(other.energyNanojoules)
        gpuNanos.addSaturating(other.gpuNanos)
        diskReadBytes.addSaturating(other.diskReadBytes)
        diskWriteBytes.addSaturating(other.diskWriteBytes)
        wakeups.addSaturating(other.wakeups)
        memoryByteSeconds.addSaturating(other.memoryByteSeconds)
        peakMemoryBytes = max(peakMemoryBytes, other.peakMemoryBytes)
    }
}

struct AppUsageRow: Identifiable, Sendable {
    var id: String { attribution.key }
    var attribution: AppAttribution
    var totals: AppUsageTotals
}

struct AppUsageReport: Sendable {
    /// The window that was asked for, in seconds.
    var window: TimeInterval
    /// Seconds of that window actually observed by plausible sample intervals.
    /// Sleep, launch gaps and discarded windows all surface here rather than
    /// silently deflating every figure below.
    var coveredSeconds: Double = 0
    /// Start of the oldest recorded bucket inside the window, when any exist —
    /// what lets the card say history begins mid-window instead of implying a
    /// freshly launched app has been watching all along.
    var earliestData: Date?
    /// Unranked; each consumer ranks by the metric it is showing.
    var rows: [AppUsageRow] = []
}

/// Rolling, bucketed account of which app did how much work, kept far enough
/// back to answer "who used the most X over the last N minutes".
///
/// macOS keeps no per-app history an app can ask for after the fact, so the
/// only way to answer that question is to have been recording all along. The
/// ledger accumulates *work* — cpu-nanoseconds, nanojoules, bytes — not rates:
/// summed deltas of cumulative counters are exact over any span regardless of
/// sampling cadence, where averaged rate snapshots would weight a six-second
/// idle interval the same as a busy one-second one, and could only ever see
/// the rows that had made a leaderboard.
///
/// Confined to the engine's serial sampler queue with the same by-construction
/// contract as the sampler core; queries hop through that queue too, so there
/// is no locking here. Everything lives in memory: history starts at launch
/// and costs no disk.
final class UsageLedger {
    /// One minute per bucket, a day of them. Windows quantise to the minute —
    /// far finer than the questions the ledger exists to answer — and the ring
    /// never reallocates.
    static let bucketWidth: TimeInterval = 60
    static let bucketCount = 1440

    private struct Entry {
        var id: Int32
        var totals: AppUsageTotals
    }

    private struct Bucket {
        /// Absolute minute index since the epoch; -1 while the slot is empty.
        /// The stamp, not the slot position, is what a query trusts — a slot
        /// still holding yesterday's minute simply fails the cutoff.
        var stamp: Int64 = -1
        var coveredSeconds: Double = 0
        var entries: [Entry] = []
    }

    private var buckets = [Bucket](repeating: Bucket(), count: UsageLedger.bucketCount)
    /// Bumped on every ring mutation, so a cached ring scan can tell whether
    /// it is still describing the buckets as they stand.
    private var flushGeneration: UInt64 = 0

    /// The minute being accumulated, kept as a dictionary while it is hot and
    /// compacted into the ring when the minute rolls over.
    private var currentStamp: Int64 = -1
    private var currentCovered: Double = 0
    private var current: [Int32: AppUsageTotals] = [:]

    /// Attribution interning. A day of buckets holds the same few dozen apps
    /// over and over; four bytes per entry instead of three strings is most of
    /// the difference between a ledger that costs megabytes and one that
    /// costs tens of them. The tables grow by distinct app, not by time —
    /// a few hundred entries on an ordinary machine, swept only if a workload
    /// of uniquely-pathed binaries pushes them past `internPruneThreshold`.
    private var ids: [String: Int32] = [:]
    private var attributions: [Int32: AppAttribution] = [:]
    /// Monotonic id source. Deliberately not `ids.count`: pruning shrinks the
    /// table, and a count-derived id would then collide with a live one.
    private var nextID: Int32 = 0

    /// Folds one sample's deltas into the minute containing `date`.
    ///
    /// `interval` is the sample's plausible window, which the caller has
    /// already vetted — implausible windows (sleep, clock steps) never reach
    /// the ledger, they just leave coverage behind. An empty delta list still
    /// records: an idle machine was observed idle, and that observation is
    /// exactly what keeps the coverage figure honest.
    func record(_ deltas: [AppWorkDelta], endingAt date: Date, interval: TimeInterval) {
        let stamp = Int64((date.timeIntervalSince1970 / Self.bucketWidth).rounded(.down))
        if stamp != currentStamp {
            flushCurrent()
            currentStamp = stamp
            // A clock rollback can revisit a flushed minute. Move its earlier
            // work back into the hot bucket immediately: reports exclude the
            // current stamp from the ring, so leaving it there hides that work
            // until the next rollover.
            if stamp >= 0 {
                let index = Int(stamp % Int64(Self.bucketCount))
                if buckets[index].stamp == stamp {
                    current = Dictionary(uniqueKeysWithValues:
                        buckets[index].entries.map { ($0.id, $0.totals) })
                    currentCovered = buckets[index].coveredSeconds
                    buckets[index] = Bucket()
                    flushGeneration &+= 1
                }
            }
        }
        currentCovered += max(0, interval)

        for delta in deltas {
            let id = internID(for: delta.attribution)
            var totals = current[id] ?? AppUsageTotals()
            totals.add(delta, interval: interval)
            current[id] = totals
        }
    }

    /// Everything recorded inside the trailing `window`, current minute
    /// included. The window is quantised outward to whole buckets, so the
    /// oldest minute may be partially outside it — up to one bucket width of
    /// slack on a question asked in tens of minutes.
    func report(window: TimeInterval, now: Date = Date()) -> AppUsageReport {
        var report = AppUsageReport(window: window)
        let nowSeconds = now.timeIntervalSince1970
        let cutoff = Int64(((nowSeconds - window) / Self.bucketWidth).rounded(.down))
        let nowStamp = Int64((nowSeconds / Self.bucketWidth).rounded(.down))

        // The ring's contribution changes only when a minute is flushed or the
        // window's bucket bounds move — once a minute, not once a query. The
        // dashboard re-queries on every fresh process table, and folding all
        // 1440 buckets each time put a 24-hour scan on the sampler queue at
        // the process cadence; the memo reduces that to one scan per minute
        // plus a fold of the small in-progress dictionary per query.
        let key = RingScanKey(
            window: window, cutoff: cutoff, nowStamp: nowStamp,
            currentStamp: currentStamp, flushGeneration: flushGeneration)
        let ring: RingScan
        if let cached = cachedRingScan, cached.key == key {
            ring = cached.scan
        } else {
            ring = scanRing(cutoff: cutoff, nowStamp: nowStamp)
            cachedRingScan = (key, ring)
        }

        var merged = ring.merged
        var covered = ring.covered
        var earliest = ring.earliest

        if currentStamp >= cutoff, currentStamp <= nowStamp {
            covered += min(currentCovered, Self.bucketWidth)
            earliest = min(earliest, currentStamp)
            for (id, totals) in current {
                var folded = merged[id] ?? AppUsageTotals()
                folded.merge(totals)
                merged[id] = folded
            }
        }

        report.coveredSeconds = min(covered, window)
        if earliest != .max {
            report.earliestData = Date(
                timeIntervalSince1970: Double(earliest) * Self.bucketWidth)
        }
        report.rows = merged.map { id, totals in
            AppUsageRow(
                attribution: attributions[id] ?? AppAttribution(
                    key: "unknown:\(id)", displayName: "Unknown",
                    bundlePath: nil, executablePath: nil),
                totals: totals)
        }
        return report
    }

    private struct RingScanKey: Equatable {
        var window: TimeInterval
        var cutoff: Int64
        var nowStamp: Int64
        var currentStamp: Int64
        var flushGeneration: UInt64
    }

    private struct RingScan {
        var merged: [Int32: AppUsageTotals] = [:]
        var covered: Double = 0
        var earliest = Int64.max
    }

    private var cachedRingScan: (key: RingScanKey, scan: RingScan)?

    private func scanRing(cutoff: Int64, nowStamp: Int64) -> RingScan {
        var scan = RingScan()
        // The active minute lives in `current`; revisited buckets are moved
        // there by record(), so the ring contains only other minutes.
        for bucket in buckets
        where bucket.stamp >= 0 && bucket.stamp != currentStamp {
            guard bucket.stamp >= cutoff, bucket.stamp <= nowStamp else { continue }
            scan.covered += min(bucket.coveredSeconds, Self.bucketWidth)
            scan.earliest = min(scan.earliest, bucket.stamp)
            for entry in bucket.entries {
                var totals = scan.merged[entry.id] ?? AppUsageTotals()
                totals.merge(entry.totals)
                scan.merged[entry.id] = totals
            }
        }
        return scan
    }

    private func flushCurrent() {
        guard currentStamp >= 0 else { return }
        let index = Int(currentStamp % Int64(Self.bucketCount))
        let entries = current.map { Entry(id: $0.key, totals: $0.value) }
        buckets[index] = Bucket(
            stamp: currentStamp,
            coveredSeconds: currentCovered,
            entries: entries)
        flushGeneration &+= 1
        current.removeAll(keepingCapacity: true)
        currentCovered = 0
        pruneInternTablesIfNeeded()
    }

    /// Attribution keys carry full executable paths, so a workload that runs
    /// uniquely-pathed binaries all day — per-build test binaries, sandboxed
    /// toolchains — interns a new entry each time while the buckets that
    /// referenced it age out after a day. Swept only past a threshold no
    /// ordinary machine approaches, and only of ids no bucket references.
    private static let internPruneThreshold = 4096

    private func pruneInternTablesIfNeeded() {
        guard ids.count > Self.internPruneThreshold else { return }
        var live = Set<Int32>(minimumCapacity: ids.count)
        for bucket in buckets where bucket.stamp >= 0 {
            for entry in bucket.entries { live.insert(entry.id) }
        }
        for id in current.keys { live.insert(id) }
        attributions = attributions.filter { live.contains($0.key) }
        ids = ids.filter { live.contains($0.value) }
    }

    private func internID(for attribution: AppAttribution) -> Int32 {
        if let id = ids[attribution.key] { return id }
        let id = nextID
        nextID &+= 1
        ids[attribution.key] = id
        attributions[id] = attribution
        return id
    }
}

extension UInt64 {
    /// The counters here saturate rather than trap or wrap: one absurd reading
    /// upstream should pin a figure at the ceiling, not take the app down or
    /// lap back to a small, plausible-looking lie.
    mutating func addSaturating(_ other: UInt64) {
        let (sum, overflow) = addingReportingOverflow(other)
        self = overflow ? .max : sum
    }
}
