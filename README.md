<h1 align="center">Better Teams</h1>

<p align="center">
  <strong>Microsoft Teams, finally at home on your Mac.</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-26%2B-111111?logo=apple&logoColor=white" alt="macOS 26 or later">
  <img src="https://img.shields.io/badge/Swift-6.2-F05138?logo=swift&logoColor=white" alt="Swift 6.2">
  <img src="https://img.shields.io/badge/core-Rust-B7410E?logo=rust&logoColor=white" alt="Rust core">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT%20%2B%20Microsoft%20exclusion-2F6FEB" alt="License: MIT + Microsoft exclusion"></a>
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/chat-dark.png">
    <source media="(prefers-color-scheme: light)" srcset="docs/screenshots/chat-light.png">
    <img src="docs/screenshots/chat-light.png" width="92%" alt="Better Teams showing a team chat with quotes, reactions, bot cards and an image">
  </picture>
</p>

<p align="center">
  A truly native Teams client, written in AppKit and SwiftUI over a Rust core. No Electron, no browser tab in disguise.<br>
  Chat, meetings, calendar, files and your team's apps, with private AI summaries that never leave your Mac.
</p>

<p align="center">
  <a href="#ten-reasons-to-switch"><b>Highlights</b></a> ·
  <a href="#everything-it-does"><b>All features</b></a> ·
  <a href="#get-started"><b>Get started</b></a> ·
  <a href="#license"><b>License</b></a>
</p>

<br>

## Ten reasons to switch

<table>
  <tr>
    <td colspan="2" align="center">
      <br>
      <sub>01</sub>
      <h2>Catch Up, privately on your Mac</h2>
      <p>Back from a week off? One click turns a long thread into a summary, key points and action items.<br>
      It runs on Apple Intelligence, on this Mac. Your messages are never sent anywhere to be summarized.</p>
      <table>
        <tr>
          <td align="center" width="33%"><b>Off</b><br><sub>No button, no summaries.</sub></td>
          <td align="center" width="33%"><b>When you click</b><br><sub>Summarize the chat you're in, on demand.</sub></td>
          <td align="center" width="33%"><b>Always up to date</b><br><sub>A live Catch Up window that refreshes as messages arrive.</sub></td>
        </tr>
      </table>
      <sub>Background updates pause in Low Power Mode and while your Mac is running hot.</sub>
      <br><br>
    </td>
  </tr>
  <tr>
    <td width="58%"><img src="docs/screenshots/activity.png" alt="Activity feed with mentions, replies and missed calls, and the mentioned message highlighted"></td>
    <td width="42%">
      <sub>02</sub>
      <h3>Mentions of you, never buried</h3>
      <p>Mentions, replies, reactions and missed calls land in one Activity feed. Click one and you're on the exact message, highlighted.</p>
      <p>With Catch Up on, anything that names you, <code>@everyone</code> or <code>@channel</code> goes to the top. The mention itself decides that, not an AI guess.</p>
    </td>
  </tr>
  <tr>
    <td width="42%">
      <sub>03</sub>
      <h3>Meetings and video calls in a real Mac window</h3>
      <p>Join from your calendar or a link, check your camera and mic in the pre-join preview, then run the call in its own window or inside the main one.</p>
      <p>One-to-one audio and video calls, speed dial and a test call are built in.</p>
    </td>
    <td width="58%"><img src="docs/screenshots/call-video.png" alt="A meeting in progress with participant tiles along the bottom"></td>
  </tr>
  <tr>
    <td width="58%"><img src="docs/screenshots/teams-thread.png" alt="A Teams channel with a reply thread open in the inspector"></td>
    <td width="42%">
      <sub>04</sub>
      <h3>Channels with threads that stay put</h3>
      <p>Every team in a tidy outline. Open a thread beside the channel and keep reading while you reply.</p>
      <p>Channel files, notes and tabs are one click away, and the team roster sits in the inspector.</p>
    </td>
  </tr>
  <tr>
    <td width="42%">
      <sub>05</sub>
      <h3>Your week at a glance</h3>
      <p>A proper week grid, plus an agenda view for the day. The Join button shows up as a meeting gets close.</p>
      <p>Schedule a new meeting, or join any meeting with its ID or link.</p>
    </td>
    <td width="58%"><img src="docs/screenshots/calendar-week.png" alt="Calendar week view with meetings laid out across the days"></td>
  </tr>
  <tr>
    <td width="58%"><img src="docs/screenshots/files.png" alt="Files table with the inspector showing file details"></td>
    <td width="42%">
      <sub>06</sub>
      <h3>Files that feel like Finder</h3>
      <p>OneDrive, files shared with you, and channel files in a real, sortable table. Select several, then move, copy or rename them.</p>
      <p>Press Space for Quick Look, drop files in to upload, and big uploads resume where they left off.</p>
    </td>
  </tr>
  <tr>
    <td width="42%">
      <sub>07</sub>
      <h3>Planner, To Do and Shifts, built in</h3>
      <p>Not a web page in a frame: native screens for Planner buckets and assignees, your To Do lists, and your team's Shifts schedule.</p>
      <p>Pin the ones you use to the sidebar.</p>
    </td>
    <td width="58%">
      <img src="docs/screenshots/planner.png" alt="Planner board with a task open in the inspector">
      <img src="docs/screenshots/shifts.png" alt="Shifts schedule for the week">
    </td>
  </tr>
