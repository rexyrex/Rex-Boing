import Foundation
import Darwin
import IOKit

/// The LaunchServices metadata a ranked process row needs.
///
/// `NSRunningApplication` resolves some of its properties through synchronous
/// LaunchServices XPC. Keeping those objects in the sampler and asking every
/// one for its pid on every pass made app labelling a surprisingly large share
/// of a background process scan. The main-actor engine maintains this small,
/// value-only catalogue from workspace launch/termination notifications and
/// hands snapshots to the sampler queue.
struct RunningApplicationMetadata: Sendable {
    var localizedName: String?
    var bundleIdentifier: String?
}

/// One pass over the process table: the ranked rate rows the dashboard shows,
/// and the same pass's counter deltas re-expressed as per-app *work* for the
/// usage ledger. Both come from one set of syscalls; splitting them into two
/// passes would double the most expensive thing the sampler does.
struct ProcessSampleResult {
    var metrics = ProcessMetrics()
    /// Per-app work over the sample window, aggregated across each app's
    /// member processes and floored to measurable amounts. Empty when counter
    /// deltas were discarded (first sample, sleep, clock step).
    var workDeltas: [AppWorkDelta] = []
}

/// Per-process CPU, memory, energy and GPU usage.
///
/// CPU and energy are cumulative counters, so everything here is a delta
/// against the previous sample. Processes that appeared since the last sample
/// have no baseline and report 0% for one interval rather than a spike.
final class ProcessSampler {
    private struct Baseline {
        /// Mach absolute time units, not nanoseconds — see
        /// `nanosecondsPerCPUTick`. Named for what it is so the next reader
        /// does not have to rediscover the difference the hard way.
        var cpuTicks: UInt64
        /// `nil` when `proc_pid_rusage` failed for this pass. Keeping that
        /// absence in the baseline prevents the next successful read from being
        /// differenced against zero and reported as a lifetime-sized spike.
        var energyNanojoules: UInt64?
        /// `nil` when GPU attribution was skipped for that sample. Treating a
        /// skipped sample as zero would credit the next one with the process's
        /// entire lifetime of GPU time — every row reading 100% on the first
        /// frame after the dashboard opens.
        var gpuNanos: UInt64?
        var startTime: UInt64
        /// Cumulative real disk I/O and interrupt wakeups — same rusage read
        /// as the energy counter, same nil-when-it-failed rule. Defaulted so
        /// the GPU-only rows, which have no rusage at all, take nil for free.
        ///
        /// Interrupt wakeups, not `ri_pkg_idle_wkups`: the package-idle
        /// counter is an Intel concept the kernel does not account on Apple
        /// silicon — it reads zero forever there, checked empirically — while
        /// `ri_interrupt_wkups` counts exactly (a 100 Hz timer measures 100/s)
        /// on both architectures.
        var diskBytesRead: UInt64? = nil
        var diskBytesWritten: UInt64? = nil
        var wakeups: UInt64? = nil
    }

    private var baselines: [Int32: Baseline] = [:]
    private let gpuAttribution = GPUProcessAttribution()

    /// Nanoseconds in one unit of `pti_total_user` / `pti_total_system`.
    ///
    /// Those counters are *mach absolute time*, not nanoseconds — they come
    /// from `TASK_ABSOLUTETIME_INFO`, whose unit is whatever `mach_timebase_info`
    /// says it is. On Intel that ratio is 1:1 and the distinction never
    /// surfaces, which is exactly why treating them as nanoseconds survives
    /// review. On Apple silicon a tick is 41.67 ns, so the same arithmetic
    /// understates every process by a factor of forty: a thread spinning flat
    /// out on one core reports 2.4% instead of 100%.
    private static let nanosecondsPerCPUTick: Double = {
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom > 0 else {
            return 1
        }
        return Double(timebase.numer) / Double(timebase.denom)
    }()

