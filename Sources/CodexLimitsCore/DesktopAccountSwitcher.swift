#if canImport(AppKit)
import AppKit
import Foundation

public enum DesktopAccountSwitchError: LocalizedError, Sendable {
    case chatGPTDesktopMissing
    case invalidSavedIdentity
    case invalidThreadID
    case desktopWouldNotQuit
    case desktopWouldNotLaunch
    case switchedIdentityDidNotStick

    public var errorDescription: String? {
        switch self {
        case .chatGPTDesktopMissing:
            return "ChatGPT/Codex Desktop was not found in /Applications."
        case .invalidSavedIdentity:
            return "The saved login does not match this account card. Sign in to the account again before switching Desktop."
        case .invalidThreadID:
            return "Codex Limits refused to open an invalid Desktop conversation id."
        case .desktopWouldNotQuit:
            return "Codex Desktop did not close cleanly, so its account was left unchanged."
        case .desktopWouldNotLaunch:
            return "Codex Desktop could not be reopened. The previous Desktop login was restored."
        case .switchedIdentityDidNotStick:
            return "Codex Desktop did not keep the selected account. The previous Desktop login was restored."
        }
    }
}

public struct DesktopAccountSwitchResult: Sendable, Equatable {
    public let accountEmail: String
    public let alreadyActive: Bool

    public init(accountEmail: String, alreadyActive: Bool) {
        self.accountEmail = accountEmail
        self.alreadyActive = alreadyActive
    }
}

@MainActor
public final class DesktopAccountSwitcher {
    public nonisolated static let chatGPTBundleIdentifier = "com.openai.codex"
    public nonisolated static let chatGPTApplicationURL = URL(fileURLWithPath: "/Applications/ChatGPT.app", isDirectory: true)

    private let workspace: NSWorkspace
    private let applicationURL: URL
    private let bundleIdentifier: String
    private let mainCodexHome: URL

    public init(
        workspace: NSWorkspace = .shared,
        applicationURL: URL = DesktopAccountSwitcher.chatGPTApplicationURL,
        bundleIdentifier: String = DesktopAccountSwitcher.chatGPTBundleIdentifier,
        mainCodexHome: URL = AppPaths.mainCodexHome
    ) {
        self.workspace = workspace
        self.applicationURL = applicationURL
        self.bundleIdentifier = bundleIdentifier
        self.mainCodexHome = mainCodexHome
    }

    public func activeSavedAccountID(accounts: [SavedAccount]) -> UUID? {
        CodexAuthSwitcher.activeSavedAccountID(accounts: accounts, mainHome: mainCodexHome)
    }

