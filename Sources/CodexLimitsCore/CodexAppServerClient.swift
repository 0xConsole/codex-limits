import Foundation

public enum CodexClientError: LocalizedError, Sendable {
    case codexNotFound
    case processLaunch(String)
    case processExited(Int32)
    case requestTimedOut(String)
    case protocolError(String)
    case serverError(String)
    case loginFailed(String)
    case reauthenticationRequired

    public var errorDescription: String? {
        switch self {
        case .codexNotFound:
            return "Codex CLI was not found. Install Codex or set CODEX_LIMITS_CODEX_PATH."
        case .processLaunch(let message):
            return "Could not start Codex: \(message)"
        case .processExited(let status):
            return "Codex app-server exited with status \(status)."
        case .requestTimedOut(let method):
            return "Codex request timed out: \(method)"
        case .protocolError(let message):
            return "Codex protocol error: \(message)"
        case .serverError(let message):
            return "Codex returned an error: \(message)"
        case .loginFailed(let message):
            return message
        case .reauthenticationRequired:
            return "This Codex login has expired. Sign in again to resume live limit updates."
        }
    }

    /// The saved login is unusable until the account signs in again.
    public var requiresSignIn: Bool {
        switch self {
        case .reauthenticationRequired, .loginFailed:
            return true
        default:
            return false
        }
    }
}

private struct CodexEnvelope: Decodable, Sendable {
    let id: Int?
    let method: String?
    let result: JSONValue?
    let params: JSONValue?
    let error: JSONValue?
}

private struct CodexRequest: Encodable, Sendable {
    let method: String
    let id: Int
    let params: JSONValue
}

private struct CodexServerErrorResponse: Encodable, Sendable {
    struct ErrorBody: Encodable, Sendable {
        let code: Int
        let message: String
    }

    let id: Int
    let error: ErrorBody
}

