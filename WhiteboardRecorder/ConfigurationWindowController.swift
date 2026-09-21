import AppKit
import SwiftUI

final class ConfigurationWindowController: NSWindowController {
    private let model: ConfigurationModel

    init(startedAt: Date,
         preferences: Preferences,
         client: WhiteboardClient,
         systemAudioAvailable: Bool,
         onConfirm: @escaping (RecordingConfiguration) -> Void,
         onCancel: @escaping () -> Void) {
        let model = ConfigurationModel(startedAt: startedAt, preferences: preferences,
                                       client: client, systemAudioAvailable: systemAudioAvailable)
        self.model = model

        // No close button: OK and Annuler are the only ways out.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 460),
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        window.title = "Whiteboard Recorder"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        window.contentView = NSHostingView(rootView: ConfigurationView(
            model: model,
            onConfirm: { [weak self] in
                onConfirm(model.makeConfiguration())
                self?.close()
            },
            onCancel: { [weak self] in
                onCancel()
                self?.close()
            }
        ))
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func focus() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
