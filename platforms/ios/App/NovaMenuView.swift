import SwiftUI
import UIKit
import SafariServices

/// Nova's game-ready home screen. Keep all launcher presentation on the iOS
/// side; this view never touches the upstream Horizon engine or its controls.
struct NovaMenuView: View {
    let onPlay: () -> Void
    let onEdit: () -> Void
    let onSettings: () -> Void
    let onLogs: () -> Void
    let onClose: () -> Void

    @StateObject private var accounts = NovaMicrosoftAccount()
    @StateObject private var elyAccount = NovaElyAccount()
    @State private var showAccounts = false
    @State private var confirmClose = false
    @State private var showDiscord = false
    @State private var packCategory: NovaPackCategory?
    @State private var showMods = false

    // Exact colors requested for the redesign.
    private enum Palette {
        static let header = Color(red: 0x38 / 255.0, green: 0x38 / 255.0, blue: 0x38 / 255.0)
        static let background = Color(red: 0x75 / 255.0, green: 0x75 / 255.0, blue: 0x75 / 255.0)
        static let forceClose = Color(red: 1.0, green: 0x42 / 255.0, blue: 0x42 / 255.0)
        static let button = Color(red: 0xA4 / 255.0, green: 0x66 / 255.0, blue: 1.0)
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let columnWidth = max(150, width * 0.25)
            let tileHeight = max(44, height * 0.095)
            let gap = max(7, height * 0.016)
            let labelSize = max(16, min(29, height * 0.033))

            VStack(spacing: 0) {
                header(width: width, height: height * 0.20)
                    .frame(height: height * 0.20)
                    .background(Palette.header)

                ZStack(alignment: .bottom) {
                    Palette.background

                    HStack(alignment: .bottom, spacing: 0) {
                        VStack(spacing: gap) {
                            tile("custom controls", size: labelSize, action: onEdit)
                            tile("mouse settings", size: labelSize, action: onSettings)
                            tile("logs", size: labelSize, action: onLogs)
                        }
                        .frame(width: columnWidth)
                        .frame(height: tileHeight * 3 + gap * 2)

                        Spacer(minLength: 0)

                        VStack(spacing: gap) {
                            tile("discord", size: labelSize) { showDiscord = true }
                            tile("download shaders", size: labelSize) { packCategory = .shader }
                            tile("download resource packs", size: labelSize) { packCategory = .resourcePack }
                            tile("manage mods", size: labelSize) { showMods = true }
                        }
                        .frame(width: columnWidth)
                        .frame(height: tileHeight * 4 + gap * 3)
                    }
                    .padding(.horizontal, max(8, width * 0.01))
                    .padding(.bottom, max(6, height * 0.008))

                    tile("PLAY", size: max(28, min(56, height * 0.06)), action: onPlay)
                        .frame(width: width * 0.275, height: max(60, height * 0.138))
                        .padding(.bottom, height * 0.085)
                }
            }
            .frame(width: width, height: height)
        }
        .ignoresSafeArea()
        .sheet(isPresented: $showAccounts) {
            NovaAccountSheet(account: accounts)
        }
        .sheet(isPresented: $showDiscord) {
            NovaDiscordBrowser()
        }
        .sheet(item: $packCategory) { category in
            NovaPackBrowser(category: category)
        }
        .sheet(isPresented: $showMods) {
            NovaModsView()
        }
        .confirmationDialog("Force close Nova?", isPresented: $confirmClose) {
            Button("Force Close App", role: .destructive, action: onClose)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The app exits immediately. Unsaved world changes can be lost.")
        }
    }

    private func header(width: CGFloat, height: CGFloat) -> some View {
        let headSize = min(height * 0.78, 140)
        return HStack(spacing: max(14, width * 0.035)) {
            Button {
                showAccounts = true
            } label: {
                HStack(spacing: max(10, width * 0.015)) {
                    AsyncImage(url: URL(string: accounts.profile.map {
                        "https://mc-heads.net/head/\($0.uuid)/128"
                    } ?? "https://mc-heads.net/head/MHF_Steve/128")) { image in
                        image.resizable().interpolation(.none).scaledToFit()
                    } placeholder: {
                        Image(systemName: "person.crop.square.fill")
                            .resizable().scaledToFit()
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    .frame(width: headSize, height: headSize)

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 5) {
                            Text(accounts.profile?.name ?? "Steve")
                                .font(.system(size: max(22, min(46, height * 0.30))))
                                .lineLimit(1)
                                .minimumScaleFactor(0.65)
                            Image(systemName: "chevron.down")
                                .font(.caption.bold())
                        }
                        Text("after logging in or switching accounts restart the launcher")
                            .font(.system(size: max(10, min(13, height * 0.095))))
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                            .foregroundStyle(.white.opacity(0.80))
                    }
                    .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Minecraft account: \(accounts.profile?.name ?? "Steve"). Tap to switch accounts")
            .frame(maxWidth: width * 0.69, alignment: .leading)

            Spacer(minLength: 8)

            tile("force close", tint: Palette.forceClose,
                 size: max(17, min(32, height * 0.18))) {
                confirmClose = true
            }
            .frame(width: max(135, width * 0.19),
                   height: max(44, height * 0.55))
        }
        .padding(.horizontal, max(12, width * 0.013))
    }

    private func tile(_ title: String,
                      tint: Color = Palette.button,
                      size: CGFloat,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: size, weight: .regular))
                .foregroundStyle(.black)
                .lineLimit(1)
                .minimumScaleFactor(0.52)
                .padding(.horizontal, 5)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(tint)
        }
        .buttonStyle(.plain)
    }

}

