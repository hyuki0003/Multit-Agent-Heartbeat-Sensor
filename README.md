# Hermes Monitor for macOS

A native SwiftUI observer for Hermes Kanban state on a remote Linux host. This package currently contains the foundation layer: strict SSH/SFTP access, Keychain-backed SSH credentials, read-only SQLite stores, schema models, task/run/session correlation, worker-log tails, and a 10-second polling primitive. The monitoring UI, notifications, and global hotkey are added by subsequent tasks.

## Requirements

- macOS 13 or newer
- Xcode 15 or newer (Swift 5.9+)
- System `/usr/bin/sftp`
- SQLite 3 (provided by macOS; Homebrew `sqlite3` is also supported)
- A populated `known_hosts` file for the remote host

Open `Package.swift` in Xcode, or run:

```sh
swift test
swift run HermesMonitorApp
```

## Read-only boundary

`RemotePathPolicy` permits reads only from:

- `/home/dhlee/.hermes/kanban.db`
- `/home/dhlee/.hermes/state.db`
- `/home/dhlee/.hermes/kanban/logs/<safe-task-id>.log`

The transport invokes `/usr/bin/sftp` directly without a shell. It forces strict host-key checking, public-key authentication, and `IdentitiesOnly=yes`; password and keyboard-interactive authentication are disabled. SQLite snapshots are opened with a `file:` URI containing `mode=ro`, `SQLITE_OPEN_READONLY`, and a runtime `sqlite3_db_readonly` assertion. The observer never opens the remote databases directly and never requests SQLite write access.

The small `kanban.db` copy is refreshed every poll. `state.db` and worker logs are downloaded only when their SFTP long-listing size/modification token changes. Each download goes to a partial file, is checked against a second SFTP metadata read, and is atomically installed. This avoids touching the remote SQLite lock state. Because the approved path allowlist excludes `-wal` and `-shm`, snapshots represent the latest checkpoint present in the main database file; they do not read uncheckpointed WAL frames.

## Keychain credential setup

Store an OpenSSH private key through `KeychainSSHCredentialStore`; do not put the key or passphrase in UserDefaults, configuration files, or source code.

```swift
let reference = SSHCredentialReference(
    service: "com.example.HermesMonitor",
    account: "remote-monitor-key"
)
let privateKey = try Data(contentsOf: privateKeyImportURL)
try KeychainSSHCredentialStore().save(
    SSHCredential(privateKey: privateKey, passphrase: importedPassphrase),
    for: reference
)
```

The imported private key remains in Keychain at rest. For each SFTP process, the transport materializes it in a randomly named `0700` temporary directory as a `0600` file and removes that directory when the process exits. An optional passphrase is supplied through a short-lived `SSH_ASKPASS` process environment and is never written to the project or preferences. The host key must already exist in `known_hosts`; the app never auto-accepts a host key.

Create a client with non-secret connection settings:

```swift
let configuration = try SSHConnectionConfiguration(
    host: "remote.example.com",
    port: 22,
    username: "dhlee",
    credentialReference: reference,
    knownHostsFile: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".ssh/known_hosts")
)
let client = HermesMonitorClient(
    configuration: configuration,
    cacheDirectory: HermesMonitorClient.defaultCacheDirectory()
)
let snapshot = try await client.refresh()
```

`client.snapshots()` provides an `AsyncThrowingStream` with a default 10-second interval.

## Correlation and liveness

`TaskCorrelator` resolves links in this order:

1. `tasks.current_run_id` to `task_runs.id`
2. `tasks.session_id` to `sessions.id`
3. `tasks.worker_pid` to `task_runs.worker_pid` or `task_runs.metadata.pid`
4. a unique `tasks.workspace_path` to `sessions.cwd` fallback
5. optional manual task/session links
6. `sessions.parent_session_id` to the parent session

Direct links are marked `.direct`; PID/workspace fallbacks and manual links remain visibly uncertain for the UI. A running task is stale when its heartbeat age is greater than 180 seconds.

## Source layout

- `Sources/HermesMonitorCore/`: transport, synchronization, SQLite, models, mapping
- `Sources/HermesMonitorApp/`: minimal SwiftUI executable entry point
- `Sources/CSQLite/`: SQLite C system-module shim
- `Tests/HermesMonitorCoreTests/`: path-boundary, parser, mapping, SQLite, and synchronization tests
