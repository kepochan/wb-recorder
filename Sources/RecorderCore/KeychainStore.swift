import Foundation
import Security

public struct KeychainStore {
    public enum Failure: Error, Equatable {
        case unavailable(OSStatus)
        case failed(OSStatus)
    }

    private let service: String
    private let account: String

    public init(service: String = "com.kepochan.whiteboard-recorder", account: String = "api-key") {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    public func save(_ key: String) throws {
        delete()
        var attributes = query
        attributes[kSecValueData as String] = Data(key.utf8)
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            if status == errSecMissingEntitlement || status == errSecNotAvailable {
                throw Failure.unavailable(status)
            }
            throw Failure.failed(status)
        }
    }

    public func read() -> String? {
        var attributes = query
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(attributes as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
