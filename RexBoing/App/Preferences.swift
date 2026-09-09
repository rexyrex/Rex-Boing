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

    @Published var launchAtLogin: Bool {
        didSet {
            guard !isSyncingLoginItem else { return }
            let effective = LoginItem.setEnabled(launchAtLogin)
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
        launchAtLogin = LoginItem.isEnabled
        launchAtLoginRequiresApproval = LoginItem.requiresApproval
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
