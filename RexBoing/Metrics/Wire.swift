import Foundation

// The Rex Boing Remote protocol, version 1, as Swift types.
//
// The specification is PROTOCOL.md in the Rex Boing Remote repository; the Go
// agent mirrors these types in agent/internal/wire. Every field is optional on
// the wire: a missing key means "not available on this machine", never zero,
// and unknown keys are ignored, so either side can grow without breaking the
// other.
//
// Rex Boing itself never encodes or decodes any of this. It lives here because
// the macOS agent builds its samples from this app's own samplers, and the
// Remote app turns samples back into a `Snapshot` for this app's own cards.

public enum WireProtocol {
    public static let version = 1
    public static let agentName = "rex-boing-agent"
}

public struct WireAgent: Codable, Sendable, Equatable {
    public var name: String?
    public var version: String?
    public var os: String?
    public var arch: String?

    public init(name: String? = nil, version: String? = nil, os: String? = nil, arch: String? = nil) {
        self.name = name
        self.version = version
        self.os = os
        self.arch = arch
    }
}

public struct WireHost: Codable, Sendable, Equatable {
    public var hostname: String?
    public var modelName: String?
    public var modelIdentifier: String?
    public var vendor: String?
    public var chipName: String?
    public var osName: String?
    public var osVersion: String?
    public var kernel: String?
    public var physicalCores: Int?
    public var logicalCores: Int?
    public var performanceCores: Int?
    public var efficiencyCores: Int?
    public var memoryBytes: UInt64?
    /// Milliseconds since the epoch.
    public var bootTime: Int64?
    public var isAppleSilicon: Bool?
    public var virtualization: String?

    public init() {}
}

public struct WireHello: Codable, Sendable {
    public var type: String = "hello"
    public var `protocol`: Int?
    public var agent: WireAgent?
    public var host: WireHost?
    public var capabilities: [String]?
    public var interval: Double?

    public init() {}
}

public struct WireCPU: Codable, Sendable {
    public var total, user, system, idle, nice, iowait, steal: Double?
    public var perCore: [Double]?
    /// One character per core: P, E or ?.
    public var kinds: String?
    public var clockMHz, performanceClockMHz, efficiencyClockMHz: Double?
    /// One, five and fifteen minutes.
    public var load: [Double]?
    public var processes, threads, zombies: Int?

    public init() {}
}

public struct WireSwap: Codable, Sendable {
    public var total, used, free: UInt64?
    public var inRate, outRate: Double?
    public var encrypted: Bool?

    public init() {}
}

public struct WireMemory: Codable, Sendable {
    public var total, used, available, free, app, wired, compressed, cached, buffers: UInt64?
    public var active, inactive, purgeable: UInt64?
    public var pressure: Double?
    public var pressureLevel: String?
    public var swap: WireSwap?

    public init() {}
}

public struct WireGPU: Codable, Sendable, Identifiable {
    public var id: String { (name ?? "GPU") + (vendor ?? "") }
    public var name: String?
    public var vendor: String?
    public var utilization: Double?
    public var engines: [String: Double]?
    public var memoryUsed, memoryTotal, memoryAllocated: UInt64?
    public var clockMHz, maxClockMHz, celsius, watts, fanRPM, fanPercent: Double?
    public var coreCount: Int?

    public init() {}
}

public struct WireSensor: Codable, Sendable {
    public var key: String?
    public var label: String?
    public var celsius: Double?
    public var category: String?
    public var high: Double?
    public var critical: Double?

    public init() {}
}

public struct WireFan: Codable, Sendable {
    public var index: Int?
    public var label: String?
    public var rpm: Double?
    public var minRPM, maxRPM: Double?

    public init() {}
}

public struct WireThermal: Codable, Sendable {
    public var sensors: [WireSensor]?
    public var fans: [WireFan]?
    public var cpuCelsius, gpuCelsius, socCelsius, batteryCelsius, storageCelsius, peakCelsius: Double?
    public var state: String?

    public init() {}
}

public struct WirePower: Codable, Sendable {
    public var cpuWatts, gpuWatts, aneWatts, packageWatts, systemWatts, systemTotalWatts,
        dcInWatts, adapterWatts: Double?

    public init() {}
}

public struct WireInterface: Codable, Sendable, Identifiable {
    public var id: String { name ?? "" }
    public var name: String?
    public var rx, tx: Double?
    public var speedMbps: Double?
    public var up: Bool?

