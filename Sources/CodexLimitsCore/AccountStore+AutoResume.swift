#if canImport(AppKit)
import Foundation

extension AccountStore {
    public func startAutoResume() {
        guard canAutoResume else { return }
        autoResumeIsEnabled = true
        autoResumeState = AutoResumeControlState(isArmed: true)
        autoResumeTemporaryFailures = 0
        autoResumeStatus = "Auto Resume is on. Checking the account signed in to Codex Desktop…"
        bannerMessage = nil
        persistAutoResumeControlState()
        launchAutoResumeLoopIfNeeded()
    }

    public func stopAutoResume() {
        guard autoResumeIsEnabled else { return }
        autoResumeIsEnabled = false
        autoResumeState = AutoResumeControlState()
        persistAutoResumeControlState()

        if autoResumeLoginAccountID != nil {
            if activeLogin != nil {
                cancelLogin()
            } else {
                loginTask?.cancel()
                loginTask = nil
            }
            autoResumeLoginAccountID = nil
        }

        if autoResumeCoordinatorIsActive {
            autoResumeStatus = "Auto Resume will stop once the current continuation reaches a safe point…"
        } else {
            autoResumeTask?.cancel()
            autoResumeStatus = "Auto Resume stopped."
        }
    }

    func launchAutoResumeLoopIfNeeded() {
        guard autoResumeIsEnabled, autoResumeTask == nil else { return }
        autoResumeTask = Task { [weak self] in
            await self?.runPersistentAutoResumeLoop()
        }
    }

    private func runPersistentAutoResumeLoop() async {
        guard !autoResumeIsRunning else { return }
        autoResumeIsRunning = true
        defer {
            autoResumeCoordinatorIsActive = false
            autoResumeIsRunning = false
            autoResumeTask = nil
            if !autoResumeIsEnabled {
                autoResumeStatus = "Auto Resume stopped."
            }
        }

        while autoResumeIsEnabled, !Task.isCancelled {
            var newlyVerifiedExhaustion = false
            if autoResumeState.verifiedExhaustedAccountID == nil {
                guard let exhausted = await freshlyVerifiedDesktopExhaustedAccountForAutoResume() else {
                    await sleepAutoResume(seconds: 30)
                    continue
                }
                autoResumeState.beginWaiting(stoppedOn: exhausted, accounts: accounts)
                newlyVerifiedExhaustion = true
                autoResumeStatus = "\(exhausted.email) hit its Codex usage limit. Looking for the conversation it stopped…"
                persistAutoResumeControlState()
            }

            do {
                autoResumeState.pendingCandidates = try await autoResumeCoordinator.pendingUsageLimitedCandidates(
                    preserving: autoResumeState.pendingCandidates,
                    includeJournalRecovery: !newlyVerifiedExhaustion
                )
                persistAutoResumeControlState()
            } catch {
                autoResumeStatus = "Couldn't check Codex: \(error.localizedDescription) Retrying in a minute…"
                await sleepAutoResume(seconds: 60)
                continue
            }

            guard autoResumeIsEnabled, !Task.isCancelled else { break }

            if autoResumeState.pendingCandidates.isEmpty {
                let stoppedAccountID = autoResumeState.verifiedExhaustedAccountID
                autoResumeTemporaryFailures = 0
                autoResumeState.finishWaiting()
                persistAutoResumeControlState()
                if let stoppedAccountID,
                   desktopAccountSwitcher.activeSavedAccountID(accounts: accounts) != stoppedAccountID {
                    autoResumeStatus = "The Codex Desktop account changed. Checking it again…"
                } else {
                    autoResumeStatus = "No conversation has stopped on the usage limit yet. Watching…"
                }
                await sleepAutoResume(seconds: 30)
                continue
            }

            await refreshAllForAutoResume()
            guard autoResumeIsEnabled, !Task.isCancelled else { break }

            // Continue on whichever saved account has a replenished 5-hour limit. An
            // account with leftover quota in a partly used window is not used.
            let now = Date()
            let resetWaits = AutoResumeCoordinator.updatedFiveHourResetWaits(
                autoResumeState.fiveHourResetWaits,
                accounts: accounts,
                now: now
            )
            if resetWaits != autoResumeState.fiveHourResetWaits {
                autoResumeState.fiveHourResetWaits = resetWaits
                persistAutoResumeControlState()
            }

            guard let resumeAccount = AutoResumeCoordinator.replenishedAccount(
                accounts: accounts,
                fiveHourResetWaits: resetWaits,
                preferredAccountID: desktopAccountSwitcher.activeSavedAccountID(accounts: accounts),
                now: now
            ) else {
                if activeLogin == nil,
                   autoResumeLoginAccountID == nil,
                   let signInAccount = AutoResumeCoordinator.accountNeedingSignIn(
                       accounts: accounts,
                       fiveHourResetWaits: resetWaits,
                       preferredAccountID: autoResumeState.verifiedExhaustedAccountID,
                       now: now
                   ) {
                    await reauthenticateForAutoResume(signInAccount)
                    continue
                }

                let wait = AutoResumeCoordinator.replenishmentWait(
                    accounts: accounts,
                    fiveHourResetWaits: resetWaits,
                    now: now
                )
                autoResumeStatus = wait.summary(accounts: accounts, now: now)
                await sleepAutoResume(seconds: wait.delay)
                continue
            }

            guard await resumeConversation(on: resumeAccount) else { break }
            if autoResumeIsEnabled, !Task.isCancelled {
                await sleepAutoResume(seconds: 2)
            }
        }
    }

