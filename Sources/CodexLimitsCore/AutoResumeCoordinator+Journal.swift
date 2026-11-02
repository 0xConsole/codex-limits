import Foundation

/// Recovery from the journal: which conversations still wait on a usage limit, and
/// what became of continuations that were started before a restart.
extension AutoResumeCoordinator {
    static func recoverableInterruptedDestinationTurnID(
        record: AutoResumeRecord,
        latestTurn: JSONValue,
        alreadyClaimedSourceTurnIDs: Set<String>
    ) -> String? {
        guard record.status == .consumed,
              record.errorInfo == "interrupted",
              let interruptedTurnID = record.destinationTurnID,
              !alreadyClaimedSourceTurnIDs.contains(interruptedTurnID),
              latestTurn["id"]?.stringValue == interruptedTurnID,
              latestTurn["status"]?.stringValue == "interrupted"
        else { return nil }
        return interruptedTurnID
    }

    static func reconciledUnacceptedStartStatus(
        sourceTurnID: String,
        latestTurnID: String?
    ) -> AutoResumeRecordStatus {
        if let latestTurnID, latestTurnID != sourceTurnID { return .consumed }
        // Time passing is not proof that a written turn/start request was rejected.
        // A response can be lost after the server accepts the turn. With no persisted
        // idempotency marker on Codex turns, exact-once safety requires retaining the
        // claim rather than guessing and replaying the source.
        return .started
    }

    func recentUsageLimitedCandidates(
        scanner: CodexAppServerClient,
        journal: AutoResumeJournal
    ) async throws -> [AutoResumeCandidate] {
        let cutoff = Date().addingTimeInterval(-Self.candidateLookback)
        let completedSourceTurns = Set(
            journal.records
                .filter { $0.status == .completed || $0.status == .consumed || $0.status == .started }
                .map(\.sourceTurnID)
        )

        var seenThreadIDs = Set<String>()
        var candidates: [AutoResumeCandidate] = []
        var cursor: String?
        repeat {
            let page = try await scanner.listThreadsPage(limit: 100, cursor: cursor)
            var pageHasRecentThread = false
            for thread in page.threads {
                if let updated = thread["updatedAt"]?.doubleValue.map(Date.init(timeIntervalSince1970:)) {
                    if updated < cutoff { continue }
                    pageHasRecentThread = true
                } else {
                    pageHasRecentThread = true
                }

                guard let threadID = thread["id"]?.stringValue,
                      seenThreadIDs.insert(threadID).inserted,
                      thread["parentThreadId"]?.stringValue == nil
                else { continue }

                let latestTurn: JSONValue?
                do {
                    latestTurn = try await scanner.latestTurn(threadID: threadID)
                } catch {
                    continue
                }
                guard let latestTurn,
                      let candidate = await scanner.usageLimitedCandidate(thread: thread, latestTurn: latestTurn),
                      !completedSourceTurns.contains(candidate.failedTurnID)
                else { continue }
                candidates.append(candidate)
            }
            cursor = page.nextCursor
            if !pageHasRecentThread { break }
        } while cursor != nil
        return candidates
    }

    func interruptedContinuationCandidates(
        scanner: CodexAppServerClient,
        journal: AutoResumeJournal
    ) async throws -> [AutoResumeCandidate] {
        let alreadyClaimed = Set(
            journal.records
                .filter { $0.status == .started || $0.status == .completed || $0.status == .consumed }
                .map(\.sourceTurnID)
        )

        var candidates: [AutoResumeCandidate] = []
        var seenTurnIDs = Set<String>()
        for record in journal.records where record.status == .consumed && record.errorInfo == "interrupted" {
            guard let latest = try await scanner.latestTurn(threadID: record.destinationThreadID),
                  let interruptedTurnID = Self.recoverableInterruptedDestinationTurnID(
                    record: record,
                    latestTurn: latest,
                    alreadyClaimedSourceTurnIDs: alreadyClaimed
                  ),
                  seenTurnIDs.insert(interruptedTurnID).inserted
            else { continue }

            candidates.append(
                AutoResumeCandidate(
                    sourceThreadID: record.destinationThreadID,
                    failedTurnID: interruptedTurnID,
                    updatedAt: record.createdAt
                )
            )
        }
        return candidates
    }

    func usageLimitedContinuationCandidates(
        scanner: CodexAppServerClient,
        journal: AutoResumeJournal
    ) async throws -> [AutoResumeCandidate] {
        let alreadyClaimed = Set(
            journal.records
                .filter { $0.status == .started || $0.status == .completed || $0.status == .consumed }
                .map(\.sourceTurnID)
        )

        var candidates: [AutoResumeCandidate] = []
        var seenTurnIDs = Set<String>()
        for record in journal.records where record.status == .consumed && record.errorInfo == "usageLimitExceeded" {
            guard let destinationTurnID = record.destinationTurnID,
                  !alreadyClaimed.contains(destinationTurnID),
                  seenTurnIDs.insert(destinationTurnID).inserted,
                  let latest = try await scanner.latestTurn(threadID: record.destinationThreadID),
                  latest["id"]?.stringValue == destinationTurnID,
                  latest["status"]?.stringValue == "failed",
                  latest["error"]?["codexErrorInfo"]?.stringValue == "usageLimitExceeded"
            else { continue }

            candidates.append(
                AutoResumeCandidate(
                    sourceThreadID: record.destinationThreadID,
                    failedTurnID: destinationTurnID,
                    updatedAt: record.createdAt
                )
            )
        }
        return candidates
    }

