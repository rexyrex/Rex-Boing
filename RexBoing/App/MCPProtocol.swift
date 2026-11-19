import Foundation

/// The MCP surface's fixed facts: who the server is, which protocol revisions
/// it speaks, what every client is told, and the names the bridge and the
/// app agree on.
enum MCPIdentity {
    /// What harness configurations call the server, and the prefix every tool
    /// carries in a host (`mcp__rex-boing__get_snapshot`).
    static let serverName = "rex-boing"
    static let title = "Rex Boing"

    /// The bundle identifier predates the app's name (see project.yml). The
    /// bridge runs from inside the same bundle, so it reads the same one.
    static let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.rexyrex.Zoomies"

    /// The Mach service the running app answers on. A bootstrap name, local
    /// to this login session like the stats broadcast's distributed
    /// notifications: no socket file, nothing on disk, nothing on a network.
    static var portName: String { bundleIdentifier + ".mcp" }

    /// The preference behind Settings › General › AI agents. The bridge reads
    /// it directly, so it can answer `disabled` without waking the app.
    static let enabledKey = "mcpEnabled"

    /// Passed when the bridge launches the app, so it starts the way a login
    /// launch does: in the menu bar, with no window and no activation, even
    /// when "Open when Rex Boing starts" is on.
    static let launchArgument = "--mcp-launch"

    /// Version of the bridge-to-app messages on the port. Bumped only if a
    /// request stops meaning what it did; an agent's bridge can outlive a
    /// reinstall of the app it talks to.
    static let portProtocolVersion = 1

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    static var build: String? {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String
    }

    /// Revisions that declare their version on every request.
    static let modernVersions = ["2026-07-28"]
    /// Revisions that open with an `initialize` handshake.
    static let legacyVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    static var supportedVersions: [String] { modernVersions + legacyVersions }

    /// Echoes the client's version when it is one this server speaks;
    /// otherwise offers the newest one an `initialize` can agree on (a
    /// modern revision has no handshake to agree on it in).
    static func negotiate(_ requested: String?) -> String {
        guard let requested, legacyVersions.contains(requested) else { return legacyVersions[0] }
        return requested
    }

    static let instructions = """
    Rex Boing is the menu bar system monitor on this Mac. These tools read its live readings and the history it keeps in memory; all of them are read-only.
    • Units are in the key names: …Percent (0 to 100), …Bytes, …BytesPerSecond, …Celsius, …Watts, …RPM, …MHz, …Seconds. The one exception is per-process cpuPercent, which is percent of one core as in Activity Monitor and can exceed 100.
    • A reading this Mac has no source for is left out, never sent as 0. get_snapshot names whole sections it cannot report under "unavailable".
    • Times are ISO 8601 with this Mac's UTC offset. Live readings carry sampledAt and ageSeconds.
    • Windows take seconds or durations (90s, 15m, 6h, 1d). Moments take ISO 8601 or how long ago (15m).
    • History exists only since Rex Boing started and only in memory: vitals per sample for the newest 600 samples (ten minutes at the default one-second refresh) and per minute for 24 hours (get_history), ranked process tables for up to an hour (get_process_history), per-app work for 24 hours (get_app_usage). get_status says how far back each reaches right now.
    • Errors are results with isError and {"error":{"code","message"}}; the codes are not_running, disabled, not_ready, not_found, bad_input, timeout and internal, and the message says what to do next.
    """

    /// The executable an agent should run: this one, at its real path.
    static var executablePath: String {
        Bundle.main.executablePath ?? CommandLine.arguments.first ?? "Rex Boing"
    }

    /// The enclosing `.app`, when this executable is inside one.
    static var appBundleURL: URL? {
        let url = Bundle.main.bundleURL
        return url.pathExtension == "app" ? url : nil
    }

