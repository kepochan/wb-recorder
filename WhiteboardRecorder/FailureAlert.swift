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
    /// `isAuthFailure` replaces "Retry" with the Préférences: the same dead
    /// key can only fail again, so sending the user there is the only move that
    /// changes anything.
    ///
    /// `canSave` is false when nothing was ever written to disk. Both the
    /// "Enregistrer…" button and the sentence promising the file will land in
    /// the save folder are then dropped — otherwise the alert sends the user
    /// hunting through Téléchargements for a file that never existed.
    static func present(message: String,
                        saveFolderName: String,
                        canRetry: Bool,
                        canSave: Bool,
                        isAuthFailure: Bool) -> Choice {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Upload failed"
        alert.informativeText = canSave
            ? """
              \(message)

              L'enregistrement est conservé. Sans action de ta part, il sera déposé dans \
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
            alert.addButton(withTitle: "Retry")
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
    /// Finder shows folders under their localized names — « Téléchargements »,
    /// not "Downloads". Naming the folder by `lastPathComponent` sent French
    /// users looking for a folder they never see spelled that way.
    var saveFolderDisplayName: String {
        FileManager.default.displayName(atPath: preferences.saveFolder.path)
    }

    func presentFailure(_ message: String, canRetry: Bool = true, isAuthFailure: Bool = false) {
        // `flow.state` is still `.failed` right here, but `flow.handle` below
        // moves it to `.idle` before returning `.moveFileToSaveFolder` — by the
        // time that effect runs, the title can no longer be read from the
        // state. Remember it now so the safety-net move still gets it right.
        if case let .failed(configuration?, _) = flow.state, !configuration.title.isEmpty {
            lastFailedTitle = configuration.title
        }

        // Both the "Enregistrer…" button and the promise that the recording will
        // be dropped in the save folder are only honest if a file is really there.
        let hasFile = currentFileURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false

        switch FailureAlert.present(message: message,
                                    saveFolderName: saveFolderDisplayName,
                                    canRetry: canRetry,
                                    canSave: hasFile,
                                    isAuthFailure: isAuthFailure) {
        case .retry:
            // Deferred to the next run loop turn so this call frame — and the
            // NSAlert.runModal() it is still returning from — unwinds first.
            // Without this, a retry that fails synchronously again (it no
            // longer can for a capture failure, since canRetry is false for
            // those, but this stays as a general safeguard) would re-enter
            // presentFailure from inside this very case, nesting modal frames
            // on every click instead of replacing the previous one.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.apply(self.flow.handle(.retryRequested))
            }
        case .openPreferences:
            // The flow deliberately stays `.failed`: the recording is still
            // held, and once the key has been fixed the same alert comes back —
            // this time with a "Retry" that can actually succeed. If the app
            // is quit instead, `prepareForTermination` still rescues the file.
            presentPreferences { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    guard let self, case let .failed(_, message) = self.flow.state else { return }
                    self.presentFailure(message)
                }
            }
        case .save:
            saveCurrentFileWithPanel()
            apply(flow.handle(.failureDismissed))
        case .dismiss:
            apply(flow.handle(.failureDismissed))
        }
    }

    /// Asks for a name, defaulting to the meeting title, in the configured
    /// folder. Moves (rather than copies) the source: once the user has
    /// chosen where the recording goes, nothing must be left behind for the
    /// `.failureDismissed` safety net to also move into `saveFolder`. If the
    /// move itself fails, `currentFileURL` is left untouched — so the safety
    /// net stays armed — and the user is told where the recording still is.
    func saveCurrentFileWithPanel() {
        guard let source = currentFileURL else { return }
        let panel = NSSavePanel()
        panel.title = "Save the meeting audio"
        panel.directoryURL = preferences.saveFolder
        panel.nameFieldStringValue = "\(suggestedFileName()).m4a"
        panel.allowedContentTypes = [.mpeg4Audio]

        guard panel.runModal() == .OK, let destination = panel.url else { return }
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: source, to: destination)
            currentFileURL = nil
        } catch {
            showSaveFailureAlert(source: source, error: error)
        }
    }

    /// Safety net for "Close" (and for "Enregistrer…" if the panel was
    /// cancelled): drops the recording into the default save folder so it is
    /// never silently lost. If the move fails, `currentFileURL` is kept so a
    /// later attempt (or the user, told where to look) can still recover it —
    /// clearing it unconditionally would orphan the file with nothing left
    /// pointing at it.
    ///
    /// Returns where the recording landed, or nil when there was nothing to move
    /// or the move failed — in the latter case `currentFileURL` is still set and
    /// the user has already been shown where the file remains.
    @discardableResult
    func moveCurrentFileToSaveFolder() -> URL? {
        guard let source = currentFileURL else { return nil }
        guard FileManager.default.fileExists(atPath: source.path) else {
            currentFileURL = nil
            return nil
        }
        let destination = uniqueURL(in: preferences.saveFolder, name: suggestedFileName())
        do {
            try FileManager.default.moveItem(at: source, to: destination)
            currentFileURL = nil
            return destination
        } catch {
            showSaveFailureAlert(source: source, error: error)
            return nil
        }
    }

    private func showSaveFailureAlert(source: URL, error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Could not save"
        alert.informativeText = """
        L'enregistrement n'a pas pu être déplacé (\(error.localizedDescription)).

        Le fichier se trouve toujours ici : \(source.path)
        """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Saving from the configuration window **copies**: the upload that follows
    /// still needs the original, and the flow deletes it only once the upload
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
        panel.nameFieldStringValue = "\(fileNameSlug(for: title)).m4a"
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

    private func suggestedFileName() -> String {
        // `.recording` and `.uploading` matter because a quit mid-flight also
        // rescues a file, and it deserves the meeting's name too.
        let configured: String?
        switch flow.state {
        case let .failed(configuration?, _), let .uploading(configuration):
            configured = configuration.title.isEmpty ? nil : configuration.title
        case .failed(nil, _), .idle, .recording, .configuring:
            configured = nil
        }

        return fileNameSlug(for: configured ?? lastFailedTitle ?? "meeting")
    }

    /// A file name built from the meeting's title and the instant it started.
    func fileNameSlug(for title: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = (cleaned.isEmpty ? "meeting" : cleaned)
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return "\(slug.isEmpty ? "meeting" : slug)-\(formatter.string(from: startedAt ?? Date()))"
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
