import Foundation
import Testing
@testable import RecorderCore

@MainActor
private func makeCoordinator(_ session: FakeSession, in directory: URL) -> UploadCoordinator {
    let client = uploadTestClient(session)
    return UploadCoordinator(store: PendingUploadStore(fileURL: directory.appendingPathComponent("pending.json")),
                             directory: directory,
                             makeUploader: { ChunkedUploader(client: client, sleep: { _ in }) })
}

/// Waits for the running upload and any that the queue starts after it.
@MainActor
private func settle(_ coordinator: UploadCoordinator) async {
    while let task = coordinator.task { await task.value }
}

@MainActor
private func pauseFirstUpload(_ session: FakeSession, _ coordinator: UploadCoordinator,
                              in directory: URL) async throws -> UUID {
    session.script = [Replies.started(), Replies.networkDown, Replies.networkDown,
                      Replies.networkDown, Replies.networkDown]
    let id = try coordinator.enqueue(fileURL: try writeAudio(named: "first.m4a", in: directory),
                                     configuration: uploadTestConfiguration())
    await settle(coordinator)
    return id
}

@MainActor @Test func aCompletedUploadDeletesTheFileAndEmptiesTheQueue() async throws {
    let directory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = FakeSession()
    session.script = [Replies.started(), Replies.offset(4), Replies.offset(8), Replies.offset(10), Replies.created]
    let coordinator = makeCoordinator(session, in: directory)
    var completed: [String] = []
    coordinator.onCompleted = { completed.append($0.configuration.title) }
    let file = try writeAudio(in: directory)

    let id = try coordinator.enqueue(fileURL: file, configuration: uploadTestConfiguration())
    await settle(coordinator)

    #expect(completed == ["Daily"])
    #expect(!FileManager.default.fileExists(atPath: file.path))
    #expect(coordinator.queue.isEmpty)
    #expect(PendingUploadStore(fileURL: directory.appendingPathComponent("pending.json")).load().isEmpty)
    #expect(coordinator.activity == .idle)
    #expect(coordinator.status(of: id) == .finished)
}

@MainActor @Test func uploadsRunOneAtATimeInOrder() async throws {
    let directory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = FakeSession()
    session.script = [Replies.started("up-1", chunkSize: 16), Replies.offset(10), Replies.created,
                      Replies.started("up-2", chunkSize: 16), Replies.offset(10), Replies.created]
    let coordinator = makeCoordinator(session, in: directory)

    try coordinator.enqueue(fileURL: try writeAudio(named: "a.m4a", in: directory),
                            configuration: uploadTestConfiguration())
    let second = try coordinator.enqueue(fileURL: try writeAudio(named: "b.m4a", in: directory),
                                         configuration: uploadTestConfiguration())
    #expect(coordinator.status(of: second) == .waiting)
    #expect(coordinator.waitingCount == 1)
    await settle(coordinator)

    #expect(requestLines(session) == ["POST /recordings/uploads",
                                      "PUT /recordings/uploads/up-1?offset=0",
                                      "POST /recordings/uploads/up-1/complete",
                                      "POST /recordings/uploads",
                                      "PUT /recordings/uploads/up-2?offset=0",
                                      "POST /recordings/uploads/up-2/complete"])
}

@MainActor @Test func aPausedUploadResumesWhenTheNetworkComesBack() async throws {
    let directory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = FakeSession()
    let coordinator = makeCoordinator(session, in: directory)
    var notifications: [String] = []
    coordinator.notify = { title, _ in notifications.append(title) }

    let id = try await pauseFirstUpload(session, coordinator, in: directory)
    guard case .paused = coordinator.status(of: id) else {
        Issue.record("expected .paused, got \(coordinator.status(of: id))")
        return
    }
    #expect(notifications == ["Upload paused"])

    session.script = [Replies.status(offset: 0), Replies.offset(4), Replies.offset(8),
                      Replies.offset(10), Replies.created]
    coordinator.networkChanged(isAvailable: false)
    coordinator.networkChanged(isAvailable: true)
    await settle(coordinator)

    #expect(coordinator.status(of: id) == .finished)
    #expect(requestLines(session).suffix(5).first == "GET /recordings/uploads/up-1")
}

@MainActor @Test func aNetworkBlipWhileUploadingStartsNothingNew() async throws {
    let directory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = FakeSession()
    session.script = [Replies.started(), Replies.offset(4), Replies.offset(8), Replies.offset(10), Replies.created]
    let coordinator = makeCoordinator(session, in: directory)

    try coordinator.enqueue(fileURL: try writeAudio(in: directory), configuration: uploadTestConfiguration())
    coordinator.networkChanged(isAvailable: false)
    coordinator.networkChanged(isAvailable: true)
    await settle(coordinator)

    #expect(requestLines(session).filter { $0 == "POST /recordings/uploads" }.count == 1)
}

