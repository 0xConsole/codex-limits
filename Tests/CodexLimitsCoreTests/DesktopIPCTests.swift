import Foundation
import Testing
@testable import CodexLimitsCore

// These tests drive fake servers through /bin/sh, python3 and Unix sockets.
#if !os(Windows)
@Test("Desktop IPC framing preserves fragmented and coalesced messages")
func desktopIPCFraming() throws {
    let first: JSONValue = .object([
        "type": .string("response"),
        "requestId": .string("one"),
        "resultType": .string("success"),
    ])
    let second: JSONValue = .object([
        "type": .string("broadcast"),
        "method": .string("thread-stream-state-changed"),
        "version": .number(Double(DesktopIPCClient.streamStateChangedVersion)),
        "params": .object(["conversationId": .string("thread-1")]),
    ])
    let firstFrame = try DesktopIPCClient.framedPayload(first)
    let secondFrame = try DesktopIPCClient.framedPayload(second)

    var buffer = Data()
    var expectedLength: Int?
    buffer.append(firstFrame.prefix(2))
    #expect(try DesktopIPCClient.decodeFrames(buffer: &buffer, expectedLength: &expectedLength).isEmpty)
    buffer.append(firstFrame.dropFirst(2).prefix(7))
    #expect(try DesktopIPCClient.decodeFrames(buffer: &buffer, expectedLength: &expectedLength).isEmpty)
    buffer.append(firstFrame.dropFirst(9))
    buffer.append(secondFrame)
    let decoded = try DesktopIPCClient.decodeFrames(buffer: &buffer, expectedLength: &expectedLength)

    #expect(decoded == [first, second])
    #expect(buffer.isEmpty)
    #expect(expectedLength == nil)
}

@Test("Desktop IPC uses owner discovery and the minimal follower-start request")
func desktopIPCOwnerRoutingEnvelope() {
    let threadID = "thread-quota-stopped"
    let ownerID = "desktop-owner"
    let discovery = DesktopIPCClient.requestEnvelope(
        method: "thread-owner-discovery",
        version: DesktopIPCClient.ownerDiscoveryVersion,
        params: .object([
            "hostId": .string("local"),
            "conversationId": .string(threadID),
        ]),
        sourceClientID: "codex-limits-client",
        timeoutSeconds: 5
    )
    #expect(discovery["version"]?.intValue == 1)
    #expect(discovery["params"]?["hostId"]?.stringValue == "local")
    #expect(discovery["params"]?["conversationId"]?.stringValue == threadID)

    let followerParams = DesktopIPCClient.followerStartTurnParams(threadID: threadID)
    let follower = DesktopIPCClient.requestEnvelope(
        method: "thread-follower-start-turn",
        version: DesktopIPCClient.followerStartTurnVersion,
        params: followerParams,
        sourceClientID: "codex-limits-client",
        targetClientID: ownerID,
        timeoutSeconds: 60
    )
    #expect(follower["version"]?.intValue == 2)
    #expect(follower["targetClientId"]?.stringValue == ownerID)
    #expect(follower["params"]?["conversationId"]?.stringValue == threadID)
    let request = follower["params"]?["turnStart"]?["request"]
    #expect(request?["threadId"]?.stringValue == threadID)
    #expect(request?["turnTrigger"]?.stringValue == "codex-limits-auto-resume")
    #expect(request?["input"]?.arrayValue == [])
    #expect(follower["params"]?["turnStart"]?["context"]?.objectValue?.isEmpty == true)
    #expect(request?.objectValue?.count == 3)
}

@Test("Desktop owner snapshots distinguish live from terminal follower turns")
func desktopIPCOwnerSnapshotOutcome() {
    let threadID = "thread-1"
    let turnID = "turn-1"
    let ownerID = "owner-1"

    func snapshot(status: String, errorInfo: String? = nil) -> DesktopIPCBroadcast {
        var turn: [String: JSONValue] = [
            "turnId": .string(turnID),
            "status": .string(status),
        ]
        if let errorInfo {
            turn["error"] = .object([
                "codexErrorInfo": .string(errorInfo),
                "message": .string("quota terminal"),
            ])
        }
        return DesktopIPCBroadcast(
            method: "thread-stream-state-changed",
            version: DesktopIPCClient.streamStateChangedVersion,
            sourceClientID: ownerID,
            params: .object([
                "conversationId": .string(threadID),
                "hostId": .string("local"),
                "change": .object([
                    "type": .string("snapshot"),
                    "revision": .number(4),
                    "conversationState": .object([
                        "turns": .array([.object(turn)]),
                    ]),
                ]),
            ])
        )
    }

    let live = DesktopIPCClient.ownerTurnOutcome(
        from: snapshot(status: "inProgress"),
        threadID: threadID,
        turnID: turnID,
        ownerClientID: ownerID
    )
    #expect(live?.status == "inProgress")

    let failed = DesktopIPCClient.ownerTurnOutcome(
        from: snapshot(status: "failed", errorInfo: "usageLimitExceeded"),
        threadID: threadID,
        turnID: turnID,
        ownerClientID: ownerID
    )
    #expect(failed?.status == "failed")
    #expect(failed?.errorInfo == "usageLimitExceeded")

    let wrongOwner = DesktopIPCClient.ownerTurnOutcome(
        from: snapshot(status: "interrupted"),
        threadID: threadID,
        turnID: turnID,
        ownerClientID: "different-owner"
    )
    #expect(wrongOwner == nil)
}

