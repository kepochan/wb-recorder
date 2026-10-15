# Resumable chunked upload — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the single `POST /recordings` upload with the server's resumable chunked upload, run in a background queue that survives quits, pauses after repeated failures and resumes when the network comes back.

**Architecture:** Three new units in `RecorderCore` (testable without network or AppKit): the four API calls on `WhiteboardClient`, a `ChunkedUploader` that drives one upload to its end, and an `UploadCoordinator` that owns a persisted FIFO queue and runs one uploader at a time. The app wires the coordinator to the menu bar, the configuration window, notifications and `NWPathMonitor`; `RecordingFlow` stops handling uploads and only hands the file over.

**Tech Stack:** Swift (tools 6.0, Swift 5 language mode), SwiftUI + AppKit, Swift Testing, Foundation `URLSession`, Combine, Network (`NWPathMonitor`), UserNotifications, `os.Logger`.

**Spec:** `docs/superpowers/specs/2026-10-15-resumable-upload-design.md` — read it before starting. The API contract is in the Whiteboard note `whiteboard-recorder-resumable-upload-prompt` (summarised in the spec and in Task 1).

## Global Constraints

- Deployment target macOS 14.4; Swift 5 language mode (see `Package.swift`). No new dependencies.
- Every user-facing string is in **English**.
- `POST /recordings` is no longer called; every file goes through the chunked path.
- No slug is ever sent; `{ "slug": null }` is sent to `complete` only after a slug `409`.
- `start` body: `workspaceId`, `title`, `recordedAt` (ISO 8601 UTC), `language`, `sharingMode`, `tags` (real JSON array, **omitted when empty**), `size`, `mimeType: "audio/mp4"`, `filename`. No other field (the server rejects unknown ones with 400).
- Use the `chunkSize` returned by `start`; never more than one `PUT` in flight.
- Transient failure (network `URLError`, timeout, 5xx, unreadable response) → wait 1 s, 2 s, 4 s; ask the server's offset (`GET`) before each new attempt; the **4th consecutive** failure pauses.
- A `404` after `complete` was sent is never re-uploaded automatically.
- The local file is deleted only after `complete` returns 2xx.
- Run core tests with `swift test`. Build the app with
  `xcodebuild -project WhiteboardRecorder.xcodeproj -scheme WhiteboardRecorder -configuration Debug -derivedDataPath build build`.
  The Xcode project uses synchronized folders: new files under `WhiteboardRecorder/` and `Sources/RecorderCore/` are picked up without editing `project.pbxproj`.
- Match the codebase: comments explain *why*, in full sentences; conventional commit messages (`feat:`, `fix:`, `docs:`, `test:`, `refactor:`).

## Review Focus

1. **Quit while `complete` is in flight, relaunch after the session was purged** → the app must flag "may already be on Whiteboard", never create a second note. Pinned in Task 3 (`a404AfterCompleteWasSentIsNeverUploadedAgain`) and Task 4 (`theQueueSurvivesARelaunch`).
2. **Wi-Fi drops long enough to pause, then returns** → exactly one automatic resume, and a network blip while an upload runs starts nothing in parallel. Pinned in Task 4 (`aPausedUploadResumesWhenTheNetworkComesBack`, `aNetworkBlipWhileUploadingStartsNothingNew`).
3. **"Retry" on a failure alert while another upload is paused or running** → the retried upload goes right after the current one, not to the back, and never runs in parallel. Pinned in Task 4 (`aRetryGoesRightAfterTheCurrentUpload`).
4. **`pending-uploads.json` unreadable or corrupt** → empty queue, no crash; the recordings it named are moved to the save folder by the launch sweep instead of being lost. Pinned in Task 2 (`aCorruptStoreYieldsAnEmptyQueue`) and the sweep filter in Task 5.
5. **Audio file deleted between a quit and the next launch** → its entry is dropped with an alert, no request is sent. Pinned in Task 4 (`aMissingFileIsDroppedAtLaunch`).

---

### Task 0: Commit the pending interface work

The working tree holds finished but uncommitted work (visibility tabs, French by default, mandatory `meeting` tag) on branch `feat/resumable-upload`. Commit it on its own so the upload work never mixes with it.

**Files:** `README.md`, `Sources/RecorderCore/Preferences.swift`, `Tests/RecorderCoreTests/PreferencesTests.swift`, `WhiteboardRecorder/ConfigurationModel.swift`, `WhiteboardRecorder/ConfigurationView.swift` (all already modified).

- [ ] **Step 1: Check the tests pass**

Run: `swift test 2>&1 | tail -3`
Expected: `Test run with 38 tests … passed`

- [ ] **Step 2: Commit**

```bash
git add README.md Sources/RecorderCore/Preferences.swift Tests/RecorderCoreTests/PreferencesTests.swift WhiteboardRecorder/ConfigurationModel.swift WhiteboardRecorder/ConfigurationView.swift
git commit -m "feat(app): visibility tabs, French by default and a mandatory meeting tag"
```

---

### Task 1: The four chunked-upload calls

**Files:**
- Modify: `Sources/RecorderCore/Models.swift` (append types)
- Modify: `Sources/RecorderCore/WhiteboardClient.swift` (`makeRequest` gains a `query` parameter)
- Modify: `Sources/RecorderCore/APIError.swift` (`fileMissing`, `isTransient`)
- Create: `Sources/RecorderCore/ChunkedUploadAPI.swift`
- Modify: `Tests/RecorderCoreTests/FakeSession.swift` (scripted replies)
- Create: `Tests/RecorderCoreTests/UploadFixtures.swift`
- Create: `Tests/RecorderCoreTests/ChunkedUploadAPITests.swift`

**Interfaces:**
- Produces:
  - `UploadSession { uploadId: String, offset: Int64, size: Int64, chunkSize: Int }` (Decodable)
  - `UploadStatus { offset: Int64, size: Int64, recordingId: String? }` (Decodable)
  - `enum ChunkResult { case advanced(to: Int64), offsetMismatch(serverOffset: Int64), alreadyCompleted }`
  - `enum CompleteResult { case completed(UploadedRecording?), notComplete(serverOffset: Int64), slugTaken }`
  - `WhiteboardClient.startUpload(configuration: RecordingConfiguration, size: Int64, filename: String) async throws -> UploadSession`
  - `WhiteboardClient.putChunk(uploadId: String, offset: Int64, data: Data) async throws -> ChunkResult`
  - `WhiteboardClient.uploadStatus(uploadId: String) async throws -> UploadStatus`
  - `WhiteboardClient.completeUpload(uploadId: String, useDefaultSlug: Bool) async throws -> CompleteResult`
  - `APIError.fileMissing`, `APIError.isTransient(_ error: Error) -> Bool`
  - Test helpers: `FakeSession.Reply`, `FakeSession.script`, `Replies.*`, `uploadTestConfiguration(tags:)`, `uploadTestClient(_:)`, `makeTemporaryDirectory()`, `writeAudio(named:in:)`, `requestLines(_:)`, `bodyText(_:)`

- [ ] **Step 1: Give `FakeSession` scripted replies**

Replace `Tests/RecorderCoreTests/FakeSession.swift` with:

```swift
import Foundation
@testable import RecorderCore

final class FakeSession: HTTPSession, @unchecked Sendable {
    struct Call {
        let request: URLRequest
        let uploadedFile: URL?
    }

    /// One answer to one request, consumed in order. When the script runs out
    /// the session falls back to `nextStatus` / `nextBody`.
    enum Reply {
        case status(Int, String)
        case failure(URLError.Code)
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    var calls: [Call] { lock.withLock { _calls } }
    var nextStatus = 200
    var nextBody = Data()
    var script: [Reply] = []

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let reply: Reply? = lock.withLock {
            _calls.append(Call(request: request, uploadedFile: nil))
            return script.isEmpty ? nil : script.removeFirst()
        }
        switch reply {
        case let .status(code, body):
            return (Data(body.utf8), response(for: request, status: code))
        case let .failure(code):
            throw URLError(code)
        case nil:
            return (nextBody, response(for: request, status: nextStatus))
        }
    }

    func upload(for request: URLRequest, fromFile fileURL: URL) async throws -> (Data, URLResponse) {
        // The envelope is deleted as soon as upload() returns, so copy it now.
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.copyItem(at: fileURL, to: copy)
        lock.withLock { _calls.append(Call(request: request, uploadedFile: copy)) }
        return (nextBody, response(for: request, status: nextStatus))
    }

    private func response(for request: URLRequest, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }
}
```

- [ ] **Step 2: Add the shared upload fixtures**

Create `Tests/RecorderCoreTests/UploadFixtures.swift`:

```swift
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
```

- [ ] **Step 3: Write the failing client tests**

Create `Tests/RecorderCoreTests/ChunkedUploadAPITests.swift`:

