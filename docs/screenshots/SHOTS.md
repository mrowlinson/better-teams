# README screenshots

Interim set, captured from the demo build (`--demo --evidence`, canned
offline data) with `scripts/ui-shot.sh`. Windows are 1440×900 pt (Settings
sizes itself to its 640 pt pane, so `SIZE` does not apply there) on a
Retina display, window shadow kept on a transparent background. Evidence
runs pin the demo clock to 10:30 AM on a weekday. By default they never
activate the app, so windows draw with the inactive appearance; `ACTIVE=1`
activates the app for the active appearance, which only takes effect in
an unlocked session nobody is using. This set draws inactive.

Re-capture one shot (from the repo root, after `scripts/build-app.sh`):

```sh
SIZE=1440x900 SHADOW=1 DELAY=1.5 scripts/ui-shot.sh '<route>' <appearance> docs/screenshots/<file>.png
```

Files over 1 MB are converted with `cwebp -q 85` and the PNG dropped.

| File | Demo route | Appearance |
| --- | --- | --- |
| chat-light.png | `chat/demo-showcase` | light |
| chat-dark.png | `chat/demo-showcase` | dark |
| teams-thread.png | `teams/demo-team/demo-channel?tab=posts&thread=demo-thread` | light |
| calendar-week.png | `calendar?view=week` | light |
| call-video.png | `call?state=presenting&presentation=main` | dark |
| files.png | `files/recent/demo-file?inspector=1` | light |
| planner.png | `app/planner/demo-plan-sprint/demo-ptask-2?inspector=1` | light |
| shifts.png | `app/shifts` | dark |
| activity.png | `activity/mention:demo-showcase:sc-1` | light |
| app-pinned.png | `app/onenote` | dark |
| settings.png | `settings/general` | light |
