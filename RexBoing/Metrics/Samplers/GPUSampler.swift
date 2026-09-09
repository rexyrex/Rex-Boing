import Foundation
import IOKit

/// GPU utilisation and memory from the accelerator's `PerformanceStatistics`
/// dictionary in the IORegistry — the same source Activity Monitor's GPU
/// history window reads, and it needs no elevated privileges.
final class GPUSampler {
    private struct Identity {
        var name: String
        var cores: Int?
    }

    /// A multi-GPU Mac has one accelerator service per device. Identity must be
    /// cached per service too: resolving one global name and then reporting the
    /// busiest device's statistics under it can label a discrete GPU as the
    /// integrated one (or vice versa).
    private var identities: [UInt64: Identity] = [:]

    func sample() -> GPUMetrics {
        let metrics = GPUMetrics()

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS
        else { return metrics }
        defer { IOObjectRelease(iterator) }

        // A Mac can expose several accelerators (integrated + discrete, or a
        // virtualised one). Report the busiest, which is the one doing the work.
        var best: GPUMetrics?

        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }

            // Kept as the toll-free `NSDictionary` rather than bridged to
            // `[String: Any]`: the bridge deep-copies and boxes all ~50
            // entries, once per accelerator per tick, to read seven of them.
            guard let stats = IORegistryEntryCreateCFProperty(
                service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSDictionary
            else { continue }

            // The dictionary can still exist after a driver/schema change.
            // Treating a missing utilisation key as zero turns an unsupported
            // source into a plausible-looking idle GPU, which is the worst
            // failure mode for telemetry. Only a real numeric value makes this
            // accelerator a candidate.
            guard let utilization = fraction(stats[statisticsKeys.deviceUtilization])
            else { continue }

            var candidate = metrics
            let identity = identity(for: service)
            candidate.name = identity.name
            candidate.coreCount = identity.cores
            candidate.available = true
            candidate.utilization = utilization
            candidate.rendererUtilization = fraction(stats[statisticsKeys.rendererUtilization]) ?? 0
            candidate.tilerUtilization = fraction(stats[statisticsKeys.tilerUtilization]) ?? 0
            candidate.inUseMemory = unsigned(stats[statisticsKeys.inUseSystemMemory])
            candidate.allocatedMemory = unsigned(stats[statisticsKeys.allocSystemMemory])

            // Discrete cards report VRAM instead of system memory. Used and
            // free VRAM sum to the card's *capacity*, which is not the same
            // quantity as the driver's allocation figure — reporting it as
            // "allocated" overstated it by the whole idle pool, so it is
            // carried separately and the allocated row hides itself instead.
            if candidate.inUseMemory == 0 {
                let used = unsigned(stats[statisticsKeys.vramUsed])
                let free = unsigned(stats[statisticsKeys.vramFree])
                candidate.inUseMemory = used
                let (total, overflow) = used.addingReportingOverflow(free)
                if !overflow, total > 0 { candidate.totalMemory = total }
            }

            if best.map({ candidate.utilization > $0.utilization }) ?? true {
                best = candidate
            }
        }

        return best ?? metrics
    }

    // MARK: - Helpers

    /// The seven statistics actually read, held as `NSString` so each lookup
    /// costs a dictionary probe rather than a fresh `String → NSString`
    /// bridge. Instance state rather than statics purely for the concurrency
    /// checker: `NSString` is immutable in fact but not `Sendable` in type,
    /// and the sampler itself is already confined to the engine's queue.
    private let statisticsKeys = (
        deviceUtilization: "Device Utilization %" as NSString,
        rendererUtilization: "Renderer Utilization %" as NSString,
        tilerUtilization: "Tiler Utilization %" as NSString,
        inUseSystemMemory: "In use system memory" as NSString,
        allocSystemMemory: "Alloc system memory" as NSString,
        vramUsed: "vramUsedBytes" as NSString,
        vramFree: "vramFreeBytes" as NSString)

    private func fraction(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        let fraction = number.doubleValue / 100
        guard fraction.isFinite else { return nil }
        return min(1, max(0, fraction))
    }

    private func unsigned(_ value: Any?) -> UInt64 {
        guard let number = value as? NSNumber else { return 0 }
        return UInt64(max(0, number.int64Value))
    }

    /// The accelerator node itself is unhelpfully named (`AGXAcceleratorG13X`),
    /// so the chip's marketing name is a better label. `gpu-core-count` lives
    /// on the accelerator node, a couple of levels above the `IOAccelerator`
    /// services that `sample()` iterates.
    private func identity(for service: io_registry_entry_t) -> Identity {
        var entryID: UInt64 = 0
        let hasEntryID = IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS
        if hasEntryID, let cached = identities[entryID] { return cached }

        let cores = searchUpwards(from: service, property: "gpu-core-count", depth: 6)
        let chip = HostInfo.current.chipName
        let identity: Identity
        if HostInfo.current.isAppleSilicon, chip.hasPrefix("Apple") {
            identity = Identity(name: chip + " GPU", cores: cores)
        } else {
            // On Intel the previous fallback walked every `IOPCIDevice` and used
            // the first `model` it found. That device is not necessarily a GPU.
            // Resolve from this accelerator's own ancestry instead.
            identity = Identity(
                name: modelNameUpwards(from: service, depth: 8) ?? "GPU",
                cores: cores)
        }
        if hasEntryID { identities[entryID] = identity }
        return identity
    }

    private func searchUpwards(
        from entry: io_registry_entry_t, property: String, depth: Int
    ) -> Int? {
        var current = entry
        var owned = false
        defer { if owned { IOObjectRelease(current) } }

        for _ in 0...depth {
            if let raw = IORegistryEntryCreateCFProperty(
                current, property as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() {
                if let number = raw as? NSNumber { return number.intValue }
                if let data = raw as? Data, data.count >= 4 {
                    return Int(data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
                }
            }

            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
                == KERN_SUCCESS, parent != 0 else { return nil }
            if owned { IOObjectRelease(current) }
            current = parent
            owned = true
        }
        return nil
    }

    private func modelNameUpwards(from entry: io_registry_entry_t, depth: Int) -> String? {
        var current = entry
        var owned = false
        defer { if owned { IOObjectRelease(current) } }

        for _ in 0...depth {
            if let raw = IORegistryEntryCreateCFProperty(
                current, "model" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() {
                if let data = raw as? Data {
                    let name = String(
                        decoding: data.prefix(while: { $0 != 0 }), as: UTF8.self)
                    if !name.isEmpty { return name }
                } else if let name = raw as? String, !name.isEmpty {
                    return name
                }
            }

            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
                == KERN_SUCCESS, parent != 0 else { return nil }
            if owned { IOObjectRelease(current) }
            current = parent
            owned = true
        }
        return nil
    }
}
