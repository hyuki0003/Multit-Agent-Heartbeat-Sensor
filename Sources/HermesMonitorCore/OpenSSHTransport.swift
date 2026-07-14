import Foundation

public protocol RemoteFileTransport: Sendable {
    func metadata(for remotePath: String) async throws -> RemoteFileMetadata
    func download(remotePath: String, to localURL: URL) async throws
}

public enum OpenSSHTransportError: Error, LocalizedError {
    case invalidRemotePath(String)
    case processFailed(executable: String, status: Int32, output: String)
    case emptyPrivateKey

    public var errorDescription: String? {
        switch self {
        case .invalidRemotePath(let path):
            return "Refusing SSH/SFTP access outside the approved path set: \(path)"
        case .processFailed(let executable, let status, let output):
            return "\(executable) exited with status \(status): \(output)"
        case .emptyPrivateKey:
            return "The Keychain SSH private key is empty."
        }
    }
}

public final class OpenSSHTransport: RemoteFileTransport, @unchecked Sendable {
    private let configuration: SSHConnectionConfiguration
    private let credentials: any SSHCredentialProviding
    private let pathPolicy: RemotePathPolicy
    private let fileManager: FileManager

    public init(
        configuration: SSHConnectionConfiguration,
        credentials: any SSHCredentialProviding = KeychainSSHCredentialStore(),
        pathPolicy: RemotePathPolicy = RemotePathPolicy(),
        fileManager: FileManager = .default
    ) {
        self.configuration = configuration
        self.credentials = credentials
        self.pathPolicy = pathPolicy
        self.fileManager = fileManager
    }

    public func metadata(for remotePath: String) async throws -> RemoteFileMetadata {
        try validate(remotePath: remotePath)
        return try await Task.detached(priority: .utility) { [self] in
            let output = try runSFTP(batchCommand: "ls -ln \(try quoted(remotePath))\n")
            return try SFTPStatParser.parse(output: output, path: remotePath)
        }.value
    }

    public func download(remotePath: String, to localURL: URL) async throws {
        try validate(remotePath: remotePath)
        try await Task.detached(priority: .utility) { [self] in
            try fileManager.createDirectory(
                at: localURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            _ = try runSFTP(
                batchCommand: "get \(try quoted(remotePath)) \(try quoted(localURL.path))\n"
            )
        }.value
    }

    private func validate(remotePath: String) throws {
        if remotePath == RemotePathPolicy.kanbanDatabase ||
            remotePath == RemotePathPolicy.stateDatabase {
            _ = try pathPolicy.validateDatabasePath(remotePath)
            return
        }
        let prefix = RemotePathPolicy.workerLogsDirectory + "/"
        guard remotePath.hasPrefix(prefix) else {
            throw OpenSSHTransportError.invalidRemotePath(remotePath)
        }
        let taskID = String(remotePath.dropFirst(prefix.count).dropLast(".log".count))
        guard remotePath.hasSuffix(".log"),
              (try? pathPolicy.workerLogPath(taskID: taskID)) == remotePath else {
            throw OpenSSHTransportError.invalidRemotePath(remotePath)
        }
    }

    private func quoted(_ value: String) throws -> String {
        guard !value.contains("\n"), !value.contains("\r"), !value.contains("\0") else {
            throw OpenSSHTransportError.invalidRemotePath(value)
        }
        return "\"\(value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    private func runSFTP(batchCommand: String) throws -> String {
        let credential = try credentials.credential(for: configuration.credentialReference)
        guard !credential.privateKey.isEmpty else {
            throw OpenSSHTransportError.emptyPrivateKey
        }

        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("HermesMonitor-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let identityURL = temporaryDirectory.appendingPathComponent("identity")
        try credential.privateKey.write(to: identityURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: identityURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sftp")
        process.arguments = OpenSSHArgumentBuilder.sftpArguments(
            configuration: configuration,
            identityFile: identityURL
        )

        var environment = ProcessInfo.processInfo.environment
        if let passphrase = credential.passphrase, !passphrase.isEmpty {
            let askPassURL = temporaryDirectory.appendingPathComponent("askpass.sh")
            let askPass = "#!/bin/sh\nprintf '%s\\n' \"$HERMES_MONITOR_SSH_PASSPHRASE\"\n"
            try Data(askPass.utf8).write(to: askPassURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: askPassURL.path)
            environment["SSH_ASKPASS"] = askPassURL.path
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment["DISPLAY"] = "HermesMonitor"
            environment["HERMES_MONITOR_SSH_PASSPHRASE"] = passphrase
        }
        process.environment = environment

        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error

        try process.run()
        input.fileHandleForWriting.write(Data(batchCommand.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()

        let standardOutput = output.fileHandleForReading.readDataToEndOfFile()
        let standardError = error.fileHandleForReading.readDataToEndOfFile()
        let outputText = String(decoding: standardOutput, as: UTF8.self)
        let errorText = String(decoding: standardError, as: UTF8.self)

        guard process.terminationStatus == 0 else {
            let combined = [outputText, errorText]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            throw OpenSSHTransportError.processFailed(
                executable: "/usr/bin/sftp",
                status: process.terminationStatus,
                output: combined
            )
        }
        return outputText
    }
}

public struct WorkerLogTailer: Sendable {
    private let transport: any RemoteFileTransport
    private let pathPolicy: RemotePathPolicy
    private let cacheDirectory: URL

    public init(
        transport: any RemoteFileTransport,
        cacheDirectory: URL,
        pathPolicy: RemotePathPolicy = RemotePathPolicy()
    ) {
        self.transport = transport
        self.cacheDirectory = cacheDirectory
        self.pathPolicy = pathPolicy
    }

    public func tail(taskID: String, lineLimit: Int = 200) async throws -> [String] {
        guard lineLimit > 0 else { return [] }
        let remotePath = try pathPolicy.workerLogPath(taskID: taskID)
        let localURL = cacheDirectory.appendingPathComponent("\(taskID).log")
        try await transport.download(remotePath: remotePath, to: localURL)
        let data = try Data(contentsOf: localURL, options: .mappedIfSafe)
        return LogTailParser.lines(from: data, limit: lineLimit)
    }
}
