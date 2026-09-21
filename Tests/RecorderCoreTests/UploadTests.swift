import Foundation
import Testing
@testable import RecorderCore

private let base = URL(string: "https://whiteboard-api.kepochan.com")!

private func makeRecording(in directory: URL, tags: [RecorderCore.Tag] = []) throws -> RecordingUpload {
    let audio = directory.appendingPathComponent("rec.m4a")
    try Data("AUDIO".utf8).write(to: audio)
    return RecordingUpload(
        audioURL: audio,
        workspaceID: "uuid-1",
        title: "Daily",
        recordedAt: Date(timeIntervalSince1970: 1_789_655_520), // 2026-09-17T14:32:00Z
        language: "fr",
        sharingMode: "private",
        tags: tags
    )
}

private func withTemporaryDirectory(_ body: (URL) async throws -> Void) async rethrows {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(directory)
}

@Test func uploadSendsTheDeclaredFieldsAndNothingElse() async throws {
    var envelope = ""
    var request: URLRequest?
    var result: UploadedRecording?

    try await withTemporaryDirectory { directory in
        let session = FakeSession()
        session.nextStatus = 201
        session.nextBody = Data(#"{"id":"rec-1","noteId":"note-1","noteSlug":"daily-2026-09-17","status":"pending"}"#.utf8)
        let client = WhiteboardClient(baseURL: base, apiKey: { "wb_test" }, session: session)
        let recording = try makeRecording(in: directory, tags: [Tag(label: "japon", color: "red", count: 10)])

        result = try await client.upload(recording)

        let call = try #require(session.calls.first)
        request = call.request
        envelope = try String(contentsOf: #require(call.uploadedFile), encoding: .utf8)
    }

    #expect(result == UploadedRecording(id: "rec-1", noteSlug: "daily-2026-09-17", status: "pending"))
    #expect(request?.httpMethod == "POST")
    #expect(request?.url?.absoluteString == "https://whiteboard-api.kepochan.com/recordings")
    #expect(request?.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)

    #expect(envelope.contains(#"name="audio"; filename="rec.m4a""#))
    #expect(envelope.contains("Content-Type: audio/mp4"))
    #expect(envelope.contains("name=\"workspaceId\"\r\n\r\nuuid-1"))
    #expect(envelope.contains("name=\"title\"\r\n\r\nDaily"))
    #expect(envelope.contains("name=\"recordedAt\"\r\n\r\n2026-09-17T14:32:00Z"))
    #expect(envelope.contains("name=\"language\"\r\n\r\nfr"))
    #expect(envelope.contains("name=\"sharingMode\"\r\n\r\nprivate"))
    // Tags travel as a JSON string, colour included, usage count stripped.
    // Key order within the JSON object is not part of the contract, so the
    // two fields are asserted independently rather than as one fixed-order
    // substring (JSONEncoder does not guarantee key order).
    #expect(envelope.contains(#"name="tags""#))
    #expect(envelope.contains(#""label":"japon""#))
    #expect(envelope.contains(#""color":"red""#))
    #expect(!envelope.contains("count"))
    // The server derives the slug; sending an undeclared field would be a 400.
    #expect(!envelope.contains(#"name="slug""#))
}

@Test func tagsFieldIsOmittedWhenNoTagIsSelected() async throws {
    try await withTemporaryDirectory { directory in
        let session = FakeSession()
        session.nextStatus = 201
        session.nextBody = Data(#"{"id":"rec-1","noteSlug":"daily","status":"pending"}"#.utf8)
        let client = WhiteboardClient(baseURL: base, apiKey: { "wb_test" }, session: session)
        let recording = try makeRecording(in: directory)

        _ = try await client.upload(recording)

        let envelope = try String(contentsOf: #require(session.calls.first?.uploadedFile), encoding: .utf8)
        #expect(!envelope.contains(#"name="tags""#))
    }
}

@Test func aFutureMeetingDateIsRefusedBeforeReachingTheServer() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let session = FakeSession()
    let client = WhiteboardClient(baseURL: base, apiKey: { "wb_test" }, session: session)
    var recording = try makeRecording(in: directory)
    recording.recordedAt = Date().addingTimeInterval(3600)

    await #expect(throws: APIError.recordedAtInFuture) { _ = try await client.upload(recording) }
    #expect(session.calls.isEmpty)
}

@Test func anEmptyTitleIsRefusedBeforeReachingTheServer() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let session = FakeSession()
    let client = WhiteboardClient(baseURL: base, apiKey: { "wb_test" }, session: session)
    var recording = try makeRecording(in: directory)
    recording.title = "   "

    await #expect(throws: APIError.invalidTitle) { _ = try await client.upload(recording) }
    #expect(session.calls.isEmpty)
}

@Test func a2xxWithAnUnreadableBodyIsStillASuccess() async throws {
    // The server keeps no copy of the audio, so the caller deletes the only one
    // the moment this returns. A response shape this app does not recognise must
    // not turn an accepted upload into a failure that keeps the file and invites
    // the user to upload the same meeting a second time.
    try await withTemporaryDirectory { directory in
        let session = FakeSession()
        session.nextStatus = 201
        session.nextBody = Data(#"{"recordingId":"rec-1","state":"queued"}"#.utf8)
        let client = WhiteboardClient(baseURL: base, apiKey: { "wb_test" }, session: session)

        let result = try await client.upload(try makeRecording(in: directory))

        #expect(result == nil)
        #expect(session.calls.count == 1)
    }
}

@Test func anErrorStatusStillFails() async throws {
    // The flip side: only the body is forgiving, the status is not.
    try await withTemporaryDirectory { directory in
        let session = FakeSession()
        session.nextStatus = 401
        session.nextBody = Data(#"{"message":"Invalid or expired API key"}"#.utf8)
        let client = WhiteboardClient(baseURL: base, apiKey: { "wb_test" }, session: session)

        await #expect(throws: APIError.unauthorized("Invalid or expired API key")) {
            try await client.upload(try makeRecording(in: directory))
        }
    }
}