    /// A shell word for a path: double-quoted, with the four characters that
    /// stay special inside double quotes escaped.
    static func shellQuoted(_ path: String) -> String {
        var quoted = ""
        for character in path {
            if "\"$`\\".contains(character) { quoted.append("\\") }
            quoted.append(character)
        }
        return "\"" + quoted + "\""
    }

    static var claudeCodeCommand: String {
        "claude mcp add --scope user \(serverName) -- \(shellQuoted(executablePath)) mcp"
    }

    static var codexCommand: String {
        "codex mcp add \(serverName) -- \(shellQuoted(executablePath)) mcp"
    }

    /// Whether the user has left agent access on. Read through CFPreferences
    /// rather than `UserDefaults.standard`, so the bridge sees a change the
    /// app made a moment ago without either process registering defaults or
    /// writing anything. Never written: absent means the default, which is on.
    static func isEnabledInPreferences() -> Bool {
        let value = CFPreferencesCopyAppValue(enabledKey as CFString, bundleIdentifier as CFString)
        return (value as? Bool) ?? true
    }
}

/// JSON-RPC 2.0 framing. Messages are one JSON object per line.
enum JSONRPC {
    static let parseError = -32700
    static let invalidRequest = -32600
    static let methodNotFound = -32601
    static let invalidParams = -32602
    static let internalError = -32603
    /// `UnsupportedProtocolVersionError`, from the 2026-07-28 revision.
    static let unsupportedProtocolVersion = -32022

    static func result(id: JSONValue, _ result: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    static func error(id: JSONValue, code: Int, message: String, data: JSONValue? = nil) -> JSONValue {
        var error: [String: JSONValue] = ["code": .int(code), "message": .string(message)]
        if let data { error["data"] = data }
        return ["jsonrpc": "2.0", "id": id, "error": .object(error)]
    }
}

/// A failure an agent can act on, returned as an `isError` tool result rather
/// than a protocol error, so the agent reads the message instead of the host
/// swallowing it. The codes and their meaning are shared with Rex Boing
/// Remote's server.
struct MCPToolError: Error, Sendable, Equatable {
    enum Code: String, Sendable, CaseIterable {
        case notRunning = "not_running"
        case disabled
        case notReady = "not_ready"
        case notFound = "not_found"
        case badInput = "bad_input"
        case timeout
        case `internal`
    }

    var code: Code
    var message: String
    var detail: [String: JSONValue] = [:]

    init(_ code: Code, _ message: String, detail: [String: JSONValue] = [:]) {
        self.code = code
        self.message = message
        self.detail = detail
    }

    var json: JSONValue {
        var error = detail
        error["code"] = .string(code.rawValue)
        error["message"] = .string(message)
        return ["error": .object(error)]
    }

    /// The error from its own JSON, as the app sends it over the port.
    init?(json: JSONValue) {
        guard let object = json["error"]?.objectValue,
              let code = object["code"]?.stringValue.flatMap(Code.init(rawValue:)),
              let message = object["message"]?.stringValue else { return nil }
        var detail = object
        detail.removeValue(forKey: "code")
        detail.removeValue(forKey: "message")
        self.init(code, message, detail: detail)
    }

    static func badInput(_ message: String) -> MCPToolError {
        MCPToolError(.badInput, message)
    }

