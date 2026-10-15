import AppKit

enum FailureAlert {
    enum Choice {
        case retry
        case openPreferences
        case save
        case dismiss
    }

    /// `canRetry` is false when the failure came from the capture itself (or
    /// there is simply no file to send): retrying an upload that was never
    /// going to have anything valid to send cannot succeed, so "Retry" is
    /// not offered and the honest choices are "Enregistrer…" or "Close".
    ///
    /// `isAuthFailure` replaces "Retry" with the preferences: the same dead
    /// key can only fail again, so sending the user there is the only move that
    /// changes anything.
    ///
    /// `canSave` is false when nothing was ever written to disk. Both the
    /// "Enregistrer…" button and the sentence promising the file will land in
    /// the save folder are then dropped — otherwise the alert sends the user
    /// hunting through the Downloads folder for a file that never existed.
    static func present(headline: String = "Upload failed",
                        message: String,
                        saveFolderName: String,
                        retryTitle: String = "Retry",
                        canRetry: Bool,
                        canSave: Bool,
                        isAuthFailure: Bool) -> Choice {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = headline
        alert.informativeText = canSave
            ? """
              \(message)

              The recording is kept. If you do nothing, it will be moved to \
              \(saveFolderName).
              """
            : message

        // Built in parallel so the response can be read back by position
        // whichever combination of buttons this failure deserves.
        var choices: [Choice] = []
        if isAuthFailure {
            alert.addButton(withTitle: "Open Preferences…")
            choices.append(.openPreferences)
        } else if canRetry {
            alert.addButton(withTitle: retryTitle)
            choices.append(.retry)
        }
        if canSave {
            alert.addButton(withTitle: "Save…")
            choices.append(.save)
        }
        alert.addButton(withTitle: "Close")
        choices.append(.dismiss)

        let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return choices.indices.contains(index) ? choices[index] : .dismiss
    }
}

extension MenuBarController {
    /// Finder shows folders under their localized names, so a French user sees
    /// "Téléchargements" where the path says "Downloads". Naming the folder by
    /// `lastPathComponent` sent them looking for a folder they never see
    /// spelled that way.
    var saveFolderDisplayName: String {
        FileManager.default.displayName(atPath: preferences.saveFolder.path)
    }

    /// A capture that could not be finalised: nothing to retry, only the
    /// partial file, if any, to keep.
    func presentFailure(_ message: String) {
        let hasFile = currentFileURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        switch FailureAlert.present(message: message, saveFolderName: saveFolderDisplayName,
                                    canRetry: false, canSave: hasFile, isAuthFailure: false) {
        case .save:
            saveCurrentFileWithPanel()
            apply(flow.handle(.failureDismissed))
        case .retry, .openPreferences, .dismiss:
            apply(flow.handle(.failureDismissed))
        }
    }

    /// An upload the server refused, or one that may already have landed. It is
    /// out of the queue: what the user picks here decides where its file goes,
    /// and a quit before that leaves the file to the launch sweep.
    ///
    /// `keyMayHaveChanged` is set when the alert comes back from the
    /// preferences: the key the server refused may have been replaced, so
    /// "Retry" is offered instead of sending the user straight back there.
    func presentUploadFailure(_ upload: PendingUpload, _ failure: UploadCoordinator.Failure,
                              keyMayHaveChanged: Bool = false) {
        let source = upload.fileURL(in: RecordingStorage.directory)
        let name = fileNameSlug(for: upload.configuration.title, at: upload.configuration.recordedAt)
        let hasFile = FileManager.default.fileExists(atPath: source.path)

        let headline: String
        let message: String
        let retryTitle: String
        let isAuthFailure: Bool
        switch failure {
        case let .rejected(error):
            headline = "Upload failed"
            message = error.message
            retryTitle = "Retry"
            isAuthFailure = error.isAuthenticationFailure && !keyMayHaveChanged
        case .maybeAlreadyUploaded:
            headline = "Upload interrupted"
            message = """
            This recording may already be on Whiteboard: the upload was finishing \
            when it was interrupted. Check before uploading it again.
            """
            retryTitle = "Upload again"
            isAuthFailure = false
        }

        switch FailureAlert.present(headline: headline,
                                    message: "\u{201C}\(upload.configuration.title)\u{201D}: \(message)",
                                    saveFolderName: saveFolderDisplayName,
                                    retryTitle: retryTitle,
                                    canRetry: hasFile,
                                    canSave: hasFile,
                                    isAuthFailure: isAuthFailure) {
        case .retry:
            uploads.requeue(upload, startingOver: failure == .maybeAlreadyUploaded)
        case .openPreferences:
            presentPreferences { [weak self] in
                DispatchQueue.main.async {
                    self?.presentUploadFailure(upload, failure, keyMayHaveChanged: true)
                }
            }
        case .save:
            if !saveFileWithPanel(source, suggestedName: name) {
                moveFileToSaveFolder(source, name: name)
            }
        case .dismiss:
            moveFileToSaveFolder(source, name: name)
        }
    }