    /// The parts of a process that never change while it lives.
    private struct Identity {
        var name: String
        var path: String?
        /// Validated against the process start time so a recycled pid cannot
        /// inherit the previous occupant's name or path.
        var startTime: UInt64
        /// Which app this process's work is filed under — derived from the
        /// path, so cached with it for the same lifetime.
        var attribution: AppAttribution
    }

    /// Identities, keyed by pid.
    ///
    /// `proc_pidpath` is a syscall that fills a 4 KB buffer, and it was being
    /// called for every process on every sample — several hundred syscalls and
    /// a megabyte of transient allocation per second, to re-derive a string
    /// that never changes for the life of a process.
    ///
    /// The name is cached beside it for the same reason, and for a second one:
    /// history retains these rows for the length of its window, so a name
    /// rebuilt every sample would be held ninety times over instead of shared.
    private var identities: [Int32: Identity] = [:]

    /// Mirrored from `MetricsEngine` onto the sampler queue. Values change only
    /// when LaunchServices reports an app launch or termination, instead of
    /// being re-fetched through XPC on every process sample.
    private var runningApplications: [Int32: RunningApplicationMetadata] = [:]

    func replaceRunningApplications(
        _ applications: [Int32: RunningApplicationMetadata]
    ) {
        runningApplications = applications
    }

    func updateRunningApplication(
        pid: Int32, metadata: RunningApplicationMetadata?
    ) {
        if let metadata {
            runningApplications[pid] = metadata
        } else {
            runningApplications.removeValue(forKey: pid)
        }
    }

