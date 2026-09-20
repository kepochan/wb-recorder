import Foundation
import Testing
@testable import RecorderCore

@Test func multipartWritesFieldsAndFileWithCRLF() throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let audio = tmp.appendingPathComponent("rec.m4a")
    try Data("AUDIOBYTES".utf8).write(to: audio)

    var body = MultipartBody(boundary: "BDRY")
    body.addFile("audio", url: audio, filename: "rec.m4a", contentType: "audio/mp4")
    body.addField("title", "Daily")

    let envelope = tmp.appendingPathComponent("envelope")
    try body.write(to: envelope)

    let written = try String(contentsOf: envelope, encoding: .utf8)
    let expected = [
        "--BDRY",
        "Content-Disposition: form-data; name=\"audio\"; filename=\"rec.m4a\"",
        "Content-Type: audio/mp4",
        "",
        "AUDIOBYTES",
        "--BDRY",
        "Content-Disposition: form-data; name=\"title\"",
        "",
        "Daily",
        "--BDRY--",
        ""
    ].joined(separator: "\r\n")

    #expect(written == expected)
    #expect(body.contentType == "multipart/form-data; boundary=BDRY")
}

@Test func multipartGeneratesAUniqueBoundaryByDefault() {
    #expect(MultipartBody().boundary != MultipartBody().boundary)
}
