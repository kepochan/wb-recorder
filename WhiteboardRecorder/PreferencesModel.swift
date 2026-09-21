import AppKit
import Foundation
import SwiftUI

@MainActor
final class PreferencesModel: ObservableObject {
    @Published var apiKey: String = ""
    @Published var apiBaseURL: String = ""
    @Published var esp32Host: String = ""
    @Published var saveFolder: URL
    @Published var workspaces: [Workspace] = []
    @Published var defaultWorkspaceID: String = ""
    @Published var testResult: String?
    /// Set by `save()` when the API key couldn't be written to the Keychain
    /// or the API URL was rejected. Both failures are silent otherwise —
    /// this is the one place the user is told why nothing (or only part of
    /// what they typed) was actually persisted.
    @Published var saveError: String?

    private let preferences: Preferences
    private let keychain: KeychainStore

    init(preferences: Preferences, keychain: KeychainStore) {
        self.preferences = preferences
        self.keychain = keychain
        self.saveFolder = preferences.saveFolder
        reload()
    }

    /// Repopulates every field from the persisted source of truth (Keychain +
    /// Preferences), discarding whatever is currently sitting unsaved in the
    /// fields. Called from `init` and again whenever the window is reopened
    /// after being closed without saving, so a stale edit from a previous
    /// session can never resurface.
    func reload() {
        apiKey = keychain.read() ?? ""
        apiBaseURL = preferences.apiBaseURL.absoluteString
        esp32Host = preferences.esp32Host ?? ""
        saveFolder = preferences.saveFolder
        defaultWorkspaceID = preferences.defaultWorkspaceID ?? ""
        testResult = nil
        saveError = nil
    }

    func save() {
        var errors: [String] = []

        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty field means "remove the key", not "store an empty
        // string" — writing "" would make `keychain.read()` return a
        // non-nil, unusable value, which every call site that checks for
        // "no key configured" treats differently from "a key is set".
        if trimmedKey.isEmpty {
            keychain.delete()
        } else {
            do {
                try keychain.save(trimmedKey)
            } catch {
                // The key is the app's only credential: a swallowed write
                // failure would leave the user certain they're configured
                // while every recording fails to upload. Say so instead.
                errors.append("La clé API n'a pas pu être enregistrée dans le Trousseau.")
            }
        }

        let trimmedURL = apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedURL.isEmpty {
            // An explicitly cleared field restores the default instead of
            // silently keeping whatever URL was stored before.
            preferences.apiBaseURL = Preferences.defaultAPIBaseURL
            apiBaseURL = Preferences.defaultAPIBaseURL.absoluteString
        } else if let url = Self.validatedAPIBaseURL(trimmedURL) {
            preferences.apiBaseURL = url
        } else {
            // URL(string:) is lenient — "example.com" or "not a url" both
            // parse into a technically-valid but unusable URL. Reject
            // anything without an http(s) scheme and a host instead of
            // silently saving an endpoint the app can never reach, and
            // leave the previously stored value untouched.
            errors.append("URL de l'API invalide : elle doit commencer par http:// ou https:// et indiquer un serveur.")
        }

        preferences.esp32Host = esp32Host
        preferences.saveFolder = saveFolder
        preferences.defaultWorkspaceID = defaultWorkspaceID.isEmpty ? nil : defaultWorkspaceID

        saveError = errors.isEmpty ? nil : errors.joined(separator: "\n")
    }

    private static func validatedAPIBaseURL(_ string: String) -> URL? {
        guard let url = URL(string: string),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }

    func test() async {
        save()
        do {
            let client = WhiteboardClient(baseURL: preferences.apiBaseURL, apiKey: { [keychain] in keychain.read() })
            workspaces = try await client.listWorkspaces()
            testResult = "Clé valide — \(workspaces.count) workspace(s)."
        } catch let error as APIError {
            testResult = error.message
        } catch {
            testResult = error.localizedDescription
        }
    }

    func chooseSaveFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = saveFolder
        if panel.runModal() == .OK, let url = panel.url { saveFolder = url }
    }
}
