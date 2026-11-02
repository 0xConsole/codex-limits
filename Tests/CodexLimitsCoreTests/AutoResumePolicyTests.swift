import Foundation
import Testing
@testable import CodexLimitsCore

private func quotaAccount(
    id: UUID = UUID(),
    email: String,
    fiveHourUsed: Double,
    fiveHourReset: Date? = nil,
    weeklyUsed: Double = 20,
    weeklyReset: Date? = nil,
    ordinaryAllowed: Bool? = true,
    lastError: String? = nil,
    needsReauthentication: Bool = false
) -> SavedAccount {
    SavedAccount(
        id: id,
        email: email,
        planType: "team",
        accountID: nil,
        usage: UsageSnapshot(
            fiveHour: LimitWindow(usedPercent: fiveHourUsed, windowDurationMinutes: 300, resetsAt: fiveHourReset),
            weekly: LimitWindow(usedPercent: weeklyUsed, windowDurationMinutes: 10_080, resetsAt: weeklyReset),
            ordinaryUsageAllowed: ordinaryAllowed,
            rateLimitReachedType: ordinaryAllowed == false ? "rate_limit_reached" : nil
        ),
        lastRefreshedAt: Date(timeIntervalSince1970: 1_800_000_000),
        lastError: lastError,
        needsReauthentication: needsReauthentication,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

@Test("Auto Resume waits for a replenished 5-hour window instead of using leftover quota")
func autoResumeRequiresReplenishedFiveHourWindow() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let exhausted = quotaAccount(
        email: "full@example.com",
        fiveHourUsed: 100,
        fiveHourReset: now.addingTimeInterval(3_600),
        ordinaryAllowed: false
    )
    let leftover = quotaAccount(
        email: "leftover@example.com",
        fiveHourUsed: 42,
        fiveHourReset: now.addingTimeInterval(1_800)
    )
    #expect(AutoResumeCoordinator.replenishedAccount(
        accounts: [exhausted, leftover],
        fiveHourResetWaits: [],
        now: now
    ) == nil)

    let fresh = quotaAccount(email: "fresh@example.com", fiveHourUsed: 0)
    #expect(AutoResumeCoordinator.replenishedAccount(
        accounts: [exhausted, leftover, fresh],
        fiveHourResetWaits: [],
        now: now
    )?.id == fresh.id)

    let leftoverAfterReset = quotaAccount(id: leftover.id, email: leftover.email, fiveHourUsed: 0)
    #expect(AutoResumeCoordinator.replenishedAccount(
        accounts: [exhausted, leftoverAfterReset],
        fiveHourResetWaits: [],
        now: now.addingTimeInterval(1_802)
    )?.id == leftover.id)
}

