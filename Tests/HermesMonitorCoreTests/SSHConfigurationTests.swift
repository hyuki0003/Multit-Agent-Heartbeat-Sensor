import XCTest
@testable import HermesMonitorCore

final class SSHConfigurationTests: XCTestCase {
    func testPasswordModeBuildsPasswordOnlySFTPArguments() throws {
        let configuration = try makeConfiguration(authenticationMode: .password)

        let arguments = OpenSSHArgumentBuilder.sftpArguments(
            configuration: configuration,
            identityFile: URL(fileURLWithPath: "/tmp/must-not-be-used")
        )

        XCTAssertTrue(arguments.contains("PubkeyAuthentication=no"))
        XCTAssertTrue(arguments.contains("PreferredAuthentications=password"))
        XCTAssertTrue(arguments.contains("PasswordAuthentication=yes"))
        XCTAssertTrue(arguments.contains("KbdInteractiveAuthentication=no"))
        XCTAssertTrue(arguments.contains("NumberOfPasswordPrompts=1"))
        XCTAssertTrue(arguments.contains("BatchMode=no"))
        XCTAssertFalse(arguments.contains("-q"))
        XCTAssertFalse(arguments.contains("-i"))
        XCTAssertFalse(arguments.contains("/tmp/must-not-be-used"))
        XCTAssertTrue(arguments.contains("StrictHostKeyChecking=yes"))
        XCTAssertTrue(arguments.contains("UserKnownHostsFile=/Users/test/.ssh/known_hosts"))
        XCTAssertLessThan(
            try XCTUnwrap(arguments.firstIndex(of: "BatchMode=no")),
            try XCTUnwrap(arguments.firstIndex(of: "-b"))
        )
        XCTAssertEqual(Array(arguments.suffix(3)), ["-b", "-", "dhlee@monitor.example.com"])
    }

    func testPasswordModeBuildsPasswordOnlySSHArguments() throws {
        let configuration = try makeConfiguration(authenticationMode: .password)
        let command = "/usr/bin/stat --printf='Size: %s\\nModify: %y\\n' -- '/safe/database.db'"

        let arguments = OpenSSHArgumentBuilder.sshArguments(
            configuration: configuration,
            identityFile: URL(fileURLWithPath: "/tmp/must-not-be-used"),
            remoteCommand: command
        )

        XCTAssertTrue(arguments.contains("PubkeyAuthentication=no"))
        XCTAssertTrue(arguments.contains("PreferredAuthentications=password"))
        XCTAssertTrue(arguments.contains("PasswordAuthentication=yes"))
        XCTAssertTrue(arguments.contains("KbdInteractiveAuthentication=no"))
        XCTAssertTrue(arguments.contains("NumberOfPasswordPrompts=1"))
        XCTAssertTrue(arguments.contains("BatchMode=no"))
        XCTAssertFalse(arguments.contains("-q"))
        XCTAssertFalse(arguments.contains("-i"))
        XCTAssertFalse(arguments.contains("/tmp/must-not-be-used"))
        XCTAssertTrue(arguments.contains("StrictHostKeyChecking=yes"))
        XCTAssertTrue(arguments.contains("UserKnownHostsFile=/Users/test/.ssh/known_hosts"))
        XCTAssertEqual(Array(arguments.suffix(2)), ["dhlee@monitor.example.com", command])
    }

