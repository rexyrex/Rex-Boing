import Foundation
import Darwin

/// Per-core CPU load from `host_processor_info`.
///
/// The kernel reports monotonically increasing tick counters, so a single read
/// tells you nothing — utilisation is the delta between two reads divided by
/// the total ticks elapsed in that window.
final class CPUSampler {
    private var previousTicks: [UInt32] = []
    private var previousCoreCount: natural_t = 0
    private let coreKinds = HostInfo.coreKinds()
    /// `mach_host_self()` takes a fresh send right on every call and nothing
    /// here ever deallocates one, so calling it per sample accumulates port
    /// references for the life of the process. The port never changes; one
    /// call is enough.
    private let host: host_t
    /// The default processor-set name port exposes exact system-wide task and
    /// thread counts without requiring access to each process. Summing
    /// `pti_threadnum` under-counts badly for an unprivileged app because
    /// `proc_pidinfo` rejects processes owned by other users.
    private let processorSet: processor_set_name_t?
    private var cachedTaskCount = 0
    private var cachedThreadCount = 0

    init() {
        let host = mach_host_self()
        self.host = host

        var processorSet: processor_set_name_t = 0
        if processor_set_default(host, &processorSet) == KERN_SUCCESS, processorSet != 0 {
            self.processorSet = processorSet
        } else {
            self.processorSet = nil
        }
    }

    deinit {
        if let processorSet {
            mach_port_deallocate(mach_task_self_, processorSet)
        }
        mach_port_deallocate(mach_task_self_, host)
    }

    func sample() -> CPUMetrics {
        var metrics = CPUMetrics()
        metrics.coreKinds = coreKinds
        metrics.loadAverage = loadAverage()
        updateSystemCounts(in: &metrics)

        var coreCount: natural_t = 0
        var infoCount: mach_msg_type_number_t = 0
        var info: processor_info_array_t?

        let result = host_processor_info(
            host, PROCESSOR_CPU_LOAD_INFO, &coreCount, &info, &infoCount)
        guard result == KERN_SUCCESS, let info else { return metrics }

        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: info)),
                vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        let stateCount = Int(CPU_STATE_MAX)
        let requiredCount = Int(coreCount) * stateCount
        guard coreCount > 0, Int(infoCount) >= requiredCount else { return metrics }
        var ticks = [UInt32](repeating: 0, count: Int(coreCount) * stateCount)
        for index in 0..<requiredCount {
            ticks[index] = UInt32(bitPattern: info[index])
        }

        // First sample after launch (or after a core-count change) has no
        // baseline to diff against; report idle and prime the buffer.
        guard previousCoreCount == coreCount, previousTicks.count == ticks.count else {
            previousTicks = ticks
            previousCoreCount = coreCount
            metrics.perCore = Array(repeating: 0, count: Int(coreCount))
            return metrics
        }

        var perCore: [Double] = []
        perCore.reserveCapacity(Int(coreCount))
        var totals = (user: 0.0, system: 0.0, idle: 0.0, nice: 0.0)

        for core in 0..<Int(coreCount) {
            let base = core * stateCount
            let user = delta(ticks[base + Int(CPU_STATE_USER)], previousTicks[base + Int(CPU_STATE_USER)])
            let system = delta(ticks[base + Int(CPU_STATE_SYSTEM)], previousTicks[base + Int(CPU_STATE_SYSTEM)])
            let idle = delta(ticks[base + Int(CPU_STATE_IDLE)], previousTicks[base + Int(CPU_STATE_IDLE)])
            let nice = delta(ticks[base + Int(CPU_STATE_NICE)], previousTicks[base + Int(CPU_STATE_NICE)])

            let total = user + system + idle + nice
            perCore.append(total > 0 ? (user + system + nice) / total : 0)

            totals.user += user
            totals.system += system
            totals.idle += idle
            totals.nice += nice
        }

        let grandTotal = totals.user + totals.system + totals.idle + totals.nice
        if grandTotal > 0 {
            metrics.user = totals.user / grandTotal
            metrics.system = totals.system / grandTotal
            metrics.nice = totals.nice / grandTotal
            metrics.idle = totals.idle / grandTotal
            metrics.total = 1 - metrics.idle
        }

        metrics.perCore = perCore
        (metrics.efficiencyLoad, metrics.performanceLoad) = clusterLoads(perCore)
        previousTicks = ticks
        previousCoreCount = coreCount
        return metrics
    }

    /// Both cluster averages in a single pass over the core array.
    private func clusterLoads(_ perCore: [Double]) -> (efficiency: Double, performance: Double) {
        var efficiencySum = 0.0, efficiencyCount = 0
        var performanceSum = 0.0, performanceCount = 0

        for (index, load) in perCore.enumerated() where index < coreKinds.count {
            switch coreKinds[index] {
            case .efficiency: efficiencySum += load; efficiencyCount += 1
            case .performance: performanceSum += load; performanceCount += 1
            case .unknown: break
            }
        }

        return (
            efficiencyCount > 0 ? efficiencySum / Double(efficiencyCount) : 0,
            performanceCount > 0 ? performanceSum / Double(performanceCount) : 0)
    }

    /// Tick counters are 32-bit and do wrap on long-running machines.
    private func delta(_ current: UInt32, _ previous: UInt32) -> Double {
        Double(current &- previous)
    }

    private func loadAverage() -> (one: Double, five: Double, fifteen: Double) {
        var values = [Double](repeating: 0, count: 3)
        guard getloadavg(&values, 3) == 3 else { return (0, 0, 0) }
        return (values[0], values[1], values[2])
    }

    /// `PROCESSOR_SET_LOAD_INFO` is a system aggregate, so it includes the
    /// root daemons and other users' processes that libproc deliberately hides
    /// from an unprivileged caller. Keep the last successful values through a
    /// transient Mach failure rather than flashing a confident zero.
    private func updateSystemCounts(in metrics: inout CPUMetrics) {
        guard let processorSet else { return }

        var info = processor_set_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<processor_set_load_info_data_t>.stride
                / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                processor_set_statistics(
                    processorSet, PROCESSOR_SET_LOAD_INFO, rebound, &count)
            }
        }

        if result == KERN_SUCCESS {
            cachedTaskCount = max(0, Int(info.task_count))
            cachedThreadCount = max(0, Int(info.thread_count))
        }
        metrics.processCount = cachedTaskCount
        metrics.threadCount = cachedThreadCount
    }
}
