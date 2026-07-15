import Foundation
#if canImport(Security)
import Security
#endif

public struct SSHCredential: Codable, Equatable, Sendable {
    public let privateKey: Data?
    public let passphrase: String?
    public let password: String?

    public init(privateKey: Data, passphrase: String? = nil) {
        self.privateKey = privateKey
        self.passphrase = passphrase
        self.password = nil
    }

    public init(password: String) {
        self.privateKey = nil
        self.passphrase = nil
        self.password = password
    }

    public func validate(for authenticationMode: SSHAuthenticationMode) throws {
        switch authenticationMode {
        case .privateKey:
            guard let privateKey, !privateKey.isEmpty else {
                throw SSHCredentialValidationError.emptyPrivateKey
            }
        case .password:
            guard let password, !password.isEmpty else {
                throw SSHCredentialValidationError.emptyPassword
            }
        }
    }

    func askPassSecret(for authenticationMode: SSHAuthenticationMode) -> String? {
        switch authenticationMode {
        case .privateKey:
            guard let passphrase, !passphrase.isEmpty else { return nil }
            return passphrase
        case .password:
            guard let password, !password.isEmpty else { return nil }
            return password
        }
    }
}

public enum SSHCredentialValidationError: Error, Equatable, LocalizedError {
    case emptyPrivateKey
    case emptyPassword

    public var errorDescription: String? {
        switch self {
        case .emptyPrivateKey:
            return "The selected Keychain SSH private key is empty."
        case .emptyPassword:
            return "The selected Keychain SSH password is empty."
        }
    }
}

public enum SSHCredentialSaveTransaction {
    public static func save(
        _ credential: SSHCredential,
        selection: SSHCredentialSelection,
        using saveCredential: (SSHCredential, SSHCredentialReference) throws -> Void,
        commit: (SSHCredentialSelection) -> Void
    ) throws {
        try credential.validate(for: selection.authenticationMode)
        try saveCredential(credential, selection.reference)
        commit(selection)
    }
}

public enum SSHCredentialEditorSaveTransaction {
    public static func save(
        resolveSelection: () throws -> SSHCredentialSelection,
        makeCredential: (SSHAuthenticationMode) throws -> SSHCredential,
        using saveCredential: (SSHCredential, SSHCredentialReference) throws -> Void,
        commit: (SSHCredentialSelection) -> Void,
        cleanup: () -> Void
    ) throws {
        defer { cleanup() }
        let selection = try resolveSelection()
        let credential = try makeCredential(selection.authenticationMode)
        try SSHCredentialSaveTransaction.save(
            credential,
            selection: selection,
            using: saveCredential,
            commit: commit
        )
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