    public init() {}
}

public struct WireNetwork: Codable, Sendable {
    public var rx, tx: Double?
    public var rxTotal, txTotal: UInt64?
    public var primaryInterface, localAddress: String?
    public var interfaces: [WireInterface]?

    public init() {}
}

public struct WireVolume: Codable, Sendable, Identifiable {
    public var id: String { (mount ?? "") + (name ?? "") }
    public var name: String?
    public var mount: String?
    public var fs: String?
    public var total, available: UInt64?
    /// Bytes in use, where the filesystem counts them itself. Less than
    /// total − available by whatever it keeps back (ext4's root reserve);
    /// absent from macOS and Windows agents and from older Linux ones.
    public var used: UInt64?

    public init() {}

    /// The space neither in use nor available.
    public var reserved: UInt64 {
        let total = total ?? 0
        let unavailable = total - min(available ?? 0, total)
        guard let used, used < unavailable else { return 0 }
        return unavailable - used
    }

    /// Full as df counts it: used / (used + available).
    public var fractionUsed: Double {
        var disk = DiskMetrics()
        disk.capacity = total ?? 0
        disk.available = available ?? 0
        disk.reserved = reserved
        return disk.fractionUsed
    }
}

public struct WireDisk: Codable, Sendable {
    public var read, write: Double?
    public var readTotal, writeTotal: UInt64?
    public var volumes: [WireVolume]?

    public init() {}
}

public struct WireBattery: Codable, Sendable {
    public var present: Bool?
    public var percentage: Double?
    public var charging, pluggedIn: Bool?
    public var timeRemainingMinutes, cycleCount, designCapacity, maxCapacity: Int?
    public var celsius, voltage, amperage: Double?
    public var condition: String?
    public var systemWatts, chargingWatts, adapterWatts: Double?

    public init() {}
}

public struct WirePressure: Codable, Sendable {
    /// Percent of time stalled, 10-second average.
    public var cpu, memory, io, memoryFull, ioFull: Double?

    public init() {}
}

public struct WireSystem: Codable, Sendable {
    public var uptime: Double?
    public var rebootRequired: Bool?
    public var rebootReason: String?
    public var updates, securityUpdates: Int?
    public var failedServices: [String]?
    public var containers: Int?

    public init() {}
}

public struct WireProcessRow: Codable, Sendable {
    public var pid: Int32?
    public var name: String?
    public var user: String?
    /// Microseconds since the epoch.
    public var start: UInt64?
    public var path: String?
    public var cmd: String?
    public var cpu: Double?
    public var memory: UInt64?
    public var gpu, energy, diskRead, diskWrite, wakeups: Double?
    public var threads: Int?

    public init() {}
}

public struct WireProcesses: Codable, Sendable {
    public var count: Int?
    /// Milliseconds since the epoch.
    public var sampledAt: Int64?
    public var interval: Double?
    public var gpuAttribution: Bool?
    public var rows: [WireProcessRow]?
    public var rank: [String: [Int32]]?

    public init() {}
}

public struct WireSleepBlocker: Codable, Sendable {
    public var pid: Int32?
    public var name: String?
    public var display, system: Bool?
    public var assertions: [String]?

    public init() {}
}

public struct WireSleep: Codable, Sendable {
    public var sampled: Bool?
    public var blockers: [WireSleepBlocker]?

    public init() {}
}

public struct WireSample: Codable, Sendable {
    public var type: String = "sample"
    public var seq: UInt64?
    /// Milliseconds since the epoch, on the agent's clock.
    public var t: Int64?
    public var interval: Double?
    public var detail: String?
    public var resync: Bool?

    public var cpu: WireCPU?
    public var memory: WireMemory?
    public var gpus: [WireGPU]?
    public var thermal: WireThermal?
    public var power: WirePower?
    public var network: WireNetwork?
    public var disk: WireDisk?
    public var battery: WireBattery?
    public var pressure: WirePressure?
    public var system: WireSystem?
    public var processes: WireProcesses?
    public var sleep: WireSleep?

    public init() {}
}

