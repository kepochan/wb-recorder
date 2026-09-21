import AppKit
import SwiftUI

final class PreferencesWindowController: NSWindowController, NSWindowDelegate {
    private let model: PreferencesModel

    /// Fired once when the window closes, then cleared so a later open — which
    /// reuses this very controller — cannot inherit it.
    private var onClose: (() -> Void)?

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
        window.delegate = self
        // `contentViewController` — not `contentView` — so the window takes its
        // size from the SwiftUI content. With `contentView` the window keeps the
        // fixed contentRect above and any content wider than it overflows,
        // clipped on both sides.
        window.contentViewController = NSHostingController(rootView: PreferencesView(model: model) { [weak self] in
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
    func show(onClose: (() -> Void)? = nil) {
        self.onClose = onClose
        if window?.isVisible != true {
            model.reload()
        }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
    }

    func windowWillClose(_ notification: Notification) {
        let callback = onClose
        onClose = nil
        callback?()
    }
}
