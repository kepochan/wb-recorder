import AppKit
import AVFoundation
import UniformTypeIdentifiers

final class MenuBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let contextMenu = NSMenu()

    let preferences = Preferences()
    private let keychain = KeychainStore()
    let capture: AudioCapture = CoreAudioCapture()
    let flow = RecordingFlow()

    var configurationWindow: ConfigurationWindowController?
    private var preferencesWindow: PreferencesWindowController?
    var currentFileURL: URL?
    var startedAt: Date?

    /// Set by `.stopCapture` when `capture.stop()` throws. Remembered so that
    /// `startUpload` can fail the flow instead of silently uploading nothing,
    /// and cleared whenever a new recording starts so it cannot leak into it.
    private var captureFailureMessage: String?

    /// Set by `presentFailure` (defined in FailureAlert.swift) while `flow.state`
    /// is still `.failed`, so the save-folder safety net can still name the file
    /// after the meeting once the flow has moved on to `.idle`. Cleared whenever
    /// a new recording starts so it cannot leak into it.
    var lastFailedTitle: String?

    private var client: WhiteboardClient {
        WhiteboardClient(baseURL: preferences.apiBaseURL, apiKey: { [keychain] in keychain.read() })
    }

    override init() {
        super.init()
        setIcon(.idle)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(handleClick)
        statusItem.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
        buildMenu()
    }

    // MARK: - Menu

    private static let preferencesTitle = "Préférences…"

    /// The elapsed-time line the spec asks for *in addition to* Préférences. It
    /// carries no action, which is what keeps `autoenablesItems` from enabling
    /// it: it reads as a status line, not as a button. Overwriting the title of
    /// the Préférences item instead used to hide Préférences behind the
    /// duration and leave its action live.
    private let durationItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let durationSeparator = NSMenuItem.separator()

    private func buildMenu() {
        durationItem.isHidden = true
        durationSeparator.isHidden = true
        contextMenu.addItem(durationItem)
        contextMenu.addItem(durationSeparator)
        let preferencesItem = NSMenuItem(title: Self.preferencesTitle, action: #selector(showPreferences), keyEquivalent: ",")
        preferencesItem.target = self
        contextMenu.addItem(preferencesItem)
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
            showMenu()
            return
        }

        // The key and microphone checks only make sense for the click that
        // starts a new recording. Gating every click on them meant that
        // revoking either while a recording was running swallowed the click
        // that should have stopped it: capture kept running, the icon stayed
        // `.recording`, and only a relaunch recovered. Stopping (or focusing
        // the configuration window, or a no-op while uploading/failed) must
        // always reach the flow.
        guard case .idle = flow.state else {
            apply(flow.handle(.iconClicked))
            return
        }

        guard keychain.read() != nil else {
            showPreferences()
            return
        }

        requestMicrophoneAccess { [weak self] granted in
            guard let self else { return }
            guard granted else { self.showMicrophoneAlert(); return }
            self.apply(self.flow.handle(.iconClicked))
        }
    }

    private func showMenu() {
        guard let button = statusItem.button else { return }
        if case let .recording(startedAt, _) = flow.state {
            let elapsed = Int(Date().timeIntervalSince(startedAt))
            durationItem.title = String(format: "Enregistrement — %02d:%02d", elapsed / 60, elapsed % 60)
            durationItem.isHidden = false
            durationSeparator.isHidden = false
        } else {
            durationItem.isHidden = true
            durationSeparator.isHidden = true
        }
        contextMenu.popUp(positioning: nil,
                          at: NSPoint(x: button.bounds.midX, y: button.bounds.minY),
                          in: button)
    }

    // MARK: - Effects

    func apply(_ effects: [RecordingEffect]) {
        for effect in effects {
            switch effect {
            case .startCapture:
                // A fresh recording must never inherit the previous one's failure.
                captureFailureMessage = nil
                lastFailedTitle = nil
                do {
                    startedAt = try capture.start()
                } catch {
                    showAlert(title: "Enregistrement impossible", message: frenchMessage(for: error))
                    apply(flow.handle(.configurationCancelled))
                    // `.startCapture` is always the first of the four effects
                    // `(.idle, .iconClicked)` returns; the other three
                    // (setIcon(.recording), setESP32Recording(true),
                    // showConfigurationWindow) all assume the capture actually
                    // started. The line above has already unwound the flow back
                    // to `.idle`, so running them now would show a recording
                    // icon, a red light and an open configuration window while
                    // the flow itself is idle — wedged until relaunch. Returning
                    // here instead of falling through to them keeps icon and
                    // flow in sync.
                    return
                }

            case .stopCapture:
                do {
                    currentFileURL = try capture.stop()
                    captureFailureMessage = nil
                } catch {
                    // stop() throws when the recording is not trustworthy. The
                    // error may still carry a partial file, which is kept as the
                    // current file so the user can rescue it via "Enregistrer…";
                    // the failure itself is remembered so startUpload refuses to
                    // ship it and reaches the failure alert instead.
                    currentFileURL = partialFileURL(for: error)
                    captureFailureMessage = "L'enregistrement n'a pas pu être finalisé : \(frenchMessage(for: error))"
                }

            case .discardFile, .deleteFile:
                if let url = currentFileURL { try? FileManager.default.removeItem(at: url) }
                currentFileURL = nil

            case .moveFileToSaveFolder:
                moveCurrentFileToSaveFolder()

            case let .upload(configuration):
                startUpload(configuration)

            case let .showConfigurationWindow(startedAt):
                showConfigurationWindow(startedAt: startedAt)

            case .focusConfigurationWindow:
                configurationWindow?.focus()

            case let .setIcon(state):
                setIcon(state)

            case let .setESP32Recording(isRecording):
                let display = ESP32Display(host: preferences.esp32Host)
                Task { await display.setRecording(isRecording) }
            }
        }
    }

    private func showConfigurationWindow(startedAt: Date) {
        configurationWindow?.close()
        let controller = ConfigurationWindowController(
            startedAt: startedAt,
            preferences: preferences,
            client: client,
            systemAudioAvailable: capture.isSystemAudioAvailable,
            deviceWatchArmed: capture.isDeviceWatchArmed,
            onConfirm: { [weak self] configuration in
                guard let self else { return }
                self.apply(self.flow.handle(.configurationConfirmed(configuration)))
            },
            onCancel: { [weak self] in
                guard let self else { return }
                self.apply(self.flow.handle(.configurationCancelled))
            }
        )
        configurationWindow = controller
        controller.focus()
    }

    private func startUpload(_ configuration: RecordingConfiguration) {
        if let captureFailureMessage {
            // The capture itself failed before there was ever anything to
            // upload; take the flow straight to its normal failure path so the
            // Task 14 alert appears instead of silently doing nothing. Retrying
            // a capture that never produced a valid file cannot succeed, so
            // Réessayer is not offered here — which also means presentFailure
            // can never be re-entered synchronously from its own `.retry` case
            // for this kind of failure.
            apply(flow.handle(.uploadFailed(captureFailureMessage)))
            presentFailure(captureFailureMessage, canRetry: false)
            return
        }

        guard let fileURL = currentFileURL else {
            // No capture failure was recorded, yet there is no file either —
            // nothing retrying would change, so this is not offered either.
            let message = "Le fichier audio est introuvable."
            apply(flow.handle(.uploadFailed(message)))
            presentFailure(message, canRetry: false)
            return
        }

        let recording = RecordingUpload(
            audioURL: fileURL,
            workspaceID: configuration.workspaceID,
            title: configuration.title,
            recordedAt: configuration.recordedAt,
            language: configuration.language,
            sharingMode: configuration.sharingMode,
            tags: configuration.tags
        )

        let client = self.client
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await client.upload(recording)
                self.apply(self.flow.handle(.uploadSucceeded))
            } catch let error as APIError {
                self.apply(self.flow.handle(.uploadFailed(error.message)))
                // A dead key cannot be retried into working, so the alert offers
                // the Préférences instead of "Réessayer".
                self.presentFailure(error.message, isAuthFailure: error.isAuthenticationFailure)
            } catch {
                self.apply(self.flow.handle(.uploadFailed(error.localizedDescription)))
                self.presentFailure(error.localizedDescription)
            }
        }
    }

    // MARK: - Helpers

    private func setIcon(_ state: IconState) {
        statusItem.button?.image = StatusIcon.image(for: state)
    }

    private func requestMicrophoneAccess(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    private func showMicrophoneAlert() {
        let alert = NSAlert()
        alert.messageText = "Accès au micro requis"
        alert.informativeText = "Autorise Whiteboard Recorder dans Réglages Système → Confidentialité et sécurité → Microphone."
        alert.addButton(withTitle: "Ouvrir les réglages")
        alert.addButton(withTitle: "Annuler")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// The partial file a failed `stop()` may still have left on disk, or nil
    /// when the error carries none (or is not a `CaptureError` at all).
    func partialFileURL(for error: Error) -> URL? {
        guard let captureError = error as? CaptureError else { return nil }
        switch captureError {
        case let .writeFailed(_, partialFile), let .deviceChanged(partialFile), let .nothingCaptured(partialFile):
            return partialFile.isEmpty ? nil : URL(fileURLWithPath: partialFile)
        case .noInputDevice, .aggregateDeviceFailed, .notRecording:
            return nil
        }
    }

    /// `CaptureError` carries no user-facing text of its own; this maps it (and
    /// any other error) to a plain French explanation.
    private func frenchMessage(for error: Error) -> String {
        guard let captureError = error as? CaptureError else { return error.localizedDescription }
        switch captureError {
        case .noInputDevice:
            return "Aucun micro n'a été trouvé."
        case .aggregateDeviceFailed:
            return "Le périphérique audio n'a pas pu être configuré."
        case .notRecording:
            return "Aucune capture n'était en cours."
        case let .writeFailed(reason, _):
            return "L'écriture du fichier audio a échoué (\(reason))."
        case .deviceChanged:
            return "Le périphérique audio a changé pendant la capture."
        case .nothingCaptured:
            return "Aucun son n'a été capté."
        }
    }

    @objc private func showPreferences() {
        presentPreferences()
    }

    /// `onClose` fires once, when the window goes away. The 401 path uses it to
    /// bring the failure alert back with a "Réessayer" that can now work.
    func presentPreferences(onClose: (() -> Void)? = nil) {
        let controller = preferencesWindow ?? PreferencesWindowController(preferences: preferences, keychain: keychain)
        preferencesWindow = controller
        controller.show(onClose: onClose)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