/// The parts of a remote sample Rex Boing's own `Snapshot` has no field for,
/// kept as they arrived so Rex Boing Remote can show them. Empty for a local
/// snapshot.
public struct SnapshotExtras: Sendable {
    public var gpus: [WireGPU] = []
    public var pressure: WirePressure?
    public var system: WireSystem?
    public var volumes: [WireVolume] = []
    public var interfaces: [WireInterface] = []
    public var iowait: Double?
    public var steal: Double?
    public var zombies: Int?
    public var clockMHz: Double?
    /// Limits per sensor key, from the hardware.
    public var sensorLimits: [String: (high: Double?, critical: Double?)] = [:]
    public var fanLabels: [Int: String] = [:]

    public init() {}
}

/// One line from the agent, decoded.
public enum WireMessage: Sendable {
    case hello(WireHello)
    case sample(WireSample)
    case notice(code: String, message: String)
    case other(String)

    private struct Envelope: Decodable {
        var type: String?
        var code: String?
        var message: String?

        private enum CodingKeys: String, CodingKey { case type, code, message }

        // Each key under its own `try?`. Unknown keys must be ignored, and
        // `code` and `message` only mean something on a notice: a future
        // message that carries either as an object must not make every line
        // of that type unreadable to this app.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try? container.decodeIfPresent(String.self, forKey: .type)
            code = try? container.decodeIfPresent(String.self, forKey: .code)
            message = try? container.decodeIfPresent(String.self, forKey: .message)
        }
    }

    /// Decodes one protocol line. Returns nil for a line that is not JSON.
    public static func decode(_ line: Data, decoder: JSONDecoder = JSONDecoder()) -> WireMessage? {
        guard let envelope = try? decoder.decode(Envelope.self, from: line) else { return nil }
        switch envelope.type {
        case "hello":
            return (try? decoder.decode(WireHello.self, from: line)).map(WireMessage.hello)
        case "sample":
            return (try? decoder.decode(WireSample.self, from: line)).map(WireMessage.sample)
        case "notice":
            return .notice(code: envelope.code ?? "", message: envelope.message ?? "")
        default:
            return .other(envelope.type ?? "")
        }
    }
}

// MARK: - Wire → Snapshot

extension Snapshot {
    /// Builds a snapshot from a remote sample, for Rex Boing's cards.
    ///
    /// `host` comes from the session's hello. `previous` carries over what a
    /// vitals-only sample does not repeat — sensor lists, the process table,
    /// volumes — so the dashboard does not blank between full samples.
    public init(sample: WireSample, host: WireHost?, previous: Snapshot? = nil) {
        self.init()
        let t = sample.t ?? Int64(Date().timeIntervalSince1970 * 1000)
        timestamp = Date(timeIntervalSince1970: Double(t) / 1000)
        interval = sample.interval ?? 1
        self.host = HostDescription(wire: host)

        if let wire = sample.cpu { cpu = CPUMetrics(wire: wire) }
        if let wire = sample.memory { memory = MemoryMetrics(wire: wire) }

        if let primary = sample.gpus?.first {
            gpu = GPUMetrics(wire: primary)
        }
        extras.gpus = sample.gpus ?? previous?.extras.gpus ?? []

        // A section or list a sample leaves out was not read this time, which
        // is not the same as being empty: agents re-read slow sources (the
        // full sensor list, the process table) less often than every tick.
        thermal = ThermalMetrics(wire: sample.thermal, gpus: sample.gpus, previous: previous?.thermal)
        if let wire = sample.thermal?.sensors {
            for sensor in wire {
                guard let key = sensor.key else { continue }
                extras.sensorLimits[key] = (sensor.high, sensor.critical)
            }
            for fan in sample.thermal?.fans ?? [] {
                if let index = fan.index, let label = fan.label { extras.fanLabels[index] = label }
            }
        } else if let previous {
            extras.sensorLimits = previous.extras.sensorLimits
            extras.fanLabels = previous.extras.fanLabels
        }

        if let wire = sample.power { power = PowerMetrics(wire: wire) }
        if power.gpuWatts == nil {
            power.gpuWatts = sample.gpus?.compactMap(\.watts).first
        }
        // On a PC the package is the CPU (plus an integrated GPU); without a
        // separate core counter it is the closest reading the CPU card has.
        // Apple silicon's package spans CPU, GPU and Neural Engine, so it is
        // left where it is there.
        if power.cpuWatts == nil, host?.isAppleSilicon != true {
            power.cpuWatts = power.packageWatts
        }
        if let wire = sample.network { network = NetworkMetrics(wire: wire) }
        if let wire = sample.disk {
            disk = DiskMetrics(wire: wire, previous: previous?.disk)
            extras.volumes = wire.volumes ?? previous?.extras.volumes ?? []
        }
        if let wire = sample.battery { battery = BatteryMetrics(wire: wire) }
        if let wire = sample.sleep { sleep = SleepMetrics(wire: wire) }

        if let wire = sample.processes {
            processes = ProcessMetrics(wire: wire)
        } else if let previous {
            processes = previous.processes
        }

        extras.pressure = sample.pressure ?? previous?.extras.pressure
        extras.system = sample.system ?? previous?.extras.system
        extras.interfaces = sample.network?.interfaces ?? previous?.extras.interfaces ?? []
        extras.iowait = sample.cpu?.iowait
        extras.steal = sample.cpu?.steal
        extras.zombies = sample.cpu?.zombies ?? previous?.extras.zombies
        extras.clockMHz = sample.cpu?.clockMHz
    }
}

