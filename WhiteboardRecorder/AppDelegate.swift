import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?

    /// There is no MainMenu nib to assign NSApp.delegate, so the application is
    /// started by hand instead of through NSApplicationMain.
    static func main() {
        let application = NSApplication.shared
        installEditMenu(on: application)
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }

    /// An LSUIElement app has no menu bar of its own, and without an Edit menu
    /// AppKit never routes ⌘X / ⌘C / ⌘V to the focused text field — pasting an
    /// API key would only work through the right-click menu.
    private static func installEditMenu(on application: NSApplication) {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: Selector(("cut:")), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: Selector(("copy:")), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: Selector(("paste:")), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: Selector(("selectAll:")), keyEquivalent: "a")

        let editItem = NSMenuItem()
        editItem.submenu = edit
        let main = NSMenu()
        main.addItem(editItem)
        application.mainMenu = main
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = MenuBarController()
        menuBarController = controller
        // Deferred so the status item is on screen before a modal alert can
        // take over, and so launch itself is never blocked by one.
        DispatchQueue.main.async { controller.sweepStrandedRecordings() }
    }

    /// `terminate` unwinds nothing on its own: a quit while recording or
    /// uploading would leave an unplayable file in a folder nothing lists and
    /// the user none the wiser. The controller closes the capture, rescues the
    /// file and says where it went; the exit waits for it.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        menuBarController?.prepareForTermination() ?? .terminateNow
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