    public func switchAccount(
        to target: SavedAccount,
        accounts: [SavedAccount],
        forceRestart: Bool = false,
        progress: (String) async -> Void
    ) async throws -> DesktopAccountSwitchResult {
        guard FileManager.default.fileExists(atPath: applicationURL.path) else {
            throw DesktopAccountSwitchError.chatGPTDesktopMissing
        }

        let targetIdentity = try AccountCredentialLoader.identity(
            at: CodexAuthSwitcher.authFile(in: AppPaths.homeDirectory(for: target.id))
        )
        guard CodexAuthSwitcher.identity(targetIdentity, matches: target) else {
            throw DesktopAccountSwitchError.invalidSavedIdentity
        }

        if !forceRestart,
           let current = try? currentDesktopIdentity(),
           CodexAuthSwitcher.sameIdentity(current, targetIdentity) {
            if runningDesktopApplications().isEmpty {
                await progress("Starting Codex Desktop as \(target.email)…")
                try await launchDesktop()
                try await waitForDesktopLaunch()
            } else {
                activateDesktopIfRunning()
            }
            return DesktopAccountSwitchResult(accountEmail: target.email, alreadyActive: true)
        }

        await progress("Closing Codex Desktop safely before switching to \(target.email)…")
        try await terminateDesktopCleanly()

        // Desktop is stopped, so the tokens it may have rotated can be saved back to
        // their account before its auth.json is replaced.
        let previousData: Data?
        do {
            previousData = try CodexAuthSwitcher.install(target, accounts: accounts, mainHome: mainCodexHome)
        } catch {
            try await relaunchDesktopBestEffort()
            if error is CodexAuthSwitchError { throw DesktopAccountSwitchError.invalidSavedIdentity }
            throw error
        }

        do {
            await progress("Starting Codex Desktop as \(target.email)…")
            try await launchDesktop()
            try await waitForDesktopLaunch()

            // Give the bundled app-server a moment to load or refresh auth, then check
            // the exact email and workspace Desktop kept in its own Codex home.
            try await Task.sleep(for: .seconds(2))
            guard CodexAuthSwitcher.sameIdentity(try currentDesktopIdentity(), targetIdentity) else {
                throw DesktopAccountSwitchError.switchedIdentityDidNotStick
            }

            activateDesktopIfRunning()
            return DesktopAccountSwitchResult(accountEmail: target.email, alreadyActive: false)
        } catch {
            // Fail closed: restore the exact previous login and reopen Desktop on it.
            _ = try? await terminateDesktopCleanly()
            if let previousData {
                try? AppPaths.writePrivateFile(previousData, to: CodexAuthSwitcher.authFile(in: mainCodexHome))
            }
            try? await relaunchDesktopBestEffort()
            if error is DesktopAccountSwitchError { throw error }
            throw DesktopAccountSwitchError.desktopWouldNotLaunch
        }
    }

    nonisolated static func threadURL(threadID: String) -> URL? {
        guard UUID(uuidString: threadID) != nil else { return nil }
        return URL(string: "codex://threads/\(threadID)")
    }

    public func openThreadForAutoResume(threadID: String) async throws {
        guard FileManager.default.fileExists(atPath: applicationURL.path) else {
            throw DesktopAccountSwitchError.chatGPTDesktopMissing
        }
        guard let threadURL = Self.threadURL(threadID: threadID) else {
            throw DesktopAccountSwitchError.invalidThreadID
        }

        let configuration = NSWorkspace.OpenConfiguration()
        // Give Desktop custody without stealing focus from the current app. Desktop
        // handles its own codex://threads/<conversation-id> links.
        configuration.activates = false
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            workspace.open(
                [threadURL],
                withApplicationAt: applicationURL,
                configuration: configuration
            ) { application, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if application == nil {
                    continuation.resume(throwing: DesktopAccountSwitchError.desktopWouldNotLaunch)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func currentDesktopIdentity() throws -> AccountCredentialLoader.Identity {
        try AccountCredentialLoader.identity(at: CodexAuthSwitcher.authFile(in: mainCodexHome))
    }

    private func terminateDesktopCleanly() async throws {
        let applications = runningDesktopApplications()
        guard !applications.isEmpty else { return }
        for application in applications {
            _ = application.terminate()
        }

        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if runningDesktopApplications().isEmpty { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw DesktopAccountSwitchError.desktopWouldNotQuit
    }

    private func launchDesktop() async throws {
        if !runningDesktopApplications().isEmpty { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            workspace.openApplication(at: applicationURL, configuration: configuration) { application, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if application == nil {
                    continuation.resume(throwing: DesktopAccountSwitchError.desktopWouldNotLaunch)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func waitForDesktopLaunch() async throws {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if !runningDesktopApplications().isEmpty { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw DesktopAccountSwitchError.desktopWouldNotLaunch
    }

    private func relaunchDesktopBestEffort() async throws {
        try await launchDesktop()
        try await waitForDesktopLaunch()
    }

    private func activateDesktopIfRunning() {
        runningDesktopApplications().first?.activate(options: [])
    }

    private func runningDesktopApplications() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { $0.bundleURL?.standardizedFileURL == applicationURL.standardizedFileURL }
    }
}
#endif
