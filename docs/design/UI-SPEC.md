# Better Teams — Native macOS UI Specification

Status: design of record for the UI rebuild (the previous UI was purged in `e7261da`). Date: 2026-09-27. Adversarial review pass applied the same day; its decisions are in section 16.
Inventory sources: `7f6baec` (pre-purge) and `HEAD` after `e015bb7` (model and store code that survived the purge).
This document is for implementers. Every **MUST** is checkable. Section 13 records deliberate departures from Apple's Human Interface Guidelines (HIG); section 15 lists every HIG page cited; section 16 is the decisions log.

## 1. Owner requirements (binding)

1. **macOS-native UI only.** AppKit/SwiftUI system controls, system materials, SF Symbols. No web UI, no custom window chrome, no imitation of Microsoft Fluent. Web content only where nothing native is possible: hosted Teams apps and Microsoft sign-in.
2. **Top-level navigation is a Teams-style tab bar**: square buttons, symbol with a label under it (Activity, Chat, Teams, Calendar, Calls, Files, pinned apps, Apps). **Not** a Mail-style source-list sidebar.
3. **The app frame lives in the main window.** A pinned app is a tab-bar item and opens in the content area exactly like Files. The App Library browses, searches, pins, and unpins apps. **No pop-out windows for apps.**
4. **No glitches.** Stock controls, deterministic state, no layout hacks (section 3).
5. **No visible focus rings anywhere.** Standing owner order (`bb177ae`), re-confirmed in `e7261da`. Exact scope in §10.
6. **Calls: the person chooses** in Settings whether a call appears in the main window or in its own window (owner decision, 2026-09-27; §8, §16 DL1).

## 2. Feature inventory

Legend: **S** = surfaced in the main UI · **Set** = Settings only · **Bg** = background (badges/notifications only) · **Drop** = not carried over.

| Capability (core types / FFI) | Class | Surface |
|---|---|---|
| Chats list, pins, folders, filters, mark unread, hide, leave, block (`ChatListViewModel`, `UserPins`, `ChatFolders`, `BlockedStore`) | S | Chat section |
| Conversation: messages, paging, send, edit, delete, reply-quote, reactions, receipts, typing (`ConversationStore`, `ReceiptStore`, `TypingStore`) | S | Conversation detail |
| Rich content: mentions, images, adaptive cards, bot posts, link previews, code blocks, GIFs (`MessageRender`, `AdaptiveCard`, `CodeBlocks`, `Klipy`) | S | Timeline rows, composer |
| Scheduled send + queue, snooze, templates, forward, save, pin, translate (`ScheduledSend`, `SnoozeStore`, `CannedResponsesStore`, `SavedMessageStore`, `PinnedMessageStore`, `MessageTranslation`) | S | Composer, context menus, inspector |
| AI catch-up + action items (`CatchUpStore`, `OnDeviceSummary`, `ActionItemsStore`) | S + Set | Inspector "Catch Up", Recaps; provider in Settings |
| Activity feed: mention, reply, reaction, channel blast, missed call (`ActivityStore`, `MentionStore`) | S | Activity section |
| Search: messages (server + offline index), people, files, recents, jump targets (`MessageSearchStore`, `LocalSearchStore`, `FilePeopleSearchStore`, `SearchRecentsStore`, `JumpPalette`) | S | Toolbar search |
| Teams/channels, join/create team, create channel, roster, channel tabs (`TeamsViewModel`, `TeamRosterViewModel`, `ChannelTabsStore`) | S | Teams section |
| Meetings, week calendar, schedule/cancel, join parse + lobby (`MeetingsViewModel`, `CalendarWeekStore`, `JoinParse`, `Meet`) | S | Calendar section, call UI (§8) |
| Calls: place/accept/end, A/V devices, camera, screen share, live video, echo test, history (`CallCenter`, `CallStore`, `AvPanelModel`, `ScreenShareModel`, `LiveVideoModel`, `CallHistoryStore`) | S | Calls section, call UI (§8) |
| Meeting chat + roster (`MeetingChatStore`, `MeetingRosterStore`) | S | Call inspector (§8) |
| Contacts search + pinned contacts (`ContactsStore`) | S | Calls ▸ Speed Dial, New Chat |
| Files: shared-in-chat, OneDrive, recents, folders, resumable upload, download, link, rename, move, copy, delete, versions, search (`SharedFilesStore`, `UnifiedFilesStore`, `FileVersionsStore`) | S | Files section, conversation Files tab |
| To Do, Planner, Shifts (`RemindersViewModel`, `PlannerViewModel`, `ShiftsStore`) | S | Native apps |
| Recordings + transcripts (`RecordingsViewModel`, `TranscriptsViewModel`, `TranscriptsParser`) | S | Native app "Recaps", meeting detail |
| OneNote notebooks/sections/pages + append (`NotesStore`) | S | Notes tab, native app "OneNote" |
| App frame: registry, library (`tabs-all`), SSO copy, crop/measure, downloads, escape policy (`TeamsFrame*`) | S | Pinned apps in tab bar, Apps section |
| Own presence, others' presence, presence schedule (`PresenceStore`, `PresenceTruthStore`, `PresenceScheduleStore`) | S + Set | Account menu, avatars; schedule in Settings |
| Multi-account, device-code + browser sign-in (`AccountStore`, `AuthViewModel`, `AccountWindowRegistry`) | S | Sign-in view, account menu, one window per account |
| Notify rules, per-chat levels, keyword/mention alerts, quiet hours, Focus sync (`RulesStore`, `NotifyRule`, `KeywordAlerts`, `MentionAlerts`, `QuietHoursStore`, `FocusSyncStore`) | Set | Settings ▸ Notifications; per-chat level also in context menu |
| Ghost mode, density, translation language, quick composer, launch at login (`GhostStore`, `DensityStore`, `TranslationStore`, `QuickComposer*`, `LoginItemStore`) | Set | Settings ▸ Chats / General |
| Archive export, diagnostics/health, MCP status (`ArchiveStore`, `Diagnostics`, `HealthReport`, `ostmac-mcp`) | Set | Settings ▸ Advanced |
| Realtime feed, token refresh, background-account sweep, unread counts, image cache/preload, local index, scheduled-send executor, snooze expiry, notification delivery | Bg | Badges, notifications |
| `CalSync` (build-only engine, zero live calls) | Bg (dormant) | None until its own lane enables it |
| Chat/meeting/file pop-out windows (`PopOutStore`, `MeetingPopOutStore`, `FilePopOutStore`) | Drop | Replaced by in-window navigation |

## 3. Principles and anti-glitch rules

**Principles:** one main window per account; navigation always visible; the content area shows exactly one thing (list plus detail, or one full-width view); every command is in the menu bar; system components first, custom drawing only in the content layer.

**Rules** (all MUST). Rules tagged [lint] are enforced by `scripts/ui-lint.sh`, which fails on any hit in `swift/Sources/BetterTeamsUI`. P0 ships the script with the original patterns; P1 adds the patterns tagged [lint+] (added in the 2026-09-27 review). Allowlists are file paths inside the script, never inline suppression comments.

- **R1 — No custom window chrome.** Banned: `titlebarAppearsTransparent`; `titleVisibility = .hidden` on the main window; `standardWindowButton(`; borderless main windows. [lint] HIG windows: "Avoid creating custom window UI".
- **R2 — Stock containers only.** `NSSplitViewController` for panes, `NSToolbar` for the toolbar, `NSTabViewController(.toolbar)` for Settings, `NSMenu` for menus. No hand-rolled split views, dividers, or view-built toolbars.
- **R3 — One source of truth for navigation.** `NavigationModel` (§11.3) owns section, per-section selection, detail tab, search state, inspector visibility. No `@State` copies of a selection. An `onChange` never writes the value it observes, or a value another `onChange` observes (no ping-pong; checked in review).
- **R4 — Stable identity.** `ForEach`/`List`/`Table` iterate model IDs only, and a refresh keeps every item's ID (stores merge; they never rebuild items under new IDs). Banned: `id: \.self`, index or `enumerated()` IDs, `UUID()` in a view body, the `.id(` modifier (it resets state and scroll position). [lint: `\.id\(UUID`, `\.id\(Date`; lint+: any `.id(` modifier, `id: \.self`, `ForEach(` over `.indices` or `.enumerated()`]
- **R5 — Lazy collections.** Dynamic data uses `List`, `Table`, or the AppKit timeline; `VStack`/`HStack` + `ForEach` over store data is banned. Exempt: bounded collections of ≤12 items (rail, capped by capacity; menus; segmented controls).
- **R6 — No nested same-axis scroll views.** Rows never contain a `ScrollView` [lint in `*Row.swift`]. A text view scrolling its own content (composer) is allowed.
- **R7 — No timing hacks.** Banned for layout or focus: `DispatchQueue.main.asyncAfter`, `Task.sleep`, run-loop spins [lint]. Exception: `Search/Debounce.swift` (250 ms). Allowed repeating tickers: one shared 60 s relative-time ticker (`Shared/RelativeTime.swift`) and one 1 s call-duration ticker owned by `CallSession` (it feeds the call toolbar, the rail call item, the main-window call item, and the Calls row). [lint+: `Timer.` outside those two files]
- **R8 — No geometry feedback loops.** `GeometryReader`/`onGeometryChange` only in `RailView.swift`, where capacity depends on container height only [lint allowlist]. Custom placement uses the SwiftUI `Layout` protocol (`WeekGridLayout`; `TileGridLayout` for the call stage).
- **R9 — System animation only.** No `matchedGeometryEffect` across panes; section switches are instant; list insert/remove uses List defaults; under Reduce Motion highlight fades become static highlights. Programmatic layout changes (section switch, pane collapse, appearance change, restoration) never animate; among layout changes only user-initiated inspector toggles and List insert/remove animate. `.animation(` always takes `value:`. [lint+: `.animation(` without `value:`]
- **R10 — Focus.** Focus-ring *drawing* is suppressed; focus itself is not (exact scope in §10). SwiftUI: `.focusEffectDisabled()` is applied once at every hosting root by the `Hosting` factory (R22), not per control. AppKit views we create set `focusRingType = .none`. `@FocusState` only in the view that owns the fields. No `.focusable(` additions [lint+]. Keys come from menu key equivalents or `onKeyPress` on the focused control, never event monitors. [lint: `addLocalMonitor`, `addGlobalMonitor`]
- **R11 — Views never call the FFI.** No `RustCore.` or `ReadCore.` in the UI target; views call store methods. [lint]
- **R12 — Stale-while-revalidate.** A refresh never replaces populated content with a spinner; loading UI only when there is no data. Async results are keyed by the requested ID; stale results are dropped.
- **R13 — Layout-stable rows.** Leading state indicators (unread dot, send state) use reserved slots, so toggling never shifts text. Trailing status indicators at the end of a truncating line (Chat row pin, mute, snooze, mention) take no width when absent and a fixed slot when present, in a glyph no taller than the line, so the row's height and its leading text never move; only the truncation point of that line changes. Images reserve their final size before pixels arrive (known dimensions, else a 240×160 aspect-fit slot).
- **R14 — Semantic appearance.** Colors are semantic (`.primary`, `.secondary`, `.tint`, `.fill.*`, `Color(nsColor: .controlBackgroundColor)`); literal colors only in `Palette.swift`. Fonts are text styles; literal sizes only in `AppFont.swift`. [lint: `Color(red:`, `NSColor(red:`, `calibratedRed`, `.system(size:`]
- **R15 — Liquid Glass only where the system puts it** (sidebar slot, toolbar, popovers). No `.glassEffect` in the content layer, no direct `NSVisualEffectView` [lint]. HIG materials: "Don't use Liquid Glass in the content layer".
- **R16 — Web views are owned, not created by views.** `WKWebView(` appears only in `FrameHost.swift`. [lint]
- **R17 — One sheet and one popover at a time.** Never a popover from a popover; never a sheet while a popover is open. All sheets go through `WindowModel.sheet` (§9.5).
- **R18 — Every pane state is designed.** Empty/loading/error use `ContentUnavailableView`, `ProgressView`, or an inline error with Retry. Blank panes are defects.
- **R19 — Menus mirror toolbars by construction.** Both are generated from one `CommandCatalog` (§5.4). HIG toolbars: "Make every toolbar item available as a command in the menu bar".
- **R20 — No deleted modules.** No imports of `BTDesign`, or of `OstMacChatList` after P0. [lint]
- **R21 — One navigation entry point.** Only `Navigator` (`Shell/Navigator.swift`, `@MainActor`) writes `NavigationModel`, whose properties are `private(set)`. Each `Navigator` method mutates the model and then, in the same call stack, applies the AppKit side: pane child swap, list-pane collapse, toolbar visibility, window title. AppKit never observes `NavigationModel` asynchronously (`withObservationTracking`, `Observations`, Combine): those deliver on a later turn and show an intermediate frame. SwiftUI list selection binds through `Navigator` setters.
- **R22 — One hosting factory.** `NSHostingController(` and `NSHostingView(` appear only in `Shared/Hosting.swift` [lint+]. The factory sets `sceneBridgingOptions = []` (SwiftUI never touches the window title or toolbar); sets `sizingOptions` to `[]` for panes, `[.preferredContentSize]` for sheets, popovers, and Settings panes, `[.intrinsicContentSize]` for timeline cells (default options let pane content resize split items or the window); applies `.focusEffectDisabled()`; and injects the environment that does not cross an AppKit boundary on its own (`ContentTextScale`, `WindowModel`).
- **R23 — No SwiftUI scene chrome.** Banned in the UI target: `.toolbar {`, `.navigationTitle(`, `.navigationSubtitle(`, `.searchable(`, `NavigationSplitView`, `NavigationStack`, `.inspector(`, `.sheet(`, `.alert(`, `.confirmationDialog(`, `.listStyle(.sidebar)`, `@EnvironmentObject` [lint+]. AppKit owns chrome (R2); sheets and alerts go through `SheetPresenter` (R17); list panes use `.listStyle(.inset)`; filter fields use `Shared/SearchField.swift` (`NSSearchField` wrapper).
- **R24 — Views don't fetch.** Network loads start from `Navigator` selection changes (`SectionProvider.selectionDidChange`) or store schedules, never from `.onAppear`/`.task` in a view. Store loads are idempotent (in-flight dedupe by ID plus a freshness window), so re-showing a pane costs nothing. `.task` is fine for local work (image decode, formatting). Checked in review and the P5 audit.
- **R25 — Split state has one writer per direction.** Rail and list pane: `canCollapseFromWindowResize = false`; the list pane collapses only through `Navigator` for `.full`. Inspector: `canCollapseFromWindowResize = true`; the shell KVO-observes its `isCollapsed` and reports user or system changes to `Navigator.inspectorDidChange`, equality-guarded and never echoed back. `toggleSidebar:` is validated off and overridden as a no-op, so ⌃⌘S or a system-inserted menu item can never hide the rail.
- **R26 — One restoration path.** Frame autosave per account plus `NavigationModel` JSON; `NSWindow.isRestorable = false`; `NSWindow.allowsAutomaticWindowTabbing = false` (window tabs would merge account windows and add a second "Tab Bar" to the View menu). The model is restored and applied before the first `makeKeyAndOrderFront` (its collapse states win over `splitView.autosaveName`), so a window never opens on one section and jumps to another.
- **R27 — Safe area respected.** `.ignoresSafeArea` only in `Call/` (video stage) [lint+]. Content never extends under the rail; web views sit below the toolbar.
- **R28 — Views observe only what they read.** No `@ObservedObject`/`@StateObject` of `AppState` or `AccountGraph` in a view; section roots take the specific stores they display (§11.3).

