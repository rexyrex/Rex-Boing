import Foundation

/// Turns the app's readings into the JSON the MCP tools return.
///
/// Pure functions of values: the app hands in what it holds, and the headless
/// check hands in synthetic snapshots and histories and holds the output to
/// the conventions, which are shared with Rex Boing Remote's server:
///
/// - every key that carries a number names its unit (`…Percent` 0 to 100,
///   `…Bytes`, `…BytesPerSecond`, `…Celsius`, `…Watts`, `…RPM`, `…MHz`,
///   `…Seconds`), and no 0...1 fraction leaves under any name;
/// - a reading this Mac has no source for is left out, never written as 0,
///   and nothing non-finite is written at all;
/// - times are ISO 8601 with the local offset;
/// - every list is bounded, and says when it was cut (`total`, `truncated`).
enum MCPPayload {
    // MARK: - get_snapshot

    /// How many sensors per group the thermal section lists unless asked for
    /// all of them: the hottest, which is what a question about heat is about.
    static let sensorsPerGroup = 3
    static let sleepBlockerLimit = 20
    static let assertionNamesPerBlocker = 5

    static func snapshot(_ snapshot: Snapshot, sections: [SnapshotSection], allSensors: Bool, now: Date) -> JSONValue {
        var root = JSONObject()
        root["sampledAt"] = .time(snapshot.timestamp)
        root["ageSeconds"] = .number(max(0, now.timeIntervalSince(snapshot.timestamp)), 1)
        root["intervalSeconds"] = .number(snapshot.interval, 2)
        var unavailable: [JSONValue] = []
        for section in sections {
            let value: JSONValue?
            switch section {
            case .host: value = host(snapshot.host, now: now)
            case .cpu: value = cpu(snapshot.cpu, host: snapshot.host)
            case .gpu: value = gpu(snapshot.gpu)
            case .memory: value = memory(snapshot.memory)
            case .thermal: value = thermal(snapshot.thermal, allSensors: allSensors)
            case .power: value = power(snapshot.power)
            case .battery: value = battery(snapshot.battery)
            case .network: value = network(snapshot.network)
            case .disk: value = disk(snapshot.disk)
            case .sleep: value = sleep(snapshot.sleep)
            }
            if let value {
                root[section.rawValue] = value
            } else {
                unavailable.append(.string(section.rawValue))
            }
        }
        if !unavailable.isEmpty { root["unavailable"] = .array(unavailable) }
        return root.value
    }

    private static func nonEmpty(_ text: String?) -> JSONValue? {
        guard let text, !text.isEmpty else { return nil }
        return .string(text)
    }

    private static func positive(_ value: Int?) -> JSONValue? {
        guard let value, value > 0 else { return nil }
        return .int(value)
    }

    private static func positiveBytes(_ value: UInt64) -> JSONValue? {
        value > 0 ? .bytes(value) : nil
    }

    static func host(_ host: HostDescription, now: Date) -> JSONValue {
        var object = JSONObject()
        object["modelName"] = nonEmpty(host.modelName)
        object["modelIdentifier"] = nonEmpty(host.modelIdentifier)
        object["chip"] = nonEmpty(host.chipName)
        object["macOSVersion"] = nonEmpty(host.osVersion)
        object["appleSilicon"] = .bool(host.isAppleSilicon)
        object["physicalCores"] = positive(host.physicalCores)
        object["logicalCores"] = positive(host.logicalCores)
        if host.isAppleSilicon {
            object["performanceCores"] = positive(host.performanceCores)
            object["efficiencyCores"] = positive(host.efficiencyCores)
        }
        object["memoryBytes"] = positiveBytes(host.memoryBytes)
        // `distantPast` is the model's "never read".
        if host.bootTime.timeIntervalSince1970 > 0 {
            object["bootedAt"] = .time(host.bootTime)
            object["uptimeSeconds"] = .number(max(0, now.timeIntervalSince(host.bootTime)), 0)
        }
        return object.value
    }

    static func cpu(_ cpu: CPUMetrics, host: HostDescription) -> JSONValue {
        var object = JSONObject()
        object["totalPercent"] = .percent(cpu.total)
        object["userPercent"] = .percent(cpu.user)
        object["systemPercent"] = .percent(cpu.system)
        object["idlePercent"] = .percent(cpu.idle)
        var load = JSONObject()
        load["oneMinute"] = .number(cpu.loadAverage.one, 2)
        load["fiveMinutes"] = .number(cpu.loadAverage.five, 2)
        load["fifteenMinutes"] = .number(cpu.loadAverage.fifteen, 2)
        object["loadAverage"] = load.value
        if !cpu.perCore.isEmpty {
            object["perCorePercent"] = .array(cpu.perCore.map { .percent($0) ?? .null })
            if cpu.coreKinds.count == cpu.perCore.count, cpu.coreKinds.contains(where: { $0 != .unknown }) {
                // One letter per core, in the same order: E or P.
                object["coreKinds"] = .string(cpu.coreKinds.map(\.rawValue).joined())
            }
        }
        if host.efficiencyCores > 0, host.performanceCores > 0 {
            object["efficiencyPercent"] = .percent(cpu.efficiencyLoad)
            object["performancePercent"] = .percent(cpu.performanceLoad)
        }
        object["efficiencyClockMHz"] = .number(cpu.efficiencyClockMHz, 0)
        object["performanceClockMHz"] = .number(cpu.performanceClockMHz, 0)
        object["processCount"] = positive(cpu.processCount)
        object["threadCount"] = positive(cpu.threadCount)
        return object.value
    }