extension HostDescription {
    public init(wire: WireHost?) {
        self.init()
        guard let wire else { return }
        modelName = wire.modelName ?? wire.hostname ?? "Computer"
        modelIdentifier = wire.modelIdentifier ?? ""
        chipName = wire.chipName ?? ""
        physicalCores = wire.physicalCores ?? wire.logicalCores ?? 0
        logicalCores = wire.logicalCores ?? physicalCores
        efficiencyCores = wire.efficiencyCores ?? 0
        performanceCores = wire.performanceCores ?? 0
        memoryBytes = wire.memoryBytes ?? 0
        osVersion = [wire.osName, wire.osVersion].compactMap { $0 }.joined(separator: " ")
        isAppleSilicon = wire.isAppleSilicon ?? false
        if let boot = wire.bootTime { bootTime = Date(timeIntervalSince1970: Double(boot) / 1000) }
    }
}

extension CPUMetrics {
    init(wire: WireCPU) {
        self.init()
        total = wire.total ?? 0
        user = wire.user ?? 0
        system = wire.system ?? 0
        nice = wire.nice ?? 0
        idle = wire.idle ?? max(0, 1 - total)
        perCore = wire.perCore ?? []
        coreKinds = (wire.kinds ?? "").map { character -> CoreKind in
            switch character {
            case "P": return .performance
            case "E": return .efficiency
            default: return .unknown
            }
        }
        if coreKinds.count != perCore.count { coreKinds = [] }
        efficiencyClockMHz = wire.efficiencyClockMHz
        performanceClockMHz = wire.performanceClockMHz
        if let load = wire.load, load.count == 3 {
            loadAverage = LoadAverage(one: load[0], five: load[1], fifteen: load[2])
        }
        processCount = wire.processes ?? 0
        threadCount = wire.threads ?? 0
        func clusterLoad(_ kind: CoreKind) -> Double {
            let loads = zip(perCore, coreKinds).filter { $0.1 == kind }.map(\.0)
            return loads.isEmpty ? 0 : loads.reduce(0, +) / Double(loads.count)
        }
        efficiencyLoad = clusterLoad(.efficiency)
        performanceLoad = clusterLoad(.performance)
    }
}

extension MemoryMetrics {
    init(wire: WireMemory) {
        self.init()
        total = wire.total ?? 0
        used = wire.used ?? 0
        free = wire.free ?? wire.available ?? 0
        active = wire.active ?? 0
        inactive = wire.inactive ?? 0
        wired = wire.wired ?? 0
        compressed = wire.compressed ?? 0
        purgeable = wire.purgeable ?? 0
        app = wire.app ?? used
        cached = (wire.cached ?? 0) + (wire.buffers ?? 0)
        pressure = wire.pressure ?? (total > 0 ? Double(used) / Double(total) : 0)
        switch wire.pressureLevel {
        case "critical": pressureLevel = .critical
        case "warning": pressureLevel = .warning
        default: pressureLevel = .normal
        }
        if let swapWire = wire.swap {
            swap.total = swapWire.total ?? 0
            swap.used = swapWire.used ?? 0
            swap.free = swapWire.free ?? (swap.total > swap.used ? swap.total - swap.used : 0)
            swap.inRate = swapWire.inRate ?? 0
            swap.outRate = swapWire.outRate ?? 0
            swap.encrypted = swapWire.encrypted ?? false
        }
    }
}

