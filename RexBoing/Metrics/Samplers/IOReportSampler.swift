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
    /// Baseline for the DVFS residency deltas. Energy keeps its own running
    /// totals in the meters below, because its window is not the sampling
    /// window — see `EnergyMeter`.
    private var previousSample: CFDictionary?

    /// One meter per SoC block. Each turns the block's cumulative counter
    /// into watts over the span between two *publications* of it, which is
    /// the only span the energy is actually known over.
    private var cpuMeter = EnergyMeter()
    private var gpuMeter = EnergyMeter()
    private var aneMeter = EnergyMeter()
    private var dramMeter = EnergyMeter()
    /// Set by the engine across a sleep or clock step: the next pass only
    /// re-primes every meter, publishing nothing that spans the gap.
    private var needsRebaseline = false

    /// Mach absolute time to seconds, for the drivers' publication stamps.
    private static let secondsPerMachTick: Double = {
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom > 0 else {
            return 1e-9
        }
        return Double(timebase.numer) / Double(timebase.denom) / 1e9
    }()

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
            if group == "Energy Model" {
                Self.pruneEnergyChannels(channels, name: channelName)
            }
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

        // Prime both baselines so the first real sample is meaningful.
        if let first = createSamples(subscription, subscribedChannels, nil)?.takeRetainedValue() {
            previousSample = first
            observeEnergy(in: first)
        }
    }

    // MARK: - Sampling

    /// Called across a sleep or a clock step. Energy is metered between
    /// publications rather than between samples, so a meter left alone would
    /// happily divide joules that straddle the gap by a span that includes it.
    func rebaseline() {
        needsRebaseline = true
    }

    func sample(interval: TimeInterval) -> Reading {
        var reading = Reading()

        guard interval > 0,
              let current = createSamples(subscription, subscribedChannels, nil)?
                .takeRetainedValue()
        else { return reading }

        let previous = previousSample
        previousSample = current

        observeEnergy(in: current)
        reading.power.cpuWatts = cpuMeter.watts
        reading.power.gpuWatts = gpuMeter.watts
        // An idle Neural Engine is power-gated and genuinely reads zero; a
        // "0.00 W" tile for a block nothing is using is noise, not news.
        reading.power.aneWatts = aneMeter.watts.flatMap { $0 > 0 ? $0 : nil }
        // The package is a sum, and a sum with its largest term missing is
        // not a smaller package — it is a different number wearing the
        // label. Where the CPU's counters are not publishing (see
        // `EnergyMeter`), the GPU alone used to be reported as the SoC.
        if let cpu = cpuMeter.watts {
            reading.power.packageWatts = cpu + (gpuMeter.watts ?? 0)
                + (aneMeter.watts ?? 0) + (dramMeter.watts ?? 0)
        }

        guard let previous,
              let delta = createSamplesDelta(previous, current, nil)?.takeRetainedValue()
        else { return reading }

        var efficiencyAccumulator = ResidencyAccumulator(states: efficiencyStates)
        var performanceAccumulator = ResidencyAccumulator(states: performanceStates)
        var gpuAccumulator = ResidencyAccumulator(states: gpuStates)

        iterate(delta) { [self] channel in
            let group = (channelGroup(channel)?.takeUnretainedValue() as String?) ?? ""
            switch group {
            case "CPU Stats":
                let subgroup = (channelSubGroup(channel)?.takeUnretainedValue() as String?) ?? ""
                guard subgroup == "CPU Core Performance States" else { break }
                // Channel names are cluster-scoped: `ECPU`, `PCPU`, `ECPU0`, …
                let name = (channelName(channel)?.takeUnretainedValue() as String?) ?? ""
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

        reading.efficiencyClockMHz = efficiencyAccumulator.averageMHz
        reading.performanceClockMHz = performanceAccumulator.averageMHz
        reading.gpuClockMHz = gpuAccumulator.averageMHz

        return reading
    }

    /// Reads every energy counter's running total and publication stamp out
    /// of a raw sample and feeds the meters.
    ///
    /// Totals, not the delta dictionary: a meter's window runs from one
    /// publication of its block to the next, which on current systems spans
    /// several samples, so it has to hold its own baseline.
    private func observeEnergy(in sample: CFDictionary) {
        let now = ProcessInfo.processInfo.systemUptime
        var totals = EnergyTotals()
        iterate(sample) { [self] channel in
            guard (channelGroup(channel)?.takeUnretainedValue() as String?) == "Energy Model"
            else { return 0 }
            let name = (channelName(channel)?.takeUnretainedValue() as String?) ?? ""
            let kind = Self.channelKind(of: name)
            guard kind != .ignored else { return 0 }
            let unit = (channelUnit(channel)?.takeUnretainedValue() as String?) ?? "mJ"
            let raw = simpleValue(channel, 0)
            totals.add(
                EnergyMeter.Reading(
                    joules: Self.joules(raw, unit: unit),
                    stamp: publicationStamp(of: channel, value: raw, now: now)),
                to: kind)
            return 0
        }

        let rebase = needsRebaseline
        needsRebaseline = false
        for (meter, observed) in [
            (\IOReportSampler.cpuMeter, totals.cpu),
            (\IOReportSampler.gpuMeter, totals.gpu),
            (\IOReportSampler.aneMeter, totals.ane),
            (\IOReportSampler.dramMeter, totals.dram),
        ] {
            if rebase {
                self[keyPath: meter].rebaseline(to: observed, at: now)
            } else {
                self[keyPath: meter].observe(observed, at: now)
            }
        }
    }

    /// When the driver last published this channel, in seconds on the uptime
    /// clock — or `nil` where that cannot be read with confidence.
    ///
    /// The time lives in the channel's raw element: a 64-byte record whose
    /// word at offset 24 is the publication's mach timestamp and whose word
    /// at offset 32 is the counter itself. The layout is private, so it is
    /// checked on every read: the counter word must be exactly the value
    /// IOReport's own accessor returns, and the stamp must be a real time no
    /// later than now. Anything else and the meter falls back to timing
    /// publications by when it noticed them.
    private func publicationStamp(
        of channel: CFDictionary, value: Int64, now: TimeInterval
    ) -> Double? {
        guard let pointer = CFDictionaryGetValue(
            channel, Unmanaged.passUnretained(rawElementsKey).toOpaque())
        else { return nil }
        let object = Unmanaged<CFTypeRef>.fromOpaque(pointer).takeUnretainedValue()
        guard CFGetTypeID(object) == CFDataGetTypeID() else { return nil }
        let data = unsafeDowncast(object, to: CFData.self)
        guard CFDataGetLength(data) >= 40, let bytes = CFDataGetBytePtr(data) else { return nil }
        let raw = UnsafeRawPointer(bytes)
        guard raw.loadUnaligned(fromByteOffset: 32, as: Int64.self) == value else { return nil }
        let stamp = raw.loadUnaligned(fromByteOffset: 24, as: UInt64.self)
        let seconds = Double(stamp) * Self.secondsPerMachTick
        guard stamp > 0, seconds <= now + 1 else { return nil }
        return seconds
    }

    /// Held as instance state for the same reason `GPUSampler` holds its
    /// keys: a `CFString` is immutable in fact but not `Sendable` in type.
    private let rawElementsKey = "RawElements" as CFString

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

    /// Each level of the tree, summed across its channels.
    private struct EnergyTotals {
        var cpuUnit: EnergyMeter.Reading?, cpuCluster: EnergyMeter.Reading?
        var gpuUnit: EnergyMeter.Reading?, gpuRail: EnergyMeter.Reading?
        var aneUnit: EnergyMeter.Reading?, aneRail: EnergyMeter.Reading?
        var dramUnit: EnergyMeter.Reading?, dramRail: EnergyMeter.Reading?

        /// Prefer the roll-up the platform publishes; fall back a level down.
        /// Chosen by whether the channel *exists*, not by whether it moved:
        /// counters now publish in batches, and a level picked afresh by
        /// "which one advanced this time" would switch between two levels'
        /// running totals and meter the difference between them.
        var cpu: EnergyMeter.Reading? { cpuUnit ?? cpuCluster }
        var gpu: EnergyMeter.Reading? { gpuUnit ?? gpuRail }
        var ane: EnergyMeter.Reading? { aneUnit ?? aneRail }
        var dram: EnergyMeter.Reading? { dramUnit ?? dramRail }

        mutating func add(_ reading: EnergyMeter.Reading, to kind: ChannelKind) {
            switch kind {
            case .cpuUnit: cpuUnit = cpuUnit.map { $0 + reading } ?? reading
            case .cpuCluster: cpuCluster = cpuCluster.map { $0 + reading } ?? reading
            case .gpuUnit: gpuUnit = gpuUnit.map { $0 + reading } ?? reading
            case .gpuRail: gpuRail = gpuRail.map { $0 + reading } ?? reading
            case .aneUnit: aneUnit = aneUnit.map { $0 + reading } ?? reading
            case .aneRail: aneRail = aneRail.map { $0 + reading } ?? reading
            case .dramUnit: dramUnit = dramUnit.map { $0 + reading } ?? reading
            case .dramRail: dramRail = dramRail.map { $0 + reading } ?? reading
            case .ignored: break
            }
        }
    }

    /// Cuts the Energy Model subscription down to the channels `channelKind`
    /// actually counts.
    ///
    /// The group is 162 channels on an M1 Pro and several hundred on the
    /// larger chips — per core, per DVFS state, per SRAM bank — of which this
    /// sampler reads eight. Every one subscribed is copied out of the kernel
    /// on each sample and walked by the iterator; subscribing only the eight
    /// took a power sample from 2.0 ms to 1.3 ms. A group whose names match
    /// nothing is left whole, so an unfamiliar chip degrades to the old cost
    /// rather than to no power readout.
    private static func pruneEnergyChannels(
        _ channels: CFMutableDictionary, name: ChannelStringFn
    ) {
        let dictionary = channels as NSMutableDictionary
        guard let all = dictionary["IOReportChannels"] as? [CFDictionary] else { return }
        let kept = NSMutableArray()
        for channel in all {
            let channelName = (name(channel)?.takeUnretainedValue() as String?) ?? ""
            if channelKind(of: channelName) != .ignored { kept.add(channel) }
        }
        guard kept.count > 0 else { return }
        // Mutable, because merging the stats groups appends to this array.
        dictionary["IOReportChannels"] = kept
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
    /// index, or by nothing at all. Deliberately strict, so `GPU SRAM0` and
    /// `PCPUDTL0e` do not match.
    private static func railKind(_ upper: String) -> ChannelKind? {
        for (prefix, kind) in [
            ("GPU", ChannelKind.gpuRail), ("ANE", .aneRail), ("DRAM", .dramRail),
        ] {
            guard upper.hasPrefix(prefix) else { continue }
            let suffix = upper.dropFirst(prefix.count)
            if suffix.allSatisfy(\.isNumber) { return kind }
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

// MARK: - Energy metering

/// Watts for one SoC block, from a cumulative energy counter that is not
/// updated when it is read.
///
/// IOReport's energy counters used to advance on every read, so energy over
/// the sample window divided by the window was the power. On macOS 27 they
/// are *published*: the driver folds the accrued energy into the counter on
/// its own schedule and stamps it. On an M5 Max the mJ channels are reported
/// to publish every ~2.1 s, so a one-second reader sees 0, 36, 0, 33 W —
/// the true figure never once. On the M1 Pro this was written on, the CPU,
/// ANE and DRAM counters went more than ten minutes between publications,
/// while GPU energy kept publishing several times a second. Dividing by the sample window turned all of that into
/// either a blank or a multiple of the truth.
///
/// So a meter measures from one publication to the next: the energy added
/// between them over the time between their stamps. Between publications it
/// holds the last figure — that is the most recent thing actually known —
/// and it lets go after `holdLimit`, or declines to publish at all when the
/// span is so long that the average would describe minutes ago rather than
/// now. A pure value type, so the checks can drive it with a synthetic
/// timeline.
struct EnergyMeter {
    /// One observation: the block's running total and, where the driver's
    /// stamp could be read, when that total was published.
    struct Reading {
        var joules: Double
        /// Seconds on the uptime clock; `nil` when unavailable.
        var stamp: Double?

        /// Two channels of one block, summed. The later stamp stands for
        /// both, since they publish together; one without a stamp makes the
        /// sum unstamped.
        static func + (lhs: Reading, rhs: Reading) -> Reading {
            let stamp: Double? = lhs.stamp.flatMap { left in rhs.stamp.map { max(left, $0) } }
            return Reading(joules: lhs.joules + rhs.joules, stamp: stamp)
        }
    }

    /// A reading averaged over more than this describes the past, not the
    /// present, and is withheld — the same plausibility ceiling every rate
    /// sampler in the engine uses.
    static let maximumSpan: TimeInterval = 30
    /// How long a figure is held after its publication before the block is
    /// treated as having stopped reporting.
    static let holdLimit: TimeInterval = 10
    /// Publications closer together than this are folded into the next span
    /// rather than divided by a sliver of time.
    static let minimumSpan: TimeInterval = 0.05

    /// The current figure, if one is known.
    var watts: Double? { held?.watts }

    private var baseline: (joules: Double, time: Double)?
    private var lastObserved: Reading?
    private var held: (watts: Double, observedAt: Double)?
    /// Cleared, for good, the first time the counter advances without its
    /// stamp moving — proof that whatever sits where the stamp should be is
    /// not a publication time on this system. Publications are then timed by
    /// when they were noticed, which is exact wherever counters update on
    /// every read and approximate where they are batched.
    private(set) var trustsStamps = true

    /// Feeds one observation. `nil` means the block reported nothing this
    /// pass: its held figure only ages.
    mutating func observe(_ reading: Reading?, at now: TimeInterval) {
        guard let reading else {
            expireIfStale(at: now)
            return
        }
        guard let base = baseline, let last = lastObserved else {
            rebaseline(to: reading, at: now)
            return
        }
        // A counter that went backwards was reset — a driver reload. Nothing
        // spanning the reset is meaningful.
        guard reading.joules >= base.joules, reading.joules >= last.joules else {
            rebaseline(to: reading, at: now)
            return
        }

        let advanced = reading.joules > last.joules
        if trustsStamps, advanced, let stamp = reading.stamp, stamp == last.stamp {
            trustsStamps = false
        }
        if trustsStamps, let stamp = reading.stamp, let lastStamp = last.stamp, stamp < lastStamp {
            trustsStamps = false
        }

        let published: Bool
        let publishedAt: Double
        if trustsStamps, let stamp = reading.stamp, let lastStamp = last.stamp {
            published = stamp != lastStamp
            publishedAt = stamp
        } else {
            published = advanced
            publishedAt = now
        }
        lastObserved = reading

        guard published else {
            expireIfStale(at: now)
            return
        }
        let span = publishedAt - base.time
        guard span >= Self.minimumSpan else { return }
        let joules = reading.joules - base.joules
        held = span <= Self.maximumSpan ? (joules / span, now) : nil
        baseline = (reading.joules, publishedAt)
    }

    /// Starts over from this observation, forgetting any figure held.
    mutating func rebaseline(to reading: Reading?, at now: TimeInterval) {
        held = nil
        guard let reading else {
            baseline = nil
            lastObserved = nil
            return
        }
        let time = trustsStamps ? (reading.stamp ?? now) : now
        baseline = (reading.joules, time)
        lastObserved = reading
    }

    private mutating func expireIfStale(at now: TimeInterval) {
        if let held, now - held.observedAt > Self.holdLimit { self.held = nil }
    }
}
