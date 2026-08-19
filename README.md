# Claude RC Manager

A macOS menu-bar app that runs one [`claude remote-control`](https://docs.claude.com/en/docs/claude-code/remote-control)
server per configured folder, so you can start Claude Code sessions on your
Mac from the Claude mobile app or claude.ai/code.

Servers run in standby by default (`--no-create-session-in-dir`): the server
holds the folder open, and new sessions are created on demand from your
phone. Spawn mode (`same-dir`, `worktree`, `session`), capacity, permission
mode, and extra CLI arguments are configurable per folder, plus autostart
and crash auto-restart with backoff.

## Requirements

- macOS 13+
- [Claude Code](https://docs.claude.com/en/docs/claude-code) installed and
  logged in with a subscription (`claude auth login`)
- Workspace trust accepted once per folder: run `claude` in the folder once
- Worktree spawn mode needs the folder to be a git repository (or
  WorktreeCreate/WorktreeRemove hooks)

## Install

```bash
make install
```

builds the app (ad-hoc signed) and copies it to `/Applications`. Start it
from there; enable "Start at Login" in the menu if you want it persistent.

Note: the ad-hoc code signature changes on every rebuild, so after a
reinstall macOS may ask you to re-approve the login item in
System Settings → General → Login Items.

`make uninstall` removes the app from `/Applications` (quit it first). Config
(`~/Library/Application Support/Claude RC Manager/`) and logs
(`~/Library/Logs/ClaudeRCManager/`) stay; delete those folders to remove all
data.

## Usage

Click the terminal icon in the menu bar:

- **Add Folder…** — pick a project folder; a settings window opens.
- Per folder: **Start/Stop**, **Open Log**, **Settings…**, **Remove…**.
- **External servers** — remote-control processes started outside the app
  are listed read-only.
- Logs live in `~/Library/Logs/ClaudeRCManager/`.

## Limitations

- Force-quitting the app leaves servers running (regular quit stops them).
- Downloaded release builds are not notarized; macOS will block the first
  launch. Either build from source (`make install`) or clear the quarantine
  flag: `xattr -d com.apple.quarantine "/Applications/Claude RC Manager.app"`.
  Developer-ID signing + notarization is a planned follow-up.

## Development

```bash
swift test   # unit tests
swift run    # run from the checkout (menu bar icon, no Dock icon)
make app     # build the .app bundle
```