    static func gpu(_ gpu: GPUMetrics) -> JSONValue? {
        guard gpu.available else { return nil }
        var object = JSONObject()
        object["name"] = nonEmpty(gpu.name)
        object["coreCount"] = positive(gpu.coreCount)
        object["utilizationPercent"] = .percent(gpu.utilization)
        object["rendererPercent"] = .percent(gpu.rendererUtilization)
        object["tilerPercent"] = .percent(gpu.tilerUtilization)
        object["inUseMemoryBytes"] = positiveBytes(gpu.inUseMemory)
        object["allocatedMemoryBytes"] = positiveBytes(gpu.allocatedMemory)
        object["totalMemoryBytes"] = positiveBytes(gpu.totalMemory)
        object["clockMHz"] = .number(gpu.clockMHz, 0)
        return object.value
    }

    static func memory(_ memory: MemoryMetrics) -> JSONValue? {
        guard memory.total > 0 else { return nil }
        var object = JSONObject()
        object["totalBytes"] = .bytes(memory.total)
        object["usedBytes"] = .bytes(memory.used)
        object["usedPercent"] = .percent(memory.fractionUsed)
        object["appBytes"] = .bytes(memory.app)
        object["wiredBytes"] = .bytes(memory.wired)
        object["compressedBytes"] = .bytes(memory.compressed)
        object["cachedBytes"] = .bytes(memory.cached)
        object["freeBytes"] = .bytes(memory.free)
        object["inactiveBytes"] = .bytes(memory.inactive)
        object["purgeableBytes"] = .bytes(memory.purgeable)
        // The kernel's own pressure figure, not used over total.
        object["pressurePercent"] = .percent(memory.pressure)
        object["pressureLevel"] = .string(memory.pressureLevel.label.lowercased())
        var swap = JSONObject()
        swap["totalBytes"] = .bytes(memory.swap.total)
        swap["usedBytes"] = .bytes(memory.swap.used)
        swap["freeBytes"] = .bytes(memory.swap.free)
        if memory.swap.total > 0 { swap["usedPercent"] = .percent(memory.swap.fraction) }
        swap["encrypted"] = .bool(memory.swap.encrypted)
        swap["pageInBytesPerSecond"] = .number(memory.swap.inRate, 0)
        swap["pageOutBytesPerSecond"] = .number(memory.swap.outRate, 0)
        object["swap"] = swap.value
        return object.value
    }

    static func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    static func thermal(_ thermal: ThermalMetrics, allSensors: Bool) -> JSONValue? {
        let sensors = thermal.sensors.filter { $0.celsius.isFinite }
        var object = JSONObject()
        object["cpuCelsius"] = .number(thermal.cpuCelsius, 1)
        object["gpuCelsius"] = .number(thermal.gpuCelsius, 1)
        object["socCelsius"] = .number(thermal.socCelsius, 1)
        object["batteryCelsius"] = .number(thermal.batteryCelsius, 1)
        object["storageCelsius"] = .number(thermal.storageCelsius, 1)
        object["peakCelsius"] = .number(thermal.peakCelsius, 1)
        let fans = thermal.fans.filter { $0.rpm.isFinite }
        // A thermal state alone is a reading every Mac has; the section is
        // unavailable only when there is not one temperature or fan to show.
        guard !object.isEmpty || !sensors.isEmpty || !fans.isEmpty else { return nil }
        object["thermalState"] = .string(thermalStateName(thermal.thermalState))
        if !fans.isEmpty {
            object["fans"] = .array(fans.map { fan in
                var entry = JSONObject()
                entry["index"] = .int(fan.index)
                entry["speedRPM"] = .number(fan.rpm, 0)
                entry["minRPM"] = .number(fan.minRPM > 0 ? fan.minRPM : nil, 0)
                entry["maxRPM"] = .number(fan.maxRPM > 0 ? fan.maxRPM : nil, 0)
                // Where the speed sits between the fan's rated minimum and maximum.
                if fan.maxRPM > fan.minRPM { entry["speedRangePercent"] = .percent(fan.fraction, 0) }
                return entry.value
            })
        }
        if !sensors.isEmpty {
            object["sensorCount"] = .int(sensors.count)
            let groups = thermal.groups.isEmpty ? SensorGroup.grouped(sensors) : thermal.groups
            object["sensorGroups"] = .array(groups.compactMap { group -> JSONValue? in
                let members = group.sensors.filter { $0.celsius.isFinite }.sorted { $0.celsius > $1.celsius }
                guard !members.isEmpty else { return nil }
                var entry = JSONObject()
                entry["category"] = .string(group.category.rawValue)
                entry["count"] = .int(members.count)
                entry["maxCelsius"] = .number(members.first?.celsius, 1)
                entry["meanCelsius"] = .number(members.map(\.celsius).reduce(0, +) / Double(members.count), 1)
                let shown = allSensors ? members : Array(members.prefix(sensorsPerGroup))
                entry["sensors"] = .array(shown.map { sensor in
                    ["key": .string(sensor.key), "label": .string(sensor.label), "celsius": .number(sensor.celsius, 1) ?? .null]
                })
                entry["truncated"] = .bool(shown.count < members.count)
                return entry.value
            })
        }
        return object.value
    }

