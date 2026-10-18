import SwiftUI
import AppKit

@main
struct RexBoingApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // Rex Boing lives entirely in the menu bar. `Settings` gives the app a
        // valid (empty) scene graph; the status item and its popover are built
        // in the delegate. The scene also wires the app menu's "Settings…"
        // item to Cmd-, — left alone, that item would present this scene as a
        // blank window whenever one of the app's windows is key. Replace it so
        // the shortcut opens the real settings window instead.
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { delegate.openSettings() }
                    .keyboardShortcut(",")
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var engine: MetricsEngine?
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launch Services only dedupes launches of the same bundle *path*, and
        // the development flow — build into dist/, install into /Applications —
        // makes same-identifier copies at different paths routine. Run both and
        // there are two status items, two writers of one preferences domain,
        // and two claimants to the login item. The copy launched most recently
        // wins, which is what "replace the running instance with the fresh
        // build" means.
        //
        // Only copies that started *before* this one are quit. Two copies
        // launched together (a login item and a manual open) would otherwise
        // each see the other and quit it, leaving nothing in the menu bar.
        let current = NSRunningApplication.current
        if let identifier = Bundle.main.bundleIdentifier {
            for incumbent in NSRunningApplication.runningApplications(
                withBundleIdentifier: identifier)
            where incumbent.processIdentifier != current.processIdentifier
                && Self.launched(incumbent, before: current) {
                incumbent.terminate()
            }
        }

        // LSUIElement is set in Info.plist, but setting the policy explicitly
        // keeps behaviour identical when running from a build directory.
        NSApp.setActivationPolicy(.accessory)

        let engine = MetricsEngine()
        self.engine = engine
        self.statusItem = StatusItemController(engine: engine)
    }

    /// Launch order, oldest first; the pid breaks a tie (or a missing date),
    /// so of any two copies exactly one counts as the elder.
    private static func launched(_ a: NSRunningApplication, before b: NSRunningApplication) -> Bool {
        if let da = a.launchDate, let db = b.launchDate, da != db { return da < db }
        return a.processIdentifier < b.processIdentifier
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Opening the app again — from Finder, Spotlight or Launchpad — while it
    /// is running shows Settings. The status item can be out of sight (a full
    /// menu bar hides it behind the notch, a menu-bar manager can collapse
    /// it, or too many readouts can push it off), and without this the open
    /// did nothing at all, leaving no way to reach Settings or Quit. The flag
    /// is no guide here: the status item's own window can count as visible.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    /// Restorable state is archived with secure coding; without saying so,
    /// AppKit logs a warning at every launch on macOS 14 and later.
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func openSettings() {
        guard let engine else { return }
        SettingsWindowController.shared.show(engine: engine)
    }
}
