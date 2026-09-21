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
    }

    func save() {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty field means "remove the key", not "store an empty
        // string" — writing "" would make `keychain.read()` return a
        // non-nil, unusable value, which every call site that checks for
        // "no key configured" treats differently from "a key is set".
        if trimmedKey.isEmpty {
            keychain.delete()
        } else {
            try? keychain.save(trimmedKey)
        }
        if let url = URL(string: apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)) {
            preferences.apiBaseURL = url
        }
        preferences.esp32Host = esp32Host
        preferences.saveFolder = saveFolder
        preferences.defaultWorkspaceID = defaultWorkspaceID.isEmpty ? nil : defaultWorkspaceID
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
