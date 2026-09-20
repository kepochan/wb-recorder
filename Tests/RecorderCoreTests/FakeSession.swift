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
