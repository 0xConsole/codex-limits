import Foundation

public enum AutoResumeError: LocalizedError, Sendable {
    case noEligibleAccount
    case waitingForFiveHourReplenishment(String)
    case codexHomeMissing
    case noRecentQuotaStoppedThreads
    case accountIdentityChanged
    case threadWriterBusy(String)
    case destinationTurnFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noEligibleAccount:
            return "No saved account has a replenished 5-hour Codex limit yet."
        case .waitingForFiveHourReplenishment(let email):
            return "\(email) hit a Codex usage limit. Auto Resume will wait for a saved account's 5-hour limit to replenish, then continue the most recent stopped conversation from that account."
        case .codexHomeMissing:
            return "The main Codex session folder could not be found."
        case .noRecentQuotaStoppedThreads:
            return "No recent Codex conversations are stopped on a usage-limit error."
        case .accountIdentityChanged:
            return "Codex is not signed in to the account Auto Resume switched to. Sign in to that account again in Codex Limits."
        case .threadWriterBusy(let threadID):
            return "Codex Desktop ownership changed while Auto Resume was preparing conversation \(threadID). It will revalidate and retry instead of silently skipping it."
        case .destinationTurnFailed(let message):
            return message
        }
    }
}

public actor AutoResumeCoordinator {
    public static let candidateLookback: TimeInterval = 24 * 60 * 60

    public init() {}

    /// Continues the most recent conversation stopped by a usage limit, on the account
    /// whose 5-hour limit the caller found replenished. Returns true when the
    /// continuation ran to completion and false when the conversation no longer
    /// needed it.
    ///
    /// `prepareAccount` must sign the main Codex home in to that account, by switching
    /// Codex Desktop or by installing its login. Codex then runs the continuation on
    /// the main home's own login, which works with any Codex version.
    public func run(
        accounts: [SavedAccount],
        resumeAccountID: UUID,
        additionalCandidates: [AutoResumeCandidate] = [],
        prepareAccount: @MainActor @Sendable (SavedAccount) async throws -> Void = { _ in },
        prepareDesktopThread: @MainActor @Sendable (String) async throws -> Void = { _ in },
        shouldContinue: @Sendable () async -> Bool = { true },
        progress: @Sendable (String) async -> Void
    ) async throws -> Bool {
        let mainHome = AppPaths.mainCodexHome
        guard FileManager.default.fileExists(atPath: mainHome.appendingPathComponent("sessions", isDirectory: true).path) else {
            throw AutoResumeError.codexHomeMissing
        }

        await progress("Looking for conversations stopped by a Codex usage limit…")
        var journal = try loadJournal()

        guard let selected = accounts.first(where: { $0.id == resumeAccountID }),
              selected.isEligibleForAutoResume
        else {
            throw AutoResumeError.noEligibleAccount
        }

        try await prepareAccount(selected)
        guard CodexAuthSwitcher.activeSavedAccountID(accounts: [selected], mainHome: mainHome) == selected.id else {
            throw AutoResumeError.accountIdentityChanged
        }

        let scanner = try CodexAppServerClient(homeURL: mainHome, experimentalAPI: true)
        try await scanner.start()
        defer { Task { await scanner.stop() } }

        let desktopIPC = await Self.connectToDesktop()
        defer {
            if let desktopIPC {
                Task { await desktopIPC.close() }
            }
        }

        try await reconcileStartedRecords(journal: &journal, scanner: scanner, desktopIPC: desktopIPC)
        try saveJournal(journal)

        let interrupted = try await interruptedContinuationCandidates(scanner: scanner, journal: journal)
        let interruptedThreadIDs = Set(interrupted.map(\.sourceThreadID))
        let durable = try await usageLimitedContinuationCandidates(scanner: scanner, journal: journal)
        let recent = try await recentUsageLimitedCandidates(scanner: scanner, journal: journal)
        let usageLimited = Self.uniqueCandidates(recent + durable + additionalCandidates)
            .filter { !interruptedThreadIDs.contains($0.sourceThreadID) }
        let lockedThreadIDs = Set(additionalCandidates.map(\.sourceThreadID))
        let pool = lockedThreadIDs.isEmpty
            ? interrupted + usageLimited
            : (additionalCandidates + interrupted + usageLimited).filter { lockedThreadIDs.contains($0.sourceThreadID) }
        guard let candidate = Self.mostRecentCandidate(pool) else {
            throw AutoResumeError.noRecentQuotaStoppedThreads
        }

        await progress("\(selected.email)'s 5-hour limit replenished. Continuing the stopped conversation…")
        guard await shouldContinue() else { return false }

        return try await continueConversation(
            candidate,
            isInterrupted: interruptedThreadIDs.contains(candidate.sourceThreadID),
            account: selected,
            journal: &journal,
            scanner: scanner,
            desktopIPC: desktopIPC,
            prepareDesktopThread: prepareDesktopThread,
            shouldContinue: shouldContinue,
            progress: progress
        )
    }

    private func continueConversation(
        _ candidate: AutoResumeCandidate,
        isInterrupted: Bool,
        account: SavedAccount,
        journal: inout AutoResumeJournal,
        scanner: CodexAppServerClient,
        desktopIPC: DesktopIPCClient?,
        prepareDesktopThread: @MainActor @Sendable (String) async throws -> Void,
        shouldContinue: @Sendable () async -> Bool,
        progress: @Sendable (String) async -> Void
    ) async throws -> Bool {
        let threadID = candidate.sourceThreadID
        var owner: DesktopThreadOwner?
        do {
            guard let preflightTurn = try await scanner.latestTurn(threadID: threadID),
                  await Self.stillStops(at: candidate, isInterrupted: isInterrupted, latestTurn: preflightTurn, scanner: scanner)
            else { return false }

            // Prefer Desktop custody even when the conversation is not open. A standalone
            // writer makes Desktop show "This is open in another app" and cannot join its
            // follower stream. Opening Desktop's codex://threads/<id> link makes it load
            // the conversation and advertise itself as the owner.
            if let desktopIPC {
                owner = try await desktopIPC.discoverThreadOwner(threadID: threadID)
                if owner == nil {
                    try await prepareDesktopThread(threadID)
                    owner = try await desktopIPC.discoverThreadOwner(threadID: threadID)
                }
            }
            if owner == nil {
                do {
                    // Desktop could not claim the conversation, so fall back to the
                    // direct app-server path.
                    let source = try await scanner.resumeThread(threadID: threadID, includeTurns: false)
                    guard source["canAcceptDirectInput"]?.boolValue == true else { return false }
                } catch {
                    guard Self.isActiveWriterError(error) else { throw error }
                    owner = try await desktopIPC?.discoverThreadOwner(threadID: threadID)
                    guard owner != nil else { throw AutoResumeError.threadWriterBusy(threadID) }
                }
            }

            var ownerBaselineRevision: Int?
            if let owner, let desktopIPC {
                guard owner.supportsUntrustedAppInput else {
                    throw DesktopIPCError.invalidResponse("Desktop owner did not advertise safe follower input for \(threadID)")
                }
                try await desktopIPC.followThread(threadID: threadID, ownerClientID: owner.clientID)
                let baseline = try await desktopIPC.waitForThreadSnapshot(threadID: threadID, ownerClientID: owner.clientID)
                ownerBaselineRevision = baseline.params["change"]?["revision"]?.intValue
            }

            guard let finalTurn = try await scanner.latestTurn(threadID: threadID),
                  Self.isContinuationBoundary(finalTurn, of: candidate, isInterrupted: isInterrupted)
            else {
                await release(owner, from: desktopIPC, threadID: threadID)
                return false
            }

            // Stop may have been pressed while ownership or the boundary was checked.
            // This is the last safe point before the durable claim and turn/start. A
            // turn Codex has accepted is left to finish rather than interrupted.
            guard await shouldContinue() else {
                await release(owner, from: desktopIPC, threadID: threadID)
                throw CancellationError()
            }

            guard let turnID = try await startContinuation(
                of: candidate,
                account: account,
                owner: owner,
                journal: &journal,
                scanner: scanner,
                desktopIPC: desktopIPC
            ) else { return false }

            await progress("Codex is continuing the conversation on \(account.email). Long model or tool work can take several minutes…")

            let outcome: CodexTurnOutcome
            if let owner, let desktopIPC {
                outcome = try await waitForOwnerTurnCompletion(
                    desktopIPC: desktopIPC,
                    scanner: scanner,
                    owner: owner,
                    threadID: threadID,
                    turnID: turnID,
                    baselineRevision: ownerBaselineRevision,
                    shouldContinue: shouldContinue
                )
            } else {
                outcome = try await scanner.waitForTurnCompletion(threadID: threadID, turnID: turnID)
            }
            await release(owner, from: desktopIPC, threadID: threadID)
            if let index = journal.records.firstIndex(where: { $0.sourceTurnID == candidate.failedTurnID }) {
                journal.records[index].status = outcome.status == "completed" ? .completed : .consumed
                journal.records[index].errorInfo = outcome.errorInfo
                    ?? (outcome.status == "interrupted" ? "interrupted" : nil)
                try saveJournal(journal)
            }

            if outcome.status == "failed", outcome.errorInfo == "usageLimitExceeded" {
                guard await shouldContinue() else { return false }
                // The failed turn is the new continuation boundary. Release this
                // app-server and let the caller wait for a replenished 5-hour window.
                await scanner.stop()
                throw AutoResumeError.waitingForFiveHourReplenishment(account.email)
            }
            guard outcome.status == "completed" else {
                let detail = outcome.errorMessage ?? outcome.errorInfo ?? "Codex returned \(outcome.status)."
                throw AutoResumeError.destinationTurnFailed("Auto Resume stopped: \(detail)")
            }
            return true
        } catch {
            await release(owner, from: desktopIPC, threadID: threadID)
            if Self.isActiveWriterError(error) {
                throw AutoResumeError.threadWriterBusy(threadID)
            }
            throw error
        }
    }

    /// Records a durable claim on the stopped turn, then starts an empty continuation
    /// turn. Returns nil when Codex reports that another turn already started.
    private func startContinuation(
        of candidate: AutoResumeCandidate,
        account: SavedAccount,
        owner: DesktopThreadOwner?,
        journal: inout AutoResumeJournal,
        scanner: CodexAppServerClient,
        desktopIPC: DesktopIPCClient?
    ) async throws -> String? {
        let threadID = candidate.sourceThreadID
        journal.records.removeAll { $0.sourceTurnID == candidate.failedTurnID }
        journal.records.append(
            AutoResumeRecord(
                sourceThreadID: threadID,
                sourceTurnID: candidate.failedTurnID,
                destinationThreadID: threadID,
                destinationTurnID: nil,
                accountID: account.id,
                status: .started,
                errorInfo: nil,
                createdAt: Date()
            )
        )
        try saveJournal(journal)

        // Errors other than the definite rejections below leave the outcome unknown:
        // the request may have been accepted. They propagate with the `.started` claim
        // kept, so restart reconciliation can see whether a turn began before retrying.
        let turnID: String
        do {
            if let owner, let desktopIPC {
                turnID = try await desktopIPC.startEmptyContinuation(threadID: threadID, ownerClientID: owner.clientID)
            } else {
                turnID = try await scanner.startTurn(threadID: threadID, input: [])
            }
        } catch let clientError as CodexClientError where Self.isActiveTurnEmptyInputRace(clientError) {
            let latest = try? await scanner.latestTurn(threadID: threadID)
            try markClaim(
                of: candidate,
                in: &journal,
                as: latest?["id"]?.stringValue == candidate.failedTurnID ? .failed : .consumed
            )
            return nil
        } catch let error as DesktopIPCError {
            // The router sends its exact `no-client-found` error before forwarding the
            // request, so that one is a definite rejection: release the claim and
            // force a full ownership recheck.
            if Self.isDefiniteDesktopOwnerStartRejection(error) {
                try markClaim(of: candidate, in: &journal, as: .failed)
                throw AutoResumeError.threadWriterBusy(threadID)
            }
            throw error
        } catch let clientError as CodexClientError {
            // On the direct path only an explicit JSON-RPC error proves turn/start was
            // rejected. A timeout or broken pipe can follow an accepted request.
            if Self.isDefiniteTurnStartRejection(clientError) {
                try markClaim(of: candidate, in: &journal, as: .failed)
            }
            throw clientError
        }

        if let index = journal.records.firstIndex(where: { $0.sourceTurnID == candidate.failedTurnID }) {
            journal.records[index].destinationTurnID = turnID
            try saveJournal(journal)
        }
        return turnID
    }

    private func markClaim(
        of candidate: AutoResumeCandidate,
        in journal: inout AutoResumeJournal,
        as status: AutoResumeRecordStatus
    ) throws {
        guard let index = journal.records.firstIndex(where: { $0.sourceTurnID == candidate.failedTurnID }) else { return }
        journal.records[index].status = status
        try saveJournal(journal)
    }

    private func release(_ owner: DesktopThreadOwner?, from desktopIPC: DesktopIPCClient?, threadID: String) async {
        guard let owner, let desktopIPC else { return }
        try? await desktopIPC.unfollowThread(threadID: threadID, ownerClientID: owner.clientID)
    }

    /// Whether the conversation still ends on the turn Auto Resume is continuing from.
    private static func stillStops(
        at candidate: AutoResumeCandidate,
        isInterrupted: Bool,
        latestTurn: JSONValue,
        scanner: CodexAppServerClient
    ) async -> Bool {
        if isInterrupted {
            return latestTurn["id"]?.stringValue == candidate.failedTurnID
                && latestTurn["status"]?.stringValue == "interrupted"
        }
        let fresh = await scanner.usageLimitedCandidate(
            thread: .object([
                "id": .string(candidate.sourceThreadID),
                "updatedAt": candidate.updatedAt.map { .number($0.timeIntervalSince1970) } ?? .null,
            ]),
            latestTurn: latestTurn
        )
        return fresh?.failedTurnID == candidate.failedTurnID
    }

    static func isContinuationBoundary(_ turn: JSONValue, of candidate: AutoResumeCandidate, isInterrupted: Bool) -> Bool {
        guard turn["id"]?.stringValue == candidate.failedTurnID else { return false }
        if isInterrupted {
            return turn["status"]?.stringValue == "interrupted"
        }
        return turn["status"]?.stringValue == "failed"
            && turn["error"]?["codexErrorInfo"]?.stringValue == "usageLimitExceeded"
    }

    static func isActiveWriterError(_ error: Error) -> Bool {
        error.localizedDescription.lowercased().contains("active writer")
    }

    /// Codex Desktop's IPC router, when Desktop is running. Owner routing only matters
    /// when a live Desktop client owns the conversation; otherwise the direct
    /// app-server path is used.
    /// Whether Codex Desktop is running. Desktop continues conversations on its own
    /// login, which only the menu-bar app can switch.
    public static func isCodexDesktopRunning() async -> Bool {
        guard let client = await connectToDesktop() else { return false }
        await client.close()
        return true
    }

    private static func connectToDesktop() async -> DesktopIPCClient? {
        let client = DesktopIPCClient()
        do {
            try await client.connect()
            return client
        } catch {
            return nil
        }
    }

    public func pendingUsageLimitedCandidates(
        preserving existing: [AutoResumeCandidate],
        includeJournalRecovery: Bool = true
    ) async throws -> [AutoResumeCandidate] {
        let scanner = try CodexAppServerClient(
            homeURL: AppPaths.mainCodexHome,
            experimentalAPI: true
        )
        try await scanner.start()
        defer { Task { await scanner.stop() } }

        let desktopIPC = await Self.connectToDesktop()
        defer {
            if let desktopIPC {
                Task { await desktopIPC.close() }
            }
        }

        var journal = try loadJournal()
        try await reconcileStartedRecords(journal: &journal, scanner: scanner, desktopIPC: desktopIPC)
        try saveJournal(journal)

        // A journal-proven interrupted destination is still part of the exact same
        // continuation chain that began at a usage-limit boundary. Persist it in the
        // outer control state too, otherwise an app restart with no *other* quota-failed
        // thread could leave the persistent loop with an empty pending set and never
        // enter run() to recover this continuation.
        let interrupted = try await interruptedContinuationCandidates(scanner: scanner, journal: journal)
        let interruptedThreadIDs = Set(interrupted.map(\.sourceThreadID))

        var retained: [AutoResumeCandidate] = []
        for candidate in existing where !interruptedThreadIDs.contains(candidate.sourceThreadID) {
            do {
                guard let latest = try await scanner.latestTurn(threadID: candidate.sourceThreadID),
                      let refreshed = Self.refreshedPendingCandidate(candidate, latestTurn: latest)
                else { continue }
                retained.append(refreshed)
            } catch {
                // A transient read failure must not erase a durable waiting boundary.
                // Keep it and revalidate on the next pass before any turn is started.
                retained.append(candidate)
            }
        }

        let selectedThreadIDs = Set(existing.map(\.sourceThreadID))
        let selectedChainThreadIDs = Set(
            existing
                .filter { Self.candidateBelongsToClaimedContinuation($0, journal: journal) }
                .map(\.sourceThreadID)
        )
        let recent = try await recentUsageLimitedCandidates(scanner: scanner, journal: journal)
        var pool = recent.filter {
            selectedChainThreadIDs.isEmpty || selectedChainThreadIDs.contains($0.sourceThreadID)
        } + retained
        if includeJournalRecovery {
            let durable = try await usageLimitedContinuationCandidates(scanner: scanner, journal: journal)
            if selectedThreadIDs.isEmpty {
                pool += interrupted + durable
            } else {
                pool += interrupted.filter { selectedThreadIDs.contains($0.sourceThreadID) }
                pool += durable.filter { selectedThreadIDs.contains($0.sourceThreadID) }
            }
        }
        guard let newest = Self.mostRecentCandidate(pool) else {
            return []
        }
        return [newest]
    }

    static func uniqueCandidates(_ candidates: [AutoResumeCandidate]) -> [AutoResumeCandidate] {
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.sourceThreadID).inserted }
    }

    static func mostRecentCandidate(_ candidates: [AutoResumeCandidate]) -> AutoResumeCandidate? {
        var newest: AutoResumeCandidate?
        for candidate in candidates {
            guard let current = newest else {
                newest = candidate
                continue
            }
            let candidateDate = candidate.updatedAt ?? .distantPast
            let currentDate = current.updatedAt ?? .distantPast
            if candidateDate > currentDate {
                newest = candidate
            }
        }
        return newest
    }

    static func candidateBelongsToClaimedContinuation(
        _ candidate: AutoResumeCandidate,
        journal: AutoResumeJournal
    ) -> Bool {
        journal.records.contains { record in
            record.sourceThreadID == candidate.sourceThreadID
                && (record.sourceTurnID == candidate.failedTurnID
                    || record.destinationTurnID == candidate.failedTurnID)
        }
    }

    static func refreshedPendingCandidate(
        _ existing: AutoResumeCandidate,
        latestTurn: JSONValue
    ) -> AutoResumeCandidate? {
        guard latestTurn["status"]?.stringValue == "failed",
              latestTurn["error"]?["codexErrorInfo"]?.stringValue == "usageLimitExceeded",
              let latestTurnID = latestTurn["id"]?.stringValue,
              !latestTurnID.isEmpty
        else { return nil }

        return AutoResumeCandidate(
            sourceThreadID: existing.sourceThreadID,
            failedTurnID: latestTurnID,
            updatedAt: existing.updatedAt
        )
    }

    static func isActiveTurnEmptyInputRace(_ error: CodexClientError) -> Bool {
        guard case .serverError(let message) = error else { return false }
        return message == "failed to submit turn input: EmptyInput"
    }

    private func waitForOwnerTurnCompletion(
        desktopIPC: DesktopIPCClient,
        scanner: CodexAppServerClient,
        owner: DesktopThreadOwner,
        threadID: String,
        turnID: String,
        baselineRevision: Int?,
        shouldContinue: @Sendable () async -> Bool
    ) async throws -> CodexTurnOutcome {
        var minimumRevision = baselineRevision

        while await shouldContinue() {
            do {
                let snapshot = try await desktopIPC.waitForThreadSnapshot(
                    threadID: threadID,
                    ownerClientID: owner.clientID,
                    minimumRevisionExclusive: minimumRevision,
                    timeoutSeconds: 30
                )
                if let revision = snapshot.params["change"]?["revision"]?.intValue {
                    minimumRevision = max(minimumRevision ?? -1, revision)
                }
                guard let liveOutcome = DesktopIPCClient.ownerTurnOutcome(
                    from: snapshot,
                    threadID: threadID,
                    turnID: turnID,
                    ownerClientID: owner.clientID
                ) else { continue }
                if liveOutcome.status == "inProgress" { continue }

                // The owner snapshot is the authority that this turn is terminal.
                // Once terminal is proven live, persisted history is safe to use only
                // to enrich Codex's error payload when deciding whether to wait for
                // the 5-hour limit to replenish.
                if let latest = try? await scanner.latestTurn(threadID: threadID),
                   latest["id"]?.stringValue == turnID,
                   let durable = Self.outcome(from: latest),
                   durable.status == liveOutcome.status {
                    return durable
                }
                return liveOutcome
            } catch let error as DesktopIPCError {
                guard case .requestTimedOut = error else { throw error }

                if let latest = try? await scanner.latestTurn(threadID: threadID),
                   latest["id"]?.stringValue == turnID,
                   let durable = Self.outcome(from: latest) {
                    if durable.status == "completed" || durable.status == "failed" {
                        return durable
                    }
                    if durable.status == "interrupted" {
                        let currentOwner = try? await desktopIPC.discoverThreadOwner(threadID: threadID)
                        // A transient owner disconnect/reconnect is not terminal proof.
                        // Keep the accepted destination claimed and let the next pass
                        // reconcile it with live ownership (or a successful direct
                        // writer probe) rather than starting another continuation.
                        if currentOwner == nil {
                            throw AutoResumeError.threadWriterBusy(threadID)
                        }
                        if currentOwner?.clientID != owner.clientID {
                            throw AutoResumeError.threadWriterBusy(threadID)
                        }
                    }
                }
            }
        }

        // Stopping Auto Resume never sends an interrupt to the owner. The `.started`
        // journal record remains intact for restart/re-arm reconciliation.
        throw CancellationError()
    }

    static func outcome(from turn: JSONValue) -> CodexTurnOutcome? {
        guard let id = turn["id"]?.stringValue,
              let status = turn["status"]?.stringValue,
              status != "inProgress"
        else { return nil }
        let error = turn["error"]?.objectValue
        return CodexTurnOutcome(
            id: id,
            status: status,
            errorInfo: error?["codexErrorInfo"]?.stringValue,
            errorMessage: error?["message"]?.stringValue
        )
    }


    static func isDefiniteTurnStartRejection(_ error: CodexClientError) -> Bool {
        if case .serverError = error { return true }
        return false
    }

    static func isDefiniteDesktopOwnerStartRejection(_ error: DesktopIPCError) -> Bool {
        guard case .serverError(let message) = error else { return false }
        return message == "no-client-found"
    }
}
