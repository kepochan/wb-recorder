# whiteboard-recorder — plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Une app macOS de barre de menu qui enregistre micro + audio système et envoie l'enregistrement à Whiteboard en un appel.

**Architecture:** Toute la logique vit dans `Sources/RecorderCore`, compilée deux fois : par SwiftPM pour les tests (`swift test`, boucle TDD sans Xcode) et par la cible applicative Xcode via un groupe de fichiers synchronisé. L'app elle-même n'est qu'une coquille AppKit (barre de menu) avec deux fenêtres SwiftUI. La capture audio est isolée derrière le protocole `AudioCapture` ; tout le reste est testable.

**Tech Stack:** Swift 5 (mode langage), Swift Testing, AppKit, SwiftUI, CoreAudio (process taps + device agrégé), AVFoundation, URLSession, Keychain.

**Spec:** `docs/superpowers/specs/2026-09-21-whiteboard-recorder-design.md`

## Global Constraints

- Cible minimale : **macOS 14.4**. Mode langage **Swift 5** (pas Swift 6 : les callbacks CoreAudio se plient mal à la concurrence stricte).
- Bundle identifier : `com.kepochan.whiteboard-recorder`. Nom affiché : `Whiteboard Recorder`. Équipe de signature : `99C5GU2775`.
- URL API par défaut : `https://whiteboard-api.kepochan.com`. Authentification : header `X-API-Key`. **Jamais** `Authorization: Bearer`, que le serveur ne lit pas.
- **Aucune clé API dans le code, dans un script ou dans un commit.** En développement, la clé est lue à l'exécution depuis `~/.claude/mcp_servers.json`.
- Textes destinés à l'utilisateur en français ; identifiants et commentaires de code en anglais.
- L'API rejette tout champ multipart non déclaré : n'envoyer que les champs listés dans la spec, et jamais `slug`.
- Commit à la fin de chaque tâche, jamais au milieu.

---

## Structure des fichiers

```
whiteboard-recorder/
├── Package.swift                     # construit RecorderCore pour swift test
├── Sources/RecorderCore/
│   ├── MultipartBody.swift           # enveloppe multipart écrite sur disque
│   ├── APIError.swift                # codes HTTP + corps → message français
│   ├── HTTPSession.swift             # protocole d'injection de URLSession
│   ├── Models.swift                  # Workspace, Tag, RecordingUpload, UploadedRecording
│   ├── WhiteboardClient.swift        # les trois appels API
│   ├── Preferences.swift             # réglages UserDefaults
│   ├── KeychainStore.swift           # la clé API
│   ├── RecordingFlow.swift           # machine à états pure
│   ├── AudioCapture.swift            # protocole + erreurs
│   ├── CoreAudioCapture.swift        # tap + agrégat + mix + écriture AAC
│   └── ESP32Display.swift            # écran rouge / noir
├── Tests/RecorderCoreTests/          # un fichier de test par module
├── WhiteboardRecorder/               # cible app (groupe synchronisé)
│   ├── AppDelegate.swift
│   ├── MenuBarController.swift
│   ├── StatusIcon.swift
│   ├── ConfigurationWindow.swift     # hôte AppKit + vue SwiftUI
│   ├── PreferencesWindow.swift
│   └── FailureAlert.swift
├── Config/
│   ├── Info.plist
│   └── WhiteboardRecorder.entitlements
├── WhiteboardRecorder.xcodeproj/
├── run.sh
└── build-release.sh
```

`Sources/RecorderCore` appartient à la fois au package SwiftPM et à la cible applicative. Conséquence : le code applicatif n'écrit **pas** `import RecorderCore` — les types sont déjà dans son module. Les tests, eux, font `@testable import RecorderCore`.

---

### Task 1: Socle du package et `MultipartBody`

**Files:**
- Create: `Package.swift`
- Create: `Sources/RecorderCore/MultipartBody.swift`
- Test: `Tests/RecorderCoreTests/MultipartBodyTests.swift`

**Interfaces:**
- Consumes: rien.
- Produces: `MultipartBody(boundary: String)`, `var contentType: String`, `mutating func addField(_ name: String, _ value: String)`, `mutating func addFile(_ name: String, url: URL, filename: String, contentType: String)`, `func write(to destination: URL) throws`.

- [ ] **Step 1: Créer `Package.swift`**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RecorderCore",
    platforms: [.macOS("14.4")],
    products: [
        .library(name: "RecorderCore", targets: ["RecorderCore"])
    ],
    targets: [
        .target(
            name: "RecorderCore",
            path: "Sources/RecorderCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "RecorderCoreTests",
            dependencies: ["RecorderCore"],
            path: "Tests/RecorderCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
```

- [ ] **Step 2: Écrire le test qui échoue**

Créer `Tests/RecorderCoreTests/MultipartBodyTests.swift` :

```swift
import Foundation
import Testing
@testable import RecorderCore

@Test func multipartWritesFieldsAndFileWithCRLF() throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let audio = tmp.appendingPathComponent("rec.m4a")
    try Data("AUDIOBYTES".utf8).write(to: audio)

    var body = MultipartBody(boundary: "BDRY")
    body.addFile("audio", url: audio, filename: "rec.m4a", contentType: "audio/mp4")
    body.addField("title", "Daily")

    let envelope = tmp.appendingPathComponent("envelope")
    try body.write(to: envelope)

    let written = try String(contentsOf: envelope, encoding: .utf8)
    let expected = [
        "--BDRY",
        "Content-Disposition: form-data; name=\"audio\"; filename=\"rec.m4a\"",
        "Content-Type: audio/mp4",
        "",
        "AUDIOBYTES",
        "--BDRY",
        "Content-Disposition: form-data; name=\"title\"",
        "",
        "Daily",
        "--BDRY--",
        ""
    ].joined(separator: "\r\n")

    #expect(written == expected)
    #expect(body.contentType == "multipart/form-data; boundary=BDRY")
}

@Test func multipartGeneratesAUniqueBoundaryByDefault() {
    #expect(MultipartBody().boundary != MultipartBody().boundary)
}
```

- [ ] **Step 3: Lancer le test et vérifier qu'il échoue**

Run: `swift test --filter MultipartBody`
Expected: échec de compilation, `cannot find 'MultipartBody' in scope`.

- [ ] **Step 4: Écrire l'implémentation minimale**

Créer `Sources/RecorderCore/MultipartBody.swift` :

```swift
import Foundation

/// Builds a multipart/form-data envelope on disk so large audio files are
/// streamed by URLSession instead of being held in memory.
public struct MultipartBody {
    private enum Part {
        case field(name: String, value: String)
        case file(name: String, url: URL, filename: String, contentType: String)
    }

    public let boundary: String
    private var parts: [Part] = []

    public init(boundary: String = "wbr-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    public var contentType: String {
        "multipart/form-data; boundary=\(boundary)"
    }

    public mutating func addField(_ name: String, _ value: String) {
        parts.append(.field(name: name, value: value))
    }

    public mutating func addFile(_ name: String, url: URL, filename: String, contentType: String) {
        parts.append(.file(name: name, url: url, filename: filename, contentType: contentType))
    }

    public func write(to destination: URL) throws {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let out = try FileHandle(forWritingTo: destination)
        defer { try? out.close() }

        for part in parts {
            switch part {
            case let .field(name, value):
                try out.write(contentsOf: Data("""
                --\(boundary)\r
                Content-Disposition: form-data; name="\(name)"\r
                \r
                \(value)\r\n
                """.utf8))
            case let .file(name, url, filename, contentType):
                try out.write(contentsOf: Data("""
                --\(boundary)\r
                Content-Disposition: form-data; name="\(name)"; filename="\(filename)"\r
                Content-Type: \(contentType)\r
                \r\n
                """.utf8))
                let input = try FileHandle(forReadingFrom: url)
                defer { try? input.close() }
                while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
                    try out.write(contentsOf: chunk)
                }
                try out.write(contentsOf: Data("\r\n".utf8))
            }
        }
        try out.write(contentsOf: Data("--\(boundary)--\r\n".utf8))
    }
}
```

Attention aux littéraux multi-lignes : chaque ligne se termine par `\r` puis le
retour à la ligne réel, ce qui produit bien `\r\n`. Si le test échoue sur un écart
d'un octet, comparer avec `Array(written.utf8)` pour localiser le caractère fautif.

- [ ] **Step 5: Lancer le test et vérifier qu'il passe**

Run: `swift test --filter MultipartBody`
Expected: 2 tests, 0 échec.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources Tests
git commit -m "feat(core): multipart envelope written to disk"
```

---

### Task 2: `APIError`

**Files:**
- Create: `Sources/RecorderCore/APIError.swift`
- Test: `Tests/RecorderCoreTests/APIErrorTests.swift`

**Interfaces:**
- Consumes: rien.
- Produces: `enum APIError: Error, Equatable` avec les cas `badRequest([String])`, `unauthorized(String)`, `forbidden(String)`, `notFound(String)`, `conflict(String)`, `tooLarge`, `server(status: Int, String)`, `invalidResponse`, `invalidTitle`, `recordedAtInFuture`, `noAPIKey` ; `static func from(status: Int, body: Data) -> APIError` ; `var message: String`.

- [ ] **Step 1: Écrire le test qui échoue**

Créer `Tests/RecorderCoreTests/APIErrorTests.swift` :

```swift
import Foundation
import Testing
@testable import RecorderCore

@Test func badRequestKeepsEveryValidationMessage() {
    let body = Data(#"{"message":["title should not be empty","language must be valid"],"statusCode":400}"#.utf8)
    let error = APIError.from(status: 400, body: body)
    #expect(error == .badRequest(["title should not be empty", "language must be valid"]))
    #expect(error.message == "title should not be empty\nlanguage must be valid")
}

@Test func singleStringMessageIsAccepted() {
    let body = Data(#"{"message":"Invalid or expired API key"}"#.utf8)
    #expect(APIError.from(status: 401, body: body) == .unauthorized("Invalid or expired API key"))
}

@Test func knownStatusesMapToFrenchMessages() {
    #expect(APIError.from(status: 413, body: Data()) == .tooLarge)
    #expect(APIError.tooLarge.message.contains("1 Gio"))
    #expect(APIError.unauthorized("").message.contains("Clé API"))
    #expect(APIError.forbidden("").message.contains("workspace"))
    #expect(APIError.conflict("").message.contains("existe déjà"))
}

@Test func unknownStatusCarriesItsCode() {
    let error = APIError.from(status: 502, body: Data())
    #expect(error == .server(status: 502, ""))
    #expect(error.message.contains("502"))
}
```

- [ ] **Step 2: Lancer le test et vérifier qu'il échoue**

Run: `swift test --filter APIError`
Expected: `cannot find 'APIError' in scope`.

- [ ] **Step 3: Écrire l'implémentation minimale**

Créer `Sources/RecorderCore/APIError.swift` :

