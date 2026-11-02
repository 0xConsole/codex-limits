import AppKit
import CodexLimitsCore
import SwiftUI

struct LimitsMenuView: View {
    @ObservedObject var store: AccountStore

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let activeLogin = store.activeLogin {
                LoginView(activeLogin: activeLogin, store: store)
            } else if store.accounts.isEmpty {
                EmptyStateView(store: store)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(store.accounts) { account in
                            AccountCard(account: account, store: store)
                        }
                    }
                    .padding(12)
                }
                .frame(height: accountListHeight)
            }

            if let message = store.bannerMessage {
                Divider()
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(.caption)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button {
                        store.bannerMessage = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                }
                .padding(10)
            }

            if let status = store.autoResumeStatus {
                Divider()
                HStack(spacing: 8) {
                    if store.autoResumeIsRunning {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(10)
            }

            if let status = store.desktopSwitchStatus {
                Divider()
                HStack(spacing: 8) {
                    if store.desktopSwitchingAccountID != nil {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "desktopcomputer")
                            .foregroundStyle(.secondary)
                    }
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(10)
            }

            Divider()
            footer
        }
        .frame(width: 420)
    }

    private var accountListHeight: CGFloat {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first {
            NSMouseInRect(mouseLocation, $0.frame, false)
        } ?? NSScreen.main

        let visibleHeight = screen?.visibleFrame.height ?? 900
        var chromeHeight: CGFloat = store.bannerMessage == nil ? 120 : 190
        if store.autoResumeStatus != nil { chromeHeight += 44 }
        if store.desktopSwitchStatus != nil { chromeHeight += 44 }
        let availableHeight = max(240, visibleHeight - chromeHeight)

        // MenuBarExtra windows may collapse a ScrollView that only has a maxHeight.
        // Give the account list a concrete content-driven height, then cap it at the
        // current display's usable height so larger account sets naturally scroll.
        let estimatedCardHeight: CGFloat = 142
        let spacing: CGFloat = 10
        let verticalPadding: CGFloat = 24
        let accountCount = CGFloat(store.accounts.count)
        let estimatedContentHeight =
            (accountCount * estimatedCardHeight)
            + (max(0, accountCount - 1) * spacing)
            + verticalPadding

        return min(availableHeight, max(180, estimatedContentHeight))
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Codex Limits")
                    .font(.headline)
                Text("\(store.accounts.count) of \(AccountStore.maximumAccounts) accounts")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if store.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            }
            Button {
                Task { await store.refreshAll() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh all accounts")
            .disabled(store.isRefreshing || store.autoResumeIsEnabled || store.autoResumeIsRunning || store.accounts.isEmpty)
        }
        .padding(12)
    }

    private var footer: some View {
        HStack {
            Button {
                store.beginLogin()
            } label: {
                Label("Add account", systemImage: "person.badge.plus")
            }
            .disabled(!store.canAddAccount)

            if store.autoResumeIsEnabled {
                Button {
                    store.stopAutoResume()
                } label: {
                    Label("Stop Auto Resume", systemImage: "stop.circle")
                }
                .help("Turn off Auto Resume. A continuation that is already running finishes first.")
            } else {
                Button {
                    store.startAutoResume()
                } label: {
                    Label("Auto Resume", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(!store.canAutoResume)
                .help("When a conversation stops on a Codex usage limit, wait until a saved account's 5-hour limit fully replenishes, switch Codex Desktop to that account, and continue the conversation.")
            }

            Spacer()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(10)
    }
}

private struct EmptyStateView: View {
    @ObservedObject var store: AccountStore

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.2.crop.square.stack")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("Track all your Codex accounts")
                .font(.headline)
            Text("Sign in once per account. Each login is kept isolated, so checking limits never switches the account used by Codex itself.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Add Codex account") {
                store.beginLogin()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
    }
}

private struct LoginView: View {
    let activeLogin: ActiveLogin
    @ObservedObject var store: AccountStore

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("Finish signing in")
                .font(.headline)
            Text("Sign in to the account you want to add in the browser page Codex opened.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let otpStatus = store.otpAssistStatus {
                Label(otpStatus, systemImage: "envelope.badge")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Open sign-in page") {
                    store.reopenLoginPage()
                }
                .buttonStyle(.borderedProminent)
                Button("Cancel") {
                    store.cancelLogin()
                }
            }
        }
        .padding(24)
    }
}

