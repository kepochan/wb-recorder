import Foundation
import Testing
@testable import RecorderCore

@Test func recordingTurnsTheDisplayRedAndStoppingTurnsItBlack() async throws {
    let session = FakeSession()
    let display = ESP32Display(host: "10.93.1.238", session: session)

    await display.setRecording(true)
    await display.setRecording(false)

    #expect(session.calls.count == 2)
    let first = try #require(session.calls.first?.request)
    #expect(first.url?.absoluteString == "http://10.93.1.238/display")
    #expect(first.httpMethod == "POST")
    #expect(first.value(forHTTPHeaderField: "Content-Type") == "application/json")

    let redBody = try #require(first.httpBody)
    let red = try #require(try JSONSerialization.jsonObject(with: redBody) as? [String: String])
    #expect(red["bg"] == "FF0000")

    let blackBody = try #require(session.calls.last?.request.httpBody)
    let black = try #require(try JSONSerialization.jsonObject(with: blackBody) as? [String: String])
    #expect(black["bg"] == "000000")
}

@Test func noHostMeansNoRequest() async {
    let session = FakeSession()
    await ESP32Display(host: nil, session: session).setRecording(true)
    #expect(session.calls.isEmpty)
}
