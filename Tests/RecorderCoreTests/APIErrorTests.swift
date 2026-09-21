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

@Test func everyStatusKeepsTheServerDetail() {
    // 401 and 409 used to drop it while 403, 404 and 5xx kept it.
    #expect(APIError.unauthorized("key revoked").message.contains("key revoked"))
    #expect(APIError.conflict("note exists").message.contains("note exists"))
    #expect(APIError.forbidden("not a member").message.contains("not a member"))
    #expect(APIError.notFound("no such workspace").message.contains("no such workspace"))
    #expect(APIError.server(status: 500, "boom").message.contains("boom"))
}

@Test func onlyKeyFailuresSendTheUserToThePreferences() {
    // Retrying with the same dead key can only fail again.
    #expect(APIError.unauthorized("").isAuthenticationFailure)
    #expect(APIError.noAPIKey.isAuthenticationFailure)
    #expect(!APIError.forbidden("").isAuthenticationFailure)
    #expect(!APIError.tooLarge.isAuthenticationFailure)
    #expect(!APIError.server(status: 500, "").isAuthenticationFailure)
}

@Test func theConflictMessageTalksAboutTheTitleAndTheDate() {
    // The app never sends a slug, and the user has never seen one.
    let message = APIError.conflict("").message
    #expect(!message.lowercased().contains("slug"))
    #expect(message.contains("titre"))
    #expect(message.contains("date"))
}