@Test("A usage-limit stop holds that account until its 5-hour window resets")
func autoResumeFiveHourResetHold() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let reset = now.addingTimeInterval(600)
    // A snapshot shows a full window, but Codex has not confirmed usage is allowed.
    let stale = quotaAccount(email: "stale@example.com", fiveHourUsed: 0, ordinaryAllowed: nil)
    let holds = [AutoResumeFiveHourResetWait(accountID: stale.id, resetsAt: reset)]
    #expect(!AutoResumeCoordinator.fiveHourLimitHasReplenished(account: stale, waitingForReset: reset, now: now))
    #expect(AutoResumeCoordinator.replenishedAccount(accounts: [stale], fiveHourResetWaits: holds, now: now) == nil)

    // Codex's explicit go-ahead with a full window wins over a reset predicted earlier:
    // windows sometimes reset before the time Codex reported.
    let resetEarly = quotaAccount(id: stale.id, email: stale.email, fiveHourUsed: 0)
    #expect(AutoResumeCoordinator.replenishedAccount(accounts: [resetEarly], fiveHourResetWaits: holds, now: now)?.id == stale.id)

    // A partly used window is still held until the recorded reset.
    let partlyUsed = quotaAccount(id: stale.id, email: stale.email, fiveHourUsed: 30)
    #expect(AutoResumeCoordinator.replenishedAccount(accounts: [partlyUsed], fiveHourResetWaits: holds, now: now) == nil)

    // After the recorded reset, light use of the fresh window still counts as replenished.
    let lightlyUsed = quotaAccount(
        id: stale.id,
        email: stale.email,
        fiveHourUsed: 3,
        fiveHourReset: reset.addingTimeInterval(18_000)
    )
    #expect(AutoResumeCoordinator.replenishedAccount(
        accounts: [lightlyUsed],
        fiveHourResetWaits: holds,
        now: reset
    )?.id == stale.id)

    // Fresh quota data that Codex permits is still required.
    let offline = quotaAccount(email: "offline@example.com", fiveHourUsed: 0, lastError: "offline")
    let denied = quotaAccount(email: "denied@example.com", fiveHourUsed: 0, ordinaryAllowed: false)
    let weeklyOut = quotaAccount(email: "weekly@example.com", fiveHourUsed: 0, weeklyUsed: 100)
    let expired = quotaAccount(email: "expired@example.com", fiveHourUsed: 0, needsReauthentication: true)
    for account in [offline, denied, weeklyOut, expired] {
        #expect(!AutoResumeCoordinator.fiveHourLimitHasReplenished(account: account, waitingForReset: nil, now: now))
    }
}

@Test("Auto Resume prefers the Codex Desktop account, then the most weekly quota left")
func autoResumeReplenishedAccountPreference() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let first = quotaAccount(email: "first@example.com", fiveHourUsed: 0, weeklyUsed: 60)
    let roomy = quotaAccount(email: "roomy@example.com", fiveHourUsed: 0, weeklyUsed: 10)
    let tied = quotaAccount(email: "tied@example.com", fiveHourUsed: 0, weeklyUsed: 10)
    let accounts = [first, roomy, tied]

    #expect(AutoResumeCoordinator.replenishedAccount(
        accounts: accounts,
        fiveHourResetWaits: [],
        now: now
    )?.id == roomy.id)
    #expect(AutoResumeCoordinator.replenishedAccount(
        accounts: accounts,
        fiveHourResetWaits: [],
        preferredAccountID: first.id,
        now: now
    )?.id == first.id)

    let busyDesktop = quotaAccount(email: "desktop@example.com", fiveHourUsed: 50)
    #expect(AutoResumeCoordinator.replenishedAccount(
        accounts: [busyDesktop, first],
        fiveHourResetWaits: [],
        preferredAccountID: busyDesktop.id,
        now: now
    )?.id == first.id)
}

