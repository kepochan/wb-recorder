import Foundation

/// Optional companion screen: red while recording, black otherwise.
/// Every failure is swallowed — a missing gadget must never block a meeting.
public struct ESP32Display {
    private let host: String?
    private let session: HTTPSession

    public init(host: String?, session: HTTPSession = URLSession.shared) {
        self.host = host
        self.session = session
    }

    public func setRecording(_ isRecording: Bool) async {
        guard let host, !host.isEmpty,
              let url = URL(string: "http://\(host)/display") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 2
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "bg": isRecording ? "FF0000" : "000000",
            "text": "",
            "textColor": "white"
        ])

        _ = try? await session.data(for: request)
    }
}
