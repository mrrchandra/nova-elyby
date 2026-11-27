// Ely.by account management for Nova (iOS).
// Based on Elyhorizon's desktop implementation and Nova's Microsoft account flow.
// Uses OAuth 2.0 authorization code with PKCE (S256) and loopback redirect.
//
// Ely.by docs: https://docs.ely.by/en/oauth.html
// Authlib-injector: https://docs.ely.by/en/authlib-injector.html

import Security
import SwiftUI
import UIKit
import CryptoKit
import Network

@MainActor
final class NovaElyAccount: ObservableObject {
    struct Profile: Codable, Equatable, Identifiable {
        let name: String
        let uuid: String
        var id: String { uuid }
    }
    struct Catalog: Codable { var profiles: [Profile]; var selected: String? }
    enum State: Equatable {
        case idle, working(String), code(String, URL), failed(String)
    }
    @Published private(set) var profile: Profile?
    @Published private(set) var accounts: [Profile] = []
    @Published private(set) var state = State.idle
    private var invalidSelection = false
    private let defaults: UserDefaults
    private let vault: AccountVault
    private let net: AccountNet
    private let now: () -> Date
    private let sleep: (UInt64) async throws -> Void
    private var signing: Task<Void, Never>?
    private var generation = UUID()
    private var selection = UUID()
    private var renewals: [String: Task<(Profile, AccountSecrets), Error>] = [:]
    private var pendingCodeVerifier: String?
    private var pendingState: String?

