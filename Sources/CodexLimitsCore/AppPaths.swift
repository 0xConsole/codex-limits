import Foundation

public enum CodexLimitsVersion {
    public static let current = "0.2.1"
}

public enum AppPaths {
    public static let appSupportFolderName = "Codex Limits"

    public static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(appSupportFolderName, isDirectory: true)
    }

    public static var accountsDirectory: URL {
        supportDirectory.appendingPathComponent("Accounts", isDirectory: true)
    }

    public static var metadataFile: URL {
        supportDirectory.appendingPathComponent("accounts.json", isDirectory: false)
    }

    public static var autoResumeStateFile: URL {
        supportDirectory.appendingPathComponent("auto-resume.json", isDirectory: false)
    }

    public static var autoResumeControlFile: URL {
        supportDirectory.appendingPathComponent("auto-resume-control.json", isDirectory: false)
    }

    /// Held by the menu-bar app, or by `codex-limits auto-resume`, while it runs.
    public static var instanceLockFile: URL {
        supportDirectory.appendingPathComponent("instance.lock", isDirectory: false)
    }

    /// The Codex home whose login and conversations Codex itself uses.
    public static var mainCodexHome: URL {
        let environment = ProcessInfo.processInfo.environment
        for key in ["CODEX_LIMITS_MAIN_CODEX_HOME", "CODEX_HOME"] {
            if let override = environment[key], !override.isEmpty {
                return URL(fileURLWithPath: override, isDirectory: true)
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
    }

    public static func homeDirectory(for id: UUID, in accountsDirectory: URL = AppPaths.accountsDirectory) -> URL {
        accountsDirectory.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    public static func reauthenticationHome(for id: UUID) -> URL {
        accountsDirectory.appendingPathComponent(".reauth-\(id.uuidString.lowercased())", isDirectory: true)
    }

    public static func ensureDirectories() throws {
        try createPrivateDirectory(at: accountsDirectory)
    }

    /// Creates a directory only the current user can open. Windows keeps files in the
    /// user profile private through its default access rules.
    public static func createPrivateDirectory(at url: URL) throws {
        #if os(Windows)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        #else
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        #endif
    }

    /// Atomically writes a file only the current user can read.
    public static func writePrivateFile(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try restrictToOwner(url)
    }

    /// Restricts a file another process wrote, such as the auth.json Codex saves.
    public static func restrictToOwner(_ url: URL) throws {
        #if !os(Windows)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #endif
    }
}

extension URL {
    /// The path in the form the operating system expects, with backslashes and a drive
    /// letter on Windows. Use it for anything handed to another process.
    var nativePath: String {
        #if os(Windows)
        return withUnsafeFileSystemRepresentation { String(cString: $0!) }
        #else
        return path
        #endif
    }
}

public enum CodexLocator {
    public static func locate() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        if let override = environment["CODEX_LIMITS_CODEX_PATH"], !override.isEmpty {
            candidates.append(override)
        }
        candidates += platformCandidates(environment: environment)
        candidates += pathCandidates(environment["PATH"] ?? environment["Path"] ?? "")

        return candidates.first(where: isLaunchable).map { URL(fileURLWithPath: $0) }
    }

    /// The executable and arguments that start Codex at `executable`. npm installs a
    /// `codex.cmd` shim on Windows, which has to run through cmd.exe.
    static func launchCommand(for executable: URL, arguments: [String]) -> (executable: URL, arguments: [String]) {
        #if os(Windows)
        if ["cmd", "bat"].contains(executable.pathExtension.lowercased()) {
            let shell = ProcessInfo.processInfo.environment["ComSpec"] ?? #"C:\Windows\System32\cmd.exe"#
            return (URL(fileURLWithPath: shell), ["/c", executable.nativePath] + arguments)
        }
        #endif
        return (executable, arguments)
    }

    static func pathCandidates(_ path: String) -> [String] {
        #if os(Windows)
        let separator: Character = ";"
        let names = ["codex.exe", "codex.cmd"]
        #else
        let separator: Character = ":"
        let names = ["codex"]
        #endif
        return path.split(separator: separator).flatMap { directory in
            names.map { URL(fileURLWithPath: String(directory), isDirectory: true).appendingPathComponent($0).path }
        }
    }

    private static func platformCandidates(environment: [String: String]) -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #if os(macOS)
        return [
            // Prefer the runtime shipped with Codex Desktop. Desktop owns the session
            // format and may move ahead of a separately installed CLI.
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            home.appendingPathComponent(".local/bin/codex").path,
        ]
        #elseif os(Windows)
        guard let appData = environment["APPDATA"] else { return [] }
        return [URL(fileURLWithPath: appData, isDirectory: true).appendingPathComponent("npm/codex.cmd").path]
        #else
        return [
            home.appendingPathComponent(".local/bin/codex").path,
            "/usr/local/bin/codex",
            "/usr/bin/codex",
        ]
        #endif
    }

    private static func isLaunchable(_ path: String) -> Bool {
        #if os(Windows)
        // Foundation does not treat .cmd scripts as executable on Windows.
        return FileManager.default.fileExists(atPath: path)
        #else
        return FileManager.default.isExecutableFile(atPath: path)
        #endif
    }
}
