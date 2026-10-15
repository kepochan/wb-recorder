import AppKit
import AVFoundation
import Combine
import Network
import UniformTypeIdentifiers

@MainActor final class MenuBarController: NSObject {
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

    /// Every recording confirmed in the configuration window is handed to this
    /// queue and sent in the background, one at a time. The queue lives on
    /// disk, so a quit or a crash only pauses it, and the icon is free for the
    /// next meeting as soon as the window says OK.
    private(set) lazy var uploads: UploadCoordinator = makeUploads()
    private let notifications = UploadNotifications()
    private let pathMonitor = NWPathMonitor()
    private var activityObserver: AnyCancellable?

    private var client: WhiteboardClient {
        WhiteboardClient(baseURL: preferences.apiBaseURL, apiKey: { [keychain] in keychain.read() })
    }

    override init() {
        super.init()
        refreshIcon()
        statusItem.button?.target = self
        statusItem.button?.action = #selector(handleClick)
        statusItem.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
        buildMenu()
    }

    // MARK: - Menu

    private static let preferencesTitle = "Preferences…"

    /// The elapsed-time line the spec asks for *in addition to* the preferences. It
    /// carries no action, which is what keeps `autoenablesItems` from enabling
    /// it: it reads as a status line, not as a button. Overwriting the title of
    /// the preferences item instead used to hide the preferences behind the
    /// duration and leave its action live.
    private let durationItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let durationSeparator = NSMenuItem.separator()
    /// Same idea as the duration line: a status line with no action, plus
    /// "Resume upload" while the queue is paused.
    private let uploadStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let resumeUploadItem = NSMenuItem(title: "Resume upload", action: #selector(resumeUpload), keyEquivalent: "")
    private let stopUploadItem = NSMenuItem(title: "Stop upload…", action: #selector(stopPausedUpload), keyEquivalent: "")
    private let uploadSeparator = NSMenuItem.separator()

    private func buildMenu() {
        durationItem.isHidden = true
        durationSeparator.isHidden = true
        contextMenu.addItem(durationItem)
        contextMenu.addItem(durationSeparator)
        uploadStatusItem.isHidden = true
        resumeUploadItem.isHidden = true
        stopUploadItem.isHidden = true
        uploadSeparator.isHidden = true
        resumeUploadItem.target = self
        stopUploadItem.target = self
        contextMenu.addItem(uploadStatusItem)
        contextMenu.addItem(resumeUploadItem)
        contextMenu.addItem(stopUploadItem)
        contextMenu.addItem(uploadSeparator)
        let preferencesItem = NSMenuItem(title: Self.preferencesTitle, action: #selector(showPreferences), keyEquivalent: ",")
        preferencesItem.target = self
        contextMenu.addItem(preferencesItem)
        contextMenu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
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
        if case let .recording(startedAt) = flow.state {
            let elapsed = Int(Date().timeIntervalSince(startedAt))
            durationItem.title = String(format: "Recording — %02d:%02d", elapsed / 60, elapsed % 60)
            durationItem.isHidden = false
            durationSeparator.isHidden = false
        } else {
            durationItem.isHidden = true
            durationSeparator.isHidden = true
        }
        let waiting = uploads.waitingCount > 0 ? " (+\(uploads.waitingCount) waiting)" : ""
        switch uploads.activity {
        case .idle:
            uploadStatusItem.isHidden = true
            resumeUploadItem.isHidden = true
            stopUploadItem.isHidden = true
            uploadSeparator.isHidden = true
        case let .uploading(_, title, sent, total):
            let percent = total > 0 ? Int(sent * 100 / total) : 0
            uploadStatusItem.title = "Uploading “\(title)” — \(percent)%\(waiting)"
            uploadStatusItem.isHidden = false
            resumeUploadItem.isHidden = true
            stopUploadItem.isHidden = true
            uploadSeparator.isHidden = false
        case let .paused(_, title, _):
            uploadStatusItem.title = "Upload paused — “\(title)”\(waiting)"
            uploadStatusItem.isHidden = false
            resumeUploadItem.isHidden = false
            stopUploadItem.isHidden = false
            uploadSeparator.isHidden = false
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
                do {
                    startedAt = try capture.start()
                } catch {
                    showAlert(title: "Cannot record", message: message(for: error))
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
                } catch {
                    // stop() throws when the recording is not trustworthy. The
                    // error may still carry a partial file, which is kept as the
                    // current file so the user can rescue it via "Enregistrer…";
                    // the failure goes to the capture-failure alert.
                    currentFileURL = partialFileURL(for: error)
                    let message = "The recording could not be finalised: \(message(for: error))"
                    // There is nothing worth configuring, so the remaining
                    // effects — including opening the configuration window —
                    // must not run. The alert lets the partial file be saved.
                    apply(flow.handle(.captureFailed(message)))
                    presentFailure(message)
                    return
                }

            case .discardFile:
                if let url = currentFileURL { try? FileManager.default.removeItem(at: url) }
                currentFileURL = nil

            case .moveFileToSaveFolder:
                moveCurrentFileToSaveFolder()

            case let .enqueueUpload(configuration):
                enqueueUpload(configuration)

            case let .showConfigurationWindow(startedAt):
                showConfigurationWindow(startedAt: startedAt)

            case .focusConfigurationWindow:
                configurationWindow?.focus()

            case .setIcon:
                // What the flow alone would show; the queue may still be
                // sending an earlier meeting, which `refreshIcon` accounts for.
                refreshIcon()

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
            uploads: uploads,
            systemAudioAvailable: capture.isSystemAudioAvailable,
            deviceWatchArmed: capture.isDeviceWatchArmed,
            onConfirm: { [weak self] configuration in
                guard let self else { return }
                self.apply(self.flow.handle(.configurationConfirmed(configuration)))
            },
            onCancel: { [weak self] in
                guard let self else { return }
                self.apply(self.flow.handle(.configurationCancelled))
            },
            onSaveCopy: { [weak self] title in
                self?.saveCopyOfCurrentFile(named: title)
            }
        )
        configurationWindow = controller
        controller.focus()
    }

    private func enqueueUpload(_ configuration: RecordingConfiguration) {
        guard let fileURL = currentFileURL else {
            configurationWindow?.close()
            showAlert(title: "Upload failed", message: APIError.fileMissing.message)
            return
        }
        do {
            let id = try uploads.enqueue(fileURL: fileURL, configuration: configuration)
            // The queue owns the file now; the next recording gets its own.
            currentFileURL = nil
            notifications.requestAuthorizationIfNeeded()
            configurationWindow?.track(uploadID: id)
        } catch {
            configurationWindow?.close()
            showAlert(title: "Upload failed", message: (error as? APIError)?.message ?? error.localizedDescription)
        }
    }

    private func makeUploads() -> UploadCoordinator {
        let coordinator = UploadCoordinator(
            store: PendingUploadStore(),
            directory: RecordingStorage.directory,
            makeUploader: { [unowned self] in ChunkedUploader(client: self.client) })
        coordinator.notify = { [notifications] title, body in
            notifications.post(title: title, body: body)
        }
        coordinator.onCompleted = { [weak self] upload in
            guard let self, self.configurationWindow?.uploadID == upload.id else { return }
            self.configurationWindow?.showUploadSucceeded()
        }
        coordinator.onFailed = { [weak self] upload, failure in
            // Out of the coordinator's call before a modal alert takes over.
            DispatchQueue.main.async { self?.uploadFailed(upload, failure) }
        }
        // `$activity` fires before the value changes; the hop reads the new one.
        activityObserver = coordinator.$activity.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.refreshIcon()
                // Waiting, uploading and paused are not the same height.
                self?.configurationWindow?.fitToContent()
            }
        }
        return coordinator
    }

    private func uploadFailed(_ upload: PendingUpload, _ failure: UploadCoordinator.Failure) {
        if configurationWindow?.uploadID == upload.id { configurationWindow?.close() }
        presentUploadFailure(upload, failure)
    }

    /// Called once at launch, after the sweep: picks up the uploads an earlier
    /// run left unfinished, and starts listening for the network to come back.
    func resumePendingUploads() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            DispatchQueue.main.async { self?.uploads.networkChanged(isAvailable: available) }
        }
        pathMonitor.start(queue: .global(qos: .utility))