## 4. Platform baseline

- **Deployment target macOS 26** (owner runs macOS 27). `Package.swift` moves to `swift-tools-version: 6.2` and `.macOS(.v26)`. Every target keeps `swiftSettings: [.swiftLanguageMode(.v5)]` to avoid concurrency churn in the core. No `#available` forks in the UI target (dual code paths are glitch sources). The same target everywhere: `swift/OstMac-Info.plist` `LSMinimumSystemVersion` = `26.0` (currently `14.0`); `scripts/build-rust.sh` exports `MACOSX_DEPLOYMENT_TARGET=26.0` for both cargo builds (the staticlib is currently built for macOS 27 against a macOS 14 package), followed by one clean Rust rebuild because cargo may not re-fingerprint on that variable. P0 (`e8140f7`) aligned `Package.swift` and `build-rust.sh`; the Info.plist value is still `14.0` and P1 aligns it. Build Mac toolchain: Swift 6.4 (satisfies tools 6.2).
- **AppKit lifecycle.** `@main` `NSApplicationDelegate` (already in place after the purge). AppKit owns the main window, split view, toolbar, menus, Settings window, status item; SwiftUI fills panes via `NSHostingController`.
- **Why not SwiftUI `NavigationSplitView`:** it cannot hide *only* its content column (its visibility modes hide the sidebar first), and the full-width pinned-app layout needs exactly that. AppKit also gives tracking-separator toolbars, an inspector split item, menu validation with Show/Hide titles, and restoration — the structure Mail, Notes, and Finder use (HIG split views).
- **AppKit islands inside SwiftUI panes:** conversation timeline (`NSTableView`), `WKWebView` container, video tiles (`AVSampleBufferDisplayLayer`), `QLPreviewPanel`, open/save panels, `NSSharingServicePicker`, Character Viewer (`NSApp.orderFrontCharacterPalette`).
- **Verify in P1 before relying on these** (a failed check updates this spec in the same commit): (1) `EnvironmentValues.sidebarRowSize` (fallback: own Small/Medium/Large setting); (2) `NSToolbarItem` prominent style + tint on macOS 26 (fallback: plain item with red symbol); (3) the 80 pt rail slot: the rail's first button sits below the toolbar safe area, the list-pane title starts at the list pane's leading edge rather than being pushed right by the window buttons, and list content does not extend under the rail glass (fallback: smallest measured width that satisfies all three, measured with a throwaway probe outside the UI target because R1 lint bans `standardWindowButton(` there; never move the buttons); (4) `.focusEffectDisabled()` at the hosting root removes rings from `TextField`, `List`, `Table`, `Button`, `Picker`, `Toggle` (any survivor gets a per-control fix recorded in §10); (5) hidden `NSToolbarItem`s (`isHidden`, macOS 15+) next to tracking separators keep the separators aligned with their dividers. **Result (P1, P1.1):** checks 1–5 pass on macOS 26. Caveat to (5): a hidden item *after* `.inspectorTrackingSeparator` still reserves its width (36 pt + 8 pt spacing) as an empty strip at the toolbar's trailing edge, so hideable items never go there (§5.4).

## 5. Window architecture

### 5.1 Main window anatomy

```
┌────────┬──────────────────────┬────────────────────────────────────┬─────────────┐
│ ● ● ●  │ Chat        [≡][✎]   ┆ [call][video] [catch up]           ┆ [i] [me][Search…]│ unified NSToolbar
│        │ 3 unread             ┆                                    ┆                  │
├────────┼──────────────────────┼────────────────────────────────────┼─────────────┤
│[Activ.]│ PINNED               │ (DS) Design Sync · 6 people         │ Inspector   │
│[ Chat ]│  (DS) Design Sync 2m │ [ Chat | Files | Notes ]            │ (trailing,  │
│[Teams ]│ RECENT               │────────────────────────────────────│  optional)  │
│[ Cal. ]│  (AK) Alex Kim 10:42 │ timeline (AppKit NSTableView)       │             │
│[Calls ]│                      │                                    │             │
│[Files ]│                      │────────────────────────────────────│             │
│ ────── │                      │ composer                           │             │
│[Planner│                      │                                    │             │
│[ Apps ]│                      │                                    │             │
└────────┴──────────────────────┴────────────────────────────────────┴─────────────┘
 tab bar   list pane (collapsible) detail                               inspector
```

`ShellSplitViewController` owns four split items, created once and never replaced:

| Item | Behavior | Width (pt) | Collapse |
|---|---|---|---|
| Tab bar | `NSSplitViewItem(sidebarWithViewController:)` | fixed 80 (min = max) | never: `canCollapse = false`, `canCollapseFromWindowResize = false`; divider 0 returns a zero effective rect (no resize cursor) |
| List pane | `NSSplitViewItem(contentListWithViewController:)` | 260 / 300 / 420 | only via `Navigator` when the layout is `.full` (`canCollapseFromWindowResize = false`) |
| Detail | default | min 440 | never |
| Inspector | `NSSplitViewItem(inspectorWithViewController:)` | 260–360 | user toggle ⌥⌘I; `canCollapseFromWindowResize = true`, so it collapses first when the window narrows (R25) |

Autosave `splitView.autosaveName = "main.<accountID>"` (widths; collapse states come from the model, R26). Minimum window 900 × 600, height raised for the Large sidebar icon size (§5.2); default 1280 × 820.

**Pane containers.** The list, detail, and inspector items each hold a `PaneContainerViewController` that keeps one child hosting controller per visited `SectionID` and swaps the visible child without animation (R21). Hidden children stay alive off-window, so returning to a section keeps its scroll position, disclosure state, and in-progress text with no refetch (R24). A web app's or the call's children are released when the app is unpinned or closed, or the call ends.

**Why the tab bar uses the sidebar slot.** HIG materials: Liquid Glass "forms a distinct functional layer for controls and navigation elements — like tab bars and sidebars"; the sidebar slot is the only stock way to get that layer, traffic-light placement, and toolbar tracking with zero custom chrome. Its **content is not a source list**: it is a fixed vertical tab bar of square labeled buttons with no Show/Hide Sidebar command (HIG tab bars: "If you hide the tab bar, people can forget which area of the app they're in"). Apple's precedent for a vertical tab bar is visionOS ("a tab bar is always vertical, floating in a position that's fixed relative to the window's leading side", same page). **Owner checkpoint:** P1 evidence shows the rail in light and dark, and the owner confirms it reads as Teams-style tab buttons, not a Mail sidebar, before Group A starts. Fallback if rejected: switch the item to default behavior with a window background — one line in `ShellSplitViewController`, nothing else changes.

### 5.2 The tab bar (rail)

**Order** (one top-aligned stack): Activity, Chat, Teams, Calendar, Calls, Files → divider → pinned apps (user order) → at most one **transient** app → the **call item** (main-window calls only, §8) → **More** (only when needed) → **Apps**. Nothing pinned to the bottom edge (HIG sidebars: "Avoid putting critical information or actions at the bottom"). Built-ins are never hidden or disabled; an empty section explains itself in place (HIG tab bars: "Don't disable or hide tab bar buttons").

**Button** (`RailButton`: stock `Button` + `ButtonStyle`, in `RailView.swift`):

| Aspect | Spec |
|---|---|
| Size | 64 × 54 pt hit area (≥ the 28 × 28 pt default control size in HIG accessibility); 10 pt continuous corners |
| Content | SF Symbol `.title2`, 3 pt gap, label `.subheadline` (11 pt), one line, tail truncation, full name in `.help()` |
| Unselected | symbol `.secondary`, label `.primary`, no background |
| Selected | `.symbolVariant(.fill)` (tab bars: "Prefer filled symbols"); foreground `.tint`; background `.tint.quaternary` |
| Selected, inactive window | when `controlActiveState != .key`: symbol `.secondary`, label `.primary` (as unselected: a `.secondary` label read lighter than the unselected tabs, as if disabled), background `.fill.tertiary` (matches system selection) |
| Hover / pressed | `.fill.quaternary` / `.fill.tertiary` (via `onHover`) |
| Keyboard focus | only with keyboard navigation or Full Keyboard Access on: the hover fill, read from `EnvironmentValues.isFocused`; never a ring (§10) |
| Badge | red capsule, white `.caption2.monospacedDigit()`, overlaid top-trailing on the symbol, never affects layout; `1…99`, then `99+`; dot-only = unread without count (tab bars: "red oval containing white text") |
| Badge sources | Activity: unreviewed items. Chat: unread chats. Teams: channels with unread mentions. Calls: missed calls since last visit |
| Scale | item height 48 / 54 / 60 pt for sidebar icon size Small / Medium / Large (`sidebarRowSize`) |
| Accessibility | container labeled "Sections"; item label e.g. "Chat, 3 unread"; traits `.isButton`, plus `.isSelected` when current |

- **Keyboard:** Go ▸ ⌘1–⌘6 = built-ins; ⌘7–⌘9 = the first three pinned apps in rail order, whether or not they are overflowed (shortcuts never change with window height). Full Keyboard Access reaches every button.
- **Overflow:** capacity = `floor((railHeight − fixedChrome) / itemHeight)`, measured with `onGeometryChange`. Pinned apps that don't fit go into **More** (`ellipsis`), a `Menu` in rail order. If the active app is overflowed, More takes the selected style and its menu checkmarks that app. The fixed items — built-ins, Apps, the call item, More — never overflow: the window's minimum height is computed from constants, not measured, as `max(600, toolbarSafeArea + railPadding + 9 × itemHeight + divider)`, rounded up to a multiple of 20 (Small and Medium stay at 600; Large ≈ 640), and updated when the sidebar icon size changes. Pinned apps fill the remaining slots (HIG tab bars: "Avoid overflow tabs"); P1 records how many fit at 900 × 600, Medium.
- **Pinning and reordering** (HIG tab bars: "Let people customize the tab bar"): rail item context menu = Unpin from Tab Bar, Move Up, Move Down (transient item: Keep in Tab Bar, Close App). View ▸ **Customize Tab Bar…** opens a sheet: a `List` with `.onMove` (stock reorder), Remove per row, Add from Library…. No direct drag-reorder on the rail (custom drag in a stack is a known glitch source).
- **Transient app** (Teams pattern): opening an unpinned app from the Library shows it as the transient item; opening another unpinned app replaces it. Every open path (Library, route, Go To…) sets the transient item through `Navigator` (Shell/), so the rail never shows a selected app it does not list.

### 5.3 Section layouts

Each section provider answers `layout(for: selection) -> .listDetail | .full`. `Navigator` sets `listItem.isCollapsed` **without animation** in the same call stack that swaps the pane children (R21), so no intermediate frame is ever visible. A list-pane selection never changes the rail section (HIG tab bars, visionOS: "prevent selections in the sidebar from changing which tab is currently open"); only Search and Go To… move to another section.

| Section | Layout | List pane | Detail | Inspector |
|---|---|---|---|---|
| Activity | listDetail | activity feed | conversation at message | conversation info |
| Chat | listDetail | chats | conversation | Info / Catch Up / Pinned |
| Teams | listDetail | teams › channels outline | channel (Posts / Files / Notes / web tabs) | thread or team |
| Calendar | listDetail (Agenda) · full (Week) | week agenda | meeting | meeting (Week view) |
| Calls | listDetail | speed dial + history | person / call | — |
| Files | listDetail | file sources | file table | info + versions |
| Apps | listDetail | app library | app card | — |
| Planner · To Do · Recaps · OneNote | listDetail | plans · lists · recaps · notebooks | tasks · tasks · player · page | task · — · action items · — |
| Shifts | full | — | week schedule table | shift |
| Web app (frame) | full | — | `WKWebView` | — |
| Call (main-window mode, §8) | full | — | pre-join or stage | People / Chat |

### 5.4 Toolbar

