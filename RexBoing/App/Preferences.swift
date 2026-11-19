import Foundation
import Combine
import SwiftUI

/// A readout that can be pinned next to the visualiser in the menu bar.
enum MenuBarReadout: String, CaseIterable, Identifiable, Codable {
    case cpu
    case gpu
    case memory
    case swap
    case cpuTemperature
    case gpuTemperature
    case power
    case network
    case disk
    case battery

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cpu: return "CPU load"
        case .gpu: return "GPU load"
        case .memory: return "Memory used"
        case .swap: return "Swap used"
        case .cpuTemperature: return "CPU temperature"
        case .gpuTemperature: return "GPU temperature"
        case .power: return "Power draw"
        case .network: return "Network throughput"
        case .disk: return "Disk throughput"
        case .battery: return "Battery charge"
        }
    }

    var symbol: String {
        switch self {
        case .cpu: return "cpu"
        case .gpu: return "cube.transparent"
        case .memory: return "memorychip"
        case .swap: return "arrow.left.arrow.right.square"
        case .cpuTemperature: return "thermometer.medium"
        case .gpuTemperature: return "thermometer.sun"
        case .power: return "bolt"
        case .network: return "network"
        case .disk: return "internaldrive"
        case .battery: return "battery.100"
        }
    }

    /// Caption drawn above the value. Spelled out rather than initialled: a
    /// lone "C" over a percentage is a puzzle at a glance, and the caption is
    /// set four sizes down from the value, so a three or four letter word costs
    /// nothing — the column is already as wide as "100%".
    var badge: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .memory: return "MEM"
        case .swap: return "SWAP"
        case .cpuTemperature: return "CPU°"
        case .gpuTemperature: return "GPU°"
        case .power: return "PWR"
        case .network: return "NET"
        case .disk: return "DISK"
        case .battery: return "BATT"
        }
    }
}

/// How smoothly the visualiser animates.
///
/// This used to be a real power trade-off: animating a status item cost about a
/// quarter of a percent of a CPU core per frame per second, almost all of it
/// inside AppKit's own update path, where each new image made it push scene
/// settings to the window server and wait on a CoreAnimation fence. Drawing
/// cheaper frames did not help — drawing fewer of them did.
///
/// Presenting the frame as layer contents instead of through `button.image`
/// sidesteps that path entirely. What is left — drawing a few dozen strokes
/// into a reused bitmap — costs little enough that the ceiling is a preference
/// about how the visualiser should look rather than a decision about battery
/// life.
enum AnimationQuality: String, CaseIterable, Identifiable {
    case off
    case economical
    case smooth
    case fluid

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "Off"
        case .economical: return "Economical"
        case .smooth: return "Smooth"
        case .fluid: return "Fluid"
        }
    }

    var detail: String {
        switch self {
        case .off: return "A still pose. Sampling only."
        case .economical: return "Up to 15 fps. The lightest setting the motion still reads at."
        case .smooth: return "Up to 30 fps. The default, and the right one for almost everything."
        case .fluid: return "Up to 60 fps, in step with the display. Smoothest, twice the top speed, and the only one a busy Mac drives flat out."
        }
    }

    /// The ceiling only. The frame rate the display link is actually asked for
    /// follows the motion — see `StatusItemController.animationRate` — so a
    /// resting visualiser does not wake the machine sixty times a second to
    /// inch a trotting rex across the bar.
    var maximumFrameRate: Double {
        switch self {
        case .off: return 0
        case .economical: return 15
        case .smooth: return 30
        case .fluid: return 60
        }
    }

    /// How many frames the setting would like to spend on one cycle of the
    /// motion.
    ///
    /// This is what the setting actually buys. Raising the ceiling alone
    /// achieves nothing, because the requested rate is derived from the motion
    /// and none of the visualisers ask for more than about two cycles a
    /// second: a 60 fps ceiling would simply never be reached. Asking for more
    /// frames *per cycle* is what turns the extra headroom into smoothness.
    var framesPerCycle: Double {
        switch self {
        case .off: return 0
        case .economical: return 11
        case .smooth: return 18
        case .fluid: return 26
        }
    }

    /// The preset's scale on the visualisers' top speed.
    ///
    /// Each visualiser's `maxRate` is tuned against Smooth's displayable
    /// ceiling, and the pace clamp — `fps / minimumFramesPerCycle` — means a
    /// preset can only ever show so many cycles a second. Scaling the ceiling
    /// to the preset, half for Economical and double for Fluid, keeps the
    /// load-to-pace line running its full course at every quality instead of
    /// hitting the clamp at part load and flattening — and it is what makes
    /// Fluid genuinely the fastest setting rather than merely the smoothest.
    var paceFactor: Double {
        switch self {
        case .off: return 0
        case .economical: return 0.5
        case .smooth: return 1.0
        case .fluid: return 2.0
        }
    }

    var isAnimated: Bool { self != .off }
}