extension GPUMetrics {
    init(wire: WireGPU) {
        self.init()
        name = wire.name ?? "GPU"
        coreCount = wire.coreCount
        utilization = wire.utilization ?? 0
        let engines = wire.engines ?? [:]
        rendererUtilization = engines["render"] ?? engines["3d"] ?? 0
        tilerUtilization = engines["tiler"] ?? 0
        inUseMemory = wire.memoryUsed ?? 0
        allocatedMemory = wire.memoryAllocated ?? 0
        totalMemory = wire.memoryTotal ?? 0
        clockMHz = wire.clockMHz
        available = true
    }
}

extension ThermalMetrics {
    init(wire: WireThermal?, gpus: [WireGPU]?, previous: ThermalMetrics?) {
        self.init()
        if let wire {
            if let wireSensors = wire.sensors {
                // Keys are the views' identities, so they are made unique
                // here as the local sampler makes them: a duplicate id leaves
                // SwiftUI's ForEach undefined. A keyless sensor gets its
                // position rather than sharing one placeholder with the rest.
                var seen = Set<String>()
                sensors = wireSensors.enumerated().compactMap { offset, sensor in
                    guard let celsius = sensor.celsius else { return nil }
                    let key = sensor.key ?? sensor.label ?? "sensor \(offset)"
                    guard seen.insert(key).inserted else { return nil }
                    return TempSensor(
                        key: key, label: sensor.label ?? key, celsius: celsius,
                        category: SensorCategory(rawValue: sensor.category ?? "") ?? .other)
                }
            } else if let previous {
                sensors = previous.sensors
            }
            if let wireFans = wire.fans {
                var seen = Set<Int>()
                fans = wireFans.enumerated().compactMap { offset, fan in
                    let index = fan.index ?? offset
                    guard seen.insert(index).inserted else { return nil }
                    let rpm = fan.rpm ?? 0
                    return Fan(
                        index: index, rpm: rpm,
                        minRPM: fan.minRPM ?? 0, maxRPM: max(fan.maxRPM ?? rpm, rpm))
                }
            } else if let previous {
                fans = previous.fans
            }
            cpuCelsius = wire.cpuCelsius
            gpuCelsius = wire.gpuCelsius
            socCelsius = wire.socCelsius
            batteryCelsius = wire.batteryCelsius
            storageCelsius = wire.storageCelsius
            peakCelsius = wire.peakCelsius
            switch wire.state {
            case "fair": thermalState = .fair
            case "serious": thermalState = .serious
            case "critical": thermalState = .critical
            default: thermalState = .nominal
            }
        } else if let previous {
            sensors = previous.sensors
            fans = previous.fans
        }
        if gpuCelsius == nil { gpuCelsius = gpus?.compactMap(\.celsius).first }
        if peakCelsius == nil {
            peakCelsius = [cpuCelsius, gpuCelsius, socCelsius].compactMap { $0 }.max()
        }
        groups = SensorGroup.grouped(sensors)
    }
}

extension PowerMetrics {
    init(wire: WirePower) {
        self.init()
        cpuWatts = wire.cpuWatts
        gpuWatts = wire.gpuWatts
        aneWatts = wire.aneWatts
        packageWatts = wire.packageWatts
        systemWatts = wire.systemWatts
        systemTotalWatts = wire.systemTotalWatts
        dcInWatts = wire.dcInWatts
        adapterWatts = wire.adapterWatts
    }
}

extension NetworkMetrics {
    init(wire: WireNetwork) {
        self.init()
        rxBytesPerSecond = wire.rx ?? 0
        txBytesPerSecond = wire.tx ?? 0
        rxTotal = wire.rxTotal ?? 0
        txTotal = wire.txTotal ?? 0
        primaryInterface = wire.primaryInterface
        localAddress = wire.localAddress
    }
}

extension DiskMetrics {
    init(wire: WireDisk, previous: DiskMetrics?) {
        self.init()
        readBytesPerSecond = wire.read ?? 0
        writeBytesPerSecond = wire.write ?? 0
        readTotal = wire.readTotal ?? 0
        writeTotal = wire.writeTotal ?? 0
        if let primary = wire.volumes?.first {
            volumeName = primary.name ?? primary.mount ?? "Disk"
            capacity = primary.total ?? 0
            available = primary.available ?? 0
            reserved = primary.reserved
        } else if let previous {
            volumeName = previous.volumeName
            capacity = previous.capacity
            available = previous.available
            reserved = previous.reserved
        } else {
            volumeName = "Disk"
        }
    }
}