    func sample(
        interval: TimeInterval, discardCounterDeltas: Bool = false
    ) -> ProcessSampleResult {
        var result = ProcessSampleResult()
        guard interval > 0 else { return result }
        var metrics = ProcessMetrics()
        /// Per-app accumulation for the ledger, keyed by attribution. Built
        /// only from windows whose deltas are trustworthy — the same rule the
        /// rate columns use.
        var work: [String: AppWorkDelta] = [:]
        let collectWork = !discardCounterDeltas

        let gpuTimes = gpuAttribution.accumulatedGPUTime()
        // An empty result means the walk found nothing this pass, not that
        // every client reset to zero. Recording zeroes would make the next
        // sample credit each process with its entire lifetime of GPU time.
        let gpuSampled = !gpuTimes.isEmpty
        metrics.gpuAttributionAvailable = gpuAttribution.available

        var rows: [ProcessRow] = []
        var nextBaselines: [Int32: Baseline] = [:]
        var nextIdentities: [Int32: Identity] = [:]
        // The all-process list is needed only for the system-wide count. Detailed
        // libproc reads are permitted for this uid's processes; asking for every
        // root/other-user pid merely produces hundreds of predictable EPERMs.
        // Cross-user GPU clients are still recovered by the independent
        // IORegistry pass below.
        let processCount = processIDs(type: UInt32(PROC_ALL_PIDS), typeInfo: 0)
            .lazy.filter { $0 > 0 }.count
        let pids = processIDs(type: UInt32(PROC_UID_ONLY), typeInfo: getuid())
        rows.reserveCapacity(pids.count)
        nextBaselines.reserveCapacity(pids.count)
        nextIdentities.reserveCapacity(pids.count)

        for pid in pids {
            guard pid > 0 else { continue }
            // A process can exit between the uid-filtered list and this read.
            guard var info = taskAllInfo(pid: pid) else { continue }

            let cpuTicks = info.ptinfo.pti_total_user + info.ptinfo.pti_total_system
            // Guards against a recycled pid being credited with the previous
            // occupant's CPU time.
            let startTime = Self.startTime(
                seconds: info.pbsd.pbi_start_tvsec,
                microseconds: info.pbsd.pbi_start_tvusec)

            let identity: Identity
            // The name comes along for free with the fetched info, and it is
            // the exec detector: `execve` replaces the image — and with it the
            // name, path and rightful attribution — without touching the start
            // time, so a (pid, startTime) key alone would pin a wrapper's
            // identity to the process for life. A `gradlew` script that execs
            // the JVM would stay filed under bash in every ranking and ledger
            // row until it exited.
            let currentName = processName(pid: pid, info: &info)
            if let cached = identities[pid], cached.startTime == startTime,
               cached.name == currentName {
                identity = cached
            } else {
                let path = executablePath(pid: pid)
                identity = Identity(
                    name: currentName,
                    path: path,
                    startTime: startTime,
                    attribution: Self.attribution(name: currentName, path: path))
            }
            nextIdentities[pid] = identity

            var row = ProcessRow(pid: pid, name: identity.name, startTime: startTime)
            row.executablePath = identity.path
            row.threadCount = Int(info.ptinfo.pti_threadnum)

            // `phys_footprint` is what Activity Monitor calls "Memory"; it is a
            // truer number than resident size because it counts compressed and
            // IOKit-mapped pages. Both calls are gated by the same same-owner
            // check, so by this point rusage only fails for a process that
            // exited between the two reads; resident size covers that race.
            var energyNanojoules: UInt64?
            var diskBytesRead: UInt64?
            var diskBytesWritten: UInt64?
            var wakeups: UInt64?
            if let usage = resourceUsage(pid: pid) {
                row.memoryBytes = usage.ri_phys_footprint
                energyNanojoules = usage.ri_energy_nj
                diskBytesRead = usage.ri_diskio_bytesread
                diskBytesWritten = usage.ri_diskio_byteswritten
                wakeups = usage.ri_interrupt_wkups
            } else {
                row.memoryBytes = info.ptinfo.pti_resident_size
            }

            // A missing client is not a zero counter. Drivers may omit a
            // client transiently even during a valid walk; retain absence so
            // its return cannot be charged its entire lifetime of GPU work.
            let gpuNanos: UInt64? = gpuSampled ? gpuTimes[pid] : nil

            // The ledger's copy of the same deltas the rate columns are about
            // to be derived from — work, not rates, because work sums exactly
            // across any span while rates only average approximately.
            var contribution = AppWorkDelta(attribution: identity.attribution)

            if let previous = baselines[pid], previous.startTime == startTime,
               !discardCounterDeltas {
                let cpuDelta = cpuTicks >= previous.cpuTicks ? cpuTicks - previous.cpuTicks : 0
                contribution.cpuNanos = UInt64(
                    Double(cpuDelta) * Self.nanosecondsPerCPUTick)
                // Percent of one core, so this exceeds 100 for multi-threaded
                // work — the same convention Activity Monitor's %CPU uses.
                row.cpuPercent = Double(cpuDelta) * Self.nanosecondsPerCPUTick
                    / (interval * 1_000_000_000) * 100

                if let energyNanojoules, let previousEnergy = previous.energyNanojoules {
                    let energyDelta = energyNanojoules >= previousEnergy
                        ? energyNanojoules - previousEnergy : 0
                    contribution.energyNanojoules = energyDelta
                    row.energyImpact = Self.energyImpact(
                        nanojoules: energyDelta, interval: interval)
                }

                if let gpuNanos, let previousGPU = previous.gpuNanos {
                    let gpuDelta = gpuNanos >= previousGPU ? gpuNanos - previousGPU : 0
                    contribution.gpuNanos = gpuDelta
                    row.gpuPercent = min(
                        100, Double(gpuDelta) / (interval * 1_000_000_000) * 100)
                }

                if let diskBytesRead, let previousRead = previous.diskBytesRead {
                    let delta = diskBytesRead >= previousRead
                        ? diskBytesRead - previousRead : 0
                    contribution.diskReadBytes = delta
                    row.diskReadBytesPerSecond = Double(delta) / interval
                }
                if let diskBytesWritten, let previousWritten = previous.diskBytesWritten {
                    let delta = diskBytesWritten >= previousWritten
                        ? diskBytesWritten - previousWritten : 0
                    contribution.diskWriteBytes = delta
                    row.diskWriteBytesPerSecond = Double(delta) / interval
                }
                if let wakeups, let previousWakeups = previous.wakeups {
                    let delta = wakeups >= previousWakeups
                        ? wakeups - previousWakeups : 0
                    contribution.wakeups = delta
                    row.wakeupsPerSecond = Double(delta) / interval
                }
            }

            nextBaselines[pid] = Baseline(
                cpuTicks: cpuTicks,
                energyNanojoules: energyNanojoules,
                gpuNanos: gpuNanos,
                startTime: startTime,
                diskBytesRead: diskBytesRead,
                diskBytesWritten: diskBytesWritten,
                wakeups: wakeups)

            if let app = runningApplications[pid] {
                row.name = app.localizedName ?? row.name
                row.bundleIdentifier = app.bundleIdentifier
            }

            if collectWork {
                // The footprint is a gauge, valid even for a process seen for
                // the first time — unlike the counters above, which need a
                // baseline and stay zero for one interval.
                contribution.memoryBytes = row.memoryBytes
                Self.accumulate(contribution, into: &work)
            }

            rows.append(row)
        }

        // Processes the uid-filtered libproc pass left out of the table still have
        // their GPU time collected — the IORegistry walk is not uid-restricted
        // — and WindowServer, which composites every window on the machine, is
        // routinely the top GPU consumer. Keep a row for any of them that is
        // touching the GPU, or the GPU ranking can never show the usual #1
        // answer. Their other measures stay zero, which keeps them out of the
        // CPU, memory and energy rankings.
        for (pid, gpuNanos) in gpuTimes where pid > 0 && nextBaselines[pid] == nil {
            let startTime = processStartTime(pid: pid)
            var row = ProcessRow(
                pid: pid,
                name: gpuAttribution.name(for: pid) ?? "pid \(pid)",
                startTime: startTime)
            if !discardCounterDeltas,
               let previous = baselines[pid], previous.startTime == startTime,
               let previousGPU = previous.gpuNanos, gpuNanos >= previousGPU {
                row.gpuPercent = min(
                    100, Double(gpuNanos - previousGPU) / (interval * 1_000_000_000) * 100)
                // Filed under the name alone: there is no readable path for
                // another user's process, and the name is stable for the
                // long-lived system clients (WindowServer) this row exists for.
                var contribution = AppWorkDelta(attribution: AppAttribution(
                    key: "proc:\(row.name)", displayName: row.name,
                    bundlePath: nil, executablePath: nil))
                contribution.gpuNanos = gpuNanos - previousGPU
                Self.accumulate(contribution, into: &work)
            }
            nextBaselines[pid] = Baseline(
                cpuTicks: 0, energyNanojoules: nil, gpuNanos: gpuNanos, startTime: startTime)
            rows.append(row)
        }

        baselines = nextBaselines
        identities = nextIdentities

        // The all-pid list, not the row list: rows exist only for this user's
        // processes (plus GPU-only clients), and reporting that subset as the
        // machine's process count under-reads it by several hundred.
        metrics.count = processCount
        for metric in ProcessMetric.allCases {
            metrics.leaders[metric] = Self.rank(
                rows, by: metric, limit: ProcessMetrics.leaderboardDepth)
        }
        result.metrics = metrics
        // The floor applies after aggregation, so an app of many small helpers
        // qualifies on their sum even when no one member would alone.
        result.workDeltas = work.values.filter(\.isMeasurable)
        return result
    }

