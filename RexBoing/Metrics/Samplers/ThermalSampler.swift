import Foundation

/// Temperatures and fans.
///
/// The SMC is the primary source because its key namespace is canonical and
/// unambiguous: on Apple silicon `Tp**` are the CPU core sensors, `Tg**` the
/// GPU, `Te**` the efficiency cluster, `Tm**` memory. That beats guessing from
/// the HID sensor product names, which are chip-specific and thermally coupled
/// enough that a GPU load visibly warms the "CPU" probes.
///
/// `HIDSensorReader` stays as a fallback for machines where the SMC user client
/// is unavailable, so the thermal card is never simply empty.
final class ThermalSampler {
    private let smc = SMCService()
    /// Resolved at construction — on the main thread, before the sampler queue
    /// exists — not lazily: lazy storage is not atomic, and this once had a
    /// second reader on the UI side.
    private let hid: HIDSensorReader?

    init() {
        hid = smc == nil ? HIDSensorReader() : nil
    }

    /// Discovered once — enumerating the SMC key index costs ~400ms.
    private var temperatureKeys: [String] = []
    private var essentialKeys: [String] = []
    private var didDiscover = false

    /// The full sensor set, values updated in place as readings come in.
    private var cachedSensors: [TempSensor] = []
    /// Position of each key in `cachedSensors`, so a partial refresh can patch
    /// the array without rebuilding or searching it.
    private var sensorIndex: [String: Int] = [:]
    /// Keys carrying a reading from the most recent pass. Aggregates are taken
    /// over these only — averaging a fresh handful together with a stale
    /// majority is what made the headline temperature lag reality by minutes.
    private var freshKeys: Set<String> = []
    private var cachedGroups: [SensorGroup] = []
    private var cachedFans: [Fan] = []
    private var lastFullRefreshUptime: TimeInterval?
    private var lastEssentialRefreshUptime: TimeInterval?
    /// Hottest reading from the last pass that covered every sensor.
    private var lastCompletePeak: Double?
    /// SoC and storage aggregates from the last pass that produced them. The
    /// essential keys cover neither category, so without a carried value these
    /// flapped value → nil → value between full passes — three of every five
    /// seconds at the fast refresh rate.
    private var lastCompleteSoc: Double?
    private var lastCompleteStorage: Double?

    /// A full pass is ~190 individual `IOConnectCallStructMethod` round trips
    /// and costs ~45ms — far too much to spend every tick for a menu bar that
    /// only needs two numbers.
    ///
    /// The two cadences are set by what is actually on screen. The headline
    /// CPU/GPU/battery figures come from the essential keys and move on a
    /// human timescale, so they refresh with the panel. The full set only
    /// backs the peak reading and the collapsed-by-default sensor list, and
    /// die temperatures do not change meaningfully inside five seconds — this
    /// pass was the single largest cost of having the dashboard open.
    private let fullRefreshInterval: TimeInterval = 5.0
    private let essentialRefreshInterval: TimeInterval = 2.0

    /// How many CPU sensors the headline average samples when the dashboard is
    /// closed. An M1 Pro exposes 33 of them and they track each other within a
    /// couple of degrees, so averaging a spread of six gives the same number
    /// for a fifth of the IOKit traffic.
    private static let essentialCPUSensorLimit = 6

    /// The engine calls this after sleep or a clock discontinuity so the next
    /// pass refreshes values immediately instead of waiting for uptime-based
    /// cadence clocks that did not advance while the machine slept.
    func invalidateCadence() {
        lastFullRefreshUptime = nil
        lastEssentialRefreshUptime = nil
    }

