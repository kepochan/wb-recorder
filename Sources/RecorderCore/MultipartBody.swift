import Foundation

/// Builds a multipart/form-data envelope on disk so large audio files are
/// streamed by URLSession instead of being held in memory.
public struct MultipartBody {
    private enum Part {
        case field(name: String, value: String)
        case file(name: String, url: URL, filename: String, contentType: String)
    }

    public let boundary: String
    private var parts: [Part] = []

    public init(boundary: String = "wbr-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    public var contentType: String {
        "multipart/form-data; boundary=\(boundary)"
    }

    public mutating func addField(_ name: String, _ value: String) {
        parts.append(.field(name: name, value: value))
    }

    public mutating func addFile(_ name: String, url: URL, filename: String, contentType: String) {
        parts.append(.file(name: name, url: url, filename: filename, contentType: contentType))
    }

    public func write(to destination: URL) throws {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let out = try FileHandle(forWritingTo: destination)
        defer { try? out.close() }

        for part in parts {
            switch part {
            case let .field(name, value):
                try out.write(contentsOf: Data("""
                --\(boundary)\r
                Content-Disposition: form-data; name="\(name)"\r
                \r
                \(value)\r\n
                """.utf8))
            case let .file(name, url, filename, contentType):
                try out.write(contentsOf: Data("""
                --\(boundary)\r
                Content-Disposition: form-data; name="\(name)"; filename="\(filename)"\r
                Content-Type: \(contentType)\r
                \r\n
                """.utf8))
                let input = try FileHandle(forReadingFrom: url)
                defer { try? input.close() }
                while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
                    try out.write(contentsOf: chunk)
                }
                try out.write(contentsOf: Data("\r\n".utf8))
            }
        }
        try out.write(contentsOf: Data("--\(boundary)--\r\n".utf8))
    }
}
