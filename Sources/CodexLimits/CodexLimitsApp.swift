import AppKit
import CodexLimitsCore
import SwiftUI

@main
struct CodexLimitsApp: App {
    @StateObject private var store: AccountStore
    private let instanceLock: SingleInstanceLock?

    init() {
        instanceLock = Self.claimSingleInstance()
        _store = StateObject(wrappedValue: AccountStore())
    }

    var body: some Scene {
        MenuBarExtra {
            LimitsMenuView(store: store)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "gauge.with.dots.needle.67percent")
                if let remaining = store.menuBarRemainingPercent {
                    Text("\(remaining)%")
                        .monospacedDigit()
                }
            }
        }
        .menuBarExtraStyle(.window)
    }

    /// Only one copy may run: two would refresh the same accounts and could both try to
    /// continue the same conversation. A second launch explains and quits before it
    /// touches any state.
    private static func claimSingleInstance() -> SingleInstanceLock? {
        let lockFile = AppPaths.instanceLockFile
        do {
            if let lock = try SingleInstanceLock.acquire(at: lockFile) {
                return lock
            }
        } catch {
            // Without a lock file there is no way to tell, so start rather than refuse.
            return nil
        }

        let ownProcess = ProcessInfo.processInfo.processIdentifier
        let otherCopy = NSRunningApplication
            .runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .first { $0.processIdentifier != ownProcess }

        let alert = NSAlert()
        alert.messageText = "Codex Limits is already running"
        if otherCopy != nil {
            alert.informativeText = "Find it in the menu bar. Quit that copy first if you want to start this one."
        } else {
            let holder = SingleInstanceLock.holderProcessID(at: lockFile).map { " (process \($0))" } ?? ""
            alert.informativeText = "Another Codex Limits process\(holder) is running, such as `codex-limits auto-resume` in a terminal. Stop it to use the menu-bar app."
        }
        NSApplication.shared.setActivationPolicy(.accessory)
        if #available(macOS 14, *) {
            NSApplication.shared.activate()
        } else {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        _ = alert.runModal()
        exit(0)
    }
}
