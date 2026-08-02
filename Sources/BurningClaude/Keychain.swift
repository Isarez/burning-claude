import Foundation
import Security

/// The login keychain, used for the one secret this app ever handles: a
/// claude.ai session cookie the user pastes in themselves.
///
/// Deliberately the *only* place a session key is written. It never reaches
/// `UserDefaults`, the JSON files under Application Support, or a log line —
/// those hold account identifiers and usage counts, and adding a credential to
/// them would turn a plainly readable state directory into something worth
/// stealing.
enum Keychain {

    /// Kept distinct from the bundle identifier so a rename of the app cannot
    /// silently orphan every stored key.
    private static let service = "com.local.claudetokenmeter.sessionkey"

    enum Failure: LocalizedError {
        case status(OSStatus)

        var errorDescription: String? {
            guard case .status(let code) = self else { return nil }
            let detail = SecCopyErrorMessageString(code, nil) as String?
            return "Keychain error \(code)" + (detail.map { ": \($0)" } ?? "")
        }
    }

    private static func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Stores or replaces the secret for an account.
    static func save(_ secret: String, account: String) throws {
        let data = Data(secret.utf8)
        let status = SecItemUpdate(
            query(account: account) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )

        if status == errSecItemNotFound {
            var insert = query(account: account)
            insert[kSecValueData as String] = data
            let added = SecItemAdd(insert as CFDictionary, nil)
            guard added == errSecSuccess else { throw Failure.status(added) }
            return
        }
        guard status == errSecSuccess else { throw Failure.status(status) }
    }

    /// Returns the stored secret, or `nil` if there is none — including when the
    /// user denied the keychain prompt, which is a refusal rather than an error
    /// worth propagating on every refresh.
    static func read(account: String) -> String? {
        var lookup = query(account: account)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Removes the secret. A missing item is success: the caller's intent is
    /// that nothing remains stored, and that is already true.
    @discardableResult
    static func delete(account: String) -> Bool {
        let status = SecItemDelete(query(account: account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
