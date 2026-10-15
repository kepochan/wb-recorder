import Foundation
@testable import RecorderCore

let uploadTestBase = URL(string: "https://whiteboard-api.kepochan.com")!
/// 2026-09-17T14:32:00Z
let uploadTestDate = Date(timeIntervalSince1970: 1_789_655_520)

func uploadTestConfiguration(tags: [RecorderCore.Tag] = []) -> RecordingConfiguration {
    RecordingConfiguration(workspaceID: "uuid-1", title: "Daily", recordedAt: uploadTestDate,
                           language: "fr", sharingMode: "private", tags: tags)
}

func uploadTestClient(_ session: FakeSession) -> WhiteboardClient {
    WhiteboardClient(baseURL: uploadTestBase, apiKey: { "wb_test" }, session: session)
}

func makeTemporaryDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

/// Ten bytes, so a 4-byte piece size gives pieces of 4, 4 and 2.
@discardableResult
func writeAudio(named name: String = "rec.m4a", in directory: URL) throws -> URL {
    let url = directory.appendingPathComponent(name)
    try Data("ABCDEFGHIJ".utf8).write(to: url)
    return url
}

/// "METHOD /path?query" for every request, in order.
func requestLines(_ session: FakeSession) -> [String] {
    session.calls.map { call in
        let url = call.request.url!
        return "\(call.request.httpMethod ?? "GET") \(url.path)\(url.query.map { "?\($0)" } ?? "")"
    }
}

func bodyText(_ call: FakeSession.Call) -> String {
    call.request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
}

enum Replies {
    static func started(_ id: String = "up-1", chunkSize: Int = 4, size: Int = 10) -> FakeSession.Reply {
        .status(201, #"{"uploadId":"\#(id)","offset":0,"size":\#(size),"chunkSize":\#(chunkSize)}"#)
    }

    static func offset(_ value: Int) -> FakeSession.Reply {
        .status(200, #"{"offset":\#(value)}"#)
    }

    static func status(offset: Int, size: Int = 10, recordingId: String? = nil) -> FakeSession.Reply {
        let id = recordingId.map { "\"\($0)\"" } ?? "null"
        return .status(200, #"{"offset":\#(offset),"size":\#(size),"recordingId":\#(id)}"#)
    }

    static let created = FakeSession.Reply.status(
        201, #"{"id":"rec-1","noteId":"note-1","noteSlug":"daily-2026-09-17","status":"pending"}"#)
    static let createdRecording = UploadedRecording(id: "rec-1", noteSlug: "daily-2026-09-17", status: "pending")
    static let notFound = FakeSession.Reply.status(404, #"{"message":"Upload not found","statusCode":404}"#)
    static let networkDown = FakeSession.Reply.failure(.networkConnectionLost)
}