    /// Asks for a name in the configured folder and moves (rather than copies)
    /// the file there: once the user has chosen where the recording goes,
    /// nothing must be left for a safety net to move again. Returns true once
    /// the file is where the user chose; on a failed move the user is told
    /// where it still is.
    @discardableResult
    func saveFileWithPanel(_ source: URL, suggestedName: String) -> Bool {
        let panel = NSSavePanel()
        panel.title = "Save the meeting audio"
        panel.directoryURL = preferences.saveFolder
        panel.nameFieldStringValue = "\(suggestedName).m4a"
        panel.allowedContentTypes = [.mpeg4Audio]

        guard panel.runModal() == .OK, let destination = panel.url else { return false }
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: source, to: destination)
            return true
        } catch {
            showSaveFailureAlert(source: source, error: error)
            return false
        }
    }

    func saveCurrentFileWithPanel() {
        guard let source = currentFileURL else { return }
        if saveFileWithPanel(source, suggestedName: suggestedFileName()) { currentFileURL = nil }
    }

    /// Safety net: drops a recording into the default save folder so it is
    /// never silently lost. Returns where it landed, or nil when there was
    /// nothing to move or the move failed — the user has then been shown where
    /// the file remains.
    @discardableResult
    func moveFileToSaveFolder(_ source: URL, name: String) -> URL? {
        guard FileManager.default.fileExists(atPath: source.path) else { return nil }
        let destination = uniqueURL(in: preferences.saveFolder, name: name)
        do {
            try FileManager.default.moveItem(at: source, to: destination)
            return destination
        } catch {
            showSaveFailureAlert(source: source, error: error)
            return nil
        }
    }

    /// The current recording's version. If the move fails `currentFileURL` is
    /// kept, so a later attempt can still recover the file.
    @discardableResult
    func moveCurrentFileToSaveFolder() -> URL? {
        guard let source = currentFileURL else { return nil }
        guard FileManager.default.fileExists(atPath: source.path) else {
            currentFileURL = nil
            return nil
        }
        let destination = moveFileToSaveFolder(source, name: suggestedFileName())
        if destination != nil { currentFileURL = nil }
        return destination
    }

    private func showSaveFailureAlert(source: URL, error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Could not save"
        alert.informativeText = """
        The recording could not be moved (\(error.localizedDescription)).

        The file is still here: \(source.path)
        """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Saving from the configuration window **copies**: the upload that follows
    /// still needs the original, and the queue deletes it only once the upload
    /// has actually succeeded.
    func saveCopyOfCurrentFile(named title: String) {
        guard let source = currentFileURL else {
            showAlert(title: "Nothing to save",
                      message: "The recording is no longer available.")
            return
        }

        let panel = NSSavePanel()
        panel.title = "Save a copy of the audio"
        panel.directoryURL = preferences.saveFolder
        panel.nameFieldStringValue = "\(fileNameSlug(for: title, at: startedAt ?? Date())).m4a"
        panel.allowedContentTypes = [.mpeg4Audio]

        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            showAlert(title: "Could not copy",
                      message: "The recording could not be copied: \(error.localizedDescription)")
        }
    }

    /// Only a capture that failed or a quit mid-recording reach this: no title
    /// was ever given, and the start time is all there is.
    private func suggestedFileName() -> String {
        fileNameSlug(for: "meeting", at: startedAt ?? Date())
    }

    /// A file name built from the meeting's title and its date.
    func fileNameSlug(for title: String, at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = (cleaned.isEmpty ? "meeting" : cleaned)
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return "\(slug.isEmpty ? "meeting" : slug)-\(formatter.string(from: date))"
    }

    func uniqueURL(in folder: URL, name: String) -> URL {
        var candidate = folder.appendingPathComponent("\(name).m4a")
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(name)-\(index).m4a")
            index += 1
        }
        return candidate
    }
}