    // MARK: - App attribution

    /// Sums a process's contribution into its app's, member by member. The
    /// footprints add too: the app's memory at this instant is what all of its
    /// processes hold together.
    private static func accumulate(
        _ contribution: AppWorkDelta, into work: inout [String: AppWorkDelta]
    ) {
        let key = contribution.attribution.key
        guard var existing = work[key] else {
            work[key] = contribution
            return
        }
        existing.cpuNanos.addSaturating(contribution.cpuNanos)
        existing.energyNanojoules.addSaturating(contribution.energyNanojoules)
        existing.gpuNanos.addSaturating(contribution.gpuNanos)
        existing.diskReadBytes.addSaturating(contribution.diskReadBytes)
        existing.diskWriteBytes.addSaturating(contribution.diskWriteBytes)
        existing.wakeups.addSaturating(contribution.wakeups)
        existing.memoryBytes.addSaturating(contribution.memoryBytes)
        work[key] = existing
    }

    /// Where a process's work is filed. The outermost `.app` bundle in the
    /// path groups helpers with the app a user would name — the same rule the
    /// dashboard's icon lookup uses — which also means a compiler run out of
    /// `Xcode.app/Contents/Developer` files under Xcode no matter who spawned
    /// it: attribution follows where the binary lives, not who launched it.
    private static func attribution(name: String, path: String?) -> AppAttribution {
        guard let path else {
            return AppAttribution(
                key: "proc:\(name)", displayName: name,
                bundlePath: nil, executablePath: nil)
        }
        if let bundle = outermostAppBundle(in: path) {
            let folder = bundle.split(separator: "/").last.map(String.init) ?? name
            let display = folder.hasSuffix(".app") ? String(folder.dropLast(4)) : folder
            return AppAttribution(
                key: "app:\(bundle)", displayName: display.isEmpty ? name : display,
                bundlePath: bundle, executablePath: path)
        }
        return AppAttribution(
            key: "exe:\(path)", displayName: name,
            bundlePath: nil, executablePath: path)
    }

