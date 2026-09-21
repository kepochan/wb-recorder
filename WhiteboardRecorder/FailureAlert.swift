import AppKit

enum FailureAlert {
    enum Choice {
        case retry
        case save
        case dismiss
    }

    static func present(message: String, saveFolder: URL) -> Choice {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Envoi impossible"
        alert.informativeText = """
        \(message)

        L'enregistrement est conservé. Sans action de ta part, il sera déposé dans \
        \(saveFolder.lastPathComponent).
        """
        alert.addButton(withTitle: "Réessayer")
        alert.addButton(withTitle: "Enregistrer…")
        alert.addButton(withTitle: "Fermer")

        switch alert.runModal() {
        case .alertFirstButtonReturn: return .retry
        case .alertSecondButtonReturn: return .save
        default: return .dismiss
        }
    }
}

extension MenuBarController {
    func presentFailure(_ message: String) {
        // `flow.state` is still `.failed` right here, but `flow.handle` below
        // moves it to `.idle` before returning `.moveFileToSaveFolder` — by the
        // time that effect runs, the title can no longer be read from the
        // state. Remember it now so the safety-net move still gets it right.
        if case let .failed(configuration, _) = flow.state, !configuration.title.isEmpty {
            lastFailedTitle = configuration.title
        }

        switch FailureAlert.present(message: message, saveFolder: preferences.saveFolder) {
        case .retry:
            apply(flow.handle(.retryRequested))
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
    /// `.failureDismissed` safety net to also move into `saveFolder`.
    func saveCurrentFileWithPanel() {
        guard let source = currentFileURL else { return }
        let panel = NSSavePanel()
        panel.title = "Enregistrer l'audio de la réunion"
        panel.directoryURL = preferences.saveFolder
        panel.nameFieldStringValue = "\(suggestedFileName()).m4a"
        panel.allowedContentTypes = [.mpeg4Audio]

        guard panel.runModal() == .OK, let destination = panel.url else { return }
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.moveItem(at: source, to: destination)
        currentFileURL = nil
    }

    func moveCurrentFileToSaveFolder() {
        guard let source = currentFileURL else { return }
        guard FileManager.default.fileExists(atPath: source.path) else {
            currentFileURL = nil
            return
        }
        let destination = uniqueURL(in: preferences.saveFolder, name: suggestedFileName())
        try? FileManager.default.moveItem(at: source, to: destination)
        currentFileURL = nil
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
