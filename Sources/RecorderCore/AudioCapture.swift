import Foundation

public enum CaptureError: Error, Equatable {
    case noInputDevice
    case aggregateDeviceFailed(OSStatus)
    case notRecording
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
}