    func reconcileStartedRecords(
        journal: inout AutoResumeJournal,
        scanner: CodexAppServerClient,
        desktopIPC: DesktopIPCClient? = nil
    ) async throws {
        for index in journal.records.indices where journal.records[index].status == .started {
            let record = journal.records[index]
            let latest: JSONValue?
            do {
                latest = try await scanner.latestTurn(threadID: record.destinationThreadID)
            } catch {
                continue
            }
            guard let latest else { continue }

            if let destinationTurnID = record.destinationTurnID {
                if latest["id"]?.stringValue != destinationTurnID {
                    journal.records[index].status = .consumed
                    continue
                }

                guard let outcome = Self.outcome(from: latest) else {
                    // A durable in-progress turn remains owned by the original start.
                    continue
                }
                if outcome.status == "completed" {
                    journal.records[index].status = .completed
                    journal.records[index].errorInfo = outcome.errorInfo
                    continue
                }
                if outcome.status == "failed" {
                    journal.records[index].status = .consumed
                    journal.records[index].errorInfo = outcome.errorInfo
                    continue
                }

                if outcome.status == "interrupted", let desktopIPC {
                    var followedOwner: DesktopThreadOwner?
                    do {
                        if let owner = try await desktopIPC.discoverThreadOwner(threadID: record.destinationThreadID) {
                            guard owner.supportsUntrustedAppInput else {
                                // A real owner exists but cannot be safely followed by
                                // this client. Do not downgrade its live turn to the
                                // persisted interrupted reconstruction.
                                continue
                            }
                            followedOwner = owner
                            try await desktopIPC.followThread(
                                threadID: record.destinationThreadID,
                                ownerClientID: owner.clientID
                            )
                            let snapshot = try await desktopIPC.waitForThreadSnapshot(
                                threadID: record.destinationThreadID,
                                ownerClientID: owner.clientID
                            )
                            try? await desktopIPC.unfollowThread(
                                threadID: record.destinationThreadID,
                                ownerClientID: owner.clientID
                            )
                            followedOwner = nil
                            if let liveOutcome = DesktopIPCClient.ownerTurnOutcome(
                                from: snapshot,
                                threadID: record.destinationThreadID,
                                turnID: destinationTurnID,
                                ownerClientID: owner.clientID
                            ) {
                                if liveOutcome.status == "inProgress" {
                                    continue
                                }
                                journal.records[index].status = liveOutcome.status == "completed" ? .completed : .consumed
                                journal.records[index].errorInfo = liveOutcome.errorInfo
                                    ?? (liveOutcome.status == "interrupted" ? "interrupted" : nil)
                                continue
                            }
                            // The live owner could not prove this turn terminal; fail
                            // closed and keep the exact-once claim rather than retrying.
                            continue
                        }
                    } catch {
                        if let followedOwner {
                            try? await desktopIPC.unfollowThread(
                                threadID: record.destinationThreadID,
                                ownerClientID: followedOwner.clientID
                            )
                        }
                        // Transient IPC failure cannot safely turn an ambiguous live
                        // interruption into a retry. Leave `.started` intact.
                        continue
                    }
                }

                if outcome.status == "interrupted" {
                    do {
                        // When no Desktop owner is discoverable (or Desktop is not
                        // running), prove that no other process owns the writer by
                        // acquiring a read/resume handle with this scanner. This starts
                        // no model turn. An active-writer race leaves the durable claim
                        // untouched; a successful probe makes the persisted interrupted
                        // state authoritative after the prior owner has disappeared.
                        _ = try await scanner.resumeThread(
                            threadID: record.destinationThreadID,
                            includeTurns: false
                        )
                    } catch {
                        // Another writer, or any other failure to probe, leaves the
                        // outcome unknown. Exact-once safety wins over retrying.
                        continue
                    }
                }

                journal.records[index].status = .consumed
                journal.records[index].errorInfo = outcome.errorInfo
                    ?? (outcome.status == "interrupted" ? "interrupted" : nil)
                continue
            }

            // A start claim with no returned destination ID remains claimed unless a
            // visible successor proves the source was consumed. Elapsed time is not
            // rejection evidence: the server can accept a request whose response is
            // lost. We intentionally do not adopt an unknown successor as our own,
            // because Codex's persisted turn record exposes neither turnTrigger nor
            // clientUserMessageId and doing so could resume an unrelated user turn.
            journal.records[index].status = Self.reconciledUnacceptedStartStatus(
                sourceTurnID: record.sourceTurnID,
                latestTurnID: latest["id"]?.stringValue
            )
        }
    }

    func loadJournal() throws -> AutoResumeJournal {
        guard FileManager.default.fileExists(atPath: AppPaths.autoResumeStateFile.path) else {
            return AutoResumeJournal()
        }
        return try AccountLibrary.decoder.decode(
            AutoResumeJournal.self,
            from: Data(contentsOf: AppPaths.autoResumeStateFile)
        )
    }

    func saveJournal(_ journal: AutoResumeJournal) throws {
        try AppPaths.ensureDirectories()
        try AppPaths.writePrivateFile(AccountLibrary.encoder.encode(journal), to: AppPaths.autoResumeStateFile)
    }
}
