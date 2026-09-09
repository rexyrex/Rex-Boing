import Foundation
import Darwin
import IOKit
import SystemConfiguration

/// Network throughput from the per-interface 64-bit byte counters in the
/// routing table's `NET_RT_IFLIST2` records.
///
/// `getifaddrs` was the previous source, and its `if_data` counters are 32-bit:
/// they wrap about every 34 seconds at gigabit speeds. A wrapped 32-bit delta
/// is exact for a single wrap, but only one — a 10GbE machine at the 5-second
/// refresh moves ~5.9 GB per interval and would silently lose 4.29 GB of it per
/// wrap. `RTM_IFINFO2` describes the same interfaces with `if_data64` counters,
/// which do not wrap in any machine's lifetime, and it is also what
/// `getifaddrs` walks internally — minus the per-address allocations for
/// families this sampler never reads. Deltas are still taken per interface and
/// accumulated into a running total that is monotonic for as long as the app
/// is up.
final class NetworkSampler {
    private struct InterfaceCounters {
        var rx: UInt64
        var tx: UInt64
        /// `ifi_lastchange` changes when a link is reconfigured. Counters may
        /// reset at the same time without the interface name disappearing.
        var changeToken: Int64
    }

    private var previousCounters: [String: InterfaceCounters] = [:]
    private var runningRx: UInt64 = 0
    private var runningTx: UInt64 = 0
    private var hasBaseline = false
    private var lastSuccessfulSample: Date?
    private var lastSuccessfulUptime: TimeInterval?

    private var cachedPrimary: (name: String, address: String?)?
    private var lastPrimaryLookupUptime: TimeInterval?
    private var store: SCDynamicStore?

    func invalidateCachedPrimary() {
        lastPrimaryLookupUptime = nil
    }

    func sample(interval: TimeInterval) -> NetworkMetrics {
        var metrics = NetworkMetrics()

        let primary = primaryInterface()
        metrics.primaryInterface = primary?.name
        metrics.localAddress = primary?.address

        var current: [String: InterfaceCounters] = [:]
        current.reserveCapacity(previousCounters.count + 4)
        var rxDelta: UInt64 = 0
        var txDelta: UInt64 = 0

        let sampledAt = Date()
        let sampledUptime = ProcessInfo.processInfo.systemUptime
        let succeeded = withInterfaceList { name, data in
            guard Self.isCounted(name) else { return }

            let changeToken = Int64(data.ifi_lastchange.tv_sec) &* 1_000_000
                &+ Int64(data.ifi_lastchange.tv_usec)
            current[name] = InterfaceCounters(
                rx: data.ifi_ibytes, tx: data.ifi_obytes, changeToken: changeToken)

            // A missing baseline means the interface appeared since the last
            // sample (Wi-Fi associating, a VPN coming up); it contributes
            // nothing this interval rather than its entire lifetime total.
            guard let previous = previousCounters[name] else { return }
            // A link transition can reset the counters. At 64 bits a backwards
            // step can only be such a reset, never a wrap, so both guards drop
            // the interval rather than fabricate a delta spanning the counter's
            // whole range.
            guard previous.changeToken == changeToken,
                  data.ifi_ibytes >= previous.rx, data.ifi_obytes >= previous.tx
            else { return }
            rxDelta = Self.saturatingAdd(rxDelta, data.ifi_ibytes - previous.rx)
            txDelta = Self.saturatingAdd(txDelta, data.ifi_obytes - previous.tx)
        }

        // Preserve the last baselines on a transient routing-sysctl failure.
        // Clearing them loses the traffic in that window; retaining them while
        // still dividing by one tick makes the next sample spike. The elapsed
        // time below is therefore measured between successful reads.
        guard succeeded else {
            metrics.rxTotal = runningRx
            metrics.txTotal = runningTx
            return metrics
        }

        previousCounters = current

        if hasBaseline {
            runningRx = Self.saturatingAdd(runningRx, rxDelta)
            runningTx = Self.saturatingAdd(runningTx, txDelta)
            let wallElapsed = lastSuccessfulSample.map {
                sampledAt.timeIntervalSince($0)
            } ?? interval
            let elapsed = lastSuccessfulUptime.map { sampledUptime - $0 } ?? interval
            if elapsed > 0, elapsed <= 30, wallElapsed > 0, wallElapsed <= 30,
               abs(wallElapsed - elapsed) <= 1 {
                metrics.rxBytesPerSecond = Double(rxDelta) / elapsed
                metrics.txBytesPerSecond = Double(txDelta) / elapsed
            }
        }
        hasBaseline = true
        lastSuccessfulSample = sampledAt
        lastSuccessfulUptime = sampledUptime

        metrics.rxTotal = runningRx
        metrics.txTotal = runningTx
        return metrics
    }

