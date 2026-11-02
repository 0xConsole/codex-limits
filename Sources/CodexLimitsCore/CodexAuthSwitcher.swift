import Foundation

public enum CodexAuthSwitchError: LocalizedError, Sendable {
    case invalidSavedIdentity

    public var errorDescription: String? {
        switch self {
        case .invalidSavedIdentity:
            return "The saved login does not match this account. Sign in to it again before switching."
        }
    }
}

/// Points the main Codex home at a saved account by replacing its auth.json.
public enum CodexAuthSwitcher {
    public static func activeSavedAccountID(
        accounts: [SavedAccount],
        mainHome: URL = AppPaths.mainCodexHome
    ) -> UUID? {
        guard let identity = try? AccountCredentialLoader.identity(at: authFile(in: mainHome)) else { return nil }
        return matchingSavedAccount(identity: identity, accounts: accounts)?.id
    }

    /// Installs `target`'s saved login in the main Codex home. The login being replaced
    /// is first copied back to its saved account, because Codex may have rotated its
    /// tokens since the last switch. Returns the replaced auth.json so a caller can
    /// restore it. Nothing else may be using the main home while this runs.
    @discardableResult
    public static func install(
        _ target: SavedAccount,
        accounts: [SavedAccount],
        mainHome: URL = AppPaths.mainCodexHome,
        accountsDirectory: URL = AppPaths.accountsDirectory
    ) throws -> Data? {
        let mainAuth = authFile(in: mainHome)
        let previous = try? Data(contentsOf: mainAuth)
        if let previous,
           let identity = try? AccountCredentialLoader.identity(data: previous),
           let owner = matchingSavedAccount(identity: identity, accounts: accounts) {
            try AppPaths.writePrivateFile(
                previous,
                to: authFile(in: AppPaths.homeDirectory(for: owner.id, in: accountsDirectory))
            )
        }

        // Read the target after the copy-back, in case it was the account just saved.
        let targetData = try verifiedLogin(of: target, accountsDirectory: accountsDirectory)
        try AppPaths.createPrivateDirectory(at: mainHome)
        try AppPaths.writePrivateFile(targetData, to: mainAuth)
        return previous
    }

    /// The saved auth.json of `account`, after checking it still belongs to it.
    static func verifiedLogin(of account: SavedAccount, accountsDirectory: URL = AppPaths.accountsDirectory) throws -> Data {
        let data = try Data(contentsOf: authFile(in: AppPaths.homeDirectory(for: account.id, in: accountsDirectory)))
        guard identity(try AccountCredentialLoader.identity(data: data), matches: account) else {
            throw CodexAuthSwitchError.invalidSavedIdentity
        }
        return data
    }

    static func authFile(in home: URL) -> URL {
        home.appendingPathComponent("auth.json", isDirectory: false)
    }

    static func identity(_ identity: AccountCredentialLoader.Identity, matches account: SavedAccount) -> Bool {
        guard identity.email.caseInsensitiveCompare(account.email) == .orderedSame else { return false }
        if let expected = account.accountID, !expected.isEmpty {
            return identity.accountID == expected
        }
        return true
    }

    static func matchingSavedAccount(
        identity: AccountCredentialLoader.Identity,
        accounts: [SavedAccount]
    ) -> SavedAccount? {
        accounts.first { self.identity(identity, matches: $0) }
    }

    static func sameIdentity(_ lhs: AccountCredentialLoader.Identity, _ rhs: AccountCredentialLoader.Identity) -> Bool {
        lhs.accountID == rhs.accountID && lhs.email.caseInsensitiveCompare(rhs.email) == .orderedSame
    }
}
