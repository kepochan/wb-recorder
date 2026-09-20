import Foundation
import Testing
@testable import RecorderCore

@Test func theKeyCanBeSavedReadReplacedAndDeleted() throws {
    let store = KeychainStore(service: "wbr-tests-\(UUID().uuidString)")
    defer { store.delete() }

    #expect(store.read() == nil)

    do {
        try store.save("wb_first")
    } catch KeychainStore.Failure.unavailable {
        // Unsigned SPM test binaries cannot always reach the login keychain.
        // The behaviour is then covered by the app's Preferences window instead.
        return
    }

    #expect(store.read() == "wb_first")

    try store.save("wb_second")
    #expect(store.read() == "wb_second")

    store.delete()
    #expect(store.read() == nil)
}
