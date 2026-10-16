import Foundation

/// Owns every sampler and produces one coherent `Snapshot` per tick.
///
/// This type is deliberately *not* main-actor isolated: it is confined to the
/// engine's serial sampler queue and nothing else ever touches it.
///
/// Two cadences are in play. The cheap samplers (CPU, memory, GPU, network,
/// disk) run on every tick because the menu bar animation is driven from them.
/// The expensive ones — enumerating several hundred processes and walking the
/// IORegistry for GPU attribution — only run at full rate while the dashboard
/// is on screen, and drop to a slow trickle otherwise. Idle cost matters for
/// something that lives in the menu bar all day.
/// Unchecked because the confinement is by construction rather than by the type
/// system: every member is touched from the engine's serial sampler queue and
/// from nowhere else, and the two flags the engine writes are set through that
/// same queue.
public final class SnapshotSampler: @unchecked Sendable {
    public init() {}

    private let cpu = CPUSampler()
    private let memory = MemorySampler()
    private let gpu = GPUSampler()
    private let thermal = ThermalSampler()
    private let power = IOReportSampler()
    private let systemPower = SystemPowerSampler()
    private let network = NetworkSampler()
    private let disk = DiskSampler()
    private let battery = BatterySampler()
    private let processes = ProcessSampler()
    private let sleepAssertions = SleepAssertionSampler()

    func replaceRunningApplications(
        _ applications: [Int32: RunningApplicationMetadata]
    ) {
        processes.replaceRunningApplications(applications)
    }

    func updateRunningApplication(
        pid: Int32, metadata: RunningApplicationMetadata?
    ) {
        processes.updateRunningApplication(pid: pid, metadata: metadata)
    }

    /// Long-window per-app accounting, fed from every process sample. Queue-
    /// confined like everything else here; the engine routes queries through
    /// the same queue.
    let usageLedger = UsageLedger()

    /// Mirrored onto the sampler queue by the engine; never read from main.
    /// Detailed cards and live process consumers are separate: the process
    /// inspector needs a fresh table, but it does not need a 190-sensor thermal
    /// pass simply because it was opened from the dashboard.
    public var detailedMetricsVisible = false
    public var liveProcessSampling = false
    public var menuPowerReadoutVisible = false
    public var forceProcessSample = false
    /// Set on system wake. On Apple silicon `mach_absolute_time` keeps
    /// advancing through sleep — uptime and wall clock agree across it — so a
    /// sleep shorter than the gap ceiling is indistinguishable from an
    /// ordinary window by clock arithmetic alone, and the deltas spanning it
    /// would be published as if the machine had been awake. The workspace
    /// notification is the reliable signal.
    public var forceResync = false

    private var lastTick: Date?
    private var lastTickUptime: TimeInterval?
    private var lastProcessSample: Date = .distantPast
    private var lastProcessSampleUptime: TimeInterval?
    private var cachedProcesses = ProcessMetrics()

    /// Charge, cycle count and cell temperature all move on the order of
    /// minutes, and reading them walks two IORegistry trees. Sampling that once
    /// a second is pure waste.
    private var lastBatterySampleUptime: TimeInterval?
    private var cachedBattery = BatteryMetrics()
    private let batteryInterval: TimeInterval = 5

    /// IOReport is the largest share of the ordinary sampler tick. Package
    /// power is sampled at the user's cadence while visible and at a slower
    /// cadence solely to retain background history otherwise.
    private var lastPowerSampleUptime: TimeInterval?
    private var cachedPower = IOReportSampler.Reading()
    private var cachedSystemPower = SystemPowerSampler.Reading()
    private let backgroundPowerInterval: TimeInterval = 2

    /// How often processes are re-enumerated when nobody is looking.
    private let backgroundProcessInterval: TimeInterval = 6

    /// Sleep assertions move on the order of app launches and media starting
    /// or stopping, and only the dashboard's power card shows them — so they
    /// are sampled every couple of seconds while it is visible and not at all
    /// otherwise, with a fresh read when it opens.
    private var lastSleepSampleUptime: TimeInterval?
    private var cachedSleep = SleepMetrics()
    private let sleepAssertionInterval: TimeInterval = 2