    func sample(detailed: Bool) -> ThermalMetrics {
        discoverIfNeeded()

        var metrics = ThermalMetrics()
        metrics.thermalState = ProcessInfo.processInfo.thermalState

        let uptime = ProcessInfo.processInfo.systemUptime
        if detailed,
           Cadence.isDue(lastFullRefreshUptime, every: fullRefreshInterval, at: uptime) {
            apply(readSensors(keys: temperatureKeys), complete: true)
            cachedFans = smc?.fans() ?? []
            lastFullRefreshUptime = uptime
            lastEssentialRefreshUptime = uptime
        } else if Cadence.isDue(
            lastEssentialRefreshUptime, every: essentialRefreshInterval, at: uptime) {
            apply(readSensors(keys: essentialKeys), complete: false)
            lastEssentialRefreshUptime = uptime
        }

        metrics.sensors = cachedSensors
        metrics.groups = cachedGroups
        metrics.fans = cachedFans

        let aggregates = freshAggregates()
        metrics.cpuCelsius = aggregates.cpu
        metrics.gpuCelsius = aggregates.gpu
        metrics.batteryCelsius = aggregates.battery

        // SoC, storage and the peak are properties of the *whole* sensor set,
        // so they are carried over from the last pass that produced them rather
        // than recomputed from whichever handful of keys was read most recently
        // — otherwise they visibly oscillated (the peak between the true value
        // and the essential sensors' peak, SoC and storage between a reading
        // and nothing) every couple of seconds. A fresh reading still wins
        // immediately. The carry lapses once full passes stop being recent —
        // the dashboard has closed and nothing is refreshing the full set — or
        // a peak from one busy afternoon would be reported all night.
        if let soc = aggregates.soc { lastCompleteSoc = soc }
        if let storage = aggregates.storage { lastCompleteStorage = storage }
        let carriedStillFresh = lastFullRefreshUptime.map {
            uptime - $0 < fullRefreshInterval * 3
        } ?? false
        metrics.socCelsius = aggregates.soc
            ?? (carriedStillFresh ? lastCompleteSoc : nil)
        metrics.storageCelsius = aggregates.storage
            ?? (carriedStillFresh ? lastCompleteStorage : nil)
        metrics.peakCelsius = carriedStillFresh
            ? [lastCompletePeak, aggregates.peak].compactMap { $0 }.max()
            : aggregates.peak

        if metrics.cpuCelsius == nil { metrics.cpuCelsius = metrics.socCelsius }

        return metrics
    }

    /// Merges a pass of readings into the cached set.
    ///
    /// A partial pass patches the values it covers and leaves the rest of the
    /// list in place, so the expandable sensor list keeps its full contents
    /// while the menu bar is running off a handful of keys. `freshKeys` records
    /// which entries the aggregates are allowed to look at.
    private func apply(_ readings: [TempSensor], complete: Bool) {
        guard !readings.isEmpty else {
            // A failed pass must not keep advertising the preceding pass as
            // fresh forever. If the full source disappeared, clear the cached
            // list too so diagnostics do not claim the sensors are available.
            freshKeys.removeAll(keepingCapacity: true)
            if complete {
                cachedSensors.removeAll(keepingCapacity: true)
                sensorIndex.removeAll(keepingCapacity: true)
                cachedGroups.removeAll(keepingCapacity: true)
                lastCompletePeak = nil
                lastCompleteSoc = nil
                lastCompleteStorage = nil
            }
            return
        }

        // A malformed SMC index can repeat a key. Besides weighting that probe
        // twice in an average, duplicate `Identifiable` ids make SwiftUI's
        // sensor grid behaviour undefined. Preserve the first reading and
        // make the cache genuinely key-unique.
        var seen = Set<String>()
        let uniqueReadings = readings.filter { seen.insert($0.key).inserted }

        if complete || cachedSensors.isEmpty {
            cachedSensors = uniqueReadings
            sensorIndex = Dictionary(
                uniqueKeysWithValues: uniqueReadings.enumerated().map { ($1.key, $0) })
            // Grouping follows full passes only. It feeds the expandable sensor
            // list, which is reachable only while the dashboard is open — and
            // that is exactly the state where a full pass runs every five
            // seconds, so the list is never staler than the card around it.
            cachedGroups = Self.group(uniqueReadings)
        } else {
            for reading in uniqueReadings {
                if let index = sensorIndex[reading.key] {
                    cachedSensors[index].celsius = reading.celsius
                } else {
                    // A sensor that was powered down during the last full pass
                    // and has since come back.
                    sensorIndex[reading.key] = cachedSensors.count
                    cachedSensors.append(reading)
                }
            }
        }

        freshKeys = Set(uniqueReadings.map(\.key))
        if complete || cachedSensors.count == uniqueReadings.count {
            lastCompletePeak = uniqueReadings.map(\.celsius).max()
        }
    }

