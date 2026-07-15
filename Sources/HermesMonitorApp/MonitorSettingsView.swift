import SwiftUI

struct MonitorSettingsView: View {
    @AppStorage("HermesMonitor.host") private var host = ""
    @AppStorage("HermesMonitor.port") private var port = "22"
    @AppStorage("HermesMonitor.username") private var username = ""
    @AppStorage("HermesMonitor.keychainService") private var keychainService = "com.hermes.monitor.ssh"
    @AppStorage("HermesMonitor.keychainAccount") private var keychainAccount = ""
    @AppStorage("HermesMonitor.knownHostsFile") private var knownHostsFile = "~/.ssh/known_hosts"
    @AppStorage(MonitorPreferenceKeys.refreshInterval) private var refreshInterval = 10.0
    @AppStorage(MonitorPreferenceKeys.notifyOnBlocked) private var notifyOnBlocked = true
    @AppStorage(MonitorPreferenceKeys.notifyOnCompleted) private var notifyOnCompleted = true
    @AppStorage(MonitorPreferenceKeys.notifyOnFailed) private var notifyOnFailed = true
    @AppStorage(MonitorPreferenceKeys.notifyOnHeartbeatStale) private var notifyOnHeartbeatStale = true
    @AppStorage(MonitorPreferenceKeys.notifyOnNewTask) private var notifyOnNewTask = false
    @AppStorage(MonitorPreferenceKeys.hotKey) private var hotKey = "H"
    @AppStorage(MonitorPreferenceKeys.hotKeyUsesCommand) private var hotKeyUsesCommand = true
    @AppStorage(MonitorPreferenceKeys.hotKeyUsesShift) private var hotKeyUsesShift = true
    @AppStorage(MonitorPreferenceKeys.hotKeyUsesOption) private var hotKeyUsesOption = false
    @AppStorage(MonitorPreferenceKeys.hotKeyUsesControl) private var hotKeyUsesControl = false

    var body: some View {
        Form {
            Section("Remote connection") {
                TextField("Host", text: $host)
                TextField("Port", text: $port)
                TextField("Username", text: $username)
                TextField("Known hosts", text: $knownHostsFile)
                Text("Connection changes take effect after relaunch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Keychain credential reference") {
                TextField("Service", text: $keychainService)
                TextField("Account", text: $keychainAccount)
                Text("The SSH private key and passphrase remain in macOS Keychain and are never stored in these settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Global hotkey") {
                Picker("Key", selection: $hotKey) {
                    ForEach(MonitorHotKeyPreference.supportedKeys, id: \.self) { key in
                        Text(key).tag(key)
                    }
                }
                .pickerStyle(.segmented)

                HStack {
                    Toggle("Command", isOn: $hotKeyUsesCommand)
                        .disabled(hotKeyUsesCommand && !hotKeyUsesShift && !hotKeyUsesOption && !hotKeyUsesControl)
                    Toggle("Shift", isOn: $hotKeyUsesShift)
                        .disabled(hotKeyUsesShift && !hotKeyUsesCommand && !hotKeyUsesOption && !hotKeyUsesControl)
                    Toggle("Option", isOn: $hotKeyUsesOption)
                        .disabled(hotKeyUsesOption && !hotKeyUsesCommand && !hotKeyUsesShift && !hotKeyUsesControl)
                    Toggle("Control", isOn: $hotKeyUsesControl)
                        .disabled(hotKeyUsesControl && !hotKeyUsesCommand && !hotKeyUsesShift && !hotKeyUsesOption)
                }

                LabeledContent("Toggle monitor") {
                    Text(hotKeyDisplayName)
                        .font(.system(.body, design: .monospaced, weight: .semibold))
                }
                Text("The shortcut is registered system-wide after the next app launch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Refresh") {
                HStack {
                    Slider(value: $refreshInterval, in: 2...60, step: 1)
                    Text("\(Int(refreshInterval))s")
                        .monospacedDigit()
                        .frame(width: 36, alignment: .trailing)
                }
            }

            Section("Notifications") {
                Toggle("Task becomes blocked", isOn: $notifyOnBlocked)
                Toggle("Task completes", isOn: $notifyOnCompleted)
                Toggle("Task fails or crashes", isOn: $notifyOnFailed)
                Toggle("Running heartbeat reaches 180 seconds", isOn: $notifyOnHeartbeatStale)
                Toggle("New task appears", isOn: $notifyOnNewTask)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 610)
    }

    private var hotKeyDisplayName: String {
        (hotKeyUsesControl ? "⌃" : "") +
            (hotKeyUsesOption ? "⌥" : "") +
            (hotKeyUsesShift ? "⇧" : "") +
            (hotKeyUsesCommand ? "⌘" : "") +
            hotKey
    }
}
