import Foundation

public enum SSHAuthenticationMode: String, Codable, CaseIterable, Hashable, Sendable {
    case privateKey
    case password
}

public struct SSHCredentialReference: Codable, Hashable, Sendable {
    public let service: String
    public let account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    public static func resolvedAccount(
        _ storedAccount: String?,
        username: String,
        host: String
    ) -> String {
        guard let storedAccount, !storedAccount.isEmpty else {
            return "\(username)@\(host)"
        }
        return storedAccount
    }
}

public struct SSHCredentialSelection: Equatable, Sendable {
    public let authenticationMode: SSHAuthenticationMode
    public let reference: SSHCredentialReference

    public init(
        authenticationMode: SSHAuthenticationMode,
        reference: SSHCredentialReference
    ) {
        self.authenticationMode = authenticationMode
        self.reference = reference
    }
}

public struct SSHCredentialSelectionDraft: Equatable, Sendable {
    public var authenticationMode: SSHAuthenticationMode
    public var keychainService: String
    public var keychainAccount: String

    private let originalAuthenticationMode: SSHAuthenticationMode
    private let originalKeychainService: String
    private let originalKeychainAccount: String

    public init(
        authenticationMode: SSHAuthenticationMode,
        keychainService: String,
        keychainAccount: String
    ) {
        self.authenticationMode = authenticationMode
        self.keychainService = keychainService
        self.keychainAccount = keychainAccount
        self.originalAuthenticationMode = authenticationMode
        self.originalKeychainService = keychainService
        self.originalKeychainAccount = keychainAccount
    }

    public mutating func cancel() {
        authenticationMode = originalAuthenticationMode
        keychainService = originalKeychainService
        keychainAccount = originalKeychainAccount
    }
}

public struct SSHCredentialPreferenceSnapshot: Equatable, Sendable {
    public static let defaultKeychainService = "com.hermes.monitor.ssh"

    public let host: String
    public let username: String
    public let authenticationModeValue: String
    public let keychainService: String
    public let keychainAccountOverride: String?
    public let isHostEnvironmentControlled: Bool
    public let isUsernameEnvironmentControlled: Bool
    public let isAuthenticationModeEnvironmentControlled: Bool
    public let isKeychainServiceEnvironmentControlled: Bool
    public let isKeychainAccountEnvironmentControlled: Bool

    public var authenticationMode: SSHAuthenticationMode? {
        SSHAuthenticationMode(rawValue: authenticationModeValue)
    }

    public func requireAuthenticationMode() throws -> SSHAuthenticationMode {
        guard let authenticationMode else {
            throw SSHAuthenticationModeResolutionError.invalidValue(authenticationModeValue)
        }
        return authenticationMode
    }

    /// Runtime validation checks authentication mode first so an invalid environment override
    /// is reported before missing connection fields or any credential access.
    public func validatedRuntimeCredentialSelection() throws -> SSHCredentialSelection {
        let authenticationMode = try requireAuthenticationMode()
        guard !host.isEmpty else {
            throw SSHCredentialPreferenceValidationError.missingHost
        }
        return SSHCredentialSelection(
            authenticationMode: authenticationMode,
            reference: SSHCredentialReference(
                service: keychainService,
                account: keychainAccount
            )
        )
    }

    public var keychainAccount: String {
        SSHCredentialReference.resolvedAccount(
            keychainAccountOverride,
            username: username,
            host: host
        )
    }

    public var credentialSelection: SSHCredentialSelection? {
        guard let authenticationMode else { return nil }
        return SSHCredentialSelection(
            authenticationMode: authenticationMode,
            reference: SSHCredentialReference(
                service: keychainService,
                account: keychainAccount
            )
        )
    }

    public static func resolve(
        storedHost: String?,
        storedUsername: String?,
        storedAuthenticationMode: String?,
        storedKeychainService: String?,
        storedKeychainAccount: String?,
        environment: [String: String],
        fallbackUsername: String
    ) -> SSHCredentialPreferenceSnapshot {
        let host = environment["HERMES_MONITOR_HOST"] ?? storedHost ?? ""
        let usernameValue = environment["HERMES_MONITOR_USERNAME"] ?? storedUsername
        let username = usernameValue.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackUsername

        return SSHCredentialPreferenceSnapshot(
            host: host,
            username: username,
            authenticationModeValue: environment["HERMES_MONITOR_AUTHENTICATION_MODE"]
                ?? storedAuthenticationMode
                ?? SSHAuthenticationMode.privateKey.rawValue,
            keychainService: environment["HERMES_MONITOR_KEYCHAIN_SERVICE"]
                ?? storedKeychainService
                ?? defaultKeychainService,
            keychainAccountOverride: environment["HERMES_MONITOR_KEYCHAIN_ACCOUNT"]
                ?? storedKeychainAccount,
            isHostEnvironmentControlled: environment["HERMES_MONITOR_HOST"] != nil,
            isUsernameEnvironmentControlled: environment["HERMES_MONITOR_USERNAME"] != nil,
            isAuthenticationModeEnvironmentControlled:
                environment["HERMES_MONITOR_AUTHENTICATION_MODE"] != nil,
            isKeychainServiceEnvironmentControlled:
                environment["HERMES_MONITOR_KEYCHAIN_SERVICE"] != nil,
            isKeychainAccountEnvironmentControlled:
                environment["HERMES_MONITOR_KEYCHAIN_ACCOUNT"] != nil
        )
    }
}

