import Foundation

public final class Preferences {
    public static let languages = ["auto", "fr", "en"]
    public static let sharingModes = ["private", "protected", "limited", "editable", "public", "open-bar"]
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

    /// French label for a sharing mode, phrased as what the choice does rather
    /// than as a translation of the API token — `limited` or `open-bar` mean
    /// nothing to someone who has not read the Whiteboard documentation. The
    /// raw token is still what gets sent.
    public static func sharingModeName(_ mode: String) -> String {
        switch mode {
        case "private": return "Private — only me"
        case "protected": return "Workspace — read"
        case "limited": return "Workspace — by invitation"
        case "editable": return "Workspace — read and edit"
        case "public": return "Public — read with the link"
        case "open-bar": return "Public — read and edit with the link"
        default: return mode
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
        get { defaults.string(forKey: "lastLanguage") ?? "auto" }
        set { defaults.set(newValue, forKey: "lastLanguage") }
    }

    public var lastSharingMode: String {
        get { defaults.string(forKey: "lastSharingMode") ?? "private" }
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
