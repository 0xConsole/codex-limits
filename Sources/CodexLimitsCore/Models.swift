import Foundation

public struct LimitWindow: Codable, Sendable, Equatable {
    public let usedPercent: Double
    public let windowDurationMinutes: Int?
    public let resetsAt: Date?

    public init(usedPercent: Double, windowDurationMinutes: Int?, resetsAt: Date?) {
        self.usedPercent = usedPercent
        self.windowDurationMinutes = windowDurationMinutes
        self.resetsAt = resetsAt
    }

    public var remainingPercent: Double {
        max(0, min(100, 100 - usedPercent))
    }

    /// Codex reports whole percentages, so a window with nothing used is full again.
    public var isFullyReplenished: Bool {
        usedPercent <= 0
    }
}

public struct UsageSnapshot: Codable, Sendable, Equatable {
    public let fiveHour: LimitWindow?
    public let weekly: LimitWindow?
    public let ordinaryUsageAllowed: Bool?
    public let rateLimitReachedType: String?

    public init(
        fiveHour: LimitWindow?,
        weekly: LimitWindow?,
        ordinaryUsageAllowed: Bool?,
        rateLimitReachedType: String?
    ) {
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.ordinaryUsageAllowed = ordinaryUsageAllowed
        self.rateLimitReachedType = rateLimitReachedType
    }
}

public struct AccountSnapshot: Sendable, Equatable {
    public let email: String
    public let planType: String
    public let accountID: String?
    public let usage: UsageSnapshot

    public init(email: String, planType: String, accountID: String?, usage: UsageSnapshot) {
        self.email = email
        self.planType = planType
        self.accountID = accountID
        self.usage = usage
    }
}

public struct SavedAccount: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var email: String
    public var planType: String
    public var accountID: String?
    public var usage: UsageSnapshot?
    public var lastRefreshedAt: Date?
    public var lastError: String?
    public var needsReauthentication: Bool?
    public let createdAt: Date

    public init(
        id: UUID,
        email: String,
        planType: String,
        accountID: String?,
        usage: UsageSnapshot?,
        lastRefreshedAt: Date?,
        lastError: String?,
        needsReauthentication: Bool? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.email = email
        self.planType = planType
        self.accountID = accountID
        self.usage = usage
        self.lastRefreshedAt = lastRefreshedAt
        self.lastError = lastError
        self.needsReauthentication = needsReauthentication
        self.createdAt = createdAt
    }

    public var isEligibleForAutoResume: Bool {
        guard needsReauthentication != true,
              usage?.ordinaryUsageAllowed != false,
              let fiveHour = usage?.fiveHour?.remainingPercent,
              let weekly = usage?.weekly?.remainingPercent
        else { return false }
        return fiveHour > 0 && weekly > 0
    }

    /// This account with a fresh quota snapshot applied.
    public func refreshed(with snapshot: AccountSnapshot, at date: Date = Date()) -> SavedAccount {
        var copy = self
        copy.email = snapshot.email
        copy.planType = snapshot.planType
        copy.accountID = snapshot.accountID
        copy.usage = snapshot.usage
        copy.lastRefreshedAt = date
        copy.lastError = nil
        copy.needsReauthentication = false
        return copy
    }

    /// This account after a failed refresh. The last good quota snapshot is kept.
    public func refreshFailed(_ error: Error) -> SavedAccount {
        var copy = self
        copy.lastError = error.localizedDescription
        if (error as? CodexClientError)?.requiresSignIn == true {
            copy.needsReauthentication = true
        }
        return copy
    }

    public var canReauthenticateForAutoResume: Bool {
        needsReauthentication == true
            && usage?.fiveHour != nil
            && usage?.weekly != nil
    }

    /// Auto Resume's trigger gate is deliberately stricter than ordinary account
    /// eligibility. We only treat the *currently signed-in Desktop account* as
    /// exhausted after a fresh Codex quota read explicitly says ordinary usage is
    /// disallowed and also exposes concrete rate-limit evidence. Missing/stale auth,
    /// refresh failures, and ambiguous snapshots must never trigger a conversation.
    public var isDefinitelyUsageLimitedForAutoResume: Bool {
        guard needsReauthentication != true,
              lastError == nil,
              let usage,
              usage.ordinaryUsageAllowed == false
        else { return false }

        let hasExplicitLimitReason = usage.rateLimitReachedType?.isEmpty == false
        let exhaustedWindow = usage.fiveHour?.remainingPercent == 0
            || usage.weekly?.remainingPercent == 0
        return hasExplicitLimitReason || exhaustedWindow
    }
}

public struct AutoResumeCandidate: Codable, Sendable, Equatable {
    public let sourceThreadID: String
    public let failedTurnID: String
    public let updatedAt: Date?