```swift
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

    let json = try #require(JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: Any])
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
```

- [ ] **Step 4: Run them to see them fail**

Run: `swift test 2>&1 | grep -E "error:|passed|failed" | head`
Expected: compile errors (`startUpload`, `fileMissing`, `isTransient` … not found).

- [ ] **Step 5: Add the response types**

Append to `Sources/RecorderCore/Models.swift`:

```swift
/// What opening an upload session answers: where the server stands and how
/// big each piece must be.
public struct UploadSession: Decodable, Equatable, Sendable {
    public let uploadId: String
    public let offset: Int64
    public let size: Int64
    public let chunkSize: Int
}

/// The server's own count of the bytes it holds — the only one to trust after
/// a cut, since a piece whose answer was lost may still have been kept.
public struct UploadStatus: Decodable, Equatable, Sendable {
    public let offset: Int64
    public let size: Int64
    /// Present once `complete` has created the recording.
    public let recordingId: String?
}

public enum ChunkResult: Equatable, Sendable {
    case advanced(to: Int64)
    /// Not a failure: the server says where it is, and the upload goes on from there.
    case offsetMismatch(serverOffset: Int64)
    case alreadyCompleted
}

public enum CompleteResult: Equatable, Sendable {
    /// Nil when a 2xx came back in a shape this app does not know: the
    /// recording exists all the same.
    case completed(UploadedRecording?)
    case notComplete(serverOffset: Int64)
    case slugTaken
}
```

- [ ] **Step 6: Let `makeRequest` carry a query**

In `Sources/RecorderCore/WhiteboardClient.swift`, replace `makeRequest`:

```swift
    func makeRequest(_ path: String, method: String = "GET", query: [URLQueryItem] = []) throws -> URLRequest {
        guard let key = apiKey(), !key.isEmpty else { throw APIError.noAPIKey }
        var url = baseURL.appendingPathComponent(path)
        if !query.isEmpty { url.append(queryItems: query) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(key, forHTTPHeaderField: "X-API-Key")
        return request
    }
```

`URLRequest`'s default `timeoutInterval` is already 60 s, the per-request timeout the contract asks for: leave it.

- [ ] **Step 7: Add `fileMissing` and `isTransient` to `APIError`**

In `Sources/RecorderCore/APIError.swift`: add `case fileMissing` after `case invalidResponse`; in `message`, add before the closing brace of the switch:

```swift
        case .fileMissing:
            return "The audio file is missing."
```

and add to the enum, after `isAuthenticationFailure`:

```swift
    /// Worth another attempt: the network, a timeout or the server itself
    /// failed, not the request. Anything else would fail the same way again.
    public static func isTransient(_ error: Error) -> Bool {
        if error is URLError { return true }
        guard let apiError = error as? APIError else { return false }
        switch apiError {
        case .server, .invalidResponse: return true
        default: return false
        }
    }
```

- [ ] **Step 8: Write the four calls**

Create `Sources/RecorderCore/ChunkedUploadAPI.swift`:

```swift
import Foundation

/// The resumable upload the backend exposes since 2026-10-10 (WB #1110). A
/// single `POST /recordings` is cut by the reverse proxy after 60 s, whatever
/// its size; pieces of a few MiB each fit well under that, and after a cut the
/// upload goes on from the byte the server stopped at.
extension WhiteboardClient {
    public func startUpload(configuration: RecordingConfiguration, size: Int64,
                            filename: String) async throws -> UploadSession {
        let title = configuration.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 255 else { throw APIError.invalidTitle }
        guard configuration.recordedAt <= Date() else { throw APIError.recordedAtInFuture }

        let body = StartBody(workspaceId: configuration.workspaceID,
                             title: title,
                             recordedAt: ISO8601.string(from: configuration.recordedAt),
                             language: configuration.language,
                             sharingMode: configuration.sharingMode,
                             tags: configuration.tags.isEmpty ? nil : configuration.tags,
                             size: size,
                             mimeType: "audio/mp4",
                             filename: filename)
        var request = try makeRequest("recordings/uploads", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        try check(response, data)
        return try decode(data)
    }

    public func putChunk(uploadId: String, offset: Int64, data chunk: Data) async throws -> ChunkResult {
        var request = try makeRequest("recordings/uploads/\(uploadId)", method: "PUT",
                                      query: [URLQueryItem(name: "offset", value: String(offset))])
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = chunk

        let (data, response) = try await session.data(for: request)
        if let conflict = OffsetConflict.from(response, data) {
            return conflict.message?.localizedCaseInsensitiveContains("already completed") == true
                ? .alreadyCompleted
                : .offsetMismatch(serverOffset: conflict.offset)
        }
        try check(response, data)
        let body: OffsetBody = try decode(data)
        return .advanced(to: body.offset)
    }

    public func uploadStatus(uploadId: String) async throws -> UploadStatus {
        let request = try makeRequest("recordings/uploads/\(uploadId)")
        let (data, response) = try await session.data(for: request)
        try check(response, data)
        return try decode(data)
    }

    /// `complete` is idempotent on the server: calling it again after a lost
    /// answer returns the same recording instead of creating a second one.
    public func completeUpload(uploadId: String, useDefaultSlug: Bool) async throws -> CompleteResult {
        var request = try makeRequest("recordings/uploads/\(uploadId)/complete", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data((useDefaultSlug ? #"{"slug":null}"# : "{}").utf8)

        let (data, response) = try await session.data(for: request)
        if let conflict = OffsetConflict.from(response, data) {
            return .notComplete(serverOffset: conflict.offset)
        }
        if (response as? HTTPURLResponse)?.statusCode == 409 {
            return .slugTaken
        }
        try check(response, data)
        // Same rule as the single upload had: past `check` the recording
        // exists, and a body this app cannot read must not turn that into a
        // failure that invites a second upload.
        return .completed(try? JSONDecoder().decode(UploadedRecording.self, from: data))
    }
}

private struct StartBody: Encodable {
    let workspaceId: String
    let title: String
    let recordedAt: String
    let language: String
    let sharingMode: String
    /// Nil is left out of the JSON entirely rather than sent as `null`.
    let tags: [Tag]?
    let size: Int64
    let mimeType: String
    let filename: String
}

private struct OffsetBody: Decodable {
    let offset: Int64
}

/// A 409 that names the server's offset: the upload is behind or ahead of
/// what the app thought, not refused.
private struct OffsetConflict: Decodable {
    let message: String?
    let offset: Int64

    static func from(_ response: URLResponse, _ data: Data) -> OffsetConflict? {
        guard (response as? HTTPURLResponse)?.statusCode == 409 else { return nil }
        return try? JSONDecoder().decode(OffsetConflict.self, from: data)
    }
}
```

- [ ] **Step 9: Run the tests**

Run: `swift test 2>&1 | tail -3`
Expected: all tests pass (38 existing + 11 new).

- [ ] **Step 10: Commit**

```bash
git add Sources/RecorderCore Tests/RecorderCoreTests
git commit -m "feat(core): the four calls of the resumable upload"
```

---

### Task 2: The persisted upload queue

**Files:**
- Modify: `Sources/RecorderCore/RecordingFlow.swift:3` (`RecordingConfiguration` becomes `Codable`)
- Create: `Sources/RecorderCore/PendingUpload.swift`
- Create: `Tests/RecorderCoreTests/PendingUploadStoreTests.swift`

**Interfaces:**
- Consumes: `RecordingConfiguration`, `RecordingStorage.directory`, `Tag` (Codable)
- Produces:
  - `struct PendingUpload: Codable, Equatable, Sendable, Identifiable { id: UUID; fileName: String; size: Int64; configuration: RecordingConfiguration; var uploadId: String?; var chunkSize: Int?; var completeSent: Bool }` with `init(id: UUID = UUID(), fileName:size:configuration:uploadId: = nil, chunkSize: = nil, completeSent: = false)` and `func fileURL(in directory: URL) -> URL`
  - `struct PendingUploadStore: Sendable { let fileURL: URL; init(fileURL: URL = PendingUploadStore.defaultFileURL); static var defaultFileURL: URL; func load() -> [PendingUpload]; func save(_ uploads: [PendingUpload]) throws }`

- [ ] **Step 1: Write the failing tests**

Create `Tests/RecorderCoreTests/PendingUploadStoreTests.swift`:

```swift
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
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test 2>&1 | grep -E "error:" | head -3`
Expected: `cannot find 'PendingUploadStore' in scope`.

- [ ] **Step 3: Make `RecordingConfiguration` Codable**

In `Sources/RecorderCore/RecordingFlow.swift`, change
`public struct RecordingConfiguration: Equatable, Sendable {` to
`public struct RecordingConfiguration: Codable, Equatable, Sendable {`.

- [ ] **Step 4: Write `PendingUpload` and its store**

