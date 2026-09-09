import Foundation

// MARK: - CPU

enum CoreKind: String {
    case efficiency = "E"
    case performance = "P"
    case unknown = "?"

    var description: String {
        switch self {
        case .efficiency: return "efficiency core"
        case .performance: return "performance core"
        case .unknown: return "core"
        }
    }
}

struct CPUMetrics {
    /// 0...1 — the fraction of wall time all cores spent doing non-idle work.
    var total: Double = 0
    var user: Double = 0
    var system: Double = 0
    var idle: Double = 1
    var nice: Double = 0

    /// 0...1 per logical core, in hardware order (efficiency cores first on Apple silicon).
    var perCore: [Double] = []
    var coreKinds: [CoreKind] = []

    /// Average active clock in MHz per cluster kind, derived from DVFS residency.
    var efficiencyClockMHz: Double?
    var performanceClockMHz: Double?

    var loadAverage: (one: Double, five: Double, fifteen: Double) = (0, 0, 0)
    var processCount: Int = 0
    var threadCount: Int = 0

    /// Cluster averages. Stored rather than derived: the dashboard reads these
    /// on every render, and zip/filter/map over the core array allocated three
    /// throwaway arrays each time.
    var efficiencyLoad: Double = 0
    var performanceLoad: Double = 0
}

// MARK: - Memory

enum MemoryPressureLevel: Int, Comparable {
    case normal = 1
    case warning = 2
    case critical = 4

    var label: String {
        switch self {
        case .normal: return "Normal"
        case .warning: return "Warning"
        case .critical: return "Critical"
        }
    }

