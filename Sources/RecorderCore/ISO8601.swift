import Foundation

public enum ISO8601 {
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    public static func string(from date: Date) -> String {
        formatter.string(from: date)
    }
}