    func testPrivateKeyModePreservesExistingArguments() throws {
        let configuration = try makeConfiguration(authenticationMode: .privateKey)
        let identityFile = URL(fileURLWithPath: "/tmp/key")
        let command = "printf ready"

        XCTAssertEqual(
            OpenSSHArgumentBuilder.sftpArguments(
                configuration: configuration,
                identityFile: identityFile
            ),
            [
                "-P", "2222",
                "-i", "/tmp/key",
                "-o", "IdentitiesOnly=yes",
                "-o", "StrictHostKeyChecking=yes",
                "-o", "PasswordAuthentication=no",
                "-o", "KbdInteractiveAuthentication=no",
                "-o", "NumberOfPasswordPrompts=0",
                "-o", "BatchMode=no",
                "-o", "ConnectTimeout=10",
                "-o", "ServerAliveInterval=15",
                "-o", "ServerAliveCountMax=2",
                "-o", "UserKnownHostsFile=/Users/test/.ssh/known_hosts",
                "-b", "-", "dhlee@monitor.example.com"
            ]
        )
        XCTAssertEqual(
            OpenSSHArgumentBuilder.sshArguments(
                configuration: configuration,
                identityFile: identityFile,
                remoteCommand: command
            ),
            [
                "-p", "2222",
                "-i", "/tmp/key",
                "-o", "IdentitiesOnly=yes",
                "-o", "StrictHostKeyChecking=yes",
                "-o", "PasswordAuthentication=no",
                "-o", "KbdInteractiveAuthentication=no",
                "-o", "NumberOfPasswordPrompts=0",
                "-o", "BatchMode=no",
                "-o", "ConnectTimeout=10",
                "-o", "ServerAliveInterval=15",
                "-o", "ServerAliveCountMax=2",
                "-o", "UserKnownHostsFile=/Users/test/.ssh/known_hosts",
                "dhlee@monitor.example.com", command
            ]
        )
    }

    func testAuthenticationModeDefaultsToPrivateKey() throws {
        let configuration = try SSHConnectionConfiguration(
            host: "monitor.example.com",
            username: "dhlee",
            credentialReference: .init(service: "service", account: "account")
        )

        XCTAssertEqual(configuration.authenticationMode, .privateKey)
    }