    static func power(_ power: PowerMetrics) -> JSONValue? {
        guard power.hasAny else { return nil }
        var object = JSONObject()
        object["totalWatts"] = .number(power.totalWatts, 2)
        if power.systemTotalWatts != nil {
            object["totalSource"] = "system rail"
        } else if power.systemWatts != nil {
            object["totalSource"] = "battery"
        } else if power.packageWatts != nil {
            object["totalSource"] = "package"
        }
        object["systemRailWatts"] = .number(power.systemTotalWatts, 2)
        object["batteryDischargeWatts"] = .number(power.systemWatts, 2)
        object["dcInWatts"] = .number(power.dcInWatts, 2)
        object["adapterRatedWatts"] = .number(power.adapterWatts, 0)
        object["cpuWatts"] = .number(power.cpuWatts, 2)
        object["gpuWatts"] = .number(power.gpuWatts, 2)
        object["neuralEngineWatts"] = .number(power.aneWatts, 2)
        object["packageWatts"] = .number(power.packageWatts, 2)
        if power.cpuIsPackage { object["cpuIsPackage"] = true }
        return object.value
    }

    static func battery(_ battery: BatteryMetrics) -> JSONValue? {
        guard battery.present else { return nil }
        var object = JSONObject()
        object["chargePercent"] = .percent(battery.percentage, 0)
        object["charging"] = .bool(battery.isCharging)
        object["pluggedIn"] = .bool(battery.isPluggedIn)
        object["timeRemainingSeconds"] = battery.timeRemainingMinutes.map { .int($0 * 60) }
        object["cycleCount"] = battery.cycleCount.map(JSONValue.int)
        object["healthPercent"] = .percent(battery.healthFraction, 0)
        object["condition"] = nonEmpty(battery.condition)
        object["celsius"] = .number(battery.celsius, 1)
        object["chargingWatts"] = .number(battery.chargingWatts, 2)
        object["dischargeWatts"] = .number(battery.systemWatts, 2)
        object["adapterWatts"] = .number(battery.adapterWatts, 0)
        return object.value
    }

    static func network(_ network: NetworkMetrics) -> JSONValue {
        var object = JSONObject()
        object["receiveBytesPerSecond"] = .number(network.rxBytesPerSecond, 0)
        object["sendBytesPerSecond"] = .number(network.txBytesPerSecond, 0)
        object["receivedSinceLaunchBytes"] = .bytes(network.rxTotal)
        object["sentSinceLaunchBytes"] = .bytes(network.txTotal)
        object["primaryInterface"] = nonEmpty(network.primaryInterface)
        object["localAddress"] = nonEmpty(network.localAddress)
        return object.value
    }

    static func disk(_ disk: DiskMetrics) -> JSONValue {
        var object = JSONObject()
        object["readBytesPerSecond"] = .number(disk.readBytesPerSecond, 0)
        object["writeBytesPerSecond"] = .number(disk.writeBytesPerSecond, 0)
        object["readSinceLaunchBytes"] = .bytes(disk.readTotal)
        object["writtenSinceLaunchBytes"] = .bytes(disk.writeTotal)
        // Capacity is resolved only while something detailed is watching;
        // zero is "not read", not an empty disk.
        if disk.capacity > 0 {
            var volume = JSONObject()
            volume["name"] = nonEmpty(disk.volumeName)
            volume["capacityBytes"] = .bytes(disk.capacity)
            volume["availableBytes"] = .bytes(disk.available)
            volume["usedBytes"] = .bytes(disk.used)
            volume["usedPercent"] = .percent(disk.fractionUsed)
            object["volume"] = volume.value
        }
        return object.value
    }

