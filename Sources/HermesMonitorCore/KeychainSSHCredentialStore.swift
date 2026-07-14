import Foundation
#if canImport(Security)
import Security
#endif

public struct SSHCredential: Codable, Equatable, Sendable {
    public let privateKey: Data
    public let passphrase: String?

    public init(privateKey: Data, passphrase: String? = nil) {
        self.privateKey = privateKey
        self.passphrase = passphrase
    }
}

public protocol SSHCredentialProviding: Sendable {
    func credential(for reference: SSHCredentialReference) throws -> SSHCredential
}

public enum SSHCredentialStoreError: Error, LocalizedError {
    case unsupportedPlatform
    case credentialNotFound
    case invalidCredentialData
    case keychainFailure(Int32)

    public var errorDescription: String? {
        switch self {
        case .unsupportedPlatform: return "macOS Keychain is unavailable on this platform."
        case .credentialNotFound: return "The requested SSH credential was not found in Keychain."
        case .invalidCredentialData: return "The Keychain item is not a valid SSH credential."
        case .keychainFailure(let status): return "Keychain operation failed with OSStatus \(status)."
        }
    }
}

public final class KeychainSSHCredentialStore: SSHCredentialProviding, @unchecked Sendable {
    public init() {}

    public func save(_ credential: SSHCredential, for reference: SSHCredentialReference) throws {
        #if canImport(Security)
        let encoded = try JSONEncoder().encode(credential)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: reference.service,
            kSecAttrAccount as String: reference.account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: encoded,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var insertion = query
            attributes.forEach { insertion[$0.key] = $0.value }
            let addStatus = SecItemAdd(insertion as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw SSHCredentialStoreError.keychainFailure(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw SSHCredentialStoreError.keychainFailure(updateStatus)
        }
        #else
        throw SSHCredentialStoreError.unsupportedPlatform
        #endif
    }

    public func credential(for reference: SSHCredentialReference) throws -> SSHCredential {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: reference.service,
            kSecAttrAccount as String: reference.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            throw SSHCredentialStoreError.credentialNotFound
        }
        guard status == errSecSuccess else {
            throw SSHCredentialStoreError.keychainFailure(status)
        }
        guard let data = item as? Data,
              let credential = try? JSONDecoder().decode(SSHCredential.self, from: data) else {
            throw SSHCredentialStoreError.invalidCredentialData
        }
        return credential
        #else
        throw SSHCredentialStoreError.unsupportedPlatform
        #endif
    }

    public func removeCredential(for reference: SSHCredentialReference) throws {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: reference.service,
            kSecAttrAccount as String: reference.account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SSHCredentialStoreError.keychainFailure(status)
        }
        #else
        throw SSHCredentialStoreError.unsupportedPlatform
        #endif
    }
}