private struct AccountCard: View {
    let account: SavedAccount
    @ObservedObject var store: AccountStore
    @State private var confirmRemoval = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.email)
                        .font(.system(.body, design: .rounded, weight: .semibold))
                        .lineLimit(1)
                    Text(account.planType.replacingOccurrences(of: "_", with: " ").capitalized)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button("Refresh") {
                        Task { await store.refresh(account: account.id) }
                    }
                    .disabled(store.autoResumeIsEnabled || store.autoResumeIsRunning)
                    Divider()
                    Button("Remove account", role: .destructive) {
                        confirmRemoval = true
                    }
                    .disabled(store.autoResumeIsEnabled || store.autoResumeIsRunning)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            LimitRow(title: "5 hour", window: account.usage?.fiveHour)
            LimitRow(title: "Weekly", window: account.usage?.weekly)

            if account.usage?.ordinaryUsageAllowed == false {
                Label(blockedMessage(account.usage?.rateLimitReachedType), systemImage: "exclamationmark.octagon.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
            if account.needsReauthentication == true {
                HStack(alignment: .center, spacing: 8) {
                    Label("Sign-in expired", systemImage: "person.crop.circle.badge.exclamationmark")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Sign in again") {
                        store.reauthenticate(account: account.id)
                    }
                    .controlSize(.small)
                    .disabled(store.autoResumeIsEnabled || store.autoResumeIsRunning)
                }
                if let refreshed = account.lastRefreshedAt {
                    Text("Limits shown above are from the last successful update, \(refreshed, style: .relative) ago.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } else if let error = account.lastError {
                Label(error, systemImage: "wifi.exclamationmark")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                if let refreshed = account.lastRefreshedAt {
                    Text("Last successful update \(refreshed, style: .relative) ago")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } else if let refreshed = account.lastRefreshedAt {
                Text("Updated \(refreshed, style: .relative) ago")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Button {
                Task { await store.switchDesktopAccount(to: account.id) }
            } label: {
                if store.desktopSwitchingAccountID == account.id {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Switching Codex Desktop…")
                    }
                } else if store.desktopActiveAccountID == account.id {
                    Label("Active in Codex Desktop", systemImage: "checkmark.circle.fill")
                } else {
                    Label("Switch Account", systemImage: "arrow.left.arrow.right")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(
                store.desktopActiveAccountID == account.id
                    || !store.canSwitchDesktopAccount(account.id)
            )
            .help(
                store.desktopActiveAccountID == account.id
                    ? "Codex Desktop is already signed in with this saved account."
                    : "Restart Codex Desktop and sign it in automatically with this saved account."
            )
        }
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .confirmationDialog(
            "Remove \(account.email)?",
            isPresented: $confirmRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove from Codex Limits", role: .destructive) {
                store.remove(account: account.id)
            }
        } message: {
            Text("This deletes only this app's saved login. It does not sign out or change your normal Codex account.")
        }
    }

    private func blockedMessage(_ type: String?) -> String {
        switch type {
        case "workspace_owner_credits_depleted", "workspace_member_credits_depleted":
            return "Workspace credits are depleted"
        case "workspace_owner_usage_limit_reached", "workspace_member_usage_limit_reached", "rate_limit_reached":
            return "Included usage is currently blocked"
        default:
            return "Codex reports this account is currently blocked"
        }
    }
}

private struct LimitRow: View {
    let title: String
    let window: LimitWindow?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let window {
                    Text("\(Int(window.remainingPercent.rounded()))% left")
                        .font(.caption.monospacedDigit().weight(.medium))
                    if let reset = window.resetsAt {
                        Text("· resets \(resetDescription(reset))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Unavailable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ProgressView(value: window?.remainingPercent ?? 0, total: 100)
                .progressViewStyle(.linear)
        }
    }

    private func resetDescription(_ date: Date) -> String {
        let now = Date()
        if date <= now { return "now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
