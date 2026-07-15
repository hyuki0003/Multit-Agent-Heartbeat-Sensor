import Foundation
#if canImport(HermesMonitorCore)
import HermesMonitorCore
#endif

struct MonitorConnectionSettings {
    let host: String
    let port: Int
    let username: String
    let authenticationMode: SSHAuthenticationMode
    let credentialReference: SSHCredentialReference
    let knownHostsFile: URL

    static func load(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> MonitorConnectionSettings {
        let credentialPreferences = SSHCredentialPreferenceSnapshot.resolve(
            storedHost: defaults.string(forKey: "HermesMonitor.host"),
            storedUsername: defaults.string(forKey: "HermesMonitor.username"),
            storedAuthenticationMode: defaults.string(forKey: "HermesMonitor.authenticationMode"),
            storedKeychainService: defaults.string(forKey: "HermesMonitor.keychainService"),
            storedKeychainAccount: defaults.string(forKey: "HermesMonitor.keychainAccount"),
            environment: environment,
            fallbackUsername: NSUserName()
        )
        let credentialSelection: SSHCredentialSelection
        do {
            credentialSelection = try credentialPreferences.validatedRuntimeCredentialSelection()
        } catch SSHCredentialPreferenceValidationError.missingHost {
            throw MonitorConfigurationError.missingHost
        }
        let host = credentialPreferences.host
        let username = credentialPreferences.username
        let portValue = value(
            environmentKey: "HERMES_MONITOR_PORT",
            defaultsKey: "HermesMonitor.port",
            defaults: defaults,
            environment: environment
        )
        let port = portValue.flatMap(Int.init) ?? 22
        let knownHostsPath = value(
            environmentKey: "HERMES_MONITOR_KNOWN_HOSTS",
            defaultsKey: "HermesMonitor.knownHostsFile",
            defaults: defaults,
            environment: environment
        ) ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/known_hosts")
            .path

        return MonitorConnectionSettings(
            host: host,
            port: port,
            username: username,
            authenticationMode: credentialSelection.authenticationMode,
            credentialReference: credentialSelection.reference,
            knownHostsFile: URL(
                fileURLWithPath: (knownHostsPath as NSString).expandingTildeInPath
            ).standardizedFileURL
        )
    }

    func makeClient() throws -> HermesMonitorClient {
        let configuration = try SSHConnectionConfiguration(
            host: host,
            port: port,
            username: username,
            authenticationMode: authenticationMode,
            credentialReference: credentialReference,
            knownHostsFile: knownHostsFile
        )
        let manualSessionLinks = try ManualSessionLinkStore(
            fileURL: ManualSessionLinkStore.defaultFileURL()
        ).load()
        return HermesMonitorClient(
            configuration: configuration,
            cacheDirectory: HermesMonitorClient.defaultCacheDirectory(),
            correlator: TaskCorrelator(manualSessionLinks: manualSessionLinks)
        )
    }

    private static func value(
        environmentKey: String,
        defaultsKey: String,
        defaults: UserDefaults,
        environment: [String: String]
    ) -> String? {
        environment[environmentKey] ?? defaults.string(forKey: defaultsKey)
    }
}

enum MonitorConfigurationError: LocalizedError {
    case missingHost

    var errorDescription: String? {
        switch self {
        case .missingHost:
            return "Set HERMES_MONITOR_HOST or the HermesMonitor.host user default to begin monitoring."
        }
    }
}