    /// Enumerates every interface's name and 64-bit counters from one routing
    /// sysctl. The buffer is a packed run of `if_msghdr2` records, each padded
    /// to its own `ifm_msglen` and followed by the `sockaddr_dl` that carries
    /// the interface name; nothing in it is guaranteed aligned, hence the
    /// unaligned loads.
    @discardableResult
    private func withInterfaceList(_ body: (String, if_data64) -> Void) -> Bool {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var fetched: (buffer: [UInt8], size: Int)?

        // An interface can appear between the size query and the fetch. Slack
        // handles the common race; one full re-query handles a larger change
        // instead of turning it into a false zero sample.
        for _ in 0..<2 {
            var needed = 0
            guard sysctl(&mib, 6, nil, &needed, nil, 0) == 0, needed > 0 else {
                return false
            }
            var buffer = [UInt8](repeating: 0, count: needed + 1024)
            var size = buffer.count
            if sysctl(&mib, 6, &buffer, &size, nil, 0) == 0 {
                fetched = (buffer, size)
                break
            }
            guard errno == ENOMEM else { return false }
        }

        guard let fetched else { return false }
        let buffer = fetched.buffer
        let size = fetched.size

        buffer.withUnsafeBytes { raw in
            let typeOffset = MemoryLayout<if_msghdr>.offset(of: \.ifm_type) ?? 3
            let familyOffset = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_family) ?? 1
            let nameLengthOffset = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_nlen) ?? 5
            let nameOffset = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data) ?? 8

            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= size {
                let messageLength = Int(raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                guard messageLength > 0, offset + messageLength <= size else { break }

                let type = raw.loadUnaligned(fromByteOffset: offset + typeOffset, as: UInt8.self)
                if Int32(type) == RTM_IFINFO2, messageLength >= MemoryLayout<if_msghdr2>.size {
                    let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    let sdl = offset + MemoryLayout<if_msghdr2>.size
                    if sdl + nameOffset <= offset + messageLength,
                       raw.loadUnaligned(fromByteOffset: sdl + familyOffset, as: UInt8.self)
                           == UInt8(AF_LINK) {
                        let nameLength = Int(raw.loadUnaligned(
                            fromByteOffset: sdl + nameLengthOffset, as: UInt8.self))
                        if nameLength > 0, sdl + nameOffset + nameLength <= offset + messageLength {
                            let name = String(decoding: raw[
                                (sdl + nameOffset)..<(sdl + nameOffset + nameLength)],
                                as: UTF8.self)
                            body(name, message.ifm_data)
                        }
                    }
                }
                offset += messageLength
            }
        }
        return true
    }

    /// Loopback, tunnels and bridges all carry traffic that is also counted on
    /// the physical interface underneath them, so including them would double
    /// the reported throughput. AWDL and its low-latency sibling are excluded
    /// for a different reason: they are the peer-to-peer transport for
    /// AirDrop, Sidecar and Continuity, whose discovery chatter and transfer
    /// traffic is not what a network readout conventionally reports.
    private static let virtualPrefixes = ["lo", "gif", "stf", "bridge", "utun", "ipsec", "ppp", "awdl", "llw"]

    private static func isCounted(_ name: String) -> Bool {
        !virtualPrefixes.contains { name.hasPrefix($0) }
    }

    private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : sum
    }

    /// The primary interface only changes when the network does, so this is
    /// cached rather than re-resolved every second. The store itself is kept
    /// too — creating one is a bootstrap lookup, not a free allocation.
    ///
    /// "No primary interface" is cached on the same clock as a found one — an
    /// offline Mac would otherwise re-run the lookup on every tick for as long
    /// as it stayed offline.
    private func primaryInterface() -> (name: String, address: String?)? {
        let uptime = ProcessInfo.processInfo.systemUptime
        if lastPrimaryLookupUptime.map({ uptime - $0 < 10 }) ?? false {
            return cachedPrimary
        }
        lastPrimaryLookupUptime = uptime

        if store == nil {
            store = SCDynamicStoreCreate(nil, "Rex Boing" as CFString, nil, nil)
        }

        guard let store else {
            cachedPrimary = nil
            return nil
        }

        func primaryName(for family: String) -> String? {
            let global = SCDynamicStoreCopyValue(
                store, "State:/Network/Global/\(family)" as CFString) as? [String: Any]
            return global?["PrimaryInterface"] as? String
        }

        func addresses(for name: String, family: String) -> [String] {
            let state = SCDynamicStoreCopyValue(
                store,
                "State:/Network/Interface/\(name)/\(family)" as CFString) as? [String: Any]
            return state?["Addresses"] as? [String] ?? []
        }

        // IPv4 remains the conventional primary where both exist, but an
        // IPv6-only network is still a connected network and should not make
        // the dashboard's interface and local-address rows disappear.
        guard let name = primaryName(for: "IPv4") ?? primaryName(for: "IPv6") else {
            cachedPrimary = nil
            return nil
        }

        let ipv4 = addresses(for: name, family: "IPv4").first
        let ipv6Addresses = addresses(for: name, family: "IPv6")
        let ipv6 = ipv6Addresses.first { !$0.lowercased().hasPrefix("fe80:") }
            ?? ipv6Addresses.first

        cachedPrimary = (name, ipv4 ?? ipv6)
        return cachedPrimary
    }
}