    static func < (lhs: MemoryPressureLevel, rhs: MemoryPressureLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct SwapMetrics {
    var total: UInt64 = 0
    var used: UInt64 = 0
    var free: UInt64 = 0
    var encrypted: Bool = false
    /// Pages moved to/from the swap file since boot.
    var ins: UInt64 = 0
    var outs: UInt64 = 0
    /// Rate of change, bytes per second, over the last sample interval.
    var inRate: Double = 0
    var outRate: Double = 0

    var fraction: Double {
        total > 0 ? min(1, Double(used) / Double(total)) : 0
    }
}

struct MemoryMetrics {
    var total: UInt64 = 0
    var free: UInt64 = 0
    var active: UInt64 = 0
    var inactive: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var speculative: UInt64 = 0
    var purgeable: UInt64 = 0
    var fileBacked: UInt64 = 0

    /// Matches Activity Monitor's "Memory Used": app + wired + compressed.
    var used: UInt64 = 0
    /// Activity Monitor's "App Memory".
    var app: UInt64 = 0
    /// Activity Monitor's "Cached Files".
    var cached: UInt64 = 0

    /// 0...1, from the kernel's own pressure metric — not simply used/total.
    var pressure: Double = 0
    var pressureLevel: MemoryPressureLevel = .normal

    var swap = SwapMetrics()

    var fractionUsed: Double {
        total > 0 ? min(1, Double(used) / Double(total)) : 0
    }
}

// MARK: - GPU

struct GPUMetrics {
    var name: String = "GPU"
    var coreCount: Int?
    /// 0...1 overall device utilisation.
    var utilization: Double = 0
    var rendererUtilization: Double = 0
    var tilerUtilization: Double = 0
    /// Bytes of memory currently mapped by the GPU driver.
    var inUseMemory: UInt64 = 0
    /// Bytes the driver has reserved. Zero where the accelerator does not
    /// report it — a discrete card publishes VRAM capacity instead, which is a
    /// different quantity and is carried in `totalMemory`.
    var allocatedMemory: UInt64 = 0
    /// Physical VRAM, discrete cards only.
    var totalMemory: UInt64 = 0
    var clockMHz: Double?
    var available: Bool = false
}

// MARK: - Thermals

enum SensorCategory: String, CaseIterable {
    case cpu = "CPU"
    case gpu = "GPU"
    case soc = "SoC"
    case memory = "Memory"
    case storage = "Storage"
    case battery = "Battery"
    case power = "Power"
    case ambient = "Ambient"
    case other = "Other"

    var sortOrder: Int {
        switch self {
        case .cpu: return 0
        case .gpu: return 1
        case .soc: return 2
        case .memory: return 3
        case .storage: return 4
        case .battery: return 5
        case .power: return 6
        case .ambient: return 7
        case .other: return 8
        }
    }
}

struct TempSensor: Identifiable {
    var id: String { key }
    var key: String
    var label: String
    /// Degrees Celsius.
    var celsius: Double
    var category: SensorCategory
}

struct Fan: Identifiable {
    var id: Int { index }
    var index: Int
    var rpm: Double
    var minRPM: Double
    var maxRPM: Double

    var fraction: Double {
        let span = maxRPM - minRPM
        guard span > 0 else { return 0 }
        return min(1, max(0, (rpm - minRPM) / span))
    }
}

struct ThermalMetrics {
    var sensors: [TempSensor] = []
    var fans: [Fan] = []

    /// `sensors` grouped and sorted for the expandable list, built once per
    /// sample instead of being re-filtered and re-sorted on every render.
    var groups: [SensorGroup] = []

    var cpuCelsius: Double?
    var gpuCelsius: Double?
    var socCelsius: Double?
    var batteryCelsius: Double?
    var storageCelsius: Double?

    /// The OS-reported pressure level, which is what actually drives throttling.
    var thermalState: ProcessInfo.ThermalState = .nominal

    /// Hottest sensor anywhere on the die — the headline number.
    ///
    /// Stored rather than derived from `sensors`, because between full passes
    /// only a subset of sensors carries a fresh reading and a peak taken over
    /// the stale majority would be wrong. The sampler computes this from
    /// whatever it just read.
    var peakCelsius: Double?
}

struct SensorGroup: Identifiable {
    var id: String { category.rawValue }
    var category: SensorCategory
    var sensors: [TempSensor]
}

// MARK: - Power

struct PowerMetrics {
    var cpuWatts: Double?
    var gpuWatts: Double?
    var aneWatts: Double?
    /// CPU + GPU + Neural Engine + DRAM. The SoC publishes several further
    /// rails (memory controller, ISP, media engines), but this combination is
    /// the one other tools report, so it is the one that can be checked.
    var packageWatts: Double?
    /// System-wide draw measured at the battery, `nil` unless discharging.
    var systemWatts: Double?
    /// Whole-machine draw from the SMC's system rail — display, SSD, fans and
    /// the rest of the board included, unlike `packageWatts`, and measured on
    /// mains as well as on battery, unlike `systemWatts`.
    var systemTotalWatts: Double?
    /// Live draw at the DC-in port while on mains, charging included.
    var dcInWatts: Double?
    var adapterWatts: Double?

    /// The figure to headline and graph: whole-machine power from the best
    /// source this Mac has. The SoC package is the last resort — a partial
    /// figure beats an empty graph on a Mac with neither a system rail nor
    /// battery telemetry.
    var totalWatts: Double? { systemTotalWatts ?? systemWatts ?? packageWatts }

    var hasAny: Bool {
        cpuWatts != nil || gpuWatts != nil || aneWatts != nil
            || packageWatts != nil || systemWatts != nil
            || systemTotalWatts != nil || dcInWatts != nil || adapterWatts != nil
    }
}

// MARK: - Battery

struct BatteryMetrics {
    var present: Bool = false
    var percentage: Double = 0
    var isCharging: Bool = false
    var isPluggedIn: Bool = false
    var timeRemainingMinutes: Int?
    var cycleCount: Int?
    var designCapacity: Int?
    var maxCapacity: Int?
    var celsius: Double?
    var voltage: Double?
    var amperage: Double?
    var condition: String?
    /// Instantaneous whole-machine draw, derived from cell voltage × current.
    /// Only meaningful while discharging, and `nil` otherwise.
    var systemWatts: Double?
    /// Power flowing into the cell, `nil` unless actually charging.
    var chargingWatts: Double?
    /// The connected charger's rated output, if one is attached.
    var adapterWatts: Double?

    var healthFraction: Double? {
        guard let design = designCapacity, let maximum = maxCapacity, design > 0 else { return nil }
        return Double(maximum) / Double(design)
    }
}

// MARK: - Sleep assertions

/// One process holding a power assertion against sleep — the answer to "why
/// won't it sleep". A display assertion keeps the screen on, which holds the
/// system up with it; a system assertion lets the screen sleep but not the
/// machine.
struct SleepBlocker: Identifiable {
    var id: Int32 { pid }
    var pid: Int32
    var name: String
    var preventsDisplaySleep: Bool = false
    var preventsSystemSleep: Bool = false
    /// The names the process gave its assertions — "Video Wake Lock",
    /// "com.apple.audio.context…" — often more legible than the process name.
    var assertionNames: [String] = []
}

struct SleepMetrics {
    /// Display blockers first, then alphabetical, so the list does not
    /// reshuffle between samples.
    var blockers: [SleepBlocker] = []
    /// False until the first successful read, so the card can tell "nothing is
    /// holding sleep" apart from "not sampled yet".
    var sampled: Bool = false
}

// MARK: - Network & disk

struct NetworkMetrics {
    var rxBytesPerSecond: Double = 0
    var txBytesPerSecond: Double = 0
    /// Bytes since Rex Boing launched. The underlying counters are 64-bit, but a
    /// since-boot aggregate is not recoverable across interfaces that have
    /// disappeared; this one is accumulated from per-interface deltas and is
    /// exact for the life of the process.
    var rxTotal: UInt64 = 0
    var txTotal: UInt64 = 0
    var primaryInterface: String?
    var localAddress: String?
}

struct DiskMetrics {
    var readBytesPerSecond: Double = 0
    var writeBytesPerSecond: Double = 0
    /// Bytes since Rex Boing launched, summed across drives present at the time.
    var readTotal: UInt64 = 0
    var writeTotal: UInt64 = 0
    var volumeName: String = "Macintosh HD"
    var capacity: UInt64 = 0
    var available: UInt64 = 0

    var used: UInt64 { capacity > available ? capacity - available : 0 }
    var fractionUsed: Double {
        capacity > 0 ? min(1, Double(used) / Double(capacity)) : 0
    }
}

// MARK: - Processes

struct ProcessRow: Identifiable, Hashable, Sendable {
    var id: Int32 { pid }
    var pid: Int32
    var name: String
    /// Process creation time in microseconds since the Unix epoch. A pid alone
    /// is not an identity: the kernel can recycle it while a retained history
    /// row is still on screen.
    var startTime: UInt64 = 0
    var bundleIdentifier: String?
    var executablePath: String?
    /// Percent of a single core, so this can exceed 100 on multi-threaded work.
    var cpuPercent: Double = 0
    var memoryBytes: UInt64 = 0
    /// Percent of GPU wall time consumed over the sample interval.
    var gpuPercent: Double = 0
    var energyImpact: Double = 0
    /// Bytes per second of real disk I/O over the sample interval — traffic
    /// that reached the device, so reads served from the page cache do not
    /// count. Deltas of cumulative rusage counters, the same way CPU is.
    var diskReadBytesPerSecond: Double = 0
    var diskWriteBytesPerSecond: Double = 0
    /// Thread wakeups per second — timers and interrupts pulling this
    /// process's threads out of a wait. The classic energy-bug tell: a 100 Hz
    /// polling timer reads as 100 here while costing almost no CPU percent.
    var wakeupsPerSecond: Double = 0
    var threadCount: Int = 0

    /// Reads and writes together — what the disk ranking ranks by.
    var diskBytesPerSecond: Double { diskReadBytesPerSecond + diskWriteBytesPerSecond }

    // Equality is deliberately the synthesized memberwise one. SwiftUI decides
    // whether to re-render a row by comparing the row values it was given, and
    // a pid-only `==` told it that a process whose readings had all changed was
    // the same row — so the top-ranked process, whose bar fraction is pinned at
    // 1.0, kept its first-render numbers for as long as it stayed on top.
    // Identity for ForEach/Table is still the pid, via `Identifiable`.
}

struct ProcessMetrics {
    /// How deep each per-metric ranking goes.
    ///
    /// Deeper than the dashboard card can show (`Preferences.processRowCount`
    /// stops at 12) because the inspector retains these rankings and lists them
    /// side by side, where a dozen rows runs out too quickly. The ranking pass
    /// is a single scan with an early-out per row, so the extra depth costs
    /// nothing measurable.
    static let leaderboardDepth = 20

    var count: Int = 0
    var gpuAttributionAvailable: Bool = false

    /// When this table was taken, and the window its deltas were measured over.
    ///
    /// The process table is sampled on its own cadence and re-attached to every
    /// snapshot in between, so a snapshot's own timestamp says nothing about
    /// how old the process rows on it are. History uses this to record each
    /// table once, and to recognise a window that spans a sleep.
    var sampledAt: Date = .distantPast
    var interval: TimeInterval = 0

    /// Ranked rows per metric, resolved on the sampler queue.
    ///
    /// The dashboard used to sort the full process table — several hundred rows
    /// — inside a computed property that the view body touched once per row,
    /// which meant a dozen full sorts on the main thread every second. Ranking
    /// happens once, off the main thread, and the view slices the result.
    var leaders: [ProcessMetric: [ProcessRow]] = [:]

    func top(by metric: ProcessMetric, limit: Int) -> ArraySlice<ProcessRow> {
        (leaders[metric] ?? []).prefix(limit)
    }

    /// Every process that placed in any of the rankings, once each.
    ///
    /// This is what the inspector retains. The lists overlap heavily — a
    /// busy app is usually near the top of more than one — so the union runs
    /// nearer forty rows than the hundred its inputs suggest, and it is exactly
    /// the set worth keeping: a process in none of the rankings was, by
    /// definition, doing nothing measurable at that instant.
    func rankedUnion() -> [ProcessRow] {
        var seen = Set<Int32>()
        var union: [ProcessRow] = []
        union.reserveCapacity(Self.leaderboardDepth * 3)

        for metric in ProcessMetric.allCases {
            for row in leaders[metric] ?? [] where seen.insert(row.pid).inserted {
                union.append(row)
            }
        }
        union.sort { $0.cpuPercent > $1.cpuPercent }
        return union
    }
}

enum ProcessMetric: String, CaseIterable, Identifiable, Sendable {
    case cpu = "CPU"
    case memory = "Memory"
    case gpu = "GPU"
    case energy = "Energy"
    case disk = "Disk"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .gpu: return "cube.transparent"
        case .energy: return "bolt"
        case .disk: return "internaldrive"
        }
    }

