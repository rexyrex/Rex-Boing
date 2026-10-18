import Foundation
import Combine
import SwiftUI
import AppKit

@MainActor
final class MetricsEngine: ObservableObject {
    @Published private(set) var snapshot = Snapshot()
    /// `snapshot` and history always advance together. Publishing both caused
    /// two ObservableObject invalidations for the entire dashboard per sample;
    /// publishing the snapshot after mutating this value gives views the same
    /// coherent state with one update pass.
    private(set) var history = MetricsHistory()
    @Published private(set) var hasReceivedFirstSample = false

    /// Ranked process tables kept over time, for the inspector.
    ///
    /// A `let` holding its own observable object rather than another
    /// `@Published` value: recording a table should not invalidate the
    /// dashboard's cards, none of which read it.
    let processHistory = ProcessHistory()

    /// How many things on screen want the process table sampled every tick.
    private var liveProcessConsumers = 0
    /// How many actual dashboard surfaces need the detailed sampler pass.
    private var dashboardConsumers = 0

    private let queue = DispatchQueue(label: "com.rexyrex.Zoomies.sampler", qos: .utility)
    private let core = SnapshotSampler()
    private var timer: DispatchSourceTimer?
    private var samplingPaused = false
    private var configuredInterval: TimeInterval = RefreshRate.fast.rawValue
    private var cancellables = Set<AnyCancellable>()
    /// The pids the sampler's application catalogue currently holds, so a
    /// change to the running set sends only what was added or removed.
    private var cataloguedPIDs = Set<Int32>()

    init() {
        configureRunningApplicationCatalogue()

        // `@Published` replays its current value on subscription, so this both
        // installs the observer and starts the first timer.
        Preferences.shared.$refreshInterval
            .removeDuplicates()
            .sink { [weak self] interval in
                // Combine delivers on whatever thread set the value. Prefs are
                // only written from the UI today, but `restart` mutates
                // MainActor state and nothing enforces that for a future
                // caller — hop when needed, stay synchronous when not (the
                // replay above is what arms the first timer during init).
                if Thread.isMainThread {
                    self?.restart(interval: interval)
                } else {
                    DispatchQueue.main.async { self?.restart(interval: interval) }
                }
            }
            .store(in: &cancellables)

        Preferences.shared.$readouts
            .map { $0.contains(.power) }
            .removeDuplicates()
            .sink { [weak self] visible in
                self?.queue.async { [core = self?.core] in
                    core?.menuPowerReadoutVisible = visible
                }
            }
            .store(in: &cancellables)
    }

