import Combine
import Foundation

/// Owns the uploads still owed to the server and sends them one at a time, in
/// the order the meetings were confirmed. The queue lives on disk, so a quit,
/// a crash or a night asleep only pauses it; the app hands a file over the
/// moment the configuration window says OK and is free to record the next
/// meeting.
@MainActor
public final class UploadCoordinator: ObservableObject {
    public enum Activity: Equatable, Sendable {
        case idle
        case uploading(id: UUID, title: String, sent: Int64, total: Int64)
        case paused(id: UUID, title: String, message: String)
    }

    /// One upload as its configuration window sees it.
    public enum ItemStatus: Equatable, Sendable {
        case waiting
        case uploading(sent: Int64, total: Int64)
        case paused(String)
        /// No longer queued: sent, or handed back to the app as a failure.
        case finished
    }

    public enum Failure: Equatable, Sendable {
        case rejected(APIError)
        case maybeAlreadyUploaded
    }

    @Published public private(set) var activity: Activity = .idle
    @Published public private(set) var queue: [PendingUpload]

    public var onCompleted: ((PendingUpload) -> Void)?
    /// The upload has left the queue; its file is still in the working folder
    /// and is now the app's to keep, retry or move.
    public var onFailed: ((PendingUpload, Failure) -> Void)?
    /// Title and body of a banner for what happens while no window watches.
    public var notify: ((String, String) -> Void)?

    private let store: PendingUploadStore
    private let directory: URL
    private let makeUploader: () -> ChunkedUploader
    private(set) var task: Task<Void, Never>?
    private var networkWasAvailable = true

    public init(store: PendingUploadStore, directory: URL, makeUploader: @escaping () -> ChunkedUploader) {
        self.store = store
        self.directory = directory
        self.makeUploader = makeUploader
        self.queue = store.load()
    }

    public var waitingCount: Int { max(queue.count - 1, 0) }

    /// Files the launch sweep must leave alone: they are on their way.
    public var referencedFileNames: Set<String> { Set(queue.map(\.fileName)) }

    public func status(of id: UUID) -> ItemStatus {
        switch activity {
        case let .uploading(current, _, sent, total) where current == id:
            return .uploading(sent: sent, total: total)
        case let .paused(current, _, message) where current == id:
            return .paused(message)
        default:
            return queue.contains { $0.id == id } ? .waiting : .finished
        }
    }

    /// The file must sit in the working folder the coordinator was given; it is
    /// remembered by name only.
    @discardableResult
    public func enqueue(fileURL: URL, configuration: RecordingConfiguration) throws -> UUID {
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { throw APIError.fileMissing }
        let upload = PendingUpload(fileName: fileURL.lastPathComponent, size: size, configuration: configuration)
        queue.append(upload)
        save()
        pump()
        return upload.id
    }

    /// An upload the user chose to retry goes right after the current one —
    /// running or paused — rather than to the back of the queue, and never
    /// alongside it.
    public func requeue(_ upload: PendingUpload, startingOver: Bool) {
        var upload = upload
        if startingOver {
            upload.uploadId = nil
            upload.chunkSize = nil
            upload.completeSent = false
        }
        queue.insert(upload, at: queue.isEmpty ? 0 : 1)
        save()
        pump()
    }

    /// "Resume upload". Does nothing unless paused.
    public func resume() {
        guard case .paused = activity, task == nil else { return }
        startHead()
    }

    /// Fed every network change. Only a return after an outage, while paused,
    /// is worth acting on — once; a new failure waits for the next return or
    /// a click.
    public func networkChanged(isAvailable: Bool) {
        defer { networkWasAvailable = isAvailable }
        guard isAvailable, !networkWasAvailable else { return }
        resume()
    }

    /// At launch: drops the entries whose file has gone and returns their
    /// titles so the app can say so, then picks the queue up where it stopped.
    public func resumeAfterLaunch() -> [String] {
        let missing = queue.filter { !FileManager.default.fileExists(atPath: $0.fileURL(in: directory).path) }
        if !missing.isEmpty {
            let missingIDs = Set(missing.map(\.id))
            queue.removeAll { missingIDs.contains($0.id) }
            save()
        }
        if let head = queue.first {
            notify?("Resuming upload", "“\(head.configuration.title)” continues where it stopped.")
        }
        pump()
        return missing.map(\.configuration.title)
    }

    /// At quit. What was sent stays sent, and the queue is already on disk.
    public func stop() {
        task?.cancel()
        task = nil
    }

    // MARK: - Running

    private func pump() {
        guard task == nil else { return }
        // A pause holds the whole queue, so the order of the meetings holds.
        if case .paused = activity { return }
        startHead()
    }

    private func startHead() {
        guard let head = queue.first else {
            activity = .idle
            return
        }
        activity = .uploading(id: head.id, title: head.configuration.title, sent: 0, total: head.size)
        let uploader = makeUploader()
        let directory = self.directory
        task = Task { [weak self] in
            let outcome: UploadOutcome
            do {
                outcome = try await uploader.run(
                    head, directory: directory,
                    progress: { [weak self] sent, total in
                        await self?.progressed(head.id, sent: sent, total: total)
                    },
                    persist: { [weak self] updated in
                        await self?.persisted(updated)
                    })
            } catch {
                // Cancelled at quit: the queue on disk is where the next
                // launch picks up.
                return
            }
            self?.finished(head.id, outcome)
        }
    }

    private func progressed(_ id: UUID, sent: Int64, total: Int64) {
        guard case let .uploading(current, title, _, _) = activity, current == id else { return }
        activity = .uploading(id: id, title: title, sent: sent, total: total)
    }

    private func persisted(_ upload: PendingUpload) {
        guard let index = queue.firstIndex(where: { $0.id == upload.id }) else { return }
        queue[index] = upload
        save()
    }

    private func finished(_ id: UUID, _ outcome: UploadOutcome) {
        task = nil
        guard let upload = queue.first(where: { $0.id == id }) else {
            pump()
            return
        }
        let title = upload.configuration.title

        switch outcome {
        case .completed:
            try? FileManager.default.removeItem(at: upload.fileURL(in: directory))
            remove(id)
            onCompleted?(upload)
        case let .paused(detail):
            activity = .paused(id: id, title: title, message: detail)
            notify?("Upload paused",
                    "“\(title)” will resume when the network comes back, or from the menu bar icon.")
            return
        case let .failed(error):
            remove(id)
            onFailed?(upload, .rejected(error))
        case .maybeAlreadyUploaded:
            remove(id)
            onFailed?(upload, .maybeAlreadyUploaded)
        }
        activity = .idle
        pump()
    }

    private func remove(_ id: UUID) {
        queue.removeAll { $0.id == id }
        save()
    }

    /// A save that fails leaves the previous queue on disk. The next launch
    /// then asks the server where each upload stands, which is safe for every
    /// entry except one whose `complete` went unrecorded — the 404 path still
    /// stops short of a second upload for those.
    private func save() {
        try? store.save(queue)
    }
}
