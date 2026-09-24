import Foundation
import Darwin
import IOKit

/// Thin, allocation-light wrappers over `sysctlbyname`.
enum Sysctl {
    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        // Sysctl strings conventionally include a terminator, but decoding the
        // bytes actually returned also stays in bounds if a future key does not.
        return String(
            decoding: buffer.prefix(size).prefix(while: { $0 != 0 })
                .map { UInt8(bitPattern: $0) },
            as: UTF8.self)
    }

    /// Integer sysctls come in two widths — `hw.logicalcpu` is 32-bit,
    /// `hw.memsize` 64 — and the kernel reports which through the out-size.
    /// Reading a 32-bit value into the top of a wider buffer only works for
    /// non-negative values by way of zero-initialisation; switching on the
    /// written size makes negative 32-bit values sign-extend correctly and
    /// turns any unexpected width into `nil` instead of garbage.
    static func integer(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        switch size {
        case MemoryLayout<Int32>.size:
            return Int(Int32(truncatingIfNeeded: value))
        case MemoryLayout<Int64>.size:
            return Int(value)
        default:
            return nil
        }
    }

    static func uint32(_ name: String) -> UInt32? {
        var value: UInt32 = 0
        var size = MemoryLayout<UInt32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    static func uint64(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    static func value<T>(_ name: String, as type: T.Type) -> T? {
        var size = MemoryLayout<T>.size
        let pointer = UnsafeMutableRawPointer.allocate(
            byteCount: size, alignment: MemoryLayout<T>.alignment)
        defer { pointer.deallocate() }
        // The allocation is uninitialised, and a short write would leave the
        // struct's tail as heap garbage — require the kernel to fill it
        // exactly. Every current caller reads a fixed-layout struct, where a
        // size mismatch means the layout is wrong, not that less data is fine.
        guard sysctlbyname(name, pointer, &size, nil, 0) == 0,
              size == MemoryLayout<T>.size
        else { return nil }
        return pointer.load(as: T.self)
    }

    static func bootTime() -> Date? {
        var timeValue = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &timeValue, &size, nil, 0) == 0 else { return nil }
        return Date(timeIntervalSince1970: Double(timeValue.tv_sec)
            + Double(timeValue.tv_usec) / 1_000_000)
    }
}

/// One-shot description of the machine. Everything here is stable for the
/// lifetime of the process apart from `uptime`, which is derived on read.
enum HostInfo {
    static let current: HostDescription = build()

    private static func build() -> HostDescription {
        var description = HostDescription()

        description.modelIdentifier = Sysctl.string("hw.model") ?? "Mac"
        description.chipName = Sysctl.string("machdep.cpu.brand_string")
            ?? Sysctl.string("hw.model")
            ?? "Unknown CPU"
        description.logicalCores = Sysctl.integer("hw.logicalcpu") ?? 0
        description.physicalCores = Sysctl.integer("hw.physicalcpu") ?? 0
        description.memoryBytes = Sysctl.uint64("hw.memsize") ?? 0
        description.bootTime = Sysctl.bootTime() ?? Date()

        // On Apple silicon `perflevel0` is the performance cluster and
        // `perflevel1` the efficiency cluster. Intel Macs expose neither.
        let levelCount = Sysctl.integer("hw.nperflevels") ?? 1
        if levelCount >= 2 {
            description.performanceCores = Sysctl.integer("hw.perflevel0.logicalcpu") ?? 0
            description.efficiencyCores = Sysctl.integer("hw.perflevel1.logicalcpu") ?? 0
            description.isAppleSilicon = true
        } else {
            description.performanceCores = description.logicalCores
            description.efficiencyCores = 0
            description.isAppleSilicon = false
        }

        let version = ProcessInfo.processInfo.operatingSystemVersion
        description.osVersion = "\(version.majorVersion).\(version.minorVersion)"
            + (version.patchVersion > 0 ? ".\(version.patchVersion)" : "")

        description.modelName = marketingName() ?? description.modelIdentifier

        return description
    }

    /// Apple silicon exposes a human-readable model name in the device tree.
    /// Intel Macs (and any future layout change) fall back to `hw.model`.
    private static func marketingName() -> String? {
        for path in ["IODeviceTree:/product", "IOService:/AppleARMPE/product"] {
            let entry = IORegistryEntryFromPath(kIOMainPortDefault, path)
            guard entry != 0 else { continue }
            defer { IOObjectRelease(entry) }
            guard let raw = IORegistryEntryCreateCFProperty(
                entry, "product-name" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() else { continue }
            if let data = raw as? Data {
                let name = String(decoding: data.prefix(while: { $0 != 0 }), as: UTF8.self)
                if !name.isEmpty { return name }
            }
            if let name = raw as? String, !name.isEmpty { return name }
        }
        return nil
    }

    /// Core layout in `host_processor_info` order: efficiency cores come first
    /// on Apple silicon, so the perf-level counts map directly onto the array.
    static func coreKinds() -> [CoreKind] {
        let host = current
        guard host.isAppleSilicon, host.efficiencyCores + host.performanceCores == host.logicalCores
        else {
            return Array(repeating: .unknown, count: max(host.logicalCores, 1))
        }
        return Array(repeating: .efficiency, count: host.efficiencyCores)
            + Array(repeating: .performance, count: host.performanceCores)
    }
}

/// Decides when a slower job that can only run on an engine tick is due.
///
/// Ticks are scheduled `refreshInterval` apart with leeway, and measured on
/// the uptime clock consecutive ticks land a few milliseconds either side of
/// the nominal spacing — about half of them short. A gate written as
/// `elapsed >= period` therefore fails on roughly every other tick that
/// should pass it: a 2 s cadence on a 1 s refresh ran at 2 s or 3 s at
/// random, the process table refreshed on alternate ticks while the dashboard
/// was open, and at the 5 s refresh setting the background process cadence
/// flipped between 5 s and 10 s. The slack absorbs that jitter. It is
/// smaller than any tick spacing the preferences allow, so nothing can fire a
/// whole tick early.
enum Cadence {
    /// The jitter is bounded by the timer's leeway, not by how precisely GCD
    /// usually fires: every tick may land anywhere up to the leeway late, so
    /// two consecutive ticks can be a whole leeway closer together than
    /// nominal. `MetricsEngine.restart` grants up to 250 ms at the slower
    /// refresh settings — 200 ms at two seconds — and the tenth of a second
    /// this used to be let the two-second thermal and power jobs slip to four
    /// seconds whenever the system spent its leeway. Above the largest
    /// leeway, below the shortest refresh interval (half a second).
    static let slack: TimeInterval = 0.3

    /// Whether a job last run at `last` (uptime; `nil` for never) is due
    /// again at `now`, given it should run every `period` seconds.
    static func isDue(
        _ last: TimeInterval?, every period: TimeInterval, at now: TimeInterval
    ) -> Bool {
        guard let last else { return true }
        return now - last >= period - slack
    }
}
