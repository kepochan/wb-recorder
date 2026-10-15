import Foundation
import Testing
@testable import RecorderCore

/// Collects what the uploader reports, from whichever thread it reports it on.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _persisted: [PendingUpload] = []
    private var _sleeps: [Duration] = []
    var persisted: [PendingUpload] { lock.withLock { _persisted } }
    var sleeps: [Duration] { lock.withLock { _sleeps } }
    func persist(_ upload: PendingUpload) { lock.withLock { _persisted.append(upload) } }
    func slept(_ duration: Duration) { lock.withLock { _sleeps.append(duration) } }
}

private func run(_ upload: PendingUpload, in directory: URL, session: FakeSession,
                 recorder: Recorder) async throws -> UploadOutcome {
    let uploader = ChunkedUploader(client: uploadTestClient(session), sleep: { recorder.slept($0) })
    return try await uploader.run(upload, directory: directory,
                                  progress: { _, _ in },
                                  persist: { recorder.persist($0) })
}

private func freshUpload() -> PendingUpload {
    PendingUpload(fileName: "rec.m4a", size: 10, configuration: uploadTestConfiguration())
}

@Test func theFileGoesInPiecesThenIsCompleted() async throws {
    let directory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try writeAudio(in: directory)
    let session = FakeSession()
    session.script = [Replies.started(), Replies.offset(4), Replies.offset(8), Replies.offset(10), Replies.created]
    let recorder = Recorder()

    let outcome = try await run(freshUpload(), in: directory, session: session, recorder: recorder)

    #expect(outcome == .completed(Replies.createdRecording))
    #expect(requestLines(session) == ["POST /recordings/uploads",
                                      "PUT /recordings/uploads/up-1?offset=0",
                                      "PUT /recordings/uploads/up-1?offset=4",
                                      "PUT /recordings/uploads/up-1?offset=8",
                                      "POST /recordings/uploads/up-1/complete"])
    // Read piece by piece from disk, never more than the piece size at once.
    #expect(session.calls[1...3].map(bodyText) == ["ABCD", "EFGH", "IJ"])
    #expect(recorder.persisted.first?.uploadId == "up-1")
    #expect(recorder.persisted.first?.chunkSize == 4)
    #expect(recorder.persisted.last?.completeSent == true)
    #expect(recorder.sleeps.isEmpty)
}

@Test func anOffsetConflictRealignsWithoutCountingAFailure() async throws {
    let directory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try writeAudio(in: directory)
    let session = FakeSession()
    session.script = [Replies.started(),
                      .status(409, #"{"message":"Offset does not match the bytes received","offset":8}"#),
                      Replies.offset(10), Replies.created]
    let recorder = Recorder()

    let outcome = try await run(freshUpload(), in: directory, session: session, recorder: recorder)

    #expect(outcome == .completed(Replies.createdRecording))
    #expect(requestLines(session)[1...2] == ["PUT /recordings/uploads/up-1?offset=0",
                                             "PUT /recordings/uploads/up-1?offset=8"])
    #expect(recorder.sleeps.isEmpty)
}

@Test func aNetworkFailureResumesFromTheServerOffset() async throws {
    let directory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try writeAudio(in: directory)
    let session = FakeSession()
    // The second piece's answer is lost, but the server kept it: GET says 8.
    session.script = [Replies.started(), Replies.offset(4), Replies.networkDown,
                      Replies.status(offset: 8), Replies.offset(10), Replies.created]
    let recorder = Recorder()

    let outcome = try await run(freshUpload(), in: directory, session: session, recorder: recorder)

    #expect(outcome == .completed(Replies.createdRecording))
    #expect(requestLines(session) == ["POST /recordings/uploads",
                                      "PUT /recordings/uploads/up-1?offset=0",
                                      "PUT /recordings/uploads/up-1?offset=4",
                                      "GET /recordings/uploads/up-1",
                                      "PUT /recordings/uploads/up-1?offset=8",
                                      "POST /recordings/uploads/up-1/complete"])
    #expect(recorder.sleeps == [.seconds(1)])
}

