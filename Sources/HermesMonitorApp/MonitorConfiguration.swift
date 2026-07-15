import Foundation

struct MonitorConnectionSettings {
    let host: String
    let port: Int
    let username: String
    let credentialReference: SSHCredentialReference
    let knownHostsFile: URL

    static func load(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> MonitorConnectionSettings {
        let host = value(
            environmentKey: "HERMES_MONITOR_HOST",
            defaultsKey: "HermesMonitor.host",
            defaults: defaults,
            environment: environment
        )
        guard let host, !host.isEmpty else {
            throw MonitorConfigurationError.missingHost
        }

        let username = value(
            environmentKey: "HERMES_MONITOR_USERNAME",
            defaultsKey: "HermesMonitor.username",
            defaults: defaults,
            environment: environment
        ) ?? NSUserName()
        let portValue = value(
            environmentKey: "HERMES_MONITOR_PORT",
            defaultsKey: "HermesMonitor.port",
            defaults: defaults,
            environment: environment
        )
        let port = portValue.flatMap(Int.init) ?? 22
        let service = value(
            environmentKey: "HERMES_MONITOR_KEYCHAIN_SERVICE",
            defaultsKey: "HermesMonitor.keychainService",
            defaults: defaults,
            environment: environment
        ) ?? "com.hermes.monitor.ssh"
        let account = value(
            environmentKey: "HERMES_MONITOR_KEYCHAIN_ACCOUNT",
            defaultsKey: "HermesMonitor.keychainAccount",
            defaults: defaults,
            environment: environment
        ) ?? "\(username)@\(host)"
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
            credentialReference: SSHCredentialReference(service: service, account: account),
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
