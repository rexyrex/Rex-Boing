import Foundation
import Darwin

/// Memory, compression and swap.
///
/// The breakdown mirrors Activity Monitor's definitions rather than the raw
/// Mach counters, because "free memory" in the Mach sense is close to
/// meaningless on a modern Mac — the interesting numbers are app memory,
/// wired, the compressor, and how hard the swap file is being worked.
final class MemorySampler {
    private var previousSwapIns: UInt64 = 0
    private var previousSwapOuts: UInt64 = 0
    private var hasBaseline = false
    /// Rates must span the time between two *successful* counter reads. If one
    /// Mach call fails and the next delta is divided by a single nominal tick,
    /// page-in/out briefly doubles (or worse) even though the underlying
    /// counters are correct.
    private var lastSuccessfulSample: Date?
    private var lastSuccessfulUptime: TimeInterval?
    private var cachedMetrics = MemoryMetrics()
    private var hasCachedMetrics = false
    private var cachedSwap = SwapMetrics()

    /// Held rather than re-fetched: `mach_host_self()` takes a new send right
    /// per call, which a once-a-second sampler would accumulate forever.
    private let host: mach_port_t
    private let pageSize: UInt64

    init() {
        let host = mach_host_self()
        self.host = host
        var size: vm_size_t = 0
        pageSize = host_page_size(host, &size) == KERN_SUCCESS ? UInt64(size) : 16_384
    }

    deinit {
        mach_port_deallocate(mach_task_self_, host)
    }

    func sample(interval: TimeInterval) -> MemoryMetrics {
        var metrics = MemoryMetrics()
        metrics.total = HostInfo.current.memoryBytes

        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)

        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(host, HOST_VM_INFO64, rebound, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            // Zero used memory is a confident and very visible lie. Preserve
            // the last instantaneous readings through a transient host call
            // failure, while blanking the rates that no new counter read can
            // support.
            guard hasCachedMetrics else { return metrics }
            var cached = cachedMetrics
            cached.swap.inRate = 0
            cached.swap.outRate = 0
            return cached
        }

        let sampledAt = Date()
        let sampledUptime = ProcessInfo.processInfo.systemUptime
        let wallElapsed = lastSuccessfulSample.map {
            sampledAt.timeIntervalSince($0)
        } ?? interval
        let elapsed = lastSuccessfulUptime.map { sampledUptime - $0 } ?? interval
        let plausibleWindow = elapsed > 0 && elapsed <= 30 && wallElapsed > 0
            && wallElapsed <= 30 && abs(wallElapsed - elapsed) <= 1

        func bytes(_ pages: UInt32) -> UInt64 { UInt64(pages) * pageSize }
        func bytes(_ pages: UInt64) -> UInt64 { pages * pageSize }

        // `free_count` nominally includes the speculative pages, but the two
        // counters are read without a lock and are not guaranteed to be
        // coherent with each other. Plain subtraction traps the process on an
        // unsigned underflow, so it is floored.
        let freePages = stats.free_count > stats.speculative_count
            ? stats.free_count - stats.speculative_count : 0
        metrics.free = bytes(freePages)
        metrics.active = bytes(stats.active_count)
        metrics.inactive = bytes(stats.inactive_count)
        metrics.wired = bytes(stats.wire_count)
        metrics.compressed = bytes(stats.compressor_page_count)
        metrics.speculative = bytes(stats.speculative_count)
        metrics.purgeable = bytes(stats.purgeable_count)
        metrics.fileBacked = bytes(stats.external_page_count)

        // App memory is anonymous (internal) memory that isn't purgeable.
        let internalBytes = bytes(stats.internal_page_count)
        metrics.app = internalBytes > metrics.purgeable ? internalBytes - metrics.purgeable : 0
        metrics.cached = metrics.fileBacked + metrics.purgeable
        metrics.used = min(metrics.total, metrics.app + metrics.wired + metrics.compressed)

        metrics.pressure = pressureFraction(stats: stats, total: metrics.total)
        metrics.pressureLevel = pressureLevel()
            ?? (hasCachedMetrics ? cachedMetrics.pressureLevel : .normal)
        metrics.swap = swapMetrics(
            stats: stats, interval: elapsed, publishRates: plausibleWindow)

        lastSuccessfulSample = sampledAt
        lastSuccessfulUptime = sampledUptime
        cachedMetrics = metrics
        hasCachedMetrics = true

        return metrics
    }

    // MARK: - Swap

    private func swapMetrics(
        stats: vm_statistics64_data_t, interval: TimeInterval, publishRates: Bool
    ) -> SwapMetrics {
        var swap = cachedSwap
        swap.inRate = 0
        swap.outRate = 0

        if let usage = Sysctl.value("vm.swapusage", as: xsw_usage.self) {
            swap.total = usage.xsu_total
            swap.used = usage.xsu_used
            swap.free = usage.xsu_avail
            swap.encrypted = usage.xsu_encrypted != 0
        }

        swap.ins = stats.swapins
        swap.outs = stats.swapouts

        if hasBaseline, publishRates {
            let inDelta = stats.swapins >= previousSwapIns ? stats.swapins - previousSwapIns : 0
            let outDelta = stats.swapouts >= previousSwapOuts ? stats.swapouts - previousSwapOuts : 0
            // Multiplied as doubles: a page delta times the page size cannot
            // overflow here, where the integer product would trap.
            swap.inRate = Double(inDelta) * Double(pageSize) / interval
            swap.outRate = Double(outDelta) * Double(pageSize) / interval
        }

        previousSwapIns = stats.swapins
        previousSwapOuts = stats.swapouts
        hasBaseline = true
        cachedSwap = swap

        return swap
    }

    // MARK: - Pressure

    /// Activity Monitor's pressure gauge tracks the share of physical memory the
    /// kernel can no longer reclaim cheaply: wired pages plus the compressor.
    private func pressureFraction(stats: vm_statistics64_data_t, total: UInt64) -> Double {
        guard total > 0 else { return 0 }
        let unreclaimable = UInt64(stats.wire_count) * pageSize
            + UInt64(stats.compressor_page_count) * pageSize
        return min(1, Double(unreclaimable) / Double(total))
    }

    private func pressureLevel() -> MemoryPressureLevel? {
        guard let raw = Sysctl.integer("kern.memorystatus_vm_pressure_level"),
              let level = MemoryPressureLevel(rawValue: raw)
        else { return nil }
        return level
    }
}