    private static func group(_ sensors: [TempSensor]) -> [SensorGroup] {
        Dictionary(grouping: sensors, by: \.category)
            .map { SensorGroup(category: $0.key, sensors: $0.value.sorted { $0.celsius > $1.celsius }) }
            .sorted { $0.category.sortOrder < $1.category.sortOrder }
    }

    // MARK: - Discovery

    private func discoverIfNeeded() {
        guard !didDiscover else { return }
        didDiscover = true

        guard let smc else {
            // HID fallback: names differ entirely, so classify those separately.
            temperatureKeys = []
            essentialKeys = []
            apply(readSensors(keys: []), complete: true)
            // Dated like the SMC path below, or the first `sample` would
            // immediately repeat the full pass this just did.
            let uptime = ProcessInfo.processInfo.systemUptime
            lastFullRefreshUptime = uptime
            lastEssentialRefreshUptime = uptime
            return
        }

        let discovered = smc.discoverTemperatures()
        temperatureKeys = discovered.map(\.key)

        func keys(_ category: SensorCategory) -> [String] {
            temperatureKeys.filter { Self.category(for: $0) == category }
        }

        let cpuKeys = keys(.cpu)
        essentialKeys = Self.spread(cpuKeys, limit: Self.essentialCPUSensorLimit)
            + Self.spread(keys(.gpu), limit: 4)
            + keys(.battery)
        // On a Mac whose key space carries no `Tp`/`Te` sensors, everything
        // lands in SoC and that is what the CPU readout falls back to — but the
        // bucket is a catch-all and can run to a hundred keys, so it is sampled
        // rather than read whole.
        if cpuKeys.isEmpty {
            essentialKeys += Self.spread(keys(.soc), limit: Self.essentialCPUSensorLimit)
        }

        // Discovery already read every candidate in order to validate it, so
        // reuse that pass. Re-reading the same ~190 keys here added another
        // full set of IOKit round trips to the app's first telemetry sample.
        apply(discovered.map { key, celsius in
            let category = Self.category(for: key)
            return TempSensor(
                key: key, label: Self.label(for: key, category: category),
                celsius: celsius, category: category)
        }, complete: true)
        cachedFans = smc.fans()
        let uptime = ProcessInfo.processInfo.systemUptime
        lastFullRefreshUptime = uptime
        lastEssentialRefreshUptime = uptime
    }

    /// An evenly spaced subset, so a sampled cluster still covers its whole
    /// range rather than just the first few keys in index order.
    private static func spread(_ keys: [String], limit: Int) -> [String] {
        guard keys.count > limit, limit > 0 else { return keys }
        let step = Double(keys.count) / Double(limit)
        return (0..<limit).map { keys[min(keys.count - 1, Int(Double($0) * step))] }
    }

    private func readSensors(keys: [String]) -> [TempSensor] {
        guard let smc else {
            return (hid?.read() ?? []).compactMap(Self.classifyHID)
        }
        return keys.compactMap { key in
            guard let celsius = smc.temperature(key: key) else { return nil }
            let category = Self.category(for: key)
            return TempSensor(
                key: key, label: Self.label(for: key, category: category),
                celsius: celsius, category: category)
        }
    }

    // MARK: - Classification

    /// SMC key prefixes, which are architecture-specific.
    ///
    /// Case is significant. Apple silicon uses a lowercase second character for
    /// the functional-unit sensors (`Tp09` CPU core, `Tg0D` GPU, `Te02`
    /// efficiency cluster, `Tm05` memory) and reuses the uppercase Intel-style
    /// prefixes for unrelated things — `TCMz` on an M1 Pro is not a CPU die
    /// sensor, and letting the Intel rule catch it drags the CPU average up by
    /// several degrees. So the two key spaces are kept strictly apart.
    private static let isAppleSilicon = HostInfo.current.isAppleSilicon