    /// The most recent full sample, so a process-only refresh has something
    /// coherent to merge into.
    private var latest = Snapshot()
    private var hasSampled = false

    public func tick(refreshInterval: TimeInterval) -> (snapshot: Snapshot, isResync: Bool) {
        let now = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        let wallElapsed = lastTick.map { now.timeIntervalSince($0) } ?? 0
        let uptimeElapsed = lastTickUptime.map { uptime - $0 } ?? 0
        lastTick = now
        lastTickUptime = uptime

        // A gap far longer than the sampling cadence means the machine slept or
        // the clock stepped. Every counter below is a difference against the
        // previous sample, so those differences span the whole gap while the
        // nominal interval does not — substituting it turned an overnight sleep
        // into a several-hundred-watt spike and a gigabyte-per-second network
        // reading. The samplers still run, because that is what re-primes their
        // baselines, but the rates they derive from a broken interval are
        // dropped rather than published.
        // The uptime clock is monotonic, so small wall-clock corrections cannot
        // skew every bytes-per-second reading. A large disagreement between the
        // clocks catches a manual clock change, and on Intel it catches sleep
        // too — Mach uptime pauses there while `Date` advances. On Apple
        // silicon both clocks tick through sleep in step, which is why short
        // sleeps arrive separately, as `forceResync` from the wake
        // notification, rather than being inferred here.
        // The ceiling matches the 30-second plausibility window every rate
        // sampler enforces for itself. Tolerating a longer gap here recorded
        // the tick while the samplers, past their own limit, had quietly left
        // every rate at zero — a fabricated 0-point at the left of each graph
        // after any 31–50 s stall on the slower refresh settings.
        let maximumGap: TimeInterval = 30
        let systemWoke = forceResync
        forceResync = false
        let clocksDiverged = abs(wallElapsed - uptimeElapsed) > 1
        let isResync = !hasSampled || systemWoke || wallElapsed <= 0 || uptimeElapsed <= 0
            || wallElapsed > maximumGap || uptimeElapsed > maximumGap
            || clocksDiverged
        let interval = isResync ? refreshInterval : uptimeElapsed

        if isResync {
            // Cadence clocks deliberately use monotonic uptime, which does not
            // age while the machine sleeps. Invalidate their deadlines here so
            // state that can change during sleep (battery, network, thermals,
            // mounted volume) is refreshed immediately after wake.
            lastBatterySampleUptime = nil
            lastPowerSampleUptime = nil
            lastSleepSampleUptime = nil
            // Energy is metered between publications, not ticks, so the
            // meters carry a baseline of their own that the gap has broken.
            power?.rebaseline()
            thermal.invalidateCadence()
            network.invalidateCachedPrimary()
            disk.invalidateCachedCapacity()
        }

        var next = Snapshot()
        next.timestamp = now
        next.interval = interval
        next.host = HostInfo.current

        next.cpu = cpu.sample()
        next.memory = memory.sample(interval: interval)
        next.gpu = gpu.sample()
        next.thermal = thermal.sample(detailed: detailedMetricsVisible)
        next.network = network.sample(interval: interval)
        next.disk = disk.sample(interval: interval, includeCapacity: detailedMetricsVisible)
        if Cadence.isDue(lastBatterySampleUptime, every: batteryInterval, at: uptime) {
            cachedBattery = battery.sample()
            lastBatterySampleUptime = uptime
        }
        next.battery = cachedBattery

        if detailedMetricsVisible,
           Cadence.isDue(lastSleepSampleUptime, every: sleepAssertionInterval, at: uptime) {
            cachedSleep = sleepAssertions.sample()
            lastSleepSampleUptime = uptime
        }
        next.sleep = cachedSleep

        if shouldSamplePower(uptime: uptime) {
            let powerInterval = lastPowerSampleUptime.map { uptime - $0 } ?? interval
            cachedPower = power?.sample(interval: powerInterval) ?? IOReportSampler.Reading()
            cachedSystemPower = systemPower?.sample() ?? SystemPowerSampler.Reading()
            lastPowerSampleUptime = uptime
        }
        next.power = cachedPower.power
        next.cpu.efficiencyClockMHz = cachedPower.efficiencyClockMHz
        next.cpu.performanceClockMHz = cachedPower.performanceClockMHz
        next.gpu.clockMHz = cachedPower.gpuClockMHz
        next.power.systemTotalWatts = cachedSystemPower.systemTotalWatts
        next.power.dcInWatts = cachedSystemPower.dcInWatts
        if next.power.systemWatts == nil {
            next.power.systemWatts = next.battery.systemWatts
        }
        next.power.adapterWatts = next.battery.adapterWatts

        if isResync { forceProcessSample = true }
        if shouldSampleProcesses(
            now: now, uptime: uptime, refreshInterval: refreshInterval
        ) {
            // A resync means the window is broken even when its length looks
            // plausible — a short sleep on Apple silicon leaves both clocks
            // agreeing — so the per-process deltas are discarded explicitly
            // rather than trusted to the window test below.
            sampleProcesses(now: now, uptime: uptime, discardDeltas: isResync)
        }

        if isResync {
            Self.clearIntervalDerivedValues(in: &next)
            // Do not reattach a rejected power or residency sample on the next
            // background tick before IOReport is sampled again.
            cachedPower = IOReportSampler.Reading()
        }

        attachProcesses(to: &next)
        latest = next
        hasSampled = true
        return (next, isResync)
    }

