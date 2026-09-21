import AppKit
import SwiftUI

final class ConfigurationWindowController: NSWindowController {
    private let model: ConfigurationModel

    init(startedAt: Date,
         preferences: Preferences,
         client: WhiteboardClient,
         systemAudioAvailable: Bool,
         deviceWatchArmed: Bool,
         onConfirm: @escaping (RecordingConfiguration) -> Void,
         onCancel: @escaping () -> Void) {
        let model = ConfigurationModel(startedAt: startedAt, preferences: preferences,
                                       client: client, systemAudioAvailable: systemAudioAvailable,
                                       deviceWatchArmed: deviceWatchArmed)
        self.model = model

        // No close button: OK and Annuler are the only ways out.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 460),
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        window.title = "Whiteboard Recorder"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        // `contentViewController` — not `contentView` — so the window takes its
        // height from the content. Pinned at 460 points it could clip the
        // OK/Annuler row once both warning banners and a few tag chips were on
        // screen, and that row is the only way out of a window with no close
        // button, while a recording is running.
        let content = NSHostingController(rootView: ConfigurationView(
            model: model,
            onConfirm: {
                let configuration = model.makeConfiguration()
                model.phase = .uploading
                onConfirm(configuration)
            },
            onCancel: { [weak self] in
                onCancel()
                self?.close()
            },
            onClose: { [weak self] in
                self?.close()
            }
        ))
        window.contentViewController = content
        // Assigning the controller does not resize the window; without this the
        // window keeps the contentRect above and clips whatever exceeds it.
        window.setContentSize(content.view.fittingSize)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Called once the upload succeeded, so the window can say so instead of
    /// vanishing and leaving the user guessing.
    func showUploadSucceeded() {
        model.phase = .sent
    }

    func focus() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
