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
