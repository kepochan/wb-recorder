import Foundation
import Testing
@testable import RecorderCore

private let fixedDate = Date(timeIntervalSince1970: 1_789_655_520)

private func makeConfiguration() -> RecordingConfiguration {
    RecordingConfiguration(workspaceID: "uuid-1", title: "Daily", recordedAt: fixedDate,
                           language: "fr", sharingMode: "private", tags: [])
}

/// Drives the flow up to the point where the configuration window is open.
private func flowAwaitingConfiguration() -> RecordingFlow {
    let flow = RecordingFlow(now: { fixedDate })
    _ = flow.handle(.iconClicked)
    _ = flow.handle(.iconClicked)
    return flow
}

@Test func clickingWhileIdleStartsCapturingAndAsksNothing() {
    let flow = RecordingFlow(now: { fixedDate })
    let effects = flow.handle(.iconClicked)
    #expect(effects == [.startCapture, .setIcon(.recording), .setESP32Recording(true)])
    #expect(flow.state == .recording(startedAt: fixedDate))
}

@Test func stoppingAsksForTheConfigurationAfterTheFact() {
    let flow = RecordingFlow(now: { fixedDate })
    _ = flow.handle(.iconClicked)

    #expect(flow.handle(.iconClicked) == [.stopCapture, .setESP32Recording(false),
                                          .setIcon(.uploading),
                                          .showConfigurationWindow(startedAt: fixedDate)])
    #expect(flow.state == .configuring(startedAt: fixedDate))
}

@Test func theMeetingDateIsTheInstantCaptureBeganNotTheInstantItStopped() {
    let flow = flowAwaitingConfiguration()
    guard case let .configuring(startedAt) = flow.state else {
        Issue.record("expected .configuring")
        return
    }
    #expect(startedAt == fixedDate)
}

@Test func clickingWhileTheWindowIsOpenOnlyBringsItBack() {
    let flow = flowAwaitingConfiguration()
    #expect(flow.handle(.iconClicked) == [.focusConfigurationWindow])
    #expect(flow.state == .configuring(startedAt: fixedDate))
}

@Test func confirmingHandsTheRecordingToTheUploadQueue() {
    let flow = flowAwaitingConfiguration()
    let configuration = makeConfiguration()

    #expect(flow.handle(.configurationConfirmed(configuration)) == [.enqueueUpload(configuration), .setIcon(.idle)])
    // The upload runs in the background; the flow is free for the next meeting.
    #expect(flow.state == .idle)
}

@Test func aClickAfterConfirmingStartsTheNextMeeting() {
    let flow = flowAwaitingConfiguration()
    _ = flow.handle(.configurationConfirmed(makeConfiguration()))
    #expect(flow.handle(.iconClicked) == [.startCapture, .setIcon(.recording), .setESP32Recording(true)])
}

@Test func cancellingThrowsTheRecordingAway() {
    let flow = flowAwaitingConfiguration()
    #expect(flow.handle(.configurationCancelled) == [.discardFile, .setIcon(.idle)])
    #expect(flow.state == .idle)
}

@Test func aCaptureThatCouldNotBeFinalisedNeverAsksForAConfiguration() {
    let flow = flowAwaitingConfiguration()

    #expect(flow.handle(.captureFailed("The sound could not be recorded.")) == [.setIcon(.idle)])
    #expect(flow.state == .failed(message: "The sound could not be recorded."))
    // Nothing is configured or uploaded from here.
    #expect(flow.handle(.configurationConfirmed(makeConfiguration())) == [])
}

@Test func dismissingACaptureFailureMovesTheFileToTheSaveFolder() {
    let flow = flowAwaitingConfiguration()
    _ = flow.handle(.captureFailed("boom"))

    #expect(flow.handle(.failureDismissed) == [.moveFileToSaveFolder, .setIcon(.idle)])
    #expect(flow.state == .idle)
}
