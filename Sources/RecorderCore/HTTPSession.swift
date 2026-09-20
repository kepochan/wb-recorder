import Foundation

/// Seam that lets tests observe the requests the client actually builds.
public protocol HTTPSession: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
    func upload(for request: URLRequest, fromFile fileURL: URL) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPSession {}
