import Foundation

public struct SSHCredentialReference: Codable, Hashable, Sendable {
    public let service: String
    public let account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }
}

public struct SSHConnectionConfiguration: Equatable, Sendable {
    public let host: String
    public let port: Int
    public let username: String
    public let credentialReference: SSHCredentialReference
    public let knownHostsFile: URL?

    public var destination: String { "\(username)@\(host)" }

    public init(
        host: String,
        port: Int = 22,
        username: String,
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
        identityFile: URL
    ) -> [String] {
        var arguments = [
            "-q",
            "-P", String(configuration.port),
            "-i", identityFile.path,
            "-o", "IdentitiesOnly=yes",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "PasswordAuthentication=no",
            "-o", "KbdInteractiveAuthentication=no",
            "-o", "NumberOfPasswordPrompts=0",
            "-o", "BatchMode=no",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=2"
        ]
        if let knownHostsFile = configuration.knownHostsFile {
            arguments += ["-o", "UserKnownHostsFile=\(knownHostsFile.path)"]
        }
        arguments += ["-b", "-", configuration.destination]
        return arguments
    }

    public static func sshArguments(
        configuration: SSHConnectionConfiguration,
        identityFile: URL,
        remoteCommand: String
    ) -> [String] {
        var arguments = [
            "-q",
            "-p", String(configuration.port),
            "-i", identityFile.path,
            "-o", "IdentitiesOnly=yes",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "PasswordAuthentication=no",
            "-o", "KbdInteractiveAuthentication=no",
            "-o", "NumberOfPasswordPrompts=0",
            "-o", "BatchMode=no",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=2"
        ]
        if let knownHostsFile = configuration.knownHostsFile {
            arguments += ["-o", "UserKnownHostsFile=\(knownHostsFile.path)"]
        }
        arguments += [configuration.destination, remoteCommand]
        return arguments
    }
}