    static func sleep(_ sleep: SleepMetrics) -> JSONValue? {
        guard sleep.sampled else { return nil }
        var object = JSONObject()
        let blockers = sleep.blockers
        object["displaySleepPrevented"] = .bool(blockers.contains { $0.preventsDisplaySleep })
        // A display assertion holds the system up with the screen.
        object["systemSleepPrevented"] = .bool(blockers.contains { $0.preventsDisplaySleep || $0.preventsSystemSleep })
        object["total"] = .int(blockers.count)
        object["truncated"] = .bool(blockers.count > sleepBlockerLimit)
        object["blockers"] = .array(blockers.prefix(sleepBlockerLimit).map { blocker in
            var entry = JSONObject()
            entry["pid"] = .int(Int(blocker.pid))
            entry["name"] = .string(blocker.name)
            entry["preventsDisplaySleep"] = .bool(blocker.preventsDisplaySleep)
            entry["preventsSystemSleep"] = .bool(blocker.preventsSystemSleep)
            entry["assertions"] = .array(blocker.assertionNames.prefix(assertionNamesPerBlocker).map(JSONValue.string))
            return entry.value
        })
        return object.value
    }

    // MARK: - get_processes

    static func processes(_ snapshot: Snapshot, sortBy: ProcessSort, limit: Int, now: Date) -> JSONValue {
        let table = snapshot.processes
        var object = JSONObject()
        if table.sampledAt.timeIntervalSince1970 > 0 {
            object["sampledAt"] = .time(table.sampledAt)
            object["ageSeconds"] = .number(max(0, now.timeIntervalSince(table.sampledAt)), 1)
        }
        if table.interval > 0, table.interval <= 30 {
            object["intervalSeconds"] = .number(table.interval, 2)
        }
        object["sortBy"] = .string(sortBy.rawValue)
        object["processCount"] = positive(table.count)
        object["gpuAttributionAvailable"] = .bool(table.gpuAttributionAvailable)
        let ranked = table.leaders[sortBy.metric] ?? []
        object["total"] = .int(ranked.count)
        object["truncated"] = .bool(ranked.count > limit)
        object["processes"] = .array(ranked.prefix(limit).map(row))
        return object.value
    }

    /// The app a process belongs to: the outermost `.app` bundle its
    /// executable lives in, the rule the dashboard groups helpers by.
    static func owningApp(of path: String?) -> String? {
        guard let path else { return nil }
        guard let component = path.split(separator: "/").first(where: { $0.hasSuffix(".app") }) else { return nil }
        let name = component.dropLast(4)
        return name.isEmpty ? nil : String(name)
    }

    static func row(_ row: ProcessRow) -> JSONValue {
        var object = JSONObject()
        object["pid"] = .int(Int(row.pid))
        object["name"] = .string(row.name)
        object["app"] = owningApp(of: row.executablePath).map(JSONValue.string)
        object["bundleIdentifier"] = nonEmpty(row.bundleIdentifier)
        object["executablePath"] = nonEmpty(row.executablePath)
        if row.startTime > 0 {
            object["startedAt"] = .time(Date(timeIntervalSince1970: Double(row.startTime) / 1_000_000))
        }
        object["gpuPercent"] = .number(row.gpuPercent, 1)
        // Another user's process is only visible through its GPU clients:
        // libproc refuses the rest, so the rest is left out rather than
        // reported as an idle process with no memory.
        let measured = row.threadCount > 0 || row.memoryBytes > 0
        if measured {
            object["cpuPercent"] = .number(row.cpuPercent, 1)
            object["memoryBytes"] = .bytes(row.memoryBytes)
            object["energyImpact"] = .number(row.energyImpact, 1)
            // The score is ten per watt; the watts are what it stands for.
            object["energyWatts"] = .number(row.energyImpact / 10, 3)
            object["diskReadBytesPerSecond"] = .number(row.diskReadBytesPerSecond, 0)
            object["diskWriteBytesPerSecond"] = .number(row.diskWriteBytesPerSecond, 0)
            object["wakeupsPerSecond"] = .number(row.wakeupsPerSecond, 1)
            object["threads"] = positive(row.threadCount)
        }
        return object.value
    }

    // MARK: - get_history

    /// Bucket widths a person reads at a glance: every bucket starts on a
    /// round second, minute or hour, so the times line up with a clock.
    static let bucketSteps: [TimeInterval] = [
        1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200, 10_800, 21_600, 43_200, 86_400,
    ]

    /// One stored reading: a sample (count 1) or a minute's aggregate.
    struct Record {
        var time: Date
        var sum: Double
        var count: Int
        var minimum: Double
        var maximum: Double
    }

