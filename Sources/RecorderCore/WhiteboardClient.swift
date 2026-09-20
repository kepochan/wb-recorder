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