    nonisolated static var clientID: String? {
        (Bundle.main.object(forInfoDictionaryKey: "HorizonElyClientID") as? String)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty || $0.hasPrefix("$(") ? nil : $0 }
    }

    init(defaults: UserDefaults = .standard, vault: AccountVault = KeychainAccountVault(),
         session: URLSession = URLSession(configuration: .ephemeral), clock: @escaping () -> Date = Date.init,
         sleep: @escaping (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) {
        self.defaults = defaults; self.vault = vault; net = AccountNet(session: session)
        now = clock; self.sleep = sleep
        if let data = defaults.data(forKey: "elyAccounts.v1"),
           let saved = try? JSONDecoder().decode(Catalog.self, from: data) {
            accounts = saved.profiles
            profile = accounts.first { $0.uuid == saved.selected }
        }
    }

    private func saveCatalog() throws {
        defaults.set(try JSONEncoder().encode(Catalog(profiles: accounts, selected: profile?.uuid)),
                     forKey: "elyAccounts.v1")
    }

    func cancel() {
        generation = UUID(); signing?.cancel(); signing = nil; state = .idle
    }

    func select(_ selected: Profile?) {
        cancel(); profile = selected
        do { try saveCatalog() } catch {
            state = .failed("Account operation failed. Try again.")
        }
    }

    func remove(_ account: Profile) async {
        cancel()
        renewals.removeValue(forKey: account.uuid)?.cancel()
        do {
            try vault.remove(account.uuid)
            accounts.removeAll { $0.uuid == account.uuid }
            if profile?.uuid == account.uuid { profile = nil }
            try saveCatalog()
        } catch {
            state = .failed("Account operation failed. Try again.")
        }
    }

    func signOut() { select(nil) }

    // MARK: - PKCE helpers

    private func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func codeChallenge(for verifier: String) -> String {
        let data = Data(verifier.utf8)
        let hash = SHA256.hash(data: data)
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func generateState() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Sign in

    func signIn() {
        guard let client = Self.clientID else {
            state = .failed("Ely.by sign-in isn't configured in this build.")
            return
        }
        cancel()
        let attempt = generation
        let epoch = selection
        let verifier = generateCodeVerifier()
        let challenge = codeChallenge(for: verifier)
        let stateParam = generateState()
        pendingCodeVerifier = verifier
        pendingState = stateParam

        let redirectPort = 19876
        let redirectURI = "http://127.0.0.1:\(redirectPort)/oauth/ely"

        var components = URLComponents(string: "https://account.ely.by/oauth/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: client),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "account_info minecraft_server_session"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: stateParam),
        ]
        guard let authURL = components.url else {
            state = .failed("Could not build authorization URL.")
            return
        }

        signing = Task {
            defer { if generation == attempt { signing = nil } }
            do {
                try Task.checkCancellation()
                state = .working("Opening Ely.by sign-in…")
                // Start loopback listener
                let code = try await listenForCallback(port: redirectPort, state: stateParam, timeout: 300)
                try Task.checkCancellation()
                guard generation == attempt, selection == epoch else { throw CancellationError() }
                state = .working("Signing in to Minecraft…")
                let tokens = try await exchangeCode(code, verifier: verifier, client: client, redirectURI: redirectURI)
                try Task.checkCancellation()
                guard generation == attempt, selection == epoch else { throw CancellationError() }
                let profile = try await fetchProfile(token: tokens.access, name: tokens.name)
                try Task.checkCancellation()
                guard generation == attempt, selection == epoch else { throw CancellationError() }
                try vault.write(AccountSecrets(refresh: tokens.refresh, token: tokens.access,
                                              expires: tokens.expires), for: profile.uuid)
                if let i = accounts.firstIndex(where: { $0.uuid == profile.uuid }) { accounts[i] = profile }
                else { accounts.append(profile) }
                try saveCatalog()
                profile = profile; invalidSelection = false; selection = UUID(); try saveCatalog()
                state = .idle; signing = nil
            } catch is CancellationError {
                if generation == attempt { state = .idle }
            } catch {
                guard generation == attempt else { return }
                state = .failed((error as? AccountError)?.localizedDescription ?? "Sign-in failed. Try again.")
            }
        }
    }

    // MARK: - Loopback listener

    private func listenForCallback(port: Int, state: String, timeout: TimeInterval) async throws -> String {
        // Use a simple TCP listener on localhost
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(integerLiteral: UInt16(port)))
        let codePromise = withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            var resumed = false
            listener.newConnectionHandler = { connection in
                connection.start(queue: .global())
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                    guard let data, let request = String(data: data, encoding: .utf8) else { return }
                    // Parse the callback URL
                    guard let firstLine = request.split(separator: "\r\n").first,
                          let path = firstLine.split(separator: " ").dropFirst().first,
                          let url = URL(string: "http://127.0.0.1:\(port)\(path)"),
                          let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                          let queryItems = components.queryItems else { return }
                    let code = queryItems.first(where: { $0.name == "code" })?.value
                    let returnedState = queryItems.first(where: { $0.name == "state" })?.value
                    // Send HTTP response
                    let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<html><body>Sign-in complete. You can close this tab.</body></html>"
                    connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                    if !resumed, returnedState == state, let code {
                        resumed = true
                        continuation.resume(returning: code)
                    }
                }
            }
            listener.start(queue: .global())
            // Timeout
            Task {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if !resumed {
                    resumed = true
                    listener.cancel()
                    continuation.resume(throwing: AccountError("Sign-in timed out. Try again."))
                }
            }
        }
        listener.cancel()
        return codePromise
    }

    // MARK: - Token exchange

    private func exchangeCode(_ code: String, verifier: String, client: String, redirectURI: String) async throws -> (access: String, refresh: String, expires: Date, name: String) {
        let answer = try await net.form("https://account.ely.by/oauth/token", [
            "grant_type": "authorization_code",
            "client_id": client,
            "code": code,
            "redirect_uri": redirectURI,
            "code_verifier": verifier,
        ], allowErrors: true)
        if let error = answer["error"] as? String {
            throw AccountError("Ely.by refused the sign-in: \(error).")
        }
        guard let access = answer["access_token"] as? String, !access.isEmpty,
              let refresh = answer["refresh_token"] as? String else {
            throw AccountError("Ely.by returned an incomplete session.")
        }
        let lifetime = (answer["expires_in"] as? Double) ?? 3600
        let expires = Date().addingTimeInterval(lifetime)
        // Fetch profile
        let profile = try await net.get("https://authserver.ely.by/session/profile/\(extractUUID(from: access))",
                                       token: access, allowErrors: true)
        let name = profile["name"] as? String ?? "Player"
        return (access, refresh, expires, name)
    }

    private func extractUUID(from token: String) -> String {
        // Ely.by access token is a JWT; extract UUID from sub claim
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return "" }
        var base64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sub = json["sub"] as? String else { return "" }
        return sub
    }

    private func fetchProfile(token: String, name: String) async throws -> Profile {
        // Use authserver.ely.by to get profile
        let url = "https://authserver.ely.by/api/users/profiles/minecraft/\(name)"
        let data = try await net.get(url, token: token, allowErrors: true)
        let id = data["id"] as? String ?? ""
        let profileName = data["name"] as? String ?? name
        let normalized = id.replacingOccurrences(of: "-", with: "").lowercased()
        guard normalized.count == 32 else {
            throw AccountError("Ely.by returned an invalid profile.")
        }
        return Profile(name: profileName, uuid: normalized)
    }
}
PYEOF