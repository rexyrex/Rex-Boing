import AppKit
import Darwin
import Foundation

/// `Rex Boing mcp`: the stdio MCP server that Claude Code, Codex, Claude
/// Desktop and the rest launch. It is the app's own executable run with an
/// argument, so registering it installs nothing, and it never starts
/// `NSApplication`: no menu bar item, no windows, no Dock icon.
///
/// It is a relay, not a second monitor. It holds no metric state; tool calls
/// go to the running app over its message port (`MCPServer`), which answers
/// from the readings and history it already keeps. Being the same binary, it
/// answers the handshake, `ping` and the tool list by itself, so a harness
/// starting up never waits on the app, let alone launches it, just to learn
/// what is on offer.
///
/// The app can go away under it: quit, restarted, reinstalled by
/// `build.sh --install`. A call in flight then gets an error result; the
/// next call finds the new app's port, launching the app quietly first when
/// it is not running at all, unless `--no-launch` says not to.
enum MCPBridge {
    static let commands: Set<String> = ["mcp", "tools", "call"]

    /// How long one call may wait on a running app's fresh sample: two
    /// ticks at the slowest refresh, with room to spare.
    static let callDeadline: TimeInterval = 12
    /// How long a call that had to launch the app waits for it, all told.
    static let launchDeadline: TimeInterval = 30

    /// Runs a subcommand and returns the exit status. `arguments` excludes
    /// the executable path.
    static func run(_ arguments: [String]) -> Int32 {
        // A client that hangs up mid-reply must not kill the process on a
        // write; the read loop sees end-of-file and exits instead.
        signal(SIGPIPE, SIG_IGN)
        guard let command = arguments.first else { return usage(status: 2) }
        var options = Array(arguments.dropFirst())
        let mayLaunch = !options.contains("--no-launch")
        options.removeAll { $0 == "--no-launch" }
        if options.contains("-h") || options.contains("--help") { return usage(status: 0) }

        switch command {
        case "mcp":
            for unknown in options {
                FileHandle.standardError.write(Data("rex-boing mcp: ignoring unknown argument \(unknown)\n".utf8))
            }
            Server(relay: Relay(mayLaunch: mayLaunch)).serve()
            return 0
        case "tools":
            for tool in MCPCatalog.tools {
                print(tool.name.padding(toLength: 22, withPad: " ", startingAt: 0) + tool.title)
            }
            return 0
        case "call":
            guard let name = options.first else { return usage(status: 2) }
            var callArguments: [String: JSONValue] = [:]
            if options.count > 1 {
                guard let parsed = try? JSONValue.parse(options[1]), let object = parsed.objectValue else {
                    FileHandle.standardError.write(Data("The arguments must be one JSON object, such as '{\"limit\": 5}'.\n".utf8))
                    return 2
                }
                callArguments = object
            }
            let result: Result<JSONValue, MCPToolError>
            switch MCPRequest.parse(tool: name, arguments: callArguments, now: Date()) {
            case .failure(let error): result = .failure(error)
            case .success: result = Relay(mayLaunch: mayLaunch).perform(tool: name, arguments: callArguments) { false }
            }
            switch result {
            case .success(let value):
                print(value.serializedString(pretty: true))
                return 0
            case .failure(let error):
                print(error.json.serializedString(pretty: true))
                return 1
            }
        default:
            return usage(status: 2)
        }
    }

    @discardableResult
    private static func usage(status: Int32) -> Int32 {
        let executable = MCPIdentity.shellQuoted(MCPIdentity.executablePath)
        let text = """
        Usage: \(executable) mcp [--no-launch]
               \(executable) tools
               \(executable) call <tool> ['<json arguments>'] [--no-launch]

        mcp    Serves Rex Boing's readings to an AI agent over MCP on stdin and stdout
               (diagnostics on stderr). Tool calls are answered by the running app,
               which is opened quietly in the menu bar when it is not running, unless
               --no-launch is given. Nothing is served over a network.
        tools  Lists the tools.
        call   Calls one tool and prints its JSON result.

        Register it with:
          \(MCPIdentity.claudeCodeCommand)
          \(MCPIdentity.codexCommand)
        """
        let output = status == 0 ? FileHandle.standardOutput : FileHandle.standardError
        output.write(Data((text + "\n").utf8))
        return status
    }

    // MARK: - Relay

