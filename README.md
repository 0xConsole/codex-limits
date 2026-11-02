# Codex Limits

Codex Limits tracks the Codex usage limits of up to 10 ChatGPT accounts and keeps your work going when one runs out. When a Codex conversation stops on a usage limit, it waits until one of your accounts has a fully replenished 5-hour window, signs Codex in to that account and continues the conversation.

It comes in two forms:

- **Menu-bar app (macOS 13 or later).** Shows every account's 5-hour and weekly limits in the menu bar, switches Codex Desktop between accounts, and runs Auto Resume with Codex Desktop.
- **`codex-limits` command-line tool (macOS, Linux and Windows).** Shows the same limits in a terminal, switches the account the Codex CLI uses, and runs Auto Resume for Codex CLI sessions.

Codex Limits is an independent project. It is not made by, affiliated with or endorsed by OpenAI.

## How it works

Each account you add signs in once through Codex's own ChatGPT sign-in and gets its own private Codex home folder. Limits come from the installed Codex CLI (`codex app-server`), so the 5-hour and weekly percentages and reset times are the same ones Codex itself uses.

Adding or refreshing an account never changes the account Codex is signed in to. Only **Switch Account** in the app, `codex-limits use`, and Auto Resume do that. Each of them first copies Codex's current login back to its saved account, because Codex may have renewed its tokens since the last switch.

### Auto Resume

1. It watches the account Codex is signed in to. Nothing happens until a fresh quota read confirms that account is blocked by a usage limit.
2. It finds the most recent conversation, from the last 24 hours, whose latest turn failed with Codex's usage-limit error.
3. It waits until a saved account's 5-hour window has fully replenished: 100% left, with Codex reporting that the account may be used. Quota left over in a partly used window does not count. If more than one account qualifies, it prefers the one Codex already uses, then the one with the most weekly quota left.
4. It signs Codex in to that account and continues the conversation where it stopped.
5. If that account runs out too, it waits for the next replenished account and continues the same conversation.

A journal records each continuation, so Auto Resume never starts the same continuation twice, even after a crash or restart.

Only one copy of Codex Limits runs at a time. A second copy of the app explains this and quits, and `codex-limits auto-resume` refuses to start while the app is open.

## Install

Download the build for your platform from the [Releases](../../releases) page.

### macOS app

1. Unzip `CodexLimits-<version>-macos.zip` and move **Codex Limits.app** to Applications.
2. The app is not notarized by Apple. The first time, right-click it and choose **Open**, or run:

   ```sh
   xattr -dr com.apple.quarantine "/Applications/Codex Limits.app"
   ```

The app needs Codex Desktop or the Codex CLI. It looks for Codex inside `/Applications/ChatGPT.app` first, then in Homebrew, `/usr/local/bin`, `~/.local/bin` and your `PATH`.

### Command-line tool

Unpack the archive for your platform and put `codex-limits` (or `codex-limits.exe`) somewhere on your `PATH`. On Windows, keep the DLLs from the zip in the same folder as the program.

The tool needs the [Codex CLI](https://github.com/openai/codex). It finds `codex` on your `PATH`; set `CODEX_LIMITS_CODEX_PATH` to use a different copy.

## Using the command-line tool

```sh
codex-limits add                    # sign in to an account; repeat for each one
codex-limits                        # show every account's limits
codex-limits status --json          # the same, as JSON for scripts
codex-limits use you@example.com    # sign the Codex CLI in to a saved account
codex-limits remove you@example.com
codex-limits auto-resume            # keep running; continue conversations that stop on a limit
```

`status` looks like this, with `*` marking the account Codex is signed in to:

```
   ACCOUNT            5-HOUR LEFT           WEEKLY LEFT
*  you@example.com    0%, resets in 1h 56m  70%, resets in 5d  usage blocked
   work@example.com   100%, resets in 5h    90%, resets in 5d

* Codex is signed in to this account.
```

`auto-resume` prints one line per change and runs until you press Ctrl-C. Codex Desktop continues conversations on its own login, which only the menu-bar app can switch, so `auto-resume` will not act while Codex Desktop is running. On a Mac with Codex Desktop, use the app.

Commands that change logins (`add`, `remove`, `use`) wait until the menu-bar app and `auto-resume` have stopped.

## Where data is stored

| Platform | Folder |
| --- | --- |
| macOS | `~/Library/Application Support/Codex Limits` |
| Linux | `~/.local/share/Codex Limits` (or `$XDG_DATA_HOME/Codex Limits`) |
| Windows | `%APPDATA%\Codex Limits` |

The folder holds `accounts.json` (emails, plans and the last quota readings), Auto Resume's state, and one subfolder per account with the login Codex saved for it. On macOS and Linux these are readable only by you. Logins never leave your computer: Codex Limits only talks to the Codex CLI running locally.

Codex itself keeps its login and conversations in `~/.codex`, or in `$CODEX_HOME` when that is set.

## Building from source

You need Swift 6 (Xcode 16 or later on macOS).

```sh
swift test
./scripts/build-app.sh                              # macOS: builds dist/Codex Limits.app
swift build -c release --product codex-limits      # any platform: builds the command-line tool
```

If the app is already running, quit it before opening a new build: replacing the app does not stop the copy that is running.

## Releasing

Push a version tag, for example `git tag v0.2.0 && git push origin v0.2.0`. The release workflow builds the macOS app, the macOS command-line tool (universal), Linux tools for x86_64 and arm64, and the Windows tool, then publishes them as a GitHub release. Keep `CodexLimitsVersion.current` in `Sources/CodexLimitsCore/AppPaths.swift` in step with the tag.

## Limitations

- Codex Limits uses parts of Codex that OpenAI does not document: the `codex app-server` protocol, and on macOS Codex Desktop's local IPC. A Codex update can change them. If Auto Resume stops working after an update, the status line shows Codex's error.
- Auto Resume's built-in Codex Desktop support is macOS only.
- Windows support is new. Please report problems.
- Use your accounts within OpenAI's terms. You are responsible for how you use them.

## License

[MIT](LICENSE)
