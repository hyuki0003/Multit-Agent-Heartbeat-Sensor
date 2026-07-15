import XCTest
@testable import HermesMonitorCore

final class SSHConfigurationTests: XCTestCase {
    func testBuildsStrictOpenSSHArguments() throws {
        let configuration = try SSHConnectionConfiguration(
            host: "monitor.example.com",
            port: 2222,
            username: "dhlee",
            credentialReference: .init(service: "com.example.HermesMonitor", account: "monitor-key"),
            knownHostsFile: URL(fileURLWithPath: "/Users/test/.ssh/known_hosts")
        )

        let arguments = OpenSSHArgumentBuilder.sftpArguments(
            configuration: configuration,
            identityFile: URL(fileURLWithPath: "/tmp/key")
        )

        XCTAssertEqual(configuration.destination, "dhlee@monitor.example.com")
        XCTAssertTrue(arguments.contains("StrictHostKeyChecking=yes"))
        XCTAssertTrue(arguments.contains("UserKnownHostsFile=/Users/test/.ssh/known_hosts"))
        XCTAssertTrue(arguments.contains("PasswordAuthentication=no"))
        XCTAssertTrue(arguments.contains("dhlee@monitor.example.com"))
    }

    func testBuildsHighResolutionRemoteStatArguments() throws {
        let configuration = try SSHConnectionConfiguration(
            host: "monitor.example.com",
            port: 2222,
            username: "dhlee",
            credentialReference: .init(service: "service", account: "account"),
            knownHostsFile: URL(fileURLWithPath: "/Users/test/.ssh/known_hosts")
        )
        let command = "/usr/bin/stat --printf='Size: %s\\nModify: %y\\n' -- '/safe/database.db'"

        let arguments = OpenSSHArgumentBuilder.sshArguments(
            configuration: configuration,
            identityFile: URL(fileURLWithPath: "/tmp/key"),
            remoteCommand: command
        )

        XCTAssertTrue(arguments.contains("-p"))
        XCTAssertTrue(arguments.contains("2222"))
        XCTAssertTrue(arguments.contains("StrictHostKeyChecking=yes"))
        XCTAssertEqual(Array(arguments.suffix(2)), ["dhlee@monitor.example.com", command])
    }

    func testCredentialStagerCreatesPrivateDirectoryAndIdentityFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("credential-stager-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stager = SSHCredentialStager(fileManager: .default, rootDirectory: root)

        let staged = try stager.stage(SSHCredential(privateKey: Data("private-key".utf8)))
        defer { stager.remove(staged) }

        let directoryMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: staged.directory.path)[.posixPermissions]
                as? NSNumber
        ).intValue
        let identityMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: staged.identityFile.path)[.posixPermissions]
                as? NSNumber
        ).intValue
        XCTAssertEqual(directoryMode, 0o700)
        XCTAssertEqual(identityMode, 0o600)
        XCTAssertEqual(try Data(contentsOf: staged.identityFile), Data("private-key".utf8))
    }

    func testRejectsShellAndArgumentInjectionCharacters() {
        XCTAssertThrowsError(
            try SSHConnectionConfiguration(
                host: "host\n-oProxyCommand=bad",
                port: 22,
                username: "dhlee",
                credentialReference: .init(service: "service", account: "account")
            )
        )
    }
}