/// Safari's in-app browser avoids requiring the Discord app to be installed.
private struct NovaDiscordBrowser: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: URL(string: "https://discord.gg/aH9mtNDc24")!)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

/// Only public Minecraft names/UUIDs appear here. Secrets stay in Keychain.
private struct NovaAccountSheet: View {
    @ObservedObject var account: NovaMicrosoftAccount
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Current player") {
                    HStack {
                        Image(systemName: account.profile == nil ? "person.fill" : "checkmark.shield.fill")
                        Text(account.profile?.name ?? "Steve (offline)")
                    }
                    Button("Use Steve (offline)") { account.signOut() }
                        .disabled(account.profile == nil)
                }
                if !account.accounts.isEmpty {
                    Section("Saved Minecraft accounts") {
                        ForEach(account.accounts) { saved in
                            HStack {
                                Button {
                                    account.select(saved)
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: account.profile?.uuid == saved.uuid
                                              ? "checkmark.circle.fill" : "circle")
                                        Text(saved.name)
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                Button(role: .destructive) {
                                    Task { await account.remove(saved) }
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .accessibilityLabel("Remove \(saved.name)")
                            }
                        }
                    }
                }
                Section("Microsoft sign-in") {
                    switch account.state {
                    case .idle:
                        Button("Add Microsoft account") { account.signIn() }
                    case let .working(stage):
                        HStack {
                            ProgressView()
                            Text(stage)
                        }
                        Button("Cancel sign-in") { account.cancel() }
                    case let .code(code, _):
                        Text("Open Microsoft's sign-in page and enter this one-time code:")
                        Text(code)
                            .font(.system(.title2, design: .monospaced).bold())
                            .textSelection(.enabled)
                        Button("Copy code") { UIPasteboard.general.string = code }
                        Button("Open microsoft.com/link") {
                            UIApplication.shared.open(URL(string: "https://www.microsoft.com/link")!)
                        }
                        Button("Cancel sign-in") { account.cancel() }
                    case let .failed(message):
                        Text(message).foregroundStyle(.red)
                        Button("Try signing in again") { account.signIn() }
                    }
                    if NovaMicrosoftAccount.clientID == nil {
                        Text("Microsoft sign-in is not configured in this build. The distributor must provide an approved application ID.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Ely.by sign-in") {
                    switch elyAccount.state {
                    case .idle:
                        Button("Add Ely.by account") { elyAccount.signIn() }
                    case let .working(stage):
                        HStack {
                            ProgressView()
                            Text(stage)
                        }
                        Button("Cancel sign-in") { elyAccount.cancel() }
                    case let .code(code, url):
                        Text("Open the link and enter this code:")
                        Text(code)
                            .font(.system(.title2, design: .monospaced).bold())
                            .textSelection(.enabled)
                        Button("Copy code") { UIPasteboard.general.string = code }
                        Button("Open sign-in page") { UIApplication.shared.open(url) }
                        Button("Cancel sign-in") { elyAccount.cancel() }
                    case let .failed(message):
                        Text(message).foregroundStyle(.red)
                        Button("Try signing in again") { elyAccount.signIn() }
                    }
                    if NovaElyAccount.clientID == nil {
                        Text("Ely.by sign-in is not configured in this build. The distributor must provide an approved application ID.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    if let bootIssue = UserDefaults.standard.string(forKey: NovaAccountBoot.issueKey) {
                        Text(bootIssue).foregroundStyle(.orange)
                    }
                    Text("after logging in or switching accounts restart the launcher")
                        .font(.footnote)
                    Text("Microsoft handles your password in its own browser. Nova stores Minecraft credentials only in iOS Keychain, not in exported game files or diagnostics.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Minecraft accounts")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
