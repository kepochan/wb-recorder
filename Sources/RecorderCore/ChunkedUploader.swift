import Foundation
import os

public enum UploadOutcome: Equatable, Sendable {
    case completed(UploadedRecording?)
    /// The fourth failure in a row. Carries the last one, for the user.
    case paused(String)
    /// A 404 after `complete` was sent: the recording may exist and its session
    /// may simply have been purged. Only the user can tell.
    case maybeAlreadyUploaded
    case failed(APIError)
}

/// Drives one upload to its end — or to the point where it has to stop and
/// say why. It holds no state between runs: everything a later run needs is in
/// the `PendingUpload` it hands to `persist`, and the offset is asked of the
/// server, which alone knows which pieces it kept.
public struct ChunkedUploader: Sendable {
    public static let maxConsecutiveFailures = 4
    /// For a session saved without its piece size; the server's own default.
    static let fallbackChunkSize = 4 * 1024 * 1024

    private static let log = Logger(subsystem: "com.kepochan.whiteboard-recorder", category: "upload")

    let client: WhiteboardClient
    let sleep: @Sendable (Duration) async throws -> Void

    public init(client: WhiteboardClient,
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.client = client
        self.sleep = sleep
    }

    /// Throws only `CancellationError`. A cancelled run leaves nothing half
    /// done: the server adds a piece only once it has received all of it.
    public func run(_ initial: PendingUpload,
                    directory: URL,
                    progress: @escaping @Sendable (Int64, Int64) async -> Void,
                    persist: @escaping @Sendable (PendingUpload) async -> Void) async throws -> UploadOutcome {
        var upload = initial
        let fileURL = upload.fileURL(in: directory)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .failed(.fileMissing) }

        var offset: Int64 = 0
        // A session from an earlier run: where it stands is the server's to say.
        var mustAskServer = upload.uploadId != nil
        var useDefaultSlug = false
        var failures = 0

        while true {
            try Task.checkCancellation()
            do {
                guard let uploadId = upload.uploadId else {
                    let session = try await client.startUpload(configuration: upload.configuration,
                                                               size: upload.size, filename: upload.fileName)
                    Self.log.notice("started \(session.uploadId, privacy: .public) size=\(upload.size, privacy: .public)")
                    upload.uploadId = session.uploadId
                    upload.chunkSize = session.chunkSize
                    upload.completeSent = false
                    offset = session.offset
                    mustAskServer = false
                    failures = 0
                    await persist(upload)
                    continue
                }

                if mustAskServer {
                    let status = try await client.uploadStatus(uploadId: uploadId)
                    // A recording already made means every byte is there, and
                    // `complete` will replay it.
                    offset = status.recordingId == nil ? status.offset : upload.size
                    mustAskServer = false
                    Self.log.notice("resuming \(uploadId, privacy: .public) at \(offset, privacy: .public)")
                }
                await progress(offset, upload.size)

                if offset < upload.size {
                    let chunk = try Self.readChunk(of: fileURL, at: offset,
                                                   length: upload.chunkSize ?? Self.fallbackChunkSize)
                    switch try await client.putChunk(uploadId: uploadId, offset: offset, data: chunk) {
                    case let .advanced(to: next):
                        offset = next
                        failures = 0
                    case let .offsetMismatch(serverOffset):
                        Self.log.notice("realigned \(uploadId, privacy: .public) \(offset, privacy: .public) -> \(serverOffset, privacy: .public)")
                        offset = serverOffset
                    case .alreadyCompleted:
                        offset = upload.size
                    }
                    continue
                }

                if !upload.completeSent {
                    upload.completeSent = true
                    await persist(upload)
                }
                switch try await client.completeUpload(uploadId: uploadId, useDefaultSlug: useDefaultSlug) {
                case let .completed(recording):
                    Self.log.notice("completed \(uploadId, privacy: .public)")
                    return .completed(recording)
                case let .notComplete(serverOffset):
                    offset = serverOffset
                    // The server says nothing was created, so a later 404 can
                    // no longer mean the recording exists.
                    upload.completeSent = false
                    await persist(upload)
                case .slugTaken:
                    // The app never sends a slug, so the server's default is
                    // the only other one to ask for — and only once.
                    guard !useDefaultSlug else { return .failed(.conflict("")) }
                    useDefaultSlug = true
                }
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }

                if case APIError.notFound = error, upload.uploadId != nil {
                    if upload.completeSent { return .maybeAlreadyUploaded }
                    // Purged or unknown before it was finished: start over,
                    // which is not a failure of the connection.
                    Self.log.notice("session lost, starting over")
                    upload.uploadId = nil
                    upload.chunkSize = nil
                    await persist(upload)
                    continue
                }

                guard APIError.isTransient(error) else {
                    return .failed(error as? APIError ?? .invalidResponse)
                }
                failures += 1
                Self.log.notice("failure \(failures, privacy: .public): \(Self.describe(error), privacy: .public)")
                if failures >= Self.maxConsecutiveFailures {
                    return .paused(Self.describe(error))
                }
                try await sleep(.seconds(1 << (failures - 1)))
                if upload.uploadId != nil { mustAskServer = true }
            }
        }
    }

    static func describe(_ error: Error) -> String {
        (error as? APIError)?.message ?? error.localizedDescription
    }

    /// One piece, read from disk: a two-hour meeting never sits in memory whole.
    static func readChunk(of url: URL, at offset: Int64, length: Int) throws -> Data {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(offset))
            let data = try handle.read(upToCount: length) ?? Data()
            guard !data.isEmpty else { throw APIError.fileMissing }
            return data
        } catch {
            throw APIError.fileMissing
        }
    }
}