    static func history(
        fine: MetricsHistory, minute: MinuteHistory, series: [HistorySeries],
        from: Date, to: Date, points: Int, sampleInterval: TimeInterval
    ) -> JSONValue {
        // The per-sample rings answer whenever nothing in the window has been
        // dropped from them yet; otherwise the minutes do.
        let fineTimes = fine.cpu.timestamps
        let fineCovers = fine.cpu.count < fine.cpu.capacity
            || (fineTimes.first.map { $0 <= from.addingTimeInterval(max(1, sampleInterval)) } ?? true)
        let resolution = fineCovers ? max(0.25, sampleInterval) : MinuteHistory.bucketWidth

        func records(for item: HistorySeries) -> [Record] {
            if fineCovers {
                let ring = item.ring(in: fine)
                return zip(ring.timestamps, ring.values).compactMap { time, value in
                    guard time >= from, time <= to, value.isFinite else { return nil }
                    return Record(time: time, sum: value, count: 1, minimum: value, maximum: value)
                }
            }
            return minute.buckets(item.minuteSeries, from: from, through: to).map {
                Record(time: $0.start, sum: $0.sum, count: $0.count, minimum: $0.minimum, maximum: $0.maximum)
            }
        }

        let span = max(1, to.timeIntervalSince(from))
        var step = bucketSteps.first { $0 >= max(resolution, span / Double(points)) } ?? 86_400
        func layout(_ step: TimeInterval) -> (start: TimeInterval, count: Int) {
            let start = (from.timeIntervalSince1970 / step).rounded(.down) * step
            let count = Int(((to.timeIntervalSince1970 - start) / step).rounded(.up))
            return (start, max(1, count))
        }
        // Aligning the first bucket to the clock can add one at the edge.
        while layout(step).count > points, let next = bucketSteps.first(where: { $0 > step }) { step = next }
        let (bucketStart, bucketCount) = layout(step)

        var object = JSONObject()
        object["from"] = .time(from)
        object["to"] = .time(to)
        object["windowSeconds"] = .number(span, 0)
        object["source"] = fineCovers ? "samples" : "minutes"
        object["resolutionSeconds"] = .number(resolution, 2)
        object["bucketSeconds"] = .number(step, 0)
        object["bucketStarts"] = .array((0..<bucketCount).map {
            .time(Date(timeIntervalSince1970: bucketStart + Double($0) * step))
        })

        var output: [String: JSONValue] = [:]
        var noData: [JSONValue] = []
        for item in series {
            let found = records(for: item)
            guard !found.isEmpty else {
                noData.append(.string(item.rawValue))
                continue
            }
            var sums = [Double](repeating: 0, count: bucketCount)
            var counts = [Int](repeating: 0, count: bucketCount)
            var peaks = [Double](repeating: -.infinity, count: bucketCount)
            var total = 0.0, samples = 0
            var lowest = found[0], highest = found[0]
            for record in found {
                let index = min(bucketCount - 1, max(0, Int((record.time.timeIntervalSince1970 - bucketStart) / step)))
                sums[index] += record.sum
                counts[index] += record.count
                peaks[index] = max(peaks[index], record.maximum)
                total += record.sum
                samples += record.count
                if record.minimum < lowest.minimum { lowest = record }
                if record.maximum > highest.maximum { highest = record }
            }
            let scale = item.scale, decimals = item.decimals
            func scaled(_ value: Double?) -> JSONValue {
                JSONValue.number(value.map { $0 * scale }, decimals) ?? .null
            }
            var entry = JSONObject()
            entry["samples"] = .int(samples)
            entry["min"] = scaled(lowest.minimum)
            entry["minAt"] = .time(lowest.time)
            entry["mean"] = scaled(samples > 0 ? total / Double(samples) : nil)
            entry["max"] = scaled(highest.maximum)
            entry["maxAt"] = .time(highest.time)
            entry["means"] = .array((0..<bucketCount).map { counts[$0] > 0 ? scaled(sums[$0] / Double(counts[$0])) : .null })
            entry["peaks"] = .array((0..<bucketCount).map { counts[$0] > 0 ? scaled(peaks[$0]) : .null })
            output[item.rawValue] = entry.value
        }
        object["series"] = .object(output)
        if !noData.isEmpty { object["noData"] = .array(noData) }
        return object.value
    }

    // MARK: - get_process_history

    /// A process's figure for a ranking, in the unit its key will name.
    private static func measure(_ sort: ProcessSort, of row: ProcessRow) -> Double {
        switch sort {
        case .cpu: return row.cpuPercent
        case .memory: return Double(row.memoryBytes)
        case .gpu: return row.gpuPercent
        case .energy: return row.energyImpact / 10
        case .disk: return row.diskBytesPerSecond
        }
    }

    private static func measureName(_ sort: ProcessSort) -> (suffix: String, decimals: Int) {
        switch sort {
        case .cpu: return ("CpuPercent", 1)
        case .memory: return ("MemoryBytes", 0)
        case .gpu: return ("GpuPercent", 1)
        case .energy: return ("EnergyWatts", 3)
        case .disk: return ("DiskBytesPerSecond", 0)
        }
    }

