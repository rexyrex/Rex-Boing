import Foundation

/// Fixed-capacity ring buffer backing the sparklines. Appending is O(1) and
/// never allocates once the buffer has filled, which matters because the
/// dashboard reads these at up to 4 Hz.
struct RingBuffer {
    private(set) var storage: [Double]
    /// When each slot of `storage` was recorded, as a reference-date offset.
    /// Stored as a plain `Double` rather than a `Date` so a full buffer is two
    /// flat allocations that never need boxing on the sampler's hot path.
    private var times: [TimeInterval]
    private var head: Int = 0
    private(set) var count: Int = 0
    let capacity: Int

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        self.storage = Array(repeating: 0, count: self.capacity)
        self.times = Array(repeating: 0, count: self.capacity)
    }

    mutating func append(_ value: Double, at date: Date) {
        storage[head] = value
        times[head] = date.timeIntervalSinceReferenceDate
        head = (head + 1) % capacity
        count = Swift.min(count + 1, capacity)
    }

    /// Oldest-to-newest values.
    var values: [Double] { ordered(storage) }

    /// When each of `values` was sampled, same order and same length. Series
    /// that skip samples — the temperatures, when no sensor answered — would
    /// otherwise have no way to say which second a point belongs to.
    var timestamps: [Date] {
        ordered(times, transform: Date.init(timeIntervalSinceReferenceDate:))
    }

    private func ordered<T>(_ buffer: [T]) -> [T] {
        guard count > 0 else { return [] }
        var result: [T] = []
        result.reserveCapacity(count)
        if count < capacity {
            result.append(contentsOf: buffer[0..<count])
        } else {
            result.append(contentsOf: buffer[head..<capacity])
            result.append(contentsOf: buffer[0..<head])
        }
        return result
    }

    /// Ordered transformation in one allocation. Timestamps used to first
    /// materialise an ordered `[Double]` and then allocate a second `[Date]` on
    /// every graph refresh.
    private func ordered<T, U>(_ buffer: [T], transform: (T) -> U) -> [U] {
        guard count > 0 else { return [] }
        var result: [U] = []
        result.reserveCapacity(count)
        if count < capacity {
            for value in buffer[0..<count] { result.append(transform(value)) }
        } else {
            for value in buffer[head..<capacity] { result.append(transform(value)) }
            for value in buffer[0..<head] { result.append(transform(value)) }
        }
        return result
    }

    var latest: Double { count > 0 ? storage[(head + capacity - 1) % capacity] : 0 }

    /// Peak over the window, without materialising the ordered array.
    var maximum: Double {
        guard count > 0 else { return 0 }
        return storage.prefix(count == capacity ? capacity : count).max() ?? 0
    }
}

/// Rolling history for every series the dashboard graphs.
struct MetricsHistory {
    static let capacity = 90

    var cpu = RingBuffer(capacity: capacity)
    var cpuUser = RingBuffer(capacity: capacity)
    var cpuSystem = RingBuffer(capacity: capacity)
    var gpu = RingBuffer(capacity: capacity)
    var memory = RingBuffer(capacity: capacity)
    var swap = RingBuffer(capacity: capacity)
    var cpuTemp = RingBuffer(capacity: capacity)
    var gpuTemp = RingBuffer(capacity: capacity)
    var power = RingBuffer(capacity: capacity)
    /// Average active clock per cluster, MHz. Empty where IOReport did not
    /// resolve — Intel Macs — and the processor card hides the traces. What
    /// these buy is throttling made visible: a clock that sags while the die
    /// temperature peaks is evidence of the thing the OS pressure state only
    /// asserts.
    var eClock = RingBuffer(capacity: capacity)
    var pClock = RingBuffer(capacity: capacity)
    var networkRx = RingBuffer(capacity: capacity)
    var networkTx = RingBuffer(capacity: capacity)
    var diskRead = RingBuffer(capacity: capacity)
    var diskWrite = RingBuffer(capacity: capacity)

    mutating func record(_ snapshot: Snapshot) {
        let now = snapshot.timestamp
        cpu.append(snapshot.cpu.total, at: now)
        cpuUser.append(snapshot.cpu.user, at: now)
        cpuSystem.append(snapshot.cpu.system, at: now)
        gpu.append(snapshot.gpu.utilization, at: now)
        memory.append(snapshot.memory.fractionUsed, at: now)
        swap.append(snapshot.memory.swap.fraction, at: now)
        // Temperatures are only recorded when a sensor actually reported one.
        // Substituting a zero used to plant a spike at the bottom of the graph
        // that the view then had to filter back out — and filtering shortened
        // the series, which shifted the whole trace sideways.
        if let celsius = snapshot.thermal.cpuCelsius ?? snapshot.thermal.socCelsius {
            cpuTemp.append(celsius, at: now)
        }
        if let celsius = snapshot.thermal.gpuCelsius {
            gpuTemp.append(celsius, at: now)
        }
        // Same rule as the temperatures: after a wake or launch there can
        // briefly be no wattage source at all, and substituting a zero
        // planted a false 0 W notch at the left of every post-wake trace.
        // The series is whole-machine draw, not the SoC package — the graph
        // should answer "what is this Mac pulling", fans and display included.
        if let watts = snapshot.power.totalWatts {
            power.append(watts, at: now)
        }
        // Same skip-don't-zero rule as the temperatures: clocks exist only
        // where IOReport resolved, and a substituted zero would be a spike.
        if let megahertz = snapshot.cpu.efficiencyClockMHz {
            eClock.append(megahertz, at: now)
        }
        if let megahertz = snapshot.cpu.performanceClockMHz {
            pClock.append(megahertz, at: now)
        }
        networkRx.append(snapshot.network.rxBytesPerSecond, at: now)
        networkTx.append(snapshot.network.txBytesPerSecond, at: now)
        diskRead.append(snapshot.disk.readBytesPerSecond, at: now)
        diskWrite.append(snapshot.disk.writeBytesPerSecond, at: now)
    }
}
