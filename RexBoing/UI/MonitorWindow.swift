import SwiftUI
import AppKit
import Combine

// The Monitor window: everything the popover knows, open at once.
//
// The popover is built to be glanced at and dismissed — it is transient, a
// fixed 560 points wide, and folds each card's detail away so the whole
// machine fits in a screenful. This is the other way to use the same data: a
// real window that stays where it is put, on a second display or beside the
// work it is watching. It leads with a strip of headline readings, lays the
// cards out in as many columns as its width allows with their detail open,
// and can stretch its graphs from the last minute and a half to the whole
// ten minutes the history keeps.

// MARK: - Feed

/// What the Monitor window draws from, in place of the engine itself.
///
/// The window can sit minimised, on another Space or behind a full-screen
/// app for days. A view observing the engine directly would re-evaluate every
/// card on every sample for all of that time, drawing nothing — the cost the
/// popover avoids by not existing while it is closed. A window cannot do
/// that without losing its scroll position and every picker's selection, so
/// instead the subscription is what goes: paused, this publishes nothing, and
/// a hidden window costs what a closed one does.
@MainActor
final class MonitorFeed: ObservableObject {
    @Published private(set) var snapshot: Snapshot
    /// Advances with `snapshot`, never on its own, so it needs no publisher.
    private(set) var history: MetricsHistory
    @Published private(set) var isReady: Bool

    private let engine: MetricsEngine
    private var subscription: AnyCancellable?

    init(engine: MetricsEngine) {
        self.engine = engine
        snapshot = engine.snapshot
        history = engine.history
        isReady = engine.hasReceivedFirstSample
    }

    func resume() {
        guard subscription == nil else { return }
        pull()
        // A turn of the main queue later rather than inside the engine's own
        // assignment: by then the history, the process history and the
        // first-sample flag have all caught up with the snapshot.
        subscription = engine.$snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.pull() }
    }

    func pause() {
        subscription = nil
    }

    private func pull() {
        history = engine.history
        snapshot = engine.snapshot
        if isReady != engine.hasReceivedFirstSample { isReady = engine.hasReceivedFirstSample }
    }
}

// MARK: - View

struct MonitorView: View {
    @ObservedObject var feed: MonitorFeed
    /// Asked for app usage and handed to the inspector — never observed; the
    /// feed above is the window's one source of invalidation.
    let engine: MetricsEngine

    @EnvironmentObject private var preferences: Preferences

    private var snapshot: Snapshot { feed.snapshot }
    private var history: MetricsHistory { feed.history }
    private var unit: TemperatureUnit { preferences.temperatureUnit }

