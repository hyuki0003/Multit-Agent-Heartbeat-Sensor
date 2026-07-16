# Agent's Heartbeat Monitor for Hermes

A native SwiftUI observer for Hermes Kanban state on a remote Linux host. The floating, resizable panel groups linked tasks, renders live heartbeat/ECG state, exposes expandable worker-log tails and task details, and refreshes its read-only SSH/SFTP snapshot every 10 seconds. A menu bar item, system-wide hotkey, and proactive notifications keep the monitor available while other apps are focused.

## Requirements

- macOS 13 or later
- Xcode 15 or newer (Swift 5.9+)
- System `/usr/bin/ssh` and `/usr/bin/sftp`
- SQLite 3 (provided by macOS; Homebrew `sqlite3` is also supported)
- A populated `known_hosts` file for the remote host

Open `Package.swift` in Xcode, or run:

```sh
swift test
swift run HermesMonitorApp
```

`swift run HermesMonitorApp` launches the UI, but UserNotifications is available only from a bundled `.app`.

## Read-only boundary

`RemotePathPolicy` permits reads only from:

- `/home/dhlee/.hermes/kanban.db`
- `/home/dhlee/.hermes/state.db`
- `/home/dhlee/.hermes/kanban/logs/<safe-task-id>.log`

The transport invokes `/usr/bin/ssh` for allowlisted GNU `stat` metadata probes and `/usr/bin/sftp` for downloads. It always forces strict host-key checking. Private-key mode uses the staged Keychain key with `IdentitiesOnly=yes` and disables password and keyboard-interactive authentication. Password mode disables public-key and keyboard-interactive authentication and supplies the selected Keychain password through a private `SSH_ASKPASS` helper. SQLite snapshots are opened with a `file:` URI containing `mode=ro`, `SQLITE_OPEN_READONLY`, and a runtime `sqlite3_db_readonly` assertion. The observer never opens the remote databases directly and never requests SQLite write access.

The small `kanban.db` copy is refreshed every poll. `state.db` is downloaded only when its byte size or nanosecond-resolution GNU `stat` modification token changes. Worker logs are requested only for running tasks; unchanged logs are reused, and changed logs use SFTP resume semantics to transfer at most the final 64 KiB. Each download goes to a partial file and is checked against a second high-resolution metadata read. Database partials must also pass SQLite `PRAGMA quick_check` before atomic installation, so an interrupted or internally inconsistent copy never replaces the last validated cache.

These guards cannot turn a concurrently changing live SQLite main file into a transactionally stable snapshot. The allowlist excludes `-wal` and `-shm`, so uncheckpointed WAL frames are intentionally absent, and an in-place change inside the remote filesystem timestamp resolution remains theoretically possible. Deployments requiring a strict guarantee must point the allowlisted database paths at server-produced, stable read-only snapshots created with SQLite's backup API or `VACUUM INTO`, then atomically publish those files.

## Keychain credential setup

Use Settings to choose Private Key or Password authentication, set the Keychain service/account, and save or clear the credential. Private-key files are imported into Keychain through `KeychainSSHCredentialStore`; passwords and optional key passphrases use secure fields. Do not put any key, password, or passphrase in UserDefaults, configuration files, command-line arguments, or source code.

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

The imported private key or password remains in Keychain at rest as a JSON-encoded `SSHCredential`. For each private-key SSH/SFTP process, the transport creates a randomly named `0700` temporary directory before writing key bytes, atomically creates the identity as a `0600` file, and removes the directory when the process exits. For password authentication no identity file is written. Passwords and optional key passphrases are supplied through a `0700` `SSH_ASKPASS` helper and short-lived process environment, never argv or standard input. The host key must already exist in `known_hosts`; the app never auto-accepts a host key.

Create a client with non-secret connection settings:

```swift
let configuration = try SSHConnectionConfiguration(
    host: "remote.example.com",
    port: 22,
    username: "dhlee",
    authenticationMode: .privateKey,
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

The app reads non-secret connection settings from environment variables or macOS user defaults. SSH key, password, and passphrase material remains in Keychain through the credential reference described above.

```sh
export HERMES_MONITOR_HOST="remote.example.com"
export HERMES_MONITOR_USERNAME="dhlee"
export HERMES_MONITOR_AUTHENTICATION_MODE="privateKey"
export HERMES_MONITOR_KEYCHAIN_SERVICE="com.hermes.monitor.ssh"
export HERMES_MONITOR_KEYCHAIN_ACCOUNT="dhlee@remote.example.com"
swift run HermesMonitorApp
```

The available variables are `HERMES_MONITOR_HOST`, `HERMES_MONITOR_PORT`, `HERMES_MONITOR_USERNAME`, `HERMES_MONITOR_AUTHENTICATION_MODE` (`privateKey` or `password`), `HERMES_MONITOR_KEYCHAIN_SERVICE`, `HERMES_MONITOR_KEYCHAIN_ACCOUNT`, and optionally `HERMES_MONITOR_KNOWN_HOSTS`. The equivalent persistent `UserDefaults` keys are prefixed with `HermesMonitor.` (for example, `HermesMonitor.host`). Environment variables take precedence, and authentication defaults to `privateKey` for backward compatibility. The known-hosts path defaults to `~/.ssh/known_hosts`.

The app launches as a menu bar accessory with the panel hidden. The Carbon hotkey API registers `Command-Shift-H` system-wide by default without requiring an event tap. Settings can change the key (`H`, `J`, `K`, `L`, or `M`) and modifier combination for the next launch. The menu bar item shows the active shortcut plus running/blocked counts and provides Toggle Window, Refresh Now, Settings, and Quit actions. The panel floats above regular windows, joins all Spaces, and restores its previous size and position.

The app requests macOS notification authorization on launch. By default it reports running tasks that become blocked, done, failed/crashed, or whose heartbeat reaches 180 seconds without an update. Completion, failure, and stale-heartbeat transitions also play a synthesized 880 Hz, 1.5-second flatline beep at 30% amplitude; each sound obeys the corresponding notification-category toggle, and normal progress updates remain silent. New-task notifications are available but disabled by default. Repeated task/event pairs are deduplicated for 60 seconds. Clicking a notification opens the panel, scrolls to the task, and highlights its card. The hotkey, notification categories, the 2–60 second refresh interval, connection metadata, authentication mode, and Keychain credential are configurable from Settings; SSH secret material remains in Keychain.

Optional one-time task/session overrides can be stored at `~/Library/Application Support/HermesMonitor/manual_links.json` as a JSON object from task ID to session ID. These local links never modify Hermes and remain marked uncertain in the UI.

## Correlation and liveness

`TaskCorrelator` resolves links in this order:

1. `tasks.current_run_id` to `task_runs.id`
2. `tasks.session_id` to `sessions.id`
3. `tasks.worker_pid` to `task_runs.worker_pid` or `task_runs.metadata.pid`
4. optional manual task/session links
5. a unique `tasks.workspace_path` to `sessions.cwd` fallback
6. `sessions.parent_session_id` to the parent session

Direct links are marked `.direct`; PID/workspace fallbacks and manual links remain visibly uncertain in each task card. Running-task liveness is fresh through 120 seconds, stale above 120 through 179 seconds, and dead at 180 seconds. A fresh/stale heart performs one bounce only when a new `last_heartbeat_at` value is observed; stale hearts are yellow and dead hearts are red. Stale ECG amplitude diminishes toward a flatline, blocked tasks show an occasional blip, and done/archived/failed tasks do not animate.

## Source layout

- `Sources/HermesMonitorCore/`: transport, synchronization, SQLite, models, mapping, and testable task-presentation rules
- `Sources/HermesMonitorApp/`: app lifecycle, menu bar, Carbon hotkey, notifications/settings, floating `NSPanel`, refresh view model, and task UI
- `Sources/CSQLite/`: SQLite C system-module shim
- `Tests/HermesMonitorCoreTests/`: path-boundary, parser, mapping, SQLite, and synchronization tests