enum RefreshRate: Double, CaseIterable, Identifiable {
    case turbo = 0.5
    case fast = 1.0
    case balanced = 2.0
    case relaxed = 3.0
    case gentle = 5.0

    var id: Double { rawValue }

    var label: String {
        switch self {
        case .turbo: return "0.5s — Turbo"
        case .fast: return "1s — Fast"
        case .balanced: return "2s — Balanced"
        case .relaxed: return "3s — Relaxed"
        case .gentle: return "5s — Gentle"
        }
    }
}

/// How much history the Monitor window's graphs show.
///
/// Counted in samples, because that is what the history keeps, and labelled
/// in time, because that is what a person chooses between — so the same
/// three choices read "90 s · 5 min · 10 min" at the default one-second
/// cadence and stretch with a slower one rather than promising minutes the
/// buffer does not hold.
enum MonitorSpan {
    /// The popover's span, a longer look, and everything the history keeps
    /// (`MetricsHistory.compactSpan` and `MetricsHistory.capacity`; spelled
    /// out so the headless checks can compile this file without the model).
    static let options = [90, 300, 600]

    static func label(samples: Int, interval: TimeInterval) -> String {
        let seconds = Double(samples) * interval
        guard seconds >= 100 else { return "\(Int(seconds.rounded())) s" }
        let minutes = seconds / 60
        return abs(minutes - minutes.rounded()) < 0.05
            ? "\(Int(minutes.rounded())) min"
            : String(format: "%.1f min", minutes)
    }
}