```swift
import Foundation

public enum APIError: Error, Equatable {
    case noAPIKey
    case invalidTitle
    case recordedAtInFuture
    case badRequest([String])
    case unauthorized(String)
    case forbidden(String)
    case notFound(String)
    case conflict(String)
    case tooLarge
    case server(status: Int, String)
    case invalidResponse

    public static func from(status: Int, body: Data) -> APIError {
        let messages = ErrorBody.decode(body)
        let joined = messages.joined(separator: "\n")
        switch status {
        case 400: return .badRequest(messages)
        case 401: return .unauthorized(joined)
        case 403: return .forbidden(joined)
        case 404: return .notFound(joined)
        case 409: return .conflict(joined)
        case 413: return .tooLarge
        default: return .server(status: status, joined)
        }
    }

    public var message: String {
        switch self {
        case .noAPIKey:
            return "Aucune clé API configurée. Ouvre les Préférences pour en coller une."
        case .invalidTitle:
            return "Le titre doit faire entre 1 et 255 caractères."
        case .recordedAtInFuture:
            return "La date de réunion ne peut pas être dans le futur."
        case let .badRequest(messages):
            return messages.isEmpty ? "Requête refusée par le serveur." : messages.joined(separator: "\n")
        case .unauthorized:
            return "Clé API absente, invalide ou révoquée."
        case let .forbidden(detail):
            return detail.isEmpty ? "Tu n'es pas membre de ce workspace." : "Accès refusé : \(detail)"
        case let .notFound(detail):
            return detail.isEmpty ? "Ressource introuvable." : detail
        case .conflict:
            return "Une note portant ce slug existe déjà."
        case .tooLarge:
            return "Fichier trop volumineux (limite : 1 Gio)."
        case let .server(status, detail):
            return detail.isEmpty ? "Erreur serveur (\(status))." : "Erreur serveur (\(status)) : \(detail)"
        case .invalidResponse:
            return "Réponse inattendue du serveur."
        }
    }
}

/// The API returns `message` as a string for auth errors and as an array for
/// validation errors; both shapes are accepted.
private struct ErrorBody: Decodable {
    let messages: [String]

    static func decode(_ data: Data) -> [String] {
        (try? JSONDecoder().decode(ErrorBody.self, from: data).messages) ?? []
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let single = try? container.decode(String.self, forKey: .message) {
            messages = [single]
        } else {
            messages = (try? container.decode([String].self, forKey: .message)) ?? []
        }
    }

    private enum CodingKeys: String, CodingKey { case message }
}
```

- [ ] **Step 4: Lancer le test et vérifier qu'il passe**

Run: `swift test --filter APIError`
Expected: 4 tests, 0 échec.

- [ ] **Step 5: Commit**

```bash
git add Sources/RecorderCore/APIError.swift Tests/RecorderCoreTests/APIErrorTests.swift
git commit -m "feat(core): map HTTP failures to French messages"
```

---

### Task 3: `WhiteboardClient` — workspaces et tags

**Files:**
- Create: `Sources/RecorderCore/HTTPSession.swift`
- Create: `Sources/RecorderCore/Models.swift`
- Create: `Sources/RecorderCore/WhiteboardClient.swift`
- Create: `Tests/RecorderCoreTests/FakeSession.swift`
- Test: `Tests/RecorderCoreTests/WhiteboardClientTests.swift`

**Interfaces:**
- Consumes: `APIError` (Task 2).
- Produces:
  - `protocol HTTPSession` : `func data(for: URLRequest) async throws -> (Data, URLResponse)` et `func upload(for: URLRequest, fromFile: URL) async throws -> (Data, URLResponse)`, avec `extension URLSession: HTTPSession {}`.
  - `struct Workspace: Decodable, Equatable, Identifiable { let id: String; let name: String }`.
  - `struct Tag: Codable, Equatable, Hashable { let label: String; let color: String; let count: Int? }` — `count` est décodé mais **jamais encodé**.
  - `struct WhiteboardClient` : `init(baseURL: URL, apiKey: @escaping () -> String?, session: HTTPSession = URLSession.shared)`, `func listWorkspaces() async throws -> [Workspace]`, `func listTags(workspaceID: String) async throws -> [Tag]`.

Note : on injecte un double de `HTTPSession` plutôt que de bouchonner `URLProtocol`.
C'est la même intention que dans la spec — observer la requête réellement construite —
mais sans la fragilité de `URLProtocol` face à `upload(for:fromFile:)`.

- [ ] **Step 1: Écrire le double de session**

Créer `Tests/RecorderCoreTests/FakeSession.swift` :

```swift
import Foundation
@testable import RecorderCore

final class FakeSession: HTTPSession, @unchecked Sendable {
    struct Call {
        let request: URLRequest
        let uploadedFile: URL?
    }

    private(set) var calls: [Call] = []
    var nextStatus = 200
    var nextBody = Data()

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        calls.append(Call(request: request, uploadedFile: nil))
        return (nextBody, response(for: request))
    }

    func upload(for request: URLRequest, fromFile fileURL: URL) async throws -> (Data, URLResponse) {
        // The envelope is deleted as soon as upload() returns, so copy it now.
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.copyItem(at: fileURL, to: copy)
        calls.append(Call(request: request, uploadedFile: copy))
        return (nextBody, response(for: request))
    }

    private func response(for request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: nextStatus, httpVersion: nil, headerFields: nil)!
    }
}
```

- [ ] **Step 2: Écrire le test qui échoue**

Créer `Tests/RecorderCoreTests/WhiteboardClientTests.swift` :

```swift
import Foundation
import Testing
@testable import RecorderCore

private let base = URL(string: "https://whiteboard-api.kepochan.com")!

private func makeClient(_ session: FakeSession, key: String? = "wb_test") -> WhiteboardClient {
    WhiteboardClient(baseURL: base, apiKey: { key }, session: session)
}

@Test func listWorkspacesSendsTheKeyInTheRightHeader() async throws {
    let session = FakeSession()
    session.nextBody = Data(#"[{"id":"uuid-1","name":"Produit","isPersonal":false}]"#.utf8)

    let workspaces = try await makeClient(session).listWorkspaces()

    #expect(workspaces == [Workspace(id: "uuid-1", name: "Produit")])
    let request = try #require(session.calls.first?.request)
    #expect(request.url?.absoluteString == "https://whiteboard-api.kepochan.com/workspaces")
    #expect(request.httpMethod == "GET")
    #expect(request.value(forHTTPHeaderField: "X-API-Key") == "wb_test")
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
}

@Test func listTagsHitsTheWorkspaceScopedRoute() async throws {
    let session = FakeSession()
    session.nextBody = Data(#"[{"label":"japon","color":"red","count":10}]"#.utf8)

    let tags = try await makeClient(session).listTags(workspaceID: "uuid-1")

    #expect(tags == [Tag(label: "japon", color: "red", count: 10)])
    #expect(session.calls.first?.request.url?.absoluteString
        == "https://whiteboard-api.kepochan.com/workspaces/uuid-1/tags")
}

@Test func missingKeyFailsBeforeAnyRequest() async {
    let session = FakeSession()
    await #expect(throws: APIError.noAPIKey) {
        _ = try await makeClient(session, key: nil).listWorkspaces()
    }
    #expect(session.calls.isEmpty)
}

@Test func httpFailureIsTranslated() async {
    let session = FakeSession()
    session.nextStatus = 401
    session.nextBody = Data(#"{"message":"Invalid or expired API key"}"#.utf8)

    await #expect(throws: APIError.unauthorized("Invalid or expired API key")) {
        _ = try await makeClient(session).listWorkspaces()
    }
}
```

- [ ] **Step 3: Lancer le test et vérifier qu'il échoue**

Run: `swift test --filter WhiteboardClient`
Expected: `cannot find 'WhiteboardClient' in scope`.

- [ ] **Step 4: Écrire `HTTPSession.swift`**

```swift
import Foundation

/// Seam that lets tests observe the requests the client actually builds.
public protocol HTTPSession: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
    func upload(for request: URLRequest, fromFile fileURL: URL) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPSession {}
```

- [ ] **Step 5: Écrire `Models.swift`**

```swift
import Foundation

public struct Workspace: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct Tag: Codable, Equatable, Hashable, Sendable {
    public let label: String
    public let color: String
    /// Usage count, returned when listing but never sent back.
    public let count: Int?

    public init(label: String, color: String, count: Int? = nil) {
        self.label = label
        self.color = color
        self.count = count
    }

    private enum CodingKeys: String, CodingKey { case label, color, count }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(label, forKey: .label)
        try container.encode(color, forKey: .color)
    }
}
```

- [ ] **Step 6: Écrire `WhiteboardClient.swift`**

```swift
import Foundation

public struct WhiteboardClient {
    public let baseURL: URL
    private let apiKey: () -> String?
    private let session: HTTPSession

    public init(baseURL: URL, apiKey: @escaping () -> String?, session: HTTPSession = URLSession.shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
    }

    public func listWorkspaces() async throws -> [Workspace] {
        try await get("workspaces")
    }

    public func listTags(workspaceID: String) async throws -> [Tag] {
        try await get("workspaces/\(workspaceID)/tags")
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let request = try makeRequest(path)
        let (data, response) = try await session.data(for: request)
        try check(response, data)
        return try decode(data)
    }

    func makeRequest(_ path: String, method: String = "GET") throws -> URLRequest {
        guard let key = apiKey(), !key.isEmpty else { throw APIError.noAPIKey }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue(key, forHTTPHeaderField: "X-API-Key")
        return request
    }

    func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            throw APIError.from(status: http.statusCode, body: data)
        }
    }

    func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.invalidResponse
        }
    }
}
```

- [ ] **Step 7: Lancer le test et vérifier qu'il passe**

Run: `swift test --filter WhiteboardClient`
Expected: 4 tests, 0 échec.

- [ ] **Step 8: Commit**

```bash
git add Sources/RecorderCore Tests/RecorderCoreTests
git commit -m "feat(core): list workspaces and workspace tags"
```

---

### Task 4: `WhiteboardClient.upload`

**Files:**
- Modify: `Sources/RecorderCore/Models.swift` (ajouter `RecordingUpload`, `UploadedRecording`)
- Modify: `Sources/RecorderCore/WhiteboardClient.swift` (ajouter `upload`)
- Create: `Sources/RecorderCore/ISO8601.swift`
- Test: `Tests/RecorderCoreTests/UploadTests.swift`

**Interfaces:**
- Consumes: `MultipartBody` (Task 1), `APIError` (Task 2), `HTTPSession`, `Tag` (Task 3).
- Produces:
  - `struct RecordingUpload: Equatable { var audioURL: URL; var workspaceID: String; var title: String; var recordedAt: Date; var language: String; var sharingMode: String; var tags: [Tag] }`
  - `struct UploadedRecording: Decodable, Equatable { let id: String; let noteSlug: String; let status: String }`
  - `func upload(_ recording: RecordingUpload) async throws -> UploadedRecording`
  - `enum ISO8601 { static func string(from: Date) -> String }`

- [ ] **Step 1: Écrire le test qui échoue**

Créer `Tests/RecorderCoreTests/UploadTests.swift` :

```swift
import Foundation
import Testing
@testable import RecorderCore

private let base = URL(string: "https://whiteboard-api.kepochan.com")!

private func makeRecording(in directory: URL, tags: [Tag] = []) throws -> RecordingUpload {
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

private func withTemporaryDirectory(_ body: (URL) throws -> Void) rethrows {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
}

@Test func uploadSendsTheDeclaredFieldsAndNothingElse() async throws {
    var envelope = ""
    var request: URLRequest?
    var result: UploadedRecording?

    try withTemporaryDirectory { directory in
        let session = FakeSession()
        session.nextStatus = 201
        session.nextBody = Data(#"{"id":"rec-1","noteId":"note-1","noteSlug":"daily-2026-09-17","status":"pending"}"#.utf8)
        let client = WhiteboardClient(baseURL: base, apiKey: { "wb_test" }, session: session)
        let recording = try makeRecording(in: directory, tags: [Tag(label: "japon", color: "red", count: 10)])

        let semaphore = DispatchSemaphore(value: 0)
        Task {
            result = try? await client.upload(recording)
            semaphore.signal()
        }
        semaphore.wait()

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
    #expect(envelope.contains(#"name="tags""#))
    #expect(envelope.contains(#"[{"label":"japon","color":"red"}]"#))
    #expect(!envelope.contains("count"))
    // The server derives the slug; sending an undeclared field would be a 400.
    #expect(!envelope.contains(#"name="slug""#))
}

@Test func tagsFieldIsOmittedWhenNoTagIsSelected() async throws {
    try withTemporaryDirectory { directory in
        let session = FakeSession()
        session.nextStatus = 201
        session.nextBody = Data(#"{"id":"rec-1","noteSlug":"daily","status":"pending"}"#.utf8)
        let client = WhiteboardClient(baseURL: base, apiKey: { "wb_test" }, session: session)
        let recording = try makeRecording(in: directory)

        let semaphore = DispatchSemaphore(value: 0)
        Task {
            _ = try? await client.upload(recording)
            semaphore.signal()
        }
        semaphore.wait()

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
```

