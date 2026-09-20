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
