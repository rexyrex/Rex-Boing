import AppKit
import Combine
import Foundation

/// The running app's half of the MCP server: answers the bridge an agent
/// runs (`Rex Boing mcp`, see `MCPBridge`) over a local Mach message port.
///
/// A `CFMessagePort` rather than a socket or a file because it is neither:
/// the name lives in this login session's bootstrap namespace, like the
/// distributed notifications the stats broadcast uses, so nothing touches the
/// network or the disk, and the port is gone the moment the app exits. It is
/// a run loop source on the main thread and costs nothing between messages;
/// with agent access switched off it is not created at all.
///
/// The callback runs on the main run loop and must reply before it returns,
/// so it can never wait for a sample. A call that needs one it does not yet
/// have answers "retry in a moment" instead, and the bridge asks again until
/// its own deadline; meanwhile the lease taken by the first ask has switched
/// detailed sampling on, so the sample it is waiting for is on its way.
///
/// The lease is what keeps this cheap: detailed sampling (the full sensor
/// pass, sleep assertions, a process table every tick) runs only from an
/// agent's first call until `leaseFor` seconds after its last, the way the
/// stats broadcast answers only while somebody keeps asking.
@MainActor
final class MCPServer {
    static let leaseFor: TimeInterval = 20
    private static let retryMilliseconds = 400

    private weak var engine: MetricsEngine?
    private var port: CFMessagePort?
    private var source: CFRunLoopSource?
    private var openAttempts = 0
    private var cancellables = Set<AnyCancellable>()

    /// Every message the port has answered since launch, retries included:
    /// what `get_status` shows to prove the port is quiet while no agent asks.
    private var messagesAnswered = 0

    private var leaseUntil: TimeInterval = 0
    private var leaseStartedAt = Date.distantPast
    private var holdingLease = false
    /// Tells a lease's own expiry check from one left over by an earlier lease.
    private var leaseGeneration = 0

    /// Ledger answers by window, briefly: the ledger lives on the sampler
    /// queue, so a usage call starts the query, answers "retry", and is
    /// answered from here on the retry.
    private var usageReports: [Int: (report: AppUsageReport, at: TimeInterval)] = [:]
    private var usagePending = Set<Int>()