    private static func category(for key: String) -> SensorCategory {
        guard key.count >= 2 else { return .other }
        let prefix = String(key.prefix(2))

        if isAppleSilicon {
            switch prefix {
            case "Tp", "Te": return .cpu      // Performance / efficiency clusters
            case "Tg": return .gpu
            case "Tm": return .memory         // Memory controller
            case "TB": return .battery
            case "TH": return .storage        // NAND
            case "Ts": return .ambient        // Enclosure skin
            case "Ta": return .ambient        // Airflow
            case "TV", "TP": return .power    // Rails and PMU
            default: return .soc
            }
        }

        switch prefix {
        case "TC": return .cpu                // Intel CPU package / die
        case "TG": return .gpu
        case "TB": return .battery
        case "TA": return .ambient
        case "TS", "Ts": return .ambient
        case "TH", "TN": return .storage
        case "Tm", "TM": return .memory
        case "TP", "TV": return .power
        default: return .soc
        }
    }

    private static func label(for key: String, category: SensorCategory) -> String {
        switch category {
        case .cpu: return key.hasPrefix("Te") ? "\(key) · E-cluster" : "\(key) · CPU"
        case .gpu: return "\(key) · GPU"
        case .memory: return "\(key) · Memory"
        case .battery: return "\(key) · Battery"
        case .ambient: return "\(key) · Enclosure"
        case .storage: return "\(key) · Storage"
        case .power: return "\(key) · Power"
        default: return key
        }
    }

    /// Fallback path: HID sensors are named rather than keyed.
    private static func classifyHID(key: String, celsius: Double) -> TempSensor? {
        let normalized = key.replacingOccurrences(of: "PMU ", with: "")
        let lower = normalized.lowercased()

        // The SMC's internal calibration reference, not a place on the die.
        if lower.hasPrefix("tcal") { return nil }

        let category: SensorCategory
        if lower.hasPrefix("tdie") || lower.hasPrefix("tdev") || lower.hasPrefix("tp") {
            category = .soc
        } else if lower.contains("nand") || lower.contains("ssd") {
            category = .storage
        } else if lower.contains("battery") || lower.contains("gas gauge") {
            category = .battery
        } else if lower.contains("gpu") {
            category = .gpu
        } else if lower.contains("cpu") {
            category = .cpu
        } else {
            category = .other
        }

        return TempSensor(key: key, label: normalized, celsius: celsius, category: category)
    }

    // MARK: - Aggregates

    /// Computes all headline figures in one pass and without temporary arrays.
    /// This runs on every engine tick even though sensor I/O runs less often.
    private func freshAggregates() -> (
        cpu: Double?, gpu: Double?, soc: Double?, battery: Double?,
        storage: Double?, peak: Double?
    ) {
        var cpuSum = 0.0, cpuCount = 0
        var gpuSum = 0.0, gpuCount = 0
        var batterySum = 0.0, batteryCount = 0
        var soc: Double?
        var storage: Double?
        var peak: Double?

        for sensor in cachedSensors where freshKeys.contains(sensor.key) {
            peak = max(peak ?? sensor.celsius, sensor.celsius)
            switch sensor.category {
            case .cpu:
                cpuSum += sensor.celsius
                cpuCount += 1
            case .gpu:
                gpuSum += sensor.celsius
                gpuCount += 1
            case .battery:
                batterySum += sensor.celsius
                batteryCount += 1
            case .soc:
                soc = max(soc ?? sensor.celsius, sensor.celsius)
            case .storage:
                storage = max(storage ?? sensor.celsius, sensor.celsius)
            default:
                break
            }
        }

        return (
            cpuCount > 0 ? cpuSum / Double(cpuCount) : nil,
            gpuCount > 0 ? gpuSum / Double(gpuCount) : nil,
            soc,
            batteryCount > 0 ? batterySum / Double(batteryCount) : nil,
            storage,
            peak)
    }
}

extension ProcessInfo.ThermalState {
    var label: String {
        switch self {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    /// 0...1, for driving the colour ramp on the thermal gauge.
    var severity: Double {
        switch self {
        case .nominal: return 0
        case .fair: return 0.4
        case .serious: return 0.75
        case .critical: return 1
        @unknown default: return 0
        }
    }
}
