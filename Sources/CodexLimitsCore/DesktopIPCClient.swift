#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

public enum DesktopIPCError: LocalizedError, Sendable, Equatable {
    case socketMissing
    case insecureSocket(String)
    case connectFailed(String)
    case connectionClosed
    case invalidFrameLength(UInt32)
    case invalidResponse(String)
    case requestTimedOut(String)
    case serverError(String)

    public var errorDescription: String? {
        switch self {
        case .socketMissing:
            return "Codex Desktop IPC is not available."
        case .insecureSocket(let detail):
            return "Codex Desktop IPC failed its local security check: \(detail)"
        case .connectFailed(let detail):
            return "Could not connect to Codex Desktop IPC: \(detail)"
        case .connectionClosed:
            return "Codex Desktop IPC connection closed."
        case .invalidFrameLength(let length):
            return "Codex Desktop IPC returned an invalid frame length (\(length) bytes)."
        case .invalidResponse(let detail):
            return "Codex Desktop IPC returned an unexpected response: \(detail)"
        case .requestTimedOut(let method):
            return "Codex Desktop IPC request timed out: \(method)"
        case .serverError(let message):
            return "Codex Desktop IPC returned an error: \(message)"
        }
    }
}

public struct DesktopThreadOwner: Sendable, Equatable {
    public let clientID: String
    public let supportsUntrustedAppInput: Bool

    public init(clientID: String, supportsUntrustedAppInput: Bool) {
        self.clientID = clientID
        self.supportsUntrustedAppInput = supportsUntrustedAppInput
    }
}

public struct DesktopIPCBroadcast: Sendable, Equatable {
    public let method: String
    public let version: Int
    public let sourceClientID: String?
    public let params: JSONValue

    public init(method: String, version: Int, sourceClientID: String?, params: JSONValue) {
        self.method = method
        self.version = version
        self.sourceClientID = sourceClientID
        self.params = params
    }
}

