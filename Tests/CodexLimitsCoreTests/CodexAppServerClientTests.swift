import Foundation
import Testing
@testable import CodexLimitsCore

// These tests drive fake servers through /bin/sh, python3 and Unix sockets.
#if !os(Windows)
@Test("Codex client parses account and rate-limit protocol")
func codexProtocolSnapshot() async throws {
    let temporary = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-limits-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let fakeCodex = temporary.appendingPathComponent("codex")
    let script = #"""
#!/bin/sh
while IFS= read -r line; do
  case "$line" in
    *'"method":"initialize"'*)
      printf '%s\n' '{"id":1,"result":{"codexHome":"/tmp/test"}}'
      ;;
    *rateLimits*read*)
      printf '%s\n' '{"id":3,"result":{"ordinaryUsageAllowed":true,"rateLimits":{"limitId":"codex","planType":"business","primary":{"usedPercent":25,"windowDurationMins":300,"resetsAt":1800000000},"secondary":{"usedPercent":60,"windowDurationMins":10080,"resetsAt":1800500000},"rateLimitReachedType":null},"rateLimitsByLimitId":null,"accountId":"workspace-1"}}'
      ;;
    *account*read*refreshToken*true*)
      printf '%s\n' '{"id":2,"error":{"message":"background usage reads must not force a token refresh"}}'
      ;;
    *account*read*)
      printf '%s\n' '{"id":2,"result":{"account":{"type":"chatgpt","email":"person@example.com","planType":"business"},"requiresOpenaiAuth":true}}'
      ;;
  esac
done
"""#
    try Data(script.utf8).write(to: fakeCodex)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeCodex.path)

    let client = try CodexAppServerClient(homeURL: temporary, executableURL: fakeCodex)
    try await client.start()
    do {
        let snapshot = try await client.fetchAccountSnapshot()
        #expect(snapshot.email == "person@example.com")
        #expect(snapshot.planType == "business")
        #expect(snapshot.accountID == "workspace-1")
        #expect(snapshot.usage.fiveHour?.remainingPercent == 75)
        #expect(snapshot.usage.weekly?.remainingPercent == 40)
        await client.stop()
    } catch {
        await client.stop()
        throw error
    }
}

@Test("Codex client preserves byte order for large fragmented JSONL responses")
func largeFragmentedProtocolResponse() async throws {
    let temporary = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-limits-large-response-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let fakeCodex = temporary.appendingPathComponent("codex")
    let script = #"""
#!/usr/bin/python3
import json
import sys
import time

for line in sys.stdin:
    request = json.loads(line)
    request_id = request["id"]
    method = request["method"]
    if method == "initialize":
        response = {
            "id": request_id,
            "result": {
                "userAgent": "codex-limit-checker/0.155.0-alpha.2.6 (test)",
                "codexHome": "/tmp/test",
            },
        }
    elif method == "thread/list":
        preview = "x" * 700000
        response = {
            "id": request_id,
            "result": {
                "data": [{"id": "thread-large", "preview": preview}],
                "nextCursor": None,
            },
        }
    else:
        response = {"id": request_id, "error": {"message": "unexpected method"}}

    encoded = (json.dumps(response, separators=(",", ":")) + "\n").encode()
    for offset in range(0, len(encoded), 4096):
        sys.stdout.buffer.write(encoded[offset:offset + 4096])
        sys.stdout.buffer.flush()