@Test("Auto Resume records the 5-hour reset of each account a usage limit stopped")
func autoResumeFiveHourResetWaitTracking() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let windowEnd = now.addingTimeInterval(3_600)
    // Codex stopped the continuation before the saved percentage reached 100.
    let justStopped = quotaAccount(email: "stopped@example.com", fiveHourUsed: 80, fiveHourReset: windowEnd)
    let exhausted = quotaAccount(
        email: "full@example.com",
        fiveHourUsed: 100,
        fiveHourReset: now.addingTimeInterval(600),
        ordinaryAllowed: false
    )
    let leftover = quotaAccount(email: "leftover@example.com", fiveHourUsed: 42, fiveHourReset: now.addingTimeInterval(900))
    let removed = AutoResumeFiveHourResetWait(accountID: UUID(), resetsAt: now.addingTimeInterval(60))

    let waits = AutoResumeCoordinator.updatedFiveHourResetWaits(
        [removed],
        accounts: [justStopped, exhausted, leftover],
        usageLimitJustHitAccountID: justStopped.id,
        now: now
    )
    #expect(waits == [
        AutoResumeFiveHourResetWait(accountID: justStopped.id, resetsAt: windowEnd),
        AutoResumeFiveHourResetWait(accountID: exhausted.id, resetsAt: now.addingTimeInterval(600)),
    ])

    // A passed reset stays recorded as proof that the window replenished.
    let later = now.addingTimeInterval(4_000)
    let replenished = quotaAccount(
        id: justStopped.id,
        email: justStopped.email,
        fiveHourUsed: 2,
        fiveHourReset: later.addingTimeInterval(17_000)
    )
    #expect(AutoResumeCoordinator.updatedFiveHourResetWaits(waits, accounts: [replenished], now: later) == [
        AutoResumeFiveHourResetWait(accountID: justStopped.id, resetsAt: windowEnd),
    ])

    // With no reset reported, a stop still holds the account instead of retrying at once.
    let noReset = quotaAccount(email: "no-reset@example.com", fiveHourUsed: 0)
    #expect(AutoResumeCoordinator.updatedFiveHourResetWaits(
        [],
        accounts: [noReset],
        usageLimitJustHitAccountID: noReset.id,
        now: now
    ) == [AutoResumeFiveHourResetWait(accountID: noReset.id, resetsAt: now.addingTimeInterval(15 * 60))])

    // A weekly block does not become a 5-hour hold.
    let weeklyBlocked = quotaAccount(
        email: "weekly@example.com",
        fiveHourUsed: 30,
        fiveHourReset: windowEnd,
        weeklyUsed: 100,
        ordinaryAllowed: false
    )
    #expect(AutoResumeCoordinator.updatedFiveHourResetWaits(
        [],
        accounts: [weeklyBlocked],
        usageLimitJustHitAccountID: weeklyBlocked.id,
        now: now
    ).isEmpty)
}

@Test("Auto Resume opens sign-in only for an expired login whose last quota was replenished")
func autoResumeSignInCandidate() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let expiredFull = quotaAccount(email: "expired-full@example.com", fiveHourUsed: 0, needsReauthentication: true)
    let expiredBusy = quotaAccount(
        email: "expired-busy@example.com",
        fiveHourUsed: 60,
        fiveHourReset: now.addingTimeInterval(600),
        needsReauthentication: true
    )
    let expiredReset = quotaAccount(
        email: "expired-reset@example.com",
        fiveHourUsed: 100,
        fiveHourReset: now.addingTimeInterval(-60),
        needsReauthentication: true
    )
    let healthy = quotaAccount(email: "healthy@example.com", fiveHourUsed: 50)

    #expect(AutoResumeCoordinator.accountNeedingSignIn(
        accounts: [healthy, expiredBusy],
        fiveHourResetWaits: [],
        now: now
    ) == nil)
    #expect(AutoResumeCoordinator.accountNeedingSignIn(
        accounts: [expiredBusy, expiredFull],
        fiveHourResetWaits: [],
        now: now
    )?.id == expiredFull.id)
    #expect(AutoResumeCoordinator.accountNeedingSignIn(
        accounts: [expiredFull, expiredReset],
        fiveHourResetWaits: [],
        preferredAccountID: expiredReset.id,
        now: now
    )?.id == expiredReset.id)
    #expect(AutoResumeCoordinator.accountNeedingSignIn(
        accounts: [expiredFull],
        fiveHourResetWaits: [AutoResumeFiveHourResetWait(accountID: expiredFull.id, resetsAt: now.addingTimeInterval(60))],
        now: now
    ) == nil)
}

