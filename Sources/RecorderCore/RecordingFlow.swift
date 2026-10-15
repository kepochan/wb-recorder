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
    /// recorded any more, and nothing has been uploaded yet.
    case configuring(startedAt: Date)
    case uploading(RecordingConfiguration)
    /// The configuration is absent when the capture itself failed, since the
    /// user never got to fill it in.
    case failed(RecordingConfiguration?, message: String)
}

public enum RecordingEvent {
    case iconClicked
    case configurationConfirmed(RecordingConfiguration)
    case configurationCancelled
    case uploadSucceeded
    case uploadFailed(String)
    /// The capture could not be finalised, so there is nothing to configure.
    case captureFailed(String)
    case retryRequested
    case failureDismissed
}

public enum RecordingEffect: Equatable {
    case startCapture
    case stopCapture
    case discardFile
    case deleteFile
    case moveFileToSaveFolder
    case upload(RecordingConfiguration)
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
            state = .uploading(configuration)
            return [.upload(configuration)]

        case (.configuring, .configurationCancelled):
            state = .idle
            return [.discardFile, .setIcon(.idle)]

        case let (.configuring, .captureFailed(message)):
            state = .failed(nil, message: message)
            return [.setIcon(.idle)]

        case (.uploading, .uploadSucceeded):
            state = .idle
            return [.deleteFile, .setIcon(.idle)]

        case let (.uploading(configuration), .uploadFailed(message)):
            state = .failed(configuration, message: message)
            return [.setIcon(.idle)]

        case let (.failed(configuration?, _), .retryRequested):
            state = .uploading(configuration)
            return [.setIcon(.uploading), .upload(configuration)]

        case (.failed, .failureDismissed):
            state = .idle
            return [.moveFileToSaveFolder, .setIcon(.idle)]

        default:
            return []
        }
    }
}
