import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public protocol RemoteFileTransport: Sendable {
    func metadata(for remotePath: String) async throws -> RemoteFileMetadata
    func download(remotePath: String, to localURL: URL) async throws
    func downloadDatabaseSnapshot(remotePath: String, to localURL: URL) async throws
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
    case processTimedOut(executable: String, timeoutSeconds: Int)
    case emptyPrivateKey
    case emptyPassword
    case missingAskPassHelper
    case missingSnapshotHelper

    public var errorDescription: String? {
        switch self {
        case .invalidRemotePath(let path):
            return "Refusing SSH/SFTP access outside the approved path set: \(path)"
        case .processFailed(let executable, let status, let output):
            return "\(executable) exited with status \(status): \(output)"
        case .processTimedOut(let executable, let timeoutSeconds):
            return "\(executable) exceeded the \(timeoutSeconds)-second database snapshot deadline and was terminated. Check the VPN and SSH gateway, then retry."
        case .emptyPrivateKey:
            return "The Keychain SSH private key is empty."
        case .emptyPassword:
            return "The Keychain SSH password is empty."
        case .missingAskPassHelper:
            return "The private SSH_ASKPASS helper could not be staged."
        case .missingSnapshotHelper:
            return "The bundled remote SQLite snapshot helper is missing."
        }
    }
}

public final class OpenSSHTransport: RemoteFileTransport, @unchecked Sendable {
    private static let snapshotProcessTimeoutSeconds: TimeInterval = 20
    private static let processTerminationGraceSeconds: TimeInterval = 1

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
                (try Self.shellQuoted(remotePath))
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

