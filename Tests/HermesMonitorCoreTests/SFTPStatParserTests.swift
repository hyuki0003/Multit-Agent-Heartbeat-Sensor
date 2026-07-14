import XCTest
@testable import HermesMonitorCore

final class SFTPStatParserTests: XCTestCase {
    func testParsesOpenSSHLongListingUsedForSFTPMetadata() throws {
        let output = """
        sftp> ls -ln /home/dhlee/.hermes/kanban.db
        -rw-r--r--    ? 1000     1000       218112 Jul 14 17:03 /home/dhlee/.hermes/kanban.db
        """

        let metadata = try SFTPStatParser.parse(output: output, path: RemotePathPolicy.kanbanDatabase)

        XCTAssertEqual(metadata.size, 218_112)
        XCTAssertEqual(metadata.modificationToken, "Jul 14 17:03")
    }

    func testParsesSizeAndModifyTokenFromOpenSSHStatOutput() throws {
        let output = """
        Size: 218112        FileType: Regular File
        Mode: (0644/-rw-r--r--)         Uid: ( 1000/ dhlee)  Gid: ( 1000/ dhlee)
        Access: 2026-07-14 17:00:00 +0900
        Modify: 2026-07-14 16:59:58.123456789 +0900
        Change: 2026-07-14 16:59:58.123456789 +0900
        """

        let metadata = try SFTPStatParser.parse(output: output, path: RemotePathPolicy.kanbanDatabase)

        XCTAssertEqual(metadata.path, RemotePathPolicy.kanbanDatabase)
        XCTAssertEqual(metadata.size, 218_112)
        XCTAssertEqual(metadata.modificationToken, "2026-07-14 16:59:58.123456789 +0900")
    }

    func testRejectsOutputWithoutStableModificationToken() {
        XCTAssertThrowsError(
            try SFTPStatParser.parse(output: "Size: 12", path: RemotePathPolicy.kanbanDatabase)
        )
    }
}