    /// Carries tool calls to the running app and their answers back, any
    /// number at once.
    ///
    /// Calls run concurrently, but every touch of the port takes a turn, and
    /// the turn is not optional. CoreFoundation hands every thread of a
    /// process the same cached object for a remote port name, and that
    /// object has one reply port and one table of pending replies: it is not
    /// safe for concurrent requests. Several threads on it at once lose
    /// replies (a call then sits out the whole receive timeout), fail with
    /// "invalid" statuses, get a nil lookup, and can trap. So the lookup, the
    /// request and the release of the remote all happen inside one turn. An
    /// exchange takes a fraction of a millisecond, because the app answers at
    /// once, "retry" included; the waiting (for a fresh sample, for a launch)
    /// happens outside the turn, so a slow call holds up no other. The remote
    /// is never invalidated here either: invalidating the shared object would
    /// kill it under every other caller.
    final class Relay: @unchecked Sendable {
        let mayLaunch: Bool
        let portName: String
        private let isEnabled: @Sendable () -> Bool
        private let appIsRunning: @Sendable () -> Bool
        private let launcher: @Sendable () -> Bool
        /// When the start this bridge has under way began, if one is: set
        /// when it starts the app, cleared once the app answers (or the start
        /// fails). Calls that find the app gone meanwhile wait for that start
        /// rather than open it again; a call that finds it gone after it has
        /// answered starts it afresh, however soon that is.
        private var startUnderWay: TimeInterval?
        private let lock = NSLock()
        private let exchangeLock = NSLock()

        /// The defaults are the real app; the headless check passes its own
        /// port and answers so it can drive this exact code against a stand-in.
        init(
            mayLaunch: Bool,
            portName: String = MCPIdentity.portName,
            isEnabled: @escaping @Sendable () -> Bool = { MCPIdentity.isEnabledInPreferences() },
            isAppRunning: @escaping @Sendable () -> Bool = { Relay.isAppRunning() },
            launch: @escaping @Sendable () -> Bool = { Relay.openApp() }
        ) {
            self.mayLaunch = mayLaunch
            self.portName = portName
            self.isEnabled = isEnabled
            self.appIsRunning = isAppRunning
            self.launcher = launch
        }

        private enum Exchange {
            case noPort
            case sent(Int32, Data?)
            /// Other calls held the port until this call's own deadline.
            case noTurn
        }

        /// One request and its reply, in this thread's turn, waiting for the
        /// turn no longer than the call itself may take.
        private func exchange(_ request: CFData, deadline: TimeInterval) -> Exchange {
            let wait = max(0, deadline - ProcessInfo.processInfo.systemUptime)
            guard exchangeLock.lock(before: Date(timeIntervalSinceNow: wait)) else { return .noTurn }
            let outcome: Exchange
            // A fresh lookup every time: after a restart the old port is
            // dead and the name belongs to the new app. The remote's scope
            // ends before the turn does, so its release happens inside it.
            if let remote = CFMessagePortCreateRemote(nil, portName as CFString) {
                var reply: Unmanaged<CFData>?
                let status = CFMessagePortSendRequest(
                    remote, 1, request, 2, 10, CFRunLoopMode.defaultMode.rawValue, &reply)
                outcome = .sent(status, reply.map { $0.takeRetainedValue() as Data })
            } else {
                outcome = .noPort
            }
            exchangeLock.unlock()
            return outcome
        }

