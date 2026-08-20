# Claude RC Manager

A macOS menu-bar app that runs one [`claude remote-control`](https://docs.claude.com/en/docs/claude-code/remote-control)
server per configured folder, so you can start Claude Code sessions on your
Mac from the Claude mobile app or claude.ai/code.

Servers run in standby by default (`--no-create-session-in-dir`): the server
holds the folder open, and new sessions are created on demand from your
phone. Spawn mode (`same-dir`, `worktree`, `session`), capacity, permission
mode, and extra CLI arguments are configurable per folder, plus autostart
and crash auto-restart with backoff.

This is an independent project. It is not affiliated with, endorsed by, or
supported by Anthropic.

## Requirements

- macOS 13+
- [Claude Code](https://docs.claude.com/en/docs/claude-code) installed and
  logged in with a subscription (`claude auth login`)
- Workspace trust accepted once per folder: run `claude` in the folder once
- Worktree spawn mode needs the folder to be a git repository (or
  WorktreeCreate/WorktreeRemove hooks)

## Install

Download [Claude RC Manager.dmg](https://github.com/sveneisenschmidt/claude-rc-manager/raw/main/dist/Claude%20RC%20Manager.dmg),
open it, and drag the app to Applications. The app is signed with a Developer
ID and notarized, so macOS does not block it. Start it from `/Applications`;
enable "Start at Login" in the menu if you want it persistent.

To build it yourself instead:

```bash
make install
```

This copies the app to `/Applications` as well. Without an Apple Developer
certificate the build is ad-hoc signed, and that signature changes on every
rebuild, so after a reinstall macOS may ask you to re-approve the login item
in System Settings → General → Login Items. The downloaded build keeps one
signature and does not.

`make uninstall` removes the app from `/Applications` (quit it first). Config
(`~/Library/Application Support/Claude RC Manager/`) and logs
(`~/Library/Logs/ClaudeRCManager/`) stay; delete those folders to remove all
data.

## Usage

The app follows the macOS system language and is available in English,
German, French, Spanish, Italian, Japanese, and Simplified Chinese.

Click the terminal icon in the menu bar:

- **Add Folder…** — pick a project folder; a settings window opens.
- Per folder: **Start/Stop**, **Open Log**, **Settings…**, **Remove…**.
- **Sessions** — a folder's row shows how many sessions are running in it
  (`● running · 2 sessions`). Stop, Stop All, Remove… and Quit ask before
  they end running sessions.
- **External servers** — remote-control processes started outside the app
  are listed read-only.
- Logs live in `~/Library/Logs/ClaudeRCManager/`.

## Limitations

- Force-quitting the app leaves servers running (regular quit stops them).
- The count comes from the server's own output, so a server that has not
  reported one yet counts as empty and a stop in the first seconds after a
  start does not ask. In `session` spawn mode the server is the session and
  counts as one for as long as it runs.
- Logout, restart and shutdown stop the servers without asking; the sessions
  end with the login session either way.

## Development

```bash
swift test      # unit tests
swift run       # run from the checkout (menu bar icon, no Dock icon)
make build      # build and sign the .app bundle
make install    # uninstall old copy, then install to /Applications
make uninstall  # remove from /Applications (config and logs stay)
make reinstall  # stop the running app, install fresh, launch it
```

`make build` signs with a Developer ID when this Mac has one and ad-hoc
otherwise; `make verify-signature` reports which. `make dmg` builds the
notarized `dist/` image and is a maintainer step: it needs a Developer ID
certificate and a notarytool profile named `claude-rc-manager`.
