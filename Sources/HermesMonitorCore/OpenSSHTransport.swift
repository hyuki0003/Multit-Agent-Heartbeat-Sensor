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
    case archiveProcessTimedOut(timeoutSeconds: Int)
    case instructionProcessTimedOut(timeoutSeconds: Int)
    case emptyPrivateKey
    case emptyPassword
    case missingAskPassHelper
    case missingSnapshotHelper
    case missingTaskInstructionHelper
    case missingTaskFamilyArchiveHelper

    public var errorDescription: String? {
        switch self {
        case .invalidRemotePath(let path):
            return "Refusing SSH/SFTP access outside the approved path set: \(path)"
        case .processFailed(let executable, let status, let output):
            return "\(executable) exited with status \(status): \(output)"
        case .processTimedOut(let executable, let timeoutSeconds):
            return "\(executable) exceeded the \(timeoutSeconds)-second database snapshot deadline and was terminated. Check the VPN and SSH gateway, then retry."
        case .archiveProcessTimedOut(let timeoutSeconds):
            return "The remote Hermes archive exceeded \(timeoutSeconds) seconds. Its remote outcome is unknown because the command may have completed before the connection was terminated. Refresh the board before taking another action."
        case .instructionProcessTimedOut(let timeoutSeconds):
            return "The Astra instruction submission exceeded \(timeoutSeconds) seconds. Retry is safe because the instruction ID is idempotent."
        case .emptyPrivateKey:
            return "The Keychain SSH private key is empty."
        case .emptyPassword:
            return "The Keychain SSH password is empty."
        case .missingAskPassHelper:
            return "The private SSH_ASKPASS helper could not be staged."
        case .missingSnapshotHelper:
            return "The bundled remote SQLite snapshot helper is missing."
        case .missingTaskInstructionHelper:
            return "The bundled Astra instruction helper is missing."
        case .missingTaskFamilyArchiveHelper:
            return "The bundled task-family archive helper is missing."
        }
    }
}

enum RemoteSQLiteSnapshotResource {
    static var bundle: Bundle {
#if SWIFT_PACKAGE
        return Bundle.module
#else
        return Bundle.main
#endif
    }

    static var url: URL? {
        bundle.url(forResource: "RemoteSQLiteSnapshot", withExtension: "py")
    }
}

public final class OpenSSHTransport: RemoteFileTransport, RemoteKanbanArchiving, RemoteTaskInstructionSubmitting, RemoteTaskFamilyArchiving, @unchecked Sendable {
    private static let snapshotProcessTimeoutSeconds: TimeInterval = 20
    private static let archiveProcessTimeoutSeconds: TimeInterval = 20
    private static let instructionProcessTimeoutSeconds: TimeInterval = 20
    private static let processTerminationGraceSeconds: TimeInterval = 1
    private static let archiveDiagnosticByteLimit = 8 * 1_024

    private let configuration: SSHConnectionConfiguration
    private let credentials: any SSHCredentialProviding
    private let sshExecutableURL: URL
    private let sftpExecutableURL: URL
    private let pathPolicy: RemotePathPolicy
    private let fileManager: FileManager

    public init(
        configuration: SSHConnectionConfiguration,
        credentials: any SSHCredentialProviding = KeychainSSHCredentialStore(),
        sshExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/ssh"),
        sftpExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/sftp"),
        pathPolicy: RemotePathPolicy = RemotePathPolicy(),
        fileManager: FileManager = .default
    ) {
        self.configuration = configuration
        self.credentials = credentials
        self.sshExecutableURL = sshExecutableURL
        self.sftpExecutableURL = sftpExecutableURL
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
        guard let helperURL = RemoteSQLiteSnapshotResource.url else {
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

    public func archiveDoneTask(taskID: String) async throws {
        let remoteCommand = try HermesKanbanArchiveCommand.remoteCommand(taskID: taskID)
        let cancellation = ProcessCancellationController()

        try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) { [self] in
                try cancellation.checkCancellation()
                try runBoundedArchiveSSH(
                    remoteCommand: remoteCommand,
                    cancellation: cancellation
                )
            }.value
        } onCancel: {
            cancellation.cancel()
        }
    }

