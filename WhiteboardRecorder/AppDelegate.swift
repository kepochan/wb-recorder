import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?

    /// There is no MainMenu nib to assign NSApp.delegate, so the application is
    /// started by hand instead of through NSApplicationMain.
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
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
