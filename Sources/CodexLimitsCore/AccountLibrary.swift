import Foundation

/// Saved accounts and Auto Resume state on disk, shared by the menu-bar app and the
/// command-line tool.
public enum AccountLibrary {
    public static let maximumAccounts = 10

    public static func loadAccounts() throws -> [SavedAccount] {
        guard FileManager.default.fileExists(atPath: AppPaths.metadataFile.path) else { return [] }
        return try decoder.decode([SavedAccount].self, from: Data(contentsOf: AppPaths.metadataFile))
    }

    public static func saveAccounts(_ accounts: [SavedAccount]) throws {
        try AppPaths.ensureDirectories()
        try AppPaths.writePrivateFile(encoder.encode(accounts), to: AppPaths.metadataFile)
    }

    public static func loadAutoResumeControlState() throws -> AutoResumeControlState {
        guard FileManager.default.fileExists(atPath: AppPaths.autoResumeControlFile.path) else {
            return AutoResumeControlState()
        }
        return try decoder.decode(
            AutoResumeControlState.self,
            from: Data(contentsOf: AppPaths.autoResumeControlFile)
        )
    }

    public static func saveAutoResumeControlState(_ state: AutoResumeControlState) throws {
        try AppPaths.ensureDirectories()
        try AppPaths.writePrivateFile(encoder.encode(state), to: AppPaths.autoResumeControlFile)
    }

    /// Reads an account's quota through its own isolated Codex home. Polling never
    /// rotates the OAuth refresh token itself; Codex refreshes it when a request
    /// actually needs a new access token.
    public static func fetchSnapshot(for id: UUID) async throws -> AccountSnapshot {
        let home = AppPaths.homeDirectory(for: id)
        guard FileManager.default.fileExists(atPath: home.appendingPathComponent("auth.json").path) else {
            throw CodexClientError.loginFailed("Saved login is missing. Remove the account and sign in again.")
        }
        let client = try CodexAppServerClient(homeURL: home)
        do {
            try await client.start()
            let snapshot = try await client.fetchAccountSnapshot()
            await client.stop()
            return snapshot
        } catch {
            await client.stop()
            throw error
        }
    }

    public static func refreshed(_ account: SavedAccount) async -> SavedAccount {
        do {
            return account.refreshed(with: try await fetchSnapshot(for: account.id))
        } catch {
            return account.refreshFailed(error)
        }
    }

    public static func isDuplicate(
        _ snapshot: AccountSnapshot,
        in accounts: [SavedAccount],
        excluding excludedID: UUID? = nil
    ) -> Bool {
        accounts.contains { existing in
            existing.id != excludedID
                && existing.email.caseInsensitiveCompare(snapshot.email) == .orderedSame
        }
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