extension BatteryMetrics {
    init(wire: WireBattery) {
        self.init()
        present = wire.present ?? false
        percentage = wire.percentage ?? 0
        isCharging = wire.charging ?? false
        isPluggedIn = wire.pluggedIn ?? false
        timeRemainingMinutes = wire.timeRemainingMinutes
        cycleCount = wire.cycleCount
        designCapacity = wire.designCapacity
        maxCapacity = wire.maxCapacity
        celsius = wire.celsius
        voltage = wire.voltage
        amperage = wire.amperage
        condition = wire.condition
        systemWatts = wire.systemWatts
        chargingWatts = wire.chargingWatts
        adapterWatts = wire.adapterWatts
    }
}

extension SleepMetrics {
    init(wire: WireSleep) {
        self.init()
        sampled = wire.sampled ?? false
        var seen = Set<Int32>()
        blockers = (wire.blockers ?? []).compactMap { blocker in
            guard let pid = blocker.pid, seen.insert(pid).inserted else { return nil }
            return SleepBlocker(
                pid: pid, name: blocker.name ?? "pid \(pid)",
                preventsDisplaySleep: blocker.display ?? false,
                preventsSystemSleep: blocker.system ?? false,
                assertionNames: blocker.assertions ?? [])
        }
    }
}

extension ProcessMetrics {
    init(wire: WireProcesses) {
        self.init()
        count = wire.count ?? 0
        gpuAttributionAvailable = wire.gpuAttribution ?? false
        if let ms = wire.sampledAt { sampledAt = Date(timeIntervalSince1970: Double(ms) / 1000) }
        interval = wire.interval ?? 0
        var byPID: [Int32: ProcessRow] = [:]
        for row in wire.rows ?? [] {
            guard let pid = row.pid else { continue }
            byPID[pid] = ProcessRow(wire: row, pid: pid)
        }
        for metric in ProcessMetric.allCases {
            var seen = Set<Int32>()
            let pids = (wire.rank?[metric.wireKey] ?? []).filter { seen.insert($0).inserted }
            let rows = pids.compactMap { byPID[$0] }
            if !rows.isEmpty { leaders[metric] = rows }
        }
    }
}

extension ProcessRow {
    init(wire: WireProcessRow, pid: Int32) {
        self.init(pid: pid, name: wire.name ?? "pid \(pid)")
        startTime = wire.start ?? 0
        executablePath = wire.path
        cpuPercent = wire.cpu ?? 0
        memoryBytes = wire.memory ?? 0
        gpuPercent = wire.gpu ?? 0
        energyImpact = wire.energy ?? 0
        diskReadBytesPerSecond = wire.diskRead ?? 0
        diskWriteBytesPerSecond = wire.diskWrite ?? 0
        wakeupsPerSecond = wire.wakeups ?? 0
        threadCount = wire.threads ?? 0
        user = wire.user
        commandLine = wire.cmd
    }
}

extension ProcessMetric {
    /// The metric's key in a sample's `processes.rank`.
    public var wireKey: String {
        switch self {
        case .cpu: return "cpu"
        case .memory: return "memory"
        case .gpu: return "gpu"
        case .energy: return "energy"
        case .disk: return "disk"
        }
    }
}

// MARK: - Snapshot → Wire (the macOS agent)

extension HostDescription {
    public func wire(hostname: String, kernel: String) -> WireHost {
        var host = WireHost()
        host.hostname = hostname
        host.modelName = modelName
        host.modelIdentifier = modelIdentifier.isEmpty ? nil : modelIdentifier
        host.vendor = "Apple"
        host.chipName = chipName
        host.osName = "macOS"
        host.osVersion = osVersion
        host.kernel = kernel
        host.physicalCores = physicalCores
        host.logicalCores = logicalCores
        host.performanceCores = performanceCores > 0 ? performanceCores : nil
        host.efficiencyCores = efficiencyCores > 0 ? efficiencyCores : nil
        host.memoryBytes = memoryBytes
        host.bootTime = Int64(bootTime.timeIntervalSince1970 * 1000)
        host.isAppleSilicon = isAppleSilicon
        // Hypervisor.framework sets this inside any guest — a CI runner, a
        // UTM or Parallels VM — so a macOS agent there says so, as the Linux
        // agent does with its own detection.
        var guest: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let inVM = sysctlbyname("kern.hv_vmm_present", &guest, &size, nil, 0) == 0 && guest == 1
        host.virtualization = inVM ? "vm" : "none"
        return host
    }
}