    public init(sourceThreadID: String, failedTurnID: String, updatedAt: Date?) {
        self.sourceThreadID = sourceThreadID
        self.failedTurnID = failedTurnID
        self.updatedAt = updatedAt
    }
}

/// The 5-hour reset Auto Resume waits on for one saved account that a usage limit
/// stopped.
public struct AutoResumeFiveHourResetWait: Codable, Sendable, Equatable {
    public let accountID: UUID
    public let resetsAt: Date

    public init(accountID: UUID, resetsAt: Date) {
        self.accountID = accountID
        self.resetsAt = resetsAt
    }
}

public struct AutoResumeControlState: Codable, Sendable, Equatable {
    public var isArmed: Bool
    public var pendingCandidates: [AutoResumeCandidate]
    public var verifiedExhaustedAccountID: UUID?
    public var verifiedExhaustedAt: Date?
    /// Per-account resets of the 5-hour windows that stopped the conversation. Auto
    /// Resume does not continue on an account before its reset, including when a
    /// stale quota snapshot still shows capacity.
    public var fiveHourResetWaits: [AutoResumeFiveHourResetWait]

    public init(
        isArmed: Bool = false,
        pendingCandidates: [AutoResumeCandidate] = [],
        verifiedExhaustedAccountID: UUID? = nil,
        verifiedExhaustedAt: Date? = nil,
        fiveHourResetWaits: [AutoResumeFiveHourResetWait] = []
    ) {
        self.isArmed = isArmed
        self.pendingCandidates = pendingCandidates
        self.verifiedExhaustedAccountID = verifiedExhaustedAccountID
        self.verifiedExhaustedAt = verifiedExhaustedAt
        self.fiveHourResetWaits = fiveHourResetWaits
    }

    // Files from earlier versions lack the newer fields.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isArmed = try container.decode(Bool.self, forKey: .isArmed)
        pendingCandidates = try container.decodeIfPresent([AutoResumeCandidate].self, forKey: .pendingCandidates) ?? []
        verifiedExhaustedAccountID = try container.decodeIfPresent(UUID.self, forKey: .verifiedExhaustedAccountID)
        verifiedExhaustedAt = try container.decodeIfPresent(Date.self, forKey: .verifiedExhaustedAt)
        fiveHourResetWaits = try container.decodeIfPresent([AutoResumeFiveHourResetWait].self, forKey: .fiveHourResetWaits) ?? []
    }
}

public struct CodexTurnOutcome: Sendable, Equatable {
    public let id: String
    public let status: String
    public let errorInfo: String?
    public let errorMessage: String?

    public init(id: String, status: String, errorInfo: String?, errorMessage: String?) {
        self.id = id
        self.status = status
        self.errorInfo = errorInfo
        self.errorMessage = errorMessage
    }
}

public enum AutoResumeRecordStatus: String, Codable, Sendable {
    case started
    case completed
    case consumed
    case failed
}

public struct AutoResumeRecord: Codable, Sendable, Equatable {
    public let sourceThreadID: String
    public let sourceTurnID: String
    public let destinationThreadID: String
    public var destinationTurnID: String?
    public let accountID: UUID
    public var status: AutoResumeRecordStatus
    public var errorInfo: String?
    public let createdAt: Date

    public init(
        sourceThreadID: String,
        sourceTurnID: String,
        destinationThreadID: String,
        destinationTurnID: String?,
        accountID: UUID,
        status: AutoResumeRecordStatus,
        errorInfo: String?,
        createdAt: Date
    ) {
        self.sourceThreadID = sourceThreadID
        self.sourceTurnID = sourceTurnID
        self.destinationThreadID = destinationThreadID
        self.destinationTurnID = destinationTurnID
        self.accountID = accountID
        self.status = status
        self.errorInfo = errorInfo
        self.createdAt = createdAt
    }
}

public struct AutoResumeJournal: Codable, Sendable, Equatable {
    public var records: [AutoResumeRecord]

    public init(records: [AutoResumeRecord] = []) {
        self.records = records
    }
}

public struct LoginTicket: Sendable, Equatable {
    public let loginID: String
    public let authorizationURL: URL

    public init(loginID: String, authorizationURL: URL) {
        self.loginID = loginID
        self.authorizationURL = authorizationURL
    }
}

public struct LoginCompletion: Sendable, Equatable {
    public let loginID: String?
    public let success: Bool
    public let error: String?

    public init(loginID: String?, success: Bool, error: String?) {
        self.loginID = loginID
        self.success = success
        self.error = error
    }
}

public struct ActiveLogin: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let loginID: String
    public let authorizationURL: URL

    public init(id: UUID, loginID: String, authorizationURL: URL) {
        self.id = id
        self.loginID = loginID
        self.authorizationURL = authorizationURL
    }
}