    init(engine: MetricsEngine) {
        self.engine = engine
        // `@Published` replays the current value, which opens the port at
        // launch when agent access is on.
        Preferences.shared.$mcpEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                if enabled { self?.open() } else { self?.close() }
            }
            .store(in: &cancellables)
    }

    // MARK: - Port

    private func open() {
        guard port == nil else { return }
        var context = CFMessagePortContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        var shouldFree: DarwinBoolean = false
        let created = CFMessagePortCreateLocal(
            nil, MCPIdentity.portName as CFString,
            { _, _, data, info in
                guard let info else { return nil }
                let request = data.map { $0 as Data } ?? Data()
                // Delivered on the main run loop, where the source was added.
                let reply = MainActor.assumeIsolated {
                    Unmanaged<MCPServer>.fromOpaque(info).takeUnretainedValue().reply(to: request)
                }
                return Unmanaged.passRetained(reply as CFData)
            },
            &context, &shouldFree)
        guard let created else {
            // The name is taken: almost always by the copy this launch is
            // replacing, which has been told to quit and is still on its way
            // out. Keep trying for a while rather than serve nobody.
            openAttempts += 1
            guard openAttempts <= 40 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                MainActor.assumeIsolated {
                    guard Preferences.shared.mcpEnabled else { return }
                    self?.open()
                }
            }
            return
        }
        openAttempts = 0
        let source = CFMessagePortCreateRunLoopSource(nil, created, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.port = created
        self.source = source
    }

    private func close() {
        if let source { CFRunLoopSourceInvalidate(source) }
        if let port { CFMessagePortInvalidate(port) }
        source = nil
        port = nil
        endLease()
    }

    // MARK: - Requests

    /// One message from a bridge, answered with one of `{"result": …}`,
    /// `{"error": {…}}` or `{"retryAfterMs": n}`.
    private func reply(to data: Data) -> Data {
        messagesAnswered += 1
        guard let message = try? JSONValue.parse(data), case .object = message else {
            return MCPToolError(.badInput, "The request was not a JSON object.").json.serialized()
        }
        return answer(message).serialized()
    }

    private func answer(_ message: JSONValue) -> JSONValue {
        guard message["v"]?.intValue == MCPIdentity.portProtocolVersion else {
            return MCPToolError(.internal, "This agent's Rex Boing MCP server is from a different version than the running app. Restart the agent's connection to rex-boing (in Claude Code, /mcp), then call again.").json
        }
        guard let engine, let tool = message["tool"]?.stringValue else {
            return MCPToolError(.badInput, "The request named no tool.").json
        }
        let now = Date()
        let request: MCPRequest
        switch MCPRequest.parse(tool: tool, arguments: message["arguments"]?.objectValue ?? [:], now: now) {
        case .failure(let error): return error.json
        case .success(let parsed): request = parsed
        }

        renewLease()
        if request.needsFreshSample, !hasFreshSample(engine) {
            return ["retryAfterMs": .int(Self.retryMilliseconds)]
        }

        switch request {
        case .snapshot(let sections, let allSensors):
            return ["result": MCPPayload.snapshot(engine.snapshot, sections: sections, allSensors: allSensors, now: now)]
        case .processes(let sortBy, let limit):
            return ["result": MCPPayload.processes(engine.snapshot, sortBy: sortBy, limit: limit, now: now)]
        case .history(let series, let from, let to, let points):
            return ["result": MCPPayload.history(
                fine: engine.history, minute: engine.minuteHistory, series: series,
                from: from, to: to, points: points, sampleInterval: engine.samplingInterval)]
        case .processHistory(let at, let window, let sortBy, let limit):
            // Only just launched (often by this very call): the lease taken
            // above makes the first table a tick or two away, so wait for it
            // rather than answer not_ready.
            if engine.processHistory.samples.isEmpty {
                return ["retryAfterMs": .int(Self.retryMilliseconds)]
            }
            switch MCPPayload.processHistory(
                engine.processHistory.samples, at: at, window: window, sortBy: sortBy, limit: limit, now: now) {
            case .success(let value): return ["result": value]
            case .failure(let error): return error.json
            }
        case .appUsage(let window, let sortBy, let limit):
            return usage(engine, window: window, sortBy: sortBy, limit: limit, now: now)
        case .status:
            return ["result": MCPPayload.status(status(engine, now: now))]
        }
    }

    /// A tick taken since detailed sampling came on, with its rates intact.
    private func hasFreshSample(_ engine: MetricsEngine) -> Bool {
        guard engine.hasReceivedFirstSample, engine.latestTickHasRates,
              let since = engine.detailedSamplingSince else { return false }
        return engine.snapshot.timestamp >= since
    }

    private func usage(
        _ engine: MetricsEngine, window: TimeInterval, sortBy: UsageSort, limit: Int, now: Date
    ) -> JSONValue {
        let key = Int(window.rounded())
        let uptime = ProcessInfo.processInfo.systemUptime
        if let cached = usageReports[key], uptime - cached.at < 2 {
            return ["result": MCPPayload.appUsage(cached.report, sortBy: sortBy, limit: limit, now: now)]
        }
        if usagePending.insert(key).inserted {
            engine.appUsage(over: window) { [weak self] report in
                guard let self else { return }
                let answered = ProcessInfo.processInfo.systemUptime
                self.usagePending.remove(key)
                self.usageReports = self.usageReports.filter { answered - $0.value.at < 10 }
                self.usageReports[key] = (report, answered)
            }
        }
        return ["retryAfterMs": 25]
    }

    private func status(_ engine: MetricsEngine, now: Date) -> MCPPayload.StatusInputs {
        let ring = engine.history.cpu
        let times = ring.timestamps
        let uptime = ProcessInfo.processInfo.systemUptime
        return MCPPayload.StatusInputs(
            snapshot: engine.snapshot,
            hasSample: engine.hasReceivedFirstSample,
            samplingInterval: engine.samplingInterval,
            samplingPaused: engine.isSamplingPaused,
            leaseRemaining: holdingLease ? max(0, leaseUntil - uptime) : nil,
            leaseStartedAt: holdingLease ? leaseStartedAt : nil,
            detailedSamplingSince: engine.detailedSamplingSince,
            messagesAnswered: messagesAnswered,
            fineCoverage: times.first.flatMap { first in times.last.map { (first, $0, ring.count) } },
            minuteCoverage: engine.minuteHistory.coverage,
            processTables: engine.processHistory.samples,
            runningSince: NSRunningApplication.current.launchDate,
            pid: getpid(),
            executablePath: MCPIdentity.executablePath,
            now: now)
    }

    // MARK: - Lease

    private func renewLease() {
        leaseUntil = ProcessInfo.processInfo.systemUptime + Self.leaseFor
        guard !holdingLease, let engine else { return }
        holdingLease = true
        leaseStartedAt = Date()
        leaseGeneration += 1
        engine.beginAgentSampling()
        scheduleLeaseCheck(after: Self.leaseFor, generation: leaseGeneration)
    }

    /// One pending check at a time, re-armed for whatever the latest request
    /// left of the lease: nothing is scheduled at all once it has lapsed.
    private func scheduleLeaseCheck(after delay: TimeInterval, generation: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.holdingLease, self.leaseGeneration == generation else { return }
                let remaining = self.leaseUntil - ProcessInfo.processInfo.systemUptime
                if remaining > 0.05 {
                    self.scheduleLeaseCheck(after: remaining, generation: generation)
                } else {
                    self.endLease()
                }
            }
        }
    }

    private func endLease() {
        guard holdingLease else { return }
        holdingLease = false
        engine?.endAgentSampling()
        usageReports.removeAll()
    }
}