/// User-facing settings, persisted in `UserDefaults` and observable from both
/// SwiftUI and the AppKit status item.
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let refreshInterval = "refreshInterval"
        static let temperatureUnit = "temperatureUnit"
        static let visualizer = "visualizer"
        static let readouts = "menuBarReadouts"
        static let monochrome = "monochromeMenuBar"
        static let animation = "animationQuality"
        static let showVisualizer = "showVisualizer"
        static let processRowCount = "processRowCount"
        static let launchAtLogin = "launchAtLogin"
        static let monitorSpan = "monitorSpan"
        static let monitorFloats = "monitorFloats"
        static let openMonitorAtLaunch = "openMonitorAtLaunch"
        static let mcpEnabled = "mcpEnabled"
    }

    @Published var refreshInterval: Double {
        didSet { defaults.set(refreshInterval, forKey: Key.refreshInterval) }
    }

    @Published var temperatureUnit: TemperatureUnit {
        didSet { defaults.set(temperatureUnit.rawValue, forKey: Key.temperatureUnit) }
    }

    @Published var visualizer: Visualizer {
        didSet { defaults.set(visualizer.rawValue, forKey: Key.visualizer) }
    }

    @Published var readouts: [MenuBarReadout] {
        didSet { defaults.set(readouts.map(\.rawValue), forKey: Key.readouts) }
    }

    @Published var monochromeMenuBar: Bool {
        didSet { defaults.set(monochromeMenuBar, forKey: Key.monochrome) }
    }

    @Published var animation: AnimationQuality {
        didSet { defaults.set(animation.rawValue, forKey: Key.animation) }
    }

    @Published var showVisualizer: Bool {
        didSet { defaults.set(showVisualizer, forKey: Key.showVisualizer) }
    }

    @Published var processRowCount: Int {
        didSet {
            // Clamped on every write, not only at launch: an out-of-range
            // assignment would otherwise be published and persisted until the
            // next start. Assigning here re-enters `didSet` (wrapped properties
            // do not get the stored-property exemption); the second pass sees
            // an in-range value and falls through to persist it.
            let clamped = min(12, max(3, processRowCount))
            if clamped != processRowCount {
                processRowCount = clamped
                return
            }
            defaults.set(processRowCount, forKey: Key.processRowCount)
        }
    }

    /// How many samples the Monitor window's graphs plot — one of
    /// `MonitorSpan.options`.
    @Published var monitorSpan: Int {
        didSet { defaults.set(monitorSpan, forKey: Key.monitorSpan) }
    }

    /// Whether the Monitor window floats above other windows.
    @Published var monitorFloats: Bool {
        didSet { defaults.set(monitorFloats, forKey: Key.monitorFloats) }
    }

    /// Whether launching the app opens the Monitor window as well as putting
    /// the rex in the menu bar.
    @Published var openMonitorAtLaunch: Bool {
        didSet { defaults.set(openMonitorAtLaunch, forKey: Key.openMonitorAtLaunch) }
    }

    /// Whether AI agents may read this Mac's readings over MCP. On by default:
    /// registering the server with an agent is the opt-in, and any process of
    /// this user can already read the same counters for itself.
    ///
    /// The one setting watched for changes made outside the app. The bridge
    /// an agent runs reads this key straight from the preferences domain to
    /// answer `disabled`, so the app has to agree with whatever is stored
    /// there, including a `defaults write` made while it runs.
    @Published var mcpEnabled: Bool {
        didSet {
            if defaults.object(forKey: Key.mcpEnabled) as? Bool != mcpEnabled {
                defaults.set(mcpEnabled, forKey: Key.mcpEnabled)
            }
        }
    }

    private var mcpEnabledObservation: NSKeyValueObservation?

    /// Guards `launchAtLogin`'s revert against its own observer. Assigning a
    /// wrapped property inside `didSet` runs `didSet` again, and that second
    /// pass must not touch ServiceManagement: `setEnabled(false)` unregisters a
    /// `.requiresApproval` item, which would delete the very registration the
    /// user is being sent to System Settings to approve.
    private var isSyncingLoginItem = false

    /// True while the login item is registered but disabled in System
    /// Settings. Read-only here: only the user, in System Settings, can
    /// change it — the settings pane shows the way there.
    @Published private(set) var launchAtLoginRequiresApproval: Bool

    /// Why the last change to `launchAtLogin` did not take, when
    /// ServiceManagement said — shown under the toggle, which otherwise just
    /// snaps back. Cleared by the next change that succeeds.
    @Published private(set) var launchAtLoginFailure: String? = nil

    @Published var launchAtLogin: Bool {
        didSet {
            guard !isSyncingLoginItem else { return }
            let (effective, failure) = LoginItem.setEnabled(launchAtLogin)
            launchAtLoginFailure = failure
            launchAtLoginRequiresApproval = LoginItem.requiresApproval
            if effective != launchAtLogin {
                isSyncingLoginItem = true
                launchAtLogin = effective
                isSyncingLoginItem = false
            }
            defaults.set(effective, forKey: Key.launchAtLogin)
        }
    }

    private init() {
        defaults.register(defaults: [
            Key.refreshInterval: RefreshRate.fast.rawValue,
            Key.temperatureUnit: TemperatureUnit.celsius.rawValue,
            // The rex is the product: the app is named for it, so it is what a
            // fresh install shows. Readouts are opt-in — the character alone
            // is the default face, and numbers are added in Settings by the
            // people who want them.
            Key.visualizer: Visualizer.rex.rawValue,
            Key.readouts: [String](),
            Key.monochrome: false,
            // Smooth by default now that the frame cost is a rounding error.
            // The economical ceiling existed to protect battery life, and
            // measurement says it no longer buys anything worth the choppiness.
            Key.animation: AnimationQuality.smooth.rawValue,
            Key.showVisualizer: true,
            Key.processRowCount: 6,
            // Five minutes: long enough to show what a wide graph is for,
            // short enough that a spike is still more than a pixel.
            Key.monitorSpan: 300,
            Key.monitorFloats: false,
            Key.openMonitorAtLaunch: false,
            Key.mcpEnabled: true,
        ])

        // Snapped to a real case: a stray stored value (hand-edited defaults,
        // or a different version's rates) would otherwise drive the engine at
        // whatever it clamps to while the Settings picker shows no selection.
        let storedInterval = defaults.double(forKey: Key.refreshInterval)
        refreshInterval = RefreshRate.allCases.min {
            abs($0.rawValue - storedInterval) < abs($1.rawValue - storedInterval)
        }?.rawValue ?? RefreshRate.fast.rawValue
        temperatureUnit = TemperatureUnit(
            rawValue: defaults.string(forKey: Key.temperatureUnit) ?? "") ?? .celsius
        visualizer = Visualizer(rawValue: defaults.string(forKey: Key.visualizer) ?? "")
            ?? .rex
        var seenReadouts = Set<MenuBarReadout>()
        readouts = (defaults.stringArray(forKey: Key.readouts) ?? [])
            .compactMap(MenuBarReadout.init(rawValue:))
            .filter { seenReadouts.insert($0).inserted }
        monochromeMenuBar = defaults.bool(forKey: Key.monochrome)
        animation = AnimationQuality(
            rawValue: defaults.string(forKey: Key.animation) ?? "") ?? .smooth
        showVisualizer = defaults.bool(forKey: Key.showVisualizer)
        processRowCount = min(12, max(3, defaults.integer(forKey: Key.processRowCount)))
        // Snapped to a real choice, like the refresh rate above.
        let storedSpan = defaults.integer(forKey: Key.monitorSpan)
        monitorSpan = MonitorSpan.options.min {
            abs($0 - storedSpan) < abs($1 - storedSpan)
        } ?? 300
        monitorFloats = defaults.bool(forKey: Key.monitorFloats)
        openMonitorAtLaunch = defaults.bool(forKey: Key.openMonitorAtLaunch)
        mcpEnabled = defaults.bool(forKey: Key.mcpEnabled)
        launchAtLogin = LoginItem.isEnabled
        launchAtLoginRequiresApproval = LoginItem.requiresApproval

        // Key-value observation of `UserDefaults` hears other processes'
        // writes to this domain too (checked on macOS 27), on whatever thread
        // cfprefsd's notice arrives.
        mcpEnabledObservation = defaults.observe(\.mcpEnabled, options: [.new]) { _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let preferences = Preferences.shared
                    let stored = preferences.defaults.bool(forKey: Key.mcpEnabled)
                    if stored != preferences.mcpEnabled { preferences.mcpEnabled = stored }
                }
            }
        }
    }

    func toggle(_ readout: MenuBarReadout) {
        if let index = readouts.firstIndex(of: readout) {
            readouts.remove(at: index)
        } else {
            readouts.append(readout)
        }
    }

    /// Moves an enabled readout one place towards the visualiser, or away from it.
    func move(_ readout: MenuBarReadout, by offset: Int) {
        guard let index = readouts.firstIndex(of: readout) else { return }
        let destination = index + offset
        guard readouts.indices.contains(destination) else { return }
        readouts.swapAt(index, destination)
    }

    func canMove(_ readout: MenuBarReadout, by offset: Int) -> Bool {
        guard let index = readouts.firstIndex(of: readout) else { return false }
        return readouts.indices.contains(index + offset)
    }

    /// ServiceManagement can change outside the app when the user approves or
    /// disables the item in System Settings. Reconcile on Settings appearance
    /// and app activation so the toggle does not remain stale until relaunch.
    func synchronizeLaunchAtLogin() {
        let requiresApproval = LoginItem.requiresApproval
        if requiresApproval != launchAtLoginRequiresApproval {
            launchAtLoginRequiresApproval = requiresApproval
        }
        let effective = LoginItem.isEnabled
        guard effective != launchAtLogin else { return }
        isSyncingLoginItem = true
        launchAtLogin = effective
        isSyncingLoginItem = false
        defaults.set(effective, forKey: Key.launchAtLogin)
    }
}

extension UserDefaults {
    /// Named for its key, so key-value observation of the property is
    /// observation of the stored preference.
    @objc dynamic fileprivate var mcpEnabled: Bool { bool(forKey: "mcpEnabled") }
}

extension StatusBarRenderer {
    /// The width of a readout's column, from the widest value and caption it
    /// can produce.
    static func width(for readout: MenuBarReadout) -> CGFloat {
        let template: String
        switch readout {
        case .cpu, .gpu, .memory, .swap, .battery: template = "100%"
        case .cpuTemperature, .gpuTemperature: template = "100°"
        // Three digits: Ultra-class machines exceed 100 W package draw, and
        // "100.0W" is wider than any two-digit reading.
        case .power: template = "100.0W"
        // The value rows are the *up* direction — "↑" for network, "W" for
        // disk — and "W" is the widest glyph either row can lead with.
        case .network: template = "↑999M"
        case .disk: template = "W999M"
        }
        // Network and disk swap the badge for a live rate at runtime, so it is
        // that rate's widest form being measured, not the badge.
        let caption: String
        switch readout {
        case .network: caption = "↓999M"
        case .disk: caption = "R999M"
        default: caption = readout.badge
        }
        return width(value: template, caption: caption)
    }
}
