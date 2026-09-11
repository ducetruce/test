import Foundation
import Security

/// Minimal Keychain wrapper for the app's credentials and ring authentication key.
enum Keychain {
    private static let service = "com.openring.tokens"

    /// Why a write failed, carried out of the Keychain rather than collapsed into `false`.
    ///
    /// The Keychain has several distinct failure causes and only one of them is the user's to
    /// fix. Reporting the wrong one sends people to look in the wrong place: a build with no
    /// entitlement fails identically to a locked device unless the status is kept, and the
    /// advice for the two is opposite.
    struct WriteFailure: Swift.Error, Equatable {
        let status: OSStatus

        /// What actually went wrong, and what — if anything — the user can do about it.
        var cause: String {
            switch status {
            case errSecMissingEntitlement:
                return "this build has no Keychain entitlement, so it cannot use secure storage at all. "
                    + "That is a signing problem in the build, not something to fix on the device"
            case errSecInteractionNotAllowed:
                return "the device was locked. Unlock it and try again"
            case errSecNotAvailable:
                return "the Keychain was not available. Unlock the device and try again"
            case errSecAuthFailed:
                return "the Keychain refused authentication"
            case errSecParam, errSecDecode:
                return "the Keychain rejected the request as malformed"
            case errSecDuplicateItem:
                return "an existing entry could be neither updated nor replaced"
            default:
                return "the Keychain refused the write"
            }
        }
    }

    /// Atomically replaces an existing value. Never delete first: if an add then failed,
    /// a transient Keychain error would destroy the only copy of a single-use refresh token
    /// or ring key.
    @discardableResult
    static func set(_ value: String, account: String) -> Result<Void, WriteFailure> {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return .success(()) }
        guard updateStatus == errSecItemNotFound else { return .failure(WriteFailure(status: updateStatus)) }

        var newItem = query
        attributes.forEach { newItem[$0.key] = $0.value }
        let addStatus = SecItemAdd(newItem as CFDictionary, nil)
        if addStatus == errSecSuccess { return .success(()) }

        // Another writer may have inserted the item between update and add.
        if addStatus == errSecDuplicateItem {
            let retry = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            return retry == errSecSuccess ? .success(()) : .failure(WriteFailure(status: retry))
        }
        return .failure(WriteFailure(status: addStatus))
    }

    /// Note that a read failure is indistinguishable from "nothing stored" here, so an
    /// unsigned build reports itself as signed out rather than as broken. Writes are where
    /// the distinction is made, because that is where the user is told something.
    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

extension Result where Success == Void, Failure == Keychain.WriteFailure {
    var succeeded: Bool {
        if case .success = self { return true }
        return false
    }

    var failure: Keychain.WriteFailure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}
