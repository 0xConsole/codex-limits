import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif os(Windows)
import WinSDK
#endif

public enum SingleInstanceLockError: LocalizedError, Sendable {
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            return "Could not create the Codex Limits instance lock: \(reason)"
        }
    }
}

/// An exclusive lock on a file, held for the life of the process. Only one process can
/// hold it, and the operating system releases it when that process exits, even after a
/// crash, so a stale lock never blocks the next launch.
public final class SingleInstanceLock {
    #if os(Windows)
    private let handle: HANDLE

    private init(handle: HANDLE) {
        self.handle = handle
    }

    deinit {
        CloseHandle(handle)
    }

    /// Returns nil when another process already holds the lock.
    public static func acquire(at url: URL) throws -> SingleInstanceLock? {
        try AppPaths.createPrivateDirectory(at: url.deletingLastPathComponent())
        let handle = url.nativePath.withCString(encodedAs: UTF16.self) { path in
            // Read and write access (GENERIC_READ | GENERIC_WRITE) with no sharing: a
            // second open fails with ERROR_SHARING_VIOLATION while this handle is open.
            CreateFileW(path, DWORD(0xC000_0000), 0, nil, DWORD(OPEN_ALWAYS), DWORD(FILE_ATTRIBUTE_NORMAL), nil)
        }
        guard let handle, handle != HANDLE(bitPattern: -1) else {
            let error = GetLastError()
            if error == DWORD(ERROR_SHARING_VIOLATION) { return nil }
            throw SingleInstanceLockError.unavailable("Windows error \(error)")
        }
        return SingleInstanceLock(handle: handle)
    }

    public static func holderProcessID(at url: URL) -> Int32? {
        nil
    }
    #else
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        close(descriptor)
    }

    /// Returns nil when another process already holds the lock.
    public static func acquire(at url: URL) throws -> SingleInstanceLock? {
        try AppPaths.createPrivateDirectory(at: url.deletingLastPathComponent())
        let descriptor = open(url.path, O_RDWR | O_CREAT, 0o600)
        guard descriptor >= 0 else {
            throw SingleInstanceLockError.unavailable(String(cString: strerror(errno)))
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK { return nil }
            throw SingleInstanceLockError.unavailable(String(cString: strerror(code)))
        }

        // Record the holder so a second launch can say which process is running.
        let pid = Data("\(getpid())\n".utf8)
        _ = ftruncate(descriptor, 0)
        _ = pid.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        return SingleInstanceLock(descriptor: descriptor)
    }

    /// The process ID the current holder recorded, if it can be read.
    public static func holderProcessID(at url: URL) -> Int32? {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    #endif
}
