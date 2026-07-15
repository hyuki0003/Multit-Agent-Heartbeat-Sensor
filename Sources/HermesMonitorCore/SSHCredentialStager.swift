import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct StagedSSHCredential {
    let directory: URL
    let identityFile: URL
    let askPassFile: URL?
}

struct SSHCredentialStager {
    private let fileManager: FileManager
    private let rootDirectory: URL

    init(fileManager: FileManager = .default, rootDirectory: URL? = nil) {
        self.fileManager = fileManager
        self.rootDirectory = rootDirectory ?? fileManager.temporaryDirectory
    }

    func stage(_ credential: SSHCredential) throws -> StagedSSHCredential {
        let directory = rootDirectory
            .appendingPathComponent("HermesMonitor-\(UUID().uuidString)", isDirectory: true)
        try createPrivateDirectory(at: directory)

        do {
            let identityFile = directory.appendingPathComponent("identity")
            try createFile(at: identityFile, data: credential.privateKey, mode: 0o600)

            var askPassFile: URL?
            if let passphrase = credential.passphrase, !passphrase.isEmpty {
                let url = directory.appendingPathComponent("askpass.sh")
                let script = "#!/bin/sh\nprintf '%s\\n' \"$HERMES_MONITOR_SSH_PASSPHRASE\"\n"
                try createFile(at: url, data: Data(script.utf8), mode: 0o700)
                askPassFile = url
            }
            return StagedSSHCredential(
                directory: directory,
                identityFile: identityFile,
                askPassFile: askPassFile
            )
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    func remove(_ staged: StagedSSHCredential) {
        try? fileManager.removeItem(at: staged.directory)
    }

    private func createPrivateDirectory(at url: URL) throws {
        let status = url.path.withCString { pointer in
            systemMkdir(pointer, mode_t(0o700))
        }
        guard status == 0 else { throw currentPOSIXError() }
    }

    private func createFile(at url: URL, data: Data, mode: Int32) throws {
        let descriptor = url.path.withCString { pointer in
            systemOpen(pointer, O_WRONLY | O_CREAT | O_EXCL, mode_t(mode))
        }
        guard descriptor >= 0 else { throw currentPOSIXError() }
        defer { _ = systemClose(descriptor) }

        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                guard let baseAddress = bytes.baseAddress else { break }
                let result = systemWrite(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw currentPOSIXError()
                }
                offset += result
            }
        }
        guard systemFSync(descriptor) == 0 else { throw currentPOSIXError() }
    }
}

private func currentPOSIXError() -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
}

private func systemMkdir(_ path: UnsafePointer<CChar>, _ mode: mode_t) -> Int32 {
    #if canImport(Darwin)
    Darwin.mkdir(path, mode)
    #elseif canImport(Glibc)
    Glibc.mkdir(path, mode)
    #endif
}

private func systemOpen(_ path: UnsafePointer<CChar>, _ flags: Int32, _ mode: mode_t) -> Int32 {
    #if canImport(Darwin)
    Darwin.open(path, flags, mode)
    #elseif canImport(Glibc)
    Glibc.open(path, flags, mode)
    #endif
}

private func systemWrite(_ descriptor: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
    #if canImport(Darwin)
    Darwin.write(descriptor, buffer, count)
    #elseif canImport(Glibc)
    Glibc.write(descriptor, buffer, count)
    #endif
}

private func systemFSync(_ descriptor: Int32) -> Int32 {
    #if canImport(Darwin)
    Darwin.fsync(descriptor)
    #elseif canImport(Glibc)
    Glibc.fsync(descriptor)
    #endif
}

private func systemClose(_ descriptor: Int32) -> Int32 {
    #if canImport(Darwin)
    Darwin.close(descriptor)
    #elseif canImport(Glibc)
    Glibc.close(descriptor)
    #endif
}