    private static func outermostAppBundle(in path: String) -> String? {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard let index = components.firstIndex(where: { $0.hasSuffix(".app") }) else {
            return nil
        }
        return components[...index].joined(separator: "/")
    }

    /// Top `limit` rows by `metric`, without sorting the whole table.
    ///
    /// A full sort of several hundred rows, once per ranking, is a lot of work
    /// for a few lists of a dozen entries. Almost every row fails the single
    /// comparison against the current cut-off and costs nothing further.
    private static func rank(
        _ rows: [ProcessRow], by metric: ProcessMetric, limit: Int
    ) -> [ProcessRow] {
        guard limit > 0 else { return [] }

        var top: [ProcessRow] = []
        top.reserveCapacity(limit)
        var cutoff = 0.0

        for row in rows {
            let value = metric.value(of: row)
            guard value > 0 else { continue }
            if top.count == limit, value <= cutoff { continue }

            let insertion = top.firstIndex { metric.value(of: $0) < value } ?? top.count
            top.insert(row, at: insertion)
            if top.count > limit { top.removeLast() }
            if top.count == limit { cutoff = metric.value(of: top[limit - 1]) }
        }
        return top
    }

    /// Activity Monitor's "Energy Impact" is an unpublished composite. This is a
    /// simple, honest stand-in: average power draw attributable to the process
    /// over the interval, scaled so that ~1 unit is roughly 100 mW.
    private static func energyImpact(nanojoules: UInt64, interval: TimeInterval) -> Double {
        guard interval > 0 else { return 0 }
        let watts = Double(nanojoules) / 1_000_000_000 / interval
        return watts * 10
    }

    // MARK: - libproc

    private func processIDs(type: UInt32, typeInfo: UInt32) -> [Int32] {
        var requiredBytes = proc_listpids(type, typeInfo, nil, 0)
        guard requiredBytes > 0 else { return [] }
        var lastResult: [Int32] = []

        // Processes can be created between the size query and the fetch. Retry
        // a buffer that came back completely full instead of silently omitting
        // whichever pids landed at the end of a busy machine's list.
        for _ in 0..<3 {
            let requiredCount = Int(requiredBytes) / MemoryLayout<Int32>.size
            var pids = [Int32](repeating: 0, count: requiredCount + 64)
            let bufferBytes = pids.count * MemoryLayout<Int32>.size
            guard bufferBytes <= Int(Int32.max) else { return [] }

            let written = proc_listpids(
                type, typeInfo, &pids, Int32(bufferBytes))
            guard written > 0 else { return [] }
            lastResult = Array(pids.prefix(Int(written) / MemoryLayout<Int32>.size))
            if Int(written) < bufferBytes {
                return lastResult
            }
            requiredBytes = written
        }
        // Extremely high churn may keep filling even the expanded buffers.
        // The last complete prefix is still more useful than replacing the
        // whole process table with a false zero.
        return lastResult
    }

