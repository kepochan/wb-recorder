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

public struct RecordingUpload: Equatable, Sendable {
    public var audioURL: URL
    public var workspaceID: String
    public var title: String
    public var recordedAt: Date
    public var language: String
    public var sharingMode: String
    public var tags: [Tag]

    public init(audioURL: URL, workspaceID: String, title: String, recordedAt: Date,
                language: String, sharingMode: String, tags: [Tag]) {
        self.audioURL = audioURL
        self.workspaceID = workspaceID
        self.title = title
        self.recordedAt = recordedAt
        self.language = language
        self.sharingMode = sharingMode
        self.tags = tags
    }
}

public struct UploadedRecording: Decodable, Equatable, Sendable {
    public let id: String
    public let noteSlug: String
    public let status: String

    public init(id: String, noteSlug: String, status: String) {
        self.id = id
        self.noteSlug = noteSlug
        self.status = status
    }
}

/// What opening an upload session answers: where the server stands and how
/// big each piece must be.
public struct UploadSession: Decodable, Equatable, Sendable {
    public let uploadId: String
    public let offset: Int64
    public let size: Int64
    public let chunkSize: Int
}

/// The server's own count of the bytes it holds — the only one to trust after
/// a cut, since a piece whose answer was lost may still have been kept.
public struct UploadStatus: Decodable, Equatable, Sendable {
    public let offset: Int64
    public let size: Int64
    /// Present once `complete` has created the recording.
    public let recordingId: String?
}

public enum ChunkResult: Equatable, Sendable {
    case advanced(to: Int64)
    /// Not a failure: the server says where it is, and the upload goes on from there.
    case offsetMismatch(serverOffset: Int64)
    case alreadyCompleted
}

public enum CompleteResult: Equatable, Sendable {
    /// Nil when a 2xx came back in a shape this app does not know: the
    /// recording exists all the same.
    case completed(UploadedRecording?)
    case notComplete(serverOffset: Int64)
    case slugTaken
}
