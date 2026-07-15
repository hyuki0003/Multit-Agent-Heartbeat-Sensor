# Agent's Heartbeat Monitor for macOS

A native SwiftUI observer for Hermes Kanban state on a remote Linux host. The floating, resizable panel groups linked tasks, renders live heartbeat/ECG state, exposes expandable worker-log tails and task details, and refreshes its read-only SSH/SFTP snapshot every 10 seconds. A menu bar item, system-wide hotkey, and proactive notifications keep the monitor available while other apps are focused.

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

## App connection settings

The app reads non-secret connection settings from environment variables or macOS user defaults. SSH private-key material remains in Keychain through the credential reference described above.

```sh
export HERMES_MONITOR_HOST="remote.example.com"
export HERMES_MONITOR_USERNAME="dhlee"
export HERMES_MONITOR_KEYCHAIN_SERVICE="com.hermes.monitor.ssh"
export HERMES_MONITOR_KEYCHAIN_ACCOUNT="dhlee@remote.example.com"
swift run HermesMonitorApp
```

The available variables are `HERMES_MONITOR_HOST`, `HERMES_MONITOR_PORT`, `HERMES_MONITOR_USERNAME`, `HERMES_MONITOR_KEYCHAIN_SERVICE`, `HERMES_MONITOR_KEYCHAIN_ACCOUNT`, and optionally `HERMES_MONITOR_KNOWN_HOSTS`. The equivalent persistent `UserDefaults` keys are prefixed with `HermesMonitor.` (for example, `HermesMonitor.host`). Environment variables take precedence. The known-hosts path defaults to `~/.ssh/known_hosts`.

The app launches as a menu bar accessory with the panel hidden. The Carbon hotkey API registers `Command-Shift-H` system-wide by default without requiring an event tap. Settings can change the key (`H`, `J`, `K`, `L`, or `M`) and modifier combination for the next launch. The menu bar item shows the active shortcut plus running/blocked counts and provides Toggle Window, Refresh Now, Settings, and Quit actions. The panel floats above regular windows, joins all Spaces, and restores its previous size and position.

The app requests macOS notification authorization on launch. By default it reports running tasks that become blocked, done, failed/crashed, or whose heartbeat exceeds 180 seconds. New-task notifications are available but disabled by default. Repeated task/event pairs are deduplicated for 60 seconds. Clicking a notification opens the panel, scrolls to the task, and highlights its card. The hotkey, notification categories, the 2–60 second refresh interval, connection metadata, and the Keychain credential reference are configurable from Settings; SSH key material remains in Keychain.

Optional one-time task/session overrides can be stored at `~/Library/Application Support/HermesMonitor/manual_links.json` as a JSON object from task ID to session ID. These local links never modify Hermes and remain marked uncertain in the UI.

## Correlation and liveness

`TaskCorrelator` resolves links in this order:

1. `tasks.current_run_id` to `task_runs.id`
2. `tasks.session_id` to `sessions.id`
3. `tasks.worker_pid` to `task_runs.worker_pid` or `task_runs.metadata.pid`
4. optional manual task/session links
5. a unique `tasks.workspace_path` to `sessions.cwd` fallback
6. `sessions.parent_session_id` to the parent session

Direct links are marked `.direct`; PID/workspace fallbacks and manual links remain visibly uncertain in each task card. Running-task liveness is fresh below 60 seconds, stale from 60 through 179 seconds, and dead at 180 seconds. Stale ECG amplitude diminishes toward a flatline; done and failed tasks show a flatline.

## Source layout

- `Sources/HermesMonitorCore/`: transport, synchronization, SQLite, models, mapping, and testable task-presentation rules
- `Sources/HermesMonitorApp/`: app lifecycle, menu bar, Carbon hotkey, notifications/settings, floating `NSPanel`, refresh view model, and task UI
- `Sources/CSQLite/`: SQLite C system-module shim
- `Tests/HermesMonitorCoreTests/`: path-boundary, parser, mapping, SQLite, and synchronization tests