@Test("Desktop IPC owner route performs targeted follow start reassert and completion")
func desktopIPCOwnerRouteIntegration() async throws {
    let suffix = String(UUID().uuidString.prefix(8))
    let temporary = URL(fileURLWithPath: "/tmp/clipc-\(suffix)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let socketURL = temporary.appendingPathComponent("ipc.sock")
    let serverScript = temporary.appendingPathComponent("server.py")
    let script = #"""
import json, os, socket, struct, sys

path = sys.argv[1]
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(path)
os.chmod(path, 0o600)
server.listen(1)

def read_exact(conn, count):
    data = b""
    while len(data) < count:
        chunk = conn.recv(count - len(data))
        if not chunk:
            raise RuntimeError("unexpected EOF")
        data += chunk
    return data

def read_frame(conn):
    size = struct.unpack("<I", read_exact(conn, 4))[0]
    return json.loads(read_exact(conn, size).decode("utf-8"))

def send_frame(conn, value):
    payload = json.dumps(value, separators=(",", ":")).encode("utf-8")
    conn.sendall(struct.pack("<I", len(payload)) + payload)

conn, _ = server.accept()
try:
    initialize = read_frame(conn)
    assert initialize["method"] == "initialize"
    send_frame(conn, {
        "type": "response",
        "requestId": initialize["requestId"],
        "resultType": "success",
        "method": "initialize",
        "handledByClientId": "router",
        "result": {"clientId": "codex-limits-test"},
    })

    discovery = read_frame(conn)
    assert discovery["method"] == "thread-owner-discovery"
    assert discovery["version"] == 1
    assert discovery["params"] == {"hostId": "local", "conversationId": "thread-1"}
    send_frame(conn, {
        "type": "response",
        "requestId": discovery["requestId"],
        "resultType": "success",
        "method": "thread-owner-discovery",
        "handledByClientId": "owner-1",
        "result": {"supportsUntrustedAppInput": True},
    })

    follow = read_frame(conn)
    assert follow["type"] == "broadcast"
    assert follow["method"] == "thread-stream-following-changed"
    assert follow["version"] == 1
    assert follow["targetClientIds"] == ["owner-1"]
    assert follow["params"] == {"conversationId": "thread-1", "hostId": "local", "following": True}
    send_frame(conn, {
        "type": "broadcast",
        "method": "thread-stream-state-changed",
        "version": 11,
        "sourceClientId": "owner-1",
        "params": {
            "conversationId": "thread-1",
            "hostId": "local",
            "change": {
                "type": "snapshot",
                "revision": 3,
                "conversationState": {"turns": [{"turnId": "old-turn", "status": "failed"}]},
            },
        },
    })

    start = read_frame(conn)
    assert start["method"] == "thread-follower-start-turn"
    assert start["version"] == 2
    assert start["targetClientId"] == "owner-1"
    request = start["params"]["turnStart"]["request"]
    assert request == {"threadId": "thread-1", "input": [], "turnTrigger": "codex-limits-auto-resume"}
    assert start["params"]["turnStart"]["context"] == {}
    send_frame(conn, {
        "type": "response",
        "requestId": start["requestId"],
        "resultType": "success",
        "method": "thread-follower-start-turn",
        "handledByClientId": "owner-1",
        "result": {"result": {"turn": {"id": "turn-1"}}},
    })

    send_frame(conn, {
        "type": "broadcast",
        "method": "thread-stream-following-status-requested",
        "version": 1,
        "sourceClientId": "owner-1",
        "params": {"conversationId": "thread-1", "hostId": "local"},
    })
    reassert = read_frame(conn)
    assert reassert["method"] == "thread-stream-following-changed"
    assert reassert["targetClientIds"] == ["owner-1"]
    assert reassert["params"]["following"] is True

    send_frame(conn, {
        "type": "broadcast",
        "method": "thread-stream-state-changed",
        "version": 11,
        "sourceClientId": "owner-1",
        "params": {
            "conversationId": "thread-1",
            "hostId": "local",
            "change": {
                "type": "snapshot",
                "revision": 4,
                "conversationState": {"turns": [{"turnId": "turn-1", "status": "completed"}]},
            },
        },
    })

    unfollow = read_frame(conn)
    assert unfollow["method"] == "thread-stream-following-changed"
    assert unfollow["targetClientIds"] == ["owner-1"]
    assert unfollow["params"]["following"] is False
finally:
    conn.close()
    server.close()
"""#
    try Data(script.utf8).write(to: serverScript)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["python3", serverScript.path, socketURL.path]
    let stderr = Pipe()
    process.standardError = stderr
    try process.run()
    defer {
        if process.isRunning { process.terminate() }
    }

    let socketDeadline = Date().addingTimeInterval(3)
    while !FileManager.default.fileExists(atPath: socketURL.path), Date() < socketDeadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(FileManager.default.fileExists(atPath: socketURL.path))

    let client = DesktopIPCClient(socketURL: socketURL, enforceProductionSecurity: false)
    try await client.connect()
    let owner = try #require(await client.discoverThreadOwner(threadID: "thread-1"))
    #expect(owner == DesktopThreadOwner(clientID: "owner-1", supportsUntrustedAppInput: true))

    try await client.followThread(threadID: "thread-1", ownerClientID: owner.clientID)
    let baseline = try await client.waitForThreadSnapshot(
        threadID: "thread-1",
        ownerClientID: owner.clientID
    )
    #expect(baseline.params["change"]?["revision"]?.intValue == 3)

    let turnID = try await client.startEmptyContinuation(threadID: "thread-1", ownerClientID: owner.clientID)
    #expect(turnID == "turn-1")
    let terminal = try await client.waitForThreadSnapshot(
        threadID: "thread-1",
        ownerClientID: owner.clientID,
        minimumRevisionExclusive: 3
    )
    let outcome = DesktopIPCClient.ownerTurnOutcome(
        from: terminal,
        threadID: "thread-1",
        turnID: turnID,
        ownerClientID: owner.clientID
    )
    #expect(outcome?.status == "completed")
    try await client.unfollowThread(threadID: "thread-1", ownerClientID: owner.clientID)
    await client.close()

    process.waitUntilExit()
    let serverError = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    #expect(process.terminationStatus == 0, "fake IPC server failed: \(serverError)")
}

@Test("Desktop IPC only retries the router's exact pre-dispatch no-client-found error")
func desktopIPCNoClientFoundClassification() async throws {
    let suffix = String(UUID().uuidString.prefix(8))
    let temporary = URL(fileURLWithPath: "/tmp/clipc-missing-\(suffix)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let socketURL = temporary.appendingPathComponent("ipc.sock")
    let serverScript = temporary.appendingPathComponent("server.py")
    let script = #"""
import json, os, socket, struct, sys

path = sys.argv[1]
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(path)
os.chmod(path, 0o600)
server.listen(1)

def read_exact(conn, count):
    data = b""
    while len(data) < count:
        chunk = conn.recv(count - len(data))
        if not chunk:
            raise RuntimeError("unexpected EOF")
        data += chunk
    return data

def read_frame(conn):
    size = struct.unpack("<I", read_exact(conn, 4))[0]
    return json.loads(read_exact(conn, size).decode("utf-8"))

def send_frame(conn, value):
    payload = json.dumps(value, separators=(",", ":")).encode("utf-8")
    conn.sendall(struct.pack("<I", len(payload)) + payload)

conn, _ = server.accept()
try:
    initialize = read_frame(conn)
    send_frame(conn, {
        "type": "response",
        "requestId": initialize["requestId"],
        "resultType": "success",
        "method": "initialize",
        "handledByClientId": "router",
        "result": {"clientId": "codex-limits-test"},
    })

    for message in ["no-client-found", "no-client-found: owner disappeared"]:
        start = read_frame(conn)
        assert start["method"] == "thread-follower-start-turn"
        assert start["targetClientId"] == "owner-1"
        send_frame(conn, {
            "type": "response",
            "requestId": start["requestId"],
            "resultType": "error",
            "method": "thread-follower-start-turn",
            "error": message,
        })
finally:
    conn.close()
    server.close()
"""#
    try Data(script.utf8).write(to: serverScript)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["python3", serverScript.path, socketURL.path]
    let stderr = Pipe()
    process.standardError = stderr
    try process.run()
    defer {
        if process.isRunning { process.terminate() }
    }

    let socketDeadline = Date().addingTimeInterval(3)
    while !FileManager.default.fileExists(atPath: socketURL.path), Date() < socketDeadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(FileManager.default.fileExists(atPath: socketURL.path))

    let client = DesktopIPCClient(socketURL: socketURL, enforceProductionSecurity: false)
    try await client.connect()

    var exactError: DesktopIPCError?
    do {
        _ = try await client.startEmptyContinuation(threadID: "thread-1", ownerClientID: "owner-1")
    } catch let error as DesktopIPCError {
        exactError = error
    }
    #expect(exactError == .serverError("no-client-found"))
    #expect(exactError.map(AutoResumeCoordinator.isDefiniteDesktopOwnerStartRejection) == true)

    var targetError: DesktopIPCError?
    do {
        _ = try await client.startEmptyContinuation(threadID: "thread-1", ownerClientID: "owner-1")
    } catch let error as DesktopIPCError {
        targetError = error
    }
    #expect(targetError == .serverError("no-client-found: owner disappeared"))
    #expect(targetError.map(AutoResumeCoordinator.isDefiniteDesktopOwnerStartRejection) == false)

    await client.close()
    process.waitUntilExit()
    let serverError = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    #expect(process.terminationStatus == 0, "fake IPC server failed: \(serverError)")
}
#endif
