import Foundation

/// One tool as `tools/list` describes it. Every tool here only reads: the
/// annotations say so, and nothing behind them changes the Mac or the app.
struct MCPTool: Sendable {
    var name: String
    var title: String
    var description: String
    /// Property name to its JSON Schema. The object schema around them is
    /// built here, closed to anything not listed.
    var properties: [(String, JSONValue)]
    var required: [String] = []

    var inputSchema: JSONValue {
        var schema: [String: JSONValue] = [
            "type": "object",
            "properties": .object(Dictionary(properties, uniquingKeysWith: { first, _ in first })),
            "additionalProperties": false,
        ]
        if !required.isEmpty { schema["required"] = .array(required.map(JSONValue.string)) }
        return .object(schema)
    }

    var listing: JSONValue {
        [
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": inputSchema,
            "annotations": [
                "title": .string(title),
                "readOnlyHint": true,
                "destructiveHint": false,
                "idempotentHint": true,
                "openWorldHint": false,
            ],
        ]
    }
}

// MARK: - Argument vocabularies

enum SnapshotSection: String, CaseIterable, Sendable {
    case host, cpu, gpu, memory, thermal, power, battery, network, disk, sleep
}

/// What a process ranking can be ordered by, in the words an agent would use.
enum ProcessSort: String, CaseIterable, Sendable {
    case cpu, memory, gpu, energy, disk

    var metric: ProcessMetric {
        switch self {
        case .cpu: return .cpu
        case .memory: return .memory
        case .gpu: return .gpu
        case .energy: return .energy
        case .disk: return .disk
        }
    }
}

enum UsageSort: String, CaseIterable, Sendable {
    case cpu, energy, gpu, disk, memory, wakeups
}

/// The series `get_history` can return, named with their units. Each is one
/// of the graph series the app keeps, at both resolutions.
enum HistorySeries: String, CaseIterable, Sendable {
    case cpuPercent
    case cpuUserPercent
    case cpuSystemPercent
    case gpuPercent
    case memoryUsedPercent
    case swapUsedPercent
    case cpuCelsius
    case gpuCelsius
    case powerWatts
    case efficiencyClockMHz
    case performanceClockMHz
    case networkReceiveBytesPerSecond
    case networkSendBytesPerSecond
    case diskReadBytesPerSecond
    case diskWriteBytesPerSecond

    var minuteSeries: MinuteHistory.Series {
        switch self {
        case .cpuPercent: return .cpu
        case .cpuUserPercent: return .cpuUser
        case .cpuSystemPercent: return .cpuSystem
        case .gpuPercent: return .gpu
        case .memoryUsedPercent: return .memory
        case .swapUsedPercent: return .swap
        case .cpuCelsius: return .cpuTemp
        case .gpuCelsius: return .gpuTemp
        case .powerWatts: return .power
        case .efficiencyClockMHz: return .eClock
        case .performanceClockMHz: return .pClock
        case .networkReceiveBytesPerSecond: return .networkRx
        case .networkSendBytesPerSecond: return .networkTx
        case .diskReadBytesPerSecond: return .diskRead
        case .diskWriteBytesPerSecond: return .diskWrite
        }
    }

    func ring(in history: MetricsHistory) -> RingBuffer {
        switch self {
        case .cpuPercent: return history.cpu
        case .cpuUserPercent: return history.cpuUser
        case .cpuSystemPercent: return history.cpuSystem
        case .gpuPercent: return history.gpu
        case .memoryUsedPercent: return history.memory
        case .swapUsedPercent: return history.swap
        case .cpuCelsius: return history.cpuTemp
        case .gpuCelsius: return history.gpuTemp
        case .powerWatts: return history.power
        case .efficiencyClockMHz: return history.eClock
        case .performanceClockMHz: return history.pClock
        case .networkReceiveBytesPerSecond: return history.networkRx
        case .networkSendBytesPerSecond: return history.networkTx
        case .diskReadBytesPerSecond: return history.diskRead
        case .diskWriteBytesPerSecond: return history.diskWrite
        }
    }

