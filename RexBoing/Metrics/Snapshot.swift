import Foundation

// MARK: - CPU

public enum CoreKind: String, Sendable {
    case efficiency = "E"
    case performance = "P"
    case unknown = "?"

    public var description: String {
        switch self {
        case .efficiency: return "efficiency core"
        case .performance: return "performance core"
        case .unknown: return "core"
        }
    }
}

public struct CPUMetrics: Sendable {
    /// 0...1 — the fraction of wall time all cores spent doing non-idle work.
    public var total: Double = 0
    public var user: Double = 0
    public var system: Double = 0
    public var idle: Double = 1
    public var nice: Double = 0

    /// 0...1 per logical core, in hardware order (efficiency cores first on Apple silicon).
    public var perCore: [Double] = []
    public var coreKinds: [CoreKind] = []

    /// Average active clock in MHz per cluster kind, derived from DVFS residency.
    public var efficiencyClockMHz: Double?
    public var performanceClockMHz: Double?

    public var loadAverage = LoadAverage()
    public var processCount: Int = 0
    public var threadCount: Int = 0

    /// Cluster averages. Stored rather than derived: the dashboard reads these
    /// on every render, and zip/filter/map over the core array allocated three
    /// throwaway arrays each time.
    public var efficiencyLoad: Double = 0
    public var performanceLoad: Double = 0
}

/// The 1-, 5- and 15-minute load averages. A struct rather than the tuple it
/// used to be, so a snapshot can be encoded for Rex Boing Remote.
public struct LoadAverage: Equatable, Sendable {
    public var one: Double = 0
    public var five: Double = 0
    public var fifteen: Double = 0
}

// MARK: - Memory

public enum MemoryPressureLevel: Int, Comparable, Sendable {
    case normal = 1
    case warning = 2
    case critical = 4

    public var label: String {
        switch self {
        case .normal: return "Normal"
        case .warning: return "Warning"
        case .critical: return "Critical"
        }
    }

