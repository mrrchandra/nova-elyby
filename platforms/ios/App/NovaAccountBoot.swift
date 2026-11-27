import Foundation
import Darwin

/// Supplies Horizon with an authenticated session before its one-shot iOS
/// winit/UIWindow entry. Nothing sensitive is stored under Documents/Nova.
enum NovaAccountBoot {
    static let issueKey = "nova.account.startupIssue"

    /// Main-thread startup entry. Network refresh runs on a detached worker:
    /// the game cannot start until its initial identity has been selected.
    static func prepare() {
        // Wipe any leftover private handoff, including after sign-out or a crash.
        removeStaleHandoffs()
        unsetenv("HORIZON_SESSION_FILE")
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: issueKey)

        // Try Microsoft accounts first
        if let publicData = defaults.data(forKey: "microsoftAccounts.v2"),
           let catalog = try? JSONDecoder().decode(NovaMicrosoftAccount.Catalog.self, from: publicData),
           let selectedID = catalog.selected,
           let selected = catalog.profiles.first(where: { $0.uuid == selectedID }) {
            // Microsoft boot path (existing)
            bootMicrosoft(selected: selected, catalog: catalog, defaults: defaults)
            return
        }

        // Try Ely.by accounts
        if let publicData = defaults.data(forKey: "elyAccounts.v1"),
           let catalog = try? JSONDecoder().decode(NovaElyAccount.Catalog.self, from: publicData),
           let selectedID = catalog.selected,
           let selected = catalog.profiles.first(where: { $0.uuid == selectedID }) {
            bootEly(selected: selected, defaults: defaults)
            return
        }

        // No account configured - offline mode
        return
    }

    private static func bootMicrosoft(selected: NovaMicrosoftAccount.Profile, catalog: NovaMicrosoftAccount.Catalog, defaults: UserDefaults) {
        let vault = KeychainAccountVault()
        do {
            guard var secrets = try vault.read(selected.uuid) else {
                defaults.set("This account needs Microsoft sign-in again.", forKey: issueKey)
                return
            }
            var profile = selected
            // A nearly expired Minecraft session must be renewed before boot
            if secrets.expires.timeIntervalSinceNow < 300 {
                guard let clientID = NovaMicrosoftAccount.clientID else {
                    defaults.set("Microsoft sign-in is not configured in this build.", forKey: issueKey)
                    return
                }
                let completed = DispatchSemaphore(value: 0)
                let outcome = Outcome()
                let savedSecrets = secrets
                let task = Task.detached(priority: .userInitiated) {
                    do {
                        let renewed = try await NovaMicrosoftAccount.refresh(clientID, savedSecrets.refresh)
                        try Task.checkCancellation()
                        try vault.write(AccountSecrets(refresh: renewed.refresh,
                                                       token: savedSecrets.token, expires: savedSecrets.expires),
                                        for: selected.uuid)
                        let (identity, credentials) = try await NovaMicrosoftAccount.exchange(microsoft: renewed)
                        guard identity.uuid == selected.uuid else {
                            throw AccountError("Microsoft returned a different account. Sign in again.")
                        }
                        try Task.checkCancellation()
                        try vault.write(credentials, for: selected.uuid)
                        outcome.store(.success((identity, credentials)))
                    } catch {
                        outcome.store(.failure(error))
                    }
                    completed.signal()
                }
                guard completed.wait(timeout: .now() + 90) == .success else {
                    task.cancel()
                    defaults.set("Account renewal timed out. Restart and try again.", forKey: issueKey)
                    return
                }
                switch outcome.take() {
                case let .some(.success((identity, credentials))):
                    profile = identity
                    secrets = credentials
                default:
                    defaults.set("Unable to renew the Microsoft account. Check sign-in and restart.", forKey: issueKey)
                    return
                }
            }
            guard secrets.expires.timeIntervalSinceNow > 60 else {
                defaults.set("Minecraft session expired. Sign in again and restart.", forKey: issueKey)
                return
            }
            let payload = try JSONSerialization.data(withJSONObject: [
                "name": profile.name,
                "uuid": profile.uuid,
                "access_token": secrets.token,
                "user_type": "msa"
            ])
            let sessionFile = try createPrivateHandoff(payload)
            guard setenv("HORIZON_SESSION_FILE", sessionFile.path, 1) == 0 else {
                try? FileManager.default.removeItem(at: sessionFile)
                defaults.set("Could not prepare authenticated gameplay. Restart Nova.", forKey: issueKey)
                return
            }
            NovaDiagnostics.record("account.session-ready; private-handoff=true")
        } catch {
            defaults.set("The selected account could not be loaded securely. Sign in again.", forKey: issueKey)
        }
    }

    private static func bootEly(selected: NovaElyAccount.Profile, defaults: UserDefaults) {
        let vault = KeychainAccountVault()
        do {
            guard let secrets = try vault.read(selected.uuid) else {
                defaults.set("This account needs Ely.by sign-in again.", forKey: issueKey)
                return
            }
            guard secrets.expires.timeIntervalSinceNow > 60 else {
                defaults.set("Ely.by session expired. Sign in again and restart.", forKey: issueKey)
                return
            }
            let payload = try JSONSerialization.data(withJSONObject: [
                "name": selected.name,
                "uuid": selected.uuid,
                "access_token": secrets.token,
                "user_type": "elyby"
            ])
            let sessionFile = try createPrivateHandoff(payload)
            guard setenv("HORIZON_SESSION_FILE", sessionFile.path, 1) == 0 else {
                try? FileManager.default.removeItem(at: sessionFile)
                defaults.set("Could not prepare authenticated gameplay. Restart Nova.", forKey: issueKey)
                return
            }
            NovaDiagnostics.record("account.session-ready; elyby=true; private-handoff=true")
        } catch {
            defaults.set("The selected Ely.by account could not be loaded securely. Sign in again.", forKey: issueKey)
        }
    }

    private final class Outcome: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<(NovaMicrosoftAccount.Profile, AccountSecrets), Error>?
        func store(_ value: Result<(NovaMicrosoftAccount.Profile, AccountSecrets), Error>) {
            lock.lock(); result = value; lock.unlock()
        }
        func take() -> Result<(NovaMicrosoftAccount.Profile, AccountSecrets), Error>? {
            lock.lock(); defer { lock.unlock() }
            return result
        }
    }

    private static func removeStaleHandoffs() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovaAccountSessions", isDirectory: true)
        if let stale = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) {
            for file in stale where file.lastPathComponent.hasPrefix("session-") {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private static func createPrivateHandoff(_ content: Data) throws -> URL {
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent("NovaAccountSessions", isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let url = directory.appendingPathComponent("session-\(UUID().uuidString).json")
        let descriptor = url.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
        }
        guard descriptor >= 0 else { throw AccountError("Could not create a private session.") }
        defer { _ = Darwin.close(descriptor) }
        do {
            try content.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { throw AccountError("Empty session.") }
                var written = 0
                while written < bytes.count {
                    let count = Darwin.write(descriptor, base.advanced(by: written), bytes.count - written)
                    if count > 0 { written += count }
                    else if count < 0 && errno == EINTR { continue }
                    else { throw AccountError("Could not write private session.") }
                }
            }
            _ = Darwin.fsync(descriptor)
            return url
        } catch {
            try? files.removeItem(at: url)
            throw error
        }
    }
}