- [ ] **Step 2: Lancer le test et vérifier qu'il échoue**

Run: `swift test --filter Upload`
Expected: `cannot find 'RecordingUpload' in scope`.

- [ ] **Step 3: Créer `Sources/RecorderCore/ISO8601.swift`**

```swift
import Foundation

public enum ISO8601 {
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    public static func string(from date: Date) -> String {
        formatter.string(from: date)
    }
}
```

- [ ] **Step 4: Ajouter les modèles à `Models.swift`**

```swift
public struct RecordingUpload: Equatable, Sendable {
    public var audioURL: URL
    public var workspaceID: String
    public var title: String
    public var recordedAt: Date
    public var language: String
    public var sharingMode: String
    public var tags: [Tag]

    public init(audioURL: URL, workspaceID: String, title: String, recordedAt: Date,
                language: String, sharingMode: String, tags: [Tag]) {
        self.audioURL = audioURL
        self.workspaceID = workspaceID
        self.title = title
        self.recordedAt = recordedAt
        self.language = language
        self.sharingMode = sharingMode
        self.tags = tags
    }
}

public struct UploadedRecording: Decodable, Equatable, Sendable {
    public let id: String
    public let noteSlug: String
    public let status: String

    public init(id: String, noteSlug: String, status: String) {
        self.id = id
        self.noteSlug = noteSlug
        self.status = status
    }
}
```

- [ ] **Step 5: Ajouter `upload` à `WhiteboardClient.swift`**

```swift
extension WhiteboardClient {
    public func upload(_ recording: RecordingUpload) async throws -> UploadedRecording {
        let title = recording.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 255 else { throw APIError.invalidTitle }
        guard recording.recordedAt <= Date() else { throw APIError.recordedAtInFuture }

        var body = MultipartBody()
        body.addFile("audio", url: recording.audioURL,
                     filename: recording.audioURL.lastPathComponent, contentType: "audio/mp4")
        body.addField("workspaceId", recording.workspaceID)
        body.addField("title", title)
        body.addField("recordedAt", ISO8601.string(from: recording.recordedAt))
        body.addField("language", recording.language)
        body.addField("sharingMode", recording.sharingMode)
        if !recording.tags.isEmpty {
            let json = try JSONEncoder().encode(recording.tags)
            body.addField("tags", String(decoding: json, as: UTF8.self))
        }

        let envelope = FileManager.default.temporaryDirectory
            .appendingPathComponent("wbr-\(UUID().uuidString).multipart")
        try body.write(to: envelope)
        defer { try? FileManager.default.removeItem(at: envelope) }

        var request = try makeRequest("recordings", method: "POST")
        request.setValue(body.contentType, forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.upload(for: request, fromFile: envelope)
        try check(response, data)
        return try decode(data)
    }
}
```

`session` est `private` : le passer en `internal` (retirer `private`) pour que
l'extension y accède. Même chose pour `apiKey` si nécessaire.

- [ ] **Step 6: Lancer toute la suite**

Run: `swift test`
Expected: tous les tests passent.

- [ ] **Step 7: Commit**

```bash
git add Sources/RecorderCore Tests/RecorderCoreTests
git commit -m "feat(core): upload a recording in one multipart call"
```

---

### Task 5: `Preferences`

**Files:**
- Create: `Sources/RecorderCore/Preferences.swift`
- Test: `Tests/RecorderCoreTests/PreferencesTests.swift`

**Interfaces:**
- Consumes: rien.
- Produces: `final class Preferences { init(defaults: UserDefaults = .standard) }` avec les propriétés en lecture/écriture `defaultWorkspaceID: String?`, `lastWorkspaceID: String?`, `lastLanguage: String`, `lastSharingMode: String`, `apiBaseURL: URL`, `esp32Host: String?`, `saveFolder: URL`, plus `var effectiveWorkspaceID: String?` et les constantes `static let languages: [String]`, `static let sharingModes: [String]`.

- [ ] **Step 1: Écrire le test qui échoue**

Créer `Tests/RecorderCoreTests/PreferencesTests.swift` :

```swift
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
    #expect(preferences.lastLanguage == "auto")
    #expect(preferences.lastSharingMode == "private")
    #expect(preferences.esp32Host == nil)
    #expect(preferences.saveFolder.path.hasSuffix("/Downloads"))
    #expect(Preferences.languages == ["auto", "fr", "en"])
    #expect(Preferences.sharingModes == ["private", "protected", "limited", "editable", "public", "open-bar"])
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
```

- [ ] **Step 2: Lancer le test et vérifier qu'il échoue**

Run: `swift test --filter Preferences`
Expected: `cannot find 'Preferences' in scope`.

- [ ] **Step 3: Écrire l'implémentation minimale**

Créer `Sources/RecorderCore/Preferences.swift` :

```swift
import Foundation

public final class Preferences {
    public static let languages = ["auto", "fr", "en"]
    public static let sharingModes = ["private", "protected", "limited", "editable", "public", "open-bar"]
    public static let defaultAPIBaseURL = URL(string: "https://whiteboard-api.kepochan.com")!

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
```

- [ ] **Step 4: Lancer le test et vérifier qu'il passe**

Run: `swift test --filter Preferences`
Expected: 4 tests, 0 échec.

- [ ] **Step 5: Commit**

```bash
git add Sources/RecorderCore/Preferences.swift Tests/RecorderCoreTests/PreferencesTests.swift
git commit -m "feat(core): persist settings and remembered choices"
```

---

### Task 6: `KeychainStore`

**Files:**
- Create: `Sources/RecorderCore/KeychainStore.swift`
- Test: `Tests/RecorderCoreTests/KeychainStoreTests.swift`

**Interfaces:**
- Consumes: rien.
- Produces: `struct KeychainStore { init(service: String = "com.kepochan.whiteboard-recorder", account: String = "api-key"); func save(_ key: String) throws; func read() -> String?; func delete() }`.

- [ ] **Step 1: Écrire le test qui échoue**

Créer `Tests/RecorderCoreTests/KeychainStoreTests.swift` :

```swift
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
```

- [ ] **Step 2: Lancer le test et vérifier qu'il échoue**

Run: `swift test --filter Keychain`
Expected: `cannot find 'KeychainStore' in scope`.

- [ ] **Step 3: Écrire l'implémentation minimale**

Créer `Sources/RecorderCore/KeychainStore.swift` :

```swift
import Foundation
import Security

public struct KeychainStore {
    public enum Failure: Error, Equatable {
        case unavailable(OSStatus)
        case failed(OSStatus)
    }

    private let service: String
    private let account: String

    public init(service: String = "com.kepochan.whiteboard-recorder", account: String = "api-key") {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    public func save(_ key: String) throws {
        delete()
        var attributes = query
        attributes[kSecValueData as String] = Data(key.utf8)
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            if status == errSecMissingEntitlement || status == errSecNotAvailable {
                throw Failure.unavailable(status)
            }
            throw Failure.failed(status)
        }
    }

    public func read() -> String? {
        var attributes = query
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(attributes as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
```

- [ ] **Step 4: Lancer le test et vérifier qu'il passe**

Run: `swift test --filter Keychain`
Expected: 1 test, 0 échec — y compris s'il sort par le chemin `unavailable`.

- [ ] **Step 5: Commit**

```bash
git add Sources/RecorderCore/KeychainStore.swift Tests/RecorderCoreTests/KeychainStoreTests.swift
git commit -m "feat(core): keep the API key in the keychain"
```

---

### Task 7: `RecordingFlow`

**Files:**
- Create: `Sources/RecorderCore/RecordingFlow.swift`
- Test: `Tests/RecorderCoreTests/RecordingFlowTests.swift`

