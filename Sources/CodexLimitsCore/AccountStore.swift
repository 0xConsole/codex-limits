#if canImport(AppKit)
import AppKit
import Foundation
import SwiftUI

@MainActor
public final class AccountStore: ObservableObject {
    public static let maximumAccounts = AccountLibrary.maximumAccounts

    @Published public private(set) var accounts: [SavedAccount] = []
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var activeLogin: ActiveLogin?
    @Published public internal(set) var autoResumeIsRunning = false
    @Published public internal(set) var autoResumeIsEnabled = false
    @Published public internal(set) var autoResumeStatus: String?
    @Published public internal(set) var desktopActiveAccountID: UUID?
    @Published public internal(set) var desktopSwitchingAccountID: UUID?
    @Published public internal(set) var desktopSwitchStatus: String?
    @Published public private(set) var otpAssistStatus: String?
    @Published public var bannerMessage: String?

    // Shared with AccountStore+AutoResume.swift.
    var loginTask: Task<Void, Never>?
    var autoResumeTask: Task<Void, Never>?
    var autoResumeCoordinatorIsActive = false
    var autoResumeLoginAccountID: UUID?
    var autoResumeState = AutoResumeControlState()
    let autoResumeCoordinator = AutoResumeCoordinator()
    let desktopAccountSwitcher = DesktopAccountSwitcher()

    private var activeLoginClient: CodexAppServerClient?
    private var otpAssistTask: Task<Void, Never>?
    private var refreshLoopTask: Task<Void, Never>?
    private var desktopSwitchAfterReauthenticationID: UUID?
    private var refreshingAccountIDs: Set<UUID> = []

    public init() {
        do {
            try AppPaths.ensureDirectories()
            accounts = try AccountLibrary.loadAccounts()
            autoResumeState = try AccountLibrary.loadAutoResumeControlState()
            autoResumeIsEnabled = autoResumeState.isArmed
            desktopActiveAccountID = desktopAccountSwitcher.activeSavedAccountID(accounts: accounts)
        } catch {
            bannerMessage = "Could not load saved accounts: \(error.localizedDescription)"
        }

        refreshLoopTask = Task { [weak self] in
            guard let self else { return }
            if !self.accounts.isEmpty {
                await self.refreshAll()
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                if Task.isCancelled { break }
                await self.refreshAll()
            }
        }

        if autoResumeIsEnabled {
            launchAutoResumeLoopIfNeeded()
        }
    }

    deinit {
        refreshLoopTask?.cancel()
        autoResumeTask?.cancel()
        loginTask?.cancel()
        otpAssistTask?.cancel()
    }

    /// Desktop switching and Auto Resume both rewrite Codex's login, so account changes
    /// wait until neither is running.
    private var isSwitchingOrResuming: Bool {
        desktopSwitchingAccountID != nil || autoResumeIsEnabled || autoResumeIsRunning
    }

    public var canAddAccount: Bool {
        accounts.count < Self.maximumAccounts && activeLogin == nil && !isSwitchingOrResuming
    }

    public var canAutoResume: Bool {
        activeLogin == nil && !isRefreshing && !isSwitchingOrResuming && !accounts.isEmpty
    }

    public var menuBarRemainingPercent: Int? {
        let values = accounts.compactMap { $0.usage?.fiveHour?.remainingPercent }
        guard let minimum = values.min() else { return nil }
        return Int(minimum.rounded())
    }

    public func canSwitchDesktopAccount(_ id: UUID) -> Bool {
        accounts.contains(where: { $0.id == id })
            && activeLogin == nil
            && !isRefreshing
            && !isSwitchingOrResuming
    }

    public func beginLogin() {
        guard canAddAccount else {
            if accounts.count >= Self.maximumAccounts {
                bannerMessage = "Codex Limits supports up to \(Self.maximumAccounts) accounts."
            }
            return
        }
        guard CodexLocator.locate() != nil else {
            bannerMessage = CodexClientError.codexNotFound.localizedDescription
            return
        }

        bannerMessage = nil
        let accountID = UUID()
        loginTask = Task { [weak self] in
            await self?.runLogin(accountID: accountID, replacingExisting: false)
        }
    }

    public func reauthenticate(account id: UUID) {
        guard activeLogin == nil,
              !isSwitchingOrResuming,
              accounts.contains(where: { $0.id == id })
        else { return }
        guard CodexLocator.locate() != nil else {
            bannerMessage = CodexClientError.codexNotFound.localizedDescription
            return
        }
        guard !refreshingAccountIDs.contains(id) else {
            bannerMessage = "That account is refreshing. Try signing in again in a moment."
            return
        }

        bannerMessage = nil
        loginTask = Task { [weak self] in
            await self?.runLogin(accountID: id, replacingExisting: true)
        }
    }

    public func reopenLoginPage() {
        guard let activeLogin else { return }
        NSWorkspace.shared.open(activeLogin.authorizationURL)
    }

