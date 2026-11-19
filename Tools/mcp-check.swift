import Foundation

// The MCP layer without the app: the protocol against scripted lines, every
// tool's schema, the argument forms, payloads encoded from synthetic
// snapshots and histories held to the shared conventions (units in key
// names, missing-not-zero, finite numbers, ISO 8601 times, bounded lists),
// and the bridge's real relay over a real message port to a stand-in app
// (this executable run with --fake-app), under many simultaneous calls and
// through the stand-in quitting and coming back. Nothing here reads this
// machine's hardware.
//
// swiftc -O -o /tmp/mcp-check Tools/mcp-check.swift RexBoing/App/MCPJSON.swift \
//   RexBoing/App/MCPProtocol.swift RexBoing/App/MCPTools.swift RexBoing/App/MCPPayloads.swift \
//   RexBoing/App/MCPBridge.swift \
//   RexBoing/Metrics/Snapshot.swift RexBoing/Metrics/Wire.swift RexBoing/Metrics/Format.swift \
//   RexBoing/Metrics/History.swift RexBoing/Metrics/MinuteHistory.swift \
//   RexBoing/Metrics/ProcessHistory.swift RexBoing/Metrics/UsageLedger.swift
@main
struct MCPCheck {
    nonisolated(unsafe) static var failures = 0

    static func check(_ condition: Bool, _ message: String) {
        print("\(condition ? "PASS" : "FAIL")  \(message)")
        if !condition { failures += 1 }
    }

    @MainActor static func main() {
        if let index = CommandLine.arguments.firstIndex(of: "--fake-app"), index + 1 < CommandLine.arguments.count {
            serveFakeApp(name: CommandLine.arguments[index + 1])
        }
        checkJSON()
        checkProtocol()
        checkSchemas()
        checkArguments()
        checkSnapshotPayloads()
        checkProcessPayloads()
        checkHistoryPayloads()
        checkProcessHistoryPayloads()
        checkUsagePayloads()
        checkStatusPayload()
        checkPortPath()
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - The port, for real

    /// Remembers when each slow request was first seen, so it can answer
    /// "retry" until its time is up, the way the app does while it waits
    /// for a fresh sample.
    final class FakeApp {
        var firstSeen: [Int: Date] = [:]
    }

    /// The stand-in app: answers on a message port from its main run loop,
    /// at once, as the real one does.
    static func serveFakeApp(name: String) -> Never {
        let app = FakeApp()
        var context = CFMessagePortContext(
            version: 0, info: Unmanaged.passUnretained(app).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        var shouldFree: DarwinBoolean = false
        let port = CFMessagePortCreateLocal(nil, name as CFString, { _, _, data, info in
            let app = Unmanaged<FakeApp>.fromOpaque(info!).takeUnretainedValue()
            let message = data.flatMap { try? JSONValue.parse($0 as Data) }
            let arguments = message?["arguments"]
            let id = arguments?["id"]?.intValue ?? -1
            let slow = arguments?["slowMs"]?.doubleValue ?? 0
            var answer: JSONValue = ["result": ["tool": message?["tool"] ?? .null, "id": .int(id), "pid": .int(Int(getpid()))]]
            if slow > 0 {
                let first = app.firstSeen[id] ?? Date()
                app.firstSeen[id] = first
                if Date().timeIntervalSince(first) * 1000 < slow { answer = ["retryAfterMs": 40] }
            }
            return Unmanaged.passRetained(answer.serialized() as CFData)
        }, &context, &shouldFree)
        guard let port else {
            print("no-port")
            fflush(stdout)
            exit(3)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMessagePortCreateRunLoopSource(nil, port, 0), .commonModes)
        print("ready")
        fflush(stdout)
        CFRunLoopRun()
        exit(0)
    }

    static func startFakeApp(_ name: String) -> Process? {
        for _ in 0..<10 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
            process.arguments = ["--fake-app", name]
            let pipe = Pipe()
            process.standardOutput = pipe
            guard (try? process.run()) != nil else { return nil }
            let line = String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self)
            if line.hasPrefix("ready") { return process }
            process.terminate()
            process.waitUntilExit()
            // The name can outlive its last owner for a moment.
            Thread.sleep(forTimeInterval: 0.2)
        }
        return nil
    }

    final class Box<Value>: @unchecked Sendable {
        let lock = NSLock()
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    static func checkPortPath() {
        let name = "com.rexyrex.Zoomies.mcp-check.\(getpid())"
        guard let app = startFakeApp(name) else {
            print("SKIP  the port path: this session has no bootstrap namespace to register a port in")
            return
        }
        let relay = MCPBridge.Relay(mayLaunch: false, portName: name, isEnabled: { true }, isAppRunning: { false })
        let queue = DispatchQueue(label: "mcp-check.burst", attributes: .concurrent)

        // Many calls at once, a quarter of them kept waiting by "retry".
        let rows = Box<[(slow: Bool, ok: Bool, seconds: Double)]>([])
        let group = DispatchGroup()
        for id in 0..<48 {
            let slow = id % 4 == 0
            queue.async(group: group) {
                let start = Date()
                let result = relay.perform(
                    tool: slow ? "get_history" : "get_status",
                    arguments: ["id": .int(id), "slowMs": .int(slow ? 600 : 0)]) { false }
                var ok = false
                if case .success(let value) = result { ok = value["id"] == .int(id) }
                rows.lock.lock()
                rows.value.append((slow, ok, Date().timeIntervalSince(start)))
                rows.lock.unlock()
            }
        }
        group.wait()
        let failed = rows.value.filter { !$0.ok }.count
        check(rows.value.count == 48 && failed == 0,
              "48 simultaneous calls through one relay all succeed, each with its own answer (\(failed) failed)")
        let slowestFast = rows.value.filter { !$0.slow }.map(\.seconds).max() ?? 99
        check(slowestFast < 0.5,
              "a call kept waiting holds up none of the others (slowest immediate answer \(Int(slowestFast * 1000)) ms)")
        check(rows.value.filter(\.slow).allSatisfy { $0.seconds >= 0.6 }, "a call told to retry waits it out")

        // The app quits with a call waiting on it.
        let inflight = Box<Result<JSONValue, MCPToolError>?>(nil)
        let done = DispatchSemaphore(value: 0)
        queue.async {
            inflight.value = relay.perform(tool: "get_history", arguments: ["id": 999, "slowMs": 10_000]) { false }
            done.signal()
        }
        Thread.sleep(forTimeInterval: 0.3)
        let firstPID = Int(app.processIdentifier)
        app.terminate()
        app.waitUntilExit()
        if done.wait(timeout: .now() + 5) == .success, case .failure(let error)? = inflight.value {
            check(error.code == .notRunning && error.message.contains("quit while answering"),
                  "a call in flight when the app quits gets not_running, promptly")
        } else {
            check(false, "a call in flight when the app quits gets not_running, promptly")
        }
        if case .failure(let error) = relay.perform(tool: "get_status", arguments: ["id": 1], isCancelled: { false }) {
            check(error.code == .notRunning, "a call while the app is gone is not_running")
        } else {
            check(false, "a call while the app is gone is not_running")
        }

        guard let restarted = startFakeApp(name) else {
            check(false, "the stand-in app comes back under the same name")
            return
        }
        if case .success(let value) = relay.perform(tool: "get_status", arguments: ["id": 2], isCancelled: { false }) {
            check(value["pid"] == .int(Int(restarted.processIdentifier)) && value["pid"] != .int(firstPID),
                  "the next call reaches the restarted app")
        } else {
            check(false, "the next call reaches the restarted app")
        }
        restarted.terminate()
        restarted.waitUntilExit()

        checkRelaunches(name + ".launch")
    }