    /// The history keeps these as 0...1 fractions; they leave as percentages.
    var scale: Double {
        switch self {
        case .cpuPercent, .cpuUserPercent, .cpuSystemPercent, .gpuPercent,
             .memoryUsedPercent, .swapUsedPercent: return 100
        default: return 1
        }
    }

    var decimals: Int {
        switch self {
        case .powerWatts: return 2
        case .efficiencyClockMHz, .performanceClockMHz,
             .networkReceiveBytesPerSecond, .networkSendBytesPerSecond,
             .diskReadBytesPerSecond, .diskWriteBytesPerSecond: return 0
        default: return 1
        }
    }
}

// MARK: - Requests

/// A tool call, checked and normalised. The bridge parses it to answer bad
/// input without waking the app; the app parses the same arguments again
/// with the same code, because any process of this user can write to the
/// port and nothing it sends is trusted.
enum MCPRequest: Sendable, Equatable {
    case snapshot(sections: [SnapshotSection], allSensors: Bool)
    case processes(sortBy: ProcessSort, limit: Int)
    case history(series: [HistorySeries], from: Date, to: Date, points: Int)
    case processHistory(at: Date?, window: TimeInterval?, sortBy: ProcessSort, limit: Int)
    case appUsage(window: TimeInterval, sortBy: UsageSort, limit: Int)
    case status

    static let processLimit = (default: 10, cap: ProcessMetrics.leaderboardDepth)
    static let processHistoryLimit = (default: 10, cap: 40)
    static let usageLimit = (default: 10, cap: 50)
    static let historyPoints = (default: 60, cap: 240)
    /// Both day-long stores, the minute tier and the usage ledger, hold this.
    static let longestWindow: TimeInterval = 86_400

    static func parse(tool: String, arguments: [String: JSONValue], now: Date) -> Result<MCPRequest, MCPToolError> {
        guard let definition = MCPCatalog.tool(named: tool) else {
            return .failure(MCPToolError(
                .notFound, "There is no tool named \(tool). Call one of the candidates.",
                detail: ["candidates": MCPCatalog.candidateList(for: tool)]))
        }
        let known = Set(definition.properties.map(\.0))
        if let unknown = arguments.keys.sorted().first(where: { !known.contains($0) }) {
            let accepted = known.isEmpty ? "none" : known.sorted().joined(separator: ", ")
            return .failure(.badInput("\(tool) takes no argument named \(unknown). Accepted arguments: \(accepted)."))
        }
        let reader = ArgumentReader(arguments: arguments, now: now)
        do {
            switch tool {
            case "get_snapshot":
                let sections = try reader.list("sections", of: SnapshotSection.self) ?? SnapshotSection.allCases
                return .success(.snapshot(sections: sections, allSensors: try reader.bool("allSensors") ?? false))
            case "get_processes":
                return .success(.processes(
                    sortBy: try reader.choice("sortBy", of: ProcessSort.self) ?? .cpu,
                    limit: try reader.limit("limit", processLimit)))
            case "get_history":
                let window = try reader.window("window", within: 1...longestWindow) ?? 600
                let end = try reader.moment("end") ?? now
                guard end <= now.addingTimeInterval(60) else {
                    throw MCPToolError.badInput("end is in the future. Give a past moment, or leave it out to mean now.")
                }
                let series = try reader.list("series", of: HistorySeries.self) ?? HistorySeries.allCases
                let points = try reader.integer("points", in: 2...historyPoints.cap) ?? historyPoints.default
                return .success(.history(series: series, from: end.addingTimeInterval(-window), to: end, points: points))
            case "get_process_history":
                let at = try reader.moment("at")
                if let at, at > now.addingTimeInterval(60) {
                    throw MCPToolError.badInput("at is in the future. Give a past moment, or leave it out to mean the latest table.")
                }
                return .success(.processHistory(
                    at: at,
                    window: try reader.window("window", within: 1...longestWindow),
                    sortBy: try reader.choice("sortBy", of: ProcessSort.self) ?? .cpu,
                    limit: try reader.limit("limit", processHistoryLimit)))
            case "get_app_usage":
                return .success(.appUsage(
                    window: try reader.window("window", within: 60...longestWindow) ?? 3600,
                    sortBy: try reader.choice("sortBy", of: UsageSort.self) ?? .cpu,
                    limit: try reader.limit("limit", usageLimit)))
            case "get_status":
                return .success(.status)
            default:
                return .failure(MCPToolError(.internal, "\(tool) is listed but has no parser."))
            }
        } catch let error as MCPToolError {
            return .failure(error)
        } catch {
            return .failure(MCPToolError(.internal, "\(error)"))
        }
    }