extension Snapshot {
    /// Encodes this snapshot as a protocol sample. `full` includes sensors,
    /// fans, volumes, sleep blockers and processes; vitals carries only what
    /// the menu bar, the fleet list and history need.
    public func wireSample(full: Bool) -> WireSample {
        var sample = WireSample()
        sample.t = Int64(timestamp.timeIntervalSince1970 * 1000)
        sample.interval = interval
        sample.detail = full ? "full" : "vitals"

        var cpuWire = WireCPU()
        cpuWire.total = cpu.total
        cpuWire.user = cpu.user
        cpuWire.system = cpu.system
        cpuWire.idle = cpu.idle
        cpuWire.nice = cpu.nice
        if full {
            cpuWire.perCore = cpu.perCore
            cpuWire.kinds = String(cpu.coreKinds.map { Character($0.rawValue) })
            cpuWire.performanceClockMHz = cpu.performanceClockMHz
            cpuWire.efficiencyClockMHz = cpu.efficiencyClockMHz
            cpuWire.load = [cpu.loadAverage.one, cpu.loadAverage.five, cpu.loadAverage.fifteen]
            cpuWire.processes = cpu.processCount
            cpuWire.threads = cpu.threadCount
        }
        sample.cpu = cpuWire

        var memoryWire = WireMemory()
        memoryWire.total = memory.total
        memoryWire.used = memory.used
        memoryWire.pressureLevel = memory.pressureLevel == .critical
            ? "critical" : memory.pressureLevel == .warning ? "warning" : "normal"
        var swapWire = WireSwap()
        swapWire.total = memory.swap.total
        swapWire.used = memory.swap.used
        if full {
            memoryWire.free = memory.free
            memoryWire.app = memory.app
            memoryWire.wired = memory.wired
            memoryWire.compressed = memory.compressed
            memoryWire.cached = memory.cached
            memoryWire.active = memory.active
            memoryWire.inactive = memory.inactive
            memoryWire.purgeable = memory.purgeable
            memoryWire.pressure = memory.pressure
            swapWire.free = memory.swap.free
            swapWire.inRate = memory.swap.inRate
            swapWire.outRate = memory.swap.outRate
            swapWire.encrypted = memory.swap.encrypted
        }
        memoryWire.swap = swapWire
        sample.memory = memoryWire

        if gpu.available {
            var gpuWire = WireGPU()
            gpuWire.name = gpu.name
            gpuWire.vendor = "apple"
            gpuWire.utilization = gpu.utilization
            if full {
                gpuWire.engines = ["render": gpu.rendererUtilization, "tiler": gpu.tilerUtilization]
                gpuWire.memoryUsed = gpu.inUseMemory
                if gpu.allocatedMemory > 0 { gpuWire.memoryAllocated = gpu.allocatedMemory }
                if gpu.totalMemory > 0 { gpuWire.memoryTotal = gpu.totalMemory }
                gpuWire.clockMHz = gpu.clockMHz
                gpuWire.coreCount = gpu.coreCount
            }
            sample.gpus = [gpuWire]
        }

        var thermalWire = WireThermal()
        thermalWire.cpuCelsius = thermal.cpuCelsius
        thermalWire.gpuCelsius = thermal.gpuCelsius
        thermalWire.peakCelsius = thermal.peakCelsius
        if full {
            thermalWire.socCelsius = thermal.socCelsius
            thermalWire.batteryCelsius = thermal.batteryCelsius
            thermalWire.storageCelsius = thermal.storageCelsius
            thermalWire.sensors = thermal.sensors.map { sensor in
                var wire = WireSensor()
                wire.key = sensor.key
                wire.label = sensor.label
                wire.celsius = sensor.celsius
                wire.category = sensor.category.rawValue
                return wire
            }
            thermalWire.fans = thermal.fans.map { fan in
                var wire = WireFan()
                wire.index = fan.index
                wire.rpm = fan.rpm
                wire.minRPM = fan.minRPM
                wire.maxRPM = fan.maxRPM
                return wire
            }
            switch thermal.thermalState {
            case .fair: thermalWire.state = "fair"
            case .serious: thermalWire.state = "serious"
            case .critical: thermalWire.state = "critical"
            default: thermalWire.state = "nominal"
            }
        }
        sample.thermal = thermalWire

        if power.hasAny {
            var powerWire = WirePower()
            powerWire.cpuWatts = power.cpuWatts
            powerWire.gpuWatts = power.gpuWatts
            powerWire.aneWatts = power.aneWatts
            powerWire.packageWatts = power.packageWatts
            powerWire.systemWatts = power.systemWatts
            powerWire.systemTotalWatts = power.systemTotalWatts
            powerWire.dcInWatts = power.dcInWatts
            powerWire.adapterWatts = power.adapterWatts
            sample.power = powerWire
        }

        var networkWire = WireNetwork()
        networkWire.rx = network.rxBytesPerSecond
        networkWire.tx = network.txBytesPerSecond
        if full {
            networkWire.rxTotal = network.rxTotal
            networkWire.txTotal = network.txTotal
            networkWire.primaryInterface = network.primaryInterface
            networkWire.localAddress = network.localAddress
        }
        sample.network = networkWire

        var diskWire = WireDisk()
        diskWire.read = disk.readBytesPerSecond
        diskWire.write = disk.writeBytesPerSecond
        if full {
            diskWire.readTotal = disk.readTotal
            diskWire.writeTotal = disk.writeTotal
            if disk.capacity > 0 {
                var volume = WireVolume()
                volume.name = disk.volumeName
                volume.mount = "/"
                volume.fs = "apfs"
                volume.total = disk.capacity
                volume.available = disk.available
                if disk.reserved > 0 { volume.used = disk.used }
                diskWire.volumes = [volume]
            }
        }
        sample.disk = diskWire

        if battery.present {
            var batteryWire = WireBattery()
            batteryWire.present = true
            batteryWire.percentage = battery.percentage
            batteryWire.charging = battery.isCharging
            batteryWire.pluggedIn = battery.isPluggedIn
            if full {
                batteryWire.timeRemainingMinutes = battery.timeRemainingMinutes
                batteryWire.cycleCount = battery.cycleCount
                batteryWire.designCapacity = battery.designCapacity
                batteryWire.maxCapacity = battery.maxCapacity
                batteryWire.celsius = battery.celsius
                batteryWire.voltage = battery.voltage
                batteryWire.amperage = battery.amperage
                batteryWire.condition = battery.condition
                batteryWire.systemWatts = battery.systemWatts
                batteryWire.chargingWatts = battery.chargingWatts
                batteryWire.adapterWatts = battery.adapterWatts
            }
            sample.battery = batteryWire
        }

        if full {
            var systemWire = WireSystem()
            systemWire.uptime = timestamp.timeIntervalSince(host.bootTime)
            sample.system = systemWire

            if sleep.sampled {
                var sleepWire = WireSleep()
                sleepWire.sampled = true
                sleepWire.blockers = sleep.blockers.map { blocker in
                    var wire = WireSleepBlocker()
                    wire.pid = blocker.pid
                    wire.name = blocker.name
                    wire.display = blocker.preventsDisplaySleep
                    wire.system = blocker.preventsSystemSleep
                    wire.assertions = blocker.assertionNames
                    return wire
                }
                sample.sleep = sleepWire
            }

            var processesWire = WireProcesses()
            processesWire.count = processes.count
            processesWire.sampledAt = Int64(processes.sampledAt.timeIntervalSince1970 * 1000)
            processesWire.interval = processes.interval
            processesWire.gpuAttribution = processes.gpuAttributionAvailable
            processesWire.rows = processes.rankedUnion().map { row in
                var wire = WireProcessRow()
                wire.pid = row.pid
                wire.name = row.name
                wire.start = row.startTime
                wire.path = row.executablePath
                wire.cpu = row.cpuPercent
                wire.memory = row.memoryBytes
                wire.gpu = row.gpuPercent
                wire.energy = row.energyImpact
                wire.diskRead = row.diskReadBytesPerSecond
                wire.diskWrite = row.diskWriteBytesPerSecond
                wire.wakeups = row.wakeupsPerSecond
                wire.threads = row.threadCount
                return wire
            }
            var rank: [String: [Int32]] = [:]
            for metric in ProcessMetric.allCases {
                let pids = (processes.leaders[metric] ?? []).map(\.pid)
                if !pids.isEmpty { rank[metric.wireKey] = pids }
            }
            processesWire.rank = rank
            sample.processes = processesWire
        }
        return sample
    }
}
