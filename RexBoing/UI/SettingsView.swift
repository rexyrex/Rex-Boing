import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject private var preferences: Preferences
    @EnvironmentObject private var engine: MetricsEngine

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            menuBarTab
                .tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }
            aboutTab
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 560)
        .onAppear { preferences.synchronizeLaunchAtLogin() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            preferences.synchronizeLaunchAtLogin()
        }
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Section {
                Picker("Refresh rate", selection: $preferences.refreshInterval) {
                    ForEach(RefreshRate.allCases) { rate in
                        Text(rate.label).tag(rate.rawValue)
                    }
                }
                Text("Faster sampling reacts sooner but wakes the CPU more often.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Temperature", selection: $preferences.temperatureUnit) {
                    ForEach(TemperatureUnit.allCases) { unit in
                        Text(unit.label).tag(unit)
                    }
                }
                .pickerStyle(.segmented)

                Stepper(
                    "Processes per list: \(preferences.processRowCount)",
                    value: $preferences.processRowCount, in: 3...12)
            }

            Section {
                Toggle("Launch at login", isOn: $preferences.launchAtLogin)
                if preferences.launchAtLoginRequiresApproval {
                    // Registered but switched off in System Settings: the
                    // toggle above cannot turn it back on, and left to snap
                    // off silently it read as broken.
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("Switched off in System Settings. It can only be turned back on there, under General › Login Items.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Button("Open Login Items…") { LoginItem.openSystemSettings() }
                            .controlSize(.small)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Menu bar

    private var menuBarTab: some View {
        Form {
            Section("Visualizer") {
                Toggle("Show visualizer", isOn: $preferences.showVisualizer)

                animationGallery
                    .disabled(!preferences.showVisualizer)

                Picker("Animation", selection: $preferences.animation) {
                    ForEach(AnimationQuality.allCases) { quality in
                        Text(quality.label).tag(quality)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!preferences.showVisualizer)

                Text("\(preferences.visualizer.detail) Its pace tracks total CPU usage. \(preferences.animation.detail)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Section("Readouts") {
                Text("Pick what appears beside the visualizer. Enabled readouts are listed in the order they are drawn, left to right.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                // Enabled readouts float to the top in their drawing order, so
                // the list is a direct picture of the menu bar rather than a
                // fixed catalogue you have to mentally reorder.
                ForEach(orderedReadouts) { readout in
                    let isOn = preferences.readouts.contains(readout)
                    HStack(spacing: 6) {
                        Toggle(isOn: Binding(
                            get: { isOn },
                            set: { _ in preferences.toggle(readout) }
                        )) {
                            Label(readout.label, systemImage: readout.symbol)
                        }

                        if isOn {
                            reorderButton(readout, by: -1, symbol: "chevron.up", help: "Move left")
                            reorderButton(readout, by: 1, symbol: "chevron.down", help: "Move right")
                        }
                    }
                }
            }

            Section {
                Toggle("Monochrome", isOn: $preferences.monochromeMenuBar)
                Text("Keeps the menu bar's own label colour throughout: no colour ramp on the character, no warning tints on hot or saturated readouts.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var animationGallery: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                TimelineView(.animation(minimumInterval: 1.0 / Self.previewFrameRate, paused: !previewMoves)) { timeline in
                    Canvas { context, size in
                        let time = previewMoves
                            ? (timeline.date.timeIntervalSinceReferenceDate - Self.previewEpoch) * previewPace
                            : Visualizer.restingTime
                        context.withCGContext { cg in
                            cg.translateBy(x: 0, y: size.height)
                            cg.scaleBy(x: 1, y: -1)
                            preferences.visualizer.draw(in: cg, rect: CGRect(origin: .zero, size: size),
                                                        time: time, load: 0.45, color: .labelColor)
                        }
                    }
                    .frame(width: 72, height: 44)
                    .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(preferences.visualizer.name).font(.headline)
                    Text("Preview at 45% CPU · \(Visualizer.allCases.count) animations")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(Visualizer.allCases) { visual in
                    let selected = preferences.visualizer == visual
                    Button {
                        preferences.visualizer = visual
                    } label: {
                        VStack(spacing: 4) {
                            Image(nsImage: VisualizerIcon.image(for: visual))
                                .resizable().frame(width: 36, height: 22)
                            Text(visual.name).font(.system(size: 11, weight: selected ? .semibold : .regular))
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 7)
                        .background(selected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.035),
                                    in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .help(visual.detail)
                    .accessibilityLabel(visual.name)
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                }
            }
        }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var previewMoves: Bool {
        preferences.showVisualizer && preferences.animation != .off && !reduceMotion
    }

    /// The preview's own frame rate. Thirty, not fifteen: the preview clock
    /// ran at half the menu bar's Smooth ceiling, and at the mid-range load
    /// it previews every character was already past the pace fifteen frames
    /// can show — a strobing preview of an animation that does not strobe.
    private static let previewFrameRate = 30.0

    /// Clock origin for the preview, so the timeline's seconds-since-2001
    /// are not fed straight into the trigonometry at full magnitude.
    private static let previewEpoch = Date().timeIntervalSinceReferenceDate

    /// The pace the menu bar would run at the preview's load and this
    /// quality setting, clamped the way the status item clamps it — so the
    /// preview shows the speed the setting actually buys, and never a pace
    /// its own frame rate would alias.
    private var previewPace: Double {
        let desired = preferences.visualizer.rate(
            forLoad: 0.45, speedFactor: preferences.animation.paceFactor)
        return min(desired, Self.previewFrameRate / Visualizer.minimumFramesPerCycle)
    }

    private var orderedReadouts: [MenuBarReadout] {
        preferences.readouts
            + MenuBarReadout.allCases.filter { !preferences.readouts.contains($0) }
    }

    private func reorderButton(
        _ readout: MenuBarReadout, by offset: Int, symbol: String, help: String
    ) -> some View {
        Button {
            preferences.move(readout, by: offset)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .frame(width: 16, height: 14)
        }
        .buttonStyle(.borderless)
        .disabled(!preferences.canMove(readout, by: offset))
        .help(help)
        .accessibilityLabel("\(help): \(readout.label)")
    }

    // MARK: - About

    private var aboutTab: some View {
        VStack(spacing: 12) {
            Spacer()

            // The app's own icon — drawn from the same rex code as the menu
            // bar — rather than a stand-in symbol.
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)

            Text("Rex Boing")
                .font(.system(size: 20, weight: .semibold))

            Text("Version \(version)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Text(capabilities)
                .font(.system(size: 10.5))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 30)
                .padding(.top, 4)
                .textSelection(.enabled)

            Spacer()

            HStack(spacing: 10) {
                // Which sources resolved is the first thing worth knowing when
                // a reading is missing, so it is one click to hand over rather
                // than something to transcribe from a settings pane.
                Button("Copy Diagnostics") { copyDiagnostics() }
                Button("Quit Rex Boing") { NSApp.terminate(nil) }
            }
            .padding(.bottom, 16)
        }
    }

    private func copyDiagnostics() {
        let host = engine.snapshot.host
        let text = """
            Rex Boing \(version)
            \(host.modelName) (\(host.modelIdentifier)) · macOS \(host.osVersion)
            \(host.chipName) · \(host.physicalCores)P/\(host.logicalCores)L cores · \(Format.bytes(host.memoryBytes))
            \(capabilities)
            """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    /// Which optional data sources actually resolved on this machine — useful
    /// when a reading is missing and you want to know whether that is a bug or
    /// simply unsupported hardware.
    private var capabilities: String {
        let snapshot = engine.snapshot
        var available: [String] = []
        var missing: [String] = []

        func record(_ name: String, _ ok: Bool) {
            if ok { available.append(name) } else { missing.append(name) }
        }

        record("GPU utilisation", snapshot.gpu.available)
        record("Temperature sensors", !snapshot.thermal.sensors.isEmpty)
        record("Fans", !snapshot.thermal.fans.isEmpty)
        record("Power", snapshot.power.hasAny)
        record("CPU clocks", snapshot.cpu.performanceClockMHz != nil)
        record("Per-process GPU", snapshot.processes.gpuAttributionAvailable)
        record("Battery", snapshot.battery.present)

        var text = "Available: " + (available.isEmpty ? "—" : available.joined(separator: ", "))
        if !missing.isEmpty {
            text += "\nNot reported by this Mac: " + missing.joined(separator: ", ")
        }
        return text
    }
}

// MARK: - Visualizer icons

/// The animation gallery icons: a still frame of each visualiser, drawn by the
/// very code that draws the menu bar, so the row shows the thing it selects
/// rather than an SF Symbol standing in for it. Because it shares
/// `Visualizer.draw`, it can never drift from what the bar shows.
///
@MainActor
enum VisualizerIcon {
    /// Use the same proportions as the menu bar.
    private static let size = Visualizer.canvasSize

    /// The pose is the same still every visualiser rests in, at a mid-range
    /// load — enough amplitude to show the motion's character.
    private static var cache: [Visualizer: NSImage] = [:]
    private static var menuCache: [Visualizer: NSImage] = [:]

    static func image(for visual: Visualizer) -> NSImage {
        if let cached = cache[visual] { return cached }
        let image = make(visual, size: size)
        cache[visual] = image
        return image
    }

    /// The same still at menu-row height, for the status item's Character
    /// submenu. A separate image rather than a resized one: `NSImage.size`
    /// is shared state, and the gallery scales the full-size one itself.
    static func menuImage(for visual: Visualizer) -> NSImage {
        if let cached = menuCache[visual] { return cached }
        let image = make(visual, size: NSSize(width: 26, height: 16))
        menuCache[visual] = image
        return image
    }

    private static func make(_ visual: Visualizer, size: NSSize) -> NSImage {
        // Drawn in plain black and marked as a template: only the alpha
        // matters, and the menu tints it to match the row — including the
        // punched-out eye, which stays a hole whatever the tint.
        let image = NSImage(size: size, flipped: false) { rect in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            visual.draw(
                in: cg, rect: rect,
                time: Visualizer.restingTime, load: 0.45, color: .black)
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// Hosts the settings window. An accessory app has no main window, so this is
/// created on demand and kept alive between openings.
///
/// The window is reused; its SwiftUI content is not. The About tab reads the
/// live snapshot, so a hosting view left in a closed-but-retained window would
/// keep observing the engine and re-evaluating once per sample for the rest of
/// the app's life. Content is built on show and released on close.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show(engine: MetricsEngine) {
        NSApp.activate(ignoringOtherApps: true)

        if let window {
            if window.contentViewController == nil {
                window.contentViewController = makeContent(engine: engine)
            }
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(contentViewController: makeContent(engine: engine))
        window.title = "Rex Boing Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)

        self.window = window
    }

    private func makeContent(engine: MetricsEngine) -> NSViewController {
        NSHostingController(
            rootView: SettingsView()
                .environmentObject(Preferences.shared)
                .environmentObject(engine))
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentViewController = nil
    }
}
