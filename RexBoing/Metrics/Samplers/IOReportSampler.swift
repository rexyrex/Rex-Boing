import Foundation
import IOKit

/// Power draw and DVFS clock residency via `IOReport`.
///
/// This is how `powermetrics` gets its numbers, except `powermetrics` needs
/// root and IOReport does not. The framework ships inside the dyld shared
/// cache with no headers, so the handful of entry points used here are bound
/// at runtime. If any of them is missing the sampler disables itself and the
/// dashboard hides the power and clock rows.
final class IOReportSampler {
    private typealias CopyChannelsFn = @convention(c)
        (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    private typealias MergeChannelsFn = @convention(c)
        (CFMutableDictionary?, CFMutableDictionary?, CFTypeRef?) -> Void
    private typealias CreateSubscriptionFn = @convention(c)
        (UnsafeMutableRawPointer?, CFMutableDictionary?,
         UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64, CFTypeRef?)
        -> Unmanaged<CFTypeRef>?
    private typealias CreateSamplesFn = @convention(c)
        (CFTypeRef?, CFMutableDictionary?, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias CreateSamplesDeltaFn = @convention(c)
        (CFDictionary?, CFDictionary?, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias IterateFn = @convention(c)
        (CFDictionary?, @convention(block) (CFDictionary) -> Int32) -> Void
    private typealias ChannelStringFn = @convention(c) (CFDictionary?) -> Unmanaged<CFString>?
    private typealias StateCountFn = @convention(c) (CFDictionary?) -> Int32
    private typealias StateNameFn = @convention(c) (CFDictionary?, Int32) -> Unmanaged<CFString>?
    private typealias StateResidencyFn = @convention(c) (CFDictionary?, Int32) -> Int64
    private typealias SimpleValueFn = @convention(c) (CFDictionary?, Int32) -> Int64

    private let copyChannels: CopyChannelsFn
    private let mergeChannels: MergeChannelsFn
    private let createSamples: CreateSamplesFn
    private let createSamplesDelta: CreateSamplesDeltaFn
    private let iterate: IterateFn
    private let channelName: ChannelStringFn
    private let channelGroup: ChannelStringFn
    private let channelSubGroup: ChannelStringFn
    private let channelUnit: ChannelStringFn
    private let stateCount: StateCountFn
    private let stateName: StateNameFn
    private let stateResidency: StateResidencyFn
    private let simpleValue: SimpleValueFn

    private let subscription: CFTypeRef
    private let subscribedChannels: CFMutableDictionary
    private var previousSample: CFDictionary?
    /// When `previousSample` was taken, on the uptime clock.
    ///
    /// The energy deltas span the window since the baseline was *taken*, which
    /// is not necessarily the window the caller tracks: if a read ever fails,
    /// the old baseline stays in place, and dividing its two-interval delta by
    /// the caller's one interval would double every wattage. The sampler
    /// therefore clocks its own baseline — on uptime rather than wall time,
    /// because the counters only accrue while the machine is awake.
    private var previousSampleTime: TimeInterval?

    /// DVFS frequency tables, in MHz, indexed by performance state.
    private let efficiencyStates: [Double]
    private let performanceStates: [Double]
    private let gpuStates: [Double]

    struct Reading {
        var power = PowerMetrics()
        var efficiencyClockMHz: Double?
        var performanceClockMHz: Double?
        var gpuClockMHz: Double?
    }

    init?() {
        guard let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY) else { return nil }

        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }

        guard
            let copyChannels = symbol("IOReportCopyChannelsInGroup", as: CopyChannelsFn.self),
            let mergeChannels = symbol("IOReportMergeChannels", as: MergeChannelsFn.self),
            let createSubscription = symbol("IOReportCreateSubscription", as: CreateSubscriptionFn.self),
            let createSamples = symbol("IOReportCreateSamples", as: CreateSamplesFn.self),
            let createSamplesDelta = symbol("IOReportCreateSamplesDelta", as: CreateSamplesDeltaFn.self),
            let iterate = symbol("IOReportIterate", as: IterateFn.self),
            let channelName = symbol("IOReportChannelGetChannelName", as: ChannelStringFn.self),
            let channelGroup = symbol("IOReportChannelGetGroup", as: ChannelStringFn.self),
            let channelSubGroup = symbol("IOReportChannelGetSubGroup", as: ChannelStringFn.self),
            let channelUnit = symbol("IOReportChannelGetUnitLabel", as: ChannelStringFn.self),
            let stateCount = symbol("IOReportStateGetCount", as: StateCountFn.self),
            let stateName = symbol("IOReportStateGetNameForIndex", as: StateNameFn.self),
            let stateResidency = symbol("IOReportStateGetResidency", as: StateResidencyFn.self),
            let simpleValue = symbol("IOReportSimpleGetIntegerValue", as: SimpleValueFn.self)
        else { return nil }

        // Energy for the power readout; the two state groups for clock speeds.
        let requested: [(String, String?)] = [
            ("Energy Model", nil),
            ("CPU Stats", "CPU Core Performance States"),
            ("GPU Stats", "GPU Performance States"),
        ]

        var merged: CFMutableDictionary?
        for (group, subgroup) in requested {
            guard let channels = copyChannels(
                group as CFString, subgroup as CFString?, 0, 0, 0)?.takeRetainedValue()
            else { continue }
            if let existing = merged {
                mergeChannels(existing, channels, nil)
            } else {
                merged = channels
            }
        }

        guard let desired = merged else { return nil }

        var subscribed: Unmanaged<CFMutableDictionary>?
        guard let subscription = createSubscription(nil, desired, &subscribed, 0, nil)?
            .takeRetainedValue(),
            let subscribedChannels = subscribed?.takeRetainedValue()
        else { return nil }

        self.copyChannels = copyChannels
        self.mergeChannels = mergeChannels
        self.createSamples = createSamples
        self.createSamplesDelta = createSamplesDelta
        self.iterate = iterate
        self.channelName = channelName
        self.channelGroup = channelGroup
        self.channelSubGroup = channelSubGroup
        self.channelUnit = channelUnit
        self.stateCount = stateCount
        self.stateName = stateName
        self.stateResidency = stateResidency
        self.simpleValue = simpleValue
        self.subscription = subscription
        self.subscribedChannels = subscribedChannels

        self.efficiencyStates = Self.frequencyTable(key: "voltage-states1-sram")
        self.performanceStates = Self.frequencyTable(key: "voltage-states5-sram")
        self.gpuStates = Self.frequencyTable(key: "voltage-states9")

        // Prime the delta baseline so the first real sample is meaningful.
        previousSample = createSamples(subscription, subscribedChannels, nil)?.takeRetainedValue()
        if previousSample != nil {
            previousSampleTime = ProcessInfo.processInfo.systemUptime
        }
    }

    // MARK: - Sampling

    func sample(interval: TimeInterval) -> Reading {
        var reading = Reading()

        guard interval > 0,
              let current = createSamples(subscription, subscribedChannels, nil)?
                .takeRetainedValue()
        else { return reading }

        // The true span of the delta below. The caller's interval is only the
        // fallback for a baseline whose age nothing recorded.
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = previousSampleTime.map { now - $0 } ?? interval

        defer {
            previousSample = current
            previousSampleTime = now
        }

        guard elapsed > 0,
              let previous = previousSample,
              let delta = createSamplesDelta(previous, current, nil)?.takeRetainedValue()
        else { return reading }

        var energy = EnergyTotals()

        var efficiencyAccumulator = ResidencyAccumulator(states: efficiencyStates)
        var performanceAccumulator = ResidencyAccumulator(states: performanceStates)
        var gpuAccumulator = ResidencyAccumulator(states: gpuStates)

        iterate(delta) { [self] channel in
            let group = (channelGroup(channel)?.takeUnretainedValue() as String?) ?? ""
            let name = (channelName(channel)?.takeUnretainedValue() as String?) ?? ""

            switch group {
            case "Energy Model":
                let unit = (channelUnit(channel)?.takeUnretainedValue() as String?) ?? "mJ"
                let joules = Self.joules(simpleValue(channel, 0), unit: unit)
                energy.add(joules, to: Self.channelKind(of: name))

            case "CPU Stats":
                let subgroup = (channelSubGroup(channel)?.takeUnretainedValue() as String?) ?? ""
                guard subgroup == "CPU Core Performance States" else { break }
                // Channel names are cluster-scoped: `ECPU`, `PCPU`, `ECPU0`, …
                let upper = name.uppercased()
                if upper.hasPrefix("E") {
                    accumulate(channel, into: &efficiencyAccumulator)
                } else if upper.hasPrefix("P") {
                    accumulate(channel, into: &performanceAccumulator)
                }

            case "GPU Stats":
                // This group also carries temperature and power-zone channels
                // whose state layout is unrelated to the DVFS table.
                let subgroup = (channelSubGroup(channel)?.takeUnretainedValue() as String?) ?? ""
                guard subgroup == "GPU Performance States" else { break }
                accumulate(channel, into: &gpuAccumulator)

            default:
                break
            }
            return 0
        }

        let cpuEnergy = energy.cpu
        let gpuEnergy = energy.gpu
        let aneEnergy = energy.ane

        if cpuEnergy > 0 { reading.power.cpuWatts = cpuEnergy / elapsed }
        if gpuEnergy > 0 { reading.power.gpuWatts = gpuEnergy / elapsed }
        if aneEnergy > 0 { reading.power.aneWatts = aneEnergy / elapsed }

        let total = cpuEnergy + gpuEnergy + aneEnergy + energy.dram
        if total > 0 { reading.power.packageWatts = total / elapsed }

        reading.efficiencyClockMHz = efficiencyAccumulator.averageMHz
        reading.performanceClockMHz = performanceAccumulator.averageMHz
        reading.gpuClockMHz = gpuAccumulator.averageMHz

        return reading
    }

    // MARK: - Energy channels

    /// Which level of the Energy Model tree a channel sits at.
    ///
    /// The group is a *hierarchy*, not a list. An M1 Pro publishes, all
    /// describing the same joules:
    ///
    ///     PACC0_CPU3   per core
    ///     PACC0_CPU    per cluster
    ///     CPU Energy   whole unit
    ///     PCPUDTL0e    per DVFS state, per cluster
    ///
    /// Adding up everything whose name contains "CPU" therefore counts the
    /// same energy three or four times over — measured at 3.6× the true figure
    /// on an M1 Pro, and 2.1× for the GPU. Only the whole-unit roll-up is
    /// counted, with the cluster level kept as a fallback for chips that do not
    /// publish one.
    private enum ChannelKind {
        case cpuUnit, cpuCluster
        case gpuUnit, gpuRail
        case aneUnit, aneRail
        case dramUnit, dramRail
        case ignored
    }

    private struct EnergyTotals {
        var cpuUnit = 0.0, cpuCluster = 0.0
        var gpuUnit = 0.0, gpuRail = 0.0
        var aneUnit = 0.0, aneRail = 0.0
        var dramUnit = 0.0, dramRail = 0.0

        /// Prefer the roll-up the platform publishes; fall back a level down.
        var cpu: Double { cpuUnit > 0 ? cpuUnit : cpuCluster }
        var gpu: Double { gpuUnit > 0 ? gpuUnit : gpuRail }
        var ane: Double { aneUnit > 0 ? aneUnit : aneRail }
        var dram: Double { dramUnit > 0 ? dramUnit : dramRail }

        mutating func add(_ joules: Double, to kind: ChannelKind) {
            switch kind {
            case .cpuUnit: cpuUnit += joules
            case .cpuCluster: cpuCluster += joules
            case .gpuUnit: gpuUnit += joules
            case .gpuRail: gpuRail += joules
            case .aneUnit: aneUnit += joules
            case .aneRail: aneRail += joules
            case .dramUnit: dramUnit += joules
            case .dramRail: dramRail += joules
            case .ignored: break
            }
        }
    }

    private static func channelKind(of name: String) -> ChannelKind {
        let upper = name.uppercased()

        // Apple's whole-unit roll-ups are the ones suffixed " Energy".
        switch upper {
        case "CPU ENERGY": return .cpuUnit
        case "GPU ENERGY": return .gpuUnit
        case "ANE ENERGY": return .aneUnit
        case "DRAM ENERGY": return .dramUnit
        default: break
        }

        // Named rails, one per functional block: `GPU0`, `ANE0`, `DRAM0`.
        if let rail = railKind(upper) { return rail }

        // Cluster roll-ups end in `_CPU` — `EACC_CPU`, `PACC0_CPU`. Per-core
        // channels end in a digit (`PACC0_CPU3`) and so do not match, which is
        // exactly the distinction that matters here.
        if upper.hasSuffix("_CPU") { return .cpuCluster }

        return .ignored
    }

    /// `GPU0`, `ANE0`, `DRAM0` — a block name followed only by its instance
    /// index. Deliberately strict, so `GPU SRAM0` and `PCPUDTL0e` do not match.
    private static func railKind(_ upper: String) -> ChannelKind? {
        for (prefix, kind) in [
            ("GPU", ChannelKind.gpuRail), ("ANE", .aneRail), ("DRAM", .dramRail),
        ] {
            guard upper.hasPrefix(prefix) else { continue }
            let suffix = upper.dropFirst(prefix.count)
            if !suffix.isEmpty, suffix.allSatisfy(\.isNumber) { return kind }
        }
        return nil
    }

    // MARK: - Residency

    /// Weighted mean of the DVFS frequency table over the interval, ignoring
    /// idle/off states so the number reads as "clock while actually running"
    /// rather than being dragged to zero by idle time.
    private struct ResidencyAccumulator {
        let states: [Double]
        var weighted: Double = 0
        var total: Double = 0

        var averageMHz: Double? {
            guard !states.isEmpty, total > 0 else { return nil }
            return weighted / total
        }
    }

    private func accumulate(_ channel: CFDictionary, into accumulator: inout ResidencyAccumulator) {
        guard !accumulator.states.isEmpty else { return }
        let count = Int(stateCount(channel))
        // Private APIs deserve a hard structural bound: a corrupt or changed
        // state count must not turn one telemetry tick into an enormous loop.
        guard count > 0, count <= 256 else { return }

        // The residency array leads with idle/off buckets and then holds one
        // bucket per DVFS state — but it is padded out to a fixed width, so the
        // trailing buckets are meaningless. The GPU channel, for instance,
        // reports 16 buckets for a 6-entry frequency table.
        //
        // Mapping by ordinal among the non-idle buckets is therefore the only
        // alignment that holds for both the CPU clusters and the GPU.
        var ordinal = 0
        for index in 0..<count {
            let name = (stateName(channel, Int32(index))?.takeUnretainedValue() as String?) ?? ""
            let upper = name.uppercased()
            if upper.contains("IDLE") || upper.contains("OFF") || upper.contains("DOWN") {
                continue
            }
            defer { ordinal += 1 }
            guard ordinal < accumulator.states.count else { break }

            let residency = Double(stateResidency(channel, Int32(index)))
            guard residency > 0 else { continue }
            accumulator.weighted += residency * accumulator.states[ordinal]
            accumulator.total += residency
        }
    }

    // MARK: - Static helpers

    private static func joules(_ raw: Int64, unit: String) -> Double {
        let value = Double(max(0, raw))
        switch unit.trimmingCharacters(in: .whitespaces) {
        case "mJ": return value / 1_000
        case "uJ", "µJ", "μJ": return value / 1_000_000
        case "nJ": return value / 1_000_000_000
        case "J": return value
        default: return value / 1_000
        }
    }

    /// Reads a DVFS table out of the power-manager node in the device tree.
    /// Entries are `(frequency, voltage)` pairs of 32-bit words.
    private static func frequencyTable(key: String) -> [Double] {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/arm-io/pmgr")
        guard entry != 0 else { return [] }
        defer { IOObjectRelease(entry) }

        guard let data = IORegistryEntryCreateCFProperty(
            entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data,
            data.count >= 8
        else { return [] }

        var frequencies: [Double] = []
        data.withUnsafeBytes { buffer in
            let pairCount = buffer.count / 8
            for index in 0..<pairCount {
                let raw = buffer.loadUnaligned(fromByteOffset: index * 8, as: UInt32.self)
                guard raw > 0 else { continue }
                frequencies.append(normalizeToMHz(Double(raw)))
            }
        }
        return frequencies
    }

    /// Tables are published in Hz on some chips and kHz on others.
    private static func normalizeToMHz(_ value: Double) -> Double {
        if value > 1_000_000_0 { return value / 1_000_000 }
        if value > 1_000_0 { return value / 1_000 }
        return value
    }
}