    func testPasswordCredentialUsesAskPassWithoutWritingSecretToFilesOrArguments() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("credential-stager-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stager = SSHCredentialStager(fileManager: .default, rootDirectory: root)
        let password = "vpn-password-that-must-not-be-staged"
        let credential = SSHCredential(password: password)

        let staged = try stager.stage(credential, authenticationMode: .password)
        defer { stager.remove(staged) }

        XCTAssertNil(staged.identityFile)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: staged.directory.appendingPathComponent("identity").path
            )
        )
        let askPassFile = try XCTUnwrap(staged.askPassFile)
        let askPassScript = try String(contentsOf: askPassFile, encoding: .utf8)
        XCTAssertFalse(askPassScript.contains(password))
        XCTAssertEqual(
            try XCTUnwrap(
                FileManager.default.attributesOfItem(atPath: askPassFile.path)[.posixPermissions]
                    as? NSNumber
            ).intValue,
            0o700
        )

        let environment = SSHAskPassEnvironment.make(
            base: ["PATH": "/usr/bin"],
            secret: try XCTUnwrap(credential.askPassSecret(for: .password)),
            askPassFile: askPassFile
        )
        XCTAssertEqual(environment[SSHAskPassEnvironment.secretKey], password)
        XCTAssertEqual(environment["SSH_ASKPASS"], askPassFile.path)
        XCTAssertEqual(environment["SSH_ASKPASS_REQUIRE"], "force")

        let arguments = OpenSSHArgumentBuilder.sshArguments(
            configuration: try makeConfiguration(authenticationMode: .password),
            identityFile: staged.identityFile,
            remoteCommand: "printf ready"
        )
        XCTAssertFalse(arguments.contains(where: { $0.contains(password) }))
        XCTAssertFalse(arguments.contains("-i"))
    }

    func testPrivateKeyPassphraseUsesAskPassWithoutWritingSecretToFilesOrArguments() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("credential-stager-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stager = SSHCredentialStager(fileManager: .default, rootDirectory: root)
        let passphrase = "private-key-passphrase-that-must-not-be-staged"
        let credential = SSHCredential(
            privateKey: Data("private-key".utf8),
            passphrase: passphrase
        )

        let staged = try stager.stage(credential, authenticationMode: .privateKey)
        defer { stager.remove(staged) }

        let identityFile = try XCTUnwrap(staged.identityFile)
        XCTAssertEqual(try Data(contentsOf: identityFile), Data("private-key".utf8))
        let askPassFile = try XCTUnwrap(staged.askPassFile)
        let askPassScript = try String(contentsOf: askPassFile, encoding: .utf8)
        XCTAssertFalse(askPassScript.contains(passphrase))

        let environment = SSHAskPassEnvironment.make(
            base: ["PATH": "/usr/bin"],
            secret: try XCTUnwrap(credential.askPassSecret(for: .privateKey)),
            askPassFile: askPassFile
        )
        XCTAssertEqual(environment[SSHAskPassEnvironment.secretKey], passphrase)
        XCTAssertEqual(environment["SSH_ASKPASS"], askPassFile.path)

        let arguments = OpenSSHArgumentBuilder.sshArguments(
            configuration: try makeConfiguration(authenticationMode: .privateKey),
            identityFile: identityFile,
            remoteCommand: "printf ready"
        )
        XCTAssertFalse(arguments.contains(where: { $0.contains(passphrase) }))
        XCTAssertTrue(arguments.contains("-i"))
    }

    func testAskPassEnvironmentScrubsInheritedValues() {
        let inherited = [
            "PATH": "/usr/bin",
            SSHAskPassEnvironment.secretKey: "inherited-secret",
            "HERMES_MONITOR_SSH_PASSPHRASE": "legacy-secret",
            "SSH_ASKPASS": "/tmp/inherited-askpass",
            "SSH_ASKPASS_REQUIRE": "prefer"
        ]

        let environment = SSHAskPassEnvironment.make(base: inherited)

        XCTAssertEqual(environment["PATH"], "/usr/bin")
        XCTAssertNil(environment[SSHAskPassEnvironment.secretKey])
        XCTAssertNil(environment["HERMES_MONITOR_SSH_PASSPHRASE"])
        XCTAssertNil(environment["SSH_ASKPASS"])
        XCTAssertNil(environment["SSH_ASKPASS_REQUIRE"])
    }

    func testFailedCredentialSaveDoesNotCommitCredentialSelection() throws {
        enum SaveFailure: Error { case rejected }
        let credential = SSHCredential(password: "keychain-password")
        let originalSelection = SSHCredentialSelection(
            authenticationMode: .privateKey,
            reference: SSHCredentialReference(service: "original-service", account: "original-account")
        )
        let draftSelection = SSHCredentialSelection(
            authenticationMode: .password,
            reference: SSHCredentialReference(service: "draft-service", account: "draft-account")
        )
        var persistedSelection = originalSelection
        var commitCount = 0

        do {
            try SSHCredentialSaveTransaction.save(
                credential,
                selection: draftSelection
            ) { _, _ in
                throw SaveFailure.rejected
            } commit: { selection in
                commitCount += 1
                persistedSelection = selection
            }
            XCTFail("A failed Keychain save must not commit its draft selection")
        } catch SaveFailure.rejected {
            // Expected.
        }
        XCTAssertEqual(commitCount, 0)
        XCTAssertEqual(persistedSelection, originalSelection)
    }

    func testSuccessfulCredentialSaveCommitsModeServiceAndAccountTogether() throws {
        let credential = SSHCredential(password: "keychain-password")
        let draftSelection = SSHCredentialSelection(
            authenticationMode: .password,
            reference: SSHCredentialReference(service: "draft-service", account: "draft-account")
        )
        var persistedSelection = SSHCredentialSelection(
            authenticationMode: .privateKey,
            reference: SSHCredentialReference(service: "original-service", account: "original-account")
        )
        var commitCount = 0

        try SSHCredentialSaveTransaction.save(
            credential,
            selection: draftSelection
        ) { savedCredential, savedReference in
            XCTAssertEqual(savedCredential, credential)
            XCTAssertEqual(savedReference, draftSelection.reference)
        } commit: { selection in
            commitCount += 1
            persistedSelection = selection
        }
        XCTAssertEqual(commitCount, 1)
        XCTAssertEqual(persistedSelection, draftSelection)
    }

    func testEditorSaveClearsEmptyPasswordAfterValidationFailure() {
        var password = ""
        var passphrase = "temporary-passphrase"
        var privateKeyData: Data? = Data("temporary-key".utf8)
        var cleanupCount = 0
        let selection = SSHCredentialSelection(
            authenticationMode: .password,
            reference: SSHCredentialReference(service: "service", account: "account")
        )

        XCTAssertThrowsError(
            try SSHCredentialEditorSaveTransaction.save(
                resolveSelection: { selection },
                makeCredential: { _ in SSHCredential(password: password) },
                using: { _, _ in XCTFail("Invalid credentials must not reach Keychain") },
                commit: { _ in XCTFail("Invalid credentials must not be committed") },
                cleanup: {
                    cleanupCount += 1
                    password = ""
                    passphrase = ""
                    privateKeyData = nil
                }
            )
        ) { error in
            XCTAssertEqual(error as? SSHCredentialValidationError, .emptyPassword)
        }
        XCTAssertEqual(cleanupCount, 1)
        XCTAssertTrue(password.isEmpty)
        XCTAssertTrue(passphrase.isEmpty)
        XCTAssertNil(privateKeyData)
    }

    func testEditorSaveClearsPassphraseWhenPrivateKeyIsMissing() {
        enum EditorFailure: Error, Equatable { case privateKeyNotSelected }
        var privateKeyData: Data?
        var passphrase = "temporary-passphrase"
        var password = "temporary-password"
        var cleanupCount = 0
        let selection = SSHCredentialSelection(
            authenticationMode: .privateKey,
            reference: SSHCredentialReference(service: "service", account: "account")
        )

        XCTAssertThrowsError(
            try SSHCredentialEditorSaveTransaction.save(
                resolveSelection: { selection },
                makeCredential: { _ in
                    guard let privateKeyData else { throw EditorFailure.privateKeyNotSelected }
                    return SSHCredential(privateKey: privateKeyData, passphrase: passphrase)
                },
                using: { _, _ in XCTFail("Missing private keys must not reach Keychain") },
                commit: { _ in XCTFail("Missing private keys must not be committed") },
                cleanup: {
                    cleanupCount += 1
                    privateKeyData = nil
                    passphrase = ""
                    password = ""
                }
            )
        ) { error in
            XCTAssertEqual(error as? EditorFailure, .privateKeyNotSelected)
        }
        XCTAssertEqual(cleanupCount, 1)
        XCTAssertNil(privateKeyData)
        XCTAssertTrue(passphrase.isEmpty)
        XCTAssertTrue(password.isEmpty)
    }

    func testEditorSaveClearsSecretsWhenKeychainSaveThrows() {
        enum SaveFailure: Error, Equatable { case rejected }
        var password = "temporary-password"
        var passphrase = "temporary-passphrase"
        var privateKeyData: Data? = Data("temporary-key".utf8)
        var didCommit = false
        var cleanupCount = 0
        let selection = SSHCredentialSelection(
            authenticationMode: .password,
            reference: SSHCredentialReference(service: "service", account: "account")
        )

        XCTAssertThrowsError(
            try SSHCredentialEditorSaveTransaction.save(
                resolveSelection: { selection },
                makeCredential: { _ in SSHCredential(password: password) },
                using: { _, _ in throw SaveFailure.rejected },
                commit: { _ in didCommit = true },
                cleanup: {
                    cleanupCount += 1
                    password = ""
                    passphrase = ""
                    privateKeyData = nil
                }
            )
        ) { error in
            XCTAssertEqual(error as? SaveFailure, .rejected)
        }
        XCTAssertFalse(didCommit)
        XCTAssertEqual(cleanupCount, 1)
        XCTAssertTrue(password.isEmpty)
        XCTAssertTrue(passphrase.isEmpty)
        XCTAssertNil(privateKeyData)
    }

    func testEditorSaveClearsAllSecretsExactlyOnceAfterSuccessfulSave() throws {
        var password = "temporary-password"
        var passphrase = "temporary-passphrase"
        var privateKeyData: Data? = Data("temporary-key".utf8)
        var cleanupCount = 0
        var commitCount = 0
        let selection = SSHCredentialSelection(
            authenticationMode: .password,
            reference: SSHCredentialReference(service: "service", account: "account")
        )

        try SSHCredentialEditorSaveTransaction.save(
            resolveSelection: { selection },
            makeCredential: { _ in SSHCredential(password: password) },
            using: { credential, reference in
                XCTAssertEqual(credential, SSHCredential(password: "temporary-password"))
                XCTAssertEqual(reference, selection.reference)
            },
            commit: { committedSelection in
                commitCount += 1
                XCTAssertEqual(committedSelection, selection)
            },
            cleanup: {
                cleanupCount += 1
                password = ""
                passphrase = ""
                privateKeyData = nil
            }
        )

        XCTAssertEqual(commitCount, 1)
        XCTAssertEqual(cleanupCount, 1)
        XCTAssertTrue(password.isEmpty)
        XCTAssertTrue(passphrase.isEmpty)
        XCTAssertNil(privateKeyData)
    }

    func testCancellingCredentialSelectionDraftRestoresAllOriginalValues() {
        var draft = SSHCredentialSelectionDraft(
            authenticationMode: .privateKey,
            keychainService: "original-service",
            keychainAccount: "original-account"
        )
        draft.authenticationMode = .password
        draft.keychainService = "draft-service"
        draft.keychainAccount = "draft-account"

        draft.cancel()

        XCTAssertEqual(draft.authenticationMode, .privateKey)
        XCTAssertEqual(draft.keychainService, "original-service")
        XCTAssertEqual(draft.keychainAccount, "original-account")
    }

    func testCredentialPreferenceSnapshotUsesEnvironmentBeforeStoredValues() throws {
        let snapshot = SSHCredentialPreferenceSnapshot.resolve(
            storedHost: "stored.example.com",
            storedUsername: "stored-user",
            storedAuthenticationMode: SSHAuthenticationMode.privateKey.rawValue,
            storedKeychainService: "stored-service",
            storedKeychainAccount: "stored-account",
            environment: [
                "HERMES_MONITOR_HOST": "environment.example.com",
                "HERMES_MONITOR_USERNAME": "environment-user",
                "HERMES_MONITOR_AUTHENTICATION_MODE": SSHAuthenticationMode.password.rawValue,
                "HERMES_MONITOR_KEYCHAIN_SERVICE": "environment-service",
                "HERMES_MONITOR_KEYCHAIN_ACCOUNT": "environment-account"
            ],
            fallbackUsername: "fallback-user"
        )

        XCTAssertEqual(snapshot.host, "environment.example.com")
        XCTAssertEqual(snapshot.username, "environment-user")
        XCTAssertEqual(snapshot.authenticationMode, .password)
        XCTAssertEqual(snapshot.keychainService, "environment-service")
        XCTAssertEqual(snapshot.keychainAccount, "environment-account")
        XCTAssertEqual(
            try XCTUnwrap(snapshot.credentialSelection),
            SSHCredentialSelection(
                authenticationMode: .password,
                reference: SSHCredentialReference(
                    service: "environment-service",
                    account: "environment-account"
                )
            )
        )
    }

    func testCredentialPreferenceSnapshotUsesEffectiveEnvironmentIdentityForDefaultAccount() {
        let snapshot = SSHCredentialPreferenceSnapshot.resolve(
            storedHost: "stored.example.com",
            storedUsername: "stored-user",
            storedAuthenticationMode: nil,
            storedKeychainService: nil,
            storedKeychainAccount: nil,
            environment: [
                "HERMES_MONITOR_HOST": "environment.example.com",
                "HERMES_MONITOR_USERNAME": "environment-user"
            ],
            fallbackUsername: "fallback-user"
        )

        XCTAssertEqual(snapshot.authenticationMode, .privateKey)
        XCTAssertEqual(snapshot.keychainService, "com.hermes.monitor.ssh")
        XCTAssertEqual(snapshot.keychainAccount, "environment-user@environment.example.com")
    }

    func testEnvironmentOnlyIdentityIsMarkedEnvironmentControlledForSettings() {
        let snapshot = SSHCredentialPreferenceSnapshot.resolve(
            storedHost: nil,
            storedUsername: nil,
            storedAuthenticationMode: nil,
            storedKeychainService: nil,
            storedKeychainAccount: nil,
            environment: [
                "HERMES_MONITOR_HOST": "environment.example.com",
                "HERMES_MONITOR_USERNAME": "environment-user"
            ],
            fallbackUsername: "fallback-user"
        )

        XCTAssertEqual(snapshot.host, "environment.example.com")
        XCTAssertEqual(snapshot.username, "environment-user")
        XCTAssertTrue(snapshot.isHostEnvironmentControlled)
        XCTAssertTrue(snapshot.isUsernameEnvironmentControlled)
    }

    func testPartialIdentityOverrideOnlyMarksEnvironmentControlledField() {
        let snapshot = SSHCredentialPreferenceSnapshot.resolve(
            storedHost: "stored.example.com",
            storedUsername: "stored-user",
            storedAuthenticationMode: nil,
            storedKeychainService: nil,
            storedKeychainAccount: nil,
            environment: ["HERMES_MONITOR_HOST": "environment.example.com"],
            fallbackUsername: "fallback-user"
        )

        XCTAssertEqual(snapshot.host, "environment.example.com")
        XCTAssertEqual(snapshot.username, "stored-user")
        XCTAssertTrue(snapshot.isHostEnvironmentControlled)
        XCTAssertFalse(snapshot.isUsernameEnvironmentControlled)
    }

    func testInvalidEnvironmentAuthenticationModeIsRejectedForSettingsAndRuntime() {
        let invalidMode = "keyboard-interactive"
        let snapshot = SSHCredentialPreferenceSnapshot.resolve(
            storedHost: "stored.example.com",
            storedUsername: "stored-user",
            storedAuthenticationMode: SSHAuthenticationMode.privateKey.rawValue,
            storedKeychainService: nil,
            storedKeychainAccount: nil,
            environment: ["HERMES_MONITOR_AUTHENTICATION_MODE": invalidMode],
            fallbackUsername: "fallback-user"
        )

        XCTAssertNil(snapshot.authenticationMode)
        XCTAssertTrue(snapshot.isAuthenticationModeEnvironmentControlled)
        XCTAssertThrowsError(try snapshot.requireAuthenticationMode()) { error in
            XCTAssertEqual(
                error as? SSHAuthenticationModeResolutionError,
                .invalidValue(invalidMode)
            )
            XCTAssertEqual(
                error.localizedDescription,
                "Invalid SSH authentication mode: \(invalidMode)."
            )
        }
    }

    func testRuntimeValidationRejectsInvalidAuthenticationModeBeforeMissingHost() {
        let invalidMode = "keyboard-interactive"
        let snapshot = SSHCredentialPreferenceSnapshot.resolve(
            storedHost: "",
            storedUsername: "stored-user",
            storedAuthenticationMode: SSHAuthenticationMode.privateKey.rawValue,
            storedKeychainService: "stored-service",
            storedKeychainAccount: "stored-account",
            environment: ["HERMES_MONITOR_AUTHENTICATION_MODE": invalidMode],
            fallbackUsername: "fallback-user"
        )

        XCTAssertThrowsError(try snapshot.validatedRuntimeCredentialSelection()) { error in
            XCTAssertEqual(
                error as? SSHAuthenticationModeResolutionError,
                .invalidValue(invalidMode)
            )
        }
    }

    func testResolvesDefaultCredentialAccountFromUsernameAndHost() {
        XCTAssertEqual(
            SSHCredentialReference.resolvedAccount(nil, username: "dhlee", host: "192.168.1.203"),
            "dhlee@192.168.1.203"
        )
        XCTAssertEqual(
            SSHCredentialReference.resolvedAccount("", username: "dhlee", host: "research-203"),
            "dhlee@research-203"
        )
        XCTAssertEqual(
            SSHCredentialReference.resolvedAccount(
                "custom-account",
                username: "dhlee",
                host: "research-203"
            ),
            "custom-account"
        )
    }

    func testCredentialStagerCreatesPrivateDirectoryAndIdentityFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("credential-stager-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stager = SSHCredentialStager(fileManager: .default, rootDirectory: root)

        let staged = try stager.stage(
            SSHCredential(privateKey: Data("private-key".utf8)),
            authenticationMode: .privateKey
        )
        defer { stager.remove(staged) }

        let identityFile = try XCTUnwrap(staged.identityFile)
        let directoryMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: staged.directory.path)[.posixPermissions]
                as? NSNumber
        ).intValue
        let identityMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: identityFile.path)[.posixPermissions]
                as? NSNumber
        ).intValue
        XCTAssertEqual(directoryMode, 0o700)
        XCTAssertEqual(identityMode, 0o600)
        XCTAssertEqual(try Data(contentsOf: identityFile), Data("private-key".utf8))
    }

    func testDecodesExistingPrivateKeyCredentialJSON() throws {
        let existingJSON = Data(
            #"{"privateKey":"cHJpdmF0ZS1rZXk=","passphrase":"existing-passphrase"}"#.utf8
        )

        let credential = try JSONDecoder().decode(SSHCredential.self, from: existingJSON)

        XCTAssertEqual(credential.privateKey, Data("private-key".utf8))
        XCTAssertEqual(credential.passphrase, "existing-passphrase")
        XCTAssertNil(credential.password)
        XCTAssertNoThrow(try credential.validate(for: .privateKey))
    }

    func testPasswordCredentialCodableRoundTrip() throws {
        let original = SSHCredential(password: "keychain-password")

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SSHCredential.self, from: encoded)

        XCTAssertEqual(decoded, original)
        XCTAssertNil(decoded.privateKey)
        XCTAssertNil(decoded.passphrase)
        XCTAssertEqual(decoded.password, "keychain-password")
    }

    func testRejectsMissingOrEmptySelectedCredential() {
        XCTAssertThrowsError(try SSHCredential(password: "").validate(for: .password)) { error in
            XCTAssertEqual(error as? SSHCredentialValidationError, .emptyPassword)
            XCTAssertEqual(error.localizedDescription, "The selected Keychain SSH password is empty.")
        }
        XCTAssertThrowsError(
            try SSHCredential(privateKey: Data()).validate(for: .privateKey)
        ) { error in
            XCTAssertEqual(error as? SSHCredentialValidationError, .emptyPrivateKey)
            XCTAssertEqual(error.localizedDescription, "The selected Keychain SSH private key is empty.")
        }
        XCTAssertThrowsError(
            try SSHCredential(password: "password").validate(for: .privateKey)
        ) { error in
            XCTAssertEqual(error as? SSHCredentialValidationError, .emptyPrivateKey)
        }
        XCTAssertThrowsError(
            try SSHCredential(privateKey: Data("key".utf8)).validate(for: .password)
        ) { error in
            XCTAssertEqual(error as? SSHCredentialValidationError, .emptyPassword)
        }
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

    func testDatabaseSnapshotCommandAcceptsOnlyExactAllowlistedPaths() throws {
        let helper = "print('snapshot')"
        let command = try OpenSSHTransport.databaseSnapshotCommand(
            helper: helper,
            remotePath: RemotePathPolicy.kanbanDatabase
        )

        XCTAssertTrue(command.hasPrefix("/usr/bin/python3 -c "))
        XCTAssertTrue(command.contains(RemotePathPolicy.kanbanDatabase))
        let invalidPath = RemotePathPolicy.kanbanDatabase + ";touch /tmp/pwned"
        XCTAssertThrowsError(
            try OpenSSHTransport.databaseSnapshotCommand(
                helper: helper,
                remotePath: invalidPath
            )
        ) { error in
            XCTAssertEqual(error as? RemotePathPolicyError, .databasePathNotAllowed(invalidPath))
        }
    }

    private func makeConfiguration(
        authenticationMode: SSHAuthenticationMode
    ) throws -> SSHConnectionConfiguration {
        try SSHConnectionConfiguration(
            host: "monitor.example.com",
            port: 2222,
            username: "dhlee",
            authenticationMode: authenticationMode,
            credentialReference: .init(service: "com.example.HermesMonitor", account: "monitor-key"),
            knownHostsFile: URL(fileURLWithPath: "/Users/test/.ssh/known_hosts")
        )
    }
}