    private static func totals(_ totals: SystemTotals) -> JSONValue {
        var object = JSONObject()
        object["cpuPercent"] = .percent(totals.cpuFraction)
        if totals.gpuAvailable { object["gpuPercent"] = .percent(totals.gpuFraction) }
        if totals.memoryTotalBytes > 0 {
            object["memoryUsedPercent"] = .percent(totals.memoryFraction)
            object["memoryUsedBytes"] = .bytes(totals.memoryUsedBytes)
            object["memoryTotalBytes"] = .bytes(totals.memoryTotalBytes)
        }
        object["totalWatts"] = .number(totals.watts, 2)
        object["diskReadBytesPerSecond"] = .number(totals.diskReadBytesPerSecond, 0)
        object["diskWriteBytesPerSecond"] = .number(totals.diskWriteBytesPerSecond, 0)
        return object.value
    }

    private static func retained(_ samples: [ProcessSample]) -> JSONValue {
        guard let first = samples.first, let last = samples.last else { return ["tables": 0] }
        return ["from": .time(first.timestamp), "to": .time(last.timestamp), "tables": .int(samples.count)]
    }

    static func processHistory(
        _ samples: [ProcessSample], at: Date?, window: TimeInterval?,
        sortBy: ProcessSort, limit: Int, now: Date
    ) -> Result<JSONValue, MCPToolError> {
        guard let first = samples.first, let last = samples.last else {
            return .failure(MCPToolError(.notReady, "Rex Boing has not kept a process table yet; it takes one every few seconds. Call again shortly."))
        }
        let (suffix, decimals) = measureName(sortBy)

        guard let window else {
            let target = at ?? last.timestamp
            guard target >= first.timestamp.addingTimeInterval(-60) else {
                return .failure(MCPToolError(
                    .notFound,
                    "Rex Boing keeps process tables back to \(MCPTime.iso(first.timestamp)) only. Ask about a later moment, or use get_app_usage for longer windows.",
                    detail: ["retained": retained(samples)]))
            }
            // Timestamps are appended in order: binary search for the first
            // at or after the target, then take it or the one before.
            var low = 0, high = samples.count
            while low < high {
                let middle = (low + high) / 2
                if samples[middle].timestamp < target { low = middle + 1 } else { high = middle }
            }
            let index = [low - 1, low].filter { samples.indices.contains($0) }.min {
                abs(samples[$0].timestamp.timeIntervalSince(target)) < abs(samples[$1].timestamp.timeIntervalSince(target))
            } ?? samples.count - 1
            let sample = samples[index]
            let ranked = sample.rows
                .filter { measure(sortBy, of: $0) > 0 }
                .sorted { measure(sortBy, of: $0) > measure(sortBy, of: $1) }
            var object = JSONObject()
            if let at { object["requestedAt"] = .time(at) }
            object["sampledAt"] = .time(sample.timestamp)
            if at != nil { object["offsetSeconds"] = .number(sample.timestamp.timeIntervalSince(target), 1) }
            object["intervalSeconds"] = .number(sample.interval, 2)
            object["processCount"] = positive(sample.processCount)
            object["gpuAttributionAvailable"] = .bool(sample.gpuAttributionAvailable)
            object["totals"] = totals(sample.totals)
            object["sortBy"] = .string(sortBy.rawValue)
            object["total"] = .int(ranked.count)
            object["truncated"] = .bool(ranked.count > limit)
            object["processes"] = .array(ranked.prefix(limit).map(row))
            object["retained"] = retained(samples)
            return .success(object.value)
        }

        let from = at.map { $0.addingTimeInterval(-window / 2) } ?? now.addingTimeInterval(-window)
        let to = at.map { $0.addingTimeInterval(window / 2) } ?? now
        let inWindow = samples.filter { $0.timestamp >= from && $0.timestamp <= to }
        guard !inWindow.isEmpty else {
            return .failure(MCPToolError(
                .notFound,
                "No process table was kept between \(MCPTime.iso(from)) and \(MCPTime.iso(to)). Rex Boing keeps them from \(MCPTime.iso(first.timestamp)) to \(MCPTime.iso(last.timestamp)).",
                detail: ["retained": retained(samples)]))
        }

        struct Tally {
            var row: ProcessRow
            var tables = 0
            var sum = 0.0
            var peak = -Double.infinity
            var peakAt = Date.distantPast
        }
        var tallies: [String: Tally] = [:]
        var cpu = (sum: 0.0, peak: -Double.infinity, at: Date.distantPast)
        for sample in inWindow {
            cpu.sum += sample.totals.cpuFraction
            if sample.totals.cpuFraction > cpu.peak { cpu = (cpu.sum, sample.totals.cpuFraction, sample.timestamp) }
            for row in sample.rows {
                let value = measure(sortBy, of: row)
                guard value > 0 else { continue }
                let key = "\(row.pid):\(row.startTime)"
                var tally = tallies[key] ?? Tally(row: row)
                tally.tables += 1
                tally.sum += value
                if value > tally.peak { tally.peak = value; tally.peakAt = sample.timestamp }
                tallies[key] = tally
            }
        }
        // Averaged over every table in the span, a table a process did not
        // place in counting as zero: a lower bound, and the fair way to rank
        // a steady hog against a single spike.
        let count = Double(inWindow.count)
        let ranked = tallies.values.sorted { $0.sum > $1.sum }
        var object = JSONObject()
        object["from"] = .time(from)
        object["to"] = .time(to)
        object["tables"] = .int(inWindow.count)
        var system = JSONObject()
        system["meanCpuPercent"] = .percent(cpu.sum / count)
        system["peakCpuPercent"] = .percent(cpu.peak)
        system["peakCpuAt"] = .time(cpu.at)
        object["totals"] = system.value
        object["sortBy"] = .string(sortBy.rawValue)
        object["total"] = .int(ranked.count)
        object["truncated"] = .bool(ranked.count > limit)
        object["processes"] = .array(ranked.prefix(limit).map { tally in
            var entry = JSONObject()
            entry["pid"] = .int(Int(tally.row.pid))
            entry["name"] = .string(tally.row.name)
            entry["app"] = owningApp(of: tally.row.executablePath).map(JSONValue.string)
            entry["bundleIdentifier"] = nonEmpty(tally.row.bundleIdentifier)
            entry["tablesPlaced"] = .int(tally.tables)
            entry["mean" + suffix] = .number(tally.sum / count, decimals)
            entry["peak" + suffix] = .number(tally.peak, decimals)
            entry["peakAt"] = .time(tally.peakAt)
            return entry.value
        })
        object["retained"] = retained(samples)
        return .success(object.value)
    }