    /// Runs one continuation on `account`. Returns false when Auto Resume was cancelled.
    private func resumeConversation(on account: SavedAccount) async -> Bool {
        autoResumeCoordinatorIsActive = true
        let result: Result<Bool, Error>
        do {
            result = .success(try await autoResumeCoordinator.run(
                accounts: [account],
                resumeAccountID: account.id,
                additionalCandidates: autoResumeState.pendingCandidates,
                prepareAccount: { account in
                    try await self.prepareDesktopForAutoResume(account)
                },
                prepareDesktopThread: { threadID in
                    try await self.prepareDesktopThreadForAutoResume(threadID)
                },
                shouldContinue: {
                    await self.autoResumeCoordinatorShouldContinue()
                }
            ) { message in
                await self.updateAutoResumeStatusFromCoordinator(message)
            })
        } catch {
            result = .failure(error)
        }
        autoResumeCoordinatorIsActive = false

        do {
            let resumed = try result.get()
            guard autoResumeIsEnabled else { return true }
            if resumed {
                autoResumeTemporaryFailures = 0
                autoResumeState.finishWaiting()
                persistAutoResumeControlState()
                autoResumeStatus = "Resumed the stopped conversation on \(account.email). Watching for the next limit."
            } else {
                autoResumeStatus = "The stopped conversation is still pending. Retrying…"
            }
        } catch AutoResumeError.waitingForFiveHourReplenishment(let email) {
            // Hold the account until the window that stopped it resets. Read its quota
            // again first: the snapshot from before the run shows a replenished window.
            await refreshOne(account: account.id)
            persistAccounts()
            autoResumeState.recordUsageLimitStop(on: account.id, accounts: accounts)
            persistAutoResumeControlState()
            autoResumeStatus = "\(email) hit its limit again. Waiting for a 5-hour limit to replenish…"
            // Even if Codex's next read contradicts the stop, retry at most once a minute.
            await sleepAutoResume(seconds: 60)
        } catch AutoResumeError.temporaryCodexError(let message) {
            // The conversation stays pending, so the next pass continues it again.
            autoResumeTemporaryFailures += 1
            let delay = AutoResumeCoordinator.temporaryFailureRetryDelay(attempt: autoResumeTemporaryFailures)
            let retry = TimeFormatting.countdown(to: Date().addingTimeInterval(delay))
            autoResumeStatus = "Codex couldn't continue: \(message) Trying again \(retry)…"
            await sleepAutoResume(seconds: delay)
        } catch AutoResumeError.noEligibleAccount {
            autoResumeStatus = "No account has a replenished 5-hour limit yet. Waiting…"
        } catch AutoResumeError.noRecentQuotaStoppedThreads {
            autoResumeStatus = "No conversation is waiting on a usage limit. Watching…"
        } catch AutoResumeError.threadWriterBusy {
            autoResumeStatus = "Codex Desktop took over the conversation. Checking again…"
            await sleepAutoResume(seconds: 3)
        } catch is CancellationError {
            return false
        } catch {
            autoResumeStatus = "Auto Resume hit an error: \(error.localizedDescription) Retrying in a minute…"
            await sleepAutoResume(seconds: 60)
        }
        return true
    }

    private func refreshAllForAutoResume() async {
        guard !accounts.isEmpty, activeLogin == nil else { return }
        for account in accounts {
            guard autoResumeIsEnabled, !Task.isCancelled else { break }
            await refreshOne(account: account.id)
        }
        persistAccounts()
    }

