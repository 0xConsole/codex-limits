import Foundation
import Testing
@testable import CodexLimitsCore

/// An auth.json shaped like the one Codex writes, with an unsigned ID token carrying `email`.
private func codexAuthFile(email: String, accountID: String, accessToken: String = "access") throws -> Data {
    func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    let header = base64URL(Data(#"{"alg":"none"}"#.utf8))
    let payload = base64URL(try JSONSerialization.data(withJSONObject: ["email": email]))
    return try JSONSerialization.data(withJSONObject: [
        "tokens": [
            "id_token": "\(header).\(payload).signature",
            "access_token": accessToken,
            "account_id": accountID,
        ],
    ])
}

private func savedAccount(email: String, accountID: String?) -> SavedAccount {
    SavedAccount(
        id: UUID(),
        email: email,
        planType: "business",
        accountID: accountID,
        usage: nil,
        lastRefreshedAt: nil,
        lastError: nil,
        createdAt: Date()
    )
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
}

@Test("Account switching distinguishes saved emails that share a workspace")
func desktopAccountIdentityMatching() throws {
    let identity = try AccountCredentialLoader.identity(
        data: codexAuthFile(email: "first@example.com", accountID: "shared-workspace")
    )
    let first = savedAccount(email: "first@example.com", accountID: "shared-workspace")
    let second = savedAccount(email: "second@example.com", accountID: "shared-workspace")

    #expect(identity.email == "first@example.com")
    #expect(identity.accountID == "shared-workspace")
    #expect(CodexAuthSwitcher.matchingSavedAccount(identity: identity, accounts: [second, first])?.id == first.id)
    #expect(CodexAuthSwitcher.identity(identity, matches: first))
    #expect(!CodexAuthSwitcher.identity(identity, matches: second))

    #if canImport(AppKit)
    let threadID = "01a0b2f1-5c25-71f1-8884-f90b795c300a"
    #expect(DesktopAccountSwitcher.threadURL(threadID: threadID)?.absoluteString == "codex://threads/\(threadID)")
    #expect(DesktopAccountSwitcher.threadURL(threadID: "not-a-thread-id") == nil)
    #endif
}

@Test("Switching the main Codex login saves the outgoing account's rotated tokens first")
func codexAuthSwitchKeepsRotatedTokens() throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let accountsDirectory = root.appendingPathComponent("Accounts", isDirectory: true)
    let mainHome = root.appendingPathComponent("main", isDirectory: true)
    let first = savedAccount(email: "first@example.com", accountID: "workspace")
    let second = savedAccount(email: "second@example.com", accountID: "workspace")
    let accounts = [first, second]

    func savedLogin(of account: SavedAccount) -> URL {
        CodexAuthSwitcher.authFile(in: AppPaths.homeDirectory(for: account.id, in: accountsDirectory))
    }
    for account in accounts {
        try AppPaths.createPrivateDirectory(at: savedLogin(of: account).deletingLastPathComponent())
        try codexAuthFile(email: account.email, accountID: "workspace").write(to: savedLogin(of: account))
    }
    // Codex rotated the first account's tokens while it was the active login.
    let rotated = try codexAuthFile(email: first.email, accountID: "workspace", accessToken: "rotated")
    try AppPaths.createPrivateDirectory(at: mainHome)
    try rotated.write(to: CodexAuthSwitcher.authFile(in: mainHome))

    let replaced = try CodexAuthSwitcher.install(second, accounts: accounts, mainHome: mainHome, accountsDirectory: accountsDirectory)

    #expect(replaced == rotated)
    #expect(try Data(contentsOf: savedLogin(of: first)) == rotated)
    #expect(try Data(contentsOf: CodexAuthSwitcher.authFile(in: mainHome)) == Data(contentsOf: savedLogin(of: second)))
    #expect(CodexAuthSwitcher.activeSavedAccountID(accounts: accounts, mainHome: mainHome) == second.id)

    // A saved login that belongs to a different account is refused.
    let mismatched = savedAccount(email: "third@example.com", accountID: "workspace")
    try AppPaths.createPrivateDirectory(at: savedLogin(of: mismatched).deletingLastPathComponent())
    try codexAuthFile(email: first.email, accountID: "workspace").write(to: savedLogin(of: mismatched))
    #expect(throws: CodexAuthSwitchError.self) {
        try CodexAuthSwitcher.install(mismatched, accounts: accounts + [mismatched], mainHome: mainHome, accountsDirectory: accountsDirectory)
    }
    #expect(CodexAuthSwitcher.activeSavedAccountID(accounts: accounts, mainHome: mainHome) == second.id)
}

@Test("Only one process holds the instance lock, and releasing it frees it")
func singleInstanceLock() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let lockFile = directory.appendingPathComponent("instance.lock")

    // Only Bools go into #expect: it keeps captured values alive, which would hold the lock.
    var holder = try SingleInstanceLock.acquire(at: lockFile)
    let acquired = holder != nil
    let acquiredWhileHeld = try SingleInstanceLock.acquire(at: lockFile) != nil
    #expect(acquired)
    #expect(!acquiredWhileHeld)
    #if !os(Windows)
    #expect(SingleInstanceLock.holderProcessID(at: lockFile) == ProcessInfo.processInfo.processIdentifier)
    #endif

    holder = nil
    let acquiredAfterRelease = try SingleInstanceLock.acquire(at: lockFile) != nil
    #expect(acquiredAfterRelease)
    withExtendedLifetime(holder) {}
}

@Test("Codex is looked up in every PATH directory")
func codexLocatorSearchesPath() {
    #if os(Windows)
    #expect(CodexLocator.pathCandidates(#"C:\tools"#).count == 2)
    #else
    #expect(CodexLocator.pathCandidates("/usr/local/bin:/opt/codex/bin") == ["/usr/local/bin/codex", "/opt/codex/bin/codex"])
    #expect(CodexLocator.pathCandidates("").isEmpty)
    #endif
}

@Test("Countdowns read as the largest two units")
func countdownFormatting() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(TimeFormatting.countdown(to: now.addingTimeInterval(-5), from: now) == "now")
    #expect(TimeFormatting.countdown(to: now.addingTimeInterval(40), from: now) == "in 40s")
    #expect(TimeFormatting.countdown(to: now.addingTimeInterval(23 * 60), from: now) == "in 23m")
    #expect(TimeFormatting.countdown(to: now.addingTimeInterval(2 * 3_600 + 5 * 60), from: now) == "in 2h 5m")
    #expect(TimeFormatting.countdown(to: now.addingTimeInterval(3 * 86_400 + 4 * 3_600), from: now) == "in 3d 4h")
}

#if canImport(AppKit)
@Test("OTP extraction accepts one unique six-digit code and rejects ambiguity")
func otpExtraction() {
    #expect(LoginOTPAssistant.extractUniqueSixDigitCode(from: "Your OpenAI code is 482193.") == "482193")
    #expect(LoginOTPAssistant.extractUniqueSixDigitCode(from: "Code 482193. Repeated: 482193") == "482193")
    #expect(LoginOTPAssistant.extractUniqueSixDigitCode(from: "Codes 482193 and 771204") == nil)
    #expect(LoginOTPAssistant.extractUniqueSixDigitCode(from: "Reference 1234567") == nil)
}
#endif