/// Disk throughput from `IOBlockStorageDriver` statistics plus volume capacity.
///
/// The per-drive counters are 64-bit and monotonic, but the *set* of drives is
/// not: attaching an external disk introduces a counter that already holds that
/// drive's lifetime total, and diffing an aggregate across that event reports
/// a multi-terabyte spike in one interval. Deltas are therefore per drive, keyed
/// by IORegistry entry ID, and a drive with no baseline contributes nothing
/// until its second sample.
final class DiskSampler {
    private var previousCounters: [UInt64: (read: UInt64, write: UInt64)] = [:]
    private var runningRead: UInt64 = 0
    private var runningWrite: UInt64 = 0
    private var hasBaseline = false
    private var lastSuccessfulSample: Date?
    private var lastSuccessfulUptime: TimeInterval?

    private var cachedCapacity: (name: String, capacity: UInt64, available: UInt64)?
    private var lastCapacityLookupUptime: TimeInterval?

    func invalidateCachedCapacity() {
        lastCapacityLookupUptime = nil
    }

    /// Refresh metadata without touching the throughput counter baseline.
    func refreshCapacity(in metrics: inout DiskMetrics) {
        let volume = capacity()
        metrics.volumeName = volume.name
        metrics.capacity = volume.capacity
        metrics.available = volume.available
    }