    public func downloadDatabaseSnapshot(remotePath: String, to localURL: URL) async throws {
        let approvedPath = try pathPolicy.validateDatabasePath(remotePath)
        guard let helperURL = Bundle.module.url(
            forResource: "RemoteSQLiteSnapshot",
            withExtension: "py"
        ) else {
            throw OpenSSHTransportError.missingSnapshotHelper
        }
        let helper = try String(contentsOf: helperURL, encoding: .utf8)
        let remoteCommand = try Self.databaseSnapshotCommand(
            helper: helper,
            remotePath: approvedPath,
            pathPolicy: pathPolicy
        )
        let cancellation = ProcessCancellationController()

        try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) { [self] in
                try cancellation.checkCancellation()
                try streamSSH(
                    remoteCommand: remoteCommand,
                    to: localURL,
                    cancellation: cancellation
                )
            }.value
        } onCancel: {
            cancellation.cancel()
        }
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

    static func databaseSnapshotCommand(
        helper: String,
        remotePath: String,
        pathPolicy: RemotePathPolicy = RemotePathPolicy()
    ) throws -> String {
        let approvedPath = try pathPolicy.validateDatabasePath(remotePath)
        return "/usr/bin/python3 -c \(try shellQuotedScript(helper)) \(try shellQuoted(approvedPath))"
    }

    private static func shellQuotedScript(_ value: String) throws -> String {
        guard !value.contains("\0") else {
            throw OpenSSHTransportError.invalidRemotePath("snapshot helper")
        }
        return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func shellQuoted(_ value: String) throws -> String {
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

    private func streamSSH(
        remoteCommand: String,
        to localURL: URL,
        cancellation: ProcessCancellationController
    ) throws {
        let credential = try credentials.credential(for: configuration.credentialReference)
        do {
            try credential.validate(for: configuration.authenticationMode)
        } catch SSHCredentialValidationError.emptyPrivateKey {
            throw OpenSSHTransportError.emptyPrivateKey
        } catch SSHCredentialValidationError.emptyPassword {
            throw OpenSSHTransportError.emptyPassword
        }

        let stager = SSHCredentialStager(fileManager: fileManager)
        let staged = try stager.stage(
            credential,
            authenticationMode: configuration.authenticationMode
        )
        defer { stager.remove(staged) }

        try fileManager.createDirectory(
            at: localURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? fileManager.removeItem(at: localURL)
        guard fileManager.createFile(atPath: localURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: localURL.path)
        var completed = false
        defer {
            if !completed { try? fileManager.removeItem(at: localURL) }
        }

        let diagnosticsURL = localURL.deletingLastPathComponent()
            .appendingPathComponent(".\(localURL.lastPathComponent).\(UUID().uuidString).stderr")
        guard fileManager.createFile(atPath: diagnosticsURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: diagnosticsURL.path)
        defer { try? fileManager.removeItem(at: diagnosticsURL) }

        let outputHandle = try FileHandle(forWritingTo: localURL)
        let errorHandle = try FileHandle(forWritingTo: diagnosticsURL)
        defer {
            try? outputHandle.close()
            try? errorHandle.close()
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = OpenSSHArgumentBuilder.sshArguments(
            configuration: configuration,
            identityFile: staged.identityFile,
            remoteCommand: remoteCommand
        )
        let askPassSecret = credential.askPassSecret(for: configuration.authenticationMode)
        if askPassSecret != nil, staged.askPassFile == nil {
            throw OpenSSHTransportError.missingAskPassHelper
        }
        process.environment = SSHAskPassEnvironment.make(
            base: ProcessInfo.processInfo.environment,
            secret: askPassSecret,
            askPassFile: staged.askPassFile
        )
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputHandle
        process.standardError = errorHandle

        try cancellation.register(process)
        defer { cancellation.clear(process) }
        try process.run()
        cancellation.didStart(process)
        try Self.waitForSnapshotProcess(
            process,
            cancellation: cancellation,
            timeoutSeconds: Self.snapshotProcessTimeoutSeconds
        )
        try outputHandle.synchronize()
        try errorHandle.synchronize()
        try cancellation.checkCancellation()

        guard process.terminationStatus == 0 else {
            let diagnostics = String(
                decoding: try Data(contentsOf: diagnosticsURL),
                as: UTF8.self
            )
            throw OpenSSHTransportError.processFailed(
                executable: "/usr/bin/ssh",
                status: process.terminationStatus,
                output: diagnostics
            )
        }
        completed = true
    }

    private static func waitForSnapshotProcess(
        _ process: Process,
        cancellation: ProcessCancellationController,
        timeoutSeconds: TimeInterval
    ) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeoutSeconds
        while process.isRunning {
            do {
                try cancellation.checkCancellation()
            } catch {
                terminateAndReap(process)
                throw error
            }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                terminateAndReap(process)
                throw OpenSSHTransportError.processTimedOut(
                    executable: "/usr/bin/ssh",
                    timeoutSeconds: Int(timeoutSeconds)
                )
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        process.waitUntilExit()
        try cancellation.checkCancellation()
    }

    private static func terminateAndReap(_ process: Process) {
        if process.isRunning {
            process.terminate()
        }
        let graceDeadline = ProcessInfo.processInfo.systemUptime + processTerminationGraceSeconds
        while process.isRunning && ProcessInfo.processInfo.systemUptime < graceDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            #if canImport(Darwin)
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
            #elseif canImport(Glibc)
            _ = Glibc.kill(process.processIdentifier, SIGKILL)
            #endif
        }
        process.waitUntilExit()
    }

    private func runOpenSSH(
        executable: String,
        standardInput: Data?,
        arguments: (URL?) -> [String]
    ) throws -> String {
        let credential = try credentials.credential(for: configuration.credentialReference)
        do {
            try credential.validate(for: configuration.authenticationMode)
        } catch SSHCredentialValidationError.emptyPrivateKey {
            throw OpenSSHTransportError.emptyPrivateKey
        } catch SSHCredentialValidationError.emptyPassword {
            throw OpenSSHTransportError.emptyPassword
        }

        let stager = SSHCredentialStager(fileManager: fileManager)
        let staged = try stager.stage(
            credential,
            authenticationMode: configuration.authenticationMode
        )
        defer { stager.remove(staged) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments(staged.identityFile)

        let askPassSecret = credential.askPassSecret(for: configuration.authenticationMode)
        if askPassSecret != nil, staged.askPassFile == nil {
            throw OpenSSHTransportError.missingAskPassHelper
        }
        process.environment = SSHAskPassEnvironment.make(
            base: ProcessInfo.processInfo.environment,
            secret: askPassSecret,
            askPassFile: staged.askPassFile
        )

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

private final class ProcessCancellationController: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func register(_ process: Process) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        self.process = process
    }

    func clear(_ process: Process) {
        lock.lock()
        defer { lock.unlock() }
        if self.process === process { self.process = nil }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let runningProcess = process
        lock.unlock()
        if runningProcess?.isRunning == true { runningProcess?.terminate() }
    }

    func didStart(_ process: Process) {
        lock.lock()
        let shouldTerminate = cancelled && self.process === process
        lock.unlock()
        if shouldTerminate && process.isRunning { process.terminate() }
    }

    func checkCancellation() throws {
        lock.lock()
        let isCancelled = cancelled
        lock.unlock()
        if isCancelled { throw CancellationError() }
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