    /// Resolves LaunchServices metadata once, then keeps it current from events.
    ///
    /// Reading `processIdentifier`, `localizedName` and `bundleIdentifier` from
    /// every `NSRunningApplication` during each process sample causes synchronous
    /// LaunchServices XPC. App launches and exits are rare; mirroring their small
    /// immutable descriptions to the sampler queue makes the common pass a plain
    /// dictionary lookup instead.
    private func configureRunningApplicationCatalogue() {
        let workspace = NSWorkspace.shared
        let applications = workspace.runningApplications
        var initial: [Int32: RunningApplicationMetadata] = [:]
        initial.reserveCapacity(applications.count)
        for application in applications {
            initial[application.processIdentifier] = Self.metadata(for: application)
        }
        let catalogue = initial
        cataloguedPIDs = Set(initial.keys)
        queue.async { [core] in core.replaceRunningApplications(catalogue) }

        // Key-value observation of the running set, not the launch and
        // terminate notifications: those are posted only for apps with a Dock
        // presence (checked on macOS 27 — a background-only app produced
        // neither). The hundred-odd accessory and background-only apps —
        // widget hosts, Quick Look and AutoFill services — were never added
        // when they started or removed when they quit, so their names
        // depended on whether they predated the app, and a recycled pid
        // inherited a dead app's name and bundle identifier.
        workspace.publisher(for: \.runningApplications)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] applications in
                guard let self else { return }
                var current: [Int32: NSRunningApplication] = [:]
                current.reserveCapacity(applications.count)
                for application in applications {
                    current[application.processIdentifier] = application
                }
                let removed = self.cataloguedPIDs.subtracting(current.keys)
                let added = current
                    .filter { !self.cataloguedPIDs.contains($0.key) }
                    .map { ($0.key, Self.metadata(for: $0.value)) }
                guard !removed.isEmpty || !added.isEmpty else { return }
                self.cataloguedPIDs = Set(current.keys)
                self.queue.async { [core = self.core] in
                    for pid in removed {
                        core.updateRunningApplication(pid: pid, metadata: nil)
                    }
                    for (pid, metadata) in added {
                        core.updateRunningApplication(pid: pid, metadata: metadata)
                    }
                }
            }
            .store(in: &cancellables)
    }

    private static func metadata(
        for application: NSRunningApplication
    ) -> RunningApplicationMetadata {
        RunningApplicationMetadata(
            localizedName: application.localizedName,
            bundleIdentifier: application.bundleIdentifier)
    }

    deinit {
        timer?.cancel()
    }

    /// Raises the process table to full sampling rate while something that
    /// reads it is on screen.
    ///
    /// A count rather than a flag, because the dashboard is no longer the only
    /// reader. The inspector opens *from* the dashboard, and the popover is
    /// transient — it closes the instant the window appears. A flag would drop
    /// sampling back to its six-second background cadence at exactly the moment
    /// a window devoted to per-process history had been opened, and the history
    /// would coarsen while the user watched it.
    ///
    /// Every call must be paired with `endLiveProcessSampling`.
    func beginLiveProcessSampling() {
        liveProcessConsumers += 1
        if liveProcessConsumers == 1 { setLiveProcessSampling(true) }
    }

    /// The dashboard needs both live processes and detailed non-process
    /// metrics. The process inspector uses only the former.
    func beginDashboardSampling() {
        dashboardConsumers += 1
        beginLiveProcessSampling()
        if dashboardConsumers == 1 { setDetailedMetricsVisible(true) }
    }

    func endDashboardSampling() {
        guard dashboardConsumers > 0 else { return }
        dashboardConsumers -= 1
        if dashboardConsumers == 0 { setDetailedMetricsVisible(false) }
        endLiveProcessSampling()
    }

    func endLiveProcessSampling() {
        guard liveProcessConsumers > 0 else { return }
        liveProcessConsumers -= 1
        if liveProcessConsumers == 0 { setLiveProcessSampling(false) }
    }

    private func setLiveProcessSampling(_ live: Bool) {
        queue.async { [core] in
            core.liveProcessSampling = live
            if live { core.forceProcessSample = true }
        }
    }

    private func setDetailedMetricsVisible(_ visible: Bool) {
        queue.async { [core] in core.detailedMetricsVisible = visible }
    }

    /// Forces the next tick to treat its window as broken and re-prime every
    /// baseline. Called on system wake: on Apple silicon the uptime clock
    /// keeps advancing through sleep, so a sleep shorter than the gap ceiling
    /// looks like an ordinary window to clock arithmetic — the notification
    /// is the only reliable signal that the interval spans one.
    func noteSystemWake() {
        queue.async { [core] in core.forceResync = true }
    }

    /// Stops all telemetry wakeups while the display is asleep. Counter-based
    /// samplers re-prime themselves on the resync tick after wake.
    func setSamplingPaused(_ paused: Bool) {
        guard samplingPaused != paused else { return }
        samplingPaused = paused
        if paused {
            timer?.cancel()
            timer = nil
        } else {
            // Display sleep can be shorter than the gap ceiling and need not
            // involve system sleep. Always reject the unobserved window, and
            // queue this before the resumed timer or any process-only refresh.
            noteSystemWake()
            restart(interval: configuredInterval)
        }
    }

    /// Which apps did how much work over the trailing `window`, from the
    /// usage ledger. Resolved on the sampler queue — the ledger is confined
    /// there — with the completion delivered on main. Responses come back in
    /// request order, so a caller re-querying on every fresh sample can just
    /// keep the latest.
    func appUsage(
        over window: TimeInterval,
        completion: @escaping @MainActor @Sendable (AppUsageReport) -> Void
    ) {
        queue.async { [core] in
            let report = core.usageLedger.report(window: window)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(report) }
            }
        }
    }

    /// Refreshes the process table out of band, used when the dashboard opens.
    /// Rate-based metrics keep the cadence they are already on.
    func refreshNow() {
        queue.async { [core, weak self] in
            core.forceProcessSample = true
            guard let snapshot = core.refreshProcesses() else { return }
            self?.publish(snapshot, recordHistory: false)
        }
    }

    private func restart(interval: TimeInterval) {
        configuredInterval = interval
        timer?.cancel()
        timer = nil

        guard !samplingPaused else { return }

        let clamped = max(0.25, min(10, interval))
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // Give longer cadences more room to coalesce with the system's other
        // wakeups. The rates use their measured elapsed time, so this improves
        // idle efficiency without biasing any reading.
        let leewayMilliseconds = Int(min(250, max(50, clamped * 100)))
        timer.schedule(
            deadline: .now() + 0.05,
            repeating: clamped,
            leeway: .milliseconds(leewayMilliseconds))
        timer.setEventHandler { [core, weak self] in
            let (snapshot, isResync) = core.tick(refreshInterval: clamped)
            // A resync sample carries no usable rates; recording it would plant
            // a false zero in every throughput and power graph.
            self?.publish(snapshot, recordHistory: !isResync)
        }
        timer.resume()
        self.timer = timer
    }

    /// Called from the sampler queue; hops to main to touch published state.
    ///
    /// `DispatchQueue.main` rather than an unstructured `Task { @MainActor }`,
    /// because concurrently created tasks carry no ordering guarantee between
    /// them: two samples enqueued a second apart could be applied in the wrong
    /// order, which puts a backwards step in every history buffer. A serial
    /// queue delivers in the order it was handed the work.
    nonisolated private func publish(_ snapshot: Snapshot, recordHistory: Bool) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if recordHistory { self.history.record(snapshot) }
                self.snapshot = snapshot
                // Recorded unconditionally, unlike the graph series. Those are
                // rates over the tick's window, which a resync invalidates; the
                // process table carries its own timestamp and its own window,
                // and the store decides for itself whether both are usable.
                // Skipping it here would also lose the out-of-band refresh the
                // dashboard triggers when it opens, which is the freshest table
                // there is.
                self.processHistory.record(snapshot)
                if !self.hasReceivedFirstSample { self.hasReceivedFirstSample = true }
            }
        }
    }
}