</table>

<table>
  <tr>
    <td width="33%" valign="top">
      <sub>08</sub>
      <h3>Native to the last pixel</h3>
      <p>AppKit and SwiftUI throughout, Liquid Glass where macOS puts it, a real menu bar and a real Settings window.</p>
    </td>
    <td width="33%" valign="top">
      <sub>09</sub>
      <h3>Calm, steady screens</h3>
      <p>Updates arrive in the background and slot into place. Lists never flash, jump, or fall back to a spinner once they have content.</p>
    </td>
    <td width="33%" valign="top">
      <sub>10</sub>
      <h3>Keyboard first</h3>
      <p>Every command is in the menu bar. <kbd>⌘</kbd><kbd>K</kbd> goes anywhere, <kbd>⌘</kbd><kbd>1</kbd>–<kbd>6</kbd> switch sections, and an optional global hotkey opens a quick composer.</p>
    </td>
  </tr>
</table>

<br>

## Everything it does

### Chat

- Pinned and recent chats, with filters to narrow the list
- Reply with quotes, react, edit, delete, forward, save and pin messages
- Send Later with a queue of scheduled messages, plus reusable templates
- Attach files or drop them onto a conversation; GIF search with your own key
- Typing indicators, "Seen by", and a Jump to Latest button with a count
- Translate messages into your language
- Ghost mode: hold back read receipts, presence and typing

### Teams and channels

- Join or create teams; create channels
- Posts, Files, Notes and web tabs for every channel
- Threads open beside the channel in the inspector
- Team roster with Add Member and Remove

### Meetings and calls

- Join meetings from the calendar, a link, or a meeting ID
- Pre-join preview with camera, mic and device choice
- One-to-one audio and video calls, speed dial, recents and missed calls
- Calls ring with a notification you can accept or decline
- Test call to check your setup
- Recaps: recordings with a transcript you can click to seek, plus action items

### Calendar

- Week grid and agenda views
- Join, copy the join link, or cancel from the event detail
- New meeting, and join with an ID or link

### Files

- OneDrive, shared with you, channel files and downloads in one place
- Sort, multi-select, move, copy, rename and delete
- Quick Look with Space, drag-and-drop upload, upload progress
- File details and version history in the inspector

### Planner, To Do, Shifts and OneNote

- **Planner:** buckets, checkboxes, add tasks, assignees in the inspector
- **To Do:** your lists, quick add, show or hide completed
- **Shifts:** the week's schedule with a team picker
- **OneNote:** browse notebooks natively and append to a page

<details>
<summary>See OneNote</summary>
<br>
<img src="docs/screenshots/app-pinned.png" alt="OneNote notebook open natively in Better Teams">
</details>

### Search

- Message search works offline from a local index on your Mac
- Online, server results merge in alongside it, with people and files
- Every hit opens at the exact message
- Find within a conversation, with next and previous match

### Catch Up (on-device AI)

- Summary, key points and action items for any conversation
- Mentions of you, <code>@everyone</code>, <code>@channel</code> and <code>@team</code> listed first
- A dedicated Catch Up window that stays current in the background
- Click a mention in Catch Up to jump straight to the message
- Everything stays on your Mac; off by default

### Notifications

- Native banners with Reply, Mark as Read and Join actions
- Per-chat notification levels and keyword alerts
- Quiet hours, and silence while a Focus is on
- Unread count on the Dock icon, with New Chat and your status in the Dock menu
- Optional menu bar item

### Mac-native and keyboard

