import Foundation

public final class Preferences {
    public static let languages = ["auto", "fr", "en"]
    /// The only three the API accepts since WB #1125; anything else is a 400
    /// at `start`. Read-only access now exists only as a per-person invite.
    public static let sharingModes = ["private", "protected", "open-bar"]
    public static let defaultAPIBaseURL = URL(string: "https://whiteboard-api.kepochan.com")!

    /// French label for a language code. The raw code is what the API receives;
    /// this only ever reaches the screen.
    public static func languageName(_ code: String) -> String {
        switch code {
        case "auto": return "Detect automatically"
        case "fr": return "French"
        case "en": return "English"
        default: return code
        }
    }

    /// Tab label for a sharing mode, phrased as what the choice does rather
    /// than as the API token — `open-bar` means nothing to someone who has not
    /// read the Whiteboard documentation. The raw token is still what gets sent.
    public static func sharingModeName(_ mode: String) -> String {
        switch mode {
        case "private": return "Only me"
        case "protected": return "Share with team"
        case "open-bar": return "Anyone with the link"
        default: return mode
        }
    }

    /// The line under the tabs, worded as the Whiteboard web app words it.
    public static func sharingModeHelp(_ mode: String) -> String {
        switch mode {
        case "private": return "You and the people you invite"
        case "protected": return "Workspace members can edit, plus the people you invite"
        case "open-bar": return "Anyone with the link can view and edit, even signed out"
        default: return ""
        }
    }

    /// A token from before the three modes, as a 1.1.0 left it in the
    /// preferences or the queue, turned into one the API accepts. Same table
    /// as the backend's `fromLegacySharingMode`: nothing becomes more open
    /// than it was, so `public` falls back to `private`.
    public static func currentSharingMode(_ mode: String) -> String {
        switch mode {
        case _ where sharingModes.contains(mode): return mode
        case "limited", "editable": return "protected"
        default: return "private"
        }
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var defaultWorkspaceID: String? {
        get { defaults.string(forKey: "defaultWorkspaceID") }
        set { defaults.set(newValue, forKey: "defaultWorkspaceID") }
    }

    public var lastWorkspaceID: String? {
        get { defaults.string(forKey: "lastWorkspaceID") }
        set { defaults.set(newValue, forKey: "lastWorkspaceID") }
    }

    /// The workspace the configuration window opens on.
    public var effectiveWorkspaceID: String? {
        lastWorkspaceID ?? defaultWorkspaceID
    }

    public var lastLanguage: String {
        get { defaults.string(forKey: "lastLanguage") ?? "fr" }
        set { defaults.set(newValue, forKey: "lastLanguage") }
    }

    public var lastSharingMode: String {
        get { Self.currentSharingMode(defaults.string(forKey: "lastSharingMode") ?? "private") }
        set { defaults.set(newValue, forKey: "lastSharingMode") }
    }

    public var apiBaseURL: URL {
        get {
            defaults.string(forKey: "apiBaseURL").flatMap(URL.init(string:)) ?? Self.defaultAPIBaseURL
        }
        set { defaults.set(newValue.absoluteString, forKey: "apiBaseURL") }
    }

    /// Empty means the ESP32 integration is off.
    public var esp32Host: String? {
        get {
            let host = (defaults.string(forKey: "esp32Host") ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return host.isEmpty ? nil : host
        }
        set { defaults.set(newValue ?? "", forKey: "esp32Host") }
    }

    public var saveFolder: URL {
        get {
            defaults.string(forKey: "saveFolder").map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        }
        set { defaults.set(newValue.path, forKey: "saveFolder") }
    }
}