    func value(of row: ProcessRow) -> Double {
        switch self {
        case .cpu: return row.cpuPercent
        case .memory: return Double(row.memoryBytes)
        case .gpu: return row.gpuPercent
        case .energy: return row.energyImpact
        case .disk: return row.diskBytesPerSecond
        }
    }

    func format(_ row: ProcessRow) -> String {
        switch self {
        case .cpu: return String(format: "%.1f%%", row.cpuPercent)
        case .memory: return Format.bytes(row.memoryBytes)
        case .gpu: return String(format: "%.1f%%", row.gpuPercent)
        case .energy: return String(format: "%.1f", row.energyImpact)
        case .disk: return Format.rate(row.diskBytesPerSecond)
        }
    }
}

// MARK: - Host

struct HostDescription {
    var modelName: String = "Mac"
    var modelIdentifier: String = ""
    var chipName: String = ""
    var physicalCores: Int = 0
    var logicalCores: Int = 0
    var efficiencyCores: Int = 0
    var performanceCores: Int = 0
    var memoryBytes: UInt64 = 0
    var osVersion: String = ""
    var isAppleSilicon: Bool = false
    var bootTime: Date = .distantPast

    var uptime: TimeInterval { Date().timeIntervalSince(bootTime) }
}

// MARK: - Snapshot

struct Snapshot {
    var timestamp: Date = Date()
    var interval: TimeInterval = 1
    var cpu = CPUMetrics()
    var memory = MemoryMetrics()
    var gpu = GPUMetrics()
    var thermal = ThermalMetrics()
    var power = PowerMetrics()
    var network = NetworkMetrics()
    var disk = DiskMetrics()
    var battery = BatteryMetrics()
    var sleep = SleepMetrics()
    var processes = ProcessMetrics()
    var host = HostDescription()
}