    /// One bridge across several quits, each one soon after the bridge
    /// started the app: every quit must be followed by exactly one new start,
    /// shared by all the calls that find the app gone.
    static func checkRelaunches(_ name: String) {
        let current = Box<Process?>(nil)
        let launches = Box(0)
        let relay = MCPBridge.Relay(
            mayLaunch: true, portName: name, isEnabled: { true },
            isAppRunning: {
                current.lock.lock()
                defer { current.lock.unlock() }
                return current.value?.isRunning == true
            },
            launch: {
                launches.lock.lock()
                launches.value += 1
                launches.lock.unlock()
                // Returns once the stand-in answers on its port; the real
                // `open` returns sooner, and the relay waits for the port.
                let started = startFakeApp(name)
                current.lock.lock()
                current.value = started
                current.lock.unlock()
                return started != nil
            })
        let queue = DispatchQueue(label: "mcp-check.relaunch", attributes: .concurrent)
        for cycle in 0..<3 {
            let failures = Box(0)
            let group = DispatchGroup()
            let start = Date()
            for id in 0..<8 {
                queue.async(group: group) {
                    let result = relay.perform(tool: "get_status", arguments: ["id": .int(id)]) { false }
                    if case .success = result { return }
                    failures.lock.lock()
                    failures.value += 1
                    failures.lock.unlock()
                }
            }
            group.wait()
            let seconds = Date().timeIntervalSince(start)
            check(failures.value == 0 && seconds < 10,
                  "quit \(cycle) of one bridge's app: 8 calls succeed in \(String(format: "%.1f", seconds)) s (\(failures.value) failed)")
            current.lock.lock()
            let app = current.value
            current.lock.unlock()
            app?.terminate()
            app?.waitUntilExit()
        }
        check(launches.value == 3, "each quit is followed by exactly one start (\(launches.value) starts for 3 quits)")
    }

    // MARK: - Helpers

    static func reply(_ line: String) -> JSONValue? {
        if case .respond(let message) = MCPSession.handle(Data(line.utf8)) { return message }
        return nil
    }

    /// The JSON inside a tool result's one text block.
    static func toolPayload(_ response: JSONValue?) -> JSONValue? {
        guard let content = response?["result"]?["content"]?.arrayValue, content.count == 1,
              content[0]["type"] == "text", let text = content[0]["text"]?.stringValue else { return nil }
        return try? JSONValue.parse(text)
    }

