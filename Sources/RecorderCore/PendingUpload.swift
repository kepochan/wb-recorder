import Foundation

/// An upload the app still owes the server, in the form it must take to
/// survive a quit, a crash or a night asleep.
public struct PendingUpload: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    /// A bare name inside `RecordingStorage.directory`. Not a full path: the
    /// sandbox container's absolute path is nothing to freeze in a file.
    public let fileName: String
    /// Measured once the capture was finalised. The server checks every byte
    /// against it, so it is never measured again.
    public let size: Int64
    public let configuration: RecordingConfiguration
    /// Nil until `start` has answered — and again after a 404, to start over.
    public var uploadId: String?
    /// The piece size `start` asked for; `GET` does not repeat it.
    public var chunkSize: Int?
    /// Set before `complete` leaves. A 404 afterwards may mean the recording
    /// was created and its session since purged: uploading the file again
    /// would make a second note.
    public var completeSent: Bool

    public init(id: UUID = UUID(), fileName: String, size: Int64, configuration: RecordingConfiguration,
                uploadId: String? = nil, chunkSize: Int? = nil, completeSent: Bool = false) {
        self.id = id
        self.fileName = fileName
        self.size = size
        self.configuration = configuration
        self.uploadId = uploadId
        self.chunkSize = chunkSize
        self.completeSent = completeSent
    }

    public func fileURL(in directory: URL) -> URL {
        directory.appendingPathComponent(fileName)
    }
}

/// The queue on disk, in upload order. The offset is deliberately absent: the
/// server's `GET` is the only count of the bytes it holds worth trusting.
public struct PendingUploadStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL = PendingUploadStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    public static var defaultFileURL: URL {
        RecordingStorage.directory.deletingLastPathComponent()
            .appendingPathComponent("pending-uploads.json")
    }

    /// An unreadable file yields an empty queue rather than a crash: the
    /// recordings it named are still in the working folder, and the launch
    /// sweep moves them to the save folder.
    public func load() -> [PendingUpload] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        // Entry by entry: one that no longer decodes must not take the
        // others, and their recordings, down with it.
        let entries = (try? Self.decoder.decode([FailableEntry].self, from: data)) ?? []
        return entries.compactMap(\.upload).map(Self.withCurrentSharingMode)
    }

    /// Every entry, session or not: a live session already holds its mode on
    /// the server, and a purged one means a fresh `start`, which would refuse
    /// a 1.1.0 token with a 400.
    private static func withCurrentSharingMode(_ upload: PendingUpload) -> PendingUpload {
        var configuration = upload.configuration
        configuration.sharingMode = Preferences.currentSharingMode(configuration.sharingMode)
        return PendingUpload(id: upload.id, fileName: upload.fileName, size: upload.size,
                             configuration: configuration, uploadId: upload.uploadId,
                             chunkSize: upload.chunkSize, completeSent: upload.completeSent)
    }

    private struct FailableEntry: Decodable {
        let upload: PendingUpload?
        init(from decoder: Decoder) throws {
            upload = try? PendingUpload(from: decoder)
        }
    }

    public func save(_ uploads: [PendingUpload]) throws {
        try Self.encoder.encode(uploads).write(to: fileURL, options: .atomic)
    }

    // ISO 8601 rather than the default seconds-since-2001, so the file can be
    // read — and written by hand to test a resume.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