    /// Blanks fields whose sample window crossed a sleep or clock step.
    ///
    /// CPU load and clock residency are ratios rather than bytes-per-second,
    /// but they are still ratios over that old window. Publishing work done by
    /// a dark wake as the load immediately after the display wakes is just as
    /// misleading as publishing its disk traffic, so those baselines are
    /// re-primed too. GPU utilisation is an instantaneous registry value and
    /// remains valid.
    private static func clearIntervalDerivedValues(in snapshot: inout Snapshot) {
        snapshot.cpu.total = 0
        snapshot.cpu.user = 0
        snapshot.cpu.system = 0
        snapshot.cpu.nice = 0
        snapshot.cpu.idle = 1
        snapshot.cpu.perCore = Array(repeating: 0, count: snapshot.cpu.perCore.count)
        snapshot.cpu.efficiencyLoad = 0
        snapshot.cpu.performanceLoad = 0
        snapshot.cpu.efficiencyClockMHz = nil
        snapshot.cpu.performanceClockMHz = nil
        snapshot.gpu.clockMHz = nil
        snapshot.memory.swap.inRate = 0
        snapshot.memory.swap.outRate = 0
        snapshot.network.rxBytesPerSecond = 0
        snapshot.network.txBytesPerSecond = 0
        snapshot.disk.readBytesPerSecond = 0
        snapshot.disk.writeBytesPerSecond = 0
        snapshot.power.cpuWatts = nil
        snapshot.power.gpuWatts = nil
        snapshot.power.aneWatts = nil
        snapshot.power.packageWatts = nil
    }

    /// Re-reads only the process table and merges it into the last full sample.
    ///
    /// Used when the dashboard opens, where the process list may be up to
    /// `backgroundProcessInterval` stale. Running a whole `tick` instead would
    /// reset every rate sampler's baseline a few milliseconds after the last
    /// one, so CPU load, throughput and swap rates would all read zero for the
    /// first frame the user sees — which is precisely the frame they opened the
    /// panel to look at.
    ///
    /// Returns `nil` before the first full tick, when there is nothing to
    /// merge into.
    public func refreshProcesses() -> Snapshot? {
        guard hasSampled, !forceResync else { return nil }
        let now = Date()
        sampleProcesses(now: now, uptime: ProcessInfo.processInfo.systemUptime)
        // The dashboard is opening, and the cached assertion set can be
        // arbitrarily stale from the last time it was open — the flag flip that
        // resumes sampling rides the same serial queue and may land after this
        // refresh. One Mach call here keeps the first frame honest.
        cachedSleep = sleepAssertions.sample()
        lastSleepSampleUptime = ProcessInfo.processInfo.systemUptime
        latest.sleep = cachedSleep
        if detailedMetricsVisible { disk.refreshCapacity(in: &latest.disk) }
        attachProcesses(to: &latest)
        return latest
    }