    static let isoPattern = try! NSRegularExpression(
        pattern: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(Z|[+-]\d{2}:\d{2})$"#)

    static func isISO(_ value: JSONValue?) -> Bool {
        guard let text = value?.stringValue else { return false }
        return isoPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static let unitSuffixes = ["Percent", "Bytes", "BytesPerSecond", "PerSecond", "Celsius", "Watts", "RPM", "MHz", "Seconds", "Joules"]
    /// Counts, indices and scores: numbers whose key needs no unit.
    static let unitless: Set<String> = [
        "pid", "index", "count", "total", "samples", "tables", "tablesPlaced", "processCount", "threadCount",
        "threads", "coreCount", "physicalCores", "logicalCores", "performanceCores", "efficiencyCores",
        "cycleCount", "sensorCount", "oneMinute", "fiveMinutes", "fifteenMinutes", "energyImpact", "wakeups",
        "capacity", "capacityMinutes", "minutes", "messagesAnswered",
    ]
    /// Under these, a "Percent" is of one core and may pass 100.
    static let perCoreKeys: Set<String> = ["cpuPercent", "averageCpuPercent", "meanCpuPercent", "peakCpuPercent"]

    /// A key ending in its unit, or one that is the unit (`celsius`).
    static func hasUnit(_ key: String) -> Bool {
        unitSuffixes.contains { key.hasSuffix($0) || key == $0.lowercased() }
    }

    /// Walks a payload and reports every way it breaks the conventions.
    static func violations(_ value: JSONValue, path: String = "", key: String = "", inProcessRow: Bool = false) -> [String] {
        var found: [String] = []
        switch value {
        case .double(let number) where !number.isFinite:
            found.append("\(path) is not finite")
        case .int, .double:
            let number = value.doubleValue ?? 0
            let seriesStat = ["min", "mean", "max"].contains(key) && path.contains(".series.")
            if !seriesStat, !unitless.contains(key), !hasUnit(key) {
                found.append("\(path) carries no unit in its name")
            }
            if key.hasSuffix("Percent"), !(inProcessRow && perCoreKeys.contains(key)), !(0...100).contains(number) {
                found.append("\(path) = \(number) is not 0 to 100")
            }
        case .string:
            if key.hasSuffix("At") || ["from", "to", "since", "runningSince"].contains(key), !isISO(value) {
                found.append("\(path) is not ISO 8601 with an offset")
            }
        case .array(let items):
            for (index, item) in items.enumerated() {
                switch item {
                case .null where ["means", "peaks", "perCorePercent"].contains(key):
                    continue
                case .int, .double:
                    // Arrays of numbers inherit the unit of their key, or of
                    // the series they belong to.
                    let owner = ["means", "peaks"].contains(key) ? (path.split(separator: ".").dropLast().last.map(String.init) ?? key) : key
                    if !hasUnit(owner) {
                        found.append("\(path)[\(index)] carries no unit")
                    }
                    if !(item.doubleValue ?? 0).isFinite { found.append("\(path)[\(index)] is not finite") }
                    if owner.hasSuffix("Percent"), !(0...100).contains(item.doubleValue ?? 0) {
                        found.append("\(path)[\(index)] is not 0 to 100")
                    }
                case .string where key == "bucketStarts":
                    if !isISO(item) { found.append("\(path)[\(index)] is not ISO 8601") }
                default:
                    let rowList = ["processes", "apps", "blockers"].contains(key)
                    found += violations(item, path: "\(path)[\(index)]", key: key, inProcessRow: inProcessRow || rowList)
                }
            }
        case .object(let object):
            for (child, item) in object {
                found += violations(item, path: path + "." + child, key: child, inProcessRow: inProcessRow)
            }
        default:
            break
        }
        return found
    }

    static func conforms(_ value: JSONValue, _ what: String) {
        let problems = violations(value)
        check(problems.isEmpty, "\(what) follows the conventions" + (problems.isEmpty ? "" : ": " + problems.prefix(4).joined(separator: "; ")))
    }

    /// Every key anywhere in a payload, for missing-not-zero assertions.
    static func keys(_ value: JSONValue) -> Set<String> {
        switch value {
        case .object(let object):
            return object.reduce(into: Set(object.keys)) { $0.formUnion(keys($1.value)) }
        case .array(let items):
            return items.reduce(into: Set()) { $0.formUnion(keys($1)) }
        default:
            return []
        }
    }

    static func size(_ value: JSONValue) -> Int { value.serialized().count }

    // MARK: - JSON

    static func checkJSON() {
        let tree: JSONValue = ["text": "line\nbreak \"quoted\" \\ tab\t \u{1} \u{2028}", "n": 1.5, "i": 3, "b": true, "z": nil, "a": [1, "x"]]
        let compact = tree.serializedString()
        check(!compact.contains("\n") && !compact.contains("\u{2028}"), "compact JSON never contains a raw line break")
        check((try? JSONValue.parse(compact)) == tree, "JSON survives a round trip")
        check(JSONValue.double(.nan).serializedString() == "null" && JSONValue.number(.infinity, 1) == nil,
              "non-finite numbers are never written as numbers")
        check(JSONValue.number(-0.0001, 1) == .int(0), "rounding never writes -0")
        check(JSONValue.number(12.345, 1) == .double(12.3) && JSONValue.percent(0.4567) == .double(45.7),
              "readings round to their stated places")
    }

    // MARK: - Protocol

    static func checkProtocol() {
        let initialize = reply(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"check","version":"1"}}}"#)
        let result = initialize?["result"]
        check(result?["protocolVersion"] == "2025-06-18", "initialize echoes a supported protocol version")
        check(result?["capabilities"] == ["tools": [:]], "initialize declares tools only")
        check(result?["serverInfo"]?["name"] == "rex-boing" && result?["serverInfo"]?["version"]?.stringValue != nil,
              "initialize names the server rex-boing, with a version")
        check((result?["instructions"]?.stringValue?.count ?? 0) > 200, "initialize carries instructions")
        check(result?["resultType"] == nil, "a legacy answer has no modern fields")
        let newer = reply(#"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"2099-01-01"}}"#)
        check(newer?["result"]?["protocolVersion"] == "2025-11-25", "an unknown version is answered with the latest handshake version")

        if case .ignore = MCPSession.handle(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)) {
            check(true, "notifications/initialized gets no answer")
        } else { check(false, "notifications/initialized gets no answer") }
        if case .ignore = MCPSession.handle(Data(#"{"jsonrpc":"2.0","method":"notifications/whatever","params":{}}"#.utf8)) {
            check(true, "an unknown notification is ignored")
        } else { check(false, "an unknown notification is ignored") }
        if case .cancel(let id) = MCPSession.handle(Data(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":7}}"#.utf8)) {
            check(id == 7, "a cancellation names its request")
        } else { check(false, "a cancellation names its request") }
        if case .ignore = MCPSession.handle(Data(#"{"jsonrpc":"2.0","id":9,"result":{}}"#.utf8)) {
            check(true, "a response from the client is not answered")
        } else { check(false, "a response from the client is not answered") }

        let ping = reply(#"{"jsonrpc":"2.0","id":"p","method":"ping"}"#)
        check(ping == ["jsonrpc": "2.0", "id": "p", "result": [:]], "ping answers an empty result, nothing more")

        let list = reply(#"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#)
        let names = list?["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
        check(names == ["get_snapshot", "get_processes", "get_history", "get_process_history", "get_app_usage", "get_status"],
              "tools/list lists the six tools in a fixed order")
        check(reply(#"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#)?.serializedString() == list?.serializedString(),
              "tools/list is byte-for-byte deterministic")

        let meta = #""_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}"#
        let discover = reply(#"{"jsonrpc":"2.0","id":"d","method":"server/discover","params":{\#(meta)}}"#)?["result"]
        check(discover?["resultType"] == "complete"
              && discover?["supportedVersions"]?.arrayValue?.contains("2026-07-28") == true
              && discover?["supportedVersions"]?.arrayValue?.contains("2025-11-25") == true,
              "server/discover lists both eras' versions")
        check(discover?["_meta"]?["io.modelcontextprotocol/serverInfo"]?["name"] == "rex-boing" && discover?["ttlMs"] != nil,
              "server/discover identifies the server and is cacheable")
        let modernList = reply(#"{"jsonrpc":"2.0","id":4,"method":"tools/list","params":{\#(meta)}}"#)?["result"]
        check(modernList?["resultType"] == "complete" && modernList?["ttlMs"] != nil && modernList?["cacheScope"] == "private"
              && modernList?["_meta"]?["io.modelcontextprotocol/serverInfo"] != nil,
              "a modern tools/list carries resultType, caching and serverInfo")
        let unsupported = reply(#"{"jsonrpc":"2.0","id":5,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"1900-01-01","io.modelcontextprotocol/clientCapabilities":{}}}}"#)
        check(unsupported?["error"]?["code"] == .int(-32022)
              && unsupported?["error"]?["data"]?["requested"] == "1900-01-01"
              && unsupported?["error"]?["data"]?["supported"]?.arrayValue?.isEmpty == false,
              "an unsupported per-request version is UnsupportedProtocolVersionError with the supported list")
        let noCapabilities = reply(#"{"jsonrpc":"2.0","id":6,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}"#)
        check(noCapabilities?["error"]?["code"] == .int(-32602), "a modern request without clientCapabilities is invalid params")

        check(reply(#"{"jsonrpc":"2.0","id":7,"method":"resources/list"}"#)?["error"]?["code"] == .int(-32601),
              "an unknown method is -32601")
        let malformed = reply("{not json")
        check(malformed?["error"]?["code"] == .int(-32700) && malformed?["id"] == .null, "a malformed line is a parse error, and the stream survives it")
        check(reply("[1,2]")?["error"]?["code"] == .int(-32600), "a batch is an invalid request")
        check(reply(#"{"jsonrpc":"2.0","id":null,"method":"ping"}"#)?["error"]?["code"] == .int(-32600), "a null id is an invalid request")
        check(reply(#"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"get_status","arguments":[1]}}"#)?["error"]?["code"] == .int(-32602),
              "arguments that are not an object are invalid params")

        let unknownTool = reply(#"{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"get_snapshots","arguments":{}}}"#)
        check(unknownTool?["error"]?["code"] == .int(-32602)
              && unknownTool?["error"]?["data"]?["candidates"]?.arrayValue?.first?["name"] == "get_snapshot",
              "an unknown tool is a -32602 protocol error, nearest candidate first")
        if case .failure(let error) = MCPRequest.parse(tool: "get_snapshots", arguments: [:], now: Date()) {
            check(error.code == .notFound && error.detail["candidates"]?.arrayValue?.first?["title"] == "Current readings",
                  "the parser's not_found carries candidates as objects")
        } else { check(false, "the parser's not_found carries candidates as objects") }
        let badLimit = toolPayload(reply(#"{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"get_processes","arguments":{"limit":0}}}"#))
        check(badLimit?["error"]?["code"] == "bad_input" && badLimit?["error"]?["message"]?.stringValue?.contains("1 to 20") == true,
              "an out-of-range limit is bad_input naming the range")
        check(reply(#"{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"get_processes","arguments":{"limit":0}}}"#)?["result"]?["isError"] == true,
              "tool errors are results with isError")
        let extra = toolPayload(reply(#"{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"get_status","arguments":{"verbose":true}}}"#))
        check(extra?["error"]?["code"] == "bad_input", "an argument the schema does not list is bad_input")
        if case .call(let call) = MCPSession.handle(Data(#"{"jsonrpc":"2.0","id":13,"method":"tools/call","params":{"name":"get_history","arguments":{"window":"15m"},\#(meta)}}"#.utf8)) {
            check(call.name == "get_history" && call.modern && call.arguments["window"] == "15m", "a valid call is handed to the relay")
            let answer = MCPSession.response(to: call, result: .success(["ok": true]))
            check(answer["result"]?["isError"] == nil && toolPayload(answer) == ["ok": true] && answer["result"]?["resultType"] == "complete",
                  "a modern call's answer is one text block of JSON with resultType")
            let failure = MCPSession.response(to: call, result: .failure(MCPToolError(.notRunning, "Open it.")))
            check(failure["result"]?["isError"] == true && toolPayload(failure)?["error"] == ["code": "not_running", "message": "Open it."],
                  "a relay failure becomes an isError result with code and message")
            check(MCPToolError(json: MCPToolError(.disabled, "x", detail: ["a": 1]).json) == MCPToolError(.disabled, "x", detail: ["a": 1]),
                  "tool errors survive the port in both directions")
        } else {
            check(false, "a valid call is handed to the relay")
        }
    }

    // MARK: - Schemas

    static func checkSchemas() {
        var names = Set<String>()
        for tool in MCPCatalog.tools {
            check(names.insert(tool.name).inserted, "\(tool.name) is listed once")
            check(tool.name.range(of: #"^get_[a-z]+(_[a-z]+)*$"#, options: .regularExpression) != nil,
                  "\(tool.name) is short snake_case, verb first")
            check(tool.description.count > 120 && tool.description.count < 1200 && !tool.description.contains("\u{2014}"),
                  "\(tool.name) has a description an agent can choose by")
            let listing = tool.listing
            check(listing["annotations"]?["readOnlyHint"] == true && listing["annotations"]?["destructiveHint"] == false
                  && listing["annotations"]?["openWorldHint"] == false,
                  "\(tool.name) is annotated read-only")
            let schema = tool.inputSchema
            check(schema["type"] == "object" && schema["additionalProperties"] == false && schema["properties"]?.objectValue != nil,
                  "\(tool.name) has a closed object schema")
            let properties = schema["properties"]?.objectValue ?? [:]
            let required = schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
            check(required.allSatisfy { properties[$0] != nil }, "\(tool.name) requires only properties it has")
            var defaults: [String: JSONValue] = [:]
            for (name, property) in properties {
                let type = property["type"]?.stringValue ?? ""
                var valid = ["string", "integer", "boolean", "array"].contains(type)
                    && (property["description"]?.stringValue?.isEmpty == false)
                if let options = property["enum"]?.arrayValue {
                    valid = valid && !options.isEmpty && Set(options.compactMap(\.stringValue)).count == options.count
                }
                if type == "integer" {
                    let low = property["minimum"]?.intValue ?? .min, high = property["maximum"]?.intValue ?? .max
                    valid = valid && low <= high && (property["default"]?.intValue.map { (low...high).contains($0) } ?? true)
                }
                if type == "array" {
                    valid = valid && property["items"]?["type"] == "string" && property["items"]?["enum"]?.arrayValue?.isEmpty == false
                }
                check(valid, "\(tool.name).\(name) is a complete schema")
                if let value = property["default"] { defaults[name] = value }
            }
            if case .failure(let error) = MCPRequest.parse(tool: tool.name, arguments: defaults, now: Date()) {
                check(false, "\(tool.name) accepts its own defaults: \(error.message)")
            } else {
                check(true, "\(tool.name) accepts its own defaults")
            }
            if case .failure = MCPRequest.parse(tool: tool.name, arguments: [:], now: Date()) {
                check(false, "\(tool.name) can be called with no arguments")
            }
        }
    }

    // MARK: - Arguments

    static func checkArguments() {
        let durations: [(JSONValue, TimeInterval?)] = [
            ("90s", 90), ("15m", 900), ("6h", 21_600), ("1d", 86_400), ("1h30m", 5400), (90, 90), ("90", 90),
            ("2 hours", 7200), ("15m ago", 900), ("abc", nil), ("-5m", nil), (0, nil), ("", nil), ("5x", nil),
        ]
        check(durations.allSatisfy { MCPTime.duration($0.0) == $0.1 }, "durations: seconds, 90s, 15m, 6h, 1d, 1h30m; nonsense rejected")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        check(MCPTime.moment("now", now: now) == now && MCPTime.moment("15m", now: now) == now.addingTimeInterval(-900)
              && MCPTime.moment(60, now: now) == now.addingTimeInterval(-60),
              "moments: now, and how long ago")
        check(MCPTime.moment("2026-11-19T14:05:00+09:00", now: now) == Date(timeIntervalSince1970: 1_795_064_700)
              && MCPTime.moment("2026-11-19T05:05:00Z", now: now) == Date(timeIntervalSince1970: 1_795_064_700)
              && MCPTime.moment("2026-11-19T05:05:00.250Z", now: now) == Date(timeIntervalSince1970: 1_795_064_700.25),
              "moments: ISO 8601 with an offset, Z, and fractions")
        var components = DateComponents(year: 2026, month: 11, day: 19, hour: 14, minute: 5)
        components.timeZone = .current
        let local = Calendar(identifier: .gregorian).date(from: components)
        check(MCPTime.moment("2026-11-19T14:05", now: now) == local && MCPTime.moment("2026-11-19 14:05:00", now: now) == local,
              "moments without an offset are this Mac's time")
        check(MCPTime.moment("yesterday-ish", now: now) == nil, "a moment that is neither ISO 8601 nor a duration is rejected")
        check(isISO(.string(MCPTime.iso(now))) && !MCPTime.iso(now).hasSuffix("Z") || TimeZone.current.secondsFromGMT() == 0,
              "times go out as ISO 8601 with the local offset")

        func parse(_ tool: String, _ arguments: [String: JSONValue]) -> Result<MCPRequest, MCPToolError> {
            MCPRequest.parse(tool: tool, arguments: arguments, now: now)
        }
        if case .failure(let error) = parse("get_history", ["window": "fortnight"]) {
            check(error.code == .badInput && error.message.contains("\"15m\""), "a bad window is bad_input naming the accepted forms")
        } else { check(false, "a bad window is bad_input naming the accepted forms") }
        if case .failure(let error) = parse("get_history", ["window": "2d"]) {
            check(error.code == .badInput && error.message.contains("24h"), "a window past a day is bad_input naming the limit")
        } else { check(false, "a window past a day is bad_input naming the limit") }
        if case .failure(let error) = parse("get_process_history", ["at": "Tuesday"]) {
            check(error.code == .badInput && error.message.contains("ISO 8601"), "a bad moment is bad_input naming the accepted forms")
        } else { check(false, "a bad moment is bad_input naming the accepted forms") }
        if case .failure = parse("get_history", ["end": "2099-01-01T00:00:00Z"]) {
            check(true, "a window ending in the future is rejected")
        } else { check(false, "a window ending in the future is rejected") }
        check(parse("get_history", ["window": "15m", "series": "cpuPercent", "points": 30])
              == .success(.history(series: [.cpuPercent], from: now.addingTimeInterval(-900), to: now, points: 30)),
              "a lone series name is a list of one")
        check(parse("get_snapshot", ["sections": ["cpu", "cpu", "sleep"]]) == .success(.snapshot(sections: [.cpu, .sleep], allSensors: false)),
              "repeated sections collapse")
        if case .failure = parse("get_snapshot", ["sections": []]) { check(true, "an empty section list is rejected") } else { check(false, "an empty section list is rejected") }
        if case .failure = parse("get_app_usage", ["sortBy": "joy"]) { check(true, "an unknown sortBy is rejected") } else { check(false, "an unknown sortBy is rejected") }
    }

    // MARK: - Synthetic machines

    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func row(_ pid: Int32, _ name: String, cpu: Double = 0, memory: UInt64 = 50_000_000, gpu: Double = 0,
                    energy: Double = 0, disk: Double = 0, path: String? = nil, threads: Int = 4) -> ProcessRow {
        ProcessRow(pid: pid, name: name, startTime: 1_799_000_000_000_000, bundleIdentifier: nil,
                   executablePath: path, cpuPercent: cpu, memoryBytes: memory, gpuPercent: gpu,
                   energyImpact: energy, diskReadBytesPerSecond: disk, diskWriteBytesPerSecond: disk / 2,
                   wakeupsPerSecond: 3, threadCount: threads)
    }

    static func richSnapshot() -> Snapshot {
        var snapshot = Snapshot()
        snapshot.timestamp = now.addingTimeInterval(-0.4)
        snapshot.interval = 1
        snapshot.host.modelName = "MacBook Pro"
        snapshot.host.modelIdentifier = "MacBookPro18,1"
        snapshot.host.chipName = "Apple M1 Pro"
        snapshot.host.osVersion = "27.2"
        snapshot.host.isAppleSilicon = true
        snapshot.host.logicalCores = 10
        snapshot.host.physicalCores = 10
        snapshot.host.efficiencyCores = 2
        snapshot.host.performanceCores = 8
        snapshot.host.memoryBytes = 32 << 30
        snapshot.host.bootTime = now.addingTimeInterval(-86_400 * 3)
        snapshot.cpu.total = 0.42
        snapshot.cpu.user = 0.3
        snapshot.cpu.system = 0.12
        snapshot.cpu.idle = 0.58
        snapshot.cpu.perCore = (0..<10).map { Double($0) / 10 }
        snapshot.cpu.coreKinds = [.efficiency, .efficiency] + Array(repeating: .performance, count: 8)
        snapshot.cpu.efficiencyLoad = 0.05
        snapshot.cpu.performanceLoad = 0.5
        snapshot.cpu.efficiencyClockMHz = 1700
        snapshot.cpu.performanceClockMHz = 3100
        snapshot.cpu.loadAverage = LoadAverage(one: 3.2, five: 2.5, fifteen: 2.0)
        snapshot.cpu.processCount = 700
        snapshot.cpu.threadCount = 3000
        snapshot.gpu = GPUMetrics(name: "Apple M1 Pro", coreCount: 16, utilization: 0.2, rendererUtilization: 0.18,
                                  tilerUtilization: 0.05, inUseMemory: 1 << 30, allocatedMemory: 2 << 30,
                                  totalMemory: 0, clockMHz: 900, available: true)
        snapshot.memory.total = 32 << 30
        snapshot.memory.used = 20 << 30
        snapshot.memory.app = 12 << 30
        snapshot.memory.wired = 4 << 30
        snapshot.memory.compressed = 4 << 30
        snapshot.memory.pressure = 0.3
        snapshot.memory.swap = SwapMetrics(total: 2 << 30, used: 1 << 30, free: 1 << 30, encrypted: true, ins: 0, outs: 0, inRate: 0, outRate: 4096)
        let categories: [SensorCategory] = [.cpu, .gpu, .soc, .memory, .battery]
        snapshot.thermal.sensors = (0..<200).map {
            TempSensor(key: "T\($0)", label: "Sensor \($0)", celsius: 30 + Double($0 % 40), category: categories[$0 % categories.count])
        }
        snapshot.thermal.sensors.append(TempSensor(key: "Tbad", label: "Broken", celsius: .nan, category: .cpu))
        snapshot.thermal.groups = SensorGroup.grouped(snapshot.thermal.sensors)
        snapshot.thermal.cpuCelsius = .nan // a source that answered nonsense
        snapshot.thermal.gpuCelsius = 48.25
        snapshot.thermal.peakCelsius = 69
        snapshot.thermal.fans = [Fan(index: 0, rpm: 1500, minRPM: 1200, maxRPM: 5800), Fan(index: 1, rpm: 1490, minRPM: 1200, maxRPM: 5800)]
        snapshot.power.systemTotalWatts = 21.5
        snapshot.power.cpuWatts = 4.2
        snapshot.power.gpuWatts = 1.1
        snapshot.power.aneWatts = 0
        snapshot.power.packageWatts = 6
        snapshot.power.adapterWatts = 96
        snapshot.battery = BatteryMetrics(present: true, percentage: 0.81, isCharging: true, isPluggedIn: true,
                                          timeRemainingMinutes: 45, cycleCount: 210, designCapacity: 6000, maxCapacity: 5400,
                                          celsius: 31, chargingWatts: 12, adapterWatts: 96)
        snapshot.network.rxBytesPerSecond = 125_000
        snapshot.network.txBytesPerSecond = 9000
        snapshot.network.primaryInterface = "en0"
        snapshot.disk.readBytesPerSecond = 1_000_000
        snapshot.disk.capacity = 1_000_000_000_000
        snapshot.disk.available = 400_000_000_000
        snapshot.sleep.sampled = true
        snapshot.sleep.blockers = (0..<25).map {
            SleepBlocker(pid: Int32(100 + $0), name: "app\($0)", preventsDisplaySleep: $0 == 0, preventsSystemSleep: true,
                         assertionNames: (0..<8).map { "assertion \($0)" })
        }
        var leaders: [ProcessMetric: [ProcessRow]] = [:]
        for metric in ProcessMetric.allCases {
            leaders[metric] = (0..<20).map { (index: Int) -> ProcessRow in
                let rank = Double(index)
                return row(Int32(1000 + index), "proc\(index)", cpu: 150 - rank, gpu: 20 - rank, energy: 30 - rank,
                           disk: 1000 * (20 - rank), path: "/Applications/Busy.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper")
            }
        }
        // Another user's GPU client: only its GPU share is readable.
        leaders[.gpu]?[19] = ProcessRow(pid: 88, name: "WindowServer", startTime: 0, gpuPercent: 7)
        snapshot.processes.leaders = leaders
        snapshot.processes.count = 700
        snapshot.processes.sampledAt = now.addingTimeInterval(-0.4)
        snapshot.processes.interval = 1
        snapshot.processes.gpuAttributionAvailable = true
        return snapshot
    }

    static func bareSnapshot() -> Snapshot {
        var snapshot = Snapshot()
        snapshot.timestamp = now.addingTimeInterval(-1)
        snapshot.host.osVersion = "14.6"
        snapshot.host.logicalCores = 4
        snapshot.host.bootTime = now.addingTimeInterval(-3600)
        snapshot.cpu.total = 0.1
        snapshot.cpu.perCore = [0.1, 0.1, 0.1, 0.1]
        snapshot.cpu.coreKinds = Array(repeating: .unknown, count: 4)
        snapshot.memory.total = 8 << 30
        snapshot.memory.used = 4 << 30
        return snapshot
    }

    // MARK: - get_snapshot

    static func checkSnapshotPayloads() {
        let broken: JSONValue = ["load": 0.5, "seenAt": "yesterday", "cpuPercent": 140, "x": ["fooBytes": .double(.nan)]]
        check(violations(broken).count == 4, "the convention walker catches a bare number, a bad time, a percent past 100 and NaN")
        let rich = MCPPayload.snapshot(richSnapshot(), sections: SnapshotSection.allCases, allSensors: false, now: now)
        conforms(rich, "a full snapshot")
        check(rich["unavailable"] == nil, "a Mac with every source lists nothing unavailable")
        check(rich["thermal"]?["cpuCelsius"] == nil && rich["thermal"]?["gpuCelsius"] == .double(48.3),
              "a non-finite reading is left out; finite ones are rounded")
        let groups = rich["thermal"]?["sensorGroups"]?.arrayValue ?? []
        check(groups.count == 5 && groups.allSatisfy { ($0["sensors"]?.arrayValue?.count ?? 0) <= MCPPayload.sensorsPerGroup && $0["truncated"] == true },
              "sensor groups list the hottest few and say they were cut")
        check(rich["thermal"]?["sensorCount"] == .int(200), "a broken sensor is not counted")
        let firstGroup = groups.first?["sensors"]?.arrayValue ?? []
        check(firstGroup.count == 3 && (firstGroup[0]["celsius"]?.doubleValue ?? 0) >= (firstGroup[1]["celsius"]?.doubleValue ?? 0),
              "the hottest sensor of a group comes first")
        check(rich["sleep"]?["total"] == .int(25) && rich["sleep"]?["truncated"] == true
              && rich["sleep"]?["blockers"]?.arrayValue?.count == MCPPayload.sleepBlockerLimit
              && rich["sleep"]?["blockers"]?.arrayValue?.first?["assertions"]?.arrayValue?.count == MCPPayload.assertionNamesPerBlocker,
              "sleep blockers are bounded and say so")
        check(rich["sleep"]?["displaySleepPrevented"] == true && rich["power"]?["totalSource"] == "system rail"
              && rich["power"]?["neuralEngineWatts"] == .int(0),
              "a measured zero stays a zero")
        check(rich["cpu"]?["coreKinds"] == "EEPPPPPPPP" && rich["cpu"]?["perCorePercent"]?.arrayValue?.count == 10,
              "per-core load comes with each core's kind")
        check(size(rich) < 12_000, "a full snapshot stays small (\(size(rich)) bytes)")
        let all = MCPPayload.snapshot(richSnapshot(), sections: [.thermal], allSensors: true, now: now)
        check(all["thermal"]?["sensorGroups"]?.arrayValue?.reduce(0) { $0 + ($1["sensors"]?.arrayValue?.count ?? 0) } == 200,
              "allSensors lists every sensor")
        check(all["cpu"] == nil && isISO(all["sampledAt"]) && all["ageSeconds"] == .double(0.4),
              "sections filter the answer, which says when it was sampled")

        let bare = MCPPayload.snapshot(bareSnapshot(), sections: SnapshotSection.allCases, allSensors: false, now: now)
        conforms(bare, "a snapshot from a Mac with few sources")
        check(bare["unavailable"] == ["gpu", "thermal", "power", "battery", "sleep"],
              "sections with no source are named unavailable, not zeroed")
        let bareKeys = keys(bare)
        check(!bareKeys.contains("efficiencyClockMHz") && !bareKeys.contains("efficiencyPercent") && !bareKeys.contains("coreKinds")
              && !bareKeys.contains("volume") && !bareKeys.contains("totalWatts") && !bareKeys.contains("gpuCelsius")
              && !bareKeys.contains("performanceCores"),
              "readings with no source are left out, never sent as 0")
    }

    // MARK: - get_processes

    static func checkProcessPayloads() {
        let snapshot = richSnapshot()
        let top = MCPPayload.processes(snapshot, sortBy: .cpu, limit: 5, now: now)
        conforms(top, "a process ranking")
        check(top["processes"]?.arrayValue?.count == 5 && top["total"] == .int(20) && top["truncated"] == true,
              "a cut ranking says how many there were")
        let first = top["processes"]?.arrayValue?.first
        check(first?["cpuPercent"] == .int(150) && first?["app"] == "Busy" && isISO(first?["startedAt"]) && first?["energyWatts"] == .int(3),
              "a row carries percent of one core, its outermost app, its start and its watts")
        let gpu = MCPPayload.processes(snapshot, sortBy: .gpu, limit: 20, now: now)
        let windowServer = gpu["processes"]?.arrayValue?.last
        check(windowServer?["name"] == "WindowServer" && windowServer?["gpuPercent"] == .int(7)
              && windowServer?["cpuPercent"] == nil && windowServer?["memoryBytes"] == nil,
              "another user's GPU client carries only what could be read")
        check(gpu["truncated"] == false && size(gpu) < 12_000, "the largest ranking stays small (\(size(gpu)) bytes)")
        check(keys(top).isDisjoint(with: ["commandLine", "user"]), "local rows expose no command line")
    }

    // MARK: - get_history

    static func checkHistoryPayloads() {
        var fine = MetricsHistory()
        var minute = MinuteHistory()
        // A day of samples every 30 s for the minute tier, the last ten
        // minutes every second for the rings; no GPU temperature, ever.
        for step in stride(from: 86_400.0, to: 600, by: -30) {
            var sample = Snapshot()
            sample.timestamp = now.addingTimeInterval(-step)
            sample.cpu.total = 0.25
            sample.thermal.cpuCelsius = 50
            sample.power.systemTotalWatts = 10
            minute.record(sample)
        }
        for second in 0..<600 {
            var sample = Snapshot()
            sample.timestamp = now.addingTimeInterval(Double(second - 599))
            sample.cpu.total = Double(second) / 599
            sample.thermal.cpuCelsius = 40 + Double(second % 10)
            sample.power.systemTotalWatts = 10
            fine.record(sample)
            minute.record(sample)
        }

        let recent = MCPPayload.history(fine: fine, minute: minute, series: HistorySeries.allCases,
                                        from: now.addingTimeInterval(-300), to: now, points: 60, sampleInterval: 1)
        conforms(recent, "five minutes of history")
        check(recent["source"] == "samples" && recent["bucketSeconds"] == .int(5) && recent["bucketStarts"]?.arrayValue?.count == 60,
              "a window the rings cover is answered per sample, in at most `points` buckets")
        let cpu = recent["series"]?["cpuPercent"]
        check(cpu?["max"] == .int(100) && cpu?["maxAt"] == .time(now) && cpu?["means"]?.arrayValue?.count == 60,
              "a series says how high it went and when")
        check(recent["noData"]?.arrayValue?.contains("gpuCelsius") == true && recent["series"]?["gpuCelsius"] == nil,
              "a series with no readings is named, not drawn as zeros")
        check(cpu?["samples"] == .int(301), "every sample in the window is counted once")

        let day = MCPPayload.history(fine: fine, minute: minute, series: [.cpuCelsius, .powerWatts],
                                     from: now.addingTimeInterval(-86_400), to: now, points: 60, sampleInterval: 1)
        conforms(day, "a day of history")
        check(day["source"] == "minutes" && day["resolutionSeconds"] == .int(60)
              && (day["bucketStarts"]?.arrayValue?.count ?? 99) <= 60,
              "a day is answered from the minutes, still within `points`")
        check(day["series"]?["powerWatts"]?["min"] == .int(10) && day["series"]?["powerWatts"]?["max"] == .int(10),
              "minute aggregates keep the readings exact")
        let celsius = day["series"]?["cpuCelsius"]
        check(celsius?["max"] == .int(50) && celsius?["min"] == .int(40), "the day's extremes span both feeds")
        check(size(day) < 8000 && size(MCPPayload.history(fine: fine, minute: minute, series: HistorySeries.allCases,
                                                           from: now.addingTimeInterval(-86_400), to: now, points: 240, sampleInterval: 1)) < 120_000,
              "history stays bounded at the largest request")
        let empty = MCPPayload.history(fine: MetricsHistory(), minute: MinuteHistory(), series: [.cpuPercent],
                                       from: now.addingTimeInterval(-60), to: now, points: 60, sampleInterval: 1)
        check(empty["noData"] == ["cpuPercent"] && empty["series"] == [:], "no history at all is said, not zero-filled")
    }

    // MARK: - get_process_history

    static func checkProcessHistoryPayloads() {
        var samples: [ProcessSample] = []
        for index in 0..<100 {
            var rows = [row(1, "steady", cpu: 40)]
            if index % 2 == 0 { rows.append(row(2, "spiky", cpu: 90)) }
            var totals = SystemTotals()
            totals.cpuFraction = Double(index) / 100
            totals.memoryTotalBytes = 16 << 30
            totals.memoryUsedBytes = 8 << 30
            totals.memoryFraction = 0.5
            samples.append(ProcessSample(
                timestamp: now.addingTimeInterval(Double(index - 99) * 6), interval: 6, rows: rows,
                gpuAttributionAvailable: true, processCount: 500, totals: totals))
        }
        guard case .success(let nearest) = MCPPayload.processHistory(
            samples, at: samples[10].timestamp.addingTimeInterval(1), window: nil, sortBy: .cpu, limit: 10, now: now) else {
            check(false, "the nearest table is found")
            return
        }
        conforms(nearest, "a table at a moment")
        check(nearest["sampledAt"] == .time(samples[10].timestamp) && nearest["offsetSeconds"] == .int(-1)
              && nearest["processes"]?.arrayValue?.first?["name"] == "spiky",
              "the nearest table is found, with how far off it is")
        if case .failure(let error) = MCPPayload.processHistory(
            samples, at: now.addingTimeInterval(-7200), window: nil, sortBy: .cpu, limit: 10, now: now) {
            check(error.code == .notFound && error.detail["retained"]?["tables"] == .int(100),
                  "a moment before the retained tables is not_found, with what is retained")
        } else { check(false, "a moment before the retained tables is not_found") }
        guard case .success(let span) = MCPPayload.processHistory(
            samples, at: nil, window: 600, sortBy: .cpu, limit: 1, now: now) else {
            check(false, "a span is summarised")
            return
        }
        conforms(span, "a summarised span")
        let top = span["processes"]?.arrayValue?.first
        check(span["tables"] == .int(100) && top?["name"] == "spiky" && top?["meanCpuPercent"] == .int(45)
              && top?["peakCpuPercent"] == .int(90) && top?["tablesPlaced"] == .int(50) && span["truncated"] == true,
              "a span ranks by the mean over every table, absences counting as zero")
        if case .failure(let error) = MCPPayload.processHistory([], at: nil, window: nil, sortBy: .cpu, limit: 10, now: now) {
            check(error.code == .notReady, "no tables yet is not_ready")
        } else { check(false, "no tables yet is not_ready") }
    }

    // MARK: - get_app_usage

    static func checkUsagePayloads() {
        func app(_ name: String, cpu: UInt64, energy: UInt64) -> AppUsageRow {
            var totals = AppUsageTotals()
            totals.cpuNanos = cpu
            totals.energyNanojoules = energy
            totals.memoryByteSeconds = 3600 * 100_000_000
            totals.peakMemoryBytes = 200_000_000
            return AppUsageRow(
                attribution: AppAttribution(key: "app:/Applications/\(name).app", displayName: name,
                                            bundlePath: "/Applications/\(name).app", executablePath: nil),
                totals: totals)
        }
        let report = AppUsageReport(
            window: 3600, coveredSeconds: 3600, earliestData: now.addingTimeInterval(-7200),
            rows: [app("Quiet", cpu: 1_000_000_000, energy: 90_000_000_000), app("Busy", cpu: 900_000_000_000, energy: 1_000_000_000),
                   app("Idle", cpu: 0, energy: 0)])
        let byEnergy = MCPPayload.appUsage(report, sortBy: .energy, limit: 1, now: now)
        conforms(byEnergy, "app usage")
        let first = byEnergy["apps"]?.arrayValue?.first
        check(first?["name"] == "Quiet" && first?["energyJoules"] == .int(90) && first?["averageWatts"] == .double(0.025)
              && byEnergy["total"] == .int(2) && byEnergy["truncated"] == true,
              "apps rank by the chosen work, in joules and watts, and idle apps are left out")
        let byCPU = MCPPayload.appUsage(report, sortBy: .cpu, limit: 10, now: now)
        check(byCPU["apps"]?.arrayValue?.first?["averageCpuPercent"] == .int(25) && byCPU["apps"]?.arrayValue?.first?["cpuSeconds"] == .int(900),
              "CPU is time and average percent of one core")
        let unobserved = MCPPayload.appUsage(AppUsageReport(window: 3600), sortBy: .cpu, limit: 10, now: now)
        check(unobserved["apps"] == [] && unobserved["coveredSeconds"] == .int(0), "a window never observed has no apps rather than zeros")
    }

    // MARK: - get_status

    static func checkStatusPayload() {
        var minute = MinuteHistory()
        var sample = richSnapshot()
        minute.record(sample)
        sample.timestamp = now.addingTimeInterval(-10)
        minute.record(sample)
        let status = MCPPayload.status(MCPPayload.StatusInputs(
            snapshot: richSnapshot(), hasSample: true, samplingInterval: 2, samplingPaused: false,
            leaseRemaining: 28, leaseStartedAt: now.addingTimeInterval(-2),
            detailedSamplingSince: now.addingTimeInterval(-1.5), messagesAnswered: 3,
            fineCoverage: (now.addingTimeInterval(-600), now, 300), minuteCoverage: minute.coverage,
            processTables: [], runningSince: now.addingTimeInterval(-3600), pid: 123,
            executablePath: "/Applications/Rex Boing.app/Contents/MacOS/Rex Boing", now: now))
        conforms(status, "status")
        check(status["sources"]?["fans"] == true && status["sources"]?["battery"] == true
              && status["history"]?["vitalsPerSample"]?["samples"] == .int(300)
              && status["history"]?["vitalsPerMinute"]?["minutes"] == .int(1)
              && status["agentAccess"]?["leaseActive"] == true,
              "status reports sources, history reach and the lease")
    }
}