"""#
    try Data(script.utf8).write(to: fakeCodex)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeCodex.path)

    let client = try CodexAppServerClient(homeURL: temporary, executableURL: fakeCodex)
    try await client.start()
    let page = try await client.listThreadsPage(limit: 100)
    #expect(page.threads.count == 1)
    #expect(page.threads.first?["id"]?.stringValue == "thread-large")
    #expect(page.threads.first?["preview"]?.stringValue?.count == 700_000)
    await client.stop()
}

@Test("Auto Resume only recognizes a failed usage-limit turn")
func autoResumeCandidateParsing() async throws {
    let client = try CodexAppServerClient(
        homeURL: FileManager.default.temporaryDirectory,
        executableURL: URL(fileURLWithPath: "/usr/bin/true")
    )
    let thread: JSONValue = .object([
        "id": .string("thread-1"),
        "updatedAt": .number(1_800_000_000),
    ])
    let usageLimited: JSONValue = .object([
        "id": .string("turn-1"),
        "status": .string("failed"),
        "error": .object([
            "message": .string("usage exhausted"),
            "codexErrorInfo": .string("usageLimitExceeded"),
        ]),
    ])
    let candidate = await client.usageLimitedCandidate(thread: thread, latestTurn: usageLimited)
    #expect(candidate?.sourceThreadID == "thread-1")
    #expect(candidate?.failedTurnID == "turn-1")
    #expect(candidate?.updatedAt == Date(timeIntervalSince1970: 1_800_000_000))

    let unrelatedFailure: JSONValue = .object([
        "id": .string("turn-2"),
        "status": .string("failed"),
        "error": .object(["codexErrorInfo": .string("cyberPolicy")]),
    ])
    #expect(await client.usageLimitedCandidate(thread: thread, latestTurn: unrelatedFailure) == nil)
}

@Test("Codex client caches turn completion that arrives immediately after turn start")
func turnCompletionProtocol() async throws {
    let temporary = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-limits-turn-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let fakeCodex = temporary.appendingPathComponent("codex")
    let script = #"""
#!/bin/sh
while IFS= read -r line; do
  case "$line" in
    *'"method":"initialize"'*)
      printf '%s\n' '{"id":1,"result":{"codexHome":"/tmp/test"}}'
      ;;
    *turn*start*)
      printf '%s\n' '{"id":2,"result":{"turn":{"id":"turn-destination","items":[],"status":"inProgress"}}}'
      printf '%s\n' '{"method":"turn/completed","params":{"threadId":"thread-destination","turn":{"id":"turn-destination","items":[],"status":"completed"}}}'
      ;;
  esac
done
"""#
    try Data(script.utf8).write(to: fakeCodex)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeCodex.path)

    let client = try CodexAppServerClient(homeURL: temporary, executableURL: fakeCodex)
    try await client.start()
    let turnID = try await client.startTurn(
        threadID: "thread-destination",
        input: [.object(["type": .string("text"), "text": .string("retry")])],
        clientUserMessageID: "retry-source-turn"
    )
    let outcome = try await client.waitForTurnCompletion(turnID: turnID)
    #expect(outcome.status == "completed")
    await client.stop()
}

@Test("Auto Resume does not trust persisted interrupted while the live thread is active")
func interruptedTurnPollingFallback() async throws {
    let temporary = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-limits-interrupted-turn-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let fakeCodex = temporary.appendingPathComponent("codex")
    let script = #"""
#!/usr/bin/python3
import json
import sys

thread_reads = 0
for line in sys.stdin:
    request = json.loads(line)
    request_id = request["id"]
    method = request["method"]
    if method == "initialize":
        result = {"userAgent": "codex-limit-checker/0.154.0 (test)", "codexHome": "/tmp/test"}
    elif method == "turn/start":
        result = {"turn": {"id": "turn-interrupted", "items": [], "status": "inProgress"}}
    elif method == "thread/read":
        thread_reads += 1
        status = {"type": "active", "activeFlags": []} if thread_reads == 1 else {"type": "idle"}
        result = {"thread": {"id": "thread-1", "status": status, "turns": []}}
    elif method == "thread/turns/list":
        result = {
            "data": [{
                "id": "turn-interrupted",
                "items": [],
                "itemsView": "notLoaded",
                "status": "interrupted",
                "error": None,
            }],
            "nextCursor": None,
        }
    else:
        sys.stdout.write(json.dumps({"id": request_id, "error": {"message": f"unexpected method {method}"}}) + "\n")
        sys.stdout.flush()
        continue
    sys.stdout.write(json.dumps({"id": request_id, "result": result}) + "\n")
    sys.stdout.flush()
"""#
    try Data(script.utf8).write(to: fakeCodex)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeCodex.path)

    let client = try CodexAppServerClient(homeURL: temporary, executableURL: fakeCodex)
    try await client.start()
    let turnID = try await client.startTurn(threadID: "thread-1", input: [])
    let started = Date()
    let outcome = try await client.waitForTurnCompletion(
        threadID: "thread-1",
        turnID: turnID,
        timeoutSeconds: 10,
        pollIntervalSeconds: 1
    )
    #expect(outcome.id == "turn-interrupted")
    #expect(outcome.status == "interrupted")
    #expect(Date().timeIntervalSince(started) >= 0.8)
    await client.stop()
}
#endif
