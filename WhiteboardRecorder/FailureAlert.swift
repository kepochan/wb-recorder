import AppKit

enum FailureAlert {
    enum Choice {
        case retry
        case save
        case dismiss
    }

    /// `canRetry` is false when the failure came from the capture itself (or
    /// there is simply no file to send): retrying an upload that was never
    /// going to have anything valid to send cannot succeed, so "Réessayer" is
    /// not offered and the honest choices are "Enregistrer…" or "Fermer".
    static func present(message: String, saveFolder: URL, canRetry: Bool) -> Choice {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Envoi impossible"
        alert.informativeText = """
        \(message)

        L'enregistrement est conservé. Sans action de ta part, il sera déposé dans \
        \(saveFolder.lastPathComponent).
        """
        if canRetry {
            alert.addButton(withTitle: "Réessayer")
        }
        alert.addButton(withTitle: "Enregistrer…")
        alert.addButton(withTitle: "Fermer")

        let response = alert.runModal()
        if canRetry {
            switch response {
            case .alertFirstButtonReturn: return .retry
            case .alertSecondButtonReturn: return .save
            default: return .dismiss
            }
        } else {
            switch response {
            case .alertFirstButtonReturn: return .save
            default: return .dismiss
            }
        }
    }
}

extension MenuBarController {
    func presentFailure(_ message: String, canRetry: Bool = true) {
        // `flow.state` is still `.failed` right here, but `flow.handle` below
        // moves it to `.idle` before returning `.moveFileToSaveFolder` — by the
        // time that effect runs, the title can no longer be read from the
        // state. Remember it now so the safety-net move still gets it right.
        if case let .failed(configuration, _) = flow.state, !configuration.title.isEmpty {
            lastFailedTitle = configuration.title
        }

        switch FailureAlert.present(message: message, saveFolder: preferences.saveFolder, canRetry: canRetry) {
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
        panel.title = "Enregistrer l'audio de la réunion"
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

    /// Safety net for "Fermer" (and for "Enregistrer…" if the panel was
    /// cancelled): drops the recording into the default save folder so it is
    /// never silently lost. If the move fails, `currentFileURL` is kept so a
    /// later attempt (or the user, told where to look) can still recover it —
    /// clearing it unconditionally would orphan the file with nothing left
    /// pointing at it.
    func moveCurrentFileToSaveFolder() {
        guard let source = currentFileURL else { return }
        guard FileManager.default.fileExists(atPath: source.path) else {
            currentFileURL = nil
            return
        }
        let destination = uniqueURL(in: preferences.saveFolder, name: suggestedFileName())
        do {
            try FileManager.default.moveItem(at: source, to: destination)
            currentFileURL = nil
        } catch {
            showSaveFailureAlert(source: source, error: error)
        }
    }

    private func showSaveFailureAlert(source: URL, error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Sauvegarde impossible"
        alert.informativeText = """
        L'enregistrement n'a pas pu être déplacé (\(error.localizedDescription)).

        Le fichier se trouve toujours ici : \(source.path)
        """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func suggestedFileName() -> String {
        let title: String
        if case let .failed(configuration, _) = flow.state, !configuration.title.isEmpty {
            title = configuration.title
        } else if let lastFailedTitle {
            title = lastFailedTitle
        } else {
            title = "reunion"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let slug = title
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return "\(slug)-\(formatter.string(from: startedAt ?? Date()))"
    }

    private func uniqueURL(in folder: URL, name: String) -> URL {
        var candidate = folder.appendingPathComponent("\(name).m4a")
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(name)-\(index).m4a")
            index += 1
        }
        return candidate
    }
}
