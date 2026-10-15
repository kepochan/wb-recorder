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
    case fileMissing

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

    /// True when the request was refused because of the API key itself.
    /// Retrying with the same dead key can only fail again, so the failure
    /// alert offers the preferences instead of "Retry".
    public var isAuthenticationFailure: Bool {
        switch self {
        case .noAPIKey, .unauthorized: return true
        default: return false
        }
    }

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

    public var message: String {
        switch self {
        case .noAPIKey:
            return "No API key configured. Open the preferences to paste one."
        case .invalidTitle:
            return "The title must be between 1 and 255 characters."
        case .recordedAtInFuture:
            return "The meeting date cannot be in the future."
        case let .badRequest(messages):
            return messages.isEmpty ? "The server rejected the request." : messages.joined(separator: "\n")
        case let .unauthorized(detail):
            return detail.isEmpty
                ? "API key missing, invalid or revoked."
                : "API key missing, invalid or revoked: \(detail)"
        case let .forbidden(detail):
            return detail.isEmpty ? "You are not a member of this workspace." : "Access denied: \(detail)"
        case let .notFound(detail):
            return detail.isEmpty ? "Not found." : detail
        case let .conflict(detail):
            // The app never sends a slug and the user has never seen one, so
            // the collision is named by what they did choose: title and date.
            return detail.isEmpty
                ? "A note already exists for this title and meeting date."
                : "A note already exists for this title and meeting date: \(detail)"
        case .tooLarge:
            return "File too large (limit: 1 GiB)."
        case let .server(status, detail):
            return detail.isEmpty ? "Server error (\(status))." : "Server error (\(status)): \(detail)"
        case .invalidResponse:
            return "Unexpected response from the server."
        case .fileMissing:
            return "The audio file is missing."
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