- Every toolbar command is also in the menu bar
- <kbd>⌘</kbd><kbd>1</kbd>–<kbd>6</kbd> for sections, <kbd>⌘</kbd><kbd>K</kbd> for Go To, next and previous unread
- Global quick composer hotkey (optional)
- Customize the sidebar: pin, reorder and remove sections and apps
- Larger or smaller text with <kbd>⌘</kbd><kbd>+</kbd> and <kbd>⌘</kbd><kbd>−</kbd>
- VoiceOver labels on icon-only controls
- Light and dark appearance

<details>
<summary>See the Settings window</summary>
<br>
<p align="center"><img src="docs/screenshots/settings.png" width="60%" alt="Better Teams Settings, General pane"></p>
</details>

### Accounts and privacy

- Sign in with a device code or in the browser
- Multiple accounts, switched in place
- Sign-in tokens live in the macOS keychain
- Export your chat archive, and rebuild the local search index

### Apps

- App library with filters, plus your own web links
- Pin apps to the sidebar
- **Coming soon:** Teams apps hosted natively, without loading the Teams web app

### For developers: MCP

`ostmac-mcp` is a Model Context Protocol server that gives AI assistants such as Claude Desktop access to your chats. It uses the app's session, so you only sign in once, in the app.

| Tool | What it does |
| --- | --- |
| `list-chats` | Recent one-to-one and group chats |
| `list-messages` | History for a chat or channel, with paging |
| `send-message` | Post a text message |
| `react-message` | Add or remove a reaction |
| `list-teams` / `list-channels` | Your teams and their channels |

Setup: [docs/mcp.md](docs/mcp.md).

<br>

## Get started

### Requirements

- macOS 26 or later
- Xcode command line tools (`swift`, `xcodebuild`) and Rust (`cargo`)
- Catch Up needs a Mac with Apple Intelligence turned on

### Build and run

```sh
./scripts/build-rust.sh   # Rust core (vendored ost + ostmac-core), release
./scripts/build-app.sh    # Better Teams.app in swift/.build/release
open "swift/.build/release/Better Teams.app"
```

**Try it without an account.** Demo mode runs fully offline with sample data:

```sh
open "swift/.build/release/Better Teams.app" --args --demo
```

### Install

```sh
./scripts/package.sh --install   # signed release build, copied to /Applications
./scripts/make-dmg.sh            # versioned installer disk image in tmp/
```

Signing uses `CODESIGN_IDENTITY` if set, otherwise your first Apple Development identity, otherwise ad-hoc. With ad-hoc signing, camera and microphone permissions don't survive a rebuild.

### Test

```sh
./scripts/test.sh   # Rust tests, then the Swift suites
```

## Under the hood

- **`swift/`**: the SwiftPM package. `OstMac` is the app entry point, `BetterTeamsUI` the AppKit and SwiftUI interface, `OstMacCore` the clients, stores and services, and `OstMacMCP` the MCP server.
- **`rust/ostmac-core/`**: a static library with a C ABI. JSON crosses the boundary, which keeps it version-tolerant.
- **`rust/ost/`**: the vendored [ost](https://github.com/eisbaw/ost) Teams protocol core, with every local change documented in `rust/ost/OSTMAC-PATCHES.md`.

## Upstream and thanks

The Teams protocol core is [eisbaw/ost](https://github.com/eisbaw/ost), the Open Source Teams client in Rust. Thank you. It is vendored under `rust/ost` so it builds on macOS as a library.

## Contributing

PRs are welcome. Run `./scripts/test.sh` first, and keep screenshots to demo mode (`--demo`): no real chats, names or tokens in commits.

<sub>Better Teams is an independent project. It is not affiliated with, endorsed by, or sponsored by Microsoft. Microsoft, Microsoft Teams, OneDrive, SharePoint, OneNote, Planner and To Do are trademarks of the Microsoft group of companies. Apple, Mac, macOS and Apple Intelligence are trademarks of Apple Inc.</sub>

## License

Better Teams is free for everyone to use, modify, redistribute and sell —
personally or commercially — under an MIT-style license, with one exception:
Microsoft (including its affiliates and anyone acting on its behalf) receives
no rights under it and needs a commercial license from the author. See
[LICENSE](LICENSE) for the full terms.

Third-party components, including the vendored `rust/ost` and the Rust crates
it depends on, keep their own licenses; see [NOTICE](NOTICE).

For commercial licensing, contact [@mrowlinson](https://github.com/mrowlinson)
on GitHub by opening an issue.
