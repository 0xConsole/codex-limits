import CodexLimitsCore
import Foundation

struct CommandError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}

enum Commands {
    static func status(json: Bool) async throws {
        let saved = try AccountLibrary.loadAccounts()
        guard !saved.isEmpty else {
            print("No saved accounts yet. Add one with: codex-limits add")
            return
        }

        var refreshed: [UUID: SavedAccount] = [:]
        for account in saved {
            refreshed[account.id] = await AccountLibrary.refreshed(account)
        }
        // Apply the results to the latest list, so nothing added meanwhile is lost.
        let accounts = try AccountLibrary.loadAccounts().map { refreshed[$0.id] ?? $0 }
        try AccountLibrary.saveAccounts(accounts)

        let activeID = CodexAuthSwitcher.activeSavedAccountID(accounts: accounts)
        print(json ? try jsonStatus(accounts, activeID: activeID) : textStatus(accounts, activeID: activeID))
    }

    static func add() async throws {
        let lock = try requireInstanceLock()
        defer { withExtendedLifetime(lock) {} }
        guard try AccountLibrary.loadAccounts().count < AccountLibrary.maximumAccounts else {
            throw CommandError("Codex Limits supports up to \(AccountLibrary.maximumAccounts) accounts.")
        }

        let accountID = UUID()
        let home = AppPaths.homeDirectory(for: accountID)
        try AppPaths.createPrivateDirectory(at: home)
        let client = try CodexAppServerClient(homeURL: home)
        do {
            try await client.start()
            let ticket = try await client.startChatGPTLogin()
            print("Sign in to the ChatGPT account you want to add. If no browser opens, visit:\n\(ticket.authorizationURL.absoluteString)\n")
            Terminal.openInBrowser(ticket.authorizationURL)
            let completion = try await client.waitForLoginCompletion(loginID: ticket.loginID)
            guard completion.success else {
                throw CodexClientError.loginFailed(completion.error ?? "Codex sign-in did not complete.")
            }
            let snapshot = try await client.fetchAccountSnapshot(refreshToken: false)
            await client.stop()

            let accounts = try AccountLibrary.loadAccounts()
            guard !AccountLibrary.isDuplicate(snapshot, in: accounts) else {
                throw CommandError("\(snapshot.email) is already saved.")
            }
            let authFile = home.appendingPathComponent("auth.json")
            if FileManager.default.fileExists(atPath: authFile.path) {
                try AppPaths.restrictToOwner(authFile)
            }
            let account = SavedAccount(
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
            try AccountLibrary.saveAccounts(
                (accounts + [account]).sorted { $0.email.localizedCaseInsensitiveCompare($1.email) == .orderedAscending }
            )
            print("Added \(snapshot.email).")
        } catch {
            await client.stop()
            try? FileManager.default.removeItem(at: home)
            throw error
        }
    }

    static func remove(email: String) throws {
        let lock = try requireInstanceLock()
        defer { withExtendedLifetime(lock) {} }
        let accounts = try AccountLibrary.loadAccounts()
        let account = try savedAccount(matching: email, in: accounts)
        try AccountLibrary.saveAccounts(accounts.filter { $0.id != account.id })
        try? FileManager.default.removeItem(at: AppPaths.homeDirectory(for: account.id))
        print("Removed \(account.email).")
    }

    static func use(email: String) throws {
        let lock = try requireInstanceLock()
        defer { withExtendedLifetime(lock) {} }
        let accounts = try AccountLibrary.loadAccounts()
        let account = try savedAccount(matching: email, in: accounts)
        try CodexAuthSwitcher.install(account, accounts: accounts)
        print("Codex is now signed in as \(account.email). Restart running Codex sessions so they use it.")
    }

    /// Commands that change saved logins wait until the menu-bar app and `auto-resume`
    /// have stopped: both keep their own copy of the accounts and would undo the change.
    private static func requireInstanceLock() throws -> SingleInstanceLock {
        guard let lock = try SingleInstanceLock.acquire(at: AppPaths.instanceLockFile) else {
            throw CommandError(
                "Codex Limits is running, as the menu-bar app or `codex-limits auto-resume`. Quit it first, or make this change in the app."
            )
        }
        return lock
    }

    private static func savedAccount(matching email: String, in accounts: [SavedAccount]) throws -> SavedAccount {
        guard let account = accounts.first(where: { $0.email.caseInsensitiveCompare(email) == .orderedSame }) else {
            throw CommandError("No saved account is signed in as \(email). Run `codex-limits status` to list them.")
        }
        return account
    }

    private static func textStatus(_ accounts: [SavedAccount], activeID: UUID?) -> String {
        let now = Date()
        func describe(_ window: LimitWindow?) -> String {
            guard let window else { return "unavailable" }
            let left = "\(Int(window.remainingPercent.rounded()))%"
            guard let reset = window.resetsAt, reset > now else { return left }
            return "\(left), resets \(TimeFormatting.countdown(to: reset, from: now))"
        }
        func note(_ account: SavedAccount) -> String {
            if account.needsReauthentication == true { return "sign-in expired" }
            if let error = account.lastError { return "couldn't refresh: \(error)" }
            if account.usage?.ordinaryUsageAllowed == false { return "usage blocked" }
            return ""
        }

        let rows = [["", "ACCOUNT", "5-HOUR LEFT", "WEEKLY LEFT", ""]] + accounts.map { account in
            [
                account.id == activeID ? "*" : "",
                account.email,
                describe(account.usage?.fiveHour),
                describe(account.usage?.weekly),
                note(account),
            ]
        }
        let table = Terminal.table(rows)
        return activeID == nil ? table : table + "\n\n* Codex is signed in to this account."
    }

    private struct AccountStatus: Encodable {
        let email: String
        let plan: String
        let signedInToCodex: Bool
        let fiveHour: LimitWindow?
        let weekly: LimitWindow?
        let usageAllowed: Bool?
        let needsSignIn: Bool
        let error: String?
    }

    private static func jsonStatus(_ accounts: [SavedAccount], activeID: UUID?) throws -> String {
        let statuses = accounts.map { account in
            AccountStatus(
                email: account.email,
                plan: account.planType,
                signedInToCodex: account.id == activeID,
                fiveHour: account.usage?.fiveHour,
                weekly: account.usage?.weekly,
                usageAllowed: account.usage?.ordinaryUsageAllowed,
                needsSignIn: account.needsReauthentication == true,
                error: account.lastError
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(statuses), as: UTF8.self)
    }
}