**Interfaces:**
- Consumes: rien (volontairement : la machine ne connaît ni le réseau ni l'audio).
- Produces:
  - `struct RecordingConfiguration: Equatable { var workspaceID: String; var title: String; var recordedAt: Date; var language: String; var sharingMode: String; var tags: [Tag] }`
  - `enum RecordingState: Equatable { case idle; case configuring(startedAt: Date); case recording(startedAt: Date, configuration: RecordingConfiguration); case uploading(RecordingConfiguration); case failed(RecordingConfiguration, message: String) }`
  - `enum RecordingEvent { case iconClicked; case configurationConfirmed(RecordingConfiguration); case configurationCancelled; case uploadSucceeded; case uploadFailed(String); case retryRequested; case failureDismissed }`
  - `enum RecordingEffect: Equatable { case startCapture; case stopCapture; case discardFile; case deleteFile; case moveFileToSaveFolder; case upload(RecordingConfiguration); case showConfigurationWindow(startedAt: Date); case focusConfigurationWindow; case setIcon(IconState); case setESP32Recording(Bool) }`
  - `enum IconState: Equatable { case idle, recording, uploading }`
  - `final class RecordingFlow { private(set) var state: RecordingState; func handle(_ event: RecordingEvent) -> [RecordingEffect] }`

- [ ] **Step 1: Écrire le test qui échoue**

Créer `Tests/RecorderCoreTests/RecordingFlowTests.swift` :

```swift
import Foundation
import Testing
@testable import RecorderCore

private let fixedDate = Date(timeIntervalSince1970: 1_789_655_520)

private func makeConfiguration() -> RecordingConfiguration {
    RecordingConfiguration(workspaceID: "uuid-1", title: "Daily", recordedAt: fixedDate,
                           language: "fr", sharingMode: "private", tags: [])
}

@Test func clickingWhileIdleStartsCapturingBeforeAskingAnything() {
    let flow = RecordingFlow(now: { fixedDate })
    let effects = flow.handle(.iconClicked)
    #expect(effects == [.startCapture, .setIcon(.recording), .setESP32Recording(true),
                        .showConfigurationWindow(startedAt: fixedDate)])
    #expect(flow.state == .configuring(startedAt: fixedDate))
}

@Test func clickingWhileTheWindowIsOpenOnlyBringsItBack() {
    let flow = RecordingFlow(now: { fixedDate })
    _ = flow.handle(.iconClicked)
    #expect(flow.handle(.iconClicked) == [.focusConfigurationWindow])
    #expect(flow.state == .configuring(startedAt: fixedDate))
}

@Test func cancellingThrowsTheRecordingAway() {
    let flow = RecordingFlow(now: { fixedDate })
    _ = flow.handle(.iconClicked)
    #expect(flow.handle(.configurationCancelled)
        == [.stopCapture, .discardFile, .setESP32Recording(false), .setIcon(.idle)])
    #expect(flow.state == .idle)
}

@Test func confirmingKeepsRecordingUntilTheNextClick() {
    let flow = RecordingFlow(now: { fixedDate })
    let configuration = makeConfiguration()
    _ = flow.handle(.iconClicked)

    #expect(flow.handle(.configurationConfirmed(configuration)) == [])
    #expect(flow.state == .recording(startedAt: fixedDate, configuration: configuration))

    #expect(flow.handle(.iconClicked)
        == [.stopCapture, .setESP32Recording(false), .setIcon(.uploading), .upload(configuration)])
    #expect(flow.state == .uploading(configuration))
}

@Test func aClickDuringUploadDoesNothing() {
    let flow = RecordingFlow(now: { fixedDate })
    _ = flow.handle(.iconClicked)
    _ = flow.handle(.configurationConfirmed(makeConfiguration()))
    _ = flow.handle(.iconClicked)
    #expect(flow.handle(.iconClicked) == [])
}

@Test func successDeletesTheLocalFile() {
    let flow = RecordingFlow(now: { fixedDate })
    _ = flow.handle(.iconClicked)
    _ = flow.handle(.configurationConfirmed(makeConfiguration()))
    _ = flow.handle(.iconClicked)

    #expect(flow.handle(.uploadSucceeded) == [.deleteFile, .setIcon(.idle)])
    #expect(flow.state == .idle)
}

@Test func failureKeepsTheFileAndAllowsARetry() {
    let flow = RecordingFlow(now: { fixedDate })
    let configuration = makeConfiguration()
    _ = flow.handle(.iconClicked)
    _ = flow.handle(.configurationConfirmed(configuration))
    _ = flow.handle(.iconClicked)

    #expect(flow.handle(.uploadFailed("Réseau injoignable")) == [.setIcon(.idle)])
    #expect(flow.state == .failed(configuration, message: "Réseau injoignable"))

    #expect(flow.handle(.retryRequested) == [.setIcon(.uploading), .upload(configuration)])
    #expect(flow.state == .uploading(configuration))
}

@Test func dismissingAFailureMovesTheFileToTheSaveFolder() {
    let flow = RecordingFlow(now: { fixedDate })
    _ = flow.handle(.iconClicked)
    _ = flow.handle(.configurationConfirmed(makeConfiguration()))
    _ = flow.handle(.iconClicked)
    _ = flow.handle(.uploadFailed("boom"))

    #expect(flow.handle(.failureDismissed) == [.moveFileToSaveFolder, .setIcon(.idle)])
    #expect(flow.state == .idle)
}
```

- [ ] **Step 2: Lancer le test et vérifier qu'il échoue**

Run: `swift test --filter RecordingFlow`
Expected: `cannot find 'RecordingFlow' in scope`.

- [ ] **Step 3: Écrire l'implémentation minimale**

Créer `Sources/RecorderCore/RecordingFlow.swift` :

```swift
import Foundation

public struct RecordingConfiguration: Equatable, Sendable {
    public var workspaceID: String
    public var title: String
    public var recordedAt: Date
    public var language: String
    public var sharingMode: String
    public var tags: [Tag]

    public init(workspaceID: String, title: String, recordedAt: Date,
                language: String, sharingMode: String, tags: [Tag]) {
        self.workspaceID = workspaceID
        self.title = title
        self.recordedAt = recordedAt
        self.language = language
        self.sharingMode = sharingMode
        self.tags = tags
    }
}

public enum IconState: Equatable, Sendable { case idle, recording, uploading }

public enum RecordingState: Equatable {
    case idle
    case configuring(startedAt: Date)
    case recording(startedAt: Date, configuration: RecordingConfiguration)
    case uploading(RecordingConfiguration)
    case failed(RecordingConfiguration, message: String)
}

public enum RecordingEvent {
    case iconClicked
    case configurationConfirmed(RecordingConfiguration)
    case configurationCancelled
    case uploadSucceeded
    case uploadFailed(String)
    case retryRequested
    case failureDismissed
}

public enum RecordingEffect: Equatable {
    case startCapture
    case stopCapture
    case discardFile
    case deleteFile
    case moveFileToSaveFolder
    case upload(RecordingConfiguration)
    case showConfigurationWindow(startedAt: Date)
    case focusConfigurationWindow
    case setIcon(IconState)
    case setESP32Recording(Bool)
}

/// Pure state machine: it decides, the controller acts.
public final class RecordingFlow {
    public private(set) var state: RecordingState = .idle
    private let now: () -> Date

    public init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    public func handle(_ event: RecordingEvent) -> [RecordingEffect] {
        switch (state, event) {
        case (.idle, .iconClicked):
            let startedAt = now()
            state = .configuring(startedAt: startedAt)
            return [.startCapture, .setIcon(.recording), .setESP32Recording(true),
                    .showConfigurationWindow(startedAt: startedAt)]

        case (.configuring, .iconClicked):
            return [.focusConfigurationWindow]

        case let (.configuring(startedAt), .configurationConfirmed(configuration)):
            state = .recording(startedAt: startedAt, configuration: configuration)
            return []

        case (.configuring, .configurationCancelled):
            state = .idle
            return [.stopCapture, .discardFile, .setESP32Recording(false), .setIcon(.idle)]

        case let (.recording(_, configuration), .iconClicked):
            state = .uploading(configuration)
            return [.stopCapture, .setESP32Recording(false), .setIcon(.uploading), .upload(configuration)]

        case (.uploading, .uploadSucceeded):
            state = .idle
            return [.deleteFile, .setIcon(.idle)]

        case let (.uploading(configuration), .uploadFailed(message)):
            state = .failed(configuration, message: message)
            return [.setIcon(.idle)]

        case let (.failed(configuration, _), .retryRequested):
            state = .uploading(configuration)
            return [.setIcon(.uploading), .upload(configuration)]

        case (.failed, .failureDismissed):
            state = .idle
            return [.moveFileToSaveFolder, .setIcon(.idle)]

        default:
            return []
        }
    }
}
```

- [ ] **Step 4: Lancer le test et vérifier qu'il passe**

Run: `swift test --filter RecordingFlow`
Expected: 8 tests, 0 échec.

- [ ] **Step 5: Commit**

```bash
git add Sources/RecorderCore/RecordingFlow.swift Tests/RecorderCoreTests/RecordingFlowTests.swift
git commit -m "feat(core): recording state machine"
```

---

### Task 8: `ESP32Display`

**Files:**
- Create: `Sources/RecorderCore/ESP32Display.swift`
- Test: `Tests/RecorderCoreTests/ESP32DisplayTests.swift`

**Interfaces:**
- Consumes: `HTTPSession` (Task 3).
- Produces: `struct ESP32Display { init(host: String?, session: HTTPSession = URLSession.shared); func setRecording(_ isRecording: Bool) async }`.

- [ ] **Step 1: Écrire le test qui échoue**

Créer `Tests/RecorderCoreTests/ESP32DisplayTests.swift` :

```swift
import Foundation
import Testing
@testable import RecorderCore

@Test func recordingTurnsTheDisplayRedAndStoppingTurnsItBlack() async throws {
    let session = FakeSession()
    let display = ESP32Display(host: "10.93.1.238", session: session)

    await display.setRecording(true)
    await display.setRecording(false)

    #expect(session.calls.count == 2)
    let first = try #require(session.calls.first?.request)
    #expect(first.url?.absoluteString == "http://10.93.1.238/display")
    #expect(first.httpMethod == "POST")
    #expect(first.value(forHTTPHeaderField: "Content-Type") == "application/json")

    let redBody = try #require(first.httpBody)
    let red = try #require(try JSONSerialization.jsonObject(with: redBody) as? [String: String])
    #expect(red["bg"] == "FF0000")

    let blackBody = try #require(session.calls.last?.request.httpBody)
    let black = try #require(try JSONSerialization.jsonObject(with: blackBody) as? [String: String])
    #expect(black["bg"] == "000000")
}

@Test func noHostMeansNoRequest() async {
    let session = FakeSession()
    await ESP32Display(host: nil, session: session).setRecording(true)
    #expect(session.calls.isEmpty)
}
```

- [ ] **Step 2: Lancer le test et vérifier qu'il échoue**

Run: `swift test --filter ESP32`
Expected: `cannot find 'ESP32Display' in scope`.

- [ ] **Step 3: Écrire l'implémentation minimale**

Créer `Sources/RecorderCore/ESP32Display.swift` :

```swift
import Foundation

/// Optional companion screen: red while recording, black otherwise.
/// Every failure is swallowed — a missing gadget must never block a meeting.
public struct ESP32Display {
    private let host: String?
    private let session: HTTPSession

    public init(host: String?, session: HTTPSession = URLSession.shared) {
        self.host = host
        self.session = session
    }

    public func setRecording(_ isRecording: Bool) async {
        guard let host, !host.isEmpty,
              let url = URL(string: "http://\(host)/display") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 2
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "bg": isRecording ? "FF0000" : "000000",
            "text": "",
            "textColor": "white"
        ])

        _ = try? await session.data(for: request)
    }
}
```

- [ ] **Step 4: Lancer toute la suite**

Run: `swift test`
Expected: tous les tests passent.

- [ ] **Step 5: Commit**

```bash
git add Sources/RecorderCore/ESP32Display.swift Tests/RecorderCoreTests/ESP32DisplayTests.swift
git commit -m "feat(core): optional ESP32 recording light"
```

---

### Task 9: Projet Xcode et coquille de barre de menu

**Files:**
- Create: `Config/Info.plist`
- Create: `Config/WhiteboardRecorder.entitlements`
- Create: `WhiteboardRecorder.xcodeproj/project.pbxproj`
- Create: `WhiteboardRecorder/AppDelegate.swift`
- Create: `WhiteboardRecorder/StatusIcon.swift`
- Create: `WhiteboardRecorder/MenuBarController.swift`
- Create: `run.sh`, `build-release.sh`

**Interfaces:**
- Consumes: `IconState` (Task 7).
- Produces: `enum StatusIcon { static func image(for state: IconState) -> NSImage }`, `final class MenuBarController { init() }`.

Le projet utilise des **groupes de fichiers synchronisés** (`PBXFileSystemSynchronizedRootGroup`,
`objectVersion = 77`) : tout fichier déposé dans `WhiteboardRecorder/` ou
`Sources/RecorderCore/` entre automatiquement dans la cible. Aucune tâche ultérieure
n'a donc à toucher au `project.pbxproj`.

- [ ] **Step 1: Créer `Config/Info.plist`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>fr</string>
	<key>CFBundleExecutable</key>
	<string>$(EXECUTABLE_NAME)</string>
	<key>CFBundleIdentifier</key>
	<string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$(PRODUCT_NAME)</string>
	<key>CFBundleDisplayName</key>
	<string>Whiteboard Recorder</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$(MARKETING_VERSION)</string>
	<key>CFBundleVersion</key>
	<string>$(CURRENT_PROJECT_VERSION)</string>
	<key>LSMinimumSystemVersion</key>
	<string>$(MACOSX_DEPLOYMENT_TARGET)</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>NSMicrophoneUsageDescription</key>
	<string>Whiteboard Recorder enregistre ton micro pendant les réunions.</string>
	<key>NSAudioCaptureUsageDescription</key>
	<string>Whiteboard Recorder capte le son des autres applications pour enregistrer les participants distants.</string>
</dict>
</plist>
```

- [ ] **Step 2: Créer `Config/WhiteboardRecorder.entitlements`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<true/>
	<key>com.apple.security.device.audio-input</key>
	<true/>
	<key>com.apple.security.network.client</key>
	<true/>
	<key>com.apple.security.files.user-selected.read-write</key>
	<true/>
	<key>com.apple.security.files.downloads.read-write</key>
	<true/>
</dict>
</plist>
```

- [ ] **Step 3: Créer `WhiteboardRecorder.xcodeproj/project.pbxproj`**

```
// !$*UTF8*$!
{
	archiveVersion = 1;
	classes = {
	};
	objectVersion = 77;
	objects = {

/* Begin PBXFileReference section */
		1A0000000000000000000001 /* WhiteboardRecorder.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = WhiteboardRecorder.app; sourceTree = BUILT_PRODUCTS_DIR; };
/* End PBXFileReference section */

/* Begin PBXFileSystemSynchronizedRootGroup section */
		1A0000000000000000000002 /* WhiteboardRecorder */ = {isa = PBXFileSystemSynchronizedRootGroup; path = WhiteboardRecorder; sourceTree = "<group>"; };
		1A0000000000000000000003 /* RecorderCore */ = {isa = PBXFileSystemSynchronizedRootGroup; name = RecorderCore; path = Sources/RecorderCore; sourceTree = "<group>"; };
/* End PBXFileSystemSynchronizedRootGroup section */

/* Begin PBXFrameworksBuildPhase section */
		1A0000000000000000000007 /* Frameworks */ = {
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
		1A0000000000000000000004 = {
			isa = PBXGroup;
			children = (
				1A0000000000000000000002 /* WhiteboardRecorder */,
				1A0000000000000000000003 /* RecorderCore */,
				1A0000000000000000000005 /* Products */,
			);
			sourceTree = "<group>";
		};
		1A0000000000000000000005 /* Products */ = {
			isa = PBXGroup;
			children = (
				1A0000000000000000000001 /* WhiteboardRecorder.app */,
			);
			name = Products;
			sourceTree = "<group>";
		};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		1A0000000000000000000009 /* WhiteboardRecorder */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = 1A000000000000000000000C /* Build configuration list for PBXNativeTarget "WhiteboardRecorder" */;
			buildPhases = (
				1A0000000000000000000006 /* Sources */,
				1A0000000000000000000007 /* Frameworks */,
				1A0000000000000000000008 /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
			);
			fileSystemSynchronizedGroups = (
				1A0000000000000000000002 /* WhiteboardRecorder */,
				1A0000000000000000000003 /* RecorderCore */,
			);
			name = WhiteboardRecorder;
			productName = WhiteboardRecorder;
			productReference = 1A0000000000000000000001 /* WhiteboardRecorder.app */;
			productType = "com.apple.product-type.application";
		};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		1A000000000000000000000A /* Project object */ = {
			isa = PBXProject;
			attributes = {
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 2600;
				LastUpgradeCheck = 2600;
				TargetAttributes = {
					1A0000000000000000000009 = {
						CreatedOnToolsVersion = 26.0;
					};
				};
			};
			buildConfigurationList = 1A000000000000000000000B /* Build configuration list for PBXProject "WhiteboardRecorder" */;
			developmentRegion = fr;
			hasScannedForEncodings = 0;
			knownRegions = (
				fr,
				Base,
			);
			mainGroup = 1A0000000000000000000004;
			minimizedProjectReferenceProxies = 1;
			productRefGroup = 1A0000000000000000000005 /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				1A0000000000000000000009 /* WhiteboardRecorder */,
			);
		};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
		1A0000000000000000000008 /* Resources */ = {
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
		1A0000000000000000000006 /* Sources */ = {
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXSourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
		1A000000000000000000000D /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				COPY_PHASE_STRIP = NO;
				ENABLE_HARDENED_RUNTIME = YES;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				GCC_OPTIMIZATION_LEVEL = 0;
				MACOSX_DEPLOYMENT_TARGET = 14.4;
				ONLY_ACTIVE_ARCH = YES;
				SDKROOT = macosx;
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;
				SWIFT_OPTIMIZATION_LEVEL = "-Onone";
				SWIFT_VERSION = 5.0;
			};
			name = Debug;
		};
		1A000000000000000000000E /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				COPY_PHASE_STRIP = NO;
				ENABLE_HARDENED_RUNTIME = YES;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				MACOSX_DEPLOYMENT_TARGET = 14.4;
				SDKROOT = macosx;
				SWIFT_COMPILATION_MODE = wholemodule;
				SWIFT_VERSION = 5.0;
			};
			name = Release;
		};
		1A000000000000000000000F /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				CODE_SIGN_ENTITLEMENTS = Config/WhiteboardRecorder.entitlements;
				CODE_SIGN_STYLE = Automatic;
				COMBINE_HIDPI_IMAGES = YES;
				CURRENT_PROJECT_VERSION = 1;
				DEVELOPMENT_TEAM = 99C5GU2775;
				ENABLE_PREVIEWS = YES;
				INFOPLIST_FILE = Config/Info.plist;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/../Frameworks",
				);
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = "com.kepochan.whiteboard-recorder";
				PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_VERSION = 5.0;
			};
			name = Debug;
		};
		1A0000000000000000000010 /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				CODE_SIGN_ENTITLEMENTS = Config/WhiteboardRecorder.entitlements;
				CODE_SIGN_STYLE = Automatic;
				COMBINE_HIDPI_IMAGES = YES;
				CURRENT_PROJECT_VERSION = 1;
				DEVELOPMENT_TEAM = 99C5GU2775;
				ENABLE_PREVIEWS = YES;
				INFOPLIST_FILE = Config/Info.plist;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/../Frameworks",
				);
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = "com.kepochan.whiteboard-recorder";
				PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_VERSION = 5.0;
			};
			name = Release;
		};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		1A000000000000000000000B /* Build configuration list for PBXProject "WhiteboardRecorder" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				1A000000000000000000000D /* Debug */,
				1A000000000000000000000E /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		};
		1A000000000000000000000C /* Build configuration list for PBXNativeTarget "WhiteboardRecorder" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				1A000000000000000000000F /* Debug */,
				1A0000000000000000000010 /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		};
/* End XCConfigurationList section */
	};
	rootObject = 1A000000000000000000000A /* Project object */;
}
```

- [ ] **Step 4: Vérifier que le projet s'ouvre**

Run: `xcodebuild -project WhiteboardRecorder.xcodeproj -list`
Expected: la cible `WhiteboardRecorder` et les configurations `Debug` / `Release` sont listées.

Si cette commande échoue sur une erreur de parsing, **ne pas bricoler le fichier** :
repartir d'une copie de `../meeting-agent-client-mac/MeetingAgent.xcodeproj/project.pbxproj`,
y remplacer les noms et identifiants, et déclarer chaque fichier source à la main.
Le reste du plan ne change pas.

- [ ] **Step 5: Créer `WhiteboardRecorder/StatusIcon.swift`**

```swift
import AppKit

enum StatusIcon {
    static func image(for state: IconState) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()

        let diameter: CGFloat = 14
        let origin = (size.width - diameter) / 2
        let rect = NSRect(x: origin, y: origin, width: diameter, height: diameter)
        let path = NSBezierPath(ovalIn: rect)

        switch state {
        case .idle:
            NSColor.black.setStroke()
            path.lineWidth = 1.5
            path.stroke()
        case .recording:
            NSColor.black.setFill()
            path.fill()
        case .uploading:
            NSColor.black.setStroke()
            path.lineWidth = 1.5
            path.stroke()
            let dot = rect.insetBy(dx: 4.5, dy: 4.5)
            NSColor.black.setFill()
            NSBezierPath(ovalIn: dot).fill()
        }

        image.unlockFocus()
        // Template images follow the menu bar appearance, light or dark.
        image.isTemplate = true
        return image
    }
}
```

- [ ] **Step 6: Créer `WhiteboardRecorder/MenuBarController.swift`**

```swift
import AppKit

final class MenuBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let contextMenu = NSMenu()

    override init() {
        super.init()
        setIcon(.idle)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(handleClick)
        statusItem.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
        buildMenu()
    }

    func setIcon(_ state: IconState) {
        statusItem.button?.image = StatusIcon.image(for: state)
    }

    private func buildMenu() {
        let preferences = NSMenuItem(title: "Préférences…", action: #selector(showPreferences), keyEquivalent: ",")
        preferences.target = self
        contextMenu.addItem(preferences)
        contextMenu.addItem(.separator())
        let quit = NSMenuItem(title: "Quitter", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        contextMenu.addItem(quit)
    }

    @objc private func handleClick() {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseDown
            || (event?.type == .leftMouseDown && event?.modifierFlags.contains(.control) == true)

        if isRightClick {
            guard let button = statusItem.button else { return }
            contextMenu.popUp(positioning: nil,
                              at: NSPoint(x: button.bounds.midX, y: button.bounds.minY),
                              in: button)
            return
        }
        handleLeftClick()
    }

    /// Wired to the recording flow in Task 13.
    private func handleLeftClick() {
        NSLog("left click")
    }

    @objc private func showPreferences() {
        NSLog("preferences")
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
```

- [ ] **Step 7: Créer `WhiteboardRecorder/AppDelegate.swift`**

```swift
import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBarController = MenuBarController()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
```

- [ ] **Step 8: Créer `run.sh`**

```bash
#!/bin/bash
# Compile en debug et relance l'app.
set -e
cd "$(dirname "$0")"

pkill -f "WhiteboardRecorder" 2>/dev/null || true

xcodebuild -project WhiteboardRecorder.xcodeproj \
           -target WhiteboardRecorder \
           -configuration Debug \
           -derivedDataPath build \
           build

open build/Build/Products/Debug/WhiteboardRecorder.app
echo "Lancé. Cherche le cercle dans la barre de menu."
```

- [ ] **Step 9: Créer `build-release.sh`**

```bash
#!/bin/bash
# Compile en release, dépose l'app à la racine et la zippe pour le dépôt.
set -e
cd "$(dirname "$0")"

xcodebuild -project WhiteboardRecorder.xcodeproj \
           -target WhiteboardRecorder \
           -configuration Release \
           -derivedDataPath build \
           build

rm -rf WhiteboardRecorder.app WhiteboardRecorder.zip
cp -R build/Build/Products/Release/WhiteboardRecorder.app .
ditto -c -k --keepParent WhiteboardRecorder.app WhiteboardRecorder.zip

echo "WhiteboardRecorder.app et WhiteboardRecorder.zip sont prêts."
echo "Installation : glisse WhiteboardRecorder.app dans /Applications."
```

Aucun de ces deux scripts ne contient de clé API, contrairement à ceux de l'ancienne app.

- [ ] **Step 10: Compiler et lancer**

Run: `chmod +x run.sh build-release.sh && ./run.sh`
Expected: la compilation réussit, un cercle vide apparaît dans la barre de menu, le
clic droit ouvre un menu avec Préférences et Quitter, `Quitter` ferme l'app.

- [ ] **Step 11: Commit**

```bash
git add Config WhiteboardRecorder WhiteboardRecorder.xcodeproj run.sh build-release.sh
git commit -m "feat(app): menu bar shell and Xcode project"
```

---

### Task 10: Spike — le tap CoreAudio passe-t-il le bac à sable ?

Tâche **jetable** : elle produit une décision, pas du code à garder. Son seul
livrable durable est l'état final de `Config/WhiteboardRecorder.entitlements`.

**Files:**
- Create (temporaire) : `WhiteboardRecorder/TapSpike.swift`
- Modify (peut-être) : `Config/WhiteboardRecorder.entitlements`

- [ ] **Step 1: Écrire la sonde**

Créer `WhiteboardRecorder/TapSpike.swift` :

```swift
import CoreAudio
import AudioToolbox
import Foundation

enum TapSpike {
    static func run() {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "Whiteboard Recorder Spike"
        description.isPrivate = true

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &tapID)
        NSLog("SPIKE AudioHardwareCreateProcessTap status=\(status) tapID=\(tapID)")

        guard status == noErr else {
            NSLog("SPIKE échec : le tap n'a pas pu être créé sous ces entitlements")
            return
        }
        NSLog("SPIKE succès : tap créé")
        AudioHardwareDestroyProcessTap(tapID)
    }
}
```

- [ ] **Step 2: Appeler la sonde au lancement**

Dans `AppDelegate.applicationDidFinishLaunching`, ajouter temporairement `TapSpike.run()`.

- [ ] **Step 3: Lancer, sandbox activé**

Run: `./run.sh` puis `log stream --predicate 'eventMessage CONTAINS "SPIKE"' --info` dans un autre terminal, ou consulter la Console.
Expected: soit `status=0` et un tapID non nul, soit un code d'erreur.

Observer aussi si macOS affiche une demande de permission d'enregistrement audio.

- [ ] **Step 4: Trancher**

- **Succès** → ne rien changer aux entitlements. Noter le résultat dans le README.
- **Échec** → passer `com.apple.security.app-sandbox` à `<false/>` dans
  `Config/WhiteboardRecorder.entitlements`, relancer, vérifier que le tap se crée.
  Sans distribution App Store, renoncer au bac à sable ne coûte rien. Noter la raison
  dans le README.

- [ ] **Step 5: Retirer la sonde**

Supprimer `WhiteboardRecorder/TapSpike.swift` et son appel dans `AppDelegate`.

- [ ] **Step 6: Commit**

```bash
git add Config/WhiteboardRecorder.entitlements WhiteboardRecorder/AppDelegate.swift
git commit -m "chore: settle sandbox entitlements for CoreAudio process taps"
```

---

### Task 11: `CoreAudioCapture`

**Files:**
- Create: `Sources/RecorderCore/AudioCapture.swift`
- Create: `Sources/RecorderCore/CoreAudioCapture.swift`
- Test: check-list manuelle (voir Step 5) — cette tâche n'a pas de test unitaire

**Interfaces:**
- Consumes: rien.
- Produces:
  - `protocol AudioCapture: AnyObject { var isSystemAudioAvailable: Bool { get }; func start() throws -> Date; func stop() throws -> URL }`
  - `enum CaptureError: Error { case aggregateDeviceFailed(OSStatus); case noInputDevice; case notRecording }`
  - `final class CoreAudioCapture: AudioCapture`
  - `enum RecordingStorage { static var directory: URL { get } }`

- [ ] **Step 1: Créer `Sources/RecorderCore/AudioCapture.swift`**

```swift
import Foundation

public enum CaptureError: Error, Equatable {
    case noInputDevice
    case aggregateDeviceFailed(OSStatus)
    case notRecording
}

public protocol AudioCapture: AnyObject {
    /// False when the system-audio tap could not be created: the microphone is
    /// still recorded, and the UI warns that remote participants are missing.
    var isSystemAudioAvailable: Bool { get }
    /// Returns the instant capture actually started — this is `recordedAt`.
    func start() throws -> Date
    /// Returns the finished .m4a file.
    func stop() throws -> URL
}

public enum RecordingStorage {
    public static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhiteboardRecorder/Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    public static func newFileURL() -> URL {
        directory.appendingPathComponent("\(UUID().uuidString).m4a")
    }
}
```

- [ ] **Step 2: Créer `Sources/RecorderCore/CoreAudioCapture.swift`**

```swift
import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// Microphone and system audio captured through a single private aggregate
/// device, so both sources share one clock and need no drift correction.
public final class CoreAudioCapture: AudioCapture {
    public private(set) var isSystemAudioAvailable = false

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var file: AVAudioFile?
    private var format: AVAudioFormat?
    private var outputURL: URL?
    private let writerQueue = DispatchQueue(label: "wbr.audio.writer")

    public init() {}

    public func start() throws -> Date {
        guard let inputUID = Self.defaultInputDeviceUID() else { throw CaptureError.noInputDevice }

        let tapUID = createTap()
        isSystemAudioAvailable = tapUID != nil

        aggregateID = try createAggregate(inputUID: inputUID, tapUID: tapUID)

        let sampleRate = Self.sampleRate(of: aggregateID)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: sampleRate,
                                   channels: 1,
                                   interleaved: false)!
        self.format = format

        let url = RecordingStorage.newFileURL()
        outputURL = url
        file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000
        ])

        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) {
            [weak self] _, inputData, _, _, _ in
            self?.mixAndQueue(inputData)
        }
        guard status == noErr, let procID else { throw CaptureError.aggregateDeviceFailed(status) }
        ioProcID = procID

        let startStatus = AudioDeviceStart(aggregateID, procID)
        guard startStatus == noErr else { throw CaptureError.aggregateDeviceFailed(startStatus) }

        return Date()
    }

    public func stop() throws -> URL {
        guard let url = outputURL else { throw CaptureError.notRecording }

        if let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil

        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }

        // Let every queued buffer reach the encoder before closing the file.
        writerQueue.sync {}
        file = nil
        outputURL = nil
        return url
    }

    // MARK: - Mixing

    /// Sums every input channel of every buffer into one mono stream. The
    /// aggregate exposes the microphone buffers first, then the tap's.
    private func mixAndQueue(_ inputData: UnsafePointer<AudioBufferList>) {
        guard let format else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        guard let firstBuffer = buffers.first, firstBuffer.mDataByteSize > 0 else { return }

        let frameCount = Int(firstBuffer.mDataByteSize) / MemoryLayout<Float>.size
            / Int(max(firstBuffer.mNumberChannels, 1))
        guard frameCount > 0,
              let mixed = AVAudioPCMBuffer(pcmFormat: format,
                                           frameCapacity: AVAudioFrameCount(frameCount)) else { return }
        mixed.frameLength = AVAudioFrameCount(frameCount)
        guard let destination = mixed.floatChannelData?[0] else { return }
        destination.update(repeating: 0, count: frameCount)

        for buffer in buffers {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let channels = Int(max(buffer.mNumberChannels, 1))
            let available = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels
            let frames = min(frameCount, available)
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels {
                    sum += data[frame * channels + channel]
                }
                destination[frame] += sum / Float(channels)
            }
        }

        // Two sources summed can clip; clamp instead of distorting.
        for frame in 0..<frameCount {
            destination[frame] = max(-1, min(1, destination[frame]))
        }

        writerQueue.async { [weak self] in
            try? self?.file?.write(from: mixed)
        }
    }

    // MARK: - CoreAudio plumbing

    private func createTap() -> String? {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "Whiteboard Recorder"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var id = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(description, &id) == noErr else { return nil }
        tapID = id
        return description.uuid.uuidString
    }

    private func createAggregate(inputUID: String, tapUID: String?) throws -> AudioObjectID {
        var settings: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Whiteboard Recorder",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: inputUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: inputUID]]
        ]
        if let tapUID {
            settings[kAudioAggregateDeviceTapListKey] = [[
                kAudioSubTapUIDKey: tapUID,
                kAudioSubTapDriftCompensationKey: true
            ]]
        }

        var id = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(settings as CFDictionary, &id)
        guard status == noErr else { throw CaptureError.aggregateDeviceFailed(status) }
        return id
    }

    private static func defaultInputDeviceUID() -> String? {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &deviceID) == noErr else { return nil }

        var uid: CFString?
        var uidSize = UInt32(MemoryLayout<CFString?>.size)
        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, &uid) == noErr else { return nil }
        return uid as String?
    }

    private static func sampleRate(of device: AudioObjectID) -> Double {
        var rate: Double = 48_000
        var size = UInt32(MemoryLayout<Double>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate)
        return rate
    }
}
```

- [ ] **Step 3: Vérifier que le package compile toujours**

Run: `swift build && swift test`
Expected: compilation réussie, tous les tests passent.

Si `CATapDescription` ou `AudioHardwareCreateProcessTap` sont introuvables, vérifier
que `.macOS("14.4")` est bien la plateforme du package — ces symboles n'existent pas
avant 14.4.

- [ ] **Step 4: Brancher temporairement sur le clic gauche**

Dans `MenuBarController.handleLeftClick`, ajouter une bascule provisoire :

```swift
private let capture = CoreAudioCapture()
private var isCapturing = false

private func handleLeftClick() {
    do {
        if isCapturing {
            let url = try capture.stop()
            isCapturing = false
            setIcon(.idle)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            _ = try capture.start()
            isCapturing = true
            setIcon(.recording)
            NSLog("système capté : \(capture.isSystemAudioAvailable)")
        }
    } catch {
        NSLog("capture error: \(error)")
    }
}
```

- [ ] **Step 5: Check-list manuelle**

Run: `./run.sh`

1. Lancer une vidéo YouTube et parler dans le micro.
2. Clic gauche pour démarrer, laisser tourner vingt secondes, clic gauche pour arrêter.
3. Le Finder s'ouvre sur le `.m4a`. L'écouter : **la voix et la vidéo doivent toutes
   deux être audibles**, sans écho ni accélération.
4. Vérifier dans la Console que `système capté : true`.
5. Vérifier la taille : environ 150 à 200 Ko pour vingt secondes.

Si seule une des deux sources est audible, l'hypothèse sur l'ordre des buffers est
fausse : journaliser `buffers.count` et `mNumberChannels` de chaque buffer dans
`mixAndQueue`, et corriger l'indexation.

Si le son est accéléré ou ralenti, c'est la fréquence d'échantillonnage : comparer
`Self.sampleRate(of: aggregateID)` avec la fréquence réelle du micro.

Si `AVAudioFile(forWriting:settings:)` refuse les réglages AAC, appliquer le repli
prévu par la spec : écrire un `.caf` non compressé pendant la capture, puis le
convertir en `.m4a` dans `stop()` avec `AVAssetExportSession` et le préréglage
`AVAssetExportPresetAppleM4A`, et ne rendre l'URL qu'une fois l'export terminé.

- [ ] **Step 6: Commit**

```bash
git add Sources/RecorderCore WhiteboardRecorder/MenuBarController.swift
git commit -m "feat(core): capture microphone and system audio into one file"
```

---

### Task 12: Fenêtre de configuration

**Files:**
- Create: `WhiteboardRecorder/ConfigurationModel.swift`
- Create: `WhiteboardRecorder/ConfigurationView.swift`
- Create: `WhiteboardRecorder/ConfigurationWindowController.swift`

**Interfaces:**
- Consumes: `Workspace`, `Tag`, `WhiteboardClient`, `Preferences`, `RecordingConfiguration` (Tasks 3, 4, 5, 7).
- Produces: `final class ConfigurationWindowController: NSWindowController { init(startedAt: Date, preferences: Preferences, client: WhiteboardClient, systemAudioAvailable: Bool, onConfirm: @escaping (RecordingConfiguration) -> Void, onCancel: @escaping () -> Void) }`.

Cette tâche n'a pas de test unitaire : la validation qu'elle applique (titre non vide,
date pas dans le futur) est déjà couverte côté client dans la Task 4. On vérifie à
l'œil.

- [ ] **Step 1: Créer `WhiteboardRecorder/ConfigurationModel.swift`**

```swift
import Foundation
import SwiftUI

@MainActor
final class ConfigurationModel: ObservableObject {
    @Published var workspaces: [Workspace] = []
    @Published var workspaceID: String = ""
    @Published var title: String = ""
    @Published var recordedAt: Date
    @Published var language: String
    @Published var sharingMode: String
    @Published var availableTags: [Tag] = []
    @Published var selectedTags: [Tag] = []
    @Published var tagQuery: String = ""
    @Published var loadingError: String?

    let systemAudioAvailable: Bool
    private let preferences: Preferences
    private let client: WhiteboardClient

    init(startedAt: Date, preferences: Preferences, client: WhiteboardClient, systemAudioAvailable: Bool) {
        self.recordedAt = startedAt
        self.preferences = preferences
        self.client = client
        self.systemAudioAvailable = systemAudioAvailable
        self.language = preferences.lastLanguage
        self.sharingMode = preferences.lastSharingMode
        self.workspaceID = preferences.effectiveWorkspaceID ?? ""
    }

    var canConfirm: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !workspaceID.isEmpty
            && recordedAt <= Date()
    }

    /// Existing tags only — the app never invents one.
    var tagSuggestions: [Tag] {
        let query = tagQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return availableTags
            .filter { tag in
                !selectedTags.contains(tag)
                    && (query.isEmpty || tag.label.lowercased().contains(query))
            }
            .prefix(6)
            .map { $0 }
    }

    func load() async {
        do {
            let workspaces = try await client.listWorkspaces()
            self.workspaces = workspaces
            if !workspaces.contains(where: { $0.id == workspaceID }) {
                workspaceID = workspaces.first?.id ?? ""
            }
            await loadTags()
        } catch let error as APIError {
            loadingError = error.message
        } catch {
            loadingError = error.localizedDescription
        }
    }

    func loadTags() async {
        guard !workspaceID.isEmpty else { return }
        selectedTags = []
        do {
            availableTags = try await client.listTags(workspaceID: workspaceID)
                .sorted { ($0.count ?? 0) > ($1.count ?? 0) }
        } catch {
            // A key scoped to recordings only may be refused here; the field
            // simply stays empty rather than blocking the recording.
            availableTags = []
        }
    }

    func select(_ tag: Tag) {
        guard !selectedTags.contains(tag) else { return }
        selectedTags.append(tag)
        tagQuery = ""
    }

    func remove(_ tag: Tag) {
        selectedTags.removeAll { $0 == tag }
    }

    func makeConfiguration() -> RecordingConfiguration {
        preferences.lastWorkspaceID = workspaceID
        preferences.lastLanguage = language
        preferences.lastSharingMode = sharingMode
        return RecordingConfiguration(
            workspaceID: workspaceID,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            recordedAt: recordedAt,
            language: language,
            sharingMode: sharingMode,
            tags: selectedTags
        )
    }
}
```

- [ ] **Step 2: Créer `WhiteboardRecorder/ConfigurationView.swift`**

```swift
import SwiftUI

struct ConfigurationView: View {
    @ObservedObject var model: ConfigurationModel
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Enregistrement en cours").font(.headline)

            if !model.systemAudioAvailable {
                Label("Audio système non capté : seul le micro est enregistré.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let error = model.loadingError {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            Form {
                Picker("Workspace", selection: $model.workspaceID) {
                    ForEach(model.workspaces) { workspace in
                        Text(workspace.name).tag(workspace.id)
                    }
                }
                .onChange(of: model.workspaceID) { _, _ in
                    Task { await model.loadTags() }
                }

                TextField("Titre", text: $model.title)

                DatePicker("Date de réunion", selection: $model.recordedAt,
                           in: ...Date(), displayedComponents: [.date, .hourAndMinute])

                Picker("Langue", selection: $model.language) {
                    ForEach(Preferences.languages, id: \.self) { Text($0).tag($0) }
                }

                Picker("Visibilité", selection: $model.sharingMode) {
                    ForEach(Preferences.sharingModes, id: \.self) { Text($0).tag($0) }
                }
            }

            tagsSection

            HStack {
                Button("Annuler", role: .destructive, action: onCancel)
                Spacer()
                Button("OK", action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canConfirm)
            }
        }
        .padding(20)
        .frame(width: 460)
        .task { await model.load() }
    }

    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tags").font(.subheadline)

            if !model.selectedTags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.selectedTags, id: \.label) { tag in
                            Button {
                                model.remove(tag)
                            } label: {
                                Text("\(tag.label) ✕")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }

            TextField("Filtrer les tags existants…", text: $model.tagQuery)
                .onSubmit {
                    if let first = model.tagSuggestions.first { model.select(first) }
                }

            if !model.tagSuggestions.isEmpty {
                HStack(spacing: 6) {
                    ForEach(model.tagSuggestions, id: \.label) { tag in
                        Button(tag.label) { model.select(tag) }
                            .buttonStyle(.link)
                    }
                }
            }

            Text("Le tag « meeting » est ajouté automatiquement.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
```

- [ ] **Step 3: Créer `WhiteboardRecorder/ConfigurationWindowController.swift`**

```swift
import AppKit
import SwiftUI

final class ConfigurationWindowController: NSWindowController {
    private let model: ConfigurationModel

    init(startedAt: Date,
         preferences: Preferences,
         client: WhiteboardClient,
         systemAudioAvailable: Bool,
         onConfirm: @escaping (RecordingConfiguration) -> Void,
         onCancel: @escaping () -> Void) {
        let model = ConfigurationModel(startedAt: startedAt, preferences: preferences,
                                       client: client, systemAudioAvailable: systemAudioAvailable)
        self.model = model

        // No close button: OK and Annuler are the only ways out.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 460),
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        window.title = "Whiteboard Recorder"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        window.contentView = NSHostingView(rootView: ConfigurationView(
            model: model,
            onConfirm: { [weak self] in
                onConfirm(model.makeConfiguration())
                self?.close()
            },
            onCancel: { [weak self] in
                onCancel()
                self?.close()
            }
        ))
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func focus() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
```

- [ ] **Step 4: Vérifier à l'œil**

Cette fenêtre n'est pas encore appelée par le clic ; la Task 13 la branche. Pour la
voir maintenant, l'ouvrir depuis `applicationDidFinishLaunching` avec un client
construit sur la clé de développement, puis retirer ce code temporaire.

Run: `./run.sh`
Expected: la liste des workspaces se remplit, les tags du workspace apparaissent en
suggestions, OK reste grisé tant que le titre est vide, la date refuse le futur.

- [ ] **Step 5: Commit**

```bash
git add WhiteboardRecorder
git commit -m "feat(app): pre-recording configuration window"
```

---

### Task 13: Câbler le flux dans `MenuBarController`

**Files:**
- Modify: `WhiteboardRecorder/MenuBarController.swift`

**Interfaces:**
- Consumes: tout ce qui précède.
- Produces: rien de nouveau.

- [ ] **Step 1: Réécrire `MenuBarController`**

```swift
import AppKit
import AVFoundation

final class MenuBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let contextMenu = NSMenu()

    private let preferences = Preferences()
    private let keychain = KeychainStore()
    private let capture: AudioCapture = CoreAudioCapture()
    private let flow = RecordingFlow()

    private var configurationWindow: ConfigurationWindowController?
    private var currentFileURL: URL?
    private var startedAt: Date?

    private var client: WhiteboardClient {
        WhiteboardClient(baseURL: preferences.apiBaseURL, apiKey: { [keychain] in keychain.read() })
    }

    override init() {
        super.init()
        setIcon(.idle)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(handleClick)
        statusItem.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
        buildMenu()
    }

    // MARK: - Menu

    private func buildMenu() {
        let preferencesItem = NSMenuItem(title: "Préférences…", action: #selector(showPreferences), keyEquivalent: ",")
        preferencesItem.target = self
        contextMenu.addItem(preferencesItem)
        contextMenu.addItem(.separator())
        let quit = NSMenuItem(title: "Quitter", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        contextMenu.addItem(quit)
    }

    @objc private func handleClick() {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseDown
            || (event?.type == .leftMouseDown && event?.modifierFlags.contains(.control) == true)

        if isRightClick {
            showMenu()
            return
        }

        guard keychain.read() != nil else {
            showPreferences()
            return
        }

        requestMicrophoneAccess { [weak self] granted in
            guard let self else { return }
            guard granted else { self.showMicrophoneAlert(); return }
            self.apply(self.flow.handle(.iconClicked))
        }
    }

    private func showMenu() {
        guard let button = statusItem.button else { return }
        if case let .recording(startedAt, _) = flow.state {
            let elapsed = Int(Date().timeIntervalSince(startedAt))
            contextMenu.item(at: 0)?.title = String(format: "Enregistrement — %02d:%02d", elapsed / 60, elapsed % 60)
        }
        contextMenu.popUp(positioning: nil,
                          at: NSPoint(x: button.bounds.midX, y: button.bounds.minY),
                          in: button)
    }

    // MARK: - Effects

    private func apply(_ effects: [RecordingEffect]) {
        for effect in effects {
            switch effect {
            case .startCapture:
                do {
                    startedAt = try capture.start()
                } catch {
                    showAlert(title: "Enregistrement impossible", message: "\(error)")
                    apply(flow.handle(.configurationCancelled))
                }

            case .stopCapture:
                currentFileURL = try? capture.stop()

            case .discardFile, .deleteFile:
                if let url = currentFileURL { try? FileManager.default.removeItem(at: url) }
                currentFileURL = nil

            case .moveFileToSaveFolder:
                moveCurrentFileToSaveFolder()

            case let .upload(configuration):
                startUpload(configuration)

            case let .showConfigurationWindow(startedAt):
                showConfigurationWindow(startedAt: startedAt)

            case .focusConfigurationWindow:
                configurationWindow?.focus()

            case let .setIcon(state):
                setIcon(state)

            case let .setESP32Recording(isRecording):
                let display = ESP32Display(host: preferences.esp32Host)
                Task { await display.setRecording(isRecording) }
            }
        }
    }

    private func showConfigurationWindow(startedAt: Date) {
        configurationWindow?.close()
        let controller = ConfigurationWindowController(
            startedAt: startedAt,
            preferences: preferences,
            client: client,
            systemAudioAvailable: capture.isSystemAudioAvailable,
            onConfirm: { [weak self] configuration in
                guard let self else { return }
                self.apply(self.flow.handle(.configurationConfirmed(configuration)))
            },
            onCancel: { [weak self] in
                guard let self else { return }
                self.apply(self.flow.handle(.configurationCancelled))
            }
        )
        configurationWindow = controller
        controller.focus()
    }

    private func startUpload(_ configuration: RecordingConfiguration) {
        guard let fileURL = currentFileURL else {
            apply(flow.handle(.uploadFailed("Le fichier audio est introuvable.")))
            return
        }

        let recording = RecordingUpload(
            audioURL: fileURL,
            workspaceID: configuration.workspaceID,
            title: configuration.title,
            recordedAt: configuration.recordedAt,
            language: configuration.language,
            sharingMode: configuration.sharingMode,
            tags: configuration.tags
        )

        let client = self.client
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await client.upload(recording)
                self.apply(self.flow.handle(.uploadSucceeded))
            } catch let error as APIError {
                self.apply(self.flow.handle(.uploadFailed(error.message)))
                self.presentFailure(error.message)
            } catch {
                self.apply(self.flow.handle(.uploadFailed(error.localizedDescription)))
                self.presentFailure(error.localizedDescription)
            }
        }
    }

    // MARK: - Helpers

    private func setIcon(_ state: IconState) {
        statusItem.button?.image = StatusIcon.image(for: state)
    }

    private func requestMicrophoneAccess(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    private func showMicrophoneAlert() {
        let alert = NSAlert()
        alert.messageText = "Accès au micro requis"
        alert.informativeText = "Autorise Whiteboard Recorder dans Réglages Système → Confidentialité et sécurité → Microphone."
        alert.addButton(withTitle: "Ouvrir les réglages")
        alert.addButton(withTitle: "Annuler")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Replaced by the real window in Task 15.
    @objc private func showPreferences() {
        NSLog("preferences")
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
```

`presentFailure` et `moveCurrentFileToSaveFolder` arrivent dans la Task 14 : cette
tâche ne compile donc qu'une fois la Task 14 terminée. Les deux se suivent
immédiatement, et la vérification à l'écran a lieu à la fin de la Task 14.

- [ ] **Step 2: Commit**

```bash
git add WhiteboardRecorder/MenuBarController.swift
git commit -m "feat(app): drive capture and upload from the state machine"
```

---

### Task 14: Alerte d'échec et sauvegarde locale

**Files:**
- Create: `WhiteboardRecorder/FailureAlert.swift`
- Modify: `WhiteboardRecorder/MenuBarController.swift`

**Interfaces:**
- Consumes: `Preferences`, `RecordingFlow`.
- Produces: `enum FailureAlert { enum Choice { case retry, save, dismiss }; static func present(message: String, saveFolder: URL) -> Choice }` et, sur `MenuBarController`, `func presentFailure(_ message: String)` et `func moveCurrentFileToSaveFolder()`.

- [ ] **Step 1: Créer `WhiteboardRecorder/FailureAlert.swift`**

```swift
import AppKit

enum FailureAlert {
    enum Choice {
        case retry
        case save
        case dismiss
    }

    static func present(message: String, saveFolder: URL) -> Choice {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Envoi impossible"
        alert.informativeText = """
        \(message)

        L'enregistrement est conservé. Sans action de ta part, il sera déposé dans \
        \(saveFolder.lastPathComponent).
        """
        alert.addButton(withTitle: "Réessayer")
        alert.addButton(withTitle: "Enregistrer…")
        alert.addButton(withTitle: "Fermer")

        switch alert.runModal() {
        case .alertFirstButtonReturn: return .retry
        case .alertSecondButtonReturn: return .save
        default: return .dismiss
        }
    }
}
```

- [ ] **Step 2: Ajouter les deux méthodes à `MenuBarController`**

```swift
extension MenuBarController {
    func presentFailure(_ message: String) {
        switch FailureAlert.present(message: message, saveFolder: preferences.saveFolder) {
        case .retry:
            apply(flow.handle(.retryRequested))
        case .save:
            saveCurrentFileWithPanel()
            apply(flow.handle(.failureDismissed))
        case .dismiss:
            apply(flow.handle(.failureDismissed))
        }
    }

    /// Asks for a name, defaulting to the meeting title, in the configured folder.
    func saveCurrentFileWithPanel() {
        guard let source = currentFileURL else { return }
        let panel = NSSavePanel()
        panel.title = "Enregistrer l'audio de la réunion"
        panel.directoryURL = preferences.saveFolder
        panel.nameFieldStringValue = "\(suggestedFileName()).m4a"
        panel.allowedContentTypes = [.mpeg4Audio]

        guard panel.runModal() == .OK, let destination = panel.url else { return }
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.copyItem(at: source, to: destination)
    }

    func moveCurrentFileToSaveFolder() {
        guard let source = currentFileURL else { return }
        guard FileManager.default.fileExists(atPath: source.path) else {
            currentFileURL = nil
            return
        }
        let destination = uniqueURL(in: preferences.saveFolder, name: suggestedFileName())
        try? FileManager.default.moveItem(at: source, to: destination)
        currentFileURL = nil
    }

    private func suggestedFileName() -> String {
        let title: String
        if case let .failed(configuration, _) = flow.state, !configuration.title.isEmpty {
            title = configuration.title
        } else {
            title = "reunion"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let slug = title
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return "\(slug)-\(formatter.string(from: startedAt ?? Date()))"
    }

    private func uniqueURL(in folder: URL, name: String) -> URL {
        var candidate = folder.appendingPathComponent("\(name).m4a")
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(name)-\(index).m4a")
            index += 1
        }
        return candidate
    }
}
```

`currentFileURL`, `flow`, `preferences`, `startedAt` et `apply` doivent être
`internal` (pas `private`) pour que l'extension y accède.

Important : `presentFailure` est appelée **après** `flow.handle(.uploadFailed(...))`,
donc l'état est bien `.failed` quand `suggestedFileName()` lit le titre.

- [ ] **Step 3: Vérifier à la main**

Run: mettre une clé API volontairement fausse dans les Préférences, puis `./run.sh`
Expected: après un court enregistrement, l'alerte affiche « Clé API absente, invalide
ou révoquée. » ; **Réessayer** rejoue l'envoi, **Enregistrer…** ouvre le panneau sur
`~/Downloads` avec un nom pré-rempli, **Fermer** dépose le fichier dans `~/Downloads`.

- [ ] **Step 4: Commit**

```bash
git add WhiteboardRecorder
git commit -m "feat(app): failure alert with retry and local save"
```

---

### Task 15: Fenêtre Préférences

**Files:**
- Create: `WhiteboardRecorder/PreferencesModel.swift`
- Create: `WhiteboardRecorder/PreferencesView.swift`
- Create: `WhiteboardRecorder/PreferencesWindowController.swift`

**Interfaces:**
- Consumes: `Preferences`, `KeychainStore`, `WhiteboardClient`.
- Produces: `final class PreferencesWindowController: NSWindowController { init(preferences: Preferences, keychain: KeychainStore) }`.

- [ ] **Step 1: Créer `WhiteboardRecorder/PreferencesModel.swift`**

```swift
import Foundation
import SwiftUI

@MainActor
final class PreferencesModel: ObservableObject {
    @Published var apiKey: String
    @Published var apiBaseURL: String
    @Published var esp32Host: String
    @Published var saveFolder: URL
    @Published var workspaces: [Workspace] = []
    @Published var defaultWorkspaceID: String
    @Published var testResult: String?

    private let preferences: Preferences
    private let keychain: KeychainStore

    init(preferences: Preferences, keychain: KeychainStore) {
        self.preferences = preferences
        self.keychain = keychain
        self.apiKey = keychain.read() ?? ""
        self.apiBaseURL = preferences.apiBaseURL.absoluteString
        self.esp32Host = preferences.esp32Host ?? ""
        self.saveFolder = preferences.saveFolder
        self.defaultWorkspaceID = preferences.defaultWorkspaceID ?? ""
    }

    func save() {
        try? keychain.save(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
        if let url = URL(string: apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)) {
            preferences.apiBaseURL = url
        }
        preferences.esp32Host = esp32Host
        preferences.saveFolder = saveFolder
        preferences.defaultWorkspaceID = defaultWorkspaceID.isEmpty ? nil : defaultWorkspaceID
    }

    func test() async {
        save()
        do {
            let client = WhiteboardClient(baseURL: preferences.apiBaseURL, apiKey: { [keychain] in keychain.read() })
            workspaces = try await client.listWorkspaces()
            testResult = "Clé valide — \(workspaces.count) workspace(s)."
        } catch let error as APIError {
            testResult = error.message
        } catch {
            testResult = error.localizedDescription
        }
    }

    func chooseSaveFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = saveFolder
        if panel.runModal() == .OK, let url = panel.url { saveFolder = url }
    }
}
```

`import AppKit` est nécessaire pour `NSOpenPanel` — l'ajouter en tête de fichier.

- [ ] **Step 2: Créer `WhiteboardRecorder/PreferencesView.swift`**

```swift
import SwiftUI

struct PreferencesView: View {
    @ObservedObject var model: PreferencesModel
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Préférences").font(.headline)

            Form {
                SecureField("Clé API", text: $model.apiKey)
                Text("Whiteboard → Settings → API keys, scopes recordings:read et recordings:write.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("URL de l'API", text: $model.apiBaseURL)

                Picker("Workspace par défaut", selection: $model.defaultWorkspaceID) {
                    Text("—").tag("")
                    ForEach(model.workspaces) { workspace in
                        Text(workspace.name).tag(workspace.id)
                    }
                }

                TextField("IP de l'ESP32 (vide = désactivé)", text: $model.esp32Host)

                HStack {
                    Text("Dossier de sauvegarde")
                    Spacer()
                    Text(model.saveFolder.lastPathComponent).foregroundStyle(.secondary)
                    Button("Choisir…") { model.chooseSaveFolder() }
                }
            }

            if let result = model.testResult {
                Text(result).font(.caption)
            }

            HStack {
                Button("Tester") { Task { await model.test() } }
                Spacer()
                Button("Enregistrer") {
                    model.save()
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .task { await model.test() }
    }
}
```

Le `.task` initial sert à peupler la liste des workspaces pour le sélecteur de
workspace par défaut ; s'il n'y a pas encore de clé, il affiche simplement le message
d'erreur correspondant.

- [ ] **Step 3: Créer `WhiteboardRecorder/PreferencesWindowController.swift`**

```swift
import AppKit
import SwiftUI

final class PreferencesWindowController: NSWindowController {
    init(preferences: Preferences, keychain: KeychainStore) {
        let model = PreferencesModel(preferences: preferences, keychain: keychain)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = "Whiteboard Recorder — Préférences"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = NSHostingView(rootView: PreferencesView(model: model) { [weak self] in
            self?.close()
        })
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
```

- [ ] **Step 4: Brancher la fenêtre dans `MenuBarController`**

Ajouter la propriété `private var preferencesWindow: PreferencesWindowController?`
et remplacer le bouchon posé en Task 13 :

```swift
@objc private func showPreferences() {
    let controller = preferencesWindow ?? PreferencesWindowController(preferences: preferences, keychain: keychain)
    preferencesWindow = controller
    NSApp.activate(ignoringOtherApps: true)
    controller.showWindow(nil)
}
```

- [ ] **Step 5: Vérifier à la main**

Run: `./run.sh`, clic droit → Préférences
Expected: coller la clé et cliquer Tester affiche le nombre de workspaces ; le
sélecteur de workspace par défaut se remplit ; relancer l'app conserve la clé
(Keychain) et les réglages.

- [ ] **Step 6: Commit**

```bash
git add WhiteboardRecorder
git commit -m "feat(app): preferences window"
```

---

### Task 16: Icône, README et première release

**Files:**
- Create: `scripts/make-icon.swift`
- Create: `WhiteboardRecorder/Assets.xcassets/` (généré)
- Create: `README.md`
- Modify: `Config/Info.plist`

- [ ] **Step 1: Créer `scripts/make-icon.swift`**

```swift
#!/usr/bin/env swift
// Dessine l'icône de l'app : un disque rouge sur fond sombre arrondi.
import AppKit

let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.14, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: size, height: size),
             xRadius: size * 0.22, yRadius: size * 0.22).fill()

NSColor(calibratedRed: 0.90, green: 0.22, blue: 0.24, alpha: 1).setFill()
let diameter = size * 0.46
NSBezierPath(ovalIn: NSRect(x: (size - diameter) / 2, y: (size - diameter) / 2,
                            width: diameter, height: diameter)).fill()

image.unlockFocus()

let representation = NSBitmapImageRep(data: image.tiffRepresentation!)!
let png = representation.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: "icon-1024.png"))
print("icon-1024.png écrit")
```

- [ ] **Step 2: Générer le jeu d'icônes**

```bash
mkdir -p /tmp/wbr-icon.iconset
swift scripts/make-icon.swift
for pair in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" "128 128x128" "256 128x128@2x" "256 256x256" "512 256x256@2x" "512 512x512" "1024 512x512@2x"; do
  set -- $pair
  sips -z "$1" "$1" icon-1024.png --out "/tmp/wbr-icon.iconset/icon_$2.png" >/dev/null
done
iconutil -c icns /tmp/wbr-icon.iconset -o AppIcon.icns
mkdir -p WhiteboardRecorder/Assets.xcassets/AppIcon.appiconset
```

Placer `icon-1024.png` dans `WhiteboardRecorder/Assets.xcassets/AppIcon.appiconset/`
avec le `Contents.json` correspondant (`"filename": "icon-1024.png"`, `"idiom": "mac"`,
`"scale": "1x"`, `"size": "512x512"`), puis ajouter au projet le réglage
`ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` dans les deux configurations de la
cible. Supprimer `icon-1024.png` et `AppIcon.icns` de la racine.

- [ ] **Step 3: Écrire `README.md`**

```markdown
# Whiteboard Recorder

App macOS de barre de menu : elle enregistre ta réunion — **micro et audio système** —
et l'envoie à [Whiteboard](https://whiteboard.kepochan.com), qui la transcrit et en
fait une note.

Elle remplace `meeting-agent-client-mac`, dont le backend s'éteint.

## Installation

1. Télécharger `WhiteboardRecorder.zip`, décompresser, glisser l'app dans `/Applications`.
2. Au premier lancement, coller une clé API dans les Préférences (clic droit sur
   l'icône). La clé se crée dans Whiteboard → Settings → API keys, avec les scopes
   `recordings:read` et `recordings:write`.
3. macOS demandera l'accès au micro, puis à l'audio système. Les deux sont nécessaires
   pour entendre les participants distants.

## Utilisation

- **Clic gauche** : démarre l'enregistrement immédiatement et ouvre la fenêtre de
  configuration (workspace, titre, date, langue, visibilité, tags).
- **Clic gauche** à nouveau : arrête et envoie.
- **Clic droit** : durée en cours, Préférences, Quitter.

L'audio n'est pas conservé sur le serveur : il est supprimé une fois la transcription
faite. L'app garde sa copie locale jusqu'à l'envoi réussi, puis la supprime. Si l'envoi
échoue, le fichier atterrit dans ton dossier de sauvegarde (`~/Downloads` par défaut).

## Développement

```bash
swift test        # la logique métier, sans Xcode
./run.sh          # compile en debug et lance
./build-release.sh # produit WhiteboardRecorder.app et le zip
```

Aucune clé API ne doit figurer dans le code ni dans un commit.
```

- [ ] **Step 4: Produire la release**

Run: `./build-release.sh`
Expected: `WhiteboardRecorder.app` et `WhiteboardRecorder.zip` à la racine.

- [ ] **Step 5: Commit**

```bash
git add README.md scripts WhiteboardRecorder Config WhiteboardRecorder.zip
git commit -m "chore: app icon, README and first release build"
```

---

## Bout-en-bout, à faire une fois le plan terminé

Avec une vraie clé recorder (scopes `recordings:read` et `recordings:write`
uniquement) et un workspace de test :

1. Vérifier que `GET /workspaces/:id/tags` répond bien avec cette clé restreinte.
   Si c'est un 403, le champ tags reste vide : ajouter le scope manquant à la clé, ou
   accepter la dégradation.
2. Enregistrer dix secondes en parlant avec une vidéo qui tourne, titre « Test »,
   un tag existant, visibilité `private`.
3. Vérifier dans Whiteboard, une quinzaine de secondes plus tard : la note existe,
   porte le tag choisi **et** le tag `meeting`, son slug vaut `test-<date du jour>`,
   et la transcription contient les deux voix.
4. Vérifier que le `.m4a` local a disparu de
   `~/Library/Application Support/WhiteboardRecorder/Recordings`.