@MainActor @Test func aRejectedUploadLeavesTheQueueAndKeepsTheFile() async throws {
    let directory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = FakeSession()
    session.script = [.status(403, #"{"message":"Not a member","statusCode":403}"#)]
    let coordinator = makeCoordinator(session, in: directory)
    var failures: [UploadCoordinator.Failure] = []
    coordinator.onFailed = { _, failure in failures.append(failure) }
    let file = try writeAudio(in: directory)

    try coordinator.enqueue(fileURL: file, configuration: uploadTestConfiguration())
    await settle(coordinator)

    #expect(failures == [.rejected(.forbidden("Not a member"))])
    #expect(FileManager.default.fileExists(atPath: file.path))
    #expect(coordinator.queue.isEmpty)
}

@MainActor @Test func aRetryGoesRightAfterTheCurrentUpload() async throws {
    let directory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = FakeSession()
    let coordinator = makeCoordinator(session, in: directory)
    let first = try await pauseFirstUpload(session, coordinator, in: directory)
    let second = try coordinator.enqueue(fileURL: try writeAudio(named: "second.m4a", in: directory),
                                         configuration: uploadTestConfiguration())
    let retried = PendingUpload(fileName: "retried.m4a", size: 10, configuration: uploadTestConfiguration(),
                                uploadId: "up-9", chunkSize: 4, completeSent: true)

    coordinator.requeue(retried, startingOver: true)

    #expect(coordinator.queue.map(\.id) == [first, retried.id, second])
    #expect(coordinator.queue[1].uploadId == nil)
    #expect(coordinator.queue[1].completeSent == false)
    // Still paused: a retry never starts a second upload alongside the first.
    #expect(coordinator.task == nil)
}

@MainActor @Test func theQueueSurvivesARelaunch() async throws {
    let directory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = FakeSession()
    let before = makeCoordinator(session, in: directory)
    _ = try await pauseFirstUpload(session, before, in: directory)
    before.stop()

    let after = makeCoordinator(session, in: directory)
    #expect(after.queue.first?.uploadId == "up-1")
    session.script = [Replies.status(offset: 4), Replies.offset(8), Replies.offset(10), Replies.created]
    var notifications: [String] = []
    after.notify = { title, _ in notifications.append(title) }

    #expect(after.resumeAfterLaunch().isEmpty)
    await settle(after)

    #expect(notifications == ["Resuming upload"])
    #expect(requestLines(session).suffix(4) == ["GET /recordings/uploads/up-1",
                                                "PUT /recordings/uploads/up-1?offset=4",
                                                "PUT /recordings/uploads/up-1?offset=8",
                                                "POST /recordings/uploads/up-1/complete"])
    #expect(after.queue.isEmpty)
}

@MainActor @Test func aMissingFileIsDroppedAtLaunch() throws {
    let directory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try PendingUploadStore(fileURL: directory.appendingPathComponent("pending.json"))
        .save([PendingUpload(fileName: "gone.m4a", size: 10, configuration: uploadTestConfiguration())])
    let session = FakeSession()
    let coordinator = makeCoordinator(session, in: directory)

    #expect(coordinator.resumeAfterLaunch() == ["Daily"])
    #expect(coordinator.queue.isEmpty)
    #expect(coordinator.task == nil)
    #expect(session.calls.isEmpty)
}

@MainActor @Test func theSweepKnowsWhichFilesAreStillQueued() async throws {
    let directory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = FakeSession()
    let coordinator = makeCoordinator(session, in: directory)
    _ = try await pauseFirstUpload(session, coordinator, in: directory)
    #expect(coordinator.referencedFileNames == ["first.m4a"])
}

@MainActor @Test func stoppingAPausedUploadLetsTheNextOneGo() async throws {
    let directory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = FakeSession()
    let coordinator = makeCoordinator(session, in: directory)
    var failures: [(String, UploadCoordinator.Failure)] = []
    coordinator.onFailed = { failures.append(($0.fileName, $1)) }
    var completed: [String] = []
    coordinator.onCompleted = { completed.append($0.fileName) }
    _ = try await pauseFirstUpload(session, coordinator, in: directory)
    try coordinator.enqueue(fileURL: try writeAudio(named: "second.m4a", in: directory),
                            configuration: uploadTestConfiguration())
    session.script = [Replies.started("up-2", chunkSize: 16), Replies.offset(10), Replies.created]

    coordinator.stopPaused()
    await settle(coordinator)

    #expect(failures.map(\.0) == ["first.m4a"])
    #expect(failures.map(\.1) == [.stopped])
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("first.m4a").path))
    #expect(completed == ["second.m4a"])
    #expect(coordinator.queue.isEmpty)
    #expect(requestLines(session).contains("PUT /recordings/uploads/up-2?offset=0"))
}