    private func sampleProcesses(
        now: Date, uptime: TimeInterval, discardDeltas: Bool = false
    ) {
        let wallElapsed = now.timeIntervalSince(lastProcessSample)
        let uptimeElapsed = lastProcessSampleUptime.map { uptime - $0 }
        let elapsed = uptimeElapsed ?? wallElapsed
        // A near-zero window makes every per-process delta meaningless.
        guard discardDeltas || elapsed >= 0.1 else { return }

        // Use monotonic uptime during an ordinary window, so a wall-clock
        // correction cannot skew every process rate. Across sleep or a clock
        // step, still read every counter to establish a new baseline but do
        // not publish the deltas: they span work that belongs to no one moment
        // on the dashboard.
        let plausibleWindow = !discardDeltas
            && uptimeElapsed != nil && elapsed > 0 && elapsed <= 30
            && wallElapsed > 0 && wallElapsed <= 30
            && abs(wallElapsed - elapsed) <= 1
        let sampled = processes.sample(
            interval: max(0.1, elapsed),
            discardCounterDeltas: !plausibleWindow)
        cachedProcesses = sampled.metrics
        if plausibleWindow {
            // Implausible windows never reach the ledger — their absence is
            // what its coverage figure reports. Recorded here, at the only
            // place fresh tables are made, so the out-of-band refresh the
            // dashboard triggers is accounted exactly once like any other.
            usageLedger.record(
                sampled.workDeltas, endingAt: now, interval: elapsed)
        }
        // Stamped here rather than inside the sampler: this is where the table
        // is dated, and history needs both numbers to tell a fresh table from a
        // re-attached one and a real window from one that spans a sleep.
        cachedProcesses.sampledAt = now
        cachedProcesses.interval = plausibleWindow ? elapsed : 31
        lastProcessSample = now
        lastProcessSampleUptime = uptime
        forceProcessSample = false
    }

    private func attachProcesses(to snapshot: inout Snapshot) {
        snapshot.processes = cachedProcesses
    }

    private func shouldSampleProcesses(
        now: Date, uptime: TimeInterval, refreshInterval: TimeInterval
    ) -> Bool {
        if forceProcessSample { return true }
        let elapsed = lastProcessSampleUptime.map { uptime - $0 }
            ?? now.timeIntervalSince(lastProcessSample)
        // Below ~0.4s the CPU deltas get noisy and the cost stops being worth it.
        // Both gates carry `Cadence.slack`: consecutive ticks land a few
        // milliseconds short of their nominal spacing about half the time,
        // and without it the live table refreshed on alternate ticks while
        // the dashboard was open.
        let foreground = max(0.4, refreshInterval)
        if liveProcessSampling { return elapsed >= foreground - Cadence.slack }

        // Sampling can only land on an engine tick. Aim for the nearest tick to
        // six seconds instead of always rounding upward: at the 5 s refresh
        // setting the old rule produced one process sample every 10 s, making
        // retained history much coarser than the preference implied.
        let background = max(
            refreshInterval, backgroundProcessInterval - refreshInterval / 2)
        return elapsed >= background - Cadence.slack
    }

    private func shouldSamplePower(uptime: TimeInterval) -> Bool {
        guard power != nil || systemPower != nil else { return false }
        return detailedMetricsVisible || menuPowerReadoutVisible
            || Cadence.isDue(lastPowerSampleUptime, every: backgroundPowerInterval, at: uptime)
    }
}
