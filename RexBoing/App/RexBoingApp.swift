import SwiftUI
import AppKit

/// Decides what this process is before AppKit starts. Run with `mcp` (or
/// `tools`, `call`) it is the stdio MCP bridge an AI agent launched, and must
/// never become an app: no `NSApplication`, no status item, no windows, and
/// no check-in with LaunchServices, so the app's own single-instance check
/// and `build.sh --install` leave it running. Anything else is the app.
///
/// Only an exact first argument counts. LaunchServices and Xcode pass flags
/// of their own (`-NSDocumentRevisionsDebugMode YES`), and none of them is a
/// bare word.
@main
enum RexBoingMain {
    @MainActor static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if let first = arguments.first, MCPBridge.commands.contains(first) {
            exit(MCPBridge.run(arguments))
        }
        RexBoingApp.main()
    }
}

struct RexBoingApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // Rex Boing lives in the menu bar; its windows — Monitor, Settings,
        // the process breakdown — are built on demand in AppKit. `Settings`
        // gives the app a valid (empty) scene graph; the status item and its
        // popover are built in the delegate. The scene also wires the app
        // menu's "Settings…" item to Cmd-, — left alone, that item would
        // present this scene as a blank window whenever one of the app's
        // windows is key. Replace it so the shortcut opens the real settings
        // window instead.
        //
        // The menus only show while the Monitor window has made the app an
        // ordinary one, which is when a Window menu is wanted.
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { delegate.openSettings() }
                    .keyboardShortcut(",")
            }
            CommandGroup(before: .windowList) {
                Button("Monitor") { delegate.openMonitor() }
                    .keyboardShortcut("1")
                Button("Process Breakdown") { delegate.openProcessBreakdown() }
                    .keyboardShortcut("2")
                Divider()
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var engine: MetricsEngine?
    private var statusItem: StatusItemController?
    private var statsBroadcaster: StatsBroadcaster?
    private var mcpServer: MCPServer?

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
        //
        // MCP bridges (`Rex Boing mcp`) share the bundle identifier and the
        // executable, but never start NSApplication or check in with
        // LaunchServices, so they are not in this list and stay connected.
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
        self.statsBroadcaster = StatsBroadcaster(engine: engine)
        self.mcpServer = MCPServer(engine: engine)

        // An agent's bridge opened the app to answer a call: it starts as
        // quietly as a login launch, whatever the Monitor preference says.
        let launchedForAgent = CommandLine.arguments.dropFirst().contains(MCPIdentity.launchArgument)
        if Preferences.shared.openMonitorAtLaunch, !launchedForAgent {
            MonitorWindowController.shared.show(engine: engine)
        }
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

    /// Opening the app again — from Finder, Spotlight, Launchpad or its Dock
    /// icon — while it is running shows the Monitor window. The status item
    /// can be out of sight (a full menu bar hides it behind the notch, a
    /// menu-bar manager can collapse it, or too many readouts can push it
    /// off), and without this the open did nothing at all, leaving no way to
    /// reach the readings, Settings or Quit; the window has all three. The
    /// flag is no guide here: the status item's own window can count as
    /// visible.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openMonitor()
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

    func openMonitor() {
        guard let engine else { return }
        MonitorWindowController.shared.show(engine: engine)
    }

    func openProcessBreakdown() {
        guard let engine else { return }
        let latest = engine.processHistory.samples.last?.timestamp ?? Date()
        ProcessInspectorWindowController.shared.show(engine: engine, metric: .cpu, at: latest)
    }
}