    public func submitTaskInstruction(
        _ request: RemoteTaskInstructionRequest
    ) async throws -> RemoteTaskInstructionReceipt {
        guard let helperURL = TaskInstructionHelperResource.url else {
            throw OpenSSHTransportError.missingTaskInstructionHelper
        }
        let helper = try String(contentsOf: helperURL, encoding: .utf8)
        let payload = try TaskInstructionCodec.encode(request)
        let remoteCommand = HermesTaskInstructionCommand.remoteCommand(helper: helper)
        let cancellation = ProcessCancellationController()

        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) { [self] in
                try cancellation.checkCancellation()
                let output = try runBoundedInstructionSSH(
                    remoteCommand: remoteCommand,
                    payload: payload,
                    message: request.message,
                    cancellation: cancellation
                )
                return try TaskInstructionCodec.decodeReceipt(
                    output,
                    expectedInstructionID: request.instructionID
                )
            }.value
        } onCancel: {
            cancellation.cancel()
        }
    }

    public func archiveCompletedTaskFamilies(
        _ request: RemoteTaskFamilyArchiveRequest
    ) async throws -> RemoteTaskFamilyArchiveReceipt {
        guard let helperURL = TaskFamilyArchiveHelperResource.url else {
            throw OpenSSHTransportError.missingTaskFamilyArchiveHelper
        }
        let helper = try String(contentsOf: helperURL, encoding: .utf8)
        let payload = try TaskFamilyArchiveCodec.encode(request)
        let remoteCommand = HermesTaskFamilyArchiveCommand.remoteCommand(helper: helper)
        let cancellation = ProcessCancellationController()

        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) { [self] in
                try cancellation.checkCancellation()
                let output = try runBoundedInstructionSSH(
                    remoteCommand: remoteCommand,
                    payload: payload,
                    message: "",
                    cancellation: cancellation
                )
                return try TaskFamilyArchiveCodec.decodeReceipt(output)
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

    private func credentialForSession() throws -> SSHCredential {
        do {
            let credential = try credentials.credential(for: configuration.credentialReference)
            try credential.validate(for: configuration.authenticationMode)
            return credential
        } catch SSHCredentialValidationError.emptyPrivateKey {
            throw OpenSSHTransportError.emptyPrivateKey
        } catch SSHCredentialValidationError.emptyPassword {
            throw OpenSSHTransportError.emptyPassword
        }
    }

    private func runSFTP(batchCommand: String) throws -> String {
        try runOpenSSH(
            executable: sftpExecutableURL.path,
            standardInput: Data(batchCommand.utf8)
        ) { identityFile in
            OpenSSHArgumentBuilder.sftpArguments(
                configuration: configuration,
                identityFile: identityFile
            )
        }
    }

    private func runSSH(remoteCommand: String) throws -> String {
        try runOpenSSH(executable: sshExecutableURL.path, standardInput: nil) { identityFile in
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
        let credential = try credentialForSession()

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
        process.executableURL = sshExecutableURL
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
            executable: sshExecutableURL.path,
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
                executable: sshExecutableURL.path,
                status: process.terminationStatus,
                output: diagnostics
            )
        }
        completed = true
    }

    private func runBoundedArchiveSSH(
        remoteCommand: String,
        cancellation: ProcessCancellationController
    ) throws {
        let credential = try credentialForSession()

        let stager = SSHCredentialStager(fileManager: fileManager)
        let staged = try stager.stage(
            credential,
            authenticationMode: configuration.authenticationMode
        )
        defer { stager.remove(staged) }

        let process = Process()
        process.executableURL = sshExecutableURL
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
        let retainedByteLimit = Self.archiveDiagnosticByteLimit +
            (askPassSecret?.utf8.count ?? 0)
        let outputCapture = BoundedProcessOutputCapture(byteLimit: retainedByteLimit)
        let errorCapture = BoundedProcessOutputCapture(byteLimit: retainedByteLimit)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputCapture.pipe
        process.standardError = errorCapture.pipe

        try cancellation.register(process)
        defer { cancellation.clear(process) }
        outputCapture.start()
        errorCapture.start()
        do {
            try process.run()
        } catch {
            outputCapture.closeParentWriteEnd()
            errorCapture.closeParentWriteEnd()
            _ = outputCapture.finish()
            _ = errorCapture.finish()
            throw error
        }
        outputCapture.closeParentWriteEnd()
        errorCapture.closeParentWriteEnd()
        cancellation.didStart(process)
        do {
            try Self.waitForArchiveProcess(
                process,
                timeoutSeconds: Self.archiveProcessTimeoutSeconds,
                cancellation: cancellation
            )
        } catch {
            _ = outputCapture.finish()
            _ = errorCapture.finish()
            throw error
        }
        let output = outputCapture.finish()
        let error = errorCapture.finish()
        try cancellation.checkCancellation()

        guard process.terminationStatus == 0 else {
            throw OpenSSHTransportError.processFailed(
                executable: sshExecutableURL.path,
                status: process.terminationStatus,
                output: Self.archiveDiagnostics(
                    output: output,
                    error: error,
                    secret: askPassSecret
                )
            )
        }
    }

    private func runBoundedInstructionSSH(
        remoteCommand: String,
        payload: Data,
        message: String,
        cancellation: ProcessCancellationController
    ) throws -> Data {
        let instructionCredential = try credentialForSession()

        let stager = SSHCredentialStager(fileManager: fileManager)
        let staged = try stager.stage(
            instructionCredential,
            authenticationMode: configuration.authenticationMode
        )
        defer { stager.remove(staged) }

        let process = Process()
        process.executableURL = sshExecutableURL
        process.arguments = OpenSSHArgumentBuilder.sshArguments(
            configuration: configuration,
            identityFile: staged.identityFile,
            remoteCommand: remoteCommand
        )
        let askPassSecret = instructionCredential.askPassSecret(for: configuration.authenticationMode)
        if askPassSecret != nil, staged.askPassFile == nil {
            throw OpenSSHTransportError.missingAskPassHelper
        }
        process.environment = SSHAskPassEnvironment.make(
            base: ProcessInfo.processInfo.environment,
            secret: askPassSecret,
            askPassFile: staged.askPassFile
        )
        let retainedByteLimit = Self.archiveDiagnosticByteLimit +
            (askPassSecret?.utf8.count ?? 0) + message.utf8.count
        let input = Pipe()
        let outputCapture = BoundedProcessOutputCapture(byteLimit: retainedByteLimit)
        let errorCapture = BoundedProcessOutputCapture(byteLimit: retainedByteLimit)
        process.standardInput = input
        process.standardOutput = outputCapture.pipe
        process.standardError = errorCapture.pipe

        try cancellation.register(process)
        defer { cancellation.clear(process) }
        outputCapture.start()
        errorCapture.start()
        do {
            try process.run()
            input.fileHandleForWriting.write(payload)
            try input.fileHandleForWriting.close()
        } catch {
            try? input.fileHandleForWriting.close()
            outputCapture.closeParentWriteEnd()
            errorCapture.closeParentWriteEnd()
            _ = outputCapture.finish()
            _ = errorCapture.finish()
            throw error
        }
        outputCapture.closeParentWriteEnd()
        errorCapture.closeParentWriteEnd()
        cancellation.didStart(process)
        do {
            try Self.waitForInstructionProcess(
                process,
                timeoutSeconds: Self.instructionProcessTimeoutSeconds,
                cancellation: cancellation
            )
        } catch {
            _ = outputCapture.finish()
            _ = errorCapture.finish()
            throw error
        }
        let output = outputCapture.finish()
        let error = errorCapture.finish()
        try cancellation.checkCancellation()

        guard process.terminationStatus == 0 else {
            throw OpenSSHTransportError.processFailed(
                executable: sshExecutableURL.path,
                status: process.terminationStatus,
                output: Self.instructionDiagnostics(
                    output: output,
                    error: error,
                    credentialSecret: askPassSecret,
                    message: message
                )
            )
        }
        return output
    }

    static func waitForArchiveProcess(
        _ process: Process,
        timeoutSeconds: TimeInterval
    ) throws {
        try waitForArchiveProcess(
            process,
            timeoutSeconds: timeoutSeconds,
            cancellation: nil
        )
    }

    private static func waitForArchiveProcess(
        _ process: Process,
        timeoutSeconds: TimeInterval,
        cancellation: ProcessCancellationController?
    ) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeoutSeconds
        while process.isRunning {
            do {
                try cancellation?.checkCancellation()
            } catch {
                terminateAndReap(process)
                throw error
            }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                terminateAndReap(process)
                throw OpenSSHTransportError.archiveProcessTimedOut(
                    timeoutSeconds: max(1, Int(timeoutSeconds.rounded(.up)))
                )
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        process.waitUntilExit()
        try cancellation?.checkCancellation()
    }

    static func archiveDiagnostics(
        output: Data,
        error: Data,
        secret: String?
    ) -> String {
        let values = [output, error].map { String(decoding: $0, as: UTF8.self) }
        var combined = values.filter { !$0.isEmpty }.joined(separator: "\n")
        if let secret, !secret.isEmpty {
            combined = combined.replacingOccurrences(of: secret, with: "<redacted>")
        }
        combined = String(combined.unicodeScalars.map { scalar in
            if scalar == "\n" || scalar == "\t" || scalar.value >= 32 {
                return Character(String(scalar))
            }
            return "�"
        })
        guard !combined.isEmpty else { return "No remote diagnostics." }
        var bounded = String(
            decoding: combined.utf8.prefix(archiveDiagnosticByteLimit),
            as: UTF8.self
        )
        while bounded.utf8.count > archiveDiagnosticByteLimit {
            bounded.removeLast()
        }
        return bounded
    }

    static func instructionDiagnostics(
        output: Data,
        error: Data,
        credentialSecret: String?,
        message: String
    ) -> String {
        let values = [output, error].map { String(decoding: $0, as: UTF8.self) }
        var combined = values.filter { !$0.isEmpty }.joined(separator: "\n")
        var didRedact = false
        for value in [credentialSecret, message].compactMap({ $0 }).filter({ !$0.isEmpty }) {
            if combined.contains(value) {
                didRedact = true
                combined = combined.replacingOccurrences(of: value, with: "<redacted>")
            }
        }
        combined = sanitizedAndBoundedDiagnostics(combined)
        if didRedact && !combined.contains("<redacted>") {
            combined = sanitizedAndBoundedDiagnostics("<redacted>\n" + combined)
        }
        return combined
    }

    private static func sanitizedAndBoundedDiagnostics(_ combined: String) -> String {
        var combined = combined
        combined = String(combined.unicodeScalars.map { scalar in
            if scalar == "\n" || scalar == "\t" || scalar.value >= 32 {
                return Character(String(scalar))
            }
            return "�"
        })
        guard !combined.isEmpty else { return "No remote diagnostics." }
        var bounded = String(
            decoding: combined.utf8.prefix(archiveDiagnosticByteLimit),
            as: UTF8.self
        )
        while bounded.utf8.count > archiveDiagnosticByteLimit {
            bounded.removeLast()
        }
        return bounded
    }

    private static func waitForSnapshotProcess(
        _ process: Process,
        executable: String,
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
                    executable: executable,
                    timeoutSeconds: Int(timeoutSeconds)
                )
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        process.waitUntilExit()
        try cancellation.checkCancellation()
    }

    private static func waitForInstructionProcess(
        _ process: Process,
        timeoutSeconds: TimeInterval,
        cancellation: ProcessCancellationController
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
                throw OpenSSHTransportError.instructionProcessTimedOut(
                    timeoutSeconds: max(1, Int(timeoutSeconds.rounded(.up)))
                )
            }
            Thread.sleep(forTimeInterval: 0.01)
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
        let credential = try credentialForSession()

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

final class BoundedProcessOutputCapture: @unchecked Sendable {
    let pipe = Pipe()

    private let byteLimit: Int
    private let lock = NSLock()
    private let readGroup = DispatchGroup()
    private let readQueue = DispatchQueue(
        label: "HermesMonitor.BoundedProcessOutputCapture",
        qos: .utility
    )
    private var data = Data()

    init(byteLimit: Int) {
        self.byteLimit = max(0, byteLimit)
    }

    func start() {
        readGroup.enter()
        readQueue.async { [self] in
            defer { readGroup.leave() }
            while true {
                do {
                    guard let chunk = try pipe.fileHandleForReading.read(upToCount: 64 * 1_024),
                          !chunk.isEmpty else {
                        return
                    }
                    append(chunk)
                } catch {
                    return
                }
            }
        }
    }

    func closeParentWriteEnd() {
        try? pipe.fileHandleForWriting.close()
    }

    func finish() -> Data {
        readGroup.wait()
        lock.lock()
        defer { lock.unlock() }
        return data
    }

    private func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        let remaining = byteLimit - data.count
        guard remaining > 0 else { return }
        data.append(contentsOf: chunk.prefix(remaining))
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