    func sample(interval: TimeInterval, includeCapacity: Bool = true) -> DiskMetrics {
        var metrics = DiskMetrics()

        let sampledAt = Date()
        let sampledUptime = ProcessInfo.processInfo.systemUptime
        if let (readDelta, writeDelta) = throughputDeltas() {
            if hasBaseline {
                runningRead = Self.saturatingAdd(runningRead, readDelta)
                runningWrite = Self.saturatingAdd(runningWrite, writeDelta)
                let wallElapsed = lastSuccessfulSample.map {
                    sampledAt.timeIntervalSince($0)
                } ?? interval
                let elapsed = lastSuccessfulUptime.map {
                    sampledUptime - $0
                } ?? interval
                if elapsed > 0, elapsed <= 30, wallElapsed > 0, wallElapsed <= 30,
                   abs(wallElapsed - elapsed) <= 1 {
                    metrics.readBytesPerSecond = Double(readDelta) / elapsed
                    metrics.writeBytesPerSecond = Double(writeDelta) / elapsed
                }
            }
            hasBaseline = true
            lastSuccessfulSample = sampledAt
            lastSuccessfulUptime = sampledUptime
        }

        metrics.readTotal = runningRead
        metrics.writeTotal = runningWrite

        // Purgeable-space accounting can invoke CacheDelete and enumerate
        // volumes. Only the dashboard displays capacity; throughput/history
        // need none of that work while it is closed.
        let volume = includeCapacity ? capacity()
            : cachedCapacity ?? (name: "Macintosh HD", capacity: 0, available: 0)
        metrics.volumeName = volume.name
        metrics.capacity = volume.capacity
        metrics.available = volume.available

        return metrics
    }

    private func throughputDeltas() -> (read: UInt64, write: UInt64)? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator)
            == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }

        var current: [UInt64: (read: UInt64, write: UInt64)] = [:]
        current.reserveCapacity(previousCounters.count + 2)
        var readDelta: UInt64 = 0
        var writeDelta: UInt64 = 0
        var sawDrive = false
        var sawCounters = false

        while case let drive = IOIteratorNext(iterator), drive != 0 {
            defer { IOObjectRelease(drive) }
            sawDrive = true

            var entryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(drive, &entryID) == KERN_SUCCESS else { continue }
            guard let statistics = IORegistryEntryCreateCFProperty(
                drive, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSDictionary
            else { continue }
            sawCounters = true

            let read = UInt64(max(0, (statistics["Bytes (Read)"] as? NSNumber)?.int64Value ?? 0))
            let write = UInt64(max(0, (statistics["Bytes (Write)"] as? NSNumber)?.int64Value ?? 0))
            current[entryID] = (read, write)

            guard let previous = previousCounters[entryID] else { continue }
            if read > previous.read {
                readDelta = Self.saturatingAdd(readDelta, read - previous.read)
            }
            if write > previous.write {
                writeDelta = Self.saturatingAdd(writeDelta, write - previous.write)
            }
        }

        // A matching service with no readable statistics is a failed pass, not
        // a machine whose drives all vanished at once. Keep the old baselines
        // so a later successful pass can average over the full elapsed window.
        guard !sawDrive || sawCounters else { return nil }
        // An iterator the registry invalidated mid-walk (a drive attaching or
        // detaching) ends exactly like a finished one, but its table may be
        // missing drives — accepting it would drop their baselines and lose
        // that interval's traffic, or read an empty torn pass as a driveless
        // machine. Same rule as above: fail the pass, keep the baselines.
        guard IOIteratorIsValid(iterator) != 0 else { return nil }
        previousCounters = current
        return (readDelta, writeDelta)
    }

    private func capacity() -> (name: String, capacity: UInt64, available: UInt64) {
        let uptime = ProcessInfo.processInfo.systemUptime
        if lastCapacityLookupUptime.map({ uptime - $0 < 30 }) ?? false {
            return cachedCapacity ?? ("Macintosh HD", 0, 0)
        }

        let url = URL(fileURLWithPath: "/")
        var name = "Macintosh HD"
        var capacity: UInt64 = 0
        var available: UInt64 = 0

        if let values = try? url.resourceValues(forKeys: [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]) {
            name = values.volumeName ?? name
            capacity = UInt64(max(0, values.volumeTotalCapacity ?? 0))
            available = UInt64(max(0, values.volumeAvailableCapacityForImportantUsage ?? 0))

            let result = (name, capacity, available)
            cachedCapacity = result
            lastCapacityLookupUptime = uptime
            return result
        }

        // Do not replace a valid capacity with zero because one metadata read
        // failed. Rate-limit retries just as successful lookups are cached.
        lastCapacityLookupUptime = uptime - 25
        return cachedCapacity ?? (name, capacity, available)
    }

    private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : sum
    }
}
