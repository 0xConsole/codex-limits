# Changelog

## 0.2.0

First public release.

- Auto Resume waits until any saved account's 5-hour window has fully replenished, signs Codex in to that account and continues the most recent conversation stopped by a usage limit. Leftover quota in a partly used window is not used.
- Auto Resume works with current Codex releases. It no longer depends on Codex's external-auth API, which limited it to a few specific Codex versions.
- An account whose window reset earlier than Codex predicted is used as soon as Codex reports it available.
- Only one copy of Codex Limits can run at a time.
- New `codex-limits` command-line tool for macOS, Linux and Windows: `status`, `add`, `remove`, `use` and `auto-resume`.
- Shorter status messages in the menu-bar app.
