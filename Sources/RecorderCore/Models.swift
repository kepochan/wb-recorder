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
