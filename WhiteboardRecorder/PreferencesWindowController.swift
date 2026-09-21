import AppKit
import SwiftUI

final class PreferencesWindowController: NSWindowController {
    private let model: PreferencesModel

    init(preferences: Preferences, keychain: KeychainStore) {
        let model = PreferencesModel(preferences: preferences, keychain: keychain)
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = "Whiteboard Recorder — Préférences"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = NSHostingView(rootView: PreferencesView(model: model) { [weak self] in
            self?.close()
        })
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// `MenuBarController` reuses a single controller instance across opens
    /// (so an already-open window is simply refocused rather than rebuilt).
    /// That reuse means the underlying `PreferencesModel` — and whatever an
    /// abandoned, never-saved edit left in it — would otherwise still be
    /// sitting there the next time the window is shown. Reloading from the
    /// persisted Keychain/Preferences state whenever the window isn't
    /// currently visible closes that gap, while leaving an already-visible
    /// window (a second click while it's open) untouched so it doesn't wipe
    /// an edit in progress.
    func show() {
        if window?.isVisible != true {
            model.reload()
        }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
    }
}