        let lost = uploads.resumeAfterLaunch()
        guard !lost.isEmpty else { return }
        showAlert(title: "Uploads dropped",
                  message: """
                  These recordings were waiting to be uploaded, but their audio file is gone:

                  \(lost.joined(separator: "\n"))
                  """)
    }

    // MARK: - Helpers

    /// The flow knows whether a meeting is being recorded or configured; the
    /// queue knows whether an earlier one is still on its way. Recording wins.
    private func refreshIcon() {
        let state: IconState
        switch flow.state {
        case .recording: state = .recording
        case .configuring: state = .uploading
        case .idle, .failed: state = uploads.activity == .idle ? .idle : .uploading
        }
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
        alert.messageText = "Microphone access required"
        alert.informativeText = "Allow Whiteboard Recorder in System Settings → Privacy & Security → Microphone."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
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
    private func message(for error: Error) -> String {
        guard let captureError = error as? CaptureError else { return error.localizedDescription }
        switch captureError {
        case .noInputDevice:
            return "No microphone was found."
        case .aggregateDeviceFailed:
            return "The audio device could not be set up."
        case .notRecording:
            return "No capture was running."
        case let .writeFailed(reason, _):
            return "Writing the audio file failed (\(reason))."
        case .deviceChanged:
            return "The audio device changed during the capture."
        case .nothingCaptured:
            return "No sound was captured."
        }
    }

    @objc private func showPreferences() {
        presentPreferences()
    }

    @objc private func resumeUpload() {
        uploads.resume()
    }

    @objc private func stopPausedUpload() {
        uploads.stopPaused()
    }

    /// `onClose` fires once, when the window goes away. The 401 path uses it to
    /// bring the failure alert back with a "Retry" that can now work.
    func presentPreferences(onClose: (() -> Void)? = nil) {
        let controller = preferencesWindow ?? PreferencesWindowController(preferences: preferences, keychain: keychain)
        preferencesWindow = controller
        controller.show(onClose: onClose)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
