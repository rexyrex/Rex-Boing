import AppKit
import Combine

/// Lets another app on this Mac show Rex Boing's headline readings — the
/// Stream Deck keys of Mac Studio Project Manager's Agent Deck, for one.
///
/// An app that wants them posts the `request` distributed notification; for
/// `answerFor` seconds after the latest request, each new sample is posted
/// back as the `stats` notification, at most once every `minimumInterval`,
/// with a small JSON object in `userInfo["payload"]`. The asker repeats its
/// request while it is still interested.
///
/// Distributed notifications are local to this login session: nothing here
/// touches the network or the disk, and nothing is posted (or even observed
/// from the engine) while nobody is asking. The payload is the dozen numbers
/// the menu bar already shows — no process names, no command lines.
@MainActor
final class StatsBroadcaster: NSObject {
    static let request = Notification.Name("com.rexyrex.Zoomies.stats.request")
    static let stats = Notification.Name("com.rexyrex.Zoomies.stats")
    static let payloadKey = "payload"
    static let answerFor: TimeInterval = 30
    static let minimumInterval: TimeInterval = 2

    private weak var engine: MetricsEngine?
    private var samples: AnyCancellable?
    private var answerUntil: TimeInterval = 0
    private var lastSent: TimeInterval = 0

    init(engine: MetricsEngine) {
        self.engine = engine
        super.init()
        // deliverImmediately: a menu bar app is never the active one, and a
        // distributed notification otherwise waits until its receiver is.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(requested(_:)), name: Self.request, object: nil,
            suspensionBehavior: .deliverImmediately)
    }

    // Delivered on the main run loop, where the observer was added.
    @objc nonisolated private func requested(_ note: Notification) {
        MainActor.assumeIsolated { answer() }
    }

    private func answer() {
        answerUntil = ProcessInfo.processInfo.systemUptime + Self.answerFor
        guard samples == nil, let engine else { return }
        // `@Published` replays the current sample on subscription, which is
        // the asker's first answer.
        samples = engine.$snapshot.sink { [weak self] snapshot in
            // The engine only ever sets `snapshot` on the main actor.
            MainActor.assumeIsolated { self?.sampled(snapshot) }
        }
    }

    private func sampled(_ snapshot: Snapshot) {
        let uptime = ProcessInfo.processInfo.systemUptime
        guard uptime <= answerUntil else {
            // Nobody has asked for a while. Dropped on the next turn of the
            // run loop: a subscription can't be released from inside its own
            // delivery.
            DispatchQueue.main.async { [weak self] in
                guard let self, ProcessInfo.processInfo.systemUptime > self.answerUntil else { return }
                self.samples = nil
            }
            return
        }
        guard engine?.hasReceivedFirstSample == true, uptime - lastSent >= Self.minimumInterval - 0.05,
              let payload = Self.payload(for: snapshot) else { return }
        lastSent = uptime
        DistributedNotificationCenter.default().postNotificationName(
            Self.stats, object: nil, userInfo: [Self.payloadKey: payload], deliverImmediately: true)
    }

    /// The reading as compact JSON. A value this Mac has no source for (no
    /// fans, no power rail, no GPU counter) is left out rather than sent as 0.
    nonisolated static func payload(for snapshot: Snapshot) -> String? {
        var object: [String: Any] = [
            "v": 1,
            "ts": snapshot.timestamp.timeIntervalSince1970,
            "cpu": snapshot.cpu.total,
            "memUsed": Double(snapshot.memory.used),
            "memTotal": Double(snapshot.memory.total),
            "memPressure": snapshot.memory.pressure,
            "netRx": snapshot.network.rxBytesPerSecond,
            "netTx": snapshot.network.txBytesPerSecond,
            "diskRead": snapshot.disk.readBytesPerSecond,
            "diskWrite": snapshot.disk.writeBytesPerSecond,
        ]
        func set(_ key: String, _ value: Double?) {
            if let value { object[key] = value }
        }
        set("gpu", snapshot.gpu.available ? snapshot.gpu.utilization : nil)
        set("cpuTemp", snapshot.thermal.cpuCelsius)
        set("gpuTemp", snapshot.thermal.gpuCelsius)
        set("hotTemp", snapshot.thermal.peakCelsius)
        set("fanRPM", snapshot.thermal.fans.map(\.rpm).max())
        set("watts", snapshot.power.totalWatts)
        // JSON has no NaN or infinity, and one would make the whole object unencodable.
        object = object.filter { _, value in (value as? Double)?.isFinite ?? true }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