    static let disabledMessage = "Rex Boing's AI agent access is switched off. Ask the user to turn on \"Let AI agents read this Mac's readings\" in Rex Boing › Settings › General, then call again."
}

/// One tool call the session has validated and handed to whoever can answer
/// it: the bridge relays it to the app.
struct MCPCall: Sendable {
    var id: JSONValue
    var name: String
    var arguments: [String: JSONValue]
    /// Whether the request declared a per-request protocol version, which
    /// decides the shape of the answer (`resultType`, `_meta`).
    var modern: Bool
}

/// What the stdio loop should do with one line from the client.
enum MCPInbound: Sendable {
    /// Write this message now.
    case respond(JSONValue)
    /// Run this call off the reading thread, then write `MCPSession.response(to:result:)`.
    case call(MCPCall)
    /// The client gave up on this request; its answer must not be sent.
    case cancel(JSONValue)
    /// A notification, or a reply to nothing: nothing to send.
    case ignore
}

/// The protocol half of the server: everything that can be answered without
/// the app. Serves both eras on the same stdio stream: an `initialize`
/// handshake (2025-11-25 and earlier) and requests that carry their version
/// in `_meta` (2026-07-28). Era is decided per request, so the same process
/// can serve either kind of client, and neither needs any state from the
/// other.
enum MCPSession {
    static let protocolVersionKey = "io.modelcontextprotocol/protocolVersion"
    static let clientCapabilitiesKey = "io.modelcontextprotocol/clientCapabilities"
    static let serverInfoKey = "io.modelcontextprotocol/serverInfo"

    static func handle(_ line: Data) -> MCPInbound {
        guard let message = try? JSONValue.parse(line) else {
            // Dropped silently, the client would wait on it forever.
            return .respond(JSONRPC.error(id: .null, code: JSONRPC.parseError, message: "Not valid JSON. Send one JSON-RPC message per line."))
        }
        if case .array = message {
            return .respond(JSONRPC.error(id: .null, code: JSONRPC.invalidRequest, message: "Batched requests are not supported; send one message per line."))
        }
        guard case .object(let object) = message else {
            return .respond(JSONRPC.error(id: .null, code: JSONRPC.invalidRequest, message: "A message must be a JSON object."))
        }
        let id = object["id"]
        guard let method = object["method"]?.stringValue else {
            // A response from the client: this server sends no requests, so
            // there is nothing for it to answer.
            if object["result"] != nil || object["error"] != nil { return .ignore }
            return .respond(JSONRPC.error(id: id ?? .null, code: JSONRPC.invalidRequest, message: "Missing method."))
        }
        let params = object["params"]?.objectValue ?? [:]

        guard let id else {
            // Notifications are never answered. `initialized` needs nothing
            // either: no state hangs on the handshake.
            if method == "notifications/cancelled", let request = params["requestId"] {
                return .cancel(request)
            }
            return .ignore
        }
        switch id {
        case .string, .int: break
        case .double(let value) where value.rounded() == value: break
        default:
            return .respond(JSONRPC.error(id: .null, code: JSONRPC.invalidRequest, message: "A request id must be a string or an integer."))
        }

        // A modern request declares its version, and is answered in kind.
        let meta = params["_meta"]?.objectValue ?? [:]
        var modern = false
        if let declared = meta[protocolVersionKey] {
            guard let version = declared.stringValue, MCPIdentity.supportedVersions.contains(version) else {
                return .respond(JSONRPC.error(
                    id: id, code: JSONRPC.unsupportedProtocolVersion, message: "Unsupported protocol version",
                    data: ["supported": .array(MCPIdentity.supportedVersions.map(JSONValue.string)), "requested": declared]))
            }
            guard meta[clientCapabilitiesKey]?.objectValue != nil else {
                return .respond(JSONRPC.error(
                    id: id, code: JSONRPC.invalidParams,
                    message: "Missing _meta[\"\(clientCapabilitiesKey)\"], which a request declaring \(protocolVersionKey) must carry."))
            }
            modern = MCPIdentity.modernVersions.contains(version)
        }

        switch method {
        case "initialize":
            let version = MCPIdentity.negotiate(params["protocolVersion"]?.stringValue)
            return .respond(JSONRPC.result(id: id, [
                "protocolVersion": .string(version),
                "capabilities": ["tools": [:]],
                "serverInfo": serverInfo,
                "instructions": .string(MCPIdentity.instructions),
            ]))
        case "server/discover":
            return .respond(JSONRPC.result(id: id, [
                "resultType": "complete",
                "supportedVersions": .array(MCPIdentity.supportedVersions.map(JSONValue.string)),
                "capabilities": ["tools": [:]],
                "_meta": .object([serverInfoKey: serverInfo]),
                "instructions": .string(MCPIdentity.instructions),
                "ttlMs": .int(cacheMilliseconds),
                "cacheScope": "private",
            ]))
        case "ping":
            // Gone from the 2026-07-28 revision, still answered: a legacy
            // client's keep-alive must never look like a dead server.
            return .respond(JSONRPC.result(id: id, decorate([:], modern: modern)))
        case "tools/list":
            var result: [String: JSONValue] = ["tools": .array(MCPCatalog.tools.map(\.listing))]
            if modern {
                result["ttlMs"] = .int(cacheMilliseconds)
                result["cacheScope"] = "private"
            }
            return .respond(JSONRPC.result(id: id, decorate(result, modern: modern)))
        case "tools/call":
            guard let name = params["name"]?.stringValue else {
                return .respond(JSONRPC.error(id: id, code: JSONRPC.invalidParams, message: "tools/call needs params.name, the tool to call."))
            }
            let arguments: [String: JSONValue]
            switch params["arguments"] {
            case nil, .null?: arguments = [:]
            case .object(let object)?: arguments = object
            default:
                return .respond(JSONRPC.error(id: id, code: JSONRPC.invalidParams, message: "tools/call params.arguments must be an object."))
            }
            // An unknown tool is a protocol error, as the specification has
            // it; the candidates ride along so a client can still recover.
            guard MCPCatalog.tool(named: name) != nil else {
                return .respond(JSONRPC.error(
                    id: id, code: JSONRPC.invalidParams,
                    message: "Unknown tool: \(name). The tools are \(MCPCatalog.tools.map(\.name).joined(separator: ", ")).",
                    data: ["candidates": MCPCatalog.candidateList(for: name)]))
            }
            let call = MCPCall(id: id, name: name, arguments: arguments, modern: modern)
            // Bad arguments are answered here, without the app, so a typo
            // never launches it.
            if case .failure(let error) = MCPRequest.parse(tool: name, arguments: arguments, now: Date()) {
                return .respond(response(to: call, result: .failure(error)))
            }
            return .call(call)
        default:
            return .respond(JSONRPC.error(id: id, code: JSONRPC.methodNotFound, message: "Unknown method \(method). This server offers tools only."))
        }
    }