public actor DesktopIPCClient {
    public static let maximumFrameLength: UInt32 = 256 * 1024 * 1024
    public static let ownerDiscoveryVersion = 1
    public static let followerStartTurnVersion = 2
    public static let streamStateChangedVersion = 11

    private struct PendingRequest {
        let method: String
        let continuation: CheckedContinuation<JSONValue, Error>
    }

    private struct BroadcastWaiter {
        let id: UUID
        let method: String
        let continuation: CheckedContinuation<DesktopIPCBroadcast, Error>
    }

    private let socketURL: URL
    private let enforceProductionSecurity: Bool
    private var socketHandle: FileHandle?
    private var readContinuation: AsyncStream<Data>.Continuation?
    private var readerTask: Task<Void, Never>?
    private var readBuffer = Data()
    private var expectedFrameLength: Int?
    private var clientID: String?
    private var pendingRequests: [String: PendingRequest] = [:]
    private var broadcastWaiters: [UUID: BroadcastWaiter] = [:]
    private var recentBroadcasts: [DesktopIPCBroadcast] = []
    private var followedThreads: [String: String] = [:]
    private var isClosed = false

    public init(
        socketURL: URL = AppPaths.mainCodexHome
            .appendingPathComponent("ipc", isDirectory: true)
            .appendingPathComponent("ipc.sock", isDirectory: false),
        enforceProductionSecurity: Bool = true
    ) {
        self.socketURL = socketURL
        self.enforceProductionSecurity = enforceProductionSecurity
    }

    public func connect(timeoutSeconds: UInt64 = 5) async throws {
        guard socketHandle == nil else { return }
        isClosed = false
        let descriptor = try Self.openSocket(at: socketURL, enforceProductionSecurity: enforceProductionSecurity)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let stream = AsyncStream<Data>(bufferingPolicy: .unbounded) { continuation in
            self.readContinuation = continuation
        }
        handle.readabilityHandler = { [continuation = readContinuation] readable in
            let data = readable.availableData
            if data.isEmpty {
                continuation?.finish()
            } else {
                continuation?.yield(data)
            }
        }
        socketHandle = handle
        readerTask = Task { [weak self] in
            for await data in stream {
                guard !Task.isCancelled else { return }
                await self?.ingest(data)
            }
            await self?.connectionEnded()
        }

        let response = try await request(
            method: "initialize",
            version: 0,
            params: .object(["clientType": .string("codex-limits")]),
            sourceClientID: "initializing-client",
            timeoutSeconds: timeoutSeconds
        )
        guard response["resultType"]?.stringValue == "success",
              response["method"]?.stringValue == "initialize",
              let assignedID = response["result"]?["clientId"]?.stringValue,
              !assignedID.isEmpty
        else {
            close()
            throw DesktopIPCError.invalidResponse("initialize")
        }
        clientID = assignedID
    }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        socketHandle?.readabilityHandler = nil
        readContinuation?.finish()
        readerTask?.cancel()
        try? socketHandle?.close()
        socketHandle = nil
        readContinuation = nil
        readerTask = nil
        clientID = nil
        followedThreads.removeAll()
        failOutstanding(with: DesktopIPCError.connectionClosed)
    }

    public func discoverThreadOwner(threadID: String, timeoutSeconds: UInt64 = 12) async throws -> DesktopThreadOwner? {
        guard let clientID else {
            throw DesktopIPCError.invalidResponse("client is not initialized")
        }
        let response = try await request(
            method: "thread-owner-discovery",
            version: Self.ownerDiscoveryVersion,
            params: .object([
                "hostId": .string("local"),
                "conversationId": .string(threadID),
            ]),
            sourceClientID: clientID,
            timeoutSeconds: timeoutSeconds
        )
        if response["resultType"]?.stringValue == "error" {
            if response["error"]?.stringValue == "no-client-found" { return nil }
            throw DesktopIPCError.serverError(response["error"]?.stringValue ?? "thread-owner-discovery failed")
        }
        guard response["resultType"]?.stringValue == "success",
              response["method"]?.stringValue == "thread-owner-discovery",
              let ownerID = response["handledByClientId"]?.stringValue,
              !ownerID.isEmpty
        else {
            throw DesktopIPCError.invalidResponse("thread-owner-discovery")
        }
        return DesktopThreadOwner(
            clientID: ownerID,
            supportsUntrustedAppInput: response["result"]?["supportsUntrustedAppInput"]?.boolValue == true
        )
    }

    public func followThread(threadID: String, ownerClientID: String) async throws {
        followedThreads[threadID] = ownerClientID
        do {
            try sendFollowingChanged(threadID: threadID, ownerClientID: ownerClientID, following: true)
        } catch {
            followedThreads.removeValue(forKey: threadID)
            throw error
        }
    }

    public func unfollowThread(threadID: String, ownerClientID: String) async throws {
        try sendFollowingChanged(threadID: threadID, ownerClientID: ownerClientID, following: false)
        if followedThreads[threadID] == ownerClientID {
            followedThreads.removeValue(forKey: threadID)
        }
    }

    public func startEmptyContinuation(
        threadID: String,
        ownerClientID: String,
        timeoutSeconds: UInt64 = 60
    ) async throws -> String {
        guard let clientID else {
            throw DesktopIPCError.invalidResponse("client is not initialized")
        }
        let response = try await request(
            method: "thread-follower-start-turn",
            version: Self.followerStartTurnVersion,
            params: Self.followerStartTurnParams(threadID: threadID),
            sourceClientID: clientID,
            targetClientID: ownerClientID,
            timeoutSeconds: timeoutSeconds
        )
        if response["resultType"]?.stringValue == "error" {
            throw DesktopIPCError.serverError(response["error"]?.stringValue ?? "thread-follower-start-turn failed")
        }
        guard response["resultType"]?.stringValue == "success",
              response["method"]?.stringValue == "thread-follower-start-turn",
              response["handledByClientId"]?.stringValue == ownerClientID
        else {
            throw DesktopIPCError.invalidResponse("thread-follower-start-turn envelope")
        }

        let result = response["result"]
        let turnID = result?["result"]?["turn"]?["id"]?.stringValue
        guard let turnID, !turnID.isEmpty else {
            throw DesktopIPCError.invalidResponse("thread-follower-start-turn did not return a turn id")
        }
        return turnID
    }

    static func followerStartTurnParams(threadID: String) -> JSONValue {
        .object([
            "conversationId": .string(threadID),
            "turnStart": .object([
                "request": .object([
                    "threadId": .string(threadID),
                    "input": .array([]),
                    "turnTrigger": .string("codex-limits-auto-resume"),
                ]),
                "context": .object([:]),
            ]),
        ])
    }

    static func ownerTurnOutcome(
        from broadcast: DesktopIPCBroadcast,
        threadID: String,
        turnID: String,
        ownerClientID: String? = nil
    ) -> CodexTurnOutcome? {
        guard broadcast.method == "thread-stream-state-changed",
              broadcast.version == streamStateChangedVersion,
              ownerClientID == nil || broadcast.sourceClientID == ownerClientID,
              broadcast.params["conversationId"]?.stringValue == threadID,
              broadcast.params["hostId"]?.stringValue == "local",
              broadcast.params["change"]?["type"]?.stringValue == "snapshot",
              let state = broadcast.params["change"]?["conversationState"],
              let turn = findTurnObject(in: state, turnID: turnID),
              let status = turn["status"]?.stringValue
        else { return nil }

        let normalizedStatus: String
        switch status {
        case "inProgress": normalizedStatus = "inProgress"
        case "completed": normalizedStatus = "completed"
        case "failed": normalizedStatus = "failed"
        case "interrupted": normalizedStatus = "interrupted"
        default: return nil
        }

        let error = turn["error"]
        let errorInfo = error?["codexErrorInfo"]?.codexErrorCode
            ?? error?["codex_error_info"]?.stringValue
            ?? turn["codexErrorInfo"]?.codexErrorCode
            ?? turn["codex_error_info"]?.stringValue
        let errorMessage = error?["message"]?.stringValue
            ?? turn["errorMessage"]?.stringValue
        return CodexTurnOutcome(
            id: turnID,
            status: normalizedStatus,
            errorInfo: errorInfo,
            errorMessage: errorMessage
        )
    }

    static func requestEnvelope(
        method: String,
        version: Int,
        params: JSONValue,
        sourceClientID: String,
        targetClientID: String? = nil,
        timeoutSeconds: UInt64
    ) -> JSONValue {
        var object: [String: JSONValue] = [
            "type": .string("request"),
            "requestId": .string("testable-request-id"),
            "sourceClientId": .string(sourceClientID),
            "version": .number(Double(version)),
            "method": .string(method),
            "params": params,
            "timeoutMs": .number(Double(timeoutSeconds * 1_000)),
        ]
        if let targetClientID { object["targetClientId"] = .string(targetClientID) }
        return .object(object)
    }

    public func nextBroadcast(
        method: String,
        timeoutSeconds: UInt64 = 30
    ) async throws -> DesktopIPCBroadcast {
        if let index = recentBroadcasts.firstIndex(where: { $0.method == method }) {
            return recentBroadcasts.remove(at: index)
        }
        let waiterID = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            broadcastWaiters[waiterID] = BroadcastWaiter(
                id: waiterID,
                method: method,
                continuation: continuation
            )
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                await self?.timeoutBroadcast(waiterID: waiterID, method: method)
            }
        }
    }

    public func waitForThreadSnapshot(
        threadID: String,
        ownerClientID: String,
        minimumRevisionExclusive: Int? = nil,
        timeoutSeconds: UInt64 = 15
    ) async throws -> DesktopIPCBroadcast {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while Date() < deadline {
            let remaining = max(1, UInt64(deadline.timeIntervalSinceNow.rounded(.up)))
            let broadcast = try await nextBroadcast(
                method: "thread-stream-state-changed",
                timeoutSeconds: remaining
            )
            guard broadcast.version == Self.streamStateChangedVersion,
                  broadcast.sourceClientID == ownerClientID,
                  broadcast.params["conversationId"]?.stringValue == threadID,
                  broadcast.params["hostId"]?.stringValue == "local",
                  broadcast.params["change"]?["type"]?.stringValue == "snapshot"
            else { continue }
            if let minimumRevisionExclusive,
               (broadcast.params["change"]?["revision"]?.intValue ?? -1) <= minimumRevisionExclusive {
                continue
            }
            return broadcast
        }
        throw DesktopIPCError.requestTimedOut("thread-stream-state-changed snapshot")
    }

    static func framedPayload(_ value: JSONValue) throws -> Data {
        let payload = try JSONEncoder().encode(value)
        guard !payload.isEmpty, payload.count <= Int(Self.maximumFrameLength) else {
            throw DesktopIPCError.invalidFrameLength(UInt32(clamping: payload.count))
        }
        var length = UInt32(payload.count).littleEndian
        var frame = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        frame.append(payload)
        return frame
    }

    static func decodeFrames(buffer: inout Data, expectedLength: inout Int?) throws -> [JSONValue] {
        var values: [JSONValue] = []
        while true {
            if expectedLength == nil {
                guard buffer.count >= 4 else { break }
                let length = buffer.prefix(4).withUnsafeBytes { raw -> UInt32 in
                    raw.loadUnaligned(as: UInt32.self).littleEndian
                }
                buffer.removeFirst(4)
                guard length > 0, length <= Self.maximumFrameLength else {
                    throw DesktopIPCError.invalidFrameLength(length)
                }
                expectedLength = Int(length)
            }
            guard let length = expectedLength, buffer.count >= length else { break }
            let payload = Data(buffer.prefix(length))
            buffer.removeFirst(length)
            expectedLength = nil
            values.append(try JSONDecoder().decode(JSONValue.self, from: payload))
        }
        return values
    }

    private func request(
        method: String,
        version: Int,
        params: JSONValue,
        sourceClientID: String,
        targetClientID: String? = nil,
        timeoutSeconds: UInt64
    ) async throws -> JSONValue {
        guard let handle = socketHandle, !isClosed else { throw DesktopIPCError.connectionClosed }
        let requestID = UUID().uuidString.lowercased()
        guard case .object(var object) = Self.requestEnvelope(
            method: method,
            version: version,
            params: params,
            sourceClientID: sourceClientID,
            targetClientID: targetClientID,
            timeoutSeconds: timeoutSeconds
        ) else {
            throw DesktopIPCError.invalidResponse("could not build request envelope")
        }
        object["requestId"] = .string(requestID)
        let frame = try Self.framedPayload(.object(object))

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[requestID] = PendingRequest(method: method, continuation: continuation)
            do {
                try handle.write(contentsOf: frame)
            } catch {
                pendingRequests.removeValue(forKey: requestID)
                continuation.resume(throwing: DesktopIPCError.connectFailed(error.localizedDescription))
                return
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                await self?.timeoutRequest(requestID: requestID, method: method)
            }
        }
    }

    private func sendBroadcast(
        method: String,
        version: Int,
        params: JSONValue,
        targetClientIDs: [String]? = nil
    ) throws {
        guard let handle = socketHandle, let clientID, !isClosed else {
            throw DesktopIPCError.connectionClosed
        }
        var object: [String: JSONValue] = [
            "type": .string("broadcast"),
            "method": .string(method),
            "sourceClientId": .string(clientID),
            "version": .number(Double(version)),
            "params": params,
        ]
        if let targetClientIDs {
            object["targetClientIds"] = .array(targetClientIDs.map(JSONValue.string))
        }
        let frame = try Self.framedPayload(.object(object))
        do {
            try handle.write(contentsOf: frame)
        } catch {
            throw DesktopIPCError.connectFailed(error.localizedDescription)
        }
    }

    private func ingest(_ data: Data) {
        guard !data.isEmpty, !isClosed else { return }
        readBuffer.append(data)
        do {
            let messages = try Self.decodeFrames(buffer: &readBuffer, expectedLength: &expectedFrameLength)
            for message in messages { handleMessage(message) }
        } catch {
            closeWithError(error)
        }
    }

    private func handleMessage(_ message: JSONValue) {
        switch message["type"]?.stringValue {
        case "response":
            guard let requestID = message["requestId"]?.stringValue,
                  let pending = pendingRequests.removeValue(forKey: requestID)
            else { return }
            pending.continuation.resume(returning: message)
        case "broadcast":
            guard let method = message["method"]?.stringValue else { return }
            let broadcast = DesktopIPCBroadcast(
                method: method,
                version: message["version"]?.intValue ?? 0,
                sourceClientID: message["sourceClientId"]?.stringValue,
                params: message["params"] ?? .null
            )
            if method == "thread-stream-following-status-requested",
               broadcast.version == 1,
               broadcast.params["hostId"]?.stringValue == "local",
               let threadID = broadcast.params["conversationId"]?.stringValue,
               let ownerClientID = followedThreads[threadID],
               broadcast.sourceClientID == ownerClientID {
                try? sendFollowingChanged(
                    threadID: threadID,
                    ownerClientID: ownerClientID,
                    following: true
                )
                return
            }
            if let waiter = broadcastWaiters.values.first(where: { $0.method == method }) {
                broadcastWaiters.removeValue(forKey: waiter.id)
                waiter.continuation.resume(returning: broadcast)
            } else {
                recentBroadcasts.append(broadcast)
                if recentBroadcasts.count > 128 {
                    recentBroadcasts.removeFirst(recentBroadcasts.count - 128)
                }
            }
        default:
            break
        }
    }

    private func timeoutRequest(requestID: String, method: String) {
        guard let pending = pendingRequests.removeValue(forKey: requestID) else { return }
        pending.continuation.resume(throwing: DesktopIPCError.requestTimedOut(method))
    }

    private func timeoutBroadcast(waiterID: UUID, method: String) {
        guard let waiter = broadcastWaiters.removeValue(forKey: waiterID) else { return }
        waiter.continuation.resume(throwing: DesktopIPCError.requestTimedOut(method))
    }

    private func connectionEnded() {
        guard !isClosed else { return }
        closeWithError(DesktopIPCError.connectionClosed)
    }

    private func closeWithError(_ error: Error) {
        isClosed = true
        socketHandle?.readabilityHandler = nil
        readContinuation?.finish()
        readerTask?.cancel()
        try? socketHandle?.close()
        socketHandle = nil
        readContinuation = nil
        readerTask = nil
        clientID = nil
        followedThreads.removeAll()
        failOutstanding(with: error)
    }

    private func failOutstanding(with error: Error) {
        let requests = pendingRequests.values
        pendingRequests.removeAll()
        for pending in requests { pending.continuation.resume(throwing: error) }
        let waiters = broadcastWaiters.values
        broadcastWaiters.removeAll()
        for waiter in waiters { waiter.continuation.resume(throwing: error) }
    }

    #if os(Windows)
    private static func openSocket(at socketURL: URL, enforceProductionSecurity: Bool) throws -> Int32 {
        // Codex Desktop's IPC endpoint is a Unix socket, so there is nothing to join here.
        throw DesktopIPCError.socketMissing
    }
    #else
    private static func openSocket(at socketURL: URL, enforceProductionSecurity: Bool) throws -> Int32 {
        if enforceProductionSecurity {
            try validateProductionSocket(at: socketURL)
        }
        #if canImport(Glibc)
        let descriptor = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        #endif
        guard descriptor >= 0 else {
            throw DesktopIPCError.connectFailed(posixErrorDescription())
        }
        do {
            try connect(descriptor: descriptor, to: socketURL.path)
        } catch {
            closeDescriptor(descriptor)
            throw error
        }
        return descriptor
    }

    private static func validateProductionSocket(at socketURL: URL) throws {
        var socketStat = stat()
        guard lstat(socketURL.path, &socketStat) == 0 else {
            if errno == ENOENT { throw DesktopIPCError.socketMissing }
            throw DesktopIPCError.insecureSocket(posixErrorDescription())
        }
        guard (socketStat.st_mode & S_IFMT) == S_IFSOCK else {
            throw DesktopIPCError.insecureSocket("endpoint is not a Unix socket")
        }
        let uid = geteuid()
        guard socketStat.st_uid == uid else {
            throw DesktopIPCError.insecureSocket("socket is owned by another user")
        }
        guard (socketStat.st_mode & 0o077) == 0 else {
            throw DesktopIPCError.insecureSocket("socket permissions are broader than 0600")
        }

        var directoryStat = stat()
        let directory = socketURL.deletingLastPathComponent().path
        guard lstat(directory, &directoryStat) == 0,
              (directoryStat.st_mode & S_IFMT) == S_IFDIR,
              directoryStat.st_uid == uid,
              (directoryStat.st_mode & 0o077) == 0
        else {
            throw DesktopIPCError.insecureSocket("IPC directory is not private to the current user")
        }
    }

    private static func connect(descriptor: Int32, to path: String) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count <= capacity else {
            throw DesktopIPCError.connectFailed("socket path is too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.initializeMemory(as: UInt8.self, repeating: 0)
            raw.copyBytes(from: bytes)
        }
        let result = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                #if canImport(Glibc)
                Glibc.connect(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
                #else
                Darwin.connect(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
                #endif
            }
        }
        guard result == 0 else {
            throw DesktopIPCError.connectFailed(posixErrorDescription())
        }
    }

    private static func closeDescriptor(_ descriptor: Int32) {
        #if canImport(Glibc)
        _ = Glibc.close(descriptor)
        #else
        _ = Darwin.close(descriptor)
        #endif
    }

    private static func posixErrorDescription() -> String {
        String(cString: strerror(errno))
    }
    #endif

    private func sendFollowingChanged(threadID: String, ownerClientID: String, following: Bool) throws {
        try sendBroadcast(
            method: "thread-stream-following-changed",
            version: 1,
            params: .object([
                "conversationId": .string(threadID),
                "hostId": .string("local"),
                "following": .bool(following),
            ]),
            targetClientIDs: [ownerClientID]
        )
    }

    private static func findTurnObject(in state: JSONValue, turnID: String) -> [String: JSONValue]? {
        if let turns = state["turns"]?.arrayValue {
            for turn in turns.compactMap(\.objectValue) {
                if turn["turnId"]?.stringValue == turnID { return turn }
            }
        }
        if let entities = state["turnHistory"]?["history"]?["entitiesByKey"]?.objectValue {
            for turn in entities.values.compactMap(\.objectValue) {
                if turn["turnId"]?.stringValue == turnID { return turn }
            }
        }
        return nil
    }
}
