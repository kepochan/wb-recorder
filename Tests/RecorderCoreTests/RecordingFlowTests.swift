import Foundation
import Testing
@testable import RecorderCore

private let fixedDate = Date(timeIntervalSince1970: 1_789_655_520)

private func makeConfiguration() -> RecordingConfiguration {
    RecordingConfiguration(workspaceID: "uuid-1", title: "Daily", recordedAt: fixedDate,
                           language: "fr", sharingMode: "private", tags: [])
}

@Test func clickingWhileIdleStartsCapturingBeforeAskingAnything() {
    let flow = RecordingFlow(now: { fixedDate })
    let effects = flow.handle(.iconClicked)
    #expect(effects == [.startCapture, .setIcon(.recording), .setESP32Recording(true),
                        .showConfigurationWindow(startedAt: fixedDate)])
    #expect(flow.state == .configuring(startedAt: fixedDate))
}

@Test func clickingWhileTheWindowIsOpenOnlyBringsItBack() {
    let flow = RecordingFlow(now: { fixedDate })
    _ = flow.handle(.iconClicked)
    #expect(flow.handle(.iconClicked) == [.focusConfigurationWindow])
    #expect(flow.state == .configuring(startedAt: fixedDate))
}

@Test func cancellingThrowsTheRecordingAway() {
    let flow = RecordingFlow(now: { fixedDate })
    _ = flow.handle(.iconClicked)
    #expect(flow.handle(.configurationCancelled)
        == [.stopCapture, .discardFile, .setESP32Recording(false), .setIcon(.idle)])
    #expect(flow.state == .idle)
}

@Test func confirmingKeepsRecordingUntilTheNextClick() {
    let flow = RecordingFlow(now: { fixedDate })
    let configuration = makeConfiguration()
    _ = flow.handle(.iconClicked)

    #expect(flow.handle(.configurationConfirmed(configuration)) == [])
    #expect(flow.state == .recording(startedAt: fixedDate, configuration: configuration))

    #expect(flow.handle(.iconClicked)
        == [.stopCapture, .setESP32Recording(false), .setIcon(.uploading), .upload(configuration)])
    #expect(flow.state == .uploading(configuration))
}

@Test func aClickDuringUploadDoesNothing() {
    let flow = RecordingFlow(now: { fixedDate })
    _ = flow.handle(.iconClicked)
    _ = flow.handle(.configurationConfirmed(makeConfiguration()))
    _ = flow.handle(.iconClicked)
    #expect(flow.handle(.iconClicked) == [])
}

@Test func successDeletesTheLocalFile() {
    let flow = RecordingFlow(now: { fixedDate })
    _ = flow.handle(.iconClicked)
    _ = flow.handle(.configurationConfirmed(makeConfiguration()))
    _ = flow.handle(.iconClicked)

    #expect(flow.handle(.uploadSucceeded) == [.deleteFile, .setIcon(.idle)])
    #expect(flow.state == .idle)
}

@Test func failureKeepsTheFileAndAllowsARetry() {
    let flow = RecordingFlow(now: { fixedDate })
    let configuration = makeConfiguration()
    _ = flow.handle(.iconClicked)
    _ = flow.handle(.configurationConfirmed(configuration))
    _ = flow.handle(.iconClicked)

    #expect(flow.handle(.uploadFailed("Réseau injoignable")) == [.setIcon(.idle)])
    #expect(flow.state == .failed(configuration, message: "Réseau injoignable"))

    #expect(flow.handle(.retryRequested) == [.setIcon(.uploading), .upload(configuration)])
    #expect(flow.state == .uploading(configuration))
}

@Test func dismissingAFailureMovesTheFileToTheSaveFolder() {
    let flow = RecordingFlow(now: { fixedDate })
    _ = flow.handle(.iconClicked)
    _ = flow.handle(.configurationConfirmed(makeConfiguration()))
    _ = flow.handle(.iconClicked)
    _ = flow.handle(.uploadFailed("boom"))

    #expect(flow.handle(.failureDismissed) == [.moveFileToSaveFolder, .setIcon(.idle)])
    #expect(flow.state == .idle)
}
