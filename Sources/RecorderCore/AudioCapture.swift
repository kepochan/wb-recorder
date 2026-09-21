import Foundation

public enum CaptureError: Error, Equatable {
    case noInputDevice
    case aggregateDeviceFailed(OSStatus)
    case notRecording
    /// The encoder failed while the capture was running, so the file is
    /// truncated. It is left on disk at `partialFile` for salvage, but it is
    /// never handed back as a recording.
    case writeFailed(reason: String, partialFile: String)
    /// The input device died, or its sample rate changed, while recording: the
    /// file is truncated or pitch-shifted and cannot be trusted.
    case deviceChanged(partialFile: String)
    /// Not a single frame reached the encoder.
    case nothingCaptured(partialFile: String)
}

public protocol AudioCapture: AnyObject {
    /// False when the system-audio tap could not be created: the microphone is
    /// still recorded, and the UI warns that remote participants are missing.
    var isSystemAudioAvailable: Bool { get }
    /// Returns the instant capture actually started — this is `recordedAt`.
    func start() throws -> Date
    /// Returns the finished .m4a file.
    func stop() throws -> URL
}

public enum RecordingStorage {
    public static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhiteboardRecorder/Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    public static func newFileURL() -> URL {
        directory.appendingPathComponent("\(UUID().uuidString).m4a")
    }

    /// Recordings still sitting in the working directory. A running capture
    /// owns the one it is writing; anything found here at launch was stranded
    /// by a crash, a kill or a move that failed, and nothing else ever lists
    /// this folder — so without this sweep those files rot there unseen.
    public static func strandedFiles(in directory: URL = RecordingStorage.directory) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        return contents
            .filter { $0.pathExtension.lowercased() == "m4a" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