    /// Whether answering needs a sample taken under the agent's lease: the
    /// live readings do; history is whatever was kept, and is answered at once.
    var needsFreshSample: Bool {
        switch self {
        case .snapshot, .processes, .status: return true
        case .history, .processHistory, .appUsage: return false
        }
    }
}

/// Reads typed arguments, throwing `bad_input` that names the accepted forms.
private struct ArgumentReader {
    var arguments: [String: JSONValue]
    var now: Date

    private func value(_ key: String) -> JSONValue? {
        guard let value = arguments[key], value != .null else { return nil }
        return value
    }

    func bool(_ key: String) throws -> Bool? {
        guard let value = value(key) else { return nil }
        guard let bool = value.boolValue else { throw MCPToolError.badInput("\(key) must be true or false.") }
        return bool
    }

    func integer(_ key: String, in range: ClosedRange<Int>) throws -> Int? {
        guard let value = value(key) else { return nil }
        guard let number = value.intValue ?? value.stringValue.flatMap({ Int($0) }), range.contains(number) else {
            throw MCPToolError.badInput("\(key) must be a whole number from \(range.lowerBound) to \(range.upperBound).")
        }
        return number
    }

    func limit(_ key: String, _ bounds: (default: Int, cap: Int)) throws -> Int {
        try integer(key, in: 1...bounds.cap) ?? bounds.default
    }

