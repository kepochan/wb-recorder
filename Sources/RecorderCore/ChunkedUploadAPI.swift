import Foundation

/// The resumable upload the backend exposes since 2026-10-10 (WB #1110). A
/// single `POST /recordings` is cut by the reverse proxy after 60 s, whatever
/// its size; pieces of a few MiB each fit well under that, and after a cut the
/// upload goes on from the byte the server stopped at.
extension WhiteboardClient {
    public func startUpload(configuration: RecordingConfiguration, size: Int64,
                            filename: String) async throws -> UploadSession {
        let title = configuration.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 255 else { throw APIError.invalidTitle }
        guard configuration.recordedAt <= Date() else { throw APIError.recordedAtInFuture }

        let body = StartBody(workspaceId: configuration.workspaceID,
                             title: title,
                             recordedAt: ISO8601.string(from: configuration.recordedAt),
                             language: configuration.language,
                             sharingMode: configuration.sharingMode,
                             tags: configuration.tags.isEmpty ? nil : configuration.tags,
                             size: size,
                             mimeType: "audio/mp4",
                             filename: filename)
        var request = try makeRequest("recordings/uploads", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        try check(response, data)
        return try decode(data)
    }

    public func putChunk(uploadId: String, offset: Int64, data chunk: Data) async throws -> ChunkResult {
        var request = try makeRequest("recordings/uploads/\(uploadId)", method: "PUT",
                                      query: [URLQueryItem(name: "offset", value: String(offset))])
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = chunk

        let (data, response) = try await session.data(for: request)
        if let conflict = OffsetConflict.from(response, data) {
            return conflict.message?.localizedCaseInsensitiveContains("already completed") == true
                ? .alreadyCompleted
                : .offsetMismatch(serverOffset: conflict.offset)
        }
        try check(response, data)
        let body: OffsetBody = try decode(data)
        return .advanced(to: body.offset)
    }

    public func uploadStatus(uploadId: String) async throws -> UploadStatus {
        let request = try makeRequest("recordings/uploads/\(uploadId)")
        let (data, response) = try await session.data(for: request)
        try check(response, data)
        return try decode(data)
    }

    /// `complete` is idempotent on the server: calling it again after a lost
    /// answer returns the same recording instead of creating a second one.
    public func completeUpload(uploadId: String, useDefaultSlug: Bool) async throws -> CompleteResult {
        var request = try makeRequest("recordings/uploads/\(uploadId)/complete", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data((useDefaultSlug ? #"{"slug":null}"# : "{}").utf8)

        let (data, response) = try await session.data(for: request)
        if let conflict = OffsetConflict.from(response, data) {
            return .notComplete(serverOffset: conflict.offset)
        }
        if (response as? HTTPURLResponse)?.statusCode == 409 {
            return .slugTaken
        }
        try check(response, data)
        // Past `check` the recording exists, and a body this app cannot read
        // must not turn that into a failure that invites a second upload.
        return .completed(try? JSONDecoder().decode(UploadedRecording.self, from: data))
    }
}

private struct StartBody: Encodable {
    let workspaceId: String
    let title: String
    let recordedAt: String
    let language: String
    let sharingMode: String
    /// Nil is left out of the JSON entirely rather than sent as `null`.
    let tags: [Tag]?
    let size: Int64
    let mimeType: String
    let filename: String
}

private struct OffsetBody: Decodable {
    let offset: Int64
}

/// A 409 that names the server's offset: the upload is behind or ahead of
/// what the app thought, not refused.
private struct OffsetConflict: Decodable {
    let message: String?
    let offset: Int64

    static func from(_ response: URLResponse, _ data: Data) -> OffsetConflict? {
        guard (response as? HTTPURLResponse)?.statusCode == 409 else { return nil }
        return try? JSONDecoder().decode(OffsetConflict.self, from: data)
    }
}