public actor CodexAppServerClient {
    private let homeURL: URL
    private let executableURL: URL
    private let experimentalAPI: Bool
    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputHandle: FileHandle?
    private var errorHandle: FileHandle?
    private var outputReaderTask: Task<Void, Never>?
    private var outputStreamContinuation: AsyncStream<Data>.Continuation?
    private var readBuffer = Data()
    private var nextRequestID = 1
    private var pendingRequests: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var requestMethods: [Int: String] = [:]
    private var loginWaiters: [String: CheckedContinuation<LoginCompletion, Error>] = [:]
    private var completedLogins: [String: LoginCompletion] = [:]
    private var turnWaiters: [String: CheckedContinuation<CodexTurnOutcome, Error>] = [:]
    private var completedTurns: [String: CodexTurnOutcome] = [:]
    private var isStopping = false

    public init(
        homeURL: URL,
        executableURL: URL? = CodexLocator.locate(),
        experimentalAPI: Bool = false
    ) throws {
        guard let executableURL else { throw CodexClientError.codexNotFound }
        self.homeURL = homeURL
        self.executableURL = executableURL
        self.experimentalAPI = experimentalAPI
    }

    public func start() async throws {
        guard process == nil else { return }

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let process = Process()
        let command = CodexLocator.launchCommand(for: executableURL, arguments: ["app-server", "--stdio"])
        process.executableURL = command.executable
        process.arguments = command.arguments
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = homeURL.nativePath
        process.environment = environment
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let outputHandle = outputPipe.fileHandleForReading
        let errorHandle = errorPipe.fileHandleForReading
        let outputStream = AsyncStream<Data>(bufferingPolicy: .unbounded) { continuation in
            self.outputStreamContinuation = continuation
        }

        outputHandle.readabilityHandler = { [continuation = outputStreamContinuation] handle in
            let data = handle.availableData
            if data.isEmpty {
                continuation?.finish()
            } else {
                continuation?.yield(data)
            }
        }
        errorHandle.readabilityHandler = { handle in
            _ = handle.availableData
        }

        process.terminationHandler = { [weak self] terminated in
            Task { await self?.handleTermination(status: terminated.terminationStatus) }
        }

        do {
            try process.run()
        } catch {
            throw CodexClientError.processLaunch(error.localizedDescription)
        }

        self.process = process
        self.inputHandle = inputPipe.fileHandleForWriting
        self.outputHandle = outputHandle
        self.errorHandle = errorHandle

        // FileHandle.readabilityHandler may fire again before an actor hop from the
        // previous callback has executed. Spawning one Task per callback can therefore
        // reorder chunks from large JSONL responses. Feed one AsyncStream and let a
        // single actor task consume it in FIFO order.
        outputReaderTask = Task { [weak self] in
            for await data in outputStream {
                guard !Task.isCancelled else { return }
                await self?.ingest(data)
            }
        }

        let capabilities: JSONValue = experimentalAPI
            ? .object(["experimentalApi": .bool(true)])
            : .null
        let initializeParams: JSONValue = .object([
            "clientInfo": .object([
                "name": .string("codex-limit-checker"),
                "title": .string("Codex Limits"),
                "version": .string(CodexLimitsVersion.current),
            ]),
            "capabilities": capabilities,
        ])
        _ = try await request(method: "initialize", params: initializeParams)
    }

    public func stop() {
        isStopping = true
        outputHandle?.readabilityHandler = nil
        errorHandle?.readabilityHandler = nil
        outputStreamContinuation?.finish()
        outputReaderTask?.cancel()
        try? inputHandle?.close()
        if process?.isRunning == true {
            process?.terminate()
        }
        failOutstanding(with: CodexClientError.processExited(0))
        process = nil
        inputHandle = nil
        outputHandle = nil
        errorHandle = nil
        outputReaderTask = nil
        outputStreamContinuation = nil
    }

    public func startChatGPTLogin() async throws -> LoginTicket {
        let result = try await request(
            method: "account/login/start",
            params: .object([
                "type": .string("chatgpt"),
                "codexStreamlinedLogin": .bool(true),
                "useHostedLoginSuccessPage": .bool(true),
            ])
        )
        guard
            let object = result.objectValue,
            object["type"]?.stringValue == "chatgpt",
            let loginID = object["loginId"]?.stringValue,
            let urlString = object["authUrl"]?.stringValue,
            let url = URL(string: urlString)
        else {
            throw CodexClientError.protocolError("login response did not contain loginId/authUrl")
        }
        return LoginTicket(loginID: loginID, authorizationURL: url)
    }

    public func cancelLogin(loginID: String) async {
        _ = try? await request(
            method: "account/login/cancel",
            params: .object(["loginId": .string(loginID)])
        )
    }

    public func waitForLoginCompletion(loginID: String) async throws -> LoginCompletion {
        if let completion = completedLogins.removeValue(forKey: loginID) {
            return completion
        }
        return try await withCheckedThrowingContinuation { continuation in
            loginWaiters[loginID] = continuation
        }
    }

    public func fetchAccountSnapshot(refreshToken: Bool = false) async throws -> AccountSnapshot {
        let accountResult = try await request(
            method: "account/read",
            params: .object(["refreshToken": .bool(refreshToken)])
        )
        guard
            let account = accountResult["account"]?.objectValue,
            account["type"]?.stringValue == "chatgpt"
        else {
            throw CodexClientError.reauthenticationRequired
        }
        let email = account["email"]?.stringValue ?? "Unknown account"
        let accountPlan = account["planType"]?.stringValue ?? "unknown"

        let limitsResult = try await request(
            method: "account/rateLimits/read",
            params: .object([
                "excludeResetCreditDetails": .bool(true),
                "supportsLunaReserve": .bool(false),
            ])
        )
        guard let snapshotObject = preferredRateLimitSnapshot(from: limitsResult) else {
            throw CodexClientError.protocolError("rate limit response did not contain a Codex snapshot")
        }

        let primary = parseWindow(snapshotObject["primary"])
        let secondary = parseWindow(snapshotObject["secondary"])
        let windows = [primary, secondary].compactMap { $0 }
        let fiveHour = windows.first(where: { $0.windowDurationMinutes == 300 })
        let weekly = windows.first(where: { $0.windowDurationMinutes == 10_080 })
        let usage = UsageSnapshot(
            fiveHour: fiveHour,
            weekly: weekly,
            ordinaryUsageAllowed: limitsResult["ordinaryUsageAllowed"]?.boolValue,
            rateLimitReachedType: snapshotObject["rateLimitReachedType"]?.stringValue
        )

        return AccountSnapshot(
            email: email,
            planType: snapshotObject["planType"]?.stringValue ?? accountPlan,
            accountID: limitsResult["accountId"]?.stringValue,
            usage: usage
        )
    }

    public func listThreadsPage(limit: Int = 100, cursor: String? = nil) async throws -> (threads: [JSONValue], nextCursor: String?) {
        var params: [String: JSONValue] = [
            "limit": .number(Double(limit)),
            "archived": .bool(false),
            "sortKey": .string("updated_at"),
            "sortDirection": .string("desc"),
        ]
        if let cursor {
            params["cursor"] = .string(cursor)
        }
        let result = try await request(
            method: "thread/list",
            params: .object(params)
        )
        return (
            threads: result["data"]?.arrayValue ?? [],
            nextCursor: result["nextCursor"]?.stringValue
        )
    }

    public func latestTurn(threadID: String) async throws -> JSONValue? {
        let result = try await request(
            method: "thread/turns/list",
            params: .object([
                "threadId": .string(threadID),
                "limit": .number(1),
                "sortDirection": .string("desc"),
                "itemsView": .string("notLoaded"),
            ])
        )
        return result["data"]?.arrayValue?.first
    }

    public func readThread(threadID: String, includeTurns: Bool = true) async throws -> JSONValue {
        let result = try await request(
            method: "thread/read",
            params: .object([
                "threadId": .string(threadID),
                "includeTurns": .bool(includeTurns),
            ])
        )
        return result["thread"] ?? result
    }

    public func resumeThread(threadID: String, includeTurns: Bool = true) async throws -> JSONValue {
        let result = try await request(
            method: "thread/resume",
            params: .object([
                "threadId": .string(threadID),
                "excludeTurns": .bool(!includeTurns),
            ])
        )
        return result["thread"] ?? result
    }

    /// The conversation's goal, or nil when it has none.
    public func threadGoal(threadID: String) async throws -> JSONValue? {
        let result = try await request(
            method: "thread/goal/get",
            params: .object(["threadId": .string(threadID)])
        )
        guard let goal = result["goal"], goal.objectValue != nil else { return nil }
        return goal
    }

    public func setThreadGoalStatus(threadID: String, status: String) async throws {
        _ = try await request(
            method: "thread/goal/set",
            params: .object([
                "threadId": .string(threadID),
                "status": .string(status),
            ])
        )
    }

    public func startTurn(
        threadID: String,
        input: [JSONValue],
        clientUserMessageID: String? = nil
    ) async throws -> String {
        var params: [String: JSONValue] = [
            "threadId": .string(threadID),
            "input": .array(input),
            "turnTrigger": .string("codex-limits-auto-resume"),
        ]
        if let clientUserMessageID {
            params["clientUserMessageId"] = .string(clientUserMessageID)
        }
        let result = try await request(
            method: "turn/start",
            params: .object(params),
            timeoutSeconds: 60
        )
        guard let turnID = result["turn"]?["id"]?.stringValue else {
            throw CodexClientError.protocolError("turn/start did not return a turn id")
        }
        return turnID
    }

    public func waitForTurnCompletion(turnID: String, timeoutSeconds: UInt64 = 7_200) async throws -> CodexTurnOutcome {
        if let outcome = completedTurns.removeValue(forKey: turnID) {
            return outcome
        }
        return try await withCheckedThrowingContinuation { continuation in
            turnWaiters[turnID] = continuation
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                await self?.timeoutTurn(turnID: turnID)
            }
        }
    }

    public func waitForTurnCompletion(
        threadID: String,
        turnID: String,
        timeoutSeconds: UInt64 = 7_200,
        pollIntervalSeconds: UInt64 = 5
    ) async throws -> CodexTurnOutcome {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        let pollInterval = max(1, pollIntervalSeconds)

        while Date() < deadline {
            if let outcome = completedTurns.removeValue(forKey: turnID) {
                return outcome
            }

            // Codex 0.154 reconstructs an unfinished persisted turn as `interrupted`
            // even while that same turn is still actively running in this app-server.
            // The live Thread.status is authoritative while the thread is loaded; only
            // consult persisted turn history after the runtime is no longer active.
            let runtimeStatus = try await runtimeThreadStatusType(threadID: threadID)
            if runtimeStatus != "active",
               let outcome = try await durableTurnOutcome(threadID: threadID, turnID: turnID) {
                return outcome
            }

            let remaining = max(1, UInt64(deadline.timeIntervalSinceNow.rounded(.up)))
            do {
                return try await waitForTurnCompletion(
                    turnID: turnID,
                    timeoutSeconds: min(pollInterval, remaining)
                )
            } catch let error as CodexClientError {
                guard case .requestTimedOut("turn/completed") = error else { throw error }
            }
        }

        throw CodexClientError.requestTimedOut("turn/completed")
    }

    private func runtimeThreadStatusType(threadID: String) async throws -> String? {
        let thread = try await readThread(threadID: threadID, includeTurns: false)
        return thread["status"]?["type"]?.stringValue
    }

    private func durableTurnOutcome(threadID: String, turnID: String) async throws -> CodexTurnOutcome? {
        let result = try await request(
            method: "thread/turns/list",
            params: .object([
                "threadId": .string(threadID),
                "limit": .number(20),
                "sortDirection": .string("desc"),
                "itemsView": .string("notLoaded"),
            ])
        )
        guard let turn = result["data"]?.arrayValue?.first(where: {
            $0["id"]?.stringValue == turnID
        }),
        let status = turn["status"]?.stringValue,
        status != "inProgress"
        else { return nil }

        let error = turn["error"]?.objectValue
        return CodexTurnOutcome(
            id: turnID,
            status: status,
            errorInfo: error?["codexErrorInfo"]?.codexErrorCode,
            errorMessage: error?["message"]?.stringValue
        )
    }

    public func usageLimitedCandidate(thread: JSONValue, latestTurn: JSONValue) -> AutoResumeCandidate? {
        guard let threadID = thread["id"]?.stringValue,
              latestTurn["status"]?.stringValue == "failed",
              latestTurn["error"]?["codexErrorInfo"]?.codexErrorCode == "usageLimitExceeded",
              let failedTurnID = latestTurn["id"]?.stringValue
        else { return nil }

        let updatedAt = thread["updatedAt"]?.doubleValue.map(Date.init(timeIntervalSince1970:))
        return AutoResumeCandidate(
            sourceThreadID: threadID,
            failedTurnID: failedTurnID,
            updatedAt: updatedAt
        )
    }

    private func request(method: String, params: JSONValue, timeoutSeconds: UInt64 = 20) async throws -> JSONValue {
        guard let process, process.isRunning, let inputHandle else {
            throw CodexClientError.processExited(process?.terminationStatus ?? -1)
        }

        let id = nextRequestID
        nextRequestID += 1
        let request = CodexRequest(method: method, id: id, params: params)
        let encoded: Data
        do {
            encoded = try JSONEncoder().encode(request) + Data([0x0A])
        } catch {
            throw CodexClientError.protocolError(error.localizedDescription)
        }

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[id] = continuation
            requestMethods[id] = method
            do {
                try inputHandle.write(contentsOf: encoded)
            } catch {
                pendingRequests.removeValue(forKey: id)
                requestMethods.removeValue(forKey: id)
                continuation.resume(throwing: error)
                return
            }

            Task { [weak self] in
                try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                await self?.timeoutRequest(id: id, method: method)
            }
        }
    }

    private func timeoutRequest(id: Int, method: String) {
        guard let continuation = pendingRequests.removeValue(forKey: id) else { return }
        requestMethods.removeValue(forKey: id)
        continuation.resume(throwing: CodexClientError.requestTimedOut(method))
    }

    private func timeoutTurn(turnID: String) {
        guard let continuation = turnWaiters.removeValue(forKey: turnID) else { return }
        continuation.resume(throwing: CodexClientError.requestTimedOut("turn/completed"))
    }

    private func ingest(_ data: Data) {
        readBuffer.append(data)
        while let newline = readBuffer.firstIndex(of: 0x0A) {
            let line = readBuffer[..<newline]
            readBuffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            do {
                let envelope = try JSONDecoder().decode(CodexEnvelope.self, from: Data(line))
                handle(envelope)
            } catch {
                // Ignore non-protocol noise and keep the server available for later responses.
            }
        }
    }

    private func handle(_ envelope: CodexEnvelope) {
        if let id = envelope.id, let method = envelope.method {
            let params = envelope.params
            Task { [weak self] in
                await self?.handleServerRequest(id: id, method: method, params: params)
            }
            return
        }

        if let id = envelope.id, let continuation = pendingRequests.removeValue(forKey: id) {
            requestMethods.removeValue(forKey: id)
            if let error = envelope.error {
                continuation.resume(
                    throwing: CodexClientError.serverError(
                        error["message"]?.stringValue ?? error.compactDescription
                    )
                )
            } else {
                continuation.resume(returning: envelope.result ?? .null)
            }
            return
        }

        if envelope.method == "turn/completed",
           let turn = envelope.params?["turn"]?.objectValue,
           let turnID = turn["id"]?.stringValue,
           let status = turn["status"]?.stringValue {
            let error = turn["error"]?.objectValue
            let outcome = CodexTurnOutcome(
                id: turnID,
                status: status,
                errorInfo: error?["codexErrorInfo"]?.codexErrorCode,
                errorMessage: error?["message"]?.stringValue
            )
            if let continuation = turnWaiters.removeValue(forKey: turnID) {
                continuation.resume(returning: outcome)
            } else {
                completedTurns[turnID] = outcome
            }
            return
        }

        guard envelope.method == "account/login/completed", let params = envelope.params?.objectValue else {
            return
        }
        let completion = LoginCompletion(
            loginID: params["loginId"]?.stringValue,
            success: params["success"]?.boolValue ?? false,
            error: params["error"]?.stringValue
        )
        if let loginID = completion.loginID {
            if let continuation = loginWaiters.removeValue(forKey: loginID) {
                continuation.resume(returning: completion)
            } else {
                completedLogins[loginID] = completion
            }
        }
    }

    /// Codex asks its client for approvals or input during a turn. Nobody is there to
    /// answer during Auto Resume, so the turn stops instead of hanging.
    private func handleServerRequest(id: Int, method: String, params: JSONValue?) async {
        let error = CodexClientError.protocolError(
            "Auto Resume stopped because Codex requested interactive input (\(method))."
        )
        try? sendServerError(id: id, message: error.localizedDescription)
        failTurnWaiters(with: error)
    }

    private func sendServerError(id: Int, message: String) throws {
        guard let process, process.isRunning, let inputHandle else {
            throw CodexClientError.processExited(process?.terminationStatus ?? -1)
        }
        let response = CodexServerErrorResponse(
            id: id,
            error: .init(code: -32_000, message: message)
        )
        let encoded = try JSONEncoder().encode(response) + Data([0x0A])
        try inputHandle.write(contentsOf: encoded)
    }

    private func handleTermination(status: Int32) {
        guard !isStopping else { return }
        failOutstanding(with: CodexClientError.processExited(status))
    }

    private func failOutstanding(with error: Error) {
        let requests = pendingRequests.values
        pendingRequests.removeAll()
        requestMethods.removeAll()
        for continuation in requests {
            continuation.resume(throwing: error)
        }

        let waiters = loginWaiters.values
        loginWaiters.removeAll()
        for continuation in waiters {
            continuation.resume(throwing: error)
        }
        failTurnWaiters(with: error)
    }

    private func failTurnWaiters(with error: Error) {
        let waiters = turnWaiters.values
        turnWaiters.removeAll()
        for continuation in waiters {
            continuation.resume(throwing: error)
        }
    }

    private func preferredRateLimitSnapshot(from result: JSONValue) -> [String: JSONValue]? {
        if let byID = result["rateLimitsByLimitId"]?.objectValue {
            if let codex = byID["codex"]?.objectValue {
                return codex
            }
            if let first = byID.values.compactMap(\.objectValue).first(where: { $0["limitId"]?.stringValue == "codex" }) {
                return first
            }
        }
        return result["rateLimits"]?.objectValue
    }

    private func parseWindow(_ value: JSONValue?) -> LimitWindow? {
        guard let object = value?.objectValue, let usedPercent = object["usedPercent"]?.doubleValue else {
            return nil
        }
        let resetsAt = object["resetsAt"]?.doubleValue.map(Date.init(timeIntervalSince1970:))
        return LimitWindow(
            usedPercent: usedPercent,
            windowDurationMinutes: object["windowDurationMins"]?.intValue,
            resetsAt: resetsAt
        )
    }
}