public enum SSHAuthenticationModeResolutionError: Error, Equatable, LocalizedError {
    case invalidValue(String)

    public var errorDescription: String? {
        switch self {
        case .invalidValue(let value):
            return "Invalid SSH authentication mode: \(value)."
        }
    }
}

public enum SSHCredentialPreferenceValidationError: Error, Equatable {
    case missingHost
}

public struct SSHConnectionConfiguration: Equatable, Sendable {
    public let host: String
    public let port: Int
    public let username: String
    public let authenticationMode: SSHAuthenticationMode
    public let credentialReference: SSHCredentialReference
    public let knownHostsFile: URL?

    public var destination: String { "\(username)@\(host)" }

    public init(
        host: String,
        port: Int = 22,
        username: String,
        authenticationMode: SSHAuthenticationMode = .privateKey,
        credentialReference: SSHCredentialReference,
        knownHostsFile: URL? = nil
    ) throws {
        let hostCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-:"))
        let userCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard !host.isEmpty, host.unicodeScalars.allSatisfy(hostCharacters.contains) else {
            throw SSHConfigurationError.invalidHost(host)
        }
        guard !username.isEmpty, username.unicodeScalars.allSatisfy(userCharacters.contains) else {
            throw SSHConfigurationError.invalidUsername(username)
        }
        guard (1...65_535).contains(port) else {
            throw SSHConfigurationError.invalidPort(port)
        }
        guard !credentialReference.service.isEmpty, !credentialReference.account.isEmpty,
              !credentialReference.service.contains(where: { $0.isNewline || $0 == "\0" }),
              !credentialReference.account.contains(where: { $0.isNewline || $0 == "\0" }) else {
            throw SSHConfigurationError.invalidCredentialReference
        }
        if let knownHostsFile, !knownHostsFile.path.hasPrefix("/") {
            throw SSHConfigurationError.knownHostsPathMustBeAbsolute(knownHostsFile.path)
        }

        self.host = host
        self.port = port
        self.username = username
        self.authenticationMode = authenticationMode
        self.credentialReference = credentialReference
        self.knownHostsFile = knownHostsFile
    }
}

public enum SSHConfigurationError: Error, Equatable, LocalizedError {
    case invalidHost(String)
    case invalidUsername(String)
    case invalidPort(Int)
    case invalidCredentialReference
    case knownHostsPathMustBeAbsolute(String)

    public var errorDescription: String? {
        switch self {
        case .invalidHost(let host): return "Invalid SSH host: \(host)"
        case .invalidUsername(let username): return "Invalid SSH username: \(username)"
        case .invalidPort(let port): return "Invalid SSH port: \(port)"
        case .invalidCredentialReference: return "Keychain service and account must be non-empty."
        case .knownHostsPathMustBeAbsolute(let path): return "known_hosts path must be absolute: \(path)"
        }
    }
}

public enum OpenSSHArgumentBuilder {
    public static func sftpArguments(
        configuration: SSHConnectionConfiguration,
        identityFile: URL?
    ) -> [String] {
        var arguments = ["-P", String(configuration.port)]
        arguments += authenticationArguments(
            configuration: configuration,
            identityFile: identityFile
        )
        arguments += connectionArguments(configuration: configuration)
        if let knownHostsFile = configuration.knownHostsFile {
            arguments += ["-o", "UserKnownHostsFile=\(knownHostsFile.path)"]
        }
        arguments += ["-b", "-", configuration.destination]
        return arguments
    }

    public static func sshArguments(
        configuration: SSHConnectionConfiguration,
        identityFile: URL?,
        remoteCommand: String
    ) -> [String] {
        var arguments = ["-p", String(configuration.port)]
        arguments += authenticationArguments(
            configuration: configuration,
            identityFile: identityFile
        )
        arguments += connectionArguments(configuration: configuration)
        if let knownHostsFile = configuration.knownHostsFile {
            arguments += ["-o", "UserKnownHostsFile=\(knownHostsFile.path)"]
        }
        arguments += [configuration.destination, remoteCommand]
        return arguments
    }

    private static func authenticationArguments(
        configuration: SSHConnectionConfiguration,
        identityFile: URL?
    ) -> [String] {
        switch configuration.authenticationMode {
        case .privateKey:
            var arguments: [String] = []
            if let identityFile {
                arguments += ["-i", identityFile.path]
            }
            arguments += [
                "-o", "IdentitiesOnly=yes",
                "-o", "StrictHostKeyChecking=yes",
                "-o", "PasswordAuthentication=no",
                "-o", "KbdInteractiveAuthentication=no",
                "-o", "NumberOfPasswordPrompts=0",
                "-o", "BatchMode=no"
            ]
            return arguments
        case .password:
            return [
                "-o", "PubkeyAuthentication=no",
                "-o", "PreferredAuthentications=password",
                "-o", "StrictHostKeyChecking=yes",
                "-o", "PasswordAuthentication=yes",
                "-o", "KbdInteractiveAuthentication=no",
                "-o", "NumberOfPasswordPrompts=1",
                "-o", "BatchMode=no"
            ]
        }
    }

    private static func connectionArguments(
        configuration: SSHConnectionConfiguration
    ) -> [String] {
        [
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=2"
        ]
    }
}