    // MARK: - get_app_usage

    static func appUsage(_ report: AppUsageReport, sortBy: UsageSort, limit: Int, now: Date) -> JSONValue {
        let covered = report.coveredSeconds
        func rank(_ totals: AppUsageTotals) -> Double {
            switch sortBy {
            case .cpu: return Double(totals.cpuNanos)
            case .energy: return Double(totals.energyNanojoules)
            case .gpu: return Double(totals.gpuNanos)
            case .disk: return Double(totals.diskReadBytes) + Double(totals.diskWriteBytes)
            // A gauge ranks by its time-average, so holding two gigabytes for
            // a minute does not outrank one gigabyte all afternoon.
            case .memory: return covered > 0 ? Double(totals.memoryByteSeconds) / covered : 0
            case .wakeups: return Double(totals.wakeups)
            }
        }
        let ranked = covered > 0
            ? report.rows.filter { rank($0.totals) > 0 }.sorted { rank($0.totals) > rank($1.totals) }
            : []

        var object = JSONObject()
        object["from"] = .time(now.addingTimeInterval(-report.window))
        object["to"] = .time(now)
        object["windowSeconds"] = .number(report.window, 0)
        object["coveredSeconds"] = .number(covered, 0)
        if let earliest = report.earliestData { object["earliestDataAt"] = .time(earliest) }
        object["sortBy"] = .string(sortBy.rawValue)
        object["total"] = .int(ranked.count)
        object["truncated"] = .bool(ranked.count > limit)
        object["apps"] = .array(ranked.prefix(limit).map { row in
            let totals = row.totals
            var entry = JSONObject()
            entry["name"] = .string(row.attribution.displayName)
            if let bundle = row.attribution.bundlePath {
                entry["bundlePath"] = .string(bundle)
            } else {
                entry["executablePath"] = nonEmpty(row.attribution.executablePath)
            }
            let cpuSeconds = Double(totals.cpuNanos) / 1e9
            let gpuSeconds = Double(totals.gpuNanos) / 1e9
            let joules = Double(totals.energyNanojoules) / 1e9
            entry["cpuSeconds"] = .number(cpuSeconds, 2)
            entry["averageCpuPercent"] = .number(cpuSeconds / covered * 100, 1)
            entry["energyJoules"] = .number(joules, 2)
            entry["averageWatts"] = .number(joules / covered, 3)
            entry["gpuSeconds"] = .number(gpuSeconds, 2)
            entry["averageGpuPercent"] = .number(gpuSeconds / covered * 100, 1)
            entry["diskReadBytes"] = .bytes(totals.diskReadBytes)
            entry["diskWriteBytes"] = .bytes(totals.diskWriteBytes)
            entry["averageMemoryBytes"] = .number(Double(totals.memoryByteSeconds) / covered, 0)
            entry["peakMemoryBytes"] = .bytes(totals.peakMemoryBytes)
            entry["wakeups"] = .int(Int(clamping: totals.wakeups))
            return entry.value
        })
        return object.value
    }

    // MARK: - get_status