@Test("Auto Resume wakes for the soonest 5-hour replenishment across saved accounts")
func autoResumeReplenishmentScheduling() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let exhausted = quotaAccount(
        email: "full@example.com",
        fiveHourUsed: 100,
        fiveHourReset: now.addingTimeInterval(7_200),
        ordinaryAllowed: false
    )
    let leftover = quotaAccount(email: "leftover@example.com", fiveHourUsed: 42, fiveHourReset: now.addingTimeInterval(18))
    let holds = [AutoResumeFiveHourResetWait(accountID: exhausted.id, resetsAt: now.addingTimeInterval(7_200))]

    let soon = AutoResumeCoordinator.replenishmentWait(accounts: [exhausted, leftover], fiveHourResetWaits: holds, now: now)
    #expect(soon.blocker == .fiveHour)
    #expect(soon.accountID == leftover.id)
    #expect(soon.reset == now.addingTimeInterval(18))
    #expect(soon.delay == 20)

    let far = AutoResumeCoordinator.replenishmentWait(accounts: [exhausted], fiveHourResetWaits: holds, now: now)
    #expect(far.accountID == exhausted.id)
    #expect(far.delay == 120)

    let weeklyBlocked = quotaAccount(
        email: "weekly@example.com",
        fiveHourUsed: 10,
        fiveHourReset: now.addingTimeInterval(60),
        weeklyUsed: 100,
        weeklyReset: now.addingTimeInterval(90),
        ordinaryAllowed: false
    )
    let weekly = AutoResumeCoordinator.replenishmentWait(accounts: [weeklyBlocked], fiveHourResetWaits: [], now: now)
    #expect(weekly.blocker == .weekly)
    #expect(weekly.accountID == weeklyBlocked.id)
    #expect(weekly.delay == 92)

    // Codex may lag briefly after a reset, so recheck soon rather than at the cap.
    let justReset = quotaAccount(
        email: "just-reset@example.com",
        fiveHourUsed: 100,
        fiveHourReset: now.addingTimeInterval(-5),
        ordinaryAllowed: false
    )
    let lagging = AutoResumeCoordinator.replenishmentWait(
        accounts: [justReset],
        fiveHourResetWaits: [AutoResumeFiveHourResetWait(accountID: justReset.id, resetsAt: now.addingTimeInterval(-5))],
        now: now
    )
    #expect(lagging.accountID == justReset.id)
    #expect(lagging.delay == 30)

    let unknown = quotaAccount(email: "unknown@example.com", fiveHourUsed: 100, ordinaryAllowed: false)
    let longAgo = quotaAccount(
        email: "long-ago@example.com",
        fiveHourUsed: 100,
        fiveHourReset: now.addingTimeInterval(-3_600),
        ordinaryAllowed: false
    )
    let fallback = AutoResumeCoordinator.replenishmentWait(accounts: [unknown, longAgo], fiveHourResetWaits: [], now: now)
    #expect(fallback.blocker == .unavailable)
    #expect(fallback.accountID == nil)
    #expect(fallback.delay == 120)
}

@Test("Auto Resume state follows one wait from the stop until the conversation continues")
func autoResumeWaitLifecycle() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let stopped = quotaAccount(
        email: "stopped@example.com",
        fiveHourUsed: 100,
        fiveHourReset: now.addingTimeInterval(600),
        ordinaryAllowed: false
    )
    let other = quotaAccount(
        email: "other@example.com",
        fiveHourUsed: 100,
        fiveHourReset: now.addingTimeInterval(9_000),
        ordinaryAllowed: false
    )
    var state = AutoResumeControlState(
        isArmed: true,
        pendingCandidates: [AutoResumeCandidate(sourceThreadID: "thread", failedTurnID: "turn", updatedAt: nil)]
    )

    state.beginWaiting(stoppedOn: stopped, accounts: [stopped, other], now: now)
    #expect(state.verifiedExhaustedAccountID == stopped.id)
    #expect(state.pendingCandidates.isEmpty)
    #expect(state.fiveHourResetWaits.map(\.accountID) == [stopped.id, other.id])

    // Once the conversation continues, resets that already passed are dropped.
    state.finishWaiting(now: now.addingTimeInterval(1_000))
    #expect(state.isArmed)
    #expect(state.verifiedExhaustedAccountID == nil)
    #expect(state.fiveHourResetWaits.map(\.accountID) == [other.id])
}