Create `Sources/RecorderCore/PendingUpload.swift`:

```swift
import Foundation

/// An upload the app still owes the server, in the form it must take to
/// survive a quit, a crash or a night asleep.
public struct PendingUpload: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    /// A bare name inside `RecordingStorage.directory`. Not a full path: the
    /// sandbox container's absolute path is nothing to freeze in a file.
    public let fileName: String
    /// Measured once the capture was finalised. The server checks every byte
    /// against it, so it is never measured again.
    public let size: Int64
    public let configuration: RecordingConfiguration
    /// Nil until `start` has answered — and again after a 404, to start over.
    public var uploadId: String?
    /// The piece size `start` asked for; `GET` does not repeat it.
    public var chunkSize: Int?
    /// Set before `complete` leaves. A 404 afterwards may mean the recording
    /// was created and its session since purged: uploading the file again
    /// would make a second note.
    public var completeSent: Bool

    public init(id: UUID = UUID(), fileName: String, size: Int64, configuration: RecordingConfiguration,
                uploadId: String? = nil, chunkSize: Int? = nil, completeSent: Bool = false) {
        self.id = id
        self.fileName = fileName
        self.size = size
        self.configuration = configuration
        self.uploadId = uploadId
        self.chunkSize = chunkSize
        self.completeSent = completeSent
    }

    public func fileURL(in directory: URL) -> URL {
        directory.appendingPathComponent(fileName)
    }
}

/// The queue on disk, in upload order. The offset is deliberately absent: the
/// server's `GET` is the only count of the bytes it holds worth trusting.
public struct PendingUploadStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL = PendingUploadStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    public static var defaultFileURL: URL {
        RecordingStorage.directory.deletingLastPathComponent()
            .appendingPathComponent("pending-uploads.json")
    }

    /// An unreadable file yields an empty queue rather than a crash: the
    /// recordings it named are still in the working folder, and the launch
    /// sweep moves them to the save folder.
    public func load() -> [PendingUpload] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? Self.decoder.decode([PendingUpload].self, from: data)) ?? []
    }

    public func save(_ uploads: [PendingUpload]) throws {
        try Self.encoder.encode(uploads).write(to: fileURL, options: .atomic)
    }

    // ISO 8601 rather than the default seconds-since-2001, so the file can be
    // read — and written by hand to test a resume.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
```

- [ ] **Step 5: Run the tests**

Run: `swift test 2>&1 | tail -3`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/RecorderCore Tests/RecorderCoreTests
git commit -m "feat(core): a pending-upload queue that survives a quit"
```

---

### Task 3: `ChunkedUploader` — one upload, to its end

**Files:**
- Create: `Sources/RecorderCore/ChunkedUploader.swift`
- Create: `Tests/RecorderCoreTests/ChunkedUploaderTests.swift`

**Interfaces:**
- Consumes: Task 1 client calls and `APIError.isTransient`, Task 2 `PendingUpload`
- Produces:
  - `enum UploadOutcome: Equatable, Sendable { case completed(UploadedRecording?), paused(String), maybeAlreadyUploaded, failed(APIError) }`
  - `struct ChunkedUploader: Sendable { static let maxConsecutiveFailures = 4; init(client: WhiteboardClient, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }); func run(_ upload: PendingUpload, directory: URL, progress: @escaping @Sendable (Int64, Int64) async -> Void, persist: @escaping @Sendable (PendingUpload) async -> Void) async throws -> UploadOutcome }` — throws only `CancellationError`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/RecorderCoreTests/ChunkedUploaderTests.swift`:

```swift
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
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test 2>&1 | grep -E "error:" | head -3`
Expected: `cannot find 'ChunkedUploader' in scope`.

- [ ] **Step 3: Write the uploader**

Create `Sources/RecorderCore/ChunkedUploader.swift`:

```swift
import Foundation
import os

public enum UploadOutcome: Equatable, Sendable {
    case completed(UploadedRecording?)
    /// The fourth failure in a row. Carries the last one, for the user.
    case paused(String)
    /// A 404 after `complete` was sent: the recording may exist and its session
    /// may simply have been purged. Only the user can tell.
    case maybeAlreadyUploaded
    case failed(APIError)
}

/// Drives one upload to its end — or to the point where it has to stop and
/// say why. It holds no state between runs: everything a later run needs is in
/// the `PendingUpload` it hands to `persist`, and the offset is asked of the
/// server, which alone knows which pieces it kept.
public struct ChunkedUploader: Sendable {
    public static let maxConsecutiveFailures = 4
    /// For a session saved without its piece size; the server's own default.
    static let fallbackChunkSize = 4 * 1024 * 1024

    private static let log = Logger(subsystem: "com.kepochan.whiteboard-recorder", category: "upload")

    let client: WhiteboardClient
    let sleep: @Sendable (Duration) async throws -> Void

    public init(client: WhiteboardClient,
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.client = client
        self.sleep = sleep
    }

    /// Throws only `CancellationError`. A cancelled run leaves nothing half
    /// done: the server adds a piece only once it has received all of it.
    public func run(_ initial: PendingUpload,
                    directory: URL,
                    progress: @escaping @Sendable (Int64, Int64) async -> Void,
                    persist: @escaping @Sendable (PendingUpload) async -> Void) async throws -> UploadOutcome {
        var upload = initial
        let fileURL = upload.fileURL(in: directory)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .failed(.fileMissing) }

        var offset: Int64 = 0
        // A session from an earlier run: where it stands is the server's to say.
        var mustAskServer = upload.uploadId != nil
        var useDefaultSlug = false
        var failures = 0

        while true {
            try Task.checkCancellation()
            do {
                guard let uploadId = upload.uploadId else {
                    let session = try await client.startUpload(configuration: upload.configuration,
                                                               size: upload.size, filename: upload.fileName)
                    Self.log.notice("started \(session.uploadId, privacy: .public) size=\(upload.size, privacy: .public)")
                    upload.uploadId = session.uploadId
                    upload.chunkSize = session.chunkSize
                    upload.completeSent = false
                    offset = session.offset
                    mustAskServer = false
                    failures = 0
                    await persist(upload)
                    continue
                }

                if mustAskServer {
                    let status = try await client.uploadStatus(uploadId: uploadId)
                    // A recording already made means every byte is there, and
                    // `complete` will replay it.
                    offset = status.recordingId == nil ? status.offset : upload.size
                    mustAskServer = false
                    Self.log.notice("resuming \(uploadId, privacy: .public) at \(offset, privacy: .public)")
                }
                await progress(offset, upload.size)

                if offset < upload.size {
                    let chunk = try Self.readChunk(of: fileURL, at: offset,
                                                   length: upload.chunkSize ?? Self.fallbackChunkSize)
                    switch try await client.putChunk(uploadId: uploadId, offset: offset, data: chunk) {
                    case let .advanced(to: next):
                        offset = next
                        failures = 0
                    case let .offsetMismatch(serverOffset):
                        Self.log.notice("realigned \(uploadId, privacy: .public) \(offset, privacy: .public) -> \(serverOffset, privacy: .public)")
                        offset = serverOffset
                    case .alreadyCompleted:
                        offset = upload.size
                    }
                    continue
                }

                if !upload.completeSent {
                    upload.completeSent = true
                    await persist(upload)
                }
                switch try await client.completeUpload(uploadId: uploadId, useDefaultSlug: useDefaultSlug) {
                case let .completed(recording):
                    Self.log.notice("completed \(uploadId, privacy: .public)")
                    return .completed(recording)
                case let .notComplete(serverOffset):
                    offset = serverOffset
                    // The server says nothing was created, so a later 404 can
                    // no longer mean the recording exists.
                    upload.completeSent = false
                    await persist(upload)
                case .slugTaken:
                    // The app never sends a slug, so the server's default is
                    // the only other one to ask for — and only once.
                    guard !useDefaultSlug else { return .failed(.conflict("")) }
                    useDefaultSlug = true
                }
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }

                if case APIError.notFound = error, upload.uploadId != nil {
                    if upload.completeSent { return .maybeAlreadyUploaded }
                    // Purged or unknown before it was finished: start over,
                    // which is not a failure of the connection.
                    Self.log.notice("session lost, starting over")
                    upload.uploadId = nil
                    upload.chunkSize = nil
                    await persist(upload)
                    continue
                }

                guard APIError.isTransient(error) else {
                    return .failed(error as? APIError ?? .invalidResponse)
                }
                failures += 1
                Self.log.notice("failure \(failures, privacy: .public): \(Self.describe(error), privacy: .public)")
                if failures >= Self.maxConsecutiveFailures {
                    return .paused(Self.describe(error))
                }
                try await sleep(.seconds(1 << (failures - 1)))
                if upload.uploadId != nil { mustAskServer = true }
            }
        }
    }

    static func describe(_ error: Error) -> String {
        (error as? APIError)?.message ?? error.localizedDescription
    }

    /// One piece, read from disk: a two-hour meeting never sits in memory whole.
    static func readChunk(of url: URL, at offset: Int64, length: Int) throws -> Data {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(offset))
            let data = try handle.read(upToCount: length) ?? Data()
            guard !data.isEmpty else { throw APIError.fileMissing }
            return data
        } catch {
            throw APIError.fileMissing
        }
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test 2>&1 | tail -3`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/RecorderCore/ChunkedUploader.swift Tests/RecorderCoreTests/ChunkedUploaderTests.swift
git commit -m "feat(core): ChunkedUploader resumes from the server offset and pauses after four failures"
```

---

### Task 4: `UploadCoordinator` — the queue, one upload at a time

**Files:**
- Create: `Sources/RecorderCore/UploadCoordinator.swift`
- Create: `Tests/RecorderCoreTests/UploadCoordinatorTests.swift`

**Interfaces:**
- Consumes: Task 2 `PendingUpload`, `PendingUploadStore`; Task 3 `ChunkedUploader`, `UploadOutcome`
- Produces (all `@MainActor`):
  - `final class UploadCoordinator: ObservableObject`
  - `enum Activity: Equatable { case idle; case uploading(id: UUID, title: String, sent: Int64, total: Int64); case paused(id: UUID, title: String, message: String) }`
  - `enum ItemStatus: Equatable { case waiting, uploading(sent: Int64, total: Int64), paused(String), finished }`
  - `enum Failure: Equatable { case rejected(APIError), maybeAlreadyUploaded }`
  - `@Published private(set) var activity: Activity`, `@Published private(set) var queue: [PendingUpload]`
  - `var onCompleted: ((PendingUpload) -> Void)?`, `var onFailed: ((PendingUpload, Failure) -> Void)?`, `var notify: ((String, String) -> Void)?` (title, body)
  - `init(store: PendingUploadStore, directory: URL, makeUploader: @escaping () -> ChunkedUploader)`
  - `var waitingCount: Int`, `var referencedFileNames: Set<String>`, `func status(of id: UUID) -> ItemStatus`
  - `@discardableResult func enqueue(fileURL: URL, configuration: RecordingConfiguration) throws -> UUID`
  - `func requeue(_ upload: PendingUpload, startingOver: Bool)`
  - `func resume()`, `func networkChanged(isAvailable: Bool)`, `func resumeAfterLaunch() -> [String]`, `func stop()`
  - internal `private(set) var task: Task<Void, Never>?` (tests await it)

- [ ] **Step 1: Write the failing tests**

Create `Tests/RecorderCoreTests/UploadCoordinatorTests.swift`:

```swift
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
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test 2>&1 | grep -E "error:" | head -3`
Expected: `cannot find 'UploadCoordinator' in scope`.

- [ ] **Step 3: Write the coordinator**

Create `Sources/RecorderCore/UploadCoordinator.swift`:

```swift
import Combine
import Foundation

