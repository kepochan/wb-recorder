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