    public func cancelLogin() {
        guard let activeLogin else { return }
        let client = activeLoginClient
        let isReauthentication = accounts.contains(where: { $0.id == activeLogin.id })
        loginTask?.cancel()
        stopOTPAssist()
        loginTask = nil
        self.activeLogin = nil
        activeLoginClient = nil
        if desktopSwitchAfterReauthenticationID == activeLogin.id {
            desktopSwitchAfterReauthenticationID = nil
            desktopSwitchStatus = "Desktop account switch cancelled."
        }

        Task {
            await client?.cancelLogin(loginID: activeLogin.loginID)
            await client?.stop()
            let abandonedHome = isReauthentication
                ? AppPaths.reauthenticationHome(for: activeLogin.id)
                : AppPaths.homeDirectory(for: activeLogin.id)
            try? FileManager.default.removeItem(at: abandonedHome)
        }
    }

    public func refreshAll() async {
        guard !isRefreshing, !isSwitchingOrResuming, !accounts.isEmpty else { return }
        guard CodexLocator.locate() != nil else {
            bannerMessage = CodexClientError.codexNotFound.localizedDescription
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }
        for account in accounts {
            if Task.isCancelled { break }
            await refreshOne(account: account.id)
        }
        persistAccounts()
        refreshDesktopActiveAccountFromDisk()
    }

    public func refresh(account id: UUID) async {
        guard !isSwitchingOrResuming, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await refreshOne(account: id)
        persistAccounts()
        refreshDesktopActiveAccountFromDisk()
    }

    public func switchDesktopAccount(to id: UUID) async {
        guard canSwitchDesktopAccount(id),
              let account = accounts.first(where: { $0.id == id })
        else { return }

        desktopSwitchingAccountID = id
        desktopSwitchStatus = "Checking \(account.email) before switching Codex Desktop…"
        bannerMessage = nil

        do {
            let snapshot = try await AccountLibrary.fetchSnapshot(for: id)
            guard let index = accounts.firstIndex(where: { $0.id == id }) else {
                desktopSwitchingAccountID = nil
                return
            }
            if let expectedAccountID = accounts[index].accountID,
               !expectedAccountID.isEmpty,
               snapshot.accountID != expectedAccountID {
                throw DesktopAccountSwitchError.invalidSavedIdentity
            }
            guard snapshot.email.caseInsensitiveCompare(accounts[index].email) == .orderedSame else {
                throw DesktopAccountSwitchError.invalidSavedIdentity
            }
            accounts[index] = accounts[index].refreshed(with: snapshot)
            persistAccounts()

            let target = accounts[index]
            let result = try await desktopAccountSwitcher.switchAccount(to: target, accounts: accounts) { [weak self] message in
                await MainActor.run {
                    self?.desktopSwitchStatus = message
                }
            }

            desktopActiveAccountID = id
            desktopSwitchStatus = result.alreadyActive
                ? "Codex Desktop is already signed in as \(result.accountEmail)."
                : "Codex Desktop is now signed in as \(result.accountEmail)."
            desktopSwitchingAccountID = nil
        } catch let clientError as CodexClientError where clientError.requiresSignIn {
            desktopSwitchingAccountID = nil
            desktopSwitchAfterReauthenticationID = id
            desktopSwitchStatus = "This login expired. Sign in again and Codex Desktop will switch to it."
            loginTask = Task { [weak self] in
                await self?.runLogin(accountID: id, replacingExisting: true)
            }
        } catch {
            desktopSwitchingAccountID = nil
            refreshDesktopActiveAccountFromDisk()
            desktopSwitchStatus = nil
            bannerMessage = error.localizedDescription
        }
    }

    public func remove(account id: UUID) {
        guard !isSwitchingOrResuming,
              let index = accounts.firstIndex(where: { $0.id == id })
        else { return }
        accounts.remove(at: index)
        try? FileManager.default.removeItem(at: AppPaths.homeDirectory(for: id))
        persistAccounts()
    }

