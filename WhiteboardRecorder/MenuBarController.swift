import AppKit

final class MenuBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let contextMenu = NSMenu()

    override init() {
        super.init()
        setIcon(.idle)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(handleClick)
        statusItem.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
        buildMenu()
    }

    func setIcon(_ state: IconState) {
        statusItem.button?.image = StatusIcon.image(for: state)
    }

    private func buildMenu() {
        let preferences = NSMenuItem(title: "Préférences…", action: #selector(showPreferences), keyEquivalent: ",")
        preferences.target = self
        contextMenu.addItem(preferences)
        contextMenu.addItem(.separator())
        let quit = NSMenuItem(title: "Quitter", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        contextMenu.addItem(quit)
    }

    @objc private func handleClick() {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseDown
            || (event?.type == .leftMouseDown && event?.modifierFlags.contains(.control) == true)

        if isRightClick {
            guard let button = statusItem.button else { return }
            contextMenu.popUp(positioning: nil,
                              at: NSPoint(x: button.bounds.midX, y: button.bounds.minY),
                              in: button)
            return
        }
        handleLeftClick()
    }

    /// Wired to the recording flow in Task 13.
    private func handleLeftClick() {
        NSLog("left click")
    }

    @objc private func showPreferences() {
        NSLog("preferences")
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