@Test func theFourthFailureInARowPauses() async throws {
    let directory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try writeAudio(in: directory)
    let session = FakeSession()
    session.script = [Replies.started(), .failure(.timedOut), .failure(.timedOut),
                      .failure(.timedOut), .failure(.timedOut)]
    let recorder = Recorder()

    let outcome = try await run(freshUpload(), in: directory, session: session, recorder: recorder)

    guard case .paused = outcome else {
        Issue.record("expected .paused, got \(outcome)")
        return
    }
    #expect(recorder.sleeps == [.seconds(1), .seconds(2), .seconds(4)])
}

@Test func aSuccessResetsTheFailureCount() async throws {
    let directory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try writeAudio(in: directory)
    let session = FakeSession()
    session.script = [Replies.started(),
                      Replies.networkDown, Replies.status(offset: 0), Replies.offset(4),
                      Replies.networkDown, Replies.status(offset: 4), Replies.offset(8),
                      Replies.offset(10), Replies.created]
    let recorder = Recorder()

    let outcome = try await run(freshUpload(), in: directory, session: session, recorder: recorder)

    #expect(outcome == .completed(Replies.createdRecording))
    #expect(recorder.sleeps == [.seconds(1), .seconds(1)])
}

@Test func a404BeforeCompleteStartsAFreshSession() async throws {
    let directory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try writeAudio(in: directory)
    let session = FakeSession()
    session.script = [Replies.started(), Replies.offset(4), Replies.notFound,
                      Replies.started("up-2"), Replies.offset(4), Replies.offset(8), Replies.offset(10),
                      Replies.created]
    let recorder = Recorder()

    let outcome = try await run(freshUpload(), in: directory, session: session, recorder: recorder)

    #expect(outcome == .completed(Replies.createdRecording))
    #expect(requestLines(session)[3...4] == ["POST /recordings/uploads",
                                             "PUT /recordings/uploads/up-2?offset=0"])
    #expect(recorder.sleeps.isEmpty)
}

@Test func a404AfterCompleteWasSentIsNeverUploadedAgain() async throws {
    let directory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try writeAudio(in: directory)
    let session = FakeSession()
    session.script = [Replies.notFound]
    var upload = freshUpload()
    upload.uploadId = "up-1"
    upload.chunkSize = 4
    upload.completeSent = true

    let outcome = try await run(upload, in: directory, session: session, recorder: Recorder())

    #expect(outcome == .maybeAlreadyUploaded)
    #expect(requestLines(session) == ["GET /recordings/uploads/up-1"])
}

@Test func aSessionAlreadyFinishedIsCompletedNotResent() async throws {
    let directory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try writeAudio(in: directory)
    let session = FakeSession()
    session.script = [Replies.status(offset: 10, recordingId: "rec-1"), Replies.created]
    var upload = freshUpload()
    upload.uploadId = "up-1"
    upload.chunkSize = 4
    upload.completeSent = true

    let outcome = try await run(upload, in: directory, session: session, recorder: Recorder())

    #expect(outcome == .completed(Replies.createdRecording))
    #expect(requestLines(session) == ["GET /recordings/uploads/up-1",
                                      "POST /recordings/uploads/up-1/complete"])
}

@Test func aTakenSlugFallsBackToTheDefaultOne() async throws {
    let directory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try writeAudio(in: directory)
    let session = FakeSession()
    session.script = [Replies.started(), Replies.offset(4), Replies.offset(8), Replies.offset(10),
                      .status(409, #"{"message":"Slug already taken","statusCode":409}"#), Replies.created]

    let outcome = try await run(freshUpload(), in: directory, session: session, recorder: Recorder())

    #expect(outcome == .completed(Replies.createdRecording))
    #expect(session.calls.suffix(2).map(bodyText) == ["{}", #"{"slug":null}"#])
}

@Test func aRejectionIsFinal() async throws {
    let directory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try writeAudio(in: directory)
    let session = FakeSession()
    session.script = [.status(403, #"{"message":"Not a member","statusCode":403}"#)]
    let recorder = Recorder()

    let outcome = try await run(freshUpload(), in: directory, session: session, recorder: recorder)

    #expect(outcome == .failed(.forbidden("Not a member")))
    #expect(recorder.sleeps.isEmpty)
}

@Test func aMissingFileFailsBeforeAnyRequest() async throws {
    let directory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = FakeSession()

    let outcome = try await run(freshUpload(), in: directory, session: session, recorder: Recorder())

    #expect(outcome == .failed(.fileMissing))
    #expect(session.calls.isEmpty)
}