    var body: some View {
        VStack(spacing: 0) {
            if feed.isReady {
                board
                Divider().opacity(0.5)
                footer
            } else {
                placeholder
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .background(backdrop)
        .navigationTitle("Rex Boing")
        .navigationSubtitle(machine)
        .toolbar { toolbar }
        .environment(\.dashboardStyle, .window)
        .environment(\.graphSpan, preferences.monitorSpan)
        // The same window every graph in the popover opens — here it stays
        // beside this one rather than replacing a popover that just closed.
        .environment(\.inspectGraph, InspectGraphAction { [engine] metric, date in
            ProcessInspectorWindowController.shared.show(
                engine: engine, metric: metric, at: date)
        })
    }

    // MARK: Board

    private var board: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 14) {
                    VitalsStrip(
                        snapshot: snapshot, history: history, unit: unit,
                        span: preferences.monitorSpan)

                    columns(MonitorColumns.count(for: proxy.size.width))
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 16)
            }
        }
    }

    /// The cards, dealt into columns by hand rather than flowed.
    ///
    /// A flow that sent each card to the shortest column would reshuffle them
    /// whenever one changed height — a sensor list opening, a sleep blocker
    /// appearing — and a card that jumps columns under the pointer is worse
    /// than a ragged foot. Fixed columns, weighed for the heights the cards
    /// usually have, leave every card where it was last seen.
    @ViewBuilder
    private func columns(_ count: Int) -> some View {
        let spacing = DashboardStyle.window.sectionSpacing
        switch count {
        case 3:
            HStack(alignment: .top, spacing: spacing) {
                column { processor; memory }
                column { graphics; thermals; power }
                column { processes; network; storage }
            }
        case 2:
            HStack(alignment: .top, spacing: spacing) {
                column { processor; memory; thermals; power }
                column { graphics; processes; network; storage }
            }
        default:
            column {
                processor; graphics; memory; thermals
                processes; power; network; storage
            }
        }
    }

    private func column<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: DashboardStyle.window.sectionSpacing) { content() }
            .frame(maxWidth: .infinity, alignment: .top)
    }

    // Each card at its own height. A row of columns proposes the tallest
    // one's height to all of them, and a card stretches to accept whatever it
    // is offered — which, unpinned, left the shorter columns' cards padded
    // out with empty ground to make the feet line up.

    private var processor: some View {
        CPUCard(snapshot: snapshot, history: history, unit: unit)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var graphics: some View {
        GPUCard(snapshot: snapshot, history: history, unit: unit)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var memory: some View {
        MemoryCard(snapshot: snapshot, history: history)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var thermals: some View {
        ThermalCard(snapshot: snapshot, history: history, unit: unit)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var power: some View {
        PowerCard(snapshot: snapshot, history: history, unit: unit)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var network: some View {
        NetworkCard(snapshot: snapshot, history: history)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var storage: some View {
        StorageCard(snapshot: snapshot, history: history)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A dozen rows at least: the popover's count is sized for a panel that
    /// has to fit a screenful, and a window has the height to rank deeper.
    private var processes: some View {
        ProcessesCard(
            usage: AppUsageQuery { [engine] window, completion in
                engine.appUsage(over: window, completion: completion)
            },
            snapshot: snapshot,
            rowCount: max(preferences.processRowCount, 12))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Taking the first sample…")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The window's own ground, with the brand blue let into the top of it —
    /// enough to set the strip of tiles on something, not enough to tint them.
    private var backdrop: some View {
        ZStack(alignment: .top) {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(
                colors: [Palette.cpu.opacity(0.10), Palette.cpu.opacity(0)],
                startPoint: .top, endPoint: .bottom)
                .frame(height: 260)
        }
        .ignoresSafeArea()
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            // The character on duty, running here at the pace it runs in the
            // menu bar — the window's proof of life, and the one thing in it
            // that says how busy the Mac is without a number.
            RexMascot(
                visualizer: preferences.visualizer,
                load: snapshot.cpu.total,
                animated: preferences.animation.isAnimated,
                color: Palette.cpu)
                .padding(.horizontal, 4)
                .help("\(preferences.visualizer.name) — pace follows CPU load")
        }

        ToolbarItem(placement: .primaryAction) {
            Picker("History", selection: $preferences.monitorSpan) {
                ForEach(MonitorSpan.options, id: \.self) { samples in
                    Text(MonitorSpan.label(
                        samples: samples, interval: preferences.refreshInterval))
                        .tag(samples)
                }
            }
            .pickerStyle(.segmented)
            .help("How much history the graphs show")
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                let latest = engine.processHistory.samples.last?.timestamp ?? Date()
                ProcessInspectorWindowController.shared.show(
                    engine: engine, metric: .cpu, at: latest)
            } label: {
                Label("Process Breakdown", systemImage: "list.bullet.rectangle")
            }
            .help("Every process, with all its measures side by side")
        }

        ToolbarItem(placement: .primaryAction) {
            Toggle(isOn: $preferences.monitorFloats) {
                Label("Keep on Top", systemImage: preferences.monitorFloats ? "pin.fill" : "pin")
            }
            .help("Keep this window above the others")
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                SettingsWindowController.shared.show(engine: engine)
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Settings")
        }
    }

    // MARK: Footer

    /// What the cards take for granted: how fresh the numbers are, and the
    /// two verdicts — thermal and memory pressure — that the OS itself gives.
    private var footer: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Palette.calm)
                    .frame(width: 7, height: 7)
                Text("Live · every \(cadence)")
            }
            .help("Sampled at the refresh rate set in Settings")

            // The counts are the first thing to go when the window is
            // narrow: the processor card carries them too.
            ViewThatFits(in: .horizontal) {
                footerDetail(counts: true)
                footerDetail(counts: false)
            }
        }
        .font(.system(size: 11))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(.bar)
    }

    private func footerDetail(counts: Bool) -> some View {
        HStack(spacing: 14) {
            if counts {
                Text("\(snapshot.cpu.processCount) processes · \(snapshot.cpu.threadCount) threads")
            }

            FooterVerdict(
                label: "Thermal", value: snapshot.thermal.thermalState.label,
                severity: .thermal(snapshot.thermal.thermalState))
            FooterVerdict(
                label: counts ? "Memory pressure" : "Memory", value: snapshot.memory.pressureLevel.label,
                severity: .memory(snapshot.memory.pressureLevel))

            Spacer(minLength: 8)

            Text("macOS \(snapshot.host.osVersion) · up \(Format.duration(snapshot.host.uptime))")
                .help(hostDetail)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// "1 s", "0.5 s" — the refresh rate as Settings words it.
    private var cadence: String {
        let interval = preferences.refreshInterval
        return interval == interval.rounded()
            ? "\(Int(interval)) s" : String(format: "%.1f s", interval)
    }

    /// The machine in one line, under the window's title.
    private var machine: String {
        let host = snapshot.host
        var parts: [String] = [host.modelName]
        if !host.chipName.isEmpty { parts.append(host.chipName) }
        if host.isAppleSilicon, host.efficiencyCores > 0 {
            parts.append("\(host.performanceCores)P + \(host.efficiencyCores)E")
        } else if host.logicalCores > 0 {
            parts.append("\(host.logicalCores) cores")
        }
        if host.memoryBytes > 0 { parts.append(Format.bytes(host.memoryBytes)) }
        return parts.joined(separator: " · ")
    }

    private var hostDetail: String {
        let host = snapshot.host
        return """
            \(host.modelName) (\(host.modelIdentifier))
            \(host.chipName) · \(host.physicalCores) physical / \(host.logicalCores) logical cores
            """
    }
}

/// One of the operating system's own verdicts, coloured only when it is not
/// the calm one.
private struct FooterVerdict: View {
    var label: String
    var value: String
    var severity: Severity

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
            Text(value)
                .fontWeight(.medium)
                .foregroundStyle(severity == .calm ? Color.primary.opacity(0.8) : severity.swiftUIColor)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Window

/// Hosts the Monitor window: one, reused, with its SwiftUI content built on
/// show and released on close, like every other window here.
///
/// While it is open the app is an ordinary one — a Dock icon, a menu bar of
/// its own, a place in ⌘-Tab and Mission Control — because a window that
/// stays open all day has to be findable the way windows are. It goes back
/// to being a menu bar item when the window closes.
@MainActor
final class MonitorWindowController: NSObject, NSWindowDelegate {
    static let shared = MonitorWindowController()

    private static let frameName = "RexBoingMonitor"

    private var window: NSWindow?
    private var engine: MetricsEngine?
    private var feed: MonitorFeed?
    /// Whether this window is holding the dashboard's detailed sampling.
    private var holdingSampling = false
    private var floats: AnyCancellable?

    /// On screen, minimised, or on another Space — anything but closed.
    var isOpen: Bool { window?.contentViewController != nil }

    func show(engine: MetricsEngine) {
        self.engine = engine
        NSApp.setActivationPolicy(.regular)

        let window = self.window ?? makeWindow()
        if window.contentViewController == nil {
            install(in: window, engine: engine)
        }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // The occlusion notification that would start the feed has not
        // arrived yet for a window ordered in this turn; do not open on a
        // stale frame waiting for it.
        setLive(true)
    }

    func close() {
        window?.performClose(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Rex Boing"
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.delegate = self
        self.window = window

        floats = Preferences.shared.$monitorFloats
            .sink { [weak window] floats in
                window?.level = floats ? .floating : .normal
            }
        return window
    }

    private func install(in window: NSWindow, engine: MetricsEngine) {
        let feed = MonitorFeed(engine: engine)
        self.feed = feed
        let hosting = NSHostingController(
            rootView: MonitorView(feed: feed, engine: engine)
                .environmentObject(Preferences.shared))
        // The title, subtitle and toolbar are SwiftUI's to fill in; the size
        // is not. Left to its defaults the controller resizes the window to
        // the view's ideal size every time it is assigned.
        hosting.sceneBridgingOptions = [.title, .toolbars]
        hosting.sizingOptions = [.minSize]

        window.contentViewController = hosting
        // Where it was last left — saved as it moves and again as it closes —
        // or, the first time, a default in the middle of the screen.
        if !window.setFrameUsingName(Self.frameName) {
            window.setContentSize(Self.defaultSize(on: window.screen ?? NSScreen.main))
            window.center()
        }
        window.setFrameAutosaveName(Self.frameName)
    }

    /// Three columns of cards where the screen has the room, never larger
    /// than the screen itself.
    private static func defaultSize(on screen: NSScreen?) -> NSSize {
        let visible = screen?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        return NSSize(
            width: min(1280, visible.width - 80),
            height: min(860, visible.height - 80))
    }

    // MARK: Liveness

    /// Detailed sampling and the feed run only while the window can be seen.
    private func setLive(_ live: Bool) {
        guard let engine, let feed else { return }
        if live, !holdingSampling {
            holdingSampling = true
            engine.beginDashboardSampling()
            engine.refreshNow()
            feed.resume()
        } else if !live, holdingSampling {
            holdingSampling = false
            feed.pause()
            engine.endDashboardSampling()
        }
    }

    /// A minimised, covered or other-Space window shows nothing, so it gives
    /// the detailed sampling back and stops redrawing; the menu bar's own
    /// cadence keeps the history filling for when it is seen again.
    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window, window.contentViewController != nil else { return }
        setLive(window.occlusionState.contains(.visible))
    }

    func windowWillClose(_ notification: Notification) {
        window?.saveFrame(usingName: Self.frameName)
        setLive(false)
        // Released with the window, for the reason the popover's is: a
        // hosting view left in a closed-but-retained window keeps its whole
        // SwiftUI graph alive.
        window?.contentViewController = nil
        feed = nil

        // Back to a menu bar item once the close has finished. Settings or
        // the process breakdown can still be open; they stay, as they do
        // when opened from the menu bar.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard !MonitorWindowController.shared.isOpen else { return }
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}