    public static func < (lhs: MemoryPressureLevel, rhs: MemoryPressureLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct SwapMetrics: Sendable {
    public var total: UInt64 = 0
    public var used: UInt64 = 0
    public var free: UInt64 = 0
    public var encrypted: Bool = false
    /// Pages moved to/from the swap file since boot.
    public var ins: UInt64 = 0
    public var outs: UInt64 = 0
    /// Rate of change, bytes per second, over the last sample interval.
    public var inRate: Double = 0
    public var outRate: Double = 0

    public var fraction: Double {
        total > 0 ? min(1, Double(used) / Double(total)) : 0
    }
}

public struct MemoryMetrics: Sendable {
    public var total: UInt64 = 0
    public var free: UInt64 = 0
    public var active: UInt64 = 0
    public var inactive: UInt64 = 0
    public var wired: UInt64 = 0
    public var compressed: UInt64 = 0
    public var speculative: UInt64 = 0
    public var purgeable: UInt64 = 0
    public var fileBacked: UInt64 = 0

    /// Matches Activity Monitor's "Memory Used": app + wired + compressed.
    public var used: UInt64 = 0
    /// Activity Monitor's "App Memory".
    public var app: UInt64 = 0
    /// Activity Monitor's "Cached Files".
    public var cached: UInt64 = 0

    /// 0...1, from the kernel's own pressure metric — not simply used/total.
    public var pressure: Double = 0
    public var pressureLevel: MemoryPressureLevel = .normal

    public var swap = SwapMetrics()

    public var fractionUsed: Double {
        total > 0 ? min(1, Double(used) / Double(total)) : 0
    }
}

// MARK: - GPU

public struct GPUMetrics: Sendable {
    public var name: String = "GPU"
    public var coreCount: Int?
    /// 0...1 overall device utilisation.
    public var utilization: Double = 0
    public var rendererUtilization: Double = 0
    public var tilerUtilization: Double = 0
    /// Bytes of memory currently mapped by the GPU driver.
    public var inUseMemory: UInt64 = 0
    /// Bytes the driver has reserved. Zero where the accelerator does not
    /// report it — a discrete card publishes VRAM capacity instead, which is a
    /// different quantity and is carried in `totalMemory`.
    public var allocatedMemory: UInt64 = 0
    /// Physical VRAM, discrete cards only.
    public var totalMemory: UInt64 = 0
    public var clockMHz: Double?
    public var available: Bool = false
}

// MARK: - Thermals

public enum SensorCategory: String, CaseIterable, Sendable {
    case cpu = "CPU"
    case gpu = "GPU"
    case soc = "SoC"
    case memory = "Memory"
    case storage = "Storage"
    case battery = "Battery"
    case power = "Power"
    case ambient = "Ambient"
    case other = "Other"

    public var sortOrder: Int {
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

public struct TempSensor: Identifiable, Sendable {
    public var id: String { key }
    public var key: String
    public var label: String
    /// Degrees Celsius.
    public var celsius: Double
    public var category: SensorCategory
}

public struct Fan: Identifiable, Sendable {
    public var id: Int { index }
    public var index: Int
    public var rpm: Double
    public var minRPM: Double
    public var maxRPM: Double

    public var fraction: Double {
        let span = maxRPM - minRPM
        guard span > 0 else { return 0 }
        return min(1, max(0, (rpm - minRPM) / span))
    }
}

public struct ThermalMetrics: Sendable {
    public var sensors: [TempSensor] = []
    public var fans: [Fan] = []

    /// `sensors` grouped and sorted for the expandable list, built once per
    /// sample instead of being re-filtered and re-sorted on every render.
    public var groups: [SensorGroup] = []

    public var cpuCelsius: Double?
    public var gpuCelsius: Double?
    public var socCelsius: Double?
    public var batteryCelsius: Double?
    public var storageCelsius: Double?

    /// The OS-reported pressure level, which is what actually drives throttling.
    public var thermalState: ProcessInfo.ThermalState = .nominal

    /// Hottest sensor anywhere on the die — the headline number.
    ///
    /// Stored rather than derived from `sensors`, because between full passes
    /// only a subset of sensors carries a fresh reading and a peak taken over
    /// the stale majority would be wrong. The sampler computes this from
    /// whatever it just read.
    public var peakCelsius: Double?
}

public struct SensorGroup: Identifiable, Sendable {
    public var id: String { category.rawValue }
    public var category: SensorCategory
    public var sensors: [TempSensor]
}

extension SensorGroup {
    /// Sensors by category in display order, hottest first within each.
    static func grouped(_ sensors: [TempSensor]) -> [SensorGroup] {
        Dictionary(grouping: sensors, by: \.category)
            .map { SensorGroup(category: $0.key, sensors: $0.value.sorted { $0.celsius > $1.celsius }) }
            .sorted { $0.category.sortOrder < $1.category.sortOrder }
    }
}

// MARK: - Power

public struct PowerMetrics: Sendable {
    public var cpuWatts: Double?
    public var gpuWatts: Double?
    public var aneWatts: Double?
    /// CPU + GPU + Neural Engine + DRAM. The SoC publishes several further
    /// rails (memory controller, ISP, media engines), but this combination is
    /// the one other tools report, so it is the one that can be checked.
    public var packageWatts: Double?
    /// System-wide draw measured at the battery, `nil` unless discharging.
    public var systemWatts: Double?
    /// Whole-machine draw from the SMC's system rail — display, SSD, fans and
    /// the rest of the board included, unlike `packageWatts`, and measured on
    /// mains as well as on battery, unlike `systemWatts`.
    public var systemTotalWatts: Double?
    /// Live draw at the DC-in port while on mains, charging included.
    public var dcInWatts: Double?
    public var adapterWatts: Double?

    /// The figure to headline and graph: whole-machine power from the best
    /// source this Mac has. The SoC package is the last resort — a partial
    /// figure beats an empty graph on a Mac with neither a system rail nor
    /// battery telemetry.
    public var totalWatts: Double? { systemTotalWatts ?? systemWatts ?? packageWatts }

    public var hasAny: Bool {
        cpuWatts != nil || gpuWatts != nil || aneWatts != nil
            || packageWatts != nil || systemWatts != nil
            || systemTotalWatts != nil || dcInWatts != nil || adapterWatts != nil
    }
}

// MARK: - Battery

public struct BatteryMetrics: Sendable {
    public var present: Bool = false
    public var percentage: Double = 0
    public var isCharging: Bool = false
    public var isPluggedIn: Bool = false
    public var timeRemainingMinutes: Int?
    public var cycleCount: Int?
    public var designCapacity: Int?
    public var maxCapacity: Int?
    public var celsius: Double?
    public var voltage: Double?
    public var amperage: Double?
    public var condition: String?
    /// Instantaneous whole-machine draw, derived from cell voltage × current.
    /// Only meaningful while discharging, and `nil` otherwise.
    public var systemWatts: Double?
    /// Power flowing into the cell, `nil` unless actually charging.
    public var chargingWatts: Double?
    /// The connected charger's rated output, if one is attached.
    public var adapterWatts: Double?

    public var healthFraction: Double? {
        guard let design = designCapacity, let maximum = maxCapacity, design > 0 else { return nil }
        return Double(maximum) / Double(design)
    }
}

// MARK: - Sleep assertions

/// One process holding a power assertion against sleep — the answer to "why
/// won't it sleep". A display assertion keeps the screen on, which holds the
/// system up with it; a system assertion lets the screen sleep but not the
/// machine.
public struct SleepBlocker: Identifiable, Sendable {
    public var id: Int32 { pid }
    public var pid: Int32
    public var name: String
    public var preventsDisplaySleep: Bool = false
    public var preventsSystemSleep: Bool = false
    /// The names the process gave its assertions — "Video Wake Lock",
    /// "com.apple.audio.context…" — often more legible than the process name.
    public var assertionNames: [String] = []
}

public struct SleepMetrics: Sendable {
    /// Display blockers first, then alphabetical, so the list does not
    /// reshuffle between samples.
    public var blockers: [SleepBlocker] = []
    /// False until the first successful read, so the card can tell "nothing is
    /// holding sleep" apart from "not sampled yet".
    public var sampled: Bool = false
}

// MARK: - Network & disk

public struct NetworkMetrics: Sendable {
    public var rxBytesPerSecond: Double = 0
    public var txBytesPerSecond: Double = 0
    /// Bytes since Rex Boing launched. The underlying counters are 64-bit, but a
    /// since-boot aggregate is not recoverable across interfaces that have
    /// disappeared; this one is accumulated from per-interface deltas and is
    /// exact for the life of the process.
    public var rxTotal: UInt64 = 0
    public var txTotal: UInt64 = 0
    public var primaryInterface: String?
    public var localAddress: String?
}

public struct DiskMetrics: Sendable {
    public var readBytesPerSecond: Double = 0
    public var writeBytesPerSecond: Double = 0
    /// Bytes since Rex Boing launched, summed across drives present at the time.
    public var readTotal: UInt64 = 0
    public var writeTotal: UInt64 = 0
    public var volumeName: String = "Macintosh HD"
    public var capacity: UInt64 = 0
    public var available: UInt64 = 0
    /// Space the filesystem keeps back, neither in use nor available: ext4
    /// reserves 5 % for root by default. Zero on a Mac.
    public var reserved: UInt64 = 0

    public var used: UInt64 {
        let unavailable = capacity > available ? capacity - available : 0
        return unavailable > reserved ? unavailable - reserved : 0
    }
    /// Full as df counts it: in use out of what can still be used, so a
    /// reserve no user can write to is not counted as data.
    public var fractionUsed: Double {
        let usable = Double(used) + Double(min(available, capacity))
        return usable > 0 ? min(1, Double(used) / usable) : 0
    }
}

// MARK: - Processes

public struct ProcessRow: Identifiable, Hashable, Sendable {
    public var id: Int32 { pid }
    public var pid: Int32
    public var name: String
    /// Process creation time in microseconds since the Unix epoch. A pid alone
    /// is not an identity: the kernel can recycle it while a retained history
    /// row is still on screen.
    public var startTime: UInt64 = 0
    public var bundleIdentifier: String?
    public var executablePath: String?
    /// Percent of a single core, so this can exceed 100 on multi-threaded work.
    public var cpuPercent: Double = 0
    public var memoryBytes: UInt64 = 0
    /// Percent of GPU wall time consumed over the sample interval.
    public var gpuPercent: Double = 0
    public var energyImpact: Double = 0
    /// Bytes per second of real disk I/O over the sample interval — traffic
    /// that reached the device, so reads served from the page cache do not
    /// count. Deltas of cumulative rusage counters, the same way CPU is.
    public var diskReadBytesPerSecond: Double = 0
    public var diskWriteBytesPerSecond: Double = 0
    /// Thread wakeups per second — timers and interrupts pulling this
    /// process's threads out of a wait. The classic energy-bug tell: a 100 Hz
    /// polling timer reads as 100 here while costing almost no CPU percent.
    public var wakeupsPerSecond: Double = 0
    public var threadCount: Int = 0
    /// Remote machines only: the owning user and the command line, secrets
    /// already removed by the agent. Local rows leave both empty.
    public var user: String?
    public var commandLine: String?

    /// Reads and writes together — what the disk ranking ranks by.
    public var diskBytesPerSecond: Double { diskReadBytesPerSecond + diskWriteBytesPerSecond }

    // Equality is deliberately the synthesized memberwise one. SwiftUI decides
    // whether to re-render a row by comparing the row values it was given, and
    // a pid-only `==` told it that a process whose readings had all changed was
    // the same row — so the top-ranked process, whose bar fraction is pinned at
    // 1.0, kept its first-render numbers for as long as it stayed on top.
    // Identity for ForEach/Table is still the pid, via `Identifiable`.
}

public struct ProcessMetrics: Sendable {
    /// How deep each per-metric ranking goes.
    ///
    /// Deeper than the dashboard card can show (`Preferences.processRowCount`
    /// stops at 12) because the inspector retains these rankings and lists them
    /// side by side, where a dozen rows runs out too quickly. The ranking pass
    /// is a single scan with an early-out per row, so the extra depth costs
    /// nothing measurable.
    public static let leaderboardDepth = 20

    public var count: Int = 0
    public var gpuAttributionAvailable: Bool = false

    /// When this table was taken, and the window its deltas were measured over.
    ///
    /// The process table is sampled on its own cadence and re-attached to every
    /// snapshot in between, so a snapshot's own timestamp says nothing about
    /// how old the process rows on it are. History uses this to record each
    /// table once, and to recognise a window that spans a sleep.
    public var sampledAt: Date = .distantPast
    public var interval: TimeInterval = 0

    /// Ranked rows per metric, resolved on the sampler queue.
    ///
    /// The dashboard used to sort the full process table — several hundred rows
    /// — inside a computed property that the view body touched once per row,
    /// which meant a dozen full sorts on the main thread every second. Ranking
    /// happens once, off the main thread, and the view slices the result.
    public var leaders: [ProcessMetric: [ProcessRow]] = [:]

    public func top(by metric: ProcessMetric, limit: Int) -> ArraySlice<ProcessRow> {
        (leaders[metric] ?? []).prefix(limit)
    }

    /// Every process that placed in any of the rankings, once each.
    ///
    /// This is what the inspector retains. The lists overlap heavily — a
    /// busy app is usually near the top of more than one — so the union runs
    /// nearer forty rows than the hundred its inputs suggest, and it is exactly
    /// the set worth keeping: a process in none of the rankings was, by
    /// definition, doing nothing measurable at that instant.
    public func rankedUnion() -> [ProcessRow] {
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

public enum ProcessMetric: String, CaseIterable, Identifiable, Sendable {
    case cpu = "CPU"
    case memory = "Memory"
    case gpu = "GPU"
    case energy = "Energy"
    case disk = "Disk"

    public var id: String { rawValue }

    public var symbol: String {
        switch self {
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .gpu: return "cube.transparent"
        case .energy: return "bolt"
        case .disk: return "internaldrive"
        }
    }

    public func value(of row: ProcessRow) -> Double {
        switch self {
        case .cpu: return row.cpuPercent
        case .memory: return Double(row.memoryBytes)
        case .gpu: return row.gpuPercent
        case .energy: return row.energyImpact
        case .disk: return row.diskBytesPerSecond
        }
    }

    public func format(_ row: ProcessRow) -> String {
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

public struct HostDescription: Sendable {
    public var modelName: String = "Mac"
    public var modelIdentifier: String = ""
    public var chipName: String = ""
    public var physicalCores: Int = 0
    public var logicalCores: Int = 0
    public var efficiencyCores: Int = 0
    public var performanceCores: Int = 0
    public var memoryBytes: UInt64 = 0
    public var osVersion: String = ""
    public var isAppleSilicon: Bool = false
    public var bootTime: Date = .distantPast

    public var uptime: TimeInterval { Date().timeIntervalSince(bootTime) }
}

// MARK: - Snapshot

public struct Snapshot: Sendable {
    public var timestamp: Date = Date()
    public var interval: TimeInterval = 1
    public var cpu = CPUMetrics()
    public var memory = MemoryMetrics()
    public var gpu = GPUMetrics()
    public var thermal = ThermalMetrics()
    public var power = PowerMetrics()
    public var network = NetworkMetrics()
    public var disk = DiskMetrics()
    public var battery = BatteryMetrics()
    public var sleep = SleepMetrics()
    public var processes = ProcessMetrics()
    public var host = HostDescription()
    /// What a remote machine reports beyond these sections. Always empty in
    /// Rex Boing itself.
    public var extras = SnapshotExtras()

    public init() {}
}
