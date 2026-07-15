import Foundation
import SwiftUI
import UniformTypeIdentifiers
#if canImport(HermesMonitorCore)
import HermesMonitorCore
#endif

struct MonitorSettingsView: View {
    @AppStorage("HermesMonitor.host") private var host = ""
    @AppStorage("HermesMonitor.port") private var port = "22"
    @AppStorage("HermesMonitor.username") private var username = ""
    @AppStorage("HermesMonitor.authenticationMode") private var persistedAuthenticationMode =
        SSHAuthenticationMode.privateKey.rawValue
    @AppStorage("HermesMonitor.keychainService") private var persistedKeychainService =
        SSHCredentialPreferenceSnapshot.defaultKeychainService
    @AppStorage("HermesMonitor.keychainAccount") private var persistedKeychainAccount = ""
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
    @State private var credentialSelectionDraft: SSHCredentialSelectionDraft
    @State private var sshPassword = ""
    @State private var privateKeyPassphrase = ""
    @State private var privateKeyData: Data?
    @State private var privateKeyFilename = ""
    @State private var isImportingPrivateKey = false
    @State private var credentialStatus = ""
    @State private var credentialStatusIsError = false
    private let environment: [String: String]
    private let fallbackUsername: String

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fallbackUsername: String = NSUserName()
    ) {
        self.environment = environment
        self.fallbackUsername = fallbackUsername
        let initialPreferences = SSHCredentialPreferenceSnapshot.resolve(
            storedHost: UserDefaults.standard.string(forKey: "HermesMonitor.host"),
            storedUsername: UserDefaults.standard.string(forKey: "HermesMonitor.username"),
            storedAuthenticationMode: UserDefaults.standard.string(
                forKey: "HermesMonitor.authenticationMode"
            ),
            storedKeychainService: UserDefaults.standard.string(
                forKey: "HermesMonitor.keychainService"
            ),
            storedKeychainAccount: UserDefaults.standard.string(
                forKey: "HermesMonitor.keychainAccount"
            ),
            environment: environment,
            fallbackUsername: fallbackUsername
        )
        _credentialSelectionDraft = State(
            initialValue: SSHCredentialSelectionDraft(
                authenticationMode: initialPreferences.authenticationMode ?? .privateKey,
                keychainService: initialPreferences.keychainService,
                keychainAccount: initialPreferences.keychainAccountOverride ?? ""
            )
        )
    }

    var body: some View {
        Form {
            Section("Remote connection") {
                if effectiveCredentialPreferences.isHostEnvironmentControlled {
                    LabeledContent("Host") {
                        Text(effectiveCredentialPreferences.host)
                            .textSelection(.enabled)
                    }
                    Text("Controlled by HERMES_MONITOR_HOST.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    TextField("Host", text: $host)
                }
                TextField("Port", text: $port)
                if effectiveCredentialPreferences.isUsernameEnvironmentControlled {
                    LabeledContent("Username") {
                        Text(effectiveCredentialPreferences.username)
                            .textSelection(.enabled)
                    }
                    Text("Controlled by HERMES_MONITOR_USERNAME.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    TextField("Username", text: $username)
                }
                TextField("Known hosts", text: $knownHostsFile)
                Text("Editable connection changes take effect after relaunch; environment-controlled fields use the values displayed above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("SSH authentication") {
                if effectiveCredentialPreferences.isAuthenticationModeEnvironmentControlled {
                    LabeledContent("Authentication") {
                        Text(authenticationModeDisplayValue)
                            .textSelection(.enabled)
                    }
                    Text("Controlled by HERMES_MONITOR_AUTHENTICATION_MODE.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Authentication", selection: $credentialSelectionDraft.authenticationMode) {
                        ForEach(SSHAuthenticationMode.allCases, id: \.self) { mode in
                            Text(mode.settingsLabel).tag(mode)
                        }
                    }
                }
                TextField("Service", text: $credentialSelectionDraft.keychainService)
                    .disabled(effectiveCredentialPreferences.isKeychainServiceEnvironmentControlled)
                TextField("Account", text: keychainAccountBinding)
                    .disabled(effectiveCredentialPreferences.isKeychainAccountEnvironmentControlled)

                LabeledContent("Runtime credential target") {
                    Text("\(effectiveCredentialPreferences.username)@\(effectiveCredentialPreferences.host)")
                        .textSelection(.enabled)
                }
                if hasCredentialEnvironmentOverride {
                    Text("Environment-overridden authentication values are read-only here. The credential is saved to the exact reference used at runtime.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let authenticationModeErrorDescription {
                    Text(authenticationModeErrorDescription)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                    Text("Credential saving is disabled until the environment value is corrected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if selectedAuthenticationMode == .password {
                    SecureField("SSH password", text: $sshPassword)
                } else {
                    HStack {
                        Button("Choose Private Key…") {
                            isImportingPrivateKey = true
                        }
                        Text(privateKeyFilename.isEmpty ? "No key selected" : privateKeyFilename)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    SecureField("Private key passphrase (optional)", text: $privateKeyPassphrase)
                }

                HStack {
                    Button("Save / Update Credential") {
                        saveCredential()
                    }
                    .disabled(authenticationModeErrorDescription != nil)
                    Button("Clear Credential", role: .destructive) {
                        clearCredential()
                    }
                }

                if !credentialStatus.isEmpty {
                    Text(credentialStatus)
                        .font(.caption)
                        .foregroundStyle(credentialStatusIsError ? Color.red : Color.green)
                        .textSelection(.enabled)
                }
                Text("Secret material is saved as a JSON SSHCredential in macOS Keychain. It is never stored in UserDefaults or passed in SSH command arguments.")
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
        .frame(width: 520, height: 720)
        .fileImporter(
            isPresented: $isImportingPrivateKey,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            importPrivateKey(result)
        }
        .onChange(of: credentialSelectionDraft.authenticationMode) { _ in
            clearSecretFields()
            credentialStatus = ""
        }
        .onDisappear {
            isImportingPrivateKey = false
            credentialSelectionDraft.cancel()
            clearSecretFields()
        }
    }

    private var hotKeyDisplayName: String {
        (hotKeyUsesControl ? "⌃" : "") +
            (hotKeyUsesOption ? "⌥" : "") +
            (hotKeyUsesShift ? "⇧" : "") +
            (hotKeyUsesCommand ? "⌘" : "") +
            hotKey
    }

    private var selectedAuthenticationMode: SSHAuthenticationMode {
        effectiveCredentialPreferences.authenticationMode
            ?? credentialSelectionDraft.authenticationMode
    }

    private var authenticationModeDisplayValue: String {
        effectiveCredentialPreferences.authenticationMode?.settingsLabel
            ?? effectiveCredentialPreferences.authenticationModeValue
    }

    private var authenticationModeErrorDescription: String? {
        do {
            _ = try effectiveCredentialPreferences.requireAuthenticationMode()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private var effectiveCredentialPreferences: SSHCredentialPreferenceSnapshot {
        SSHCredentialPreferenceSnapshot.resolve(
            storedHost: host,
            storedUsername: username,
            storedAuthenticationMode: credentialSelectionDraft.authenticationMode.rawValue,
            storedKeychainService: credentialSelectionDraft.keychainService,
            storedKeychainAccount: credentialSelectionDraft.keychainAccount,
            environment: environment,
            fallbackUsername: fallbackUsername
        )
    }

    private var resolvedKeychainAccount: String {
        effectiveCredentialPreferences.keychainAccount
    }

    private var hasCredentialEnvironmentOverride: Bool {
        effectiveCredentialPreferences.isHostEnvironmentControlled
            || effectiveCredentialPreferences.isUsernameEnvironmentControlled
            || effectiveCredentialPreferences.isAuthenticationModeEnvironmentControlled
            || effectiveCredentialPreferences.isKeychainServiceEnvironmentControlled
            || effectiveCredentialPreferences.isKeychainAccountEnvironmentControlled
    }

    private var keychainAccountBinding: Binding<String> {
        Binding(
            get: { resolvedKeychainAccount },
            set: { credentialSelectionDraft.keychainAccount = $0 }
        )
    }

    private func credentialReference() throws -> SSHCredentialReference {
        try Self.credentialReference(from: effectiveCredentialPreferences)
    }

    private static func credentialReference(
        from preferences: SSHCredentialPreferenceSnapshot
    ) throws -> SSHCredentialReference {
        let account = preferences.keychainAccount
        let service = preferences.keychainService
        guard !service.isEmpty, !account.isEmpty,
              !service.contains(where: { $0.isNewline || $0 == "\0" }),
              !account.contains(where: { $0.isNewline || $0 == "\0" }) else {
            throw CredentialEditorError.emptyReference
        }
        return SSHCredentialReference(service: service, account: account)
    }

    private static func credentialSelection(
        from preferences: SSHCredentialPreferenceSnapshot
    ) throws -> SSHCredentialSelection {
        SSHCredentialSelection(
            authenticationMode: try preferences.requireAuthenticationMode(),
            reference: try credentialReference(from: preferences)
        )
    }

    private func saveCredential() {
        let preferences = effectiveCredentialPreferences
        do {
            try SSHCredentialEditorSaveTransaction.save(
                resolveSelection: { try Self.credentialSelection(from: preferences) },
                makeCredential: { authenticationMode in
                    switch authenticationMode {
                    case .privateKey:
                        guard let privateKeyData, !privateKeyData.isEmpty else {
                            throw CredentialEditorError.privateKeyNotSelected
                        }
                        return SSHCredential(
                            privateKey: privateKeyData,
                            passphrase: privateKeyPassphrase.isEmpty
                                ? nil
                                : privateKeyPassphrase
                        )
                    case .password:
                        return SSHCredential(password: sshPassword)
                    }
                },
                using: { credential, reference in
                    try KeychainSSHCredentialStore().save(credential, for: reference)
                },
                commit: { committedSelection in
                    persistedAuthenticationMode = committedSelection.authenticationMode.rawValue
                    persistedKeychainService = committedSelection.reference.service
                    persistedKeychainAccount = committedSelection.reference.account
                },
                cleanup: { clearSecretFields() }
            )
            showCredentialStatus("Credential saved in Keychain.", isError: false)
        } catch {
            showCredentialStatus(error.localizedDescription, isError: true)
        }
    }

    private func clearCredential() {
        do {
            try KeychainSSHCredentialStore().removeCredential(for: credentialReference())
            clearSecretFields()
            showCredentialStatus("Credential cleared from Keychain.", isError: false)
        } catch {
            showCredentialStatus(error.localizedDescription, isError: true)
        }
    }

    private func importPrivateKey(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else {
                throw CredentialEditorError.privateKeyNotSelected
            }
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard !data.isEmpty else { throw CredentialEditorError.emptyPrivateKeyFile }
            privateKeyData = data
            privateKeyFilename = url.lastPathComponent
            showCredentialStatus(
                "Private key selected. Save to update the Keychain credential.",
                isError: false
            )
        } catch {
            clearSecretFields()
            showCredentialStatus(error.localizedDescription, isError: true)
        }
    }

    private func clearSecretFields() {
        sshPassword = ""
        privateKeyPassphrase = ""
        privateKeyData = nil
        privateKeyFilename = ""
    }

    private func showCredentialStatus(_ message: String, isError: Bool) {
        credentialStatus = message
        credentialStatusIsError = isError
    }
}

private enum CredentialEditorError: LocalizedError {
    case emptyReference
    case privateKeyNotSelected
    case emptyPrivateKeyFile

    var errorDescription: String? {
        switch self {
        case .emptyReference:
            return "Keychain service and account must be non-empty single-line values."
        case .privateKeyNotSelected:
            return "Choose a private-key file before saving."
        case .emptyPrivateKeyFile:
            return "The selected private-key file is empty."
        }
    }
}

private extension SSHAuthenticationMode {
    var settingsLabel: String {
        switch self {
        case .privateKey: return "Private Key"
        case .password: return "Password"
        }
    }
}