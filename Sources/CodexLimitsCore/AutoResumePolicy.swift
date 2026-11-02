import Foundation

public struct AutoResumeReplenishmentWait: Equatable, Sendable {
    public enum Blocker: Equatable, Sendable {
        case fiveHour
        case weekly
        case unavailable
    }

    public let blocker: Blocker
    /// The saved account expected to replenish first, when one is known.
    public let accountID: UUID?
    public let reset: Date?
    public let delay: TimeInterval

    public init(blocker: Blocker, accountID: UUID?, reset: Date?, delay: TimeInterval) {
        self.blocker = blocker
        self.accountID = accountID
        self.reset = reset
        self.delay = delay
    }
}

/// Chooses which saved account continues a conversation stopped by a usage limit.
/// Auto Resume waits until some saved account's 5-hour window has replenished and
/// continues there; leftover quota in a partially used window is never enough.
extension AutoResumeCoordinator {
    /// How long a usage-limit stop holds an account when Codex reports no 5-hour
    /// reset time, so a stale snapshot cannot restart the failing turn at once.
    static let unknownFiveHourResetHold: TimeInterval = 15 * 60

    /// How often to recheck a window whose reset just passed but that Codex does
    /// not report as replenished yet.
    static let recentResetRecheckDelay: TimeInterval = 30

    /// An account can continue a stopped conversation only after its 5-hour window
    /// has replenished. A fresh read showing a full window that Codex explicitly
    /// allows counts at once, even if the window reset earlier than Codex predicted.
    /// Otherwise a recorded reset holds the account until that time, so a stale
    /// snapshot cannot start it early; after the reset, light use of the fresh window
    /// before this check still counts.
    public static func fiveHourLimitHasReplenished(
        account: SavedAccount,
        waitingForReset: Date?,
        now: Date = Date()
    ) -> Bool {
        guard account.isEligibleForAutoResume, account.lastError == nil else { return false }
        let windowIsFull = account.usage?.fiveHour?.isFullyReplenished == true
        if windowIsFull, account.usage?.ordinaryUsageAllowed == true {
            return true
        }
        if let waitingForReset {
            return now >= waitingForReset
        }
        return windowIsFull
    }

    /// Records the 5-hour reset to wait on for each saved account. An exhausted
    /// window records its reset. The account a usage limit just stopped records the
    /// current window end even before its percentage reaches zero. A reset that
    /// has passed is kept, because it proves that window replenished.
    public static func updatedFiveHourResetWaits(
        _ existing: [AutoResumeFiveHourResetWait],
        accounts: [SavedAccount],
        usageLimitJustHitAccountID: UUID? = nil,
        now: Date = Date()
    ) -> [AutoResumeFiveHourResetWait] {
        accounts.compactMap { account -> AutoResumeFiveHourResetWait? in
            let recorded = resetWait(for: account.id, in: existing)
            let usageLimitJustHit = account.id == usageLimitJustHitAccountID
            let weeklyHasCapacity = (account.usage?.weekly?.remainingPercent ?? 1) > 0

            if let fiveHour = account.usage?.fiveHour,
               let reset = fiveHour.resetsAt,
               reset > now,
               fiveHour.remainingPercent <= 0 || (usageLimitJustHit && weeklyHasCapacity) {
                return AutoResumeFiveHourResetWait(accountID: account.id, resetsAt: reset)
            }
            if usageLimitJustHit, weeklyHasCapacity, recorded.map({ $0 <= now }) ?? true {
                return AutoResumeFiveHourResetWait(
                    accountID: account.id,
                    resetsAt: now.addingTimeInterval(unknownFiveHourResetHold)
                )
            }
            return recorded.map { AutoResumeFiveHourResetWait(accountID: account.id, resetsAt: $0) }
        }
    }

    /// The saved account to continue on: one whose 5-hour limit has replenished.
    /// The account Codex Desktop already uses goes first, so Desktop does not
    /// restart. Otherwise the account with the most weekly quota left goes first.
    public static func replenishedAccount(
        accounts: [SavedAccount],
        fiveHourResetWaits: [AutoResumeFiveHourResetWait],
        preferredAccountID: UUID? = nil,
        now: Date = Date()
    ) -> SavedAccount? {
        let replenished = accounts.filter { account in
            fiveHourLimitHasReplenished(
                account: account,
                waitingForReset: resetWait(for: account.id, in: fiveHourResetWaits),
                now: now
            )
        }
        if let preferred = replenished.first(where: { $0.id == preferredAccountID }) {
            return preferred
        }
        return replenished.max { lhs, rhs in
            (lhs.usage?.weekly?.remainingPercent ?? 0) < (rhs.usage?.weekly?.remainingPercent ?? 0)
        }
    }

    /// A saved login that expired while its last known quota showed a replenished
    /// 5-hour window. Auto Resume opens sign-in for it rather than skip it.
    public static func accountNeedingSignIn(
        accounts: [SavedAccount],
        fiveHourResetWaits: [AutoResumeFiveHourResetWait],
        preferredAccountID: UUID? = nil,
        now: Date = Date()
    ) -> SavedAccount? {
        let candidates = accounts.filter { account in
            guard account.canReauthenticateForAutoResume,
                  let fiveHour = account.usage?.fiveHour,
                  let weekly = account.usage?.weekly,
                  weekly.remainingPercent > 0 || weekly.resetsAt.map({ $0 <= now }) == true
            else { return false }
            if let waitingForReset = resetWait(for: account.id, in: fiveHourResetWaits) {
                return now >= waitingForReset
            }
            return fiveHour.isFullyReplenished || fiveHour.resetsAt.map { $0 <= now } == true
        }
        return candidates.first { $0.id == preferredAccountID } ?? candidates.first
    }