- **One toolbar, fixed identifiers.** One `NSToolbar`, style `.unified`, `allowsUserCustomization = false` in v1 (D5). The delegate's identifier list is the fixed superset of every item any state can show, created once at window creation. The **pure function** `ToolbarModel.visible(items:layout:hasInspector:searching:call:connection:)` (unit-tested; `items` = the provider's `toolbarItems(sel)`) returns the identifiers to show; `ShellToolbarController.sync()`, called by `Navigator` (R21), sets `NSToolbarItem.isHidden` on the difference. Items are never inserted, removed, or recreated after launch (insert/remove relayouts the toolbar and flickers). Enablement comes from validation, never from hiding: the inspector toggle, account menu, and search item are always visible, and the toggle validates off in sections without an inspector.
- **Item order and groups:** `.sidebarTrackingSeparator` → **list group** (title and subtitle render here) → `NSTrackingSeparatorToolbarItem` on the list|detail divider → **detail group** → flexible space → hideable status items: connection item (§5.7), then call item (§8) → **trailing group**, always-visible items only: `.toggleInspector`, account `NSMenuToolbarItem`, and `NSSearchToolbarItem` last (HIG search fields: "Put a search field at the trailing side of the toolbar"). **No `.inspectorTrackingSeparator`** (P2c-fix decision, DL12): the region after it is only as wide as the inspector column and is sized from every item in it, hidden ones included (§4 check 5), so search there collapsed to its icon whenever the inspector was closed, and search before it broke "search last" and left the inspector column's toolbar area empty. Without it the detail region runs to the window edge: search keeps its full field with the inspector open or closed and ends 8 pt from the edge, and the flexible space absorbs any hidden status item. The placement is structural: `ShellToolbarController.layout` puts `trailingGroup` (inspector toggle, account, search) last and every other `.trailing` command after the flexible space and before it, so a new status item (P4a's call item) needs no ordering code (pinned by `testToolbarTrailingGroupEndsWithSearch`). Three groups (HIG toolbars: "aim for a maximum of three"); system symbols without symbol enclosures ("Prefer system-provided symbols without borders"; item bezels stay, `isBordered = true`). The list|detail tracking separator is hidden in `.full` layout (the list pane is collapsed; a visible one draws a stray divider). In `.full` layout, list-group items that must stay reachable (Calendar week navigation and Agenda | Week) have detail-group twins with their own identifiers; the list-group originals are hidden.
- **Hidden toolbar:** View ▸ Hide Toolbar is supported. Every toolbar item has a menu-bar command (R19; HIG toolbars: "Because people can customize the toolbar or hide it, it can't be the only place that presents a command"). ⌥⌘F, ⌘F, and ⌘K show the toolbar first if it is hidden, then focus the field.
- **Account menu:** Presence ▸ Available / Busy / Do Not Disturb / Away / Appear Offline; Presence Schedule…; account list (switch); Add Account…; Sign Out. Mirrored in the menu bar (Better Teams ▸ Status ▸, §9.1).
- **Title and subtitle:** title = section or app name; subtitle = context ("3 unread", or a web page's title). HIG toolbars: "Don't title windows with your app name". With more than one account window open, the title becomes "Chat — ‹Account›" so the Window menu can tell windows apart.
- **`CommandCatalog`:** aggregates the per-section command lists (§11.3) of `Command { id, title, symbol, keyEquivalent, selector, menuPlacement }`. Menu items and toolbar items are both built from it and both validate through the responder chain (`validateMenuItem` / `validateToolbarItem`); `NavigationModel` answers enabled/state; section providers perform actions.

### 5.5 Search

HIG search fields: "Put a search field at the trailing side of the toolbar"; "start search immediately"; "scope bar in the search results".

- **Search mode:** typing (250 ms debounce) calls `Navigator.beginSearch`, which sets `NavigationModel.search`. The list pane expands if collapsed and shows results; the detail shows the selected result. Esc or the clear button restores the exact prior section, selection, and layout.
- **Results:** segmented scope bar **All | Messages | People | Files**, default All ("Default to a broader scope"). *Top Hits* = chats, channels, people from the `JumpPalette` fuzzy matcher (local, instant); *Messages* = server results, merged with the offline index when offline; *Files*. Return on a top hit opens it and exits search mode. Recent searches (`SearchRecentsStore`) show when the field is focused and empty.
- **As built (P2b):** the search item sits in the trailing group, last (§5.4); recent searches are the field's native `NSSearchField` recents menu (`searchMenuTemplate`, fed from `SearchRecentsStore` when editing begins), not a custom list; the selected result lives in `SearchModel` (not `NavigationModel`), because search mode is transient and Esc restores the prior selection.
- **As built (ACTSEARCH):** segments never shrink below their labels, so the scope bar takes the first that fits the list pane: small segments, then mini (the default 300 pt pane with four scopes), else the same choices in a pop-up menu (the ⌘F conversation segment makes five). Online, Messages lists the server window only; the offline index fills the list while that window loads ("On This Mac" badge) and replaces it offline or on a network failure. ⌘F find lists the conversation's own matches from the on-device index (case- and diacritic-insensitive) merged with its server hits, not a filtered global window. Person results: Call, Video (disabled: no video call-start path), Chat (starts the 1:1 when none exists), Email. File results: Open and Quick Look (download to a private temporary folder first), Download (~/Downloads), Show in Chat (`source_id`), Open in Browser. File sizes use `ByteCountFormatter` (`.file`).
- **Keys** (HIG keyboards): ⌥⌘F focuses the field (standard "jump to the search field"); ⌘F focuses it scoped to the current conversation, channel, or page (placeholder "Search in ‹name›"); ⌘K = Go To… (Teams parity: focuses the field with scope All; Return opens the top hit); ⌘G / ⇧⌘G step through in-conversation hits. In web apps the field becomes "Find in Page" and drives `WKWebView.find`.

### 5.6 Inspector

Trailing split item with an optional segmented header (≤3 segments). Content is a function of (section, selection) and follows selection changes; visibility is remembered per section. Toggle: toolbar `.toggleInspector`, or View ▸ Show/Hide Inspector ⌥⌘I (standard "Display an inspector window"). HIG panels: "An inspector displays the details of the currently selected item … consider using a split view pane".

### 5.7 Windows, accounts, sign-in

- **One main window per account** (`ShellWindowController(accountID:)`). The active account uses `AppState`; other accounts use their `AccountWindowRegistry` graph; the UI sees both through the `AccountGraph` protocol (P0). File ▸ Open Account in New Window ▸ ‹account›. Never a second window for the same account: `FrameHost` is per account, so a web view has exactly one possible parent.
- **Other windows:** only Settings, the call window when Settings ▸ Calls is set to In a Separate Window (§8), and the opt-in quick-composer panel (HIG windows: "Avoid opening new windows as default behavior unless it makes sense for your app"). System panels (Quick Look, open/save, Character Viewer) are not counted.
- **Restoration:** R26; frame autosave per account; `NavigationModel` persisted as JSON per account; web views restore lazily (§7.3).
- **Connection states** (content stays on screen, R12): **Offline** → informational status item (§5.4 order) `wifi.slash` "Offline" (`.help`: "Showing saved content"); sends queue as pending rows (§6.2.1) and search falls back to the offline index. **Session expired** → the same status item relabeled `exclamationmark.triangle` "Sign In Again" (also Better Teams ▸ Sign In Again…) opening the sign-in sheet; the window never swaps back to the sign-in view while the account has data.
- **Signed out:** the window's content view controller is `SignInViewController` — centered, no rail, no split view. **Sign in with Microsoft** uses the in-app browser sheet (§7.4). **Use a device code** shows the code in large monospaced type with Copy Code, Open Browser, and a waiting status. After sign-in the content controller swaps to the shell exactly once. `--demo` skips sign-in.

## 6. Sections

**Shared row conventions.** Avatars are 28 pt monogram circles (`Palette.swift`); groups use `person.2.fill`; times `.caption`/`.secondary`. Presence = shape + color (HIG accessibility: "Convey information with more than color alone"): Available `checkmark.circle.fill`, Busy `circle.fill`, Do Not Disturb `minus.circle.fill`, Away `clock.fill`, Offline `xmark.circle`.

**Lists** use `List(selection:)` with `.listStyle(.inset)` + `.contextMenu(forSelectionType:menu:primaryAction:)`; double-click or Return opens. Selected rows keep the system selection background (no custom `listRowBackground` for selection), which is also the macOS focus cue for lists (§10). Selection stays highlighted in every pane leading to the detail (HIG split views: "persistently highlight the current selection"). **Context menus** (HIG context menus): hide unavailable items; ≤3 separator groups; one submenu level; no shortcuts shown; every item also exists in the menu bar.

**Pane states** (R18). Loading = `ProgressView` only when there is no data (R12). Error = inline message + Try Again (worded "You're offline" when offline). Empty and no-selection use `ContentUnavailableView`:

| Section | Empty (list) | No selection (detail) |
|---|---|---|
| Activity | "No Activity" — "Mentions, replies and reactions appear here." | "No Item Selected" |
| Chat | "No Chats" + New Chat | "No Chat Selected" |
| Teams | "You're not a member of any teams" + Join a Team… | "No Channel Selected" |
| Calendar | "No Meetings This Week" + New Meeting… | "No Meeting Selected" |
| Calls | "No Recent Calls" + New Call… | "No Contact Selected" |
| Files | "No Files" (per source) + Upload… | — (the table always shows the selected source) |
| Apps | "No Apps Found" + Refresh Library | "No App Selected" |
| Native apps | per §6.7 (e.g. "Shifts isn't set up for your teams") | "No ‹Item› Selected" |
| Search | `ContentUnavailableView.search(text:)` | "No Result Selected" |

### 6.1 Activity (`bell`)

- **List pane:** filter pop-up (All, Unread, Mentions, Replies, Reactions, Missed Calls, Saved) + Mark All as Read.
- **Row:** reserved unread dot · kind symbol (`ActivityKind.systemImage`) over the avatar · headline ("Alex Kim mentioned you in Design Sync") · 2-line snippet · time.
- **Detail:** the conversation scrolled to the message, highlighted by a 1.5 s `keyframeAnimator` fade (an animation, not a timer, so R7 holds; static under Reduce Motion and under `--evidence`). A missed call shows the person detail with Call Back. A vanished message shows an inline "Message no longer available" notice, never a silent open at the top.
- **As built (ACTSEARCH):** the inspector (conversation info, §5.3) is available when a conversation item is selected; with nothing selected or a missed call it validates off. The cached-feed error strip has Try Again (a fresh look at the store; the feed is built from live events). Filter and Mark All as Read validate off with nothing listed. Missed-call Call Back places the call on the call's 1:1 thread (as Calls ▸ Call Back).
- **Context menu:** Open, Mark as Read/Unread, Remove from Saved. **Empty:** "No Activity" — "Mentions, replies and reactions appear here."

### 6.2 Chat (`bubble.left.and.bubble.right`)

- **List toolbar:** Filter menu (`line.3.horizontal.decrease`: All, Unread, Mentions, Muted, Snoozed, Hidden, one item per folder, Manage Folders…); New Chat (`square.and.pencil`, ⌘N: sheet with people search + recent contacts).
- **List:** Pinned (UserPins order), then Recent; a folder filter narrows to that folder.
- **Row:** reserved unread slot, avatar (presence badge for 1:1). Line 1: name (`.headline` when unread, else `.body`), time. Line 2: "Sender: preview" (`.subheadline`, `.secondary`, one line), then trailing status indicators (`pin.fill`, `bell.slash`, `moon.zzz`, `at`; 12 pt `.caption` each), laid out only when present (R13). Indicators live on line 2, not line 1, so names never truncate against them. Mention count via stock `.badge(n)`.
- **Context menu:** Mark as Read/Unread, Pin/Unpin · Mute, Snooze ▸ (1 Hour, Until Tomorrow, Until Next Week, Custom… → sheet), Notifications ▸ (All, Mentions Only, Off), Move to Folder ▸ · Hide, Leave Chat… (groups, confirmed), Block… (confirmed).

**Detail — the conversation view** (shared by Chat, Activity, Search, Teams posts):

- **Header** (content layer): avatar, name (`.title3` semibold), subtitle (presence or member count), trailing segmented tab control **Chat | Files | Notes** (HIG tab views: "The tabbed control appears on the top edge of the content area"). ≤5 segments; extra channel tabs go into a `More ▾` pull-down ("a pop-up button … when there are too many panes"). Menu: View ▸ Chat ⌥⌘1, Files ⌥⌘2, Notes ⌥⌘3.
- **Tabs:** Chat = timeline (§6.2.1) + composer (§6.2.2); Files = `FileTable(scope: .conversation(id))` (§6.6); Notes = OneNote page list, page, Append field.
- **Detail toolbar:** Audio Call (`phone`), Video Call (`video`), Catch Up (`sparkles`: opens the inspector on Catch Up and runs it), inspector toggle.
- **Inspector segments:** **Info** (members with presence; mute/level; Snooze, Hide, Leave) · **Catch Up** (summary, action items, provider state, Retry) · **Pinned** (pinned messages; click to jump).

#### 6.2.1 Timeline (AppKit island)

- **Structure:** `TimelineViewController` = `NSScrollView` + view-based `NSTableView`: one column, no header, no selection highlight, `focusRingType = .none`; rows are reused cells hosting `MessageRowView` through `Hosting` (R22).
- **Row heights are explicit, not automatic** (`usesAutomaticRowHeights = false`). `RowHeightCache` measures each row once with an off-screen sizing host at the current column width and caches by (id, revision, width, `ContentTextScale`); `heightOfRow` reads the cache. A history page is measured before `insertRows`, so `ScrollAnchor` restores offsets from final heights (estimated heights that correct themselves while scrolling are the classic chat-history jump). A width change re-measures visible rows once in `viewDidEndLiveResize` (and on text-scale change), then calls `noteHeightOfRows`; off-screen rows re-measure lazily before they are shown.
- **`TimelineSnapshot`** (pure) maps store messages to `[TimelineItem]`: `daySeparator`, `newMessagesDivider`, `message(id, revision)`, `typing`. Sender runs within 5 min share one header; channel posts group by `reply_to` (§6.3). Updates diff by ID (`CollectionDifference`) into `insertRows` / `removeRows` / `reloadData(forRowIndexes:)` with **no animation**, then `noteHeightOfRows` for rows whose cached height changed.
- **`ScrollAnchor`** (pure policy, unit-tested on synthetic row frames): `pinnedToBottom` (within 24 pt of the bottom; updates keep the bottom pinned) · `anchored(id, offset)` (after any update — history prepend near top, image height change — the anchor row's offset is restored in the same layout pass) · `jump(id)` (center + highlight the row, paging until found or reporting a miss). When not pinned, an overlay "Jump to latest" button (`chevron.down.circle.fill`, with unread count) sits bottom-trailing.
- **Row content:** header name (`.headline`) + time (`.caption`); body `AttributedString` from `MessageRender`, mentions tinted; code monospaced `.callout` on `.fill.quaternary`; images per R13, click → `QLPreviewPanel`; file chips; adaptive/bot cards with native buttons; link previews; reaction chips (`.bordered`, small); edited marker; reply-quote block; no bubble tails. **Chat scope** (1:1 and group chats): own messages are trailing-aligned with no avatar or name, on an accent-tinted card; others' are leading with avatar + name; "Seen by …" on the last own message. **Channel and thread scope** (Posts, thread inspector): every post, own included, is a leading-aligned threaded post with avatar + name, no own card, and no "Seen by" receipts (Microsoft Teams parity; owner 2026-09-27). Send state in a reserved slot (R13): sending/queued offline = `clock` (`.secondary`); failed = `exclamationmark.circle` (red) + the words "Not Sent", with Retry and Delete in the context menu.
- **Message context menu:** React ▸ (six quick + More…), Reply, Forward…, Copy, Copy Link · Save/Unsave, Pin/Unpin, Translate, Mark Unread from Here · Edit, Delete… (own only).
- **VoiceOver:** each row is one element ("Alex Kim, 10:42 AM, ‹text›, 2 reactions"); every context action is also an `accessibilityAction`. A hover bar (React / Reply / More) may come later, overlay only.

#### 6.2.2 Composer

- **Field:** `TextField(axis: .vertical)`, 1–8 lines. Return sends, ⇧Return inserts a newline (swappable in Settings), via `onKeyPress` on the field. **P2a verifies** image paste and marked-text (IME) input on this field; if either fails, the field becomes an `NSTextView` island behind the same API, recorded here in the same commit.
- **Leading buttons:** Attach (`paperclip` → `NSOpenPanel`; drop onto the conversation also works) · Emoji (`face.smiling`, system Character Viewer) · GIF (popover; only when a Klipy key exists) · Templates menu (`text.badge.plus`).
- **Send** (`paperplane.fill`) with pull-down: Send Now, Send Later… (popover with graphical `DatePicker`).
- **Popovers anchored to the composer** (`ComposerPopover` enum, one at a time): @-mention suggestions, reaction More…, GIF search.
- **Status:** reply chip while quoting; "2 scheduled" button opening the queue sheet; typing line in a reserved slot; `eye.slash` glyph when ghost mode is on.

### 6.3 Teams (`person.3`)

- **List toolbar:** Join or Create ▸ (Join a Team…, Create Team…).
- **List:** outline `List`, one `DisclosureGroup` per team, collapse state persisted. Team rows: monogram tile + name. Channel rows: `number` + name, bold when unread, mention `.badge`.
- **Context menus:** team = Create Channel…, Manage Members…, Mark All as Read; channel = Mark as Read, Notifications ▸, Copy Link.
- **Detail:** header "Team › Channel" (subtitle = description), tabs **Posts | Files | Notes | ‹≤2 web tabs› | More ▾** (from `ChannelTab.target`). Posts = timeline of root posts; "N replies" opens the **thread inspector** (replies + reply composer). Web tabs render in-window through `FrameHost` (§7) under key `tab:<id>`; browser only when `.external`.
- **Inspector:** Thread when a post is selected; else Team (roster, owners first; owners get Add Member…, Remove).
- **Sheets:** Create Team, Create Channel, Join a Team (search list). **Empty:** "You're not a member of any teams" + Join a Team….
- **As built (P2c):** the channel tabs sit on their own row under the title (a trailing tab row squeezed the title at the 440 pt detail minimum); the row is the widest fold that fits, trailing tabs fold into More ▾, and the selected tab is always a visible segment (an overflow tab takes the last segment's place). ⌥⌘1–3 select Posts | Files | Notes. The thread inspector's reply field is a slim field + Send (one `ComposerModel` per window: two full composers would fight over popovers and focus). The channel tab and open thread live in the Teams selection path (`[team, channel, "tab:<key>", "thread:<id>"]`), not `NavigationModel.detailTab`, which cannot hold web tabs. While the list is loading, errored, or empty the detail stays empty; a selected team shows its name and channel count.
- **Unverified:** whether live channel replies carry `reply_to` (`ChatMessage.reply_to`, `Models.swift`). P2c probes demo and live first; if not, Posts renders flat.

### 6.4 Calendar (`calendar`)

- **List toolbar:** ‹ Today › week navigation + **Agenda | Week** segmented control.
- **Agenda:** sectioned by day. Row: time range (`.monospacedDigit`), subject, organizer, `video` badge when online; a small `.borderedProminent` **Join** when joinable now (±10 min).
- **Detail:** subject, time, organizer, join link; Join (primary), Meeting Chat, Copy Join Link; Cancel Meeting… for organizers (confirmed); **Recap** group with matched recording + transcript (Play, Open).
- **Week** (`.full`): work-week grid via `WeekGridLayout`, a `Layout` with pure lane assignment for overlaps (unit-tested); selected event detail in the inspector.
- **Toolbar:** New Meeting… (sheet: subject, start, end, Teams-meeting toggle); Join with ID or Link… (sheet using `JoinParse`; no shortcut — ⌘J is the standard "Scroll to a selection"). Join opens the call pre-join in the chosen presentation (§8).

### 6.5 Calls (`phone`)

- **List:** Speed Dial (pinned contacts with presence), then Recent (`CallHistoryStore`). Recent row: direction symbol (`phone.arrow.up.right` / `phone.arrow.down.left`; missed = `.red` + the word "Missed") · name · time · duration.
- **List toolbar:** New Call (people search sheet), Test Call (echo bot).
- **Detail:** large avatar, presence, Call / Video / Chat buttons, recent calls with this person.
- **Context menu:** Call Back, Chat, Add to/Remove from Speed Dial, Remove from Recents.
- **During a call:** a "Current call" row with live duration at the top; clicking it shows the call (`CallSession.show()`: the rail call item or the call window, §8).
- **As built (P3b):** Calendar week navigation (‹ Today ›), Agenda | Week (a pull-down, not a segmented control: the toolbar factory has no segmented item), New Meeting… and Join with ID or Link… are detail-group items, so they stay visible in both layouts without twins; ‹ Today › and web Back / Forward / Reload are `isNavigational` (leading, before the title). The Week grid shows the store's 7-day window (not a work week) because the core week start follows the locale. The first Calendar visit starts the week load (the core loads it on demand only). Recent = `CallHistoryStore` + realtime missed-call Activity rows the history never saw (keyed by `callerID`, same-caller within `missedCallWindow` = one call). Not built (core gaps): meeting Recap group (no meeting→recording match API), Meeting Chat (event carries no chat thread; button disabled), Cancel Meeting… shows only when the organizer name equals the own display name (no organizer flag), Video call (no video call-start path; disabled), Remove from Recents and Add to / Remove from Speed Dial (no per-record delete; pins need a directory `TeamMember`), live duration on the Current call row (the 1 s ticker is P4a's). Settings ships the Calls pane only (Show calls); devices and Test Call join it in P4a/P4c. The call stage is a minimal seam (pre-join: Mic/Camera toggles + Join Now; then name + state in words); the main-window Leave item is a plain toolbar item (P4a styles it `.prominent` red); the call ends only through Leave (core-driven end is P4a).

### 6.6 Files (`folder`)

- **List (sources):** Recent · My Files (OneDrive) · Shared in Chats · Teams (disclosure: team › channel library) · Downloads (includes frame downloads).
- **Detail — `FileTable`**, SwiftUI `Table` (HIG lists and tables): columns Name (icon, middle truncation), Modified, Modified By, Size, Location; header click sorts, again reverses; resizable columns, alternating rows, multi-select. Folder drill-in shows a breadcrumb of borderless buttons. Space = Quick Look; dropping files onto the table uploads.
- **Toolbar:** Upload… (⌘U) · Quick Look (`eye`) · Share (`square.and.arrow.up`, save-first `NSSharingServicePicker`) · Transfers (`arrow.down.circle`: popover of uploads/downloads with determinate progress, like Safari's) · inspector toggle.
- **Inspector:** info (size, dates, location, link) + **Versions** (Restore, Download).
- **Context menu:** Open, Open in Browser, Quick Look · Download, Save As…, Copy Link, Share… · Rename…, Move To…, Copy To…, Delete… (confirmed).
- **Search:** scope Files, or searching inside this section, uses `ostmac_file_search`.
- **As built (P3c):** one `FileTableView` serves the section and a chat's / channel's Files tab (same columns, sort, context menu, Space = Quick Look); in a tab, Location is plain text and there is no upload. Modified By = the core's `sender` (no modified-by field). Location links the source conversation (`source_id`: channel → Teams, else Chat). Empty / loading / error draw inside the table area under its header. A Teams › channel source lists the channel library through a Files-owned `SharedFilesStore` (never the open conversation's). Downloads = `TransferStore` (OstMacCore; finished downloads persist in the account's storage defaults, in memory in demo): Files and Files-tab downloads, frame `WKDownload`s and timeline image saves. Transfers is a trailing toolbar item (⌥⌘L). Added: Show in Finder (local files only). Shortcuts: Open ⌘O, Quick Look ⌘Y, Save As… ⇧⌘S. **As built (FILES2):** Rename… / Move To… / Copy To… / Delete… (⌘⌫) in the context menu and File menu act on the store that listed the file (Files index, channel library, or the conversation's Files tab); Rename and Move/Copy are sheets (destination = a folder list: the folders above the open one and beside the item on the same drive; demo shows three canned folders), Delete… confirms with the stock alert. Demo acts on in-memory rows only (move drops the row from a folder listing; the flat index keeps it; copy is a no-op). Searching inside Files (typing in the toolbar field, ⌘F, ⌥⌘F) starts in the Files scope; the field reads "Search in Files". Timeline images: context menu Save Image to “Downloads” / Save Image As… (panel opens in ~/Downloads), recorded in Transfers and Files ▸ Downloads; demo writes to the demo tmp dir only. File chips in the timeline (§6.2.1) are still not built.

### 6.7 Native apps

Native apps pin like web apps and are listed in the Library under "Built-in".

- **Planner** (`checklist`): list = plans grouped by team; detail = List sectioned by bucket, rows with `.checkbox` toggle (complete/reopen), title, due date, an "Add Task" field ending each section; inspector = task. No kanban board in v1 (forces nested scroll axes, R6).
- **To Do** (`checkmark.circle`): list = lists; detail = tasks with checkboxes, add field on top, Show Completed toggle.
- **Shifts** (`person.badge.clock`, `.full`): toolbar team picker + week navigation; `Table` rows = people, columns = days, cells = time + theme label + color swatch; time off as rows; empty "Shifts isn't set up for your teams".
- **Recaps** (`play.rectangle.on.rectangle`): list = recordings + transcripts merged per meeting, searchable; detail = `AVPlayerView` (AppKit island) above transcript turns, click a turn to seek; inspector = Action Items (on-device), Save, Open in Browser.
- **OneNote** (`note.text`): list = notebook › section › page outline; detail = page (read-only) + Append field.
- **As built (P4B-LEFT):** Planner rows add the assignees (the first assignee's name, "+n" for more; roster names of the plan's team, "Unknown Person" when the roster lacks an id); the task inspector gains an Assigned To section and an Assign To menu (also in the row context menu; checkable team members). To Do: route `app/todo/<list>`; the add field and a Show Completed checkbox sit above the tasks (View ▸ Show Completed Tasks is the twin, off by default); completed rows are read-only (the service has no reopen); no inspector. Recaps: route `app/recaps/<recording or transcript id>`; rows merge a recording and its transcript by file stem, newest first; the list filters locally (Filter Recaps field, no server search); the player loads paused; turn clicks seek; inspector = details, Action Items (Find Action Items, on this Mac), Save … to Downloads, Open in Browser. Shifts: each week is fetched from the server (range filter), so ‹ Today › show loading while the week lands.

## 7. App frame (redesign)

### 7.1 Model

- **`FrameApp`** = `{ id, label, symbol, source, launch, cropOverride?, zoom }`. `source`: `.channelTab(team, channel, tabID)` | `.personal(appID)` | `.webLink` | `.teamsWeb`. `launch`: `.teamsHosted(entityURL)` | `.direct(url)` | `.external(url)`.
- **`RailModel.pinned: [RailEntry]`**, `RailEntry` = `.native(NativeAppID)` | `.web(FrameApp.ID)`, persisted per account. Replaces `TeamsFrameRegistry.selectedAppKey` (the old single "selected app" model).
- **Launch resolution** (pure `FramePolicy.launch(for:)`, unit-tested; first match wins): (1) Posts / Files / Notes → native views; (2) a `contentURL` on an allow-listed standalone host (SharePoint, OneDrive, Office.com, Forms, Power BI, Planner web) → `.direct`, loads without Teams chrome, no crop; (3) everything else → `.teamsHosted` via the hash-route entity URL `/_#/l/entity/…`, which skips the launcher interstitial (FRAME-LIVE-PROOF); (4) non-http schemes and library entries marked external → `.external`.

### 7.2 Apps section (Library, `square.grid.2x2`)

- **List pane:** filter field at the top of the list (HIG search fields: "Include search at the top of the sidebar when filtering content"), then sections **Pinned** · **Built-in** (Planner, To Do, Shifts, Recaps, OneNote, and "Teams on the Web" = `.teamsWeb`, full chrome, no crop) · **Channel Tabs** grouped "Team › Channel" (`TeamsFrameLibrary`) · **Personal Apps** (gap G2) · **Web Links**.
- **List toolbar:** Refresh Library (`arrow.clockwise`, determinate "Scanning 12 of 22 channels"); Add Web Link… (sheet: URL, name, symbol).
- **Detail — app card:** symbol tile, name, source line, capability ("Runs in Better Teams" or "Opens in your browser — ‹reason›"). Buttons: **Open** (prominent), **Pin to Tab Bar / Unpin**, Open in Browser, Remove (web links only). Advanced disclosure: crop Left/Top steppers, Measure, Reset, Unload from Memory.
- **Open:** an unpinned app becomes the transient rail item and is selected. An `.external` app opens in the default browser; its **Pin** is disabled with an inline reason — the only case the owner's "unless not otherwise possible" allows.
- **States:** first run "Scanning your channels for apps…" with progress; errors inline with Retry; results from the existing library cache.
- **As built (P3a):** the scan is one `teams-cli tabs-all` call (absolute path via `resolveCLI`), so progress is indeterminate, not "Scanning 12 of 22"; it starts on the first Apps visit when no cache exists (never under `--evidence`). Channel tabs list in one **Channel Tabs** section sorted by "Team › Channel" (shown as each row's second line), not one section per channel. Personal Apps is a single "Browse in Teams on the Web" row (G2). The Advanced disclosure (crop steppers, Measure, Reset) is not built: chrome hiding is still open (see §7.3 as built). Customize Tab Bar… is also on the rail's pinned-item context menu.

### 7.3 In-window hosting and lifecycle

**Ownership.** `FrameHost` (one per account window, `@MainActor`) owns every `WKWebView`, keyed by `FrameKey` (`app:<id>`, `tab:<id>`). SwiftUI shows an app through `FrameContainer(key)`, an `NSViewRepresentable`: `makeNSView` returns an empty `FrameContainerView`; `updateNSView` calls `host.attach(key, to:)`, which first detaches whatever that container shows, and moves a key shown elsewhere (one parent, ever); `dismantleNSView` calls `host.detach(key)`. `FrameContainerView.viewDidMoveToWindow` reports visibility, because a hidden pane child (§5.1) is off-window without being dismantled: in a window → `live`, off-window → `warm`. Eviction may remove a web view from an off-window container; the container re-requests it when it returns to a window. **Detach never destroys**: the same instance returns on the next visit — no reload, no flash, scroll and form state intact (R16). P3a asserts instance identity across detach/attach in a test.

| State | Meaning / entry action |
|---|---|
| `cold` | no web view yet |
| `live` | attached and visible |
| `warm` | detached; WebKit throttles hidden views |
| `suspended` | warm beyond keep-alive → `setAllMediaPlaybackSuspended(true)`, `pauseAllMediaPlayback`, snapshot taken |
| `evicted` | `interactionState` + URL saved, view released |

- **Eviction** (pure `FramePolicy.evict(…)`, unit-tested): LRU cap on non-visible views from Settings ▸ Apps ▸ **Keep apps in memory** (Low 1 / Balanced 3 default / High 6). Keep-alive before suspend: 15 min default (existing `teamsFrameKeepAliveMinutes`; 0 = immediate). Memory pressure (`DispatchSource.makeMemoryPressureSource`): `.warning` evicts suspended views, `.critical` evicts all non-visible views. Restore recreates the view with `interactionState`, showing the last snapshot under a small `ProgressView` until first paint. Settings ▸ Apps lists apps in memory, each with Unload.
- **Data store and SSO:** one persistent `WKWebsiteDataStore(forIdentifier: account.webStoreUUID)` per account, shared by the sign-in sheet and every frame — one sign-in authenticates every app, and accounts stay isolated. One-time migration: the existing `TeamsFrameSSO` Microsoft-cookie filter copies the old `.default()` jar into the account store (5 s timeout gate), then never runs again. Device-code users sign in once inside the frame; the store keeps that session. No `WKProcessPool`.
- **Chrome hiding** (`.teamsHosted` only), in order: (1) a document-start `WKUserScript` inserts a stylesheet hiding the Teams app bar and title bar — selectors live in `FrameChromeStyle.swift` (versioned), initial set derived in P3a with the authenticated `TeamsFrameMeasure` probe; (2) the measure probe verifies after every load; (3) if chrome is still visible, fall back to the geometric crop (`TeamsFrameCrop`, per-app override): `clipsToBounds = true`, web view frame outset by the crop insets. The calibrate overlay is dropped; crop numbers are edited in the app card.
- **Web-app toolbar** (full layout): Back / Forward (⌘[ / ⌘]), Reload/Stop (⌘R / ⌘.); "More" menu = Actual Size ⌘0, Zoom In ⌘+, Zoom Out ⌘−, Find in Page ⌘F, Copy Link, Open in Browser, Unload App, Unpin. Subtitle = page title; determinate `ProgressView` (`estimatedProgress`) only while loading. No URL field, no browser tabs (HIG web views: "Support forward and back navigation"; "Avoid using a web view to build a web browser").
- **Navigation policy** (existing `TeamsFrameConfig.escapeDecision`): main-frame navigation to a non-allowed host is cancelled and opened in the default browser; `target=_blank` to an allowed host loads in place, anything else goes to the default browser.
- **Popups:** `createWebViewWith` from auth hosts (`login.microsoftonline.com`, …) presents the child view in a **sheet** (`WebAuthSheet`, Cancel); `webViewDidClose` dismisses it. The child view is created in `FrameHost.swift` (R16). No popup windows ever.
- **Permissions:** camera/microphone requests denied (calls are native); web-app notification requests ignored.
- **Downloads:** `WKDownload` → `~/Downloads` (`TeamsFrameDownloads.sanitizedFilename`), then listed in Files ▸ Downloads and Transfers.
- **Load failure:** "Couldn't Load ‹App›" (`ContentUnavailableView`) with Retry, Open in Browser, WebKit error as detail.
- **As built (P3a):** `FrameHost` + `FramePage` (per key, `@Observable` load state) + `FrameContainerView` as above; instance identity and LRU pinned by `P3aAppFrameTests`. Deviations: (1) keep-alive suspension and eviction run on attach/detach and memory-pressure events only (R7 bans timers), so a warm view is suspended at the first frame event after 15 min, not exactly at 15 min; (2) a restored view shows the spinner until first paint (no snapshot); (3) the toolbar Reload item does not morph into Stop — Stop Loading is menu-only (View, ⌘.); (4) the More menu's menu-bar twin is View ▸ More ▸ (every toolbar item has a menu item, R19); (5) Unload App returns to the previous section, then releases the view; closing or unpinning an app releases its web view, not its pane child; (6) offline = "You're Offline" pane with Try Again, shown when a load fails with a connectivity error or the window is offline before first paint; (7) web-app commands are owned by `.apps` and forwarded to the web app on screen (every web app is its own `SectionID`); (8) chrome hiding (`FrameChromeStyle`, measure probe, crop fallback) is NOT built — `.teamsHosted` apps show Teams chrome; (9) downloads land in ~/Downloads but are not yet listed in Files (P3c); (10) the keep-in-memory setting is read from `bt.frame.keepInMemory` (Settings pane = P4c).

### 7.4 Sign-in web view

Browser sign-in uses `WebAuthSheet`: a sheet around a `WKWebView` that `FrameHost` creates on the account's data store. Permitted "not otherwise possible" case: the Teams OAuth redirect can't be captured by `ASWebAuthenticationSession` without a custom scheme. Cancel only, no custom chrome.

## 8. Calls

**Decision** (owner, 2026-09-27; §16 DL1): the person chooses where calls appear in Settings ▸ Calls ▸ **Show calls:** **In Main Window** (default) | **In a Separate Window**. The choice applies from the next call; a running call keeps its host (no mid-call move in v1).

**Shared parts.** `CallSession` (one per call, owned by the account's `WindowModel`) owns a `CallStageViewController` — remote tiles in `TileGridLayout`, self view, share tile; audio-only calls show avatars with speaking rings — created once per call and released at call end. Hosts attach and detach it under the `FrameHost` contract: detach never destroys, and video layers are never recreated during a call. Both presentations use the same pre-join view, controls, and inspector.

- **Controls in the toolbar and the Call menu, never a bottom bar** (HIG windows: "Avoid putting critical information or actions in a bottom bar, because people often relocate a window in a way that hides its bottom edge"): Mute (⇧⌘M), Camera (⇧⌘O), Share Screen (⇧⌘E, `SCContentSharingPicker`), Devices (popover: mic/speaker/camera pickers + level meter), People | Chat inspector toggle, **Leave** (⇧⌘H) as the single `.prominent` red-tinted trailing item (HIG toolbars: "Only specify one primary action, and put it on the trailing side of the toolbar"). Title = call name; subtitle = duration.
- **Pre-join:** camera preview, mic level, device pickers, Mic and Camera toggles, **Join Now** (default button).
- **Inspector:** People (roster) | Chat (meeting chat).
- **Full screen:** a window hosting a call keeps its toolbar visible (full-screen presentation options never include `.autoHideToolbar`).

**In Main Window (default).** While a call is pre-joining, ringing, or active, the rail shows the **call item** (`phone.connection.fill`, or `video.fill` for video; label = duration in `.monospacedDigit()`; accessibility "Current call, 12 minutes"), after the pinned and transient apps, never overflowed (§5.2). Selecting it shows `SectionID.call`: layout `.full`, detail = pre-join or stage, inspector = People | Chat, detail and trailing toolbar groups = call controls. Join (Calendar, Calls, notification Accept) selects it and brings the window forward. Moving to another section keeps audio and sharing running; the stage detaches (no picture-in-picture, no floating overlay) and the toolbar call item (status item, §5.4 order) appears: "12:34" with `phone.fill` (green symbol, no background tint); menu = Show Call, Mute/Unmute, Leave. When the call ends while its item is selected, `Navigator` returns to the previous section.

**In a Separate Window.** `CallWindowController` exists only while a call is pre-joining, ringing, or active: an `NSSplitViewController` with the stage and the People | Chat inspector, plus the same toolbar. The main window shows the toolbar call item (status item, §5.4 order); Show Call brings the call window forward. Closing the call window asks "Leave the call?" (`NSAlert`: Leave, Cancel).

**Why both, and why this default.** HIG windows: "Avoid opening new windows as default behavior unless it makes sense for your app" and "Consider providing the option to view content in a new window"; the owner wants in-window integration (§1 item 3). A separate window stays available because "Opening content in a separate window is great for helping people multitask or preserve context" — a call next to a chat, or on another display.

- **Incoming call:** time-sensitive notification, category `CALL`, **Accept** (foreground) + **Decline** (destructive) (HIG managing notifications: "Time Sensitive … happening now"). Rings via `CallNotify` until answered or timed out. When the app is frontmost, `willPresent` still returns banner + sound; no custom ring UI. Accept goes through the core `CallCenter`; the host reacts to call state, whichever lane built the notification.
- **End:** the host detaches and releases the stage; the call window (if any) closes; the rail call item disappears; "Call ended · 12:34" appears in Calls ▸ Recent.
- **As built (P4a), deviations:** (1) Show Call is also the toolbar call item (one command id, custom `NSButton` view: green `phone.fill` + duration, click = Show Call / Mute / Leave menu); Devices is a custom toolbar button so the popover has an anchor. (2) Remote end = the core slot's phase reaching `ended`/`idle` after it was inviting/active for this session (a leftover ended slot never ends the next call); same teardown as Leave without the core end call. (3) Video call start and remote video are not built (no core video call-start or remote-frame path): tiles show avatars with speaking rings; the self view is the local camera (`CameraCapture`), a placeholder feed in demo. Speaking/muted come from the meeting roster feed; 1:1 calls have none. (4) Duration counts from when the session sees the call connect (not the core `started_at`); evidence shows a fixed 12:34 and runs no timer. (5) Mic level uses the core A/V model's 0.6 s level poll (core target, outside R7's UI scope), only while pre-join or the Devices popover shows it. (6) Chat inspector = the meeting chat (read + send); person calls show "No Meeting Chat". (7) Call and Test Call now place live-media legs (`placeLive` / `echoLive`, the old Test Call path) instead of P3b's signaling-only legs. (8) Pre-join Camera defaults off. (9) Not built: incoming-call Accept → call host (P4c notification), Chat ▸ Audio/Video Call, main-window full-screen toolbar rule (shell), "Call ended · 12:34" Recent row (history store, unverified live). Demo `CallSettings` uses `MemoryDefaults`.

## 9. Menus, notifications, presentations, Settings

### 9.1 Menu bar

HIG the menu bar: standard menu order; unavailable items disabled, never hidden; Show/Hide titles reflect state. All menus are built from `CommandCatalog`.

| Menu | Items (`·` = separator) |
|---|---|
| Better Teams | About · Settings… ⌘,, Status ▸ (presence, Presence Schedule…), Add Account…, Sign In Again…, Sign Out… (app-level items after Settings in one group, per HIG the menu bar) · Services · Hide ⌘H, Hide Others ⌥⌘H, Show All · Quit ⌘Q |
| File | New Chat ⌘N, New Meeting…, Join Meeting…, New Call… · Open Account in New Window ▸ · Upload File… ⌘U, Export Chat Archive… · Close Window ⌘W |
| Edit | standard editing items · Find ▸ (Search ⌥⌘F, Find in Conversation ⌘F, Find Next ⌘G, Find Previous ⇧⌘G, Use Selection for Find ⌘E) · Spelling and Grammar · Substitutions · Emoji & Symbols |
| View | Show/Hide Toolbar ⌥⌘T, Show/Hide Inspector ⌥⌘I, Customize Tab Bar… · Chat ⌥⌘1, Files ⌥⌘2, Notes ⌥⌘3 · Agenda/Week · Actual Size ⌘0, Zoom In ⌘+, Zoom Out ⌘− · Reload Page ⌘R, Stop ⌘. · Enter Full Screen ⌃⌘F |
| Go | Activity ⌘1 … Files ⌘6, pinned apps ⌘7–⌘9 (dynamic titles), Apps · Go To… ⌘K, Next Unread Chat ⌥⌘↓, Previous Unread Chat ⌥⌘↑ · Back ⌘[, Forward ⌘] (web apps) |
| Conversation | Reply, Forward…, React ▸, Save, Pin, Translate, Mark as Unread ⇧⌘U, Mute, Snooze ▸, Notifications ▸, Catch Up · Leave Chat… |
| Call | Start Audio Call, Start Video Call, Show Call, Mute ⇧⌘M, Camera ⇧⌘O, Share Screen… ⇧⌘E, Show/Hide People, Show/Hide Chat, Leave Call ⇧⌘H · Test Call |
| Window | Minimize ⌘M, Zoom · Bring All to Front · window list (the call window appears here when open) |
| Help | Better Teams Help, Keyboard Shortcuts |

⌘+ / ⌘− / ⌘0 control page zoom in web apps and **text size** everywhere else (§10).

### 9.2 Dock menu and menu bar extra

- **Dock menu** (`applicationDockMenu`): New Chat, Set Status ▸, up to five unread chats.
- **Menu bar extra:** Settings ▸ General ▸ "Show in menu bar", **off by default** (HIG the menu bar: "Let people — not your app — decide"). `NSStatusItem` with `bubble.left.and.bubble.right`, plus a dot when unread. It opens an **NSMenu, not a popover** ("Display a menu — not a popover"): Presence ▸, up to five unread chats, New Chat, Open Better Teams, Quit.

### 9.3 Notifications

HIG notifications. Categories: `MESSAGE` (Reply with text input, Mark as Read) · `CALL` (Accept, Decline) · `MEETING` (Join; meeting starts within 5 min).

- **Threading:** thread identifier = chat ID. **Communication notifications** for messages (sender avatar via `INSendMessageIntent`) when the entitlement exists; otherwise the active level.
- **Dock badge:** unread chats + unread channel mentions, never raw message counts ("Use a badge only to show people how many unread notifications they have").
- **Foreground:** no banner for the conversation on screen; other chats bump rail badges; banners while active are opt-in (General); calls always banner.
- The rules engine (`ChatFilter`, `NotifyRule`, quiet hours, Focus sync, keyword and mention alerts) keeps running unchanged in the background.

### 9.4 Settings window

`SettingsWindowController` hosts an `NSTabViewController` with `tabStyle = .toolbar`: non-customizable toolbar of labeled panes (HIG settings). Window title follows the pane; last pane restored; minimize and zoom disabled. Each pane is a `Hosting` controller (R22) around `Form { … }.formStyle(.grouped)`; changes apply immediately.

| Pane (symbol) | Contents |
|---|---|
| General (`gearshape`) | launch at login · menu bar extra · Dock badge · banners while active · default section |
| Accounts (`person.crop.circle`) | accounts (add, remove, sign out, reorder) · per-account web data (Sign in to web apps, Clear website data) |
| Notifications (`bell.badge`) | enable/sounds · mention and keyword alerts (allow/block lists) · per-chat levels · quiet hours · Focus sync · presence schedule |
| Chats (`bubble.left`) | Return-to-send · density · text size · translation language · templates (List + edit sheet) · scheduled messages · read receipts and typing (ghost mode) · blocked people · quick composer (enable, hotkey recorder) · GIF key (Keychain) |
| Calls (`video`) | **Show calls: In Main Window / In a Separate Window** (radio group, default In Main Window; footnote "Applies to your next call") · mic/speaker/camera pickers · level meter · camera preview · Test Call |
| Apps (`square.grid.2x2`) | keep in memory (Low/Balanced/High) · suspend after 0/5/15/30/60 min · apps in memory with Unload · downloads folder · reset crops · refresh library |
| AI (`sparkles`) | catch-up provider (on-device, OpenCode CLI, OpenAI-compatible) · keys (Keychain) · availability |
| Advanced (`wrench.and.screwdriver`) | diagnostics/health · MCP status · export archive · rebuild offline index · reset caches · logs folder |

- **As built (P4c), deviations:** (1) Category ids keep the core's names (`OM_MESSAGE`/`OM_MENTION`, `OM_CALL`, new `OM_MEETING`); MESSAGE keeps Open chat beside Reply and Mark as Read. (2) CALL stays interruption level `.active` (core gap-g4: Focus decides), not Time Sensitive; MEETING is Time Sensitive. (3) Foreground "conversation on screen" = the conversation open in the core (`openChatID`). (4) Dock badge = the rail's Chat + Teams badges, so a muted chat marked unread counts (rail parity). (5) Not built, no store or accessor yet: Accounts add/reorder and Sign in to web apps; Notifications mention toggles (per-chat levels list only chats set to Mentions/Muted; quiet hours edits schedule 1's times; presence schedule entries read-only); Apps "apps in memory with Unload", downloads folder, reset crops (need a `FrameHost` accessor); Advanced rebuild offline index, reset caches, logs folder; communication notifications (`INSendMessageIntent`). (6) Templates edit inline under the list, not in a sheet (Settings has no `WindowModel` sheet host, R23). (7) Default section applies when a window has no saved state.
- **As built (SETGAPS), closes P4c (5) except as noted:** Accounts: Add Account… (also the account menu) signs a fresh profile in through a sheet on the main window with an ephemeral web store; drag reorder (`AccountStore.move`); Sign In to Web Apps… opens Teams on the web in the account's `FrameHost` store and closes when `/v2` loads. Notifications: Mention Alerts switches (channel/team/everyone mentions in Mentions chats, name backup) edit the core switch rules; message banners carry the sender and post as `INSendMessageIntent` communication notifications with the monogram avatar, which only takes effect once the app is signed with the communication-notifications entitlement (not added: restricted entitlement, needs a provisioning profile). Apps: apps in memory with Unload (the one on screen shows "On screen"), downloads folder, Hide the Teams header and app bar (`FrameChromeStyle` v1, document-start sheet, Teams-hosted pages only), per-app crop Left/Top for pinned Teams-hosted apps and Reset Crops — in Settings, not the app card; the measure probe is not run after loads. Advanced: Rebuild Index… and Reset Caches… (NSAlert; media cache + web-app disk/memory/fetch caches), Open Logs Folder (`~/Library/Logs/Better Teams`, writes this session's unified-log entries first). All maintenance is disabled and a no-op in demo.

### 9.5 Sheets, popovers, alerts

Per HIG sheets and HIG popovers:

- **Sheet = scoped multi-field task:** New Chat, New Call, Create Team, Create Channel, Join a Team, New Meeting, Join with ID, Forward, Rename, Move/Copy To, scheduled queue, Customize Tab Bar, Manage Folders, Add Web Link, Snooze Custom, Edit Template, web sign-in/auth. One presenter (`SheetPresenter`, `presentAsSheet`); requests are `SheetRequest` values declared in each section's folder (§11.3); a request while a sheet is up is refused and logged, never stacked ("Display only one sheet at a time"). Buttons: Cancel + a default action, never a lone Done.
- **Popover = transient picker anchored to its control:** reactions More…, GIF search, @-mentions, Send Later, Transfers, call Devices. Work is kept when a popover auto-closes ("Always save work when automatically closing a nonmodal popover").
- **Alert (`NSAlert`) = destructive confirmation or blocking error:** Delete message/file, Leave chat, Block, Remove account, Sign out, Cancel meeting, Leave the call (closing the call window). Warnings never go in popovers.
- **Menu = choosing among options:** filters, snooze presets, notification levels, presence.

## 10. Accessibility, appearance, text size

Per HIG accessibility and HIG typography:

- **Labels:** every icon-only control has an `accessibilityLabel` and `.help`. Custom rows combine into one element and expose their context actions as accessibility actions.
- **Contrast:** semantic colors (R14) give Increase Contrast and Dark Mode for free. Text meets 4.5:1 (≤17 pt) in both appearances; a unit test contrast-checks the `Palette.swift` colors in both.
- **Never color alone:** presence = shape + color; unread = weight + dot + badge; missed calls = symbol + the word "Missed".
- **Text size:** HIG typography: "macOS doesn't support Dynamic Type", while HIG accessibility asks to "enlarge text by at least 200 percent". So: a `ContentTextScale` environment value (1.0 / 1.15 / 1.3 / 1.5 / 1.75 / 2.0), driven by View ▸ Actual Size / Zoom In / Zoom Out and Settings ▸ Chats ▸ Text Size, scales `AppFont` text styles in lists, timeline, and composer. Base sizes follow the macOS text-style table (Body 13, Headline 13 bold, Subheadline 11, Caption 10, Title3 15); nothing below 10 pt. The rail follows the system sidebar icon size instead.
- **Motion:** under Reduce Motion, static highlights and no scale/zoom transitions. Reduce Transparency and Increase Contrast are handled by the unmodified system materials.
- **Keyboard:** Full Keyboard Access via stock controls; arrows move in lists, Return opens; ⌥⌘↓/↑ jump between unread chats; Esc exits search and closes popovers and sheets.
- **Focus rings** (owner order; R10, D3). HIG focus and selection: "In general, use a focus ring for a text or search field, but use a highlight in a list or collection", and in macOS "you only need to support focus for content elements like list items, text fields, and search fields, and not for controls like buttons" (buttons take focus only when the person turns on keyboard navigation).
  - **Suppressed — the drawn ring, wherever we own the view:** SwiftUI via `.focusEffectDisabled()` at every hosting root (R22); AppKit views we create — timeline table, `Shared/SearchField`, the toolbar `NSSearchToolbarItem.searchField`, `AVPlayerView`, the web container — via `focusRingType = .none`.
  - **Kept, fully working:** keyboard focus and first responder; Tab / ⇧Tab traversal and Full Keyboard Access; arrows, Return, and Space in lists and tables; the text insertion point; the VoiceOver cursor (drawn by VoiceOver, unaffected); list and table selection emphasis — accent highlight while the list has focus, gray otherwise — which is the HIG's macOS focus appearance for lists, so it is not a ring and stays.
  - **Replacement cue:** a rail button focused through keyboard navigation or Full Keyboard Access shows its hover fill (§5.2). Text and search fields rely on the insertion point.
  - **Not covered (stated, not an oversight):** rings the system draws on toolbar items and menus under Full Keyboard Access (removing them needs custom chrome, banned by R1/R2; they appear only with keyboard navigation turned on), and focus outlines inside hosted web pages (the web app's own UI).
- **Light and dark** are both first-class; every screen needs evidence in both (§11.4).

## 11. Code architecture

### 11.1 Targets (after P0)

| Target | Kind | Contents |
|---|---|---|
| `COstMac` | C | FFI header (unchanged) |
| `OstMacCore` | library | all non-view logic, including the former `OstMacChatList` files and `AppState.swift` (moved, not renamed) |
| `BetterTeamsUI` | library, new | every view, controller, window; depends on `OstMacCore`, `COstMac` |
| `OstMac` | executable | `@main` `AppDelegate` shim that starts `BetterTeamsUI` |
| `OstMacMCP`, `ostmac-mcp` | unchanged | |
| `BetterTeamsUITests` | tests, new | pure logic only: `TimelineSnapshot`, `ScrollAnchor`, `RowHeightCache` keying, `ToolbarModel`, rail capacity and minimum height, `Navigator` (synchronous apply), `CommandCatalog` (unique key equivalents; every toolbar command has a menu item), `FramePolicy`, `Route`, `WeekGridLayout`, `TileGridLayout`, palette contrast |

`OstMacChatList` is deleted once its files have moved.

### 11.2 File plan (`swift/Sources/BetterTeamsUI/`)

| Folder | Files |
|---|---|
| `App/` | AppDelegate, MainMenu, CommandCatalog, DockMenu, StatusItemController, Notifications (all categories and actions), QuickComposerPanel, LaunchOptions |
| `Shell/` | ShellWindowController, ShellSplitViewController, PaneContainerViewController, ShellToolbarController, ToolbarModel, WindowModel, NavigationModel, Navigator, Route, SectionLayout, SheetPresenter |
| `Rail/` | RailView, RailButtonStyle, RailModel, CustomizeTabBarSheet |
| `Sections/<Name>/` | one folder each for Activity, Chat, Teams, Calendar, Calls, Files, Apps, Planner, ToDo, Shifts, Recaps, OneNote: `<Name>Section.swift` (`SectionProvider`) + its list, detail, inspector, rows, sheets |
| `Conversation/` | ConversationDetail, ConversationHeader, Composer, ComposerPopovers, ConversationInspector |
| `Timeline/` | TimelineViewController, TimelineDataSource, TimelineSnapshot, ScrollAnchor, RowHeightCache, MessageRowView, MessageContextMenu, AttachmentViews |
| `Frame/` | FrameHost, FrameContainer, FrameContainerView, FramePolicy, FrameChromeStyle, WebAuthSheet, FrameDownloads, WebAppSection (the one `SectionProvider` for every web app) |
| `Search/` | SearchModel, SearchResultsList, Debounce |
| `Call/` | CallPresentation (setting), CallSession, CallStageViewController, TileGridLayout, VideoTileView, PreJoinView, CallInspector, CallSection (main-window `SectionProvider`), CallWindowController |
| `Auth/` | SignInViewController, DeviceCodeView |
| `Settings/` | SettingsWindowController + one file per pane |
| `Shared/` | Hosting (R22), SearchField, Avatar, PresenceBadge, Palette, AppFont, StateViews, RelativeTime |
| `Evidence/` | EvidenceHarness, EvidenceControlView |

### 11.3 State model and store binding

- **`WindowModel`** (`@Observable @MainActor`, one per window): `graph: AccountGraph` (`AppState` or an account-window graph), `nav: NavigationModel`, `rail: RailModel`, `search: SearchModel`, `frameHost: FrameHost`, `call: CallSession?`, `sheet: SheetRequest?`.
- **`NavigationModel`** (`@Observable`, `private(set)`): `section: SectionID` (`.activity`, `.chat`, `.teams`, `.calendar`, `.calls`, `.files`, `.apps`, `.native(NativeAppID)`, `.web(FrameApp.ID)`, `.call`), `previousSection`, `selection: [SectionID: SectionSelection]`, `detailTab: [ConversationRef: ConversationTab]`, `inspectorVisible: [SectionID: Bool]`, `search: SearchState?` (query, scope, and the exact state to restore). P1 declares every case, including all `NativeAppID`s (planner, todo, shifts, recaps, onenote), so no later lane edits these enums.
- **`Navigator`** (`@MainActor`, one per window) is the only writer (R21): `apply(_ route: Route)`, `select(section:)`, `select(_ selection:, in:)`, `setDetailTab`, `beginSearch`/`endSearch`, `inspectorDidChange`. Each call applies the AppKit side before returning.
- **`Route`** = one grammar for deep links (`betterteams://`), launch flags, and evidence; first modifier takes `?`, later ones `&`. Examples: `chat/<id>`, `chat/<id>?tab=files&message=<mid>`, `teams/<team>/<channel>?tab=posts&thread=<mid>`, `calendar?view=week`, `files/recent`, `apps/<appID>`, `app/<appID>`, `call?state=prejoin|active&presentation=main|window`, `search?q=<q>&scope=all|messages|people|files`, `settings/<pane>`, `signin?state=code`. Modifiers: `state=empty|loading|error`, `inspector=1|<segment>`; evidence-only (honored only with `--demo`): `sheet=<name>`, `popover=<name>`, `call=prejoin|active` + `presentation=main|window` (a demo call behind any route), `pins=<n>` (seed n demo web apps), `connection=offline|expired` (§5.7 status item). `Route` parsing is generic (path segments + query); each provider interprets its own segments.
- **Domain state stays in the existing `ObservableObject` stores.** Section roots receive their stores as `@ObservedObject` init parameters; UI models never mirror store fields (R3). Only UI-only state is `@Observable`.

```swift
@MainActor protocol SectionProvider {
    func layout(_ sel: SectionSelection?) -> SectionLayout
    func listPane(_ m: WindowModel) -> AnyView
    func detailPane(_ m: WindowModel) -> AnyView
    func inspector(_ m: WindowModel) -> AnyView?
    var allToolbarItems: [CommandID] { get }                 // this section's share of the fixed superset (§5.4)
    func toolbarItems(_ sel: SectionSelection?) -> [CommandID] // visible subset
    func perform(_ c: CommandID, arg: String?, _ m: WindowModel) -> Bool
    func validate(_ c: CommandID, arg: String?, _ m: WindowModel) -> CommandValidation // enabled + title
    func submenuItems(_ c: CommandID, _ m: WindowModel) -> [SubmenuItem] // dynamic menus (Filter, Status)
    func selection(for route: Route) -> SectionSelection?
    func selectionDidChange(_ sel: SectionSelection?, _ m: WindowModel) // loads start here (R24)
    // also: section, title, subtitle(_:), sheet(_:_:), badge(_:) — see Shell/SectionLayout.swift
}
```

P1 writes the `SectionID` → provider switch once; later lanes replace only their own provider folders, which is what makes parallel lanes merge-safe.

**Cross-lane seams** (P1 creates them so no lane edits another lane's folder). In the owning lane's folder, with final signatures and a `ContentUnavailableView` body naming the owning lane: `FileTable(scope:)` (`Sections/Files`, P3c), `NotesTab(scope:)` (`Sections/OneNote`, P4b), `FrameContainer(key:)` (`Frame/`, P3a), `CallPresentation` + `CallSession.show()` (`Call/`, P4a). In every section folder: `<Name>Commands.swift` (empty), the section's `SheetRequest`/popover names, and route interpretation. `CommandID` is a string-backed struct, so each section declares its own commands; `CommandCatalog` aggregates the per-section lists P1 wires once; menu placement is data on each command. Consumers call the seam; the owner replaces the body without changing the signature.

- **Demo mode:** `--demo` builds the graph from `DemoData`, `PlannerDemo`, `RecordingsDemo`, `TranscriptsDemo`, `MeetingDemo`, and the store `seedDemo` functions. `state=` forces empty/loading/error per section. Demo web apps use `loadHTMLString` with a bundled page (no network). Evidence uses fixed demo aliases defined in `Evidence/` (P1): `demo-rich` (chat with code, card, image, reactions, reply), `demo-msg-40` (a message inside it), `demo-team`, `demo-channel`, `demo-thread`, `demo-meeting`, `demo-person`, `demo-file`, `web-demo`.
- **Lint and tests:** `scripts/ui-lint.sh` implements every [lint] rule (P0) and every [lint+] rule (P1). Each lane adds tests only for the pure functions it introduces.

### 11.4 Visual-evidence harness

- **App flags:** `--demo` (required), `--route <route>`, `--appearance light|dark`, `--window-size 1280x820`, `--evidence`. Capture refuses to run without `--demo`, so live account data can never be captured. `--evidence` pins the relative-time clock to the demo epoch and renders highlight fades static, so captures are deterministic.
- **Settle signal:** the app prints `EVIDENCE READY route=<r> appearance=<a> windowID=<n> settled=true` (`windowID` = the route's primary window: the call window for `presentation=window` call routes, else the main window) once (1) every store on the route reports non-loading, (2) `window.displayIfNeeded()` has run, and (3) two run-loop turns pass with no pending layout; after a 10 s hard cap it prints `settled=false`. The window stays frontmost at a fixed origin on the main screen until killed, because occluded windows may not paint (FRAME-LIVE-PROOF gap 3).
- **`scripts/ui-shot.sh <route> <light|dark> <out.png>`:** launch the release bundle from `scripts/build-app.sh` (notifications and screen capture need a bundle) with the flags above, through LaunchServices (`open -n`), not exec, so the window can activate (a background shell's child is never made active and captures inactive) → wait for READY → `screencapture -l<windowID> -o -x <out.png>` → reject captures under 20 KB or of a single color (`sips`) → quit. `screencapture`, not `cacheDisplay`, because `cacheDisplay` cannot see WKWebView content or Liquid Glass. The script resolves `APP=` through symlinks (`cd -P`; `.build/release` is a symlink to `.build/out/Products/Release`) and finds the new process as the bundle-ID (`lsappinfo`) or resolved-executable (`pgrep`) PID that was not running before `open`, so any spelling of the bundle path works (fixed after P1.1). With the screen locked no app activates, so chrome draws inactive; SwiftUI content under `--evidence` renders with key appearance (`controlActiveState`), but rail selection tint and key-window look need a live check.
- **Positive control:** route `evidence/control` renders a fixed test card; run it once per session before believing any blank or odd capture.
- **Output:** `tmp/evidence/<lane>/<route>-<appearance>.png`, never committed.

## 12. Phased implementation plan (max 3 concurrent lanes)

**Every lane must:** build green (`swift build -c release`); pass `scripts/ui-lint.sh` with 0 hits; pass its new pure-logic tests; capture its evidence routes in **light + dark** at 1280×820, plus 900×600 where marked (min); claim its files per the repo claim protocol and edit only files it owns, reaching other lanes only through the §11.3 seams. Owner visual approval gates P1 and each group before the next starts.

**Testing cap** (every lane except P0, which follows its own brief): ≤4 release builds; lint after each build; ≤2 runs of the lane's own test classes (`swift test --filter`), never the full suite (P5 only: one full run); evidence = each route captured once per appearance + 1 positive control per session, ≤1 retake per failed route, no other screenshots. The Cap column gives the capture count. The same symptom surviving 3 build-run cycles → stop and report.

| Lane | Scope (owned files) | Deps | Acceptance | Evidence routes (× light/dark) | Cap (captures) |
|---|---|---|---|---|---|
| **P0 Core consolidation — MERGED (`e8140f7`)** | Package.swift (tools 6.2, macOS 26, new targets); move `OstMacChatList/*` + `AppState.swift` into `OstMacCore`; `AccountGraph`; delete `OstMacChatList`; `scripts/ui-lint.sh`; `BetterTeamsUI` + tests skeleton | — | scoped core + MCP tests green; `--demo --coldstart-quit` exits cleanly; new tools/platform warnings listed, not silenced | none | per its brief |
| **P1 Shell + tab bar + Chat** | App/ (except DockMenu, StatusItemController, Notifications, QuickComposerPanel), Shell/, Rail/, Timeline/ (read + send, `RowHeightCache`, jump API with highlight), Conversation/ (header, tab shell wired to the Files/Notes seams, text-only composer), Sections/Chat, Auth/, Shared/, Evidence/, `swift/OstMac-Info.plist` (`LSMinimumSystemVersion` 26.0), `Frame/FrameHost.swift` + `Frame/WebAuthSheet.swift` (per-account data store and sign-in web view only), search-mode plumbing (field, enter/exit, exact restore; empty results list), `scripts/ui-shot.sh`, the [lint+] patterns; placeholder providers and all §11.3 seams | P0 | ⌘1–⌘9 work; `Navigator` test: after `select(section: .web(x))` returns, collapse, pane child, toolbar visibility, and title are already applied; `CommandCatalog` test; `ScrollAnchor` + `RowHeightCache` tests; ui-shot + positive control work; §4 checks recorded in this spec; owner rail checkpoint (§5.1) | `signin`, `signin?state=code`, `chat/demo-rich`, `chat/demo-rich` (min), `chat?state=empty`, `chat?state=error`, `chat/demo-rich?inspector=1` | 7 routes → 15 |
| **P2a Conversation complete** | Conversation/ (composer: mentions, attach, GIF, templates, Send Later + queue; Catch Up + Pinned inspector), Timeline/ row files (`MessageRowView` content types and send states, `MessageContextMenu`, `AttachmentViews`), receipts, typing | P1 | every §6.2 action works in demo; R17 holds; composer paste/IME check recorded (§6.2.2) | `chat/demo-rich`, `chat/demo-rich?popover=mention`, `chat/demo-rich?inspector=catchup`, `chat/demo-rich?sheet=forward`, `chat/demo-rich?sheet=scheduled` | 5 → 11 |
| **P2b Activity + Search** | Sections/Activity, Search/ (results, scopes, recents); uses P1's jump API and search plumbing without editing Shell/ or Timeline/ | P1 | a hit lands on the exact row; a miss shows the notice; Esc restores the exact prior state | `activity`, `activity?state=empty`, `search?q=design&scope=all`, `search?q=spec&scope=files`, `chat/demo-rich?message=demo-msg-40` | 5 → 11 |
| **P2c Teams** | Sections/Teams (outline, channel view, thread inspector, roster, create/join sheets; wires the `FrameContainer`/`FileTable`/`NotesTab` seams), `Timeline/TimelineSnapshot.swift` (post grouping) | P1 | `reply_to` probe result recorded; web, Files, and Notes tabs show their owning lane's placeholder | `teams`, `teams/demo-team/demo-channel?tab=posts&thread=demo-thread`, `teams?sheet=createTeam`, `teams/demo-team?inspector=1` | 4 → 9 |
| **P3a App frame + Library** | Frame/ (all), Sections/Apps, Rail/ (pin, transient, More, Customize sheet), web-app toolbar commands, SSO migration | P1, P2c | `FramePolicy` tests (launch, LRU, pressure); instance identity across detach/attach; R16 lint; channel web tabs go live with no edit outside Frame/ | `apps`, `apps/web-demo`, `app/web-demo`, `app/web-demo?pins=8` (min), `apps?sheet=customizeTabBar`, `app/web-demo?state=error`; as built also `apps?state=loading\|error\|empty`, `apps/web-demo-status`, `apps?sheet=addWebLink`, `app/web-demo-1?pins=6` (pinned), `app/web-demo?state=loading`, `app/web-demo?connection=offline`, `app/web-demo?find=1` (list in `scripts/ui-shot.sh`) | 6 → 13 |
| **P3b Calendar + Calls** | Sections/Calendar (agenda, detail, week grid, sheets), Sections/Calls (Current-call row calls `CallSession.show()`) | P1 | `WeekGridLayout` overlap tests | `calendar`, `calendar?view=week`, `calendar/demo-meeting`, `calendar?sheet=newMeeting`, `calls`, `calls/demo-person` | 6 → 13 |
| **P3c Files** | Sections/Files (`FileTable` body, sources, Transfers, Quick Look, versions) | P1 | sort, resize, multi-select; drop-to-upload in demo; conversation and channel Files tabs show real tables with no edit outside Sections/Files | `files/recent`, `files/shared`, `files/recent/demo-file?inspector=1`, `files/recent?popover=transfers`, `chat/demo-rich?tab=files` | 5 → 11 |
| **P4a Calls, both presentations** | Call/ (all: `CallSession`, stage, pre-join, controls, devices, People/Chat inspector, `CallSection`, `CallWindowController`), Rail/ call item | P3b | Leave ends the call in both modes; the separate window's close asks to leave; leaving and re-selecting the rail call item reuses the same `CallStageViewController` (test); the call items never shift pane content | `call?state=prejoin&presentation=main`, `call?state=prejoin&presentation=window`, `call?state=active&presentation=main&inspector=1`, `call?state=active&presentation=window&inspector=1`, `chat/demo-rich?call=active&presentation=main`, `chat/demo-rich?call=active&presentation=window` | 6 → 13 |
| **P4b Native apps** | Sections/Planner, ToDo, Shifts, Recaps, OneNote (incl. the `NotesTab` body); already listed as built-ins through `NativeAppID` | P3a | each pins, unpins, and opens like Files; Notes tabs work with no edit outside these folders | `app/planner`, `app/todo`, `app/shifts`, `app/recaps`, `app/onenote`, each also with `?state=empty` | 10 → 21 |
| **P4c Settings + system** | Settings/ (8 panes, incl. Calls ▸ Show calls via the `CallPresentation` seam), App/DockMenu, App/StatusItemController, App/Notifications (MESSAGE, CALL, MEETING categories; actions go to core stores and `CallCenter`), App/QuickComposerPanel | P1 (Apps pane after P3a) | last pane restored; title follows pane; extra off by default; unit test of Dock and status menu contents | `settings/general`, `settings/accounts`, `settings/notifications`, `settings/chats`, `settings/calls`, `settings/apps`, `settings/ai`, `settings/advanced` | 8 → 17 |
| **P5 Integration + audit** | full route matrix; VoiceOver label audit; keyboard map vs §9.1; Full Keyboard Access pass (every control reachable, rail focus cue); live frame memory check (4 apps: evict, then restore); idle CPU with every section visited (§14 risk 9); §13 review | all | lint 0; matrix complete; owner approval | full matrix (~80 routes) | 1 full test run; matrix once + ≤1 retake round |

**Order and parallel groups:** P0 → P1 → owner checkpoint → **Group A** P2a ∥ P2b ∥ P2c → **Group B** P3a ∥ P3b ∥ P3c → **Group C** P4a ∥ P4b ∥ P4c → P5. Within a group no two lanes own the same file; ownership passes only between groups.

## 13. HIG deviation register

| # | Deviation | Reason |
|---|---|---|
| D1 | Vertical symbol-over-label tab bar on macOS (HIG tab bars has no macOS-specific form) | Owner requirement (Teams navigation). Built from stock buttons in the system sidebar slot; visionOS vertical tab bar precedent. |
| D2 | ⇧⌘M / ⇧⌘O / ⇧⌘E / ⇧⌘H add Shift to unrelated standard shortcuts, and ⇧⌘U (Mark as Unread) adds Shift to ⌘U (HIG keyboards: "Avoid creating a new shortcut by adding a modifier to an existing shortcut for an unrelated command") | Call keys: Microsoft Teams parity for time-critical call control, confined to the Call menu. ⇧⌘U: Mail's Mark as Unread precedent. |
| D3 | No focus ring on text and search fields or on controls we own under Full Keyboard Access (HIG focus and selection: "use a focus ring for a text or search field") | Standing owner order `bb177ae`. Lists keep the HIG highlight; focus, traversal, VoiceOver, and the insertion point are untouched; rail buttons show a hover-fill cue (§10). Revisit if keyboard users report problems. |
| D4 | ⌘[ / ⌘] as Back/Forward (HIG keyboards lists them as text alignment) | The app has no text alignment; Safari/Finder precedent; web apps only. |
| D5 | No toolbar customization in v1 (HIG toolbars: "consider letting people customize the toolbar") | The toolbar is a pure function of section state. Revisit after P5. |
| D6 | ⌘U = Upload File… (HIG keyboards: ⌘U is Underline) | HIG allows redefining a standard shortcut "if its action doesn't make sense in your experience"; the app has no text styling. |

## 14. Core gaps and risks

**Gaps** (the UI degrades gracefully until the core adds each):

| # | Gap | UI consequence until fixed |
|---|---|---|
| G1 | Library shells out to a bundled `teams-cli tabs-all` (`swift/Sources/OstMacCore/TeamsFrame.swift:425`) and falls back to `/usr/local/bin`/PATH lookup (`:397-398`) — binary-hijack risk. Needs an `ostmac_tabs_all` FFI; the header only has per-channel `ostmac_tabs` (`ostmac_core.h:64`). | Library keeps using the subprocess |
| G2 | No installed/personal Teams apps API (Graph `installedApps`). | "Personal Apps" shows only "Browse in Teams on the Web" |
| G3 | `ostmac_presence_set` (`ostmac_core.h:343-346`) has no Be Right Back and no status message. | Account menu omits both |
| G4 | `MeetingItem` (`Models.swift:560` at `7f6baec`) has no attendees or RSVP; no accept/decline FFI. | Meeting detail shows the organizer only |
| G5 | **Closed (core-a):** `ostmac_chat_create_group` (`ostmac_core.h:131`) via `AppState.openNewChat(people:topic:)`. | New Chat with two or more people starts a group chat (optional Group Name) |
| G6 | No user-photo FFI. | Avatars are monograms |
| G7 | No create-folder call among `ostmac_files_*`. | Files has no New Folder |
| G8 | `TeamsFrameStore` (`TeamsFrame.swift:633`) models one web view, one pool, one selected app. | P3a replaces it with `FrameHost`, keeping the pure `TeamsFrame*` helpers |

**Risks:**

1. **Rail slot width:** 80 pt slot vs the window-button width on macOS 26/27. Checked in P1 (§4 check 3); widen if needed, never move the buttons.
2. **Global core profile:** the Rust core serves one active profile globally (`AccountCoreRunner.swift:1-14`). Two busy account windows flip the profile on every call, which may serialize or race.
3. **Notification entitlements:** time-sensitive and communication notifications need entitlements an ad-hoc-signed build may lack. Fallback: the active level.
4. **Teams web chrome selectors** change without notice. The CSS → measure → crop chain limits damage, but crop numbers are still unmeasured behind the login wall (FRAME-LIVE-PROOF).
5. **D3** (no focus rings): mitigated by §10 (focus, traversal, VoiceOver, list highlight, and insertion point intact); the residual gap is Full Keyboard Access users on text fields and toolbar-adjacent controls we own.
6. **Evidence capture:** `screencapture` needs Screen Recording permission for the agent's terminal. The harness forces the window frontmost; the positive control exposes a blind capture path.
7. **Toolchain move:** tools 6.2 / macOS 26 may raise new warnings in core targets. P0 lists them rather than silencing them.
8. **Rail look:** the macOS 26 sidebar slot renders as a floating glass panel, the same container Mail uses. The owner may read it as "the Mail sidebar" despite the tab-button content; the P1 checkpoint (§5.1) decides, and the fallback is one line.
9. **Hidden pane children** (§5.1) keep observing their stores while off-window. P5 measures idle CPU with every section visited; if material, children beyond the four most recent are released (their state then restores from `NavigationModel` only).
10. **Call video re-parenting** (main-window mode): the stage detaches and re-attaches within one window during navigation. `AVSampleBufferDisplayLayer` keeps its layer tree when its view moves; P4a's instance test covers identity, not visual continuity, which the owner judges from the P4a evidence.

## 15. HIG pages cited

Quotes from pages marked ✓ were re-verified verbatim against the HIG JSON on 2026-09-27; the others were not re-checked in that pass.

- Windows ✓ — https://developer.apple.com/design/human-interface-guidelines/windows (R1, §5.7, §8)
- Materials ✓ — https://developer.apple.com/design/human-interface-guidelines/materials (R15, §5.1)
- Toolbars ✓ — https://developer.apple.com/design/human-interface-guidelines/toolbars (R19, §5.4, §8, D5)
- Split views ✓ — https://developer.apple.com/design/human-interface-guidelines/split-views (§4, §6)
- Tab bars ✓ — https://developer.apple.com/design/human-interface-guidelines/tab-bars (§5.1, §5.2, §5.3, D1)
- Sidebars ✓ — https://developer.apple.com/design/human-interface-guidelines/sidebars (§5.2)
- Search fields ✓ — https://developer.apple.com/design/human-interface-guidelines/search-fields (§5.4, §5.5, §7.2)
- Keyboards ✓ — https://developer.apple.com/design/human-interface-guidelines/keyboards (§5.5, §6.4, D2, D4, D6)
- Focus and selection ✓ — https://developer.apple.com/design/human-interface-guidelines/focus-and-selection (§10, D3)
- The menu bar ✓ — https://developer.apple.com/design/human-interface-guidelines/the-menu-bar (§9.1, §9.2)
- Accessibility ✓ — https://developer.apple.com/design/human-interface-guidelines/accessibility (§5.2, §6, §10)
- Typography ✓ — https://developer.apple.com/design/human-interface-guidelines/typography (§10)
- Panels — https://developer.apple.com/design/human-interface-guidelines/panels (§5.6)
- Context menus — https://developer.apple.com/design/human-interface-guidelines/context-menus (§6)
- Tab views — https://developer.apple.com/design/human-interface-guidelines/tab-views (§6.2)
- Lists and tables — https://developer.apple.com/design/human-interface-guidelines/lists-and-tables (§6.6)
- Web views — https://developer.apple.com/design/human-interface-guidelines/web-views (§7.3)
- Managing notifications — https://developer.apple.com/design/human-interface-guidelines/managing-notifications (§8)
- Notifications — https://developer.apple.com/design/human-interface-guidelines/notifications (§9.3)
- Settings — https://developer.apple.com/design/human-interface-guidelines/settings (§9.4)
- Sheets — https://developer.apple.com/design/human-interface-guidelines/sheets (§9.5)
- Popovers — https://developer.apple.com/design/human-interface-guidelines/popovers (§9.5)

## 16. Decisions log

Review pass of 2026-09-27. Each entry: decision — why.

- **DL1 Calls: both presentations, default In Main Window.** Owner decision (relayed 2026-09-27): "allow the user to chose in settings for the call in window or new window". Default follows HIG windows ("Avoid opening new windows as default behavior unless it makes sense for your app") and the owner's in-window preference; the separate window is the HIG's "option to view content in a new window" for multitasking. The setting applies from the next call; no mid-call move in v1, because moving live video layers between windows mid-call adds a glitch surface nobody asked for. Host-independent `CallStageViewController` makes both hosts thin (§8).
- **DL2 Rail stays in the system sidebar slot** — only stock route to glass, window-button placement, and toolbar tracking with zero custom chrome; content is square labeled tab buttons, never a source list. Owner checkpoint after P1; one-line fallback (§5.1).
- **DL3 Toolbar = fixed identifiers + `isHidden`**, replacing insert/remove diffing — insert/remove relayouts and flickers on every selection change (§5.4).
- **DL4 Timeline heights measured and cached**, replacing `usesAutomaticRowHeights` — estimated heights that self-correct cause history-prepend jumps and anchor drift (§6.2.1).
- **DL5 One synchronous navigation writer (`Navigator`)** — async observation from AppKit (`withObservationTracking`, `Observations`) lands one turn late and shows an intermediate frame (R21).
- **DL6 Cached per-section pane children** — returning to a section keeps scroll, disclosure, and draft state and triggers no refetch; views never fetch (R24, §5.1).
- **DL7 One hosting factory** — `sizingOptions`, `sceneBridgingOptions`, focus-effect suppression, and environment injection are set in one place, so the classic `NSHostingController` seams (split panes resized by content, SwiftUI touching the toolbar, environment lost across AppKit islands) cannot recur per call site (R22, R23).
- **DL8 Focus rings: suppress drawing, keep focus** — satisfies the owner order while keeping keyboard and VoiceOver users working; lists already meet the HIG through selection highlight (§10, D3).
- **DL9 Platform: macOS 26, tools 6.2, one deployment target across Swift, Info.plist, and Rust** (§4).
- **DL10 Shortcuts:** ⌘J dropped from Join Meeting (standard "Scroll to a selection"); ⌘U kept for Upload as a HIG-permitted redefinition (D6); ⇧⌘U logged under D2; the bottom-bar citation moved from Layout to Windows, where the quote actually lives.
- **DL11 Cross-lane seams created by P1** — shared tables (`CommandCatalog`, sheets, routes, `SectionID`) are per-section or declared up front, so parallel lanes never edit the same file (§11.3, §12).
- **DL12 Toolbar: search last, no inspector tracking separator** (P2c fix, 2026-09-27) — the only arrangement where search is last *and* stays a full field with the inspector open or closed; the inspector toggle and account precede it in one always-visible trailing group (§5.4). The inspector yields rather than widening the window: a route, restore or automatic open in a window narrower than the pane minimums (rail + list + detail + the inspector's 260 pt minimum; where its last width does not fit it opens at the widest width that does) leaves it collapsed, so the 900 pt minimum stays reachable; only an explicit Show Inspector may grow the window (§5.1, R25), and opening a thread ("N replies" or a `?thread=` route) is explicit: where even the minimum does not fit it grows the window rather than being dropped (CALTEAMS, 2026-09-27). A fitting open never widens the window: the expanding pass uses `collapseBehavior = .useConstraints` (the inspector default widened the window by the whole inspector on every open).
