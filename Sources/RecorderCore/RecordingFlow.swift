import Foundation

public struct RecordingConfiguration: Codable, Equatable, Sendable {
    public var workspaceID: String
    public var title: String
    public var recordedAt: Date
    public var language: String
    public var sharingMode: String
    public var tags: [Tag]

    public init(workspaceID: String, title: String, recordedAt: Date,
                language: String, sharingMode: String, tags: [Tag]) {
        self.workspaceID = workspaceID
        self.title = title
        self.recordedAt = recordedAt
        self.language = language
        self.sharingMode = sharingMode
        self.tags = tags
    }
}

public enum IconState: Equatable, Sendable { case idle, recording, uploading }

public enum RecordingState: Equatable {
    case idle
    /// Capturing. The configuration is asked for once the recording stops.
    case recording(startedAt: Date)
    /// Capture is over and the configuration window is up; nothing is being
    /// recorded any more, and nothing has been handed to the upload queue yet.
    case configuring(startedAt: Date)
    /// The capture could not be finalised: there is nothing to configure or
    /// upload, only perhaps a partial file to keep.
    case failed(message: String)
}

public enum RecordingEvent {
    case iconClicked
    case configurationConfirmed(RecordingConfiguration)
    case configurationCancelled
    /// The capture could not be finalised, so there is nothing to configure.
    case captureFailed(String)
    case failureDismissed
}

public enum RecordingEffect: Equatable {
    case startCapture
    case stopCapture
    case discardFile
    case moveFileToSaveFolder
    /// Hands the file to the upload queue, which sends it in the background
    /// and owns it from then on.
    case enqueueUpload(RecordingConfiguration)
    case showConfigurationWindow(startedAt: Date)
    case focusConfigurationWindow
    case setIcon(IconState)
    case setESP32Recording(Bool)
}

/// Pure state machine: it decides, the controller acts.
public final class RecordingFlow {
    public private(set) var state: RecordingState = .idle
    private let now: () -> Date

    public init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    public func handle(_ event: RecordingEvent) -> [RecordingEffect] {
        switch (state, event) {
        case (.idle, .iconClicked):
            let startedAt = now()
            state = .recording(startedAt: startedAt)
            return [.startCapture, .setIcon(.recording), .setESP32Recording(true)]

        case let (.recording(startedAt), .iconClicked):
            state = .configuring(startedAt: startedAt)
            return [.stopCapture, .setESP32Recording(false), .setIcon(.uploading),
                    .showConfigurationWindow(startedAt: startedAt)]

        case (.configuring, .iconClicked):
            return [.focusConfigurationWindow]

        case let (.configuring, .configurationConfirmed(configuration)):
            state = .idle
            return [.enqueueUpload(configuration), .setIcon(.idle)]

        case (.configuring, .configurationCancelled):
            state = .idle
            return [.discardFile, .setIcon(.idle)]

        case let (.configuring, .captureFailed(message)):
            state = .failed(message: message)
            return [.setIcon(.idle)]

        case (.failed, .failureDismissed):
            state = .idle
            return [.moveFileToSaveFolder, .setIcon(.idle)]

        default:
            return []
        }
    }
}
