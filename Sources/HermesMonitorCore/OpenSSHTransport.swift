import Foundation

public protocol RemoteFileTransport: Sendable {
    func metadata(for remotePath: String) async throws -> RemoteFileMetadata
    func download(remotePath: String, to localURL: URL) async throws
    func downloadTail(remotePath: String, to localURL: URL, byteLimit: Int) async throws
}

public extension RemoteFileTransport {
    func downloadTail(remotePath: String, to localURL: URL, byteLimit: Int) async throws {
        try await download(remotePath: remotePath, to: localURL)
    }
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
            let command = "/usr/bin/stat --printf='Size: %s\\nModify: %y\\n' -- " +
                (try shellQuoted(remotePath))
            let output = try runSSH(remoteCommand: command)
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

    public func downloadTail(remotePath: String, to localURL: URL, byteLimit: Int) async throws {
        try validate(remotePath: remotePath)
        guard byteLimit > 0 else {
            try Data().write(to: localURL, options: .atomic)
            return
        }

        let remoteMetadata = try await metadata(for: remotePath)
        let offset = max(0, remoteMetadata.size - Int64(byteLimit))
        guard offset > 0 else {
            try await download(remotePath: remotePath, to: localURL)
            return
        }

        try await Task.detached(priority: .utility) { [self] in
            try fileManager.createDirectory(
                at: localURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let resumeURL = localURL.deletingLastPathComponent()
                .appendingPathComponent(".\(localURL.lastPathComponent).\(UUID().uuidString).tail")
            defer { try? fileManager.removeItem(at: resumeURL) }

            _ = fileManager.createFile(atPath: resumeURL.path, contents: nil)
            let writeHandle = try FileHandle(forWritingTo: resumeURL)
            try writeHandle.truncate(atOffset: UInt64(offset))
            try writeHandle.close()

            _ = try runSFTP(
                batchCommand: "reget \(try quoted(remotePath)) \(try quoted(resumeURL.path))\n"
            )

            try Self.installDownloadedTail(
                from: resumeURL,
                offset: UInt64(offset),
                byteLimit: byteLimit,
                to: localURL
            )
        }.value
    }

    static func installDownloadedTail(
        from transferURL: URL,
        offset: UInt64,
        byteLimit: Int,
        to localURL: URL
    ) throws {
        let readHandle = try FileHandle(forReadingFrom: transferURL)
        defer { try? readHandle.close() }
        try readHandle.seek(toOffset: offset)
        let tail = try readHandle.read(upToCount: max(0, byteLimit)) ?? Data()
        try tail.write(to: localURL, options: .atomic)
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
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private func shellQuoted(_ value: String) throws -> String {
        guard !value.contains("\n"), !value.contains("\r"), !value.contains("\0") else {
            throw OpenSSHTransportError.invalidRemotePath(value)
        }
        return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func runSFTP(batchCommand: String) throws -> String {
        try runOpenSSH(
            executable: "/usr/bin/sftp",
            standardInput: Data(batchCommand.utf8)
        ) { identityFile in
            OpenSSHArgumentBuilder.sftpArguments(
                configuration: configuration,
                identityFile: identityFile
            )
        }
    }

    private func runSSH(remoteCommand: String) throws -> String {
        try runOpenSSH(executable: "/usr/bin/ssh", standardInput: nil) { identityFile in
            OpenSSHArgumentBuilder.sshArguments(
                configuration: configuration,
                identityFile: identityFile,
                remoteCommand: remoteCommand
            )
        }
    }

    private func runOpenSSH(
        executable: String,
        standardInput: Data?,
        arguments: (URL) -> [String]
    ) throws -> String {
        let credential = try credentials.credential(for: configuration.credentialReference)
        guard !credential.privateKey.isEmpty else {
            throw OpenSSHTransportError.emptyPrivateKey
        }

        let stager = SSHCredentialStager(fileManager: fileManager)
        let staged = try stager.stage(credential)
        defer { stager.remove(staged) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments(staged.identityFile)

        var environment = ProcessInfo.processInfo.environment
        if let passphrase = credential.passphrase, !passphrase.isEmpty {
            guard let askPassFile = staged.askPassFile else {
                throw OpenSSHTransportError.emptyPrivateKey
            }
            environment["SSH_ASKPASS"] = askPassFile.path
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment["DISPLAY"] = "HermesMonitor"
            environment["HERMES_MONITOR_SSH_PASSPHRASE"] = passphrase
        }
        process.environment = environment

        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.standardInput = standardInput == nil ? FileHandle.nullDevice : input
        process.standardOutput = output
        process.standardError = error

        try process.run()
        if let standardInput {
            input.fileHandleForWriting.write(standardInput)
            try input.fileHandleForWriting.close()
        }
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
                executable: executable,
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

    public func tail(
        taskID: String,
        lineLimit: Int = 200,
        byteLimit: Int = 64 * 1_024
    ) async throws -> [String] {
        guard lineLimit > 0 else { return [] }
        let remotePath = try pathPolicy.workerLogPath(taskID: taskID)
        let localURL = cacheDirectory.appendingPathComponent("\(taskID).log")
        try await transport.downloadTail(
            remotePath: remotePath,
            to: localURL,
            byteLimit: byteLimit
        )
        let data = try Data(contentsOf: localURL, options: .mappedIfSafe)
        return LogTailParser.lines(from: data, limit: lineLimit)
    }
}
