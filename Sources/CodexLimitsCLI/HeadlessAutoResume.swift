import CodexLimitsCore
import Foundation

/// `codex-limits auto-resume`: the menu-bar app's Auto Resume without a menu bar. It signs
/// the main Codex home in to the replenished account itself, so it suits the Codex CLI.
/// Codex Desktop continues conversations on its own login, which only the menu-bar app
/// can switch, so this refuses to act while Desktop is running.
@MainActor
final class HeadlessAutoResume {
    private let coordinator = AutoResumeCoordinator()
    private var accounts: [SavedAccount] = []
    private var state = AutoResumeControlState()
    private var lastReport: String?

    func run() async throws {
        guard let lock = try SingleInstanceLock.acquire(at: AppPaths.instanceLockFile) else {
            throw CommandError(
                "Codex Limits is already running, as the menu-bar app or another auto-resume. Only one can watch at a time."
            )
        }
        defer { withExtendedLifetime(lock) {} }
        guard await !AutoResumeCoordinator.isCodexDesktopRunning() else {
            throw CommandError(
                "Codex Desktop is running. Use the Codex Limits menu-bar app for Auto Resume with Desktop, or quit Desktop first."
            )
        }

        state = try AccountLibrary.loadAutoResumeControlState()
        report("Watching for conversations stopped by a Codex usage limit. Press Ctrl-C to stop.")
        while true {
            accounts = try AccountLibrary.loadAccounts()
            guard !accounts.isEmpty else {
                throw CommandError("No saved accounts yet. Add one with: codex-limits add")
            }
            let delay = await checkOnce()
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    /// One pass of the same steps the menu-bar app takes. Returns the seconds to wait
    /// before the next pass.
    private func checkOnce() async -> TimeInterval {
        var newlyStopped = false
        if state.verifiedExhaustedAccountID == nil {
            guard let stopped = await usageLimitedActiveAccount() else { return 30 }
            state.beginWaiting(stoppedOn: stopped, accounts: accounts)
            saveState()
            newlyStopped = true
            report("\(stopped.email) hit its Codex usage limit. Looking for the conversation it stopped…")
        }

        do {
            state.pendingCandidates = try await coordinator.pendingUsageLimitedCandidates(
                preserving: state.pendingCandidates,
                includeJournalRecovery: !newlyStopped
            )
            saveState()
        } catch {
            report("Couldn't check Codex: \(error.localizedDescription) Retrying in a minute…")
            return 60
        }
        guard !state.pendingCandidates.isEmpty else {
            state.finishWaiting()
            saveState()
            report("No conversation has stopped on the usage limit yet. Watching…")
            return 30
        }

        await refreshAccounts()
        let now = Date()
        state.fiveHourResetWaits = AutoResumeCoordinator.updatedFiveHourResetWaits(
            state.fiveHourResetWaits,
            accounts: accounts,
            now: now
        )
        saveState()
        guard let target = AutoResumeCoordinator.replenishedAccount(
            accounts: accounts,
            fiveHourResetWaits: state.fiveHourResetWaits,
            preferredAccountID: CodexAuthSwitcher.activeSavedAccountID(accounts: accounts),
            now: now
        ) else {
            if let expired = AutoResumeCoordinator.accountNeedingSignIn(
                accounts: accounts,
                fiveHourResetWaits: state.fiveHourResetWaits,
                preferredAccountID: state.verifiedExhaustedAccountID,
                now: now
            ) {
                report("\(expired.email)'s saved login expired. Sign in again: codex-limits remove \(expired.email), then codex-limits add")
            }
            let wait = AutoResumeCoordinator.replenishmentWait(
                accounts: accounts,
                fiveHourResetWaits: state.fiveHourResetWaits,
                now: now
            )
            report(wait.summary(accounts: accounts, now: now))
            return wait.delay
        }
        guard await !AutoResumeCoordinator.isCodexDesktopRunning() else {
            report("Codex Desktop is running. Quit it, or use the menu-bar app, to continue on \(target.email).")
            return 60
        }
        return await resume(on: target)
    }

    private func resume(on account: SavedAccount) async -> TimeInterval {
        let savedAccounts = accounts
        do {
            let resumed = try await coordinator.run(
                accounts: [account],
                resumeAccountID: account.id,
                additionalCandidates: state.pendingCandidates,
                prepareAccount: { account in
                    _ = try CodexAuthSwitcher.install(account, accounts: savedAccounts)
                }
            ) { message in
                await self.report(message)
            }
            if resumed {
                state.finishWaiting()
                saveState()
                report("Continued the stopped conversation on \(account.email). Watching for the next limit.")
            } else {
                report("The stopped conversation is still pending. Retrying…")
            }
            return 2
        } catch AutoResumeError.waitingForFiveHourReplenishment(let email) {
            // Hold the account until the window that stopped it resets. Read its quota
            // again first: the snapshot from before the run shows a replenished window.
            if let index = accounts.firstIndex(where: { $0.id == account.id }) {
                accounts[index] = await AccountLibrary.refreshed(accounts[index])
                try? AccountLibrary.saveAccounts(accounts)
            }
            state.recordUsageLimitStop(on: account.id, accounts: accounts)
            saveState()
            report("\(email) hit its limit again. Waiting for a 5-hour limit to replenish…")
            // Even if Codex's next read contradicts the stop, retry at most once a minute.
            return 60
        } catch AutoResumeError.noRecentQuotaStoppedThreads {
            report("No conversation is waiting on a usage limit. Watching…")
            return 30
        } catch AutoResumeError.threadWriterBusy {
            report("Another Codex process took over the conversation. Checking again…")
            return 3
        } catch {
            report("Auto Resume hit an error: \(error.localizedDescription) Retrying in a minute…")
            return 60
        }
    }

    /// The account Codex is signed in to, only when a fresh quota read confirms a usage
    /// limit stopped it.
    private func usageLimitedActiveAccount() async -> SavedAccount? {
        guard let activeID = CodexAuthSwitcher.activeSavedAccountID(accounts: accounts),
              let index = accounts.firstIndex(where: { $0.id == activeID })
        else {
            report("Codex is signed in to an account that isn't saved here. Add it with: codex-limits add")
            return nil
        }
        accounts[index] = await AccountLibrary.refreshed(accounts[index])
        try? AccountLibrary.saveAccounts(accounts)

        let account = accounts[index]
        guard account.lastError == nil, account.needsReauthentication != true else {
            report("Couldn't read \(account.email)'s quota: \(account.lastError ?? "sign-in expired"). Retrying…")
            return nil
        }
        guard account.isDefinitelyUsageLimitedForAutoResume else {
            report("Watching \(account.email). Auto Resume steps in when it hits a usage limit.")
            return nil
        }
        return account
    }

    private func refreshAccounts() async {
        for index in accounts.indices {
            accounts[index] = await AccountLibrary.refreshed(accounts[index])
        }
        try? AccountLibrary.saveAccounts(accounts)
    }

    private func saveState() {
        do {
            try AccountLibrary.saveAutoResumeControlState(state)
        } catch {
            report("Couldn't save Auto Resume state: \(error.localizedDescription)")
        }
    }

    /// Prints a timestamped line, skipping repeats so a long wait reads as one line.
    private func report(_ message: String) {
        guard message != lastReport else { return }
        lastReport = message
        // Written straight to the file handle so lines appear at once when piped to a log.
        FileHandle.standardOutput.write(Data("[\(Terminal.timestamp())] \(message)\n".utf8))
    }
}
