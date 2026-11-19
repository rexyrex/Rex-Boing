import Foundation

/// The graph series again, one bucket a minute for a day: mean, minimum and
/// maximum per minute, so "how hot did it get this afternoon?" has an
/// answer after the ten-minute rings have long since wrapped.
///
/// Fed from exactly the samples `MetricsHistory` records, with the same
/// skip-don't-zero rules, so a resync sample (sleep, launch, clock step) never
/// lands here either, and a minute in which nothing was sampled (the display
/// asleep, the machine asleep, the app not yet running) simply has no bucket
/// rather than a zero.
///
/// Recording is a handful of arithmetic operations per series into storage
/// allocated once: a slot is the minute's index modulo a day, and the stamp
/// on it, not its position, is what a query trusts. A slot still holding
/// yesterday's minute fails the window test; a clock that steps back into a
/// minute already recorded adds to it rather than corrupting a neighbour.
/// Memory only, like everything else the app keeps: about 400 KB, never
/// written anywhere.
///
/// A separate value from `MetricsHistory` on purpose: the cards hold copies of
/// that one, and a day of buckets inside it would be copied on the next
/// record whenever a view still held the old value.
public struct MinuteHistory: Sendable {
    public enum Series: Int, CaseIterable, Sendable {
        case cpu, cpuUser, cpuSystem, gpu, memory, swap, cpuTemp, gpuTemp, power
        case eClock, pClock, networkRx, networkTx, diskRead, diskWrite
    }

    public static let bucketWidth: TimeInterval = 60
    public static let capacity = 1440

    private static let seriesCount = Series.allCases.count

    /// Absolute minute since the epoch per slot; -1 while empty.
    private var stamps: [Int64]
    private var counts: [UInt16]
    /// Sums in double precision, so a minute's mean is the exact mean of its
    /// samples; extremes need no more than single precision.
    private var sums: [Double]
    private var minima: [Float]
    private var maxima: [Float]

    public init() {
        let cells = Self.capacity * Self.seriesCount
        stamps = Array(repeating: -1, count: Self.capacity)
        counts = Array(repeating: 0, count: cells)
        sums = Array(repeating: 0, count: cells)
        minima = Array(repeating: 0, count: cells)
        maxima = Array(repeating: 0, count: cells)
    }

    public struct Bucket: Sendable, Equatable {
        /// The start of the minute.
        public var start: Date
        public var count: Int
        public var sum: Double
        public var minimum: Double
        public var maximum: Double

        public var mean: Double { count > 0 ? sum / Double(count) : 0 }
    }

    /// The same readings `MetricsHistory.record` takes, under the same rules:
    /// fractions stay fractions, and a reading with no source is not counted.
    public mutating func record(_ snapshot: Snapshot) {
        let minute = (snapshot.timestamp.timeIntervalSince1970 / Self.bucketWidth).rounded(.down)
        guard minute.isFinite, minute >= 0 else { return }
        let stamp = Int64(minute)
        let slot = Int(stamp % Int64(Self.capacity))
        if stamps[slot] != stamp {
            stamps[slot] = stamp
            let base = slot * Self.seriesCount
            for cell in base..<(base + Self.seriesCount) { counts[cell] = 0 }
        }

        add(snapshot.cpu.total, .cpu, slot)
        add(snapshot.cpu.user, .cpuUser, slot)
        add(snapshot.cpu.system, .cpuSystem, slot)
        add(snapshot.gpu.utilization, .gpu, slot)
        add(snapshot.memory.fractionUsed, .memory, slot)
        add(snapshot.memory.swap.fraction, .swap, slot)
        add(snapshot.thermal.cpuCelsius ?? snapshot.thermal.socCelsius, .cpuTemp, slot)
        add(snapshot.thermal.gpuCelsius, .gpuTemp, slot)
        add(snapshot.power.totalWatts, .power, slot)
        add(snapshot.cpu.efficiencyClockMHz, .eClock, slot)
        add(snapshot.cpu.performanceClockMHz, .pClock, slot)
        add(snapshot.network.rxBytesPerSecond, .networkRx, slot)
        add(snapshot.network.txBytesPerSecond, .networkTx, slot)
        add(snapshot.disk.readBytesPerSecond, .diskRead, slot)
        add(snapshot.disk.writeBytesPerSecond, .diskWrite, slot)
    }

    private mutating func add(_ value: Double?, _ series: Series, _ slot: Int) {
        guard let value, value.isFinite else { return }
        let cell = slot * Self.seriesCount + series.rawValue
        let count = counts[cell]
        if count == 0 {
            counts[cell] = 1
            sums[cell] = value
            minima[cell] = Float(value)
            maxima[cell] = Float(value)
            return
        }
        // A minute holds 120 samples at the fastest refresh; only a clock
        // that keeps stepping back into it could fill a counter. Stop
        // counting rather than wrap and misstate the mean.
        guard count < .max else { return }
        counts[cell] = count + 1
        sums[cell] += value
        let narrow = Float(value)
        if narrow < minima[cell] { minima[cell] = narrow }
        if narrow > maxima[cell] { maxima[cell] = narrow }
    }

    /// The minutes of `series` that overlap `from...through`, oldest first.
    /// Minutes with no reading of that series are absent, never zero.
    public func buckets(_ series: Series, from: Date, through: Date) -> [Bucket] {
        let first = Int64((from.timeIntervalSince1970 / Self.bucketWidth).rounded(.down))
        let last = Int64((through.timeIntervalSince1970 / Self.bucketWidth).rounded(.down))
        guard last >= first else { return [] }
        var found: [(Int64, Int)] = []
        for (slot, stamp) in stamps.enumerated() where stamp >= first && stamp <= last {
            let cell = slot * Self.seriesCount + series.rawValue
            if counts[cell] > 0 { found.append((stamp, cell)) }
        }
        found.sort { $0.0 < $1.0 }
        return found.map { stamp, cell in
            Bucket(
                start: Date(timeIntervalSince1970: Double(stamp) * Self.bucketWidth),
                count: Int(counts[cell]), sum: sums[cell],
                minimum: Double(minima[cell]), maximum: Double(maxima[cell]))
        }
    }

    /// The oldest and newest minutes holding any reading, and how many do.
    public var coverage: (oldest: Date, newest: Date, minutes: Int)? {
        var oldest = Int64.max
        var newest = Int64.min
        var minutes = 0
        for (slot, stamp) in stamps.enumerated() where stamp >= 0 {
            let base = slot * Self.seriesCount
            guard counts[base..<(base + Self.seriesCount)].contains(where: { $0 > 0 }) else { continue }
            oldest = min(oldest, stamp)
            newest = max(newest, stamp)
            minutes += 1
        }
        guard minutes > 0 else { return nil }
        return (Date(timeIntervalSince1970: Double(oldest) * Self.bucketWidth),
                Date(timeIntervalSince1970: Double(newest) * Self.bucketWidth), minutes)
    }
}