    func choice<T: RawRepresentable & CaseIterable>(_ key: String, of type: T.Type) throws -> T? where T.RawValue == String {
        guard let value = value(key) else { return nil }
        guard let text = value.stringValue, let choice = T(rawValue: text) else {
            throw MCPToolError.badInput("\(key) must be one of: \(T.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        return choice
    }

    func list<T: RawRepresentable & CaseIterable>(_ key: String, of type: T.Type) throws -> [T]? where T.RawValue == String {
        guard let value = value(key) else { return nil }
        let names = T.allCases.map(\.rawValue).joined(separator: ", ")
        // A lone name is what an agent means by a list of one.
        let items = value.arrayValue ?? [value]
        var result: [T] = []
        for item in items {
            guard let text = item.stringValue, let choice = T(rawValue: text) else {
                throw MCPToolError.badInput("\(key) must be a list drawn from: \(names).")
            }
            if !result.contains(where: { $0.rawValue == choice.rawValue }) { result.append(choice) }
        }
        guard !result.isEmpty else { throw MCPToolError.badInput("\(key) must name at least one of: \(names).") }
        return result
    }

    func window(_ key: String, within range: ClosedRange<TimeInterval>) throws -> TimeInterval? {
        guard let value = value(key) else { return nil }
        guard let seconds = MCPTime.duration(value) else {
            throw MCPToolError.badInput("\(key) must be a duration: a number of seconds or text like \"90s\", \"15m\", \"6h\", \"1d\" or \"1h30m\".")
        }
        guard range.contains(seconds) else {
            throw MCPToolError.badInput("\(key) must be from \(Self.spoken(range.lowerBound)) to \(Self.spoken(range.upperBound)).")
        }
        return seconds
    }

    func moment(_ key: String) throws -> Date? {
        guard let value = value(key) else { return nil }
        guard let date = MCPTime.moment(value, now: now) else {
            throw MCPToolError.badInput("\(key) must be a moment: ISO 8601 such as \"2026-11-19T14:05:00+09:00\" (without an offset it means this Mac's time), \"now\", or how long ago such as \"15m\" or \"2h\".")
        }
        return date
    }

    private static func spoken(_ seconds: TimeInterval) -> String {
        if seconds >= 3600, seconds.truncatingRemainder(dividingBy: 3600) == 0 { return "\(Int(seconds / 3600))h" }
        if seconds >= 60, seconds.truncatingRemainder(dividingBy: 60) == 0 { return "\(Int(seconds / 60))m" }
        return "\(Int(seconds))s"
    }
}

// MARK: - Catalog

enum MCPCatalog {
    static func tool(named name: String) -> MCPTool? {
        tools.first { $0.name == name }
    }

    /// Every tool, nearest names first: the list is short enough that all of
    /// it is the useful answer to a typo.
    static func candidates(for name: String) -> [String] {
        let lowered = Array(name.lowercased())
        let ranked = tools.map { ($0.name, editDistance(Array($0.name), lowered)) }
        return ranked.sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0 < $1.0 }.map(\.0)
    }

    /// Candidates as objects, nearest first, the shape every `not_found`
    /// shares with Rex Boing Remote's server.
    static func candidateList(for name: String) -> JSONValue {
        .array(candidates(for: name).compactMap { candidate in
            tool(named: candidate).map { ["name": .string($0.name), "title": .string($0.title)] }
        })
    }

    /// Levenshtein distance; the names are a few dozen characters at most.
    private static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return max(a.count, b.count) }
        var previous = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: b.count)
            for (j, y) in b.enumerated() {
                current[j + 1] = min(previous[j + 1] + 1, current[j] + 1, previous[j] + (x == y ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }

    private static func choice<T: RawRepresentable & CaseIterable>(_ type: T.Type, default value: T? = nil, _ description: String) -> JSONValue where T.RawValue == String {
        var schema: [String: JSONValue] = [
            "type": "string",
            "enum": .array(T.allCases.map { .string($0.rawValue) }),
            "description": .string(description),
        ]
        if let value { schema["default"] = .string(value.rawValue) }
        return .object(schema)
    }

    private static func list<T: RawRepresentable & CaseIterable>(_ type: T.Type, _ description: String) -> JSONValue where T.RawValue == String {
        [
            "type": "array",
            "items": ["type": "string", "enum": .array(T.allCases.map { .string($0.rawValue) })],
            "uniqueItems": true,
            "minItems": 1,
            "description": .string(description),
        ]
    }

    private static func limit(_ bounds: (default: Int, cap: Int), _ what: String) -> JSONValue {
        [
            "type": "integer",
            "minimum": 1,
            "maximum": .int(bounds.cap),
            "default": .int(bounds.default),
            "description": .string("How many \(what) to return, at most \(bounds.cap)."),
        ]
    }

    // Durations and moments are typed as strings, with numbers accepted as
    // well: several hosts translate MCP schemas for their model and reject a
    // union type, while every one of them passes a string through.
    private static func duration(_ description: String) -> JSONValue {
        ["type": "string", "description": .string(description + " Seconds, or text like \"90s\", \"15m\", \"6h\", \"1d\".")]
    }

    private static func moment(_ description: String) -> JSONValue {
        ["type": "string", "description": .string(description + " ISO 8601 (\"2026-11-19T14:05:00+09:00\"; without an offset it is this Mac's time), or how long ago (\"15m\", \"2h\").")]
    }

    static let tools: [MCPTool] = [
        MCPTool(
            name: "get_snapshot",
            title: "Current readings",
            description: """
            This Mac's readings right now: CPU (total, user and system, per core, per cluster with clocks, load average), GPU, memory (used, pressure, swap), thermals (CPU, GPU and peak temperatures, fans, every sensor by group), power (whole machine and per component), battery, network and disk throughput, the startup volume, uptime, model and macOS version, and which processes are keeping the Mac awake (section "sleep"). Ask for only the sections you need. For which processes are using what, call get_processes; for how readings moved over time, get_history.
            """,
            properties: [
                ("sections", list(SnapshotSection.self, "Which sections to return. All of them when left out.")),
                ("allSensors", ["type": "boolean", "default": false, "description": "Every temperature sensor instead of the three hottest per group (an M1 Pro has 186)."]),
            ]),
        MCPTool(
            name: "get_processes",
            title: "Top processes",
            description: """
            The processes using the most CPU, memory, GPU, energy or disk right now, ranked by sortBy, with pid, name, owning app, bundle identifier, executable path and start time, and all measures side by side: cpuPercent (percent of one core, so it can exceed 100), memoryBytes, gpuPercent, energyImpact (Rex Boing's score, about 100 mW per point) and energyWatts, disk read and write rates, wakeupsPerSecond and threads. Covers this user's processes, plus other users' processes that use the GPU such as WindowServer. For which apps did the most over a period, call get_app_usage; for a past moment, get_process_history.
            """,
            properties: [
                ("sortBy", choice(ProcessSort.self, default: .cpu, "The measure to rank by.")),
                ("limit", limit(MCPRequest.processLimit, "processes")),
            ]),
        MCPTool(
            name: "get_history",
            title: "Vitals history",
            description: """
            How the headline readings moved over a window: CPU (total, user, system), GPU, memory and swap used, CPU and GPU temperature, whole-machine power, cluster clocks, network and disk throughput. Each series comes back as at most `points` buckets (mean and peak each) with its min, mean and max over the window and when the extremes happened. The newest 600 samples (ten minutes at the default one-second refresh) are kept as they were taken, the last 24 hours per minute; the finer one answers whenever it covers the window. History starts when Rex Boing started, lives only in memory, and gaps (sleep, display asleep) are left empty rather than read as zero.
            """,
            properties: [
                ("window", duration("How far back from `end` to look, up to 24 hours. Defaults to 10 minutes.")),
                ("end", moment("Where the window ends. Defaults to now.")),
                ("series", list(HistorySeries.self, "Which series to return. All of them when left out.")),
                ("points", [
                    "type": "integer", "minimum": 2, "maximum": .int(MCPRequest.historyPoints.cap),
                    "default": .int(MCPRequest.historyPoints.default),
                    "description": "At most how many buckets per series.",
                ]),
            ]),
        MCPTool(
            name: "get_process_history",
            title: "What was running",
            description: """
            The ranked process tables Rex Boing kept, to answer what caused a spike. With `at` alone: the table nearest that moment (and how far from it), with the system totals at that instant. With `window`: every table in that span, centred on `at` or ending now, summarised per process as how many tables it placed in and its mean and peak for sortBy. Tables are kept about every six seconds, every sample while a dashboard or an agent is watching, for up to an hour; a process that did nothing measurable is not in them.
            """,
            properties: [
                ("at", moment("The moment to look at. Defaults to the latest table.")),
                ("window", duration("Summarise every table in this span instead of returning one.")),
                ("sortBy", choice(ProcessSort.self, default: .cpu, "The measure to rank by.")),
                ("limit", limit(MCPRequest.processHistoryLimit, "processes")),
            ]),
        MCPTool(
            name: "get_app_usage",
            title: "App usage over a window",
            description: """
            Which apps did the most work over the trailing window, from Rex Boing's usage ledger: CPU time and average percent of one core, energy in joules and average watts, GPU time, bytes read and written, average and peak memory, and wakeups. Helpers are folded into the app they belong to, so a browser's renderer processes count as the browser. Kept per minute for 24 hours, in memory, since Rex Boing started; coveredSeconds says how much of the window was actually observed.
            """,
            properties: [
                ("window", duration("The trailing window, from 1 minute to 24 hours. Defaults to 1 hour.")),
                ("sortBy", choice(UsageSort.self, default: .cpu, "The measure to rank by: total work for cpu, energy, gpu, disk and wakeups; the time-average for memory.")),
                ("limit", limit(MCPRequest.usageLimit, "apps")),
            ]),
        MCPTool(
            name: "get_status",
            title: "Rex Boing status",
            description: """
            Rex Boing itself: its version, the sampling interval, which data sources resolved on this Mac (GPU counters, temperature sensors, fans, power, CPU clocks, per-process GPU, battery), how far back each kind of history reaches right now, and whether an agent is keeping detailed sampling on. Call it when a reading you expected is missing, or before asking about the past.
            """,
            properties: []),
    ]
}