/// Owns the uploads still owed to the server and sends them one at a time, in
/// the order the meetings were confirmed. The queue lives on disk, so a quit,
/// a crash or a night asleep only pauses it; the app hands a file over the
/// moment the configuration window says OK and is free to record the next
/// meeting.
@MainActor
public final class UploadCoordinator: ObservableObject {
    public enum Activity: Equatable, Sendable {
        case idle
        case uploading(id: UUID, title: String, sent: Int64, total: Int64)
        case paused(id: UUID, title: String, message: String)
    }

    /// One upload as its configuration window sees it.
    public enum ItemStatus: Equatable, Sendable {
        case waiting
        case uploading(sent: Int64, total: Int64)
        case paused(String)
        /// No longer queued: sent, or handed back to the app as a failure.
        case finished
    }

    public enum Failure: Equatable, Sendable {
        case rejected(APIError)
        case maybeAlreadyUploaded
    }

    @Published public private(set) var activity: Activity = .idle
    @Published public private(set) var queue: [PendingUpload]

    public var onCompleted: ((PendingUpload) -> Void)?
    /// The upload has left the queue; its file is still in the working folder
    /// and is now the app's to keep, retry or move.
    public var onFailed: ((PendingUpload, Failure) -> Void)?
    /// Title and body of a banner for what happens while no window watches.
    public var notify: ((String, String) -> Void)?

    private let store: PendingUploadStore
    private let directory: URL
    private let makeUploader: () -> ChunkedUploader
    private(set) var task: Task<Void, Never>?
    private var networkWasAvailable = true

    public init(store: PendingUploadStore, directory: URL, makeUploader: @escaping () -> ChunkedUploader) {
        self.store = store
        self.directory = directory
        self.makeUploader = makeUploader
        self.queue = store.load()
    }

    public var waitingCount: Int { max(queue.count - 1, 0) }

    /// Files the launch sweep must leave alone: they are on their way.
    public var referencedFileNames: Set<String> { Set(queue.map(\.fileName)) }

    public func status(of id: UUID) -> ItemStatus {
        switch activity {
        case let .uploading(current, _, sent, total) where current == id:
            return .uploading(sent: sent, total: total)
        case let .paused(current, _, message) where current == id:
            return .paused(message)
        default:
            return queue.contains { $0.id == id } ? .waiting : .finished
        }
    }

    /// The file must sit in the working folder the coordinator was given; it is
    /// remembered by name only.
    @discardableResult
    public func enqueue(fileURL: URL, configuration: RecordingConfiguration) throws -> UUID {
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { throw APIError.fileMissing }
        let upload = PendingUpload(fileName: fileURL.lastPathComponent, size: size, configuration: configuration)
        queue.append(upload)
        save()
        pump()
        return upload.id
    }

    /// An upload the user chose to retry goes right after the current one —
    /// running or paused — rather than to the back of the queue, and never
    /// alongside it.
    public func requeue(_ upload: PendingUpload, startingOver: Bool) {
        var upload = upload
        if startingOver {
            upload.uploadId = nil
            upload.chunkSize = nil
            upload.completeSent = false
        }
        queue.insert(upload, at: queue.isEmpty ? 0 : 1)
        save()
        pump()
    }

    /// "Resume upload". Does nothing unless paused.
    public func resume() {
        guard case .paused = activity, task == nil else { return }
        startHead()
    }

    /// Fed every network change. Only a return after an outage, while paused,
    /// is worth acting on — once; a new failure waits for the next return or
    /// a click.
    public func networkChanged(isAvailable: Bool) {
        defer { networkWasAvailable = isAvailable }
        guard isAvailable, !networkWasAvailable else { return }
        resume()
    }

    /// At launch: drops the entries whose file has gone and returns their
    /// titles so the app can say so, then picks the queue up where it stopped.
    public func resumeAfterLaunch() -> [String] {
        let missing = queue.filter { !FileManager.default.fileExists(atPath: $0.fileURL(in: directory).path) }
        if !missing.isEmpty {
            let missingIDs = Set(missing.map(\.id))
            queue.removeAll { missingIDs.contains($0.id) }
            save()
        }
        if let head = queue.first {
            notify?("Resuming upload", "“\(head.configuration.title)” continues where it stopped.")
        }
        pump()
        return missing.map(\.configuration.title)
    }

    /// At quit. What was sent stays sent, and the queue is already on disk.
    public func stop() {
        task?.cancel()
        task = nil
    }

    // MARK: - Running

    private func pump() {
        guard task == nil else { return }
        // A pause holds the whole queue, so the order of the meetings holds.
        if case .paused = activity { return }
        startHead()
    }

    private func startHead() {
        guard let head = queue.first else {
            activity = .idle
            return
        }
        activity = .uploading(id: head.id, title: head.configuration.title, sent: 0, total: head.size)
        let uploader = makeUploader()
        let directory = self.directory
        task = Task { [weak self] in
            let outcome: UploadOutcome
            do {
                outcome = try await uploader.run(
                    head, directory: directory,
                    progress: { [weak self] sent, total in
                        await self?.progressed(head.id, sent: sent, total: total)
                    },
                    persist: { [weak self] updated in
                        await self?.persisted(updated)
                    })
            } catch {
                // Cancelled at quit: the queue on disk is where the next
                // launch picks up.
                return
            }
            self?.finished(head.id, outcome)
        }
    }

    private func progressed(_ id: UUID, sent: Int64, total: Int64) {
        guard case let .uploading(current, title, _, _) = activity, current == id else { return }
        activity = .uploading(id: id, title: title, sent: sent, total: total)
    }

    private func persisted(_ upload: PendingUpload) {
        guard let index = queue.firstIndex(where: { $0.id == upload.id }) else { return }
        queue[index] = upload
        save()
    }

