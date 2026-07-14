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
