import Foundation
import Testing
@testable import RecorderCore

@Test func startSendsTheMetadataAndTheFileDescriptionAsJSON() async throws {
    let session = FakeSession()
    session.script = [Replies.started()]
    let configuration = uploadTestConfiguration(tags: [Tag(label: "japon", color: "red", count: 10)])

    let started = try await uploadTestClient(session)
        .startUpload(configuration: configuration, size: 10, filename: "rec.m4a")

    #expect(started.uploadId == "up-1")
    #expect(started.chunkSize == 4)
    let request = try #require(session.calls.first?.request)
    #expect(requestLines(session) == ["POST /recordings/uploads"])
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(request.value(forHTTPHeaderField: "X-API-Key") == "wb_test")

    let body = try #require(request.httpBody)
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(Set(json.keys) == ["workspaceId", "title", "recordedAt", "language", "sharingMode",
                               "tags", "size", "mimeType", "filename"])
    #expect(json["workspaceId"] as? String == "uuid-1")
    #expect(json["recordedAt"] as? String == "2026-09-17T14:32:00Z")
    #expect(json["size"] as? Int == 10)
    #expect(json["mimeType"] as? String == "audio/mp4")
    #expect(json["filename"] as? String == "rec.m4a")
    // A real array here, not the JSON string the multipart form carried, and
    // without the usage count that only ever comes back from the server.
    let tags = try #require(json["tags"] as? [[String: Any]])
    #expect(tags.count == 1)
    #expect(tags.first?["label"] as? String == "japon")
    #expect(tags.first?["count"] == nil)
}

@Test func startLeavesTagsOutWhenNoneIsSelected() async throws {
    let session = FakeSession()
    session.script = [Replies.started()]
    _ = try await uploadTestClient(session).startUpload(configuration: uploadTestConfiguration(),
                                                        size: 10, filename: "rec.m4a")
    let body = try #require(session.calls.first?.request.httpBody)
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(json["tags"] == nil)
}

@Test func startRefusesAnEmptyTitleBeforeReachingTheServer() async {
    let session = FakeSession()
    var configuration = uploadTestConfiguration()
    configuration.title = "   "
    await #expect(throws: APIError.invalidTitle) {
        _ = try await uploadTestClient(session).startUpload(configuration: configuration, size: 10, filename: "rec.m4a")
    }
    #expect(session.calls.isEmpty)
}

@Test func aChunkIsPutAsRawBytesAtItsOffset() async throws {
    let session = FakeSession()
    session.script = [Replies.offset(8)]

    let result = try await uploadTestClient(session)
        .putChunk(uploadId: "up-1", offset: 4, data: Data("EFGH".utf8))

    #expect(result == .advanced(to: 8))
    #expect(requestLines(session) == ["PUT /recordings/uploads/up-1?offset=4"])
    let call = try #require(session.calls.first)
    #expect(call.request.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream")
    #expect(bodyText(call) == "EFGH")
}

@Test func anOffsetConflictTellsWhereTheServerIs() async throws {
    let session = FakeSession()
    session.script = [.status(409, #"{"message":"Offset does not match the bytes received","offset":4}"#)]
    let result = try await uploadTestClient(session).putChunk(uploadId: "up-1", offset: 8, data: Data("IJ".utf8))
    #expect(result == .offsetMismatch(serverOffset: 4))
}

@Test func anAlreadyCompletedSessionIsRecognised() async throws {
    let session = FakeSession()
    session.script = [.status(409, #"{"message":"Upload already completed","offset":10}"#)]
    let result = try await uploadTestClient(session).putChunk(uploadId: "up-1", offset: 8, data: Data("IJ".utf8))
    #expect(result == .alreadyCompleted)
}

@Test func statusReadsTheServerOffset() async throws {
    let session = FakeSession()
    session.script = [Replies.status(offset: 4)]
    let status = try await uploadTestClient(session).uploadStatus(uploadId: "up-1")
    #expect(status.offset == 4)
    #expect(status.recordingId == nil)
    #expect(requestLines(session) == ["GET /recordings/uploads/up-1"])
}

@Test func completeSendsAnEmptyBodyUnlessTheDefaultSlugIsAsked() async throws {
    let session = FakeSession()
    session.script = [Replies.created, Replies.created]
    let client = uploadTestClient(session)

    #expect(try await client.completeUpload(uploadId: "up-1", useDefaultSlug: false)
            == .completed(Replies.createdRecording))
    #expect(try await client.completeUpload(uploadId: "up-1", useDefaultSlug: true)
            == .completed(Replies.createdRecording))

    #expect(requestLines(session) == ["POST /recordings/uploads/up-1/complete",
                                      "POST /recordings/uploads/up-1/complete"])
    #expect(bodyText(session.calls[0]) == "{}")
    #expect(bodyText(session.calls[1]) == #"{"slug":null}"#)
}

@Test func completeReportsMissingBytesAndATakenSlug() async throws {
    let session = FakeSession()
    session.script = [.status(409, #"{"message":"Upload is not complete","offset":8}"#),
                      .status(409, #"{"message":"Slug already taken","statusCode":409}"#)]
    let client = uploadTestClient(session)
    #expect(try await client.completeUpload(uploadId: "up-1", useDefaultSlug: false) == .notComplete(serverOffset: 8))
    #expect(try await client.completeUpload(uploadId: "up-1", useDefaultSlug: false) == .slugTaken)
}

@Test func completeWithAnUnreadableBodyIsStillASuccess() async throws {
    let session = FakeSession()
    session.script = [.status(201, "not json")]
    #expect(try await uploadTestClient(session).completeUpload(uploadId: "up-1", useDefaultSlug: false)
            == .completed(nil))
}

@Test func onlyNetworkAndServerFailuresAreWorthRetrying() {
    #expect(APIError.isTransient(URLError(.timedOut)))
    #expect(APIError.isTransient(URLError(.notConnectedToInternet)))
    #expect(APIError.isTransient(APIError.server(status: 502, "")))
    #expect(APIError.isTransient(APIError.invalidResponse))
    #expect(!APIError.isTransient(APIError.forbidden("")))
    #expect(!APIError.isTransient(APIError.unauthorized("")))
    #expect(!APIError.isTransient(APIError.badRequest([])))
    #expect(!APIError.isTransient(APIError.fileMissing))
}