    /// When the next saved account could have a replenished 5-hour limit. Auto
    /// Resume rechecks then, and at least every `maximumDelay` seconds.
    public static func replenishmentWait(
        accounts: [SavedAccount],
        fiveHourResetWaits: [AutoResumeFiveHourResetWait],
        now: Date = Date(),
        maximumDelay: TimeInterval = 120
    ) -> AutoResumeReplenishmentWait {
        var soonest: AutoResumeReplenishmentWait?
        for account in accounts where account.needsReauthentication != true {
            guard let expected = expectedReplenishment(
                of: account,
                waitingForReset: resetWait(for: account.id, in: fiveHourResetWaits),
                now: now,
                maximumDelay: maximumDelay
            ) else { continue }
            if let current = soonest?.reset, current <= expected.reset { continue }
            soonest = AutoResumeReplenishmentWait(
                blocker: expected.blocker,
                accountID: account.id,
                reset: expected.reset,
                delay: recheckDelay(until: expected.reset, now: now, maximumDelay: maximumDelay)
            )
        }
        return soonest ?? AutoResumeReplenishmentWait(
            blocker: .unavailable,
            accountID: nil,
            reset: nil,
            delay: maximumDelay
        )
    }

    private static func expectedReplenishment(
        of account: SavedAccount,
        waitingForReset: Date?,
        now: Date,
        maximumDelay: TimeInterval
    ) -> (blocker: AutoResumeReplenishmentWait.Blocker, reset: Date)? {
        let expected: (blocker: AutoResumeReplenishmentWait.Blocker, reset: Date?)
        if let weekly = account.usage?.weekly, weekly.remainingPercent <= 0 {
            expected = (.weekly, weekly.resetsAt)
        } else if let waitingForReset {
            expected = (.fiveHour, waitingForReset)
        } else if let fiveHour = account.usage?.fiveHour, !fiveHour.isFullyReplenished {
            expected = (.fiveHour, fiveHour.resetsAt)
        } else {
            return nil
        }
        // Codex can take a moment to report a window that just reset. Older resets
        // say nothing about when the account becomes usable again.
        guard let reset = expected.reset, reset.timeIntervalSince(now) > -maximumDelay else { return nil }
        return (expected.blocker, reset)
    }

    private static func recheckDelay(
        until reset: Date,
        now: Date,
        maximumDelay: TimeInterval
    ) -> TimeInterval {
        if reset <= now { return min(recentResetRecheckDelay, maximumDelay) }
        return max(2, min(maximumDelay, reset.timeIntervalSince(now) + 2))
    }

    private static func resetWait(
        for accountID: UUID,
        in waits: [AutoResumeFiveHourResetWait]
    ) -> Date? {
        waits.first { $0.accountID == accountID }?.resetsAt
    }
}

/// The steps of one wait: a usage limit stops a conversation, Auto Resume waits for a
/// replenished account, and the wait ends once the conversation has continued.
extension AutoResumeControlState {
    /// Starts waiting to continue the conversation `account`'s usage limit stopped.
    public mutating func beginWaiting(stoppedOn account: SavedAccount, accounts: [SavedAccount], now: Date = Date()) {
        pendingCandidates = []
        recordUsageLimitStop(on: account.id, accounts: accounts, now: now)
    }

    /// Records that a usage limit stopped the conversation while it ran on `accountID`.
    public mutating func recordUsageLimitStop(on accountID: UUID, accounts: [SavedAccount], now: Date = Date()) {
        verifiedExhaustedAccountID = accountID
        verifiedExhaustedAt = now
        fiveHourResetWaits = AutoResumeCoordinator.updatedFiveHourResetWaits(
            fiveHourResetWaits,
            accounts: accounts,
            usageLimitJustHitAccountID: accountID,
            now: now
        )
    }

    /// Ends the wait, because the conversation continued or no longer needs to. A reset
    /// that already passed is dropped, so it cannot later make a partly used window
    /// count as replenished.
    public mutating func finishWaiting(now: Date = Date()) {
        verifiedExhaustedAccountID = nil
        verifiedExhaustedAt = nil
        pendingCandidates = []
        fiveHourResetWaits = fiveHourResetWaits.filter { $0.resetsAt > now }
    }
}

extension AutoResumeReplenishmentWait {
    /// A one-line status for this wait, naming the account expected to replenish next.
    public func summary(accounts: [SavedAccount], now: Date = Date()) -> String {
        guard let account = accountID.flatMap({ id in accounts.first(where: { $0.id == id }) }),
              let reset
        else {
            return "Waiting for a saved account's 5-hour limit to replenish…"
        }
        guard reset > now else {
            return "\(account.email)'s limit just reset. Waiting for Codex to confirm…"
        }

        let timing = TimeFormatting.countdown(to: reset, from: now)
        switch blocker {
        case .fiveHour:
            return "Waiting for a 5-hour limit to replenish. Next: \(account.email), \(timing)."
        case .weekly:
            return "Waiting for a limit to replenish. Next: \(account.email)'s weekly limit, \(timing)."
        case .unavailable:
            return "Waiting for a saved account's 5-hour limit to replenish…"
        }
    }
}