    /// Start time for a process `taskAllInfo` cannot see. `KERN_PROC` is
    /// readable across users — it is how unprivileged `ps` shows START for
    /// root's processes — and the recycled-pid guard needs it for the
    /// GPU-only rows too. Zero when the process is already gone, which can
    /// never match a real baseline.
    private func processStartTime(pid: Int32) -> UInt64 {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return 0 }
        let start = info.kp_proc.p_starttime
        return Self.startTime(seconds: start.tv_sec, microseconds: start.tv_usec)
    }

    private static func startTime<T: BinaryInteger, U: BinaryInteger>(
        seconds: T, microseconds: U
    ) -> UInt64 {
        let seconds = UInt64(clamping: seconds)
        let microseconds = UInt64(clamping: microseconds)
        let (scaled, multiplyOverflow) = seconds.multipliedReportingOverflow(by: 1_000_000)
        guard !multiplyOverflow else { return UInt64.max }
        let (result, addOverflow) = scaled.addingReportingOverflow(microseconds)
        return addOverflow ? UInt64.max : result
    }

    private func taskAllInfo(pid: Int32) -> proc_taskallinfo? {
        var info = proc_taskallinfo()
        let size = Int32(MemoryLayout<proc_taskallinfo>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, $0, size)
        }
        return result == size ? info : nil
    }

    /// `proc_pid_rusage` writes into a caller-owned buffer; the `rusage_info_t`
    /// parameter type is just C's untyped `void *` for that destination, so the
    /// struct's address is rebound rather than passed indirectly.
    ///
    /// Can still fail when a process exits between the pid and rusage reads.
    private func resourceUsage(pid: Int32) -> rusage_info_v6? {
        var usage = rusage_info_v6()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V6, rebound)
            }
        }
        return result == 0 ? usage : nil
    }

    private func processName(pid: Int32, info: inout proc_taskallinfo) -> String {
        // `pbi_name` is the full (up to 32 char) name; `pbi_comm` truncates to 16.
        let fromName = withUnsafeBytes(of: &info.pbsd.pbi_name) { buffer -> String in
            String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        if !fromName.isEmpty { return fromName }

        let fromComm = withUnsafeBytes(of: &info.pbsd.pbi_comm) { buffer -> String in
            String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return fromComm.isEmpty ? "pid \(pid)" : fromComm
    }

    /// PROC_PIDPATHINFO_MAXSIZE — not re-exported into Swift. Held as a member
    /// so a cold cache does not allocate 4 KB per process.
    private var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))

    private func executablePath(pid: Int32) -> String? {
        let length = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        guard length > 0 else { return nil }
        return pathBuffer.withUnsafeBytes { raw in
            let bytes = raw.prefix(min(Int(length), raw.count)).prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}

// MARK: - GPU attribution

/// Maps GPU time onto processes by walking the accelerator's user clients.
///
/// Each Metal client in the IORegistry carries an `IOUserClientCreator` string
/// of the form `"pid 1234, ProcessName"` alongside an `AppUsage` array whose
/// entries hold `accumulatedGPUTime` in nanoseconds. This is the same
/// accounting Activity Monitor's GPU column is built on.
final class GPUProcessAttribution {
    private(set) var available = false
    /// Walks that found no clients since the last one that did. WindowServer
    /// is always a GPU client, so a genuinely empty walk means the mechanism
    /// has stopped working, not that the GPU is idle — but one transient miss
    /// should not flip the column to "unavailable" either. `available` was
    /// previously latched true forever, which turned a broken walk into a
    /// table of confident zeros.
    private var consecutiveEmptyWalks = 0
    private static let emptyWalksBeforeUnavailable = 3

    /// Names from the creator strings of the last walk, `pbi_comm`-truncated.
    /// The process table cannot read anything about another user's process,
    /// but the creator string names it for free.
    private var names: [Int32: String] = [:]

    func name(for pid: Int32) -> String? { names[pid] }

    func accumulatedGPUTime() -> [Int32: UInt64] {
        // The registry invalidates an iterator when it changes mid-walk, and
        // the accelerator subtree is exactly where that happens: a user client
        // appears or vanishes whenever any process starts or stops touching
        // Metal. `IOIteratorNext` then returns 0 exactly as if the walk had
        // finished, so without the validity check a torn pass reads as a
        // complete one — and a partial table is worse than none. Every pid it
        // happens to miss would take a zero baseline and be credited its
        // entire lifetime of GPU time on the next pass, one spiked row on
        // screen and hours of phantom GPU-seconds in the ledger. Retry once;
        // a second torn pass reports "no walk", which is the nil-baseline
        // path the samplers already handle.
        var totals = attemptWalk()
        if totals == nil { totals = attemptWalk() }
        let result = totals ?? [:]

        if !result.isEmpty {
            available = true
            consecutiveEmptyWalks = 0
        } else {
            consecutiveEmptyWalks += 1
            if consecutiveEmptyWalks >= Self.emptyWalksBeforeUnavailable {
                available = false
            }
        }
        return result
    }

    /// One full pass over every accelerator's clients, or `nil` when the
    /// registry invalidated an iterator midway and the table cannot be
    /// trusted to be complete.
    private func attemptWalk() -> [Int32: UInt64]? {
        var totals: [Int32: UInt64] = [:]
        names.removeAll(keepingCapacity: true)

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS
        else { return totals }
        defer { IOObjectRelease(iterator) }

        while case let accelerator = IOIteratorNext(iterator), accelerator != 0 {
            defer { IOObjectRelease(accelerator) }
            guard walk(accelerator, into: &totals) else { return nil }
        }
        guard IOIteratorIsValid(iterator) != 0 else { return nil }
        return totals
    }

    /// Returns `false` when the child iterator was invalidated before the
    /// walk finished, so the caller can discard the partial table.
    private func walk(
        _ root: io_registry_entry_t, into totals: inout [Int32: UInt64]
    ) -> Bool {
        var children: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(
            root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &children)
            == KERN_SUCCESS
        else { return false }
        defer { IOObjectRelease(children) }

        while case let entry = IOIteratorNext(children), entry != 0 {
            defer { IOObjectRelease(entry) }

            guard let creator = IORegistryEntryCreateCFProperty(
                entry, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String,
                let pid = Self.parsePID(from: creator)
            else { continue }

            guard let usage = IORegistryEntryCreateCFProperty(
                entry, "AppUsage" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSArray
            else { continue }

            var total: UInt64 = 0
            for entry in usage {
                guard let entry = entry as? NSDictionary else { continue }
                guard let raw = entry["accumulatedGPUTime"] as? NSNumber else { continue }
                let value = UInt64(max(0, raw.int64Value))
                let (sum, overflow) = total.addingReportingOverflow(value)
                total = overflow ? UInt64.max : sum
            }
            guard total > 0 else { continue }
            let previous = totals[pid, default: 0]
            let (sum, overflow) = previous.addingReportingOverflow(total)
            totals[pid] = overflow ? UInt64.max : sum
            if names[pid] == nil, let name = Self.parseName(from: creator) {
                names[pid] = name
            }
        }
        return IOIteratorIsValid(children) != 0
    }

    /// Parses the leading pid out of `"pid 1234, WindowServer"`.
    private static func parsePID(from creator: String) -> Int32? {
        guard creator.hasPrefix("pid ") else { return nil }
        let remainder = creator.dropFirst(4)
        let digits = remainder.prefix { $0.isNumber }
        return Int32(digits)
    }

    /// The name after the comma in `"pid 1234, WindowServer"`.
    private static func parseName(from creator: String) -> String? {
        guard let comma = creator.firstIndex(of: ",") else { return nil }
        let name = creator[creator.index(after: comma)...]
            .trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}
