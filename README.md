# Better Teams

Native macOS client for Microsoft Teams, over a Rust core
(`ostmac-core` FFI staticlib) built on vendored
[`ost`](https://github.com/eisbaw/ost). Runs fully offline in `--demo`
with canned data; sign in via device code or browser to go live.

> UI being rebuilt — see docs/design/UI-SPEC.md. The previous app UI
> was deleted; the app currently launches with no windows while the
> stores, services, and core below stay intact.

## Features

Core capabilities (logic + stores kept; surfaces pending the new UI):

Chat & conversation

- Chat list with pins, chat folders with auto-rules, filters,
  mark-unread, hide, leave/block; live Trouter feed, paged history.
- Messaging: send, edit, delete, quote replies, emoji reactions,
  scheduled send + pending queue, per-chat snooze, forward/copy/save,
  pinned messages, @-mention parsing; Klipy GIF search (bring-your-own
  key, kept in the macOS keychain).
- Rich message parsing: mentions, inline images, bot posts, adaptive
  cards, link previews, read receipts, typing, code blocks with
  offline highlighting.
- Shared files: list/upload/download, folders, share links, versions,
  move/copy/rename/delete, resumable big uploads, QuickLook, save-as.
- Jump-to-context: search hits resolve to the exact message.

Teams, meetings, calls

- Teams & channels — join/create team, create channel, channel tabs,
  team roster.
- Meetings — upcoming list, join parsing + lobby, recordings,
  transcripts (turns + matching recording).
- Calls — place/accept/end, mic/speaker/camera capture, echo-bot test,
  call history; incoming calls ring with a system notification
  (Accept/Decline).

Notifications & accounts

- Native banners with rules, quiet hours (Focus sync on by default),
  @me/@team and keyword alerts, per-chat levels.
- Multi-account: device code or browser (PKCE) sign-in, persisted
  per-profile session, per-account graphs, background sweep posts
  `[account]`-named banners for inactive accounts with unread roll-up
  on switch.

Productivity

- AI thread catch-up — OpenCode CLI, on-device Apple Intelligence,
  or bring-your-own key (macOS keychain).
- Reminders/tasks, Planner plans, Shifts schedules, per-chat Notes
  (OneNote notebooks read), saved messages, translation.
- Offline message archive (compressed export + local search index).
- Teams app-frame logic: app registry, SSO cookie bootstrap, escape
  policy, downloads naming, crop geometry.

Session, diagnostics, integration

- Per-profile tokens in the keychain, refresh/expiry handling.
- MCP server (`ostmac-mcp`, see `docs/mcp.md`) reusing the app's
  session.

## Requirements

- macOS 14+, Xcode command line tools (`swift`, `xcodebuild`), Rust (`cargo`)

## Build / install / run

```sh
./scripts/test.sh        # rust tests + swift tests (builds rust first)
./scripts/build-rust.sh  # vendored ost + ostmac-core staticlib (release)
./scripts/build-app.sh   # Better Teams.app in swift/.build/release
open "swift/.build/release/Better Teams.app"
open "swift/.build/release/Better Teams.app" --args --demo  # offline canned data
./scripts/package.sh [--install]  # signed release tmp/Better Teams.app (+ /Applications)
./scripts/make-dmg.sh    # versioned installer in tmp/
./scripts/install.sh     # copy the release app to /Applications
```

Signing: `CODESIGN_IDENTITY` wins; else the first Apple Development
identity; else ad-hoc (mic/camera grants won't stick across rebuilds).

## Usage

- Try offline first: `--demo` (optionally `--chat <id>`).
- Sign-in UI is pending the rebuild; the device-code and browser
  (PKCE) sign-in logic is kept, and an existing session persists
  across launches.
- `ostmac-mcp` exposes chats to MCP clients (Claude Desktop) — see
  `docs/mcp.md`. It reuses the app's session; sign in once in the app.

## Architecture

- `swift/` — SPM package: `OstMac` (the app entry + composition root),
  `OstMacCore` (clients, stores, models, services), `OstMacChatList`
  (chat-list / browser view models), `OstMacMCP` + `ostmac-mcp`
  executable, `COstMac` (C header).
- `rust/ostmac-core/` — FFI `staticlib`: ~100-function C ABI, JSON over
  the boundary, every string freed with `ostmac_free`.
- `rust/ost/` — vendored upstream `ost` (built as a lib) plus our
  documented patch stack (`OSTMAC-PATCHES.md`, tagged `[minor]`/`[major]`).
- `scripts/` — `build-rust.sh`, `build-app.sh`, `package.sh`,
  `make-dmg.sh`, `install.sh`, `make-icon.sh`, `test.sh`.

Rust builds first; Swift links the staticlib. JSON keeps the FFI
boundary version-tolerant.

## Testing

`./scripts/test.sh` runs ost unit tests, ostmac-core tests, a release
core build, then the Swift suites (`OstMacCoreTests`, `OstMacMCPTests`).

## Upstream & thanks

Teams protocol core: [eisbaw/ost](https://github.com/eisbaw/ost) (Open
Source Teams client, Rust) — thank you. It is vendored under `rust/ost`
so the app builds on macOS and exposes a library surface; every local
change is a documented patch in `rust/ost/OSTMAC-PATCHES.md`.

## Contributing

PRs welcome. Run `./scripts/test.sh` first, and keep screenshots
demo-mode only (`--demo`) — no live chats, names, or tokens in commits.

## License

MIT — see [LICENSE](LICENSE).
