import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
PACKAGE = ROOT / "Package.swift"
TRANSPORT = ROOT / "Sources" / "HermesMonitorCore" / "OpenSSHTransport.swift"
SYNCHRONIZER = ROOT / "Sources" / "HermesMonitorCore" / "RemoteSnapshotSynchronizer.swift"
HELPER = ROOT / "Sources" / "HermesMonitorCore" / "Resources" / "RemoteSQLiteSnapshot.py"
STORES = ROOT / "Sources" / "HermesMonitorCore" / "Stores.swift"


class SnapshotArchitectureTests(unittest.TestCase):
    def test_database_seam_streams_to_file_and_logs_keep_tail_transport(self):
        package = PACKAGE.read_text(encoding="utf-8")
        transport = TRANSPORT.read_text(encoding="utf-8")
        synchronizer = SYNCHRONIZER.read_text(encoding="utf-8")
        helper = HELPER.read_text(encoding="utf-8")
        stores = STORES.read_text(encoding="utf-8")

        self.assertIn('.copy("Resources/RemoteSQLiteSnapshot.py")', package)
        self.assertIn("func downloadDatabaseSnapshot(remotePath: String, to localURL: URL)", transport)
        self.assertIn("process.standardOutput = outputHandle", transport)
        self.assertIn("process.standardError = errorHandle", transport)
        snapshot_stream = transport.split("private func streamSSH(", 1)[1].split(
            "private func runOpenSSH(", 1
        )[0]
        self.assertNotIn("String(contentsOf: localURL", snapshot_stream)
        self.assertIn("let diagnostics = String(", snapshot_stream)
        self.assertIn("decoding: try Data(contentsOf: diagnosticsURL)", snapshot_stream)
        self.assertIn("as: UTF8.self", snapshot_stream)
        self.assertIn("SSHAskPassEnvironment.make(", snapshot_stream)
        self.assertIn("OpenSSHArgumentBuilder.sshArguments(", snapshot_stream)
        self.assertEqual(synchronizer.count("transport.downloadDatabaseSnapshot("), 1)
        self.assertIn("try await synchronizeDatabase(\n            remotePath: RemotePathPolicy.kanbanDatabase", synchronizer)
        self.assertIn("try await synchronizeDatabase(\n            remotePath: RemotePathPolicy.stateDatabase", synchronizer)
        self.assertIn("atomicRename(source, target)", synchronizer)
        self.assertNotIn("try fileManager.removeItem(at: destination)", synchronizer)
        self.assertIn("try removeSQLiteSidecars(at: destination)", synchronizer)
        self.assertIn("transport.downloadTail(", synchronizer)
        self.assertIn('f"file:{quoted_path}?mode=ro"', helper)
        self.assertIn("source.backup(destination)", helper)
        self.assertIn("os.fchmod(descriptor, 0o600)", helper)
        self.assertIn('PRAGMA journal_mode=DELETE', helper)
        self.assertIn('PRAGMA quick_check', helper)
        self.assertIn("snapshot.read(1024 * 1024)", helper)
        self.assertIn('KANBAN_DATABASE_PATH: FULL_BACKUP_MODE', helper)
        self.assertIn('STATE_DATABASE_PATH: STATE_SESSIONS_MODE', helper)
        self.assertIn('destination.execute(schema_row[0])', helper)
        self.assertIn('rows = source.execute("SELECT * FROM sessions")', helper)
        self.assertNotIn('SELECT * FROM messages', helper)
        load_sessions = stores.split("public func loadSessions()", 1)[1].split(
            "public func messages(sessionID:", 1
        )[0]
        self.assertIn("FROM sessions", load_sessions)
        self.assertNotIn("FROM messages", load_sessions)
        self.assertIn("case processTimedOut(executable: String, timeoutSeconds: Int)", transport)
        self.assertIn("private static let snapshotProcessTimeoutSeconds: TimeInterval = 20", transport)
        self.assertIn("try Self.waitForSnapshotProcess(", snapshot_stream)
        self.assertIn("process.terminate()", transport)
        self.assertIn("SIGKILL", transport)
        self.assertIn("process.waitUntilExit()", transport)


if __name__ == "__main__":
    unittest.main()