    /// The account signed in to Codex Desktop, only when a fresh quota read confirms a
    /// usage limit stopped it.
    private func freshlyVerifiedDesktopExhaustedAccountForAutoResume() async -> SavedAccount? {
        guard autoResumeIsEnabled, !Task.isCancelled else { return nil }
        guard activeLogin == nil else {
            autoResumeStatus = "Waiting for the sign-in to finish…"
            return nil
        }

        guard let activeID = desktopAccountSwitcher.activeSavedAccountID(accounts: accounts) else {
            desktopActiveAccountID = nil
            autoResumeStatus = "Codex Desktop is signed in to an account that isn't saved here. Add it to use Auto Resume."
            return nil
        }
        desktopActiveAccountID = activeID

        await refreshOne(account: activeID)
        persistAccounts()

        guard autoResumeIsEnabled, !Task.isCancelled else { return nil }
        guard desktopAccountSwitcher.activeSavedAccountID(accounts: accounts) == activeID else {
            refreshDesktopActiveAccountFromDisk()
            autoResumeStatus = "The Codex Desktop account changed. Checking it again…"
            return nil
        }
        desktopActiveAccountID = activeID

        guard let activeAccount = accounts.first(where: { $0.id == activeID }) else { return nil }
        guard activeAccount.lastError == nil, activeAccount.needsReauthentication != true else {
            autoResumeStatus = "Couldn't read \(activeAccount.email)'s current quota. Retrying…"
            return nil
        }
        guard activeAccount.isDefinitelyUsageLimitedForAutoResume else {
            autoResumeState.pendingCandidates = []
            autoResumeStatus = "Watching \(activeAccount.email). Auto Resume steps in when it hits a usage limit."
            persistAutoResumeControlState()
            return nil
        }
        return activeAccount
    }

    private func autoResumeCoordinatorShouldContinue() -> Bool {
        autoResumeIsEnabled
    }

    private func updateAutoResumeStatusFromCoordinator(_ message: String) {
        autoResumeStatus = message
    }

    private func prepareDesktopForAutoResume(_ account: SavedAccount) async throws {
        guard autoResumeIsEnabled, !Task.isCancelled else { throw CancellationError() }
        desktopSwitchingAccountID = account.id
        desktopSwitchStatus = "Switching Codex Desktop to \(account.email)…"
        defer { desktopSwitchingAccountID = nil }

        _ = try await desktopAccountSwitcher.switchAccount(to: account, accounts: accounts) { [weak self] message in
            await MainActor.run {
                self?.desktopSwitchStatus = message
            }
        }
        desktopActiveAccountID = account.id
        desktopSwitchStatus = "Codex Desktop is signed in as \(account.email)."
    }

    private func prepareDesktopThreadForAutoResume(_ threadID: String) async throws {
        guard autoResumeIsEnabled, !Task.isCancelled else { throw CancellationError() }
        autoResumeStatus = "Opening the conversation in Codex Desktop…"
        try await desktopAccountSwitcher.openThreadForAutoResume(threadID: threadID)
    }

    private func reauthenticateForAutoResume(_ account: SavedAccount) async {
        autoResumeLoginAccountID = account.id
        autoResumeStatus = "\(account.email) needs to sign in again. Opening the sign-in page…"
        loginTask = Task { [weak self] in
            await self?.runLogin(accountID: account.id, replacingExisting: true)
        }

        while autoResumeIsEnabled,
              !Task.isCancelled,
              (loginTask != nil || activeLogin != nil) {
            await sleepAutoResume(seconds: 1)
        }
        autoResumeLoginAccountID = nil

        if autoResumeIsEnabled,
           accounts.first(where: { $0.id == account.id })?.needsReauthentication == true {
            autoResumeStatus = "\(account.email) still needs to sign in. Trying again in 5 minutes…"
            await sleepAutoResume(seconds: 300)
        }
    }

    private func sleepAutoResume(seconds: TimeInterval) async {
        guard seconds > 0 else { return }
        // Cancellation ends the sleep early; the loop checks for it next.
        try? await Task.sleep(for: .seconds(seconds))
    }

    func persistAutoResumeControlState() {
        autoResumeState.isArmed = autoResumeIsEnabled
        do {
            try AccountLibrary.saveAutoResumeControlState(autoResumeState)
        } catch {
            bannerMessage = "Could not save Auto Resume state: \(error.localizedDescription)"
        }
    }
}
#endif
