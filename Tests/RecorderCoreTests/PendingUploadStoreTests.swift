import Foundation
import Testing
@testable import RecorderCore

private func makeStore() -> (PendingUploadStore, URL) {
    let directory = makeTemporaryDirectory()
    return (PendingUploadStore(fileURL: directory.appendingPathComponent("pending-uploads.json")), directory)
}

@Test func theQueueSurvivesAWriteAndARead() throws {
    let (store, directory) = makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = PendingUpload(fileName: "a.m4a", size: 10,
                              configuration: uploadTestConfiguration(tags: [Tag(label: "japon", color: "red")]))
    let second = PendingUpload(fileName: "b.m4a", size: 20, configuration: uploadTestConfiguration(),
                               uploadId: "up-2", chunkSize: 4_194_304, completeSent: true)

    try store.save([first, second])

    #expect(store.load() == [first, second])
}

@Test func aQueuedOldModeIsConvertedOnLoad() throws {
    // A 1.1.0 queue may hold the old tokens. With or without a session: a
    // purged one means a fresh `start`, which would refuse them with a 400.
    let (store, directory) = makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    var configuration = uploadTestConfiguration()
    configuration.sharingMode = "editable"
    let waiting = PendingUpload(fileName: "a.m4a", size: 10, configuration: configuration)
    configuration.sharingMode = "public"
    let started = PendingUpload(fileName: "b.m4a", size: 20, configuration: configuration,
                                uploadId: "up-2", chunkSize: 4_194_304)

    try store.save([waiting, started])
    let loaded = store.load()

    #expect(loaded.map(\.configuration.sharingMode) == ["protected", "private"])
    #expect(loaded.map(\.uploadId) == [nil, "up-2"])
    #expect(loaded.map(\.id) == [waiting.id, started.id])
}

@Test func noFileMeansAnEmptyQueue() {
    let (store, directory) = makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(store.load().isEmpty)
}

@Test func aCorruptStoreYieldsAnEmptyQueue() throws {
    // The recordings it named are still in the working folder; the launch
    // sweep moves them to the save folder rather than losing them.
    let (store, directory) = makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("{ not json".utf8).write(to: store.fileURL)
    #expect(store.load().isEmpty)
}

@Test func theFileIsFoundByNameInTheWorkingFolder() {
    let upload = PendingUpload(fileName: "rec.m4a", size: 10, configuration: uploadTestConfiguration())
    let folder = URL(fileURLWithPath: "/tmp/recordings", isDirectory: true)
    #expect(upload.fileURL(in: folder).path == "/tmp/recordings/rec.m4a")
}

@Test func theStoreSitsNextToTheRecordingsFolder() {
    #expect(PendingUploadStore.defaultFileURL.lastPathComponent == "pending-uploads.json")
    #expect(PendingUploadStore.defaultFileURL.deletingLastPathComponent()
            == RecordingStorage.directory.deletingLastPathComponent())
}

@Test func oneBadEntryDoesNotDropTheOthers() throws {
    let (store, directory) = makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = PendingUpload(fileName: "a.m4a", size: 10, configuration: uploadTestConfiguration())
    let second = PendingUpload(fileName: "b.m4a", size: 20, configuration: uploadTestConfiguration())
    try store.save([first, second])

    var entries = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [Any])
    entries.insert(["id": "broken"], at: 1)
    try JSONSerialization.data(withJSONObject: entries).write(to: store.fileURL)

    #expect(store.load() == [first, second])
}
