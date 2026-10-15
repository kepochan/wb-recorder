import Foundation
import Testing
@testable import RecorderCore

private func makePreferences() -> Preferences {
    let suite = UserDefaults(suiteName: "wbr-tests-\(UUID().uuidString)")!
    return Preferences(defaults: suite)
}

@Test func defaultsMatchTheSpec() {
    let preferences = makePreferences()
    #expect(preferences.apiBaseURL.absoluteString == "https://whiteboard-api.kepochan.com")
    #expect(preferences.lastLanguage == "fr")
    #expect(preferences.lastSharingMode == "private")
    #expect(preferences.esp32Host == nil)
    #expect(preferences.saveFolder.path.hasSuffix("/Downloads"))
    #expect(Preferences.languages == ["auto", "fr", "en"])
    #expect(Preferences.sharingModes == ["private", "protected", "limited", "editable", "public", "open-bar"])
    #expect(Preferences.quickSharingModes.allSatisfy(Preferences.sharingModes.contains))
}

@Test func valuesSurviveAWriteAndRead() {
    let preferences = makePreferences()
    preferences.lastWorkspaceID = "uuid-1"
    preferences.lastLanguage = "fr"
    preferences.lastSharingMode = "public"
    preferences.apiBaseURL = URL(string: "http://localhost:3000")!
    preferences.esp32Host = "10.93.1.238"

    #expect(preferences.lastWorkspaceID == "uuid-1")
    #expect(preferences.lastLanguage == "fr")
    #expect(preferences.lastSharingMode == "public")
    #expect(preferences.apiBaseURL.absoluteString == "http://localhost:3000")
    #expect(preferences.esp32Host == "10.93.1.238")
}

@Test func anEmptyEsp32HostMeansDisabled() {
    let preferences = makePreferences()
    preferences.esp32Host = "   "
    #expect(preferences.esp32Host == nil)
}

@Test func theLastWorkspaceWinsOverTheDefaultOne() {
    let preferences = makePreferences()
    preferences.defaultWorkspaceID = "uuid-default"
    #expect(preferences.effectiveWorkspaceID == "uuid-default")
    preferences.lastWorkspaceID = "uuid-last"
    #expect(preferences.effectiveWorkspaceID == "uuid-last")
}

@Test func bothPickersHaveAReadableLabelForEveryRawValue() {
    // The raw values are the contract with the API; these are only ever read.
    for code in Preferences.languages {
        #expect(Preferences.languageName(code) != code)
    }
    for mode in Preferences.sharingModes {
        #expect(Preferences.sharingModeName(mode) != mode)
    }
    #expect(Preferences.languageName("fr") == "French")
    #expect(Preferences.sharingModeName("open-bar").hasPrefix("Public"))
    // An unknown value coming back from a future API still shows as itself
    // rather than as an empty picker row.
    #expect(Preferences.sharingModeName("teams-only") == "teams-only")
    #expect(Preferences.sharingModeShortName("private") == "Only me")
    #expect(Preferences.sharingModeShortName("editable") == "Share with team")
    #expect(Preferences.sharingModeShortName("public") == Preferences.sharingModeName("public"))
}
