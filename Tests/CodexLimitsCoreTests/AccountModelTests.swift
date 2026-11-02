import Foundation
import Testing
@testable import CodexLimitsCore

@Test("Limit windows expose remaining percentages")
func remainingPercent() {
    let normal = LimitWindow(usedPercent: 37, windowDurationMinutes: 300, resetsAt: nil)
    #expect(normal.remainingPercent == 63)

    let over = LimitWindow(usedPercent: 140, windowDurationMinutes: 300, resetsAt: nil)
    #expect(over.remainingPercent == 0)

    let negative = LimitWindow(usedPercent: -10, windowDurationMinutes: 300, resetsAt: nil)
    #expect(negative.remainingPercent == 100)
}

@Test("Auto Resume only treats a fresh explicit Codex quota denial as exhausted")
func definiteAutoResumeUsageLimit() {
    let now = Date()
    func account(
        ordinaryAllowed: Bool?,
        rateLimitReason: String?,
        fiveHourUsed: Double,
        weeklyUsed: Double,
        lastError: String? = nil
    ) -> SavedAccount {
        SavedAccount(
            id: UUID(),
            email: "current@example.com",
            planType: "business",
            accountID: "workspace-current",
            usage: UsageSnapshot(
                fiveHour: LimitWindow(usedPercent: fiveHourUsed, windowDurationMinutes: 300, resetsAt: nil),
                weekly: LimitWindow(usedPercent: weeklyUsed, windowDurationMinutes: 10_080, resetsAt: nil),
                ordinaryUsageAllowed: ordinaryAllowed,
                rateLimitReachedType: rateLimitReason
            ),
            lastRefreshedAt: now,
            lastError: lastError,
            needsReauthentication: false,
            createdAt: now
        )
    }

    #expect(account(
        ordinaryAllowed: false,
        rateLimitReason: "workspace_owner_credits_depleted",
        fiveHourUsed: 20,
        weeklyUsed: 80
    ).isDefinitelyUsageLimitedForAutoResume)
    #expect(account(
        ordinaryAllowed: false,
        rateLimitReason: nil,
        fiveHourUsed: 100,
        weeklyUsed: 80
    ).isDefinitelyUsageLimitedForAutoResume)
    #expect(!account(
        ordinaryAllowed: true,
        rateLimitReason: "workspace_owner_credits_depleted",
        fiveHourUsed: 100,
        weeklyUsed: 100
    ).isDefinitelyUsageLimitedForAutoResume)
    #expect(!account(
        ordinaryAllowed: false,
        rateLimitReason: nil,
        fiveHourUsed: 20,
        weeklyUsed: 80
    ).isDefinitelyUsageLimitedForAutoResume)
    #expect(!account(
        ordinaryAllowed: false,
        rateLimitReason: "workspace_owner_credits_depleted",
        fiveHourUsed: 100,
        weeklyUsed: 100,
        lastError: "refresh failed"
    ).isDefinitelyUsageLimitedForAutoResume)
}

@Test("JSONValue decodes Codex numeric and nullable fields")
func jsonValueDecoding() throws {
    let data = Data(#"{"primary":{"usedPercent":42,"windowDurationMins":300,"resetsAt":1789492302},"ordinaryUsageAllowed":false,"missing":null}"#.utf8)
    let value = try JSONDecoder().decode(JSONValue.self, from: data)
    #expect(value["primary"]?["usedPercent"]?.doubleValue == 42)
    #expect(value["primary"]?["windowDurationMins"]?.intValue == 300)
    #expect(value["ordinaryUsageAllowed"]?.boolValue == false)
    #expect(value["missing"] == .null)
}

@Test("Auto Resume control state persists armed mode and the exact pending turn")
func autoResumeControlStateRoundTrip() throws {
    let pending = AutoResumeCandidate(
        sourceThreadID: "thread-pending",
        failedTurnID: "turn-usage-limit",
        updatedAt: Date(timeIntervalSince1970: 1_800_000_123)
    )
    let exhaustedAccountID = UUID()
    let verifiedAt = Date(timeIntervalSince1970: 1_800_000_456)
    let resetWaits = [
        AutoResumeFiveHourResetWait(accountID: exhaustedAccountID, resetsAt: Date(timeIntervalSince1970: 1_800_018_000)),
        AutoResumeFiveHourResetWait(accountID: UUID(), resetsAt: Date(timeIntervalSince1970: 1_800_009_000)),
    ]
    let original = AutoResumeControlState(
        isArmed: true,
        pendingCandidates: [pending],
        verifiedExhaustedAccountID: exhaustedAccountID,
        verifiedExhaustedAt: verifiedAt,
        fiveHourResetWaits: resetWaits
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(original)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(AutoResumeControlState.self, from: data)

    #expect(decoded.isArmed)
    #expect(decoded.pendingCandidates == [pending])
    #expect(decoded.verifiedExhaustedAccountID == exhaustedAccountID)
    #expect(decoded.verifiedExhaustedAt == verifiedAt)
    #expect(decoded.fiveHourResetWaits == resetWaits)
}

@Test("Auto Resume control state safely migrates legacy files without verified exhaustion")
func autoResumeControlStateLegacyDecode() throws {
    let legacy = Data(#"""
    {
      "isArmed": true,
      "pendingCandidates": [
        {
          "sourceThreadID": "thread-legacy",
          "failedTurnID": "turn-legacy",
          "updatedAt": "2026-09-24T11:16:29Z"
        }
      ]
    }
    """#.utf8)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(AutoResumeControlState.self, from: legacy)

    #expect(decoded.isArmed)
    #expect(decoded.pendingCandidates.map(\.sourceThreadID) == ["thread-legacy"])
    #expect(decoded.verifiedExhaustedAccountID == nil)
    #expect(decoded.verifiedExhaustedAt == nil)
    #expect(decoded.fiveHourResetWaits.isEmpty)
}
