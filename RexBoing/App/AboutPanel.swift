import AppKit

/// The standard About panel, raised the same way from every entry point —
/// the status item's context menu, the dashboard's overflow menu and the
/// Settings window — so all of them show the same name, version, icon and
/// copyright line instead of three variations on it. The copyright line is
/// `NSHumanReadableCopyright` in Info.plist, the one place it is written.
@MainActor
enum AboutPanel {
    static func show() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }
}
