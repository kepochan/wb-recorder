import Foundation
@testable import RecorderCore

final class FakeSession: HTTPSession, @unchecked Sendable {
    struct Call {
        let request: URLRequest
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
            _calls.append(Call(request: request))
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

    private func response(for request: URLRequest, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }
}