    struct StatusInputs {
        var snapshot: Snapshot
        var hasSample: Bool
        var samplingInterval: TimeInterval
        var samplingPaused: Bool
        var leaseRemaining: TimeInterval?
        /// When the current lease began. A call that finds the app idle
        /// starts one, so a lease begun moments ago means nothing was held
        /// before this call.
        var leaseStartedAt: Date?
        var detailedSamplingSince: Date?
        var messagesAnswered: Int
        var fineCoverage: (oldest: Date, newest: Date, samples: Int)?
        var minuteCoverage: (oldest: Date, newest: Date, minutes: Int)?
        var processTables: [ProcessSample]
        var runningSince: Date?
        var pid: Int32
        var executablePath: String
        var now: Date
    }

    static func status(_ inputs: StatusInputs) -> JSONValue {
        let snapshot = inputs.snapshot
        var app = JSONObject()
        app["name"] = .string(MCPIdentity.title)
        app["version"] = .string(MCPIdentity.version)
        app["build"] = nonEmpty(MCPIdentity.build)
        app["pid"] = .int(Int(inputs.pid))
        app["executablePath"] = .string(inputs.executablePath)
        if let since = inputs.runningSince { app["runningSince"] = .time(since) }

        var agent = JSONObject()
        agent["serverName"] = .string(MCPIdentity.serverName)
        agent["leaseActive"] = .bool(inputs.leaseRemaining != nil)
        agent["leaseRemainingSeconds"] = .number(inputs.leaseRemaining, 0)
        if let started = inputs.leaseStartedAt { agent["leaseStartedAt"] = .time(started) }
        agent["detailedSampling"] = .bool(inputs.detailedSamplingSince != nil)
        if let since = inputs.detailedSamplingSince { agent["detailedSamplingSince"] = .time(since) }
        // Port messages since launch, retries included.
        agent["messagesAnswered"] = .int(inputs.messagesAnswered)

        var sampling = JSONObject()
        sampling["intervalSeconds"] = .number(inputs.samplingInterval, 2)
        // Paused while the display sleeps and no agent is asking.
        sampling["paused"] = .bool(inputs.samplingPaused)
        if inputs.hasSample {
            sampling["lastSampleAt"] = .time(snapshot.timestamp)
            sampling["ageSeconds"] = .number(max(0, inputs.now.timeIntervalSince(snapshot.timestamp)), 1)
        }

        var sources = JSONObject()
        if inputs.hasSample {
            sources["gpuUtilization"] = .bool(snapshot.gpu.available)
            sources["temperatureSensors"] = .bool(!snapshot.thermal.sensors.isEmpty)
            sources["fans"] = .bool(!snapshot.thermal.fans.isEmpty)
            sources["power"] = .bool(snapshot.power.hasAny)
            sources["cpuClocks"] = .bool(snapshot.cpu.performanceClockMHz != nil)
            sources["perProcessGPU"] = .bool(snapshot.processes.gpuAttributionAvailable)
            sources["battery"] = .bool(snapshot.battery.present)
        }

        var history = JSONObject()
        var perSample = JSONObject()
        perSample["capacity"] = .int(MetricsHistory.capacity)
        perSample["resolutionSeconds"] = .number(inputs.samplingInterval, 2)
        perSample["samples"] = .int(inputs.fineCoverage?.samples ?? 0)
        if let coverage = inputs.fineCoverage {
            perSample["from"] = .time(coverage.oldest)
            perSample["to"] = .time(coverage.newest)
        }
        history["vitalsPerSample"] = perSample.value
        var perMinute = JSONObject()
        perMinute["capacityMinutes"] = .int(MinuteHistory.capacity)
        perMinute["minutes"] = .int(inputs.minuteCoverage?.minutes ?? 0)
        if let coverage = inputs.minuteCoverage {
            perMinute["from"] = .time(coverage.oldest)
            perMinute["to"] = .time(coverage.newest.addingTimeInterval(MinuteHistory.bucketWidth))
        }
        history["vitalsPerMinute"] = perMinute.value
        var tables = JSONObject()
        // The same depth as the graph rings (`ProcessHistory.capacity`).
        tables["capacity"] = .int(MetricsHistory.capacity)
        tables["tables"] = .int(inputs.processTables.count)
        if let first = inputs.processTables.first, let last = inputs.processTables.last {
            tables["from"] = .time(first.timestamp)
            tables["to"] = .time(last.timestamp)
        }
        history["processTables"] = tables.value
        var usage = JSONObject()
        usage["retentionSeconds"] = .int(Int(UsageLedger.bucketWidth) * UsageLedger.bucketCount)
        if let since = inputs.runningSince {
            usage["since"] = .time(max(since, inputs.now.addingTimeInterval(-MCPRequest.longestWindow)))
        }
        history["appUsage"] = usage.value

        var object = JSONObject()
        object["app"] = app.value
        object["agentAccess"] = agent.value
        object["sampling"] = sampling.value
        object["mac"] = host(snapshot.host, now: inputs.now)
        if !sources.isEmpty { object["sources"] = sources.value }
        object["history"] = history.value
        return object.value
    }
}
