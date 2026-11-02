import Foundation
import Testing
@testable import CodexLimitsCore

@Test("Auto Resume only treats Codex's exact empty-input error as an active-turn race")
func activeTurnRaceClassification() {
    #expect(AutoResumeCoordinator.isActiveTurnEmptyInputRace(
        .serverError("failed to submit turn input: EmptyInput")
    ))
    #expect(!AutoResumeCoordinator.isActiveTurnEmptyInputRace(
        .serverError("input was empty for some other reason")
    ))
}

@Test("Auto Resume can safely chain from its own latest interrupted continuation")
func interruptedContinuationRecoveryClassification() {
    let accountID = UUID()
    let createdAt = Date().addingTimeInterval(-8 * 24 * 60 * 60)
    let record = AutoResumeRecord(
        sourceThreadID: "thread-1",
        sourceTurnID: "quota-turn",
        destinationThreadID: "thread-1",
        destinationTurnID: "interrupted-turn",
        accountID: accountID,
        status: .consumed,
        errorInfo: "interrupted",
        createdAt: createdAt
    )
    let latest: JSONValue = .object([
        "id": .string("interrupted-turn"),
        "status": .string("interrupted"),
    ])

    #expect(AutoResumeCoordinator.recoverableInterruptedDestinationTurnID(
        record: record,
        latestTurn: latest,
        alreadyClaimedSourceTurnIDs: []
    ) == "interrupted-turn")

    #expect(AutoResumeCoordinator.recoverableInterruptedDestinationTurnID(
        record: record,
        latestTurn: latest,
        alreadyClaimedSourceTurnIDs: ["interrupted-turn"]
    ) == nil)
}

@Test("Auto Resume restart reconciliation never retries an outcome-ambiguous start by time alone")
func autoResumeRestartReconciliation() {
    #expect(AutoResumeCoordinator.reconciledUnacceptedStartStatus(
        sourceTurnID: "failed-turn",
        latestTurnID: "failed-turn"
    ) == .started)
    #expect(AutoResumeCoordinator.reconciledUnacceptedStartStatus(
        sourceTurnID: "failed-turn",
        latestTurnID: "successor-turn"
    ) == .consumed)

    #expect(AutoResumeCoordinator.isDefiniteTurnStartRejection(.serverError("rejected")))
    #expect(!AutoResumeCoordinator.isDefiniteTurnStartRejection(.requestTimedOut("turn/start")))
    #expect(!AutoResumeCoordinator.isDefiniteTurnStartRejection(.processExited(1)))
    #expect(!AutoResumeCoordinator.isDefiniteTurnStartRejection(.protocolError("missing turn id")))

    #expect(AutoResumeCoordinator.isDefiniteDesktopOwnerStartRejection(.serverError("no-client-found")))
    #expect(!AutoResumeCoordinator.isDefiniteDesktopOwnerStartRejection(.serverError("no-client-found: owner disappeared")))
    #expect(!AutoResumeCoordinator.isDefiniteDesktopOwnerStartRejection(.requestTimedOut("thread-follower-start-turn")))
    #expect(!AutoResumeCoordinator.isDefiniteDesktopOwnerStartRejection(.connectionClosed))
}

@Test("Auto Resume chooses only the newest recent quota-stopped conversation")
func autoResumeNewestCandidateOnly() {
    let old = AutoResumeCandidate(
        sourceThreadID: "thread-old",
        failedTurnID: "turn-old",
        updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    let newest = AutoResumeCandidate(
        sourceThreadID: "thread-newest",
        failedTurnID: "turn-newest",
        updatedAt: Date(timeIntervalSince1970: 1_800_000_200)
    )
    let undated = AutoResumeCandidate(
        sourceThreadID: "thread-undated",
        failedTurnID: "turn-undated",
        updatedAt: nil
    )

    #expect(AutoResumeCoordinator.mostRecentCandidate([old, newest, undated]) == newest)
    #expect(AutoResumeCoordinator.mostRecentCandidate([undated]) == undated)
    #expect(AutoResumeCoordinator.mostRecentCandidate([]) == nil)
}

@Test("Auto Resume locks a started continuation chain to its selected conversation")
func autoResumeClaimedContinuationLock() {
    let accountID = UUID()
    let selected = AutoResumeCandidate(
        sourceThreadID: "thread-selected",
        failedTurnID: "turn-selected-successor",
        updatedAt: Date(timeIntervalSince1970: 1_800_000_200)
    )
    let unrelated = AutoResumeCandidate(
        sourceThreadID: "thread-other",
        failedTurnID: "turn-other",
        updatedAt: Date(timeIntervalSince1970: 1_800_000_300)
    )
    let journal = AutoResumeJournal(records: [
        AutoResumeRecord(
            sourceThreadID: "thread-selected",
            sourceTurnID: "turn-original-quota",
            destinationThreadID: "thread-selected",
            destinationTurnID: "turn-selected-successor",
            accountID: accountID,
            status: .consumed,
            errorInfo: "usageLimitExceeded",
            createdAt: Date(timeIntervalSince1970: 1_800_000_150)
        )
    ])

    #expect(AutoResumeCoordinator.candidateBelongsToClaimedContinuation(selected, journal: journal))
    #expect(!AutoResumeCoordinator.candidateBelongsToClaimedContinuation(unrelated, journal: journal))
}

@Test("Auto Resume refreshes a stale pending quota boundary and prunes a completed thread")
func autoResumePendingCandidateRefresh() {
    let original = AutoResumeCandidate(
        sourceThreadID: "thread-1",
        failedTurnID: "old-quota-turn",
        updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    let newerQuotaFailure: JSONValue = .object([
        "id": .string("new-quota-turn"),
        "status": .string("failed"),
        "error": .object(["codexErrorInfo": .string("usageLimitExceeded")]),
    ])
    let refreshed = AutoResumeCoordinator.refreshedPendingCandidate(
        original,
        latestTurn: newerQuotaFailure
    )
    #expect(refreshed?.sourceThreadID == original.sourceThreadID)
    #expect(refreshed?.failedTurnID == "new-quota-turn")
    #expect(refreshed?.updatedAt == original.updatedAt)

    let completed: JSONValue = .object([
        "id": .string("completed-turn"),
        "status": .string("completed"),
        "error": .null,
    ])
    #expect(AutoResumeCoordinator.refreshedPendingCandidate(original, latestTurn: completed) == nil)
}

@Test("Auto Resume pending precedence keeps a journal-proven interrupted continuation ahead of stale quota state")
func autoResumePendingInterruptedPrecedence() {
    let interrupted = AutoResumeCandidate(
        sourceThreadID: "thread-1",
        failedTurnID: "own-interrupted-successor",
        updatedAt: Date(timeIntervalSince1970: 1_800_000_100)
    )
    let staleQuota = AutoResumeCandidate(
        sourceThreadID: "thread-1",
        failedTurnID: "old-quota-turn",
        updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    let anotherQuota = AutoResumeCandidate(
        sourceThreadID: "thread-2",
        failedTurnID: "quota-turn-2",
        updatedAt: Date(timeIntervalSince1970: 1_800_000_200)
    )

    let merged = AutoResumeCoordinator.uniqueCandidates([
        interrupted,
        staleQuota,
        anotherQuota,
    ])
    #expect(merged == [interrupted, anotherQuota])
}