        func perform(tool: String, arguments: [String: JSONValue], isCancelled: () -> Bool) -> Result<JSONValue, MCPToolError> {
            // Read on every call: the user may have flipped it since the last.
            guard isEnabled() else {
                return .failure(MCPToolError(.disabled, MCPToolError.disabledMessage))
            }
            let request = JSONValue.object([
                "v": .int(MCPIdentity.portProtocolVersion),
                "tool": .string(tool),
                "arguments": .object(arguments),
            ]).serialized() as CFData

            let start = ProcessInfo.processInfo.systemUptime
            var deadline = start + MCPBridge.callDeadline
            var answered = false
            var launched = false
            var waitedForRetry = false

            while !isCancelled() {
                let now = ProcessInfo.processInfo.systemUptime
                let outcome = exchange(request, deadline: deadline)
                if case .noTurn = outcome {
                    return .failure(MCPToolError(.timeout, "Rex Boing's port stayed busy with this agent's other calls until this one ran out of time. Call again."))
                }
                guard case .sent(let status, let data) = outcome else {
                    if answered {
                        return .failure(MCPToolError(.notRunning, "Rex Boing quit while answering this call. Call again: the next call reconnects, opening Rex Boing if it is not running."))
                    }
                    guard isEnabled() else {
                        return .failure(MCPToolError(.disabled, MCPToolError.disabledMessage))
                    }
                    if !appIsRunning() {
                        guard mayLaunch else {
                            return .failure(MCPToolError(.notRunning, "Rex Boing is not running, and this MCP server was started with --no-launch. Ask the user to open Rex Boing, then call again."))
                        }
                        if !launched {
                            launched = true
                            guard let started = startApp() else {
                                return .failure(MCPToolError(.notRunning, "Rex Boing is not running and could not be opened from \(MCPIdentity.appBundleURL?.path ?? MCPIdentity.executablePath). Ask the user to open Rex Boing, then call again."))
                            }
                            deadline = max(deadline, started + MCPBridge.launchDeadline)
                        }
                    } else if !launched, let started = currentStart() {
                        // Another call's start: the app exists but is not
                        // answering yet. Wait for it as that call does.
                        launched = true
                        deadline = max(deadline, started + MCPBridge.launchDeadline)
                    } else if !launched, now - start > 8 {
                        // Running, with access on, yet no port after a
                        // launch's worth of waiting: a build from before MCP.
                        return .failure(MCPToolError(.notRunning, "Rex Boing is running but not answering over MCP; it may be a version without it. Ask the user to update or reopen Rex Boing, then call again."))
                    }
                    guard now < deadline else {
                        return .failure(MCPToolError(.notRunning, "Rex Boing did not start answering within \(Int(MCPBridge.launchDeadline)) s of being opened. Ask the user to check that Rex Boing is in the menu bar, then call again."))
                    }
                    Thread.sleep(forTimeInterval: 0.25)
                    continue
                }

                switch status {
                case kCFMessagePortSuccess:
                    answered = true
                    startAnswered()
                    guard let data, let message = try? JSONValue.parse(data) else {
                        return .failure(MCPToolError(.internal, "Rex Boing sent an answer that is not JSON. Call again; if it persists, restart Rex Boing."))
                    }
                    if let result = message["result"] { return .success(result) }
                    if let error = MCPToolError(json: message) { return .failure(error) }
                    guard let wait = message["retryAfterMs"]?.doubleValue else {
                        return .failure(MCPToolError(.internal, "Rex Boing sent an answer this server does not understand. Restart the agent's connection to rex-boing, then call again."))
                    }
                    waitedForRetry = true
                    let remaining = deadline - ProcessInfo.processInfo.systemUptime
                    guard remaining > 0 else {
                        return .failure(MCPToolError(.notReady, "Rex Boing has not finished taking a fresh reading. Call again in a few seconds."))
                    }
                    Thread.sleep(forTimeInterval: min(max(0.01, wait / 1000), remaining))
                case kCFMessagePortSendTimeout, kCFMessagePortReceiveTimeout:
                    return .failure(MCPToolError(.timeout, "Rex Boing did not answer within 10 s; it may be busy or stuck. Call again; if it keeps happening, ask the user to restart Rex Boing."))
                case kCFMessagePortBecameInvalidError:
                    // The app went away with this request already in its
                    // queue. Not retried here: an app quitting is often an
                    // app being replaced, and relaunching the copy on disk
                    // mid-install would start the old build in place of
                    // the new one. The next call reconnects.
                    return .failure(MCPToolError(.notRunning, "Rex Boing quit while answering this call. Call again: the next call reconnects, opening Rex Boing if it is not running."))
                default:
                    // The port was dead before anything was sent: the app
                    // went away between the lookup and the send.
                    if waitedForRetry || answered {
                        return .failure(MCPToolError(.notRunning, "Rex Boing quit while answering this call. Call again: the next call reconnects, opening Rex Boing if it is not running."))
                    }
                    guard ProcessInfo.processInfo.systemUptime < deadline else {
                        return .failure(MCPToolError(.timeout, "Rex Boing's port kept failing (status \(status)). Ask the user to restart Rex Boing, then call again."))
                    }
                    Thread.sleep(forTimeInterval: 0.25)
                }
            }
            return .failure(MCPToolError(.timeout, "The call was cancelled."))
        }

        /// Starts the app, or joins the start already under way, so a burst
        /// of calls that all find it gone opens it once. Returns when the
        /// start began; nil when the app could not be started.
        private func startApp() -> TimeInterval? {
            lock.lock()
            let now = ProcessInfo.processInfo.systemUptime
            if let started = startUnderWay, now - started < MCPBridge.launchDeadline {
                lock.unlock()
                return started
            }
            startUnderWay = now
            lock.unlock()
            guard launcher() else {
                lock.lock()
                if startUnderWay == now { startUnderWay = nil }
                lock.unlock()
                return nil
            }
            return now
        }