    /// The `tools/call` answer: one text block of compact JSON, success or not.
    static func response(to call: MCPCall, result: Result<JSONValue, MCPToolError>) -> JSONValue {
        var body: [String: JSONValue]
        switch result {
        case .success(let value):
            body = ["content": [["type": "text", "text": .string(value.serializedString())]]]
        case .failure(let error):
            body = ["content": [["type": "text", "text": .string(error.json.serializedString())]], "isError": true]
        }
        return JSONRPC.result(id: call.id, decorate(body, modern: call.modern))
    }

    /// The tool list cannot change while this process lives: it is compiled
    /// into the executable the client launched. An hour is a polite hint.
    private static let cacheMilliseconds = 3_600_000

    private static var serverInfo: JSONValue {
        var info: [String: JSONValue] = ["name": .string(MCPIdentity.serverName), "title": .string(MCPIdentity.title), "version": .string(MCPIdentity.version)]
        if let build = MCPIdentity.build { info["version"] = .string("\(MCPIdentity.version) (\(build))") }
        return .object(info)
    }

    /// Modern results carry `resultType` and say who answered. Legacy ones
    /// are left exactly as their revision defines them: a strict client
    /// validating an empty `ping` result rejects any extra key.
    private static func decorate(_ result: [String: JSONValue], modern: Bool) -> JSONValue {
        guard modern else { return .object(result) }
        var result = result
        result["resultType"] = "complete"
        result["_meta"] = .object([serverInfoKey: serverInfo])
        return .object(result)
    }
}
