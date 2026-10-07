import Foundation
import os
import Security

/// The API key, in the data-protection Keychain under an access group shared by the app
/// and the extension. One item per server profile, named by the profile id.
public enum Keychain {
    public enum ReadResult: Equatable, Sendable {
        case found(String)
        case notFound
        /// The Keychain could not be read right now, e.g. a signing problem (-34018). Not a
        /// reason to forget anything.
        case unavailable(OSStatus)
    }

    public struct Failure: Error, LocalizedError {
        public var status: OSStatus
        public var errorDescription: String? {
            "Keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown")"
        }
    }

    static let service = "Immich API key"
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ImmountKit", category: "keychain")

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: SharedContainer.keychainGroupID,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    private static func query(for profileID: String) -> [String: Any] {
        var query = baseQuery()
        query[kSecAttrAccount as String] = profileID
        return query
    }

    /// Updates the key in place, adding the item only if it does not exist yet, so a failed
    /// write never loses the previous key.
    public static func setAPIKey(_ key: String, for profileID: String) throws {
        let data = Data(key.utf8)
        var status = SecItemUpdate(query(for: profileID) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query(for: profileID)
            attributes[kSecValueData as String] = data
            // The extension may need the key while the screen is locked.
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            log.error("Saving the API key failed: \(status)")
            throw Failure(status: status)
        }
    }

    public static func apiKey(for profileID: String) -> ReadResult {
        var query = query(for: profileID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return .unavailable(errSecDecode) }
            return .found(String(decoding: data, as: UTF8.self))
        case errSecItemNotFound:
            return .notFound
        default:
            log.error("Reading the API key failed: \(status)")
            return .unavailable(status)
        }
    }

    public static func deleteAPIKey(for profileID: String) {
        let status = SecItemDelete(query(for: profileID) as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            log.error("Deleting the API key failed: \(status)")
        }
    }

    /// Profile ids that have a stored key, to clean up keys left by forgotten profiles.
    public static func storedProfileIDs() -> [String] {
        var query = baseQuery()
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }
}