    func runLogin(accountID: UUID, replacingExisting: Bool) async {
        let savedHome = AppPaths.homeDirectory(for: accountID)
        // A sign-in that refreshes an existing account runs in a scratch home, so a
        // failed or wrong-account attempt never touches the saved login.
        let home = replacingExisting ? AppPaths.reauthenticationHome(for: accountID) : savedHome
        let original = replacingExisting ? accounts.first(where: { $0.id == accountID }) : nil
        do {
            if replacingExisting {
                try? FileManager.default.removeItem(at: home)
            }
            try AppPaths.createPrivateDirectory(at: home)

            let client = try CodexAppServerClient(homeURL: home)
            activeLoginClient = client
            try await client.start()
            let ticket = try await client.startChatGPTLogin()
            activeLogin = ActiveLogin(id: accountID, loginID: ticket.loginID, authorizationURL: ticket.authorizationURL)
            NSWorkspace.shared.open(ticket.authorizationURL)
            if let original {
                startOTPAssist(for: original.email)
            }

            let completion = try await client.waitForLoginCompletion(loginID: ticket.loginID)
            stopOTPAssist()
            guard completion.success else {
                throw CodexClientError.loginFailed(completion.error ?? "Codex login did not complete.")
            }

            let snapshot = try await client.fetchAccountSnapshot(refreshToken: false)
            if let original, original.email.caseInsensitiveCompare(snapshot.email) != .orderedSame {
                throw CodexClientError.loginFailed(
                    "Signed in as \(snapshot.email). Sign in again and choose \(original.email) to refresh this saved account."
                )
            }
            if let originalAccountID = original?.accountID, snapshot.accountID != originalAccountID {
                throw CodexClientError.loginFailed(
                    "The sign-in completed for a different Codex workspace. Sign in again and choose the workspace previously saved for \(original?.email ?? "this account")."
                )
            }
            if AccountLibrary.isDuplicate(snapshot, in: accounts, excluding: original?.id) {
                throw CodexClientError.loginFailed("That Codex account is already in the menu bar app.")
            }

            let authFile = home.appendingPathComponent("auth.json")
            if FileManager.default.fileExists(atPath: authFile.path) {
                try AppPaths.restrictToOwner(authFile)
            }

            if replacingExisting, let index = accounts.firstIndex(where: { $0.id == accountID }) {
                guard FileManager.default.fileExists(atPath: authFile.path) else {
                    throw CodexClientError.loginFailed("Codex completed sign-in without saving account credentials.")
                }
                try AppPaths.createPrivateDirectory(at: savedHome)
                try AppPaths.writePrivateFile(Data(contentsOf: authFile), to: savedHome.appendingPathComponent("auth.json"))
                accounts[index] = accounts[index].refreshed(with: snapshot)
            } else {
                accounts.append(
                    SavedAccount(
                        id: accountID,
                        email: snapshot.email,
                        planType: snapshot.planType,
                        accountID: snapshot.accountID,
                        usage: snapshot.usage,
                        lastRefreshedAt: Date(),
                        lastError: nil,
                        needsReauthentication: false,
                        createdAt: Date()
                    )
                )
            }
            accounts.sort { $0.email.localizedCaseInsensitiveCompare($1.email) == .orderedAscending }
            persistAccounts()
            await client.stop()
            if replacingExisting {
                try? FileManager.default.removeItem(at: home)
            }
            finishLogin()
            if desktopSwitchAfterReauthenticationID == accountID {
                desktopSwitchAfterReauthenticationID = nil
                await switchDesktopAccount(to: accountID)
            }
        } catch {
            stopOTPAssist()
            await activeLoginClient?.stop()
            try? FileManager.default.removeItem(at: home)
            finishLogin()
            let cancelled = error is CancellationError
            if desktopSwitchAfterReauthenticationID == accountID {
                desktopSwitchAfterReauthenticationID = nil
                desktopSwitchStatus = cancelled ? "Desktop account switch cancelled." : nil
            }
            if !cancelled {
                bannerMessage = error.localizedDescription
            }
        }
    }

    private func finishLogin() {
        activeLogin = nil
        activeLoginClient = nil
        loginTask = nil
    }

    private func startOTPAssist(for email: String) {
        otpAssistTask?.cancel()
        otpAssistStatus = "Watching Apple Mail for a one-time OpenAI code…"
        otpAssistTask = Task { [weak self] in
            guard let self else { return }
            for _ in 0..<90 {
                if Task.isCancelled { return }
                do {
                    if let code = try await LoginOTPAssistant.latestCodeFromAppleMail(for: email),
                       try await LoginOTPAssistant.fillCodeInArc(code, expectedEmail: email) {
                        self.otpAssistStatus = "One-time code filled in Arc."
                        return
                    }
                } catch {
                    self.otpAssistStatus = "Filling the code needs macOS Automation access to Apple Mail and Arc. You can still finish signing in yourself."
                    return
                }
                try? await Task.sleep(for: .seconds(2))
            }
            if !Task.isCancelled {
                self.otpAssistStatus = "No matching one-time code arrived. Finish signing in in the browser."
            }
        }
    }

    private func stopOTPAssist() {
        otpAssistTask?.cancel()
        otpAssistTask = nil
        otpAssistStatus = nil
    }

    func refreshOne(account id: UUID) async {
        guard accounts.contains(where: { $0.id == id }),
              refreshingAccountIDs.insert(id).inserted
        else { return }
        defer { refreshingAccountIDs.remove(id) }

        let result: Result<AccountSnapshot, Error>
        do {
            result = .success(try await AccountLibrary.fetchSnapshot(for: id))
        } catch {
            result = .failure(error)
        }
        // The account list may have changed while Codex answered.
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        switch result {
        case .success(let snapshot):
            accounts[index] = accounts[index].refreshed(with: snapshot)
        case .failure(let error):
            accounts[index] = accounts[index].refreshFailed(error)
        }
    }

    func persistAccounts() {
        do {
            try AccountLibrary.saveAccounts(accounts)
        } catch {
            bannerMessage = "Could not save account list: \(error.localizedDescription)"
        }
    }

    func refreshDesktopActiveAccountFromDisk() {
        desktopActiveAccountID = desktopAccountSwitcher.activeSavedAccountID(accounts: accounts)
    }
}
#endif