        /// The start under way, if one is and it is not past its deadline.
        private func currentStart() -> TimeInterval? {
            lock.lock()
            defer { lock.unlock() }
            guard let started = startUnderWay,
                  ProcessInfo.processInfo.systemUptime - started < MCPBridge.launchDeadline else { return nil }
            return started
        }

        /// The app answered: whatever start was under way is over. If the app
        /// goes away after this, the next call that finds it gone starts it
        /// again instead of waiting on a start that already finished.
        private func startAnswered() {
            lock.lock()
            startUnderWay = nil
            lock.unlock()
        }

        /// Opens the app the way a login launch would: in the background,
        /// with the argument that keeps the Monitor window closed. `open` on
        /// a copy that is already running would only deliver a reopen, which
        /// shows that window, so this is reached only when none is running.
        static func openApp() -> Bool {
            guard let bundle = MCPIdentity.appBundleURL else { return false }
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            // -g: no activation. -n: a new instance even if LaunchServices
            // still has a quitting copy on its books, which otherwise turns
            // the launch into a reopen of the dying one. Not -j: a hidden
            // launch hides an accessory app's popover too, and the rex is
            // the user's way into it.
            open.arguments = ["-n", "-g", bundle.path, "--args", MCPIdentity.launchArgument]
            open.standardOutput = FileHandle.nullDevice
            open.standardError = FileHandle.nullDevice
            do {
                try open.run()
                open.waitUntilExit()
            } catch {
                return false
            }
            return open.terminationStatus == 0
        }

        /// Whether a copy of the app is running. Bridges never check in with
        /// LaunchServices, so they are not counted, here or by the app's own
        /// single-instance check.
        static func isAppRunning() -> Bool {
            let me = getpid()
            return NSRunningApplication.runningApplications(withBundleIdentifier: MCPIdentity.bundleIdentifier)
                .contains { $0.processIdentifier != me && !$0.isTerminated }
        }
    }

    // MARK: - stdio

    /// Reads one message per line from stdin and writes one per line to
    /// stdout; nothing else is ever written to stdout.
    private final class Server: @unchecked Sendable {
        private let relay: Relay
        private let output = NSLock()
        private let state = NSLock()
        private var inFlight = Set<String>()
        private var cancelled = Set<String>()
        /// Calls run off the reading thread and side by side: agents issue
        /// tool calls in parallel, a `ping` or a cancellation must still be
        /// read while one waits on the app, and a call waiting for a fresh
        /// sample must not hold up one the app can answer at once.
        private let calls = DispatchQueue(
            label: "com.rexyrex.Zoomies.mcp.calls", qos: .userInitiated, attributes: .concurrent)
        private let pending = DispatchGroup()

        init(relay: Relay) {
            self.relay = relay
        }

        func serve() {
            while let line = readLine(strippingNewline: true) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                switch MCPSession.handle(Data(trimmed.utf8)) {
                case .respond(let message):
                    write(message)
                case .ignore:
                    break
                case .cancel(let id):
                    let key = id.serializedString()
                    state.lock()
                    // Only for a call still waiting: a late cancellation of
                    // one already answered has nothing left to stop.
                    if inFlight.contains(key) { cancelled.insert(key) }
                    state.unlock()
                case .call(let call):
                    let key = call.id.serializedString()
                    state.lock()
                    inFlight.insert(key)
                    state.unlock()
                    calls.async(group: pending) { [self] in
                        let result = relay.perform(tool: call.name, arguments: call.arguments) {
                            self.isCancelled(key)
                        }
                        state.lock()
                        inFlight.remove(key)
                        let wasCancelled = cancelled.remove(key) != nil
                        state.unlock()
                        // A cancelled request gets no answer at all.
                        if !wasCancelled { write(MCPSession.response(to: call, result: result)) }
                    }
                }
            }
            // End of input is the client's way of saying goodbye. Calls
            // already read are finished, within their own deadlines, so a
            // scripted session piped in whole still gets every answer.
            pending.wait()
        }

        private func isCancelled(_ key: String) -> Bool {
            state.lock()
            defer { state.unlock() }
            return cancelled.contains(key)
        }

        private func write(_ message: JSONValue) {
            var data = message.serialized()
            data.append(0x0A)
            output.lock()
            defer { output.unlock() }
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var offset = 0
                while offset < raw.count {
                    let written = Darwin.write(STDOUT_FILENO, base + offset, raw.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        return
                    }
                    offset += written
                }
            }
        }
    }
}
