import Foundation

public struct RecordingConfiguration: Equatable, Sendable {
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
    case configuring(startedAt: Date)
    case recording(startedAt: Date, configuration: RecordingConfiguration)
    case uploading(RecordingConfiguration)
    case failed(RecordingConfiguration, message: String)
}

public enum RecordingEvent {
    case iconClicked
    case configurationConfirmed(RecordingConfiguration)
    case configurationCancelled
    case uploadSucceeded
    case uploadFailed(String)
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
            state = .configuring(startedAt: startedAt)
            return [.startCapture, .setIcon(.recording), .setESP32Recording(true),
                    .showConfigurationWindow(startedAt: startedAt)]

        case (.configuring, .iconClicked):
            return [.focusConfigurationWindow]

        case let (.configuring(startedAt), .configurationConfirmed(configuration)):
            state = .recording(startedAt: startedAt, configuration: configuration)
            return []

        case (.configuring, .configurationCancelled):
            state = .idle
            return [.stopCapture, .discardFile, .setESP32Recording(false), .setIcon(.idle)]

        case let (.recording(_, configuration), .iconClicked):
            state = .uploading(configuration)
            return [.stopCapture, .setESP32Recording(false), .setIcon(.uploading), .upload(configuration)]

        case (.uploading, .uploadSucceeded):
            state = .idle
            return [.deleteFile, .setIcon(.idle)]

        case let (.uploading(configuration), .uploadFailed(message)):
            state = .failed(configuration, message: message)
            return [.setIcon(.idle)]

        case let (.failed(configuration, _), .retryRequested):
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