    private func finished(_ id: UUID, _ outcome: UploadOutcome) {
        task = nil
        guard let upload = queue.first(where: { $0.id == id }) else {
            pump()
            return
        }
        let title = upload.configuration.title

        switch outcome {
        case .completed:
            try? FileManager.default.removeItem(at: upload.fileURL(in: directory))
            remove(id)
            onCompleted?(upload)
        case let .paused(detail):
            activity = .paused(id: id, title: title, message: "The connection keeps failing: \(detail)")
            notify?("Upload paused",
                    "“\(title)” will resume when the network comes back, or from the menu bar icon.")
            return
        case let .failed(error):
            remove(id)
            onFailed?(upload, .rejected(error))
        case .maybeAlreadyUploaded:
            remove(id)
            onFailed?(upload, .maybeAlreadyUploaded)
        }
        activity = .idle
        pump()
    }

    private func remove(_ id: UUID) {
        queue.removeAll { $0.id == id }
        save()
    }

    /// A save that fails leaves the previous queue on disk. The next launch
    /// then asks the server where each upload stands, which is safe for every
    /// entry except one whose `complete` went unrecorded — the 404 path still
    /// stops short of a second upload for those.
    private func save() {
        try? store.save(queue)
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test 2>&1 | tail -3`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/RecorderCore/UploadCoordinator.swift Tests/RecorderCoreTests/UploadCoordinatorTests.swift
git commit -m "feat(core): UploadCoordinator sends the queue one upload at a time"
```

---

### Task 5: Hand recordings to the queue; retire the single upload

**Files:**
- Modify: `Sources/RecorderCore/RecordingFlow.swift` (states, events, effects, transitions)
- Modify: `Tests/RecorderCoreTests/RecordingFlowTests.swift`
- Delete: `Sources/RecorderCore/MultipartBody.swift`, `Tests/RecorderCoreTests/MultipartBodyTests.swift`, `Tests/RecorderCoreTests/UploadTests.swift`
- Modify: `Sources/RecorderCore/WhiteboardClient.swift` (remove `upload(_:)`), `Sources/RecorderCore/Models.swift` (remove `RecordingUpload`), `Sources/RecorderCore/HTTPSession.swift` and `Tests/RecorderCoreTests/FakeSession.swift` (remove file upload)
- Create: `WhiteboardRecorder/UploadNotifications.swift`
- Modify: `WhiteboardRecorder/MenuBarController.swift`, `WhiteboardRecorder/FailureAlert.swift`, `WhiteboardRecorder/RecordingRescue.swift`, `WhiteboardRecorder/AppDelegate.swift`, `WhiteboardRecorder/ConfigurationWindowController.swift`

**Interfaces:**
- Consumes: Task 4 `UploadCoordinator` (all of it), Task 2 `PendingUpload`, `PendingUploadStore`, Task 3 `ChunkedUploader`
- Produces:
  - `RecordingState`: `.idle`, `.recording(startedAt:)`, `.configuring(startedAt:)`, `.failed(message: String)`
  - `RecordingEvent`: `.iconClicked`, `.configurationConfirmed(_)`, `.configurationCancelled`, `.captureFailed(_)`, `.failureDismissed`
  - `RecordingEffect`: `.startCapture`, `.stopCapture`, `.discardFile`, `.moveFileToSaveFolder`, `.enqueueUpload(RecordingConfiguration)`, `.showConfigurationWindow(startedAt:)`, `.focusConfigurationWindow`, `.setIcon(IconState)`, `.setESP32Recording(Bool)`
  - `MenuBarController.uploads: UploadCoordinator` (read by Task 6), `MenuBarController.resumePendingUploads()`
  - `ConfigurationWindowController.uploadID: UUID?`, `track(uploadID: UUID)`

- [ ] **Step 1: Rewrite the flow tests that change**

In `Tests/RecorderCoreTests/RecordingFlowTests.swift`, replace `confirmingUploadsWhatWasRecorded`, `aCaptureThatCouldNotBeFinalisedNeverAsksForAConfiguration`, `aClickDuringUploadDoesNothing`, `successDeletesTheLocalFile`, `failureKeepsTheFileAndAllowsARetry` and `dismissingAFailureMovesTheFileToTheSaveFolder` with:

```swift
@Test func confirmingHandsTheRecordingToTheUploadQueue() {
    let flow = flowAwaitingConfiguration()
    let configuration = makeConfiguration()

    #expect(flow.handle(.configurationConfirmed(configuration)) == [.enqueueUpload(configuration), .setIcon(.idle)])
    // The upload runs in the background; the flow is free for the next meeting.
    #expect(flow.state == .idle)
}

@Test func aClickAfterConfirmingStartsTheNextMeeting() {
    let flow = flowAwaitingConfiguration()
    _ = flow.handle(.configurationConfirmed(makeConfiguration()))
    #expect(flow.handle(.iconClicked) == [.startCapture, .setIcon(.recording), .setESP32Recording(true)])
}

@Test func aCaptureThatCouldNotBeFinalisedNeverAsksForAConfiguration() {
    let flow = flowAwaitingConfiguration()

    #expect(flow.handle(.captureFailed("The sound could not be recorded.")) == [.setIcon(.idle)])
    #expect(flow.state == .failed(message: "The sound could not be recorded."))
    // Nothing is configured or uploaded from here.
    #expect(flow.handle(.configurationConfirmed(makeConfiguration())) == [])
}

@Test func dismissingACaptureFailureMovesTheFileToTheSaveFolder() {
    let flow = flowAwaitingConfiguration()
    _ = flow.handle(.captureFailed("boom"))

    #expect(flow.handle(.failureDismissed) == [.moveFileToSaveFolder, .setIcon(.idle)])
    #expect(flow.state == .idle)
}
```

Run: `swift test 2>&1 | grep -E "error:" | head -3`
Expected: compile errors (`enqueueUpload`, `failed(message:)`).

- [ ] **Step 2: Rewrite the flow**

In `Sources/RecorderCore/RecordingFlow.swift`, replace `RecordingState`, `RecordingEvent`, `RecordingEffect` and the body of `handle` with:

```swift
public enum RecordingState: Equatable {
    case idle
    /// Capturing. The configuration is asked for once the recording stops.
    case recording(startedAt: Date)
    /// Capture is over and the configuration window is up; nothing is being
    /// recorded any more, and nothing has been handed to the upload queue yet.
    case configuring(startedAt: Date)
    /// The capture could not be finalised: there is nothing to configure or
    /// upload, only perhaps a partial file to keep.
    case failed(message: String)
}

public enum RecordingEvent {
    case iconClicked
    case configurationConfirmed(RecordingConfiguration)
    case configurationCancelled
    /// The capture could not be finalised, so there is nothing to configure.
    case captureFailed(String)
    case failureDismissed
}

public enum RecordingEffect: Equatable {
    case startCapture
    case stopCapture
    case discardFile
    case moveFileToSaveFolder
    /// Hands the file to the upload queue, which sends it in the background
    /// and owns it from then on.
    case enqueueUpload(RecordingConfiguration)
    case showConfigurationWindow(startedAt: Date)
    case focusConfigurationWindow
    case setIcon(IconState)
    case setESP32Recording(Bool)
}
```

```swift
    public func handle(_ event: RecordingEvent) -> [RecordingEffect] {
        switch (state, event) {
        case (.idle, .iconClicked):
            let startedAt = now()
            state = .recording(startedAt: startedAt)
            return [.startCapture, .setIcon(.recording), .setESP32Recording(true)]

        case let (.recording(startedAt), .iconClicked):
            state = .configuring(startedAt: startedAt)
            return [.stopCapture, .setESP32Recording(false), .setIcon(.uploading),
                    .showConfigurationWindow(startedAt: startedAt)]

        case (.configuring, .iconClicked):
            return [.focusConfigurationWindow]

        case let (.configuring, .configurationConfirmed(configuration)):
            state = .idle
            return [.enqueueUpload(configuration), .setIcon(.idle)]

        case (.configuring, .configurationCancelled):
            state = .idle
            return [.discardFile, .setIcon(.idle)]

        case let (.configuring, .captureFailed(message)):
            state = .failed(message: message)
            return [.setIcon(.idle)]

        case (.failed, .failureDismissed):
            state = .idle
            return [.moveFileToSaveFolder, .setIcon(.idle)]

        default:
            return []
        }
    }
```

- [ ] **Step 3: Remove the single upload**

```bash
git rm Sources/RecorderCore/MultipartBody.swift Tests/RecorderCoreTests/MultipartBodyTests.swift Tests/RecorderCoreTests/UploadTests.swift
```

Then:
- `Sources/RecorderCore/WhiteboardClient.swift`: delete the whole `extension WhiteboardClient { … upload(_ recording: RecordingUpload) … }` block (from `extension WhiteboardClient {` after the struct to the end of the file).
- `Sources/RecorderCore/Models.swift`: delete `public struct RecordingUpload { … }`.
- `Sources/RecorderCore/HTTPSession.swift`: delete the `upload(for:fromFile:)` requirement.
- `Tests/RecorderCoreTests/FakeSession.swift`: delete `upload(for:fromFile:)`, and the `uploadedFile` field from `Call` and both places that set it (`Call(request: request)`).

Run: `swift test 2>&1 | tail -3`
Expected: all core tests pass (the app does not build yet — next steps).

- [ ] **Step 4: Add the notification helper**

Create `WhiteboardRecorder/UploadNotifications.swift`:

```swift
import UserNotifications

/// Banners for what happens to an upload while no window watches it: a pause,
/// or a resume at launch. A refusal changes nothing else — the window and the
/// menu still show where every upload stands.
final class UploadNotifications: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        center.delegate = self
    }

    /// Asked at the first upload rather than at launch: by then the user knows
    /// what the banners will be about. The system only ever asks once.
    func requestAuthorizationIfNeeded() {
        center.requestAuthorization(options: [.alert]) { _, _ in }
    }

    func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// A menu bar app counts as frontmost often enough that, without this, its
    /// banners would be swallowed.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }
}
```

- [ ] **Step 5: Wire the coordinator into `MenuBarController`**

In `WhiteboardRecorder/MenuBarController.swift`:

1. Imports: add `import Combine` and `import Network`. Annotate the class: `@MainActor final class MenuBarController: NSObject {`.
2. Delete the `captureFailureMessage` and `lastFailedTitle` properties with their doc comments, and every line that sets them (`.startCapture` case: the two reset lines and the comment above them; `.stopCapture` case: `captureFailureMessage = nil` and `captureFailureMessage = message`).
3. After `var startedAt: Date?`, add:

```swift
    /// Every recording confirmed in the configuration window is handed to this
    /// queue and sent in the background, one at a time. The queue lives on
    /// disk, so a quit or a crash only pauses it, and the icon is free for the
    /// next meeting as soon as the window says OK.
    private(set) lazy var uploads: UploadCoordinator = makeUploads()
    private let notifications = UploadNotifications()
    private let pathMonitor = NWPathMonitor()
    private var activityObserver: AnyCancellable?
```

4. In `init()`, replace `setIcon(.idle)` with `refreshIcon()`.
5. In `apply(_:)`:
   - `.stopCapture` catch block: replace `presentFailure(message, canRetry: false)` with `presentFailure(message)`.
   - Replace `case .discardFile, .deleteFile:` with `case .discardFile:`.
   - Replace `case let .upload(configuration): startUpload(configuration)` with
     `case let .enqueueUpload(configuration): enqueueUpload(configuration)`.
   - Replace `case let .setIcon(state): setIcon(state)` with:

```swift
            case .setIcon:
                // What the flow alone would show; the queue may still be
                // sending an earlier meeting, which `refreshIcon` accounts for.
                refreshIcon()
```

6. Delete `startUpload(_:)` entirely and add in its place:

```swift
    private func enqueueUpload(_ configuration: RecordingConfiguration) {
        guard let fileURL = currentFileURL else {
            configurationWindow?.close()
            showAlert(title: "Upload failed", message: APIError.fileMissing.message)
            return
        }
        do {
            let id = try uploads.enqueue(fileURL: fileURL, configuration: configuration)
            // The queue owns the file now; the next recording gets its own.
            currentFileURL = nil
            notifications.requestAuthorizationIfNeeded()
            configurationWindow?.track(uploadID: id)
        } catch {
            configurationWindow?.close()
            showAlert(title: "Upload failed", message: (error as? APIError)?.message ?? error.localizedDescription)
        }
    }

    private func makeUploads() -> UploadCoordinator {
        let coordinator = UploadCoordinator(
            store: PendingUploadStore(),
            directory: RecordingStorage.directory,
            makeUploader: { [unowned self] in ChunkedUploader(client: self.client) })
        coordinator.notify = { [notifications] title, body in
            notifications.post(title: title, body: body)
        }
        coordinator.onCompleted = { [weak self] upload in
            guard let self, self.configurationWindow?.uploadID == upload.id else { return }
            self.configurationWindow?.showUploadSucceeded()
        }
        coordinator.onFailed = { [weak self] upload, failure in
            // Out of the coordinator's call before a modal alert takes over.
            DispatchQueue.main.async { self?.uploadFailed(upload, failure) }
        }
        // `$activity` fires before the value changes; the hop reads the new one.
        activityObserver = coordinator.$activity.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshIcon() }
        }
        return coordinator
    }

    private func uploadFailed(_ upload: PendingUpload, _ failure: UploadCoordinator.Failure) {
        if configurationWindow?.uploadID == upload.id { configurationWindow?.close() }
        presentUploadFailure(upload, failure)
    }

    /// Called once at launch, after the sweep: picks up the uploads an earlier
    /// run left unfinished, and starts listening for the network to come back.
    func resumePendingUploads() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            DispatchQueue.main.async { self?.uploads.networkChanged(isAvailable: available) }
        }
        pathMonitor.start(queue: .global(qos: .utility))

        let lost = uploads.resumeAfterLaunch()
        guard !lost.isEmpty else { return }
        showAlert(title: "Uploads dropped",
                  message: """
                  These recordings were waiting to be uploaded, but their audio file is gone:

                  \(lost.joined(separator: "\n"))
                  """)
    }
```

7. Replace `private func setIcon(_ state: IconState)` with:

```swift
    /// The flow knows whether a meeting is being recorded or configured; the
    /// queue knows whether an earlier one is still on its way. Recording wins.
    private func refreshIcon() {
        let state: IconState
        switch flow.state {
        case .recording: state = .recording
        case .configuring: state = .uploading
        case .idle, .failed: state = uploads.activity == .idle ? .idle : .uploading
        }
        statusItem.button?.image = StatusIcon.image(for: state)
    }
```

- [ ] **Step 6: Split the failure alerts in `FailureAlert.swift`**

In `WhiteboardRecorder/FailureAlert.swift`:

1. Give `FailureAlert.present` a headline and a retry label — change its signature and first lines to:

```swift
    static func present(headline: String = "Upload failed",
                        message: String,
                        saveFolderName: String,
                        retryTitle: String = "Retry",
                        canRetry: Bool,
                        canSave: Bool,
                        isAuthFailure: Bool) -> Choice {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = headline
```

   and `alert.addButton(withTitle: "Retry")` becomes `alert.addButton(withTitle: retryTitle)`.

2. Replace the whole `presentFailure(_:canRetry:isAuthFailure:)` function with:

```swift
    /// A capture that could not be finalised: nothing to retry, only the
    /// partial file, if any, to keep.
    func presentFailure(_ message: String) {
        let hasFile = currentFileURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        switch FailureAlert.present(message: message, saveFolderName: saveFolderDisplayName,
                                    canRetry: false, canSave: hasFile, isAuthFailure: false) {
        case .save:
            saveCurrentFileWithPanel()
            apply(flow.handle(.failureDismissed))
        case .retry, .openPreferences, .dismiss:
            apply(flow.handle(.failureDismissed))
        }
    }

    /// An upload the server refused, or one that may already have landed. It is
    /// out of the queue: what the user picks here decides where its file goes,
    /// and a quit before that leaves the file to the launch sweep.
    ///
    /// `keyMayHaveChanged` is set when the alert comes back from the
    /// preferences: the key the server refused may have been replaced, so
    /// "Retry" is offered instead of sending the user straight back there.
    func presentUploadFailure(_ upload: PendingUpload, _ failure: UploadCoordinator.Failure,
                              keyMayHaveChanged: Bool = false) {
        let source = upload.fileURL(in: RecordingStorage.directory)
        let name = fileNameSlug(for: upload.configuration.title, at: upload.configuration.recordedAt)
        let hasFile = FileManager.default.fileExists(atPath: source.path)

        let headline: String
        let message: String
        let retryTitle: String
        let isAuthFailure: Bool
        switch failure {
        case let .rejected(error):
            headline = "Upload failed"
            message = error.message
            retryTitle = "Retry"
            isAuthFailure = error.isAuthenticationFailure && !keyMayHaveChanged
        case .maybeAlreadyUploaded:
            headline = "Upload interrupted"
            message = """
            This recording may already be on Whiteboard: the upload was finishing \
            when it was interrupted. Check before uploading it again.
            """
            retryTitle = "Upload again"
            isAuthFailure = false
        }

        switch FailureAlert.present(headline: headline,
                                    message: "“\(upload.configuration.title)”: \(message)",
                                    saveFolderName: saveFolderDisplayName,
                                    retryTitle: retryTitle,
                                    canRetry: hasFile,
                                    canSave: hasFile,
                                    isAuthFailure: isAuthFailure) {
        case .retry:
            uploads.requeue(upload, startingOver: failure == .maybeAlreadyUploaded)
        case .openPreferences:
            presentPreferences { [weak self] in
                DispatchQueue.main.async {
                    self?.presentUploadFailure(upload, failure, keyMayHaveChanged: true)
                }
            }
        case .save:
            if !saveFileWithPanel(source, suggestedName: name) {
                moveFileToSaveFolder(source, name: name)
            }
        case .dismiss:
            moveFileToSaveFolder(source, name: name)
        }
    }
```

3. Replace `saveCurrentFileWithPanel()` and `moveCurrentFileToSaveFolder()` with versions built on file-taking helpers:

```swift
    /// Asks for a name in the configured folder and moves (rather than copies)
    /// the file there: once the user has chosen where the recording goes,
    /// nothing must be left for a safety net to move again. Returns true once
    /// the file is where the user chose; on a failed move the user is told
    /// where it still is.
    @discardableResult
    func saveFileWithPanel(_ source: URL, suggestedName: String) -> Bool {
        let panel = NSSavePanel()
        panel.title = "Save the meeting audio"
        panel.directoryURL = preferences.saveFolder
        panel.nameFieldStringValue = "\(suggestedName).m4a"
        panel.allowedContentTypes = [.mpeg4Audio]

        guard panel.runModal() == .OK, let destination = panel.url else { return false }
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: source, to: destination)
            return true
        } catch {
            showSaveFailureAlert(source: source, error: error)
            return false
        }
    }

    func saveCurrentFileWithPanel() {
        guard let source = currentFileURL else { return }
        if saveFileWithPanel(source, suggestedName: suggestedFileName()) { currentFileURL = nil }
    }

    /// Safety net: drops a recording into the default save folder so it is
    /// never silently lost. Returns where it landed, or nil when there was
    /// nothing to move or the move failed — the user has then been shown where
    /// the file remains.
    @discardableResult
    func moveFileToSaveFolder(_ source: URL, name: String) -> URL? {
        guard FileManager.default.fileExists(atPath: source.path) else { return nil }
        let destination = uniqueURL(in: preferences.saveFolder, name: name)
        do {
            try FileManager.default.moveItem(at: source, to: destination)
            return destination
        } catch {
            showSaveFailureAlert(source: source, error: error)
            return nil
        }
    }

    /// The current recording's version. If the move fails `currentFileURL` is
    /// kept, so a later attempt can still recover the file.
    @discardableResult
    func moveCurrentFileToSaveFolder() -> URL? {
        guard let source = currentFileURL else { return nil }
        guard FileManager.default.fileExists(atPath: source.path) else {
            currentFileURL = nil
            return nil
        }
        let destination = moveFileToSaveFolder(source, name: suggestedFileName())
        if destination != nil { currentFileURL = nil }
        return destination
    }
```

4. Replace `suggestedFileName()` and `fileNameSlug(for:)` with:

```swift
    /// Only a capture that failed or a quit mid-recording reach this: no title
    /// was ever given, and the start time is all there is.
    private func suggestedFileName() -> String {
        fileNameSlug(for: "meeting", at: startedAt ?? Date())
    }

    /// A file name built from the meeting's title and its date.
    func fileNameSlug(for title: String, at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = (cleaned.isEmpty ? "meeting" : cleaned)
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return "\(slug.isEmpty ? "meeting" : slug)-\(formatter.string(from: date))"
    }
```

5. In `saveCopyOfCurrentFile(named:)`, change `fileNameSlug(for: title)` to `fileNameSlug(for: title, at: startedAt ?? Date())`, and update its doc comment's last sentence to: "the upload that follows still needs the original, and the queue deletes it only once the upload has actually succeeded."

- [ ] **Step 7: Quit and launch (`RecordingRescue.swift`, `AppDelegate.swift`)**

In `WhiteboardRecorder/RecordingRescue.swift`, replace the start of `prepareForTermination()` up to the end of its `switch` with:

```swift
    func prepareForTermination() -> NSApplication.TerminateReply {
        // Anything queued is already on disk and resumes at the next launch;
        // stopping only spares the server a request cut in half.
        uploads.stop()

        if case .idle = flow.state { return .terminateNow }

        switch flow.state {
        case .configuring, .recording:
            // Closes the encoder and finalises the container. Even when it
            // throws, the partial file it names is worth rescuing.
            do {
                currentFileURL = try capture.stop()
            } catch {
                currentFileURL = partialFileURL(for: error)
            }
        case .idle, .failed:
            // Capture already stopped; `currentFileURL` is the partial file the
            // capture-failure alert is holding.
            break
        }
```

In `sweepStrandedRecordings()`, replace `let stranded = RecordingStorage.strandedFiles()` with:

```swift
        // Files still in the upload queue are not stranded: they resume next.
        let queued = uploads.referencedFileNames
        let stranded = RecordingStorage.strandedFiles().filter { !queued.contains($0.lastPathComponent) }
```

In `WhiteboardRecorder/AppDelegate.swift`, replace the deferred call in `applicationDidFinishLaunching` with:

```swift
        // Deferred so the status item is on screen before a modal alert can
        // take over, and so launch itself is never blocked by one. The sweep
        // runs first and leaves queued files alone; the queue then resumes.
        DispatchQueue.main.async {
            controller.sweepStrandedRecordings()
            controller.resumePendingUploads()
        }
```

and change the doc comment of `applicationShouldTerminate` to: "`terminate` unwinds nothing on its own: a quit while recording would leave an unplayable file in a folder nothing lists. The controller closes the capture, rescues the file and says where it went; uploads simply stop and resume at the next launch."

- [ ] **Step 8: Let the window know which upload it shows**

In `WhiteboardRecorder/ConfigurationWindowController.swift`, add after `private var content: …`:

```swift
    /// The upload this window shows, once OK has handed the recording over.
    private(set) var uploadID: UUID?

    func track(uploadID: UUID) {
        self.uploadID = uploadID
    }
```

- [ ] **Step 9: Build the app and run the tests**

Run: `xcodebuild -project WhiteboardRecorder.xcodeproj -scheme WhiteboardRecorder -configuration Debug -derivedDataPath build build 2>&1 | grep -E "error:|BUILD" | head -20`
Expected: `** BUILD SUCCEEDED **`.

If the compiler reports main-actor isolation errors in a callback known to run on the main thread (an AppKit or `DispatchQueue.main.async` closure), wrap the body in `MainActor.assumeIsolated { … }`. Do not drop `@MainActor` from the class.

Run: `swift test 2>&1 | tail -3`
Expected: all pass.

- [ ] **Step 10: Commit**

```bash
git add -A Sources/RecorderCore Tests/RecorderCoreTests WhiteboardRecorder
git commit -m "feat(app): send recordings through the background upload queue"
```

---

### Task 6: Progress, pause and resume in the window and the menu

**Files:**
- Modify: `WhiteboardRecorder/ConfigurationModel.swift` (`uploadID`)
- Modify: `WhiteboardRecorder/ConfigurationView.swift` (`sending` view)
- Modify: `WhiteboardRecorder/ConfigurationWindowController.swift` (pass the coordinator, `fitToContent` internal)
- Modify: `WhiteboardRecorder/MenuBarController.swift` (status line, Resume item, window refit)

**Interfaces:**
- Consumes: `UploadCoordinator.status(of:)`, `.activity`, `.waitingCount`, `.resume()`; `MenuBarController.uploads`; `ConfigurationWindowController.track(uploadID:)`
- Produces: `ConfigurationModel.uploadID: UUID?`; `ConfigurationView.uploads: UploadCoordinator`; `ConfigurationWindowController.init(…, uploads: UploadCoordinator, …)`; `ConfigurationWindowController.fitToContent()` (internal)

- [ ] **Step 1: The model carries the upload's id**

In `WhiteboardRecorder/ConfigurationModel.swift`, after `@Published var phase: Phase = .form`, add:

```swift
    /// Set once OK has handed the recording to the upload queue; the window
    /// follows that upload's progress by it.
    @Published var uploadID: UUID?
```

- [ ] **Step 2: The window passes the coordinator to its view**

In `WhiteboardRecorder/ConfigurationWindowController.swift`:
- add `uploads: UploadCoordinator,` to `init` right after `client: WhiteboardClient,`;
- pass it to the view: `ConfigurationView(model: model, uploads: uploads, onConfirm: …`;
- in `track(uploadID:)`, add `model.uploadID = uploadID` and `fitToContent()`;
- change `private func fitToContent()` to `func fitToContent()`.

In `WhiteboardRecorder/MenuBarController.swift` `showConfigurationWindow(startedAt:)`, add `uploads: uploads,` after `client: client,`.

- [ ] **Step 3: Replace the uploading screen**

In `WhiteboardRecorder/ConfigurationView.swift`, add `@ObservedObject var uploads: UploadCoordinator` after `@ObservedObject var model: ConfigurationModel`, then replace `private var sending: some View { … }` with:

```swift
    private var uploadStatus: UploadCoordinator.ItemStatus {
        model.uploadID.map(uploads.status(of:)) ?? .waiting
    }

    private var sending: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch uploadStatus {
            case .waiting:
                Text("Waiting…").font(.headline)
                Text("Waiting for the previous upload to finish…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case let .uploading(sent, total):
                Text("Uploading…").font(.headline)
                ProgressView(value: Double(sent), total: Double(max(total, 1)))
                    .progressViewStyle(.linear)
                Text("\(Self.megabytes(sent)) of \(Self.megabytes(total))")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            case let .paused(message):
                Label("Upload paused", systemImage: "pause.circle")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .finished:
                Text("Finishing…").font(.headline)
            }
            Text("Sending “\(model.title)” to \(model.selectedWorkspaceName).")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                // Closing is safe: the queue keeps going, and survives a quit.
                Text("The upload continues in the background.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if case .paused = uploadStatus {
                    Button("Resume upload") { uploads.resume() }
                }
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    private static func megabytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
```

- [ ] **Step 4: The window refits when its status changes**

In `MenuBarController.makeUploads()`, change the `activityObserver` sink body to:

```swift
            DispatchQueue.main.async {
                self?.refreshIcon()
                // Waiting, uploading and paused are not the same height.
                self?.configurationWindow?.fitToContent()
            }
```

- [ ] **Step 5: The menu says where the upload stands**

In `WhiteboardRecorder/MenuBarController.swift`:

1. After `private let durationSeparator = NSMenuItem.separator()`, add:

```swift
    /// Same idea as the duration line: a status line with no action, plus
    /// "Resume upload" while the queue is paused.
    private let uploadStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let resumeUploadItem = NSMenuItem(title: "Resume upload", action: #selector(resumeUpload), keyEquivalent: "")
    private let uploadSeparator = NSMenuItem.separator()
```

2. In `buildMenu()`, after `contextMenu.addItem(durationSeparator)`, add:

```swift
        uploadStatusItem.isHidden = true
        resumeUploadItem.isHidden = true
        uploadSeparator.isHidden = true
        resumeUploadItem.target = self
        contextMenu.addItem(uploadStatusItem)
        contextMenu.addItem(resumeUploadItem)
        contextMenu.addItem(uploadSeparator)
```

3. In `showMenu()`, before `contextMenu.popUp(…)`, add:

```swift
        let waiting = uploads.waitingCount > 0 ? " (+\(uploads.waitingCount) waiting)" : ""
        switch uploads.activity {
        case .idle:
            uploadStatusItem.isHidden = true
            resumeUploadItem.isHidden = true
            uploadSeparator.isHidden = true
        case let .uploading(_, title, sent, total):
            let percent = total > 0 ? Int(sent * 100 / total) : 0
            uploadStatusItem.title = "Uploading “\(title)” — \(percent)%\(waiting)"
            uploadStatusItem.isHidden = false
            resumeUploadItem.isHidden = true
            uploadSeparator.isHidden = false
        case let .paused(_, title, _):
            uploadStatusItem.title = "Upload paused — “\(title)”\(waiting)"
            uploadStatusItem.isHidden = false
            resumeUploadItem.isHidden = false
            uploadSeparator.isHidden = false
        }
```

4. Add next to `showPreferences`:

```swift
    @objc private func resumeUpload() {
        uploads.resume()
    }
```

- [ ] **Step 6: Build**

Run: `xcodebuild -project WhiteboardRecorder.xcodeproj -scheme WhiteboardRecorder -configuration Debug -derivedDataPath build build 2>&1 | grep -E "error:|BUILD" | head -20`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add WhiteboardRecorder
git commit -m "feat(app): upload progress, pause and resume in the window and the menu"
```

---

### Task 7: Docs, then the real-world check

This task needs the user (Wi-Fi off and on by hand): run it in the main session, not in a subagent.

**Files:**
- Modify: `README.md` ("Using it" and "When an upload fails")
- Modify: `docs/superpowers/specs/2026-10-15-resumable-upload-design.md` (status line)

- [ ] **Step 1: Update the README**

In `README.md`:
- In "Using it", replace the **OK** bullet with: "**OK** hands the recording to the upload queue. Uploads run in the background, one at a time, in pieces: a cut connection resumes where the server stopped, and a quit or a crash resumes at the next launch. The window shows the progress and can be closed; the icon is free for the next meeting at once."
- Replace "The app keeps its local copy until the upload succeeds, then deletes it." with "The app keeps its local copy until the server has the whole file and has created the recording, then deletes it."
- In "When an upload fails", add a first paragraph: "After four failed attempts in a row the upload pauses. It resumes by itself when the network comes back, or from **Resume upload** in the window or the right-click menu. A refused upload (key, workspace, title) shows the alert below; it leaves the queue so the next one can go."
- Update the spec's `Statut :` line to `implémenté`.

```bash
git add README.md docs/superpowers/specs/2026-10-15-resumable-upload-design.md
git commit -m "docs: the background, resumable upload"
```

- [ ] **Step 2: Build, install and relaunch the release app**

```bash
xcodebuild -project WhiteboardRecorder.xcodeproj -scheme WhiteboardRecorder -configuration Release -derivedDataPath build -allowProvisioningUpdates build 2>&1 | grep -E "error:|BUILD"
osascript -e 'tell application id "com.kepochan.whiteboard-recorder" to quit'
rm -rf /Applications/WhiteboardRecorder.app
cp -R build/Build/Products/Release/WhiteboardRecorder.app /Applications/
codesign --verify --strict /Applications/WhiteboardRecorder.app && echo SIGNED-OK
```

Do not open it yet.

- [ ] **Step 3: Prepare a recording of several tens of MB, queued by hand**

The queue file format makes this possible without recording for an hour:

```bash
WORK="$SCRATCHPAD/bigaudio"; mkdir -p "$WORK"
for i in $(seq 1 400); do echo "This is sentence number $i of the resumable upload test."; done > "$WORK/text.txt"
say -f "$WORK/text.txt" -o "$WORK/speech.aiff"
afconvert -f m4af -d aac@48000 -b 256000 "$WORK/speech.aiff" "$WORK/big.m4a"
ls -l "$WORK/big.m4a"   # aim for 30 MB or more; add sentences if smaller

APP_SUPPORT="$HOME/Library/Containers/com.kepochan.whiteboard-recorder/Data/Library/Application Support/WhiteboardRecorder"
NAME="$(uuidgen).m4a"
cp "$WORK/big.m4a" "$APP_SUPPORT/Recordings/$NAME"
SIZE=$(stat -f %z "$APP_SUPPORT/Recordings/$NAME")
cat > "$APP_SUPPORT/pending-uploads.json" <<EOF
[{"id":"$(uuidgen)","fileName":"$NAME","size":$SIZE,"completeSent":false,
  "configuration":{"workspaceID":"26d26a02-e0d2-4242-92ce-138995cf05f5","title":"Resumable upload test",
  "recordedAt":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","language":"en","sharingMode":"private","tags":[]}}]
EOF
```

(`$SCRATCHPAD` is the session scratchpad directory.)

- [ ] **Step 4: Launch, cut the Wi-Fi mid-upload, and watch it resume**

```bash
open /Applications/WhiteboardRecorder.app
/usr/bin/log stream --predicate 'subsystem == "com.kepochan.whiteboard-recorder"' --style compact
```

Expected: a "Resuming upload" banner, then `started … size=…`. Ask the user to turn the Wi-Fi off for about 20 s, then back on. Expected in the log: `failure 1…`, then either `resuming … at N` with N > 0 and pieces continuing from N, or, after four failures, a pause followed by an automatic resume at the server's offset once the Wi-Fi is back.

- [ ] **Step 5: Quit mid-upload and relaunch**

While pieces are still going: `osascript -e 'tell application id "com.kepochan.whiteboard-recorder" to quit'`, check that `pending-uploads.json` still lists the upload with its `uploadId`, then `open /Applications/WhiteboardRecorder.app`. Expected log: `resuming <same uploadId> at N` with N > 0 — no new `started` line — then `completed …`.

- [ ] **Step 6: Check the note on Whiteboard**

With the whiteboard MCP: `list_notes` (tag `meeting`) shows "resumable-upload-test-…"; read it after a few minutes and check that the transcription has arrived. `pending-uploads.json` is `[]` and the `.m4a` is gone from `Recordings/`. Ask the user before deleting the test note.

- [ ] **Step 7: Record the result in the Whiteboard note**

Append to `whiteboard-recorder-resumable-upload-prompt` a short "Vérification" section: file size, what was cut, the offsets seen at each resume, the note slug. Then report to the user.
