# Tasks menu bar app: rebuild plan

Status: plan only, not started (2026-11-02). Replaces the SwiftBar plugin with a
native menu bar app in the style of `pace/`. The Python MCP server stays as it is.

## Why

The SwiftBar menu does its job badly for how little it is used.

| Problem in the current menu | Effect |
|---|---|
| Every task with notes gets a second "🔗 notes" row | The menu is about twice as tall as the task count |
| All 25 open tasks show, grouped by list | About 50 rows. The menu runs off the screen and scrolls |
| Width follows the longest title | The menu is about 1100 px wide |
| Overdue shows as "Fri 9/25 · overdue" in red | 13 of 25 rows are red, so red tells you nothing. A task 38 days late looks the same as one 1 day late |
| One click anywhere on a row completes the task | Easy to complete the wrong task. There is no undo |
| List headers say "9 open · next overdue" | Uses a line, adds little |
| SwiftBar is a third-party app | It crashed when launched by its own URL, was not a login item, and its icon has no fixed position, so it hides behind the notch |

The question the menu must answer in 2 seconds: **what is late, and what is due
soon?** Everything else is one click deeper.

## Design

### Menu bar

```
 ☑ 13
```

- A checklist mark and the count of tasks due today or overdue. This is the
  same number as now.
- The number is red when something is overdue, and menu bar ink otherwise.
- When nothing is due, it shows only the mark. There is no "✓" or total.
- Fixed `autosaveName` ("tasks") and a default preferred position, so it stays
  to the right of the notch like Pace and the recorder.
- ⌘⌥T opens it. The hotkey code comes from `recorder/`.

### Popover

360 pt wide, the same as Pace. One line per task. The header and footer stay in
place, and only the task area scrolls, after about 14 rows.

```
┌────────────────────────────────────────────┐
│ ☑ Tasks              13 due · 25 open   ⚙  │
│ [ Due ][ Lists ]                           │
├────────────────────────────────────────────┤
│ OVERDUE 13                                 │
│ ○ ● Send the signed contract       ≡   38d │
│ ○ ● Finish the launch blog post        31d │
│ ○ ● Review the pricing deck        ≡   12d │
│ ○ ● Book the workshop room              3d │
│     … 9 more                               │
│ THIS WEEK 2                                │
│ ○ ● Draft the workshop agenda      ≡   Fri │
│ ○ ● Send the invoice                   Sun │
│ LATER 4 · NO DATE 6                    ▸   │
├────────────────────────────────────────────┤
│ updated 12 s ago        Open Google Tasks  │
└────────────────────────────────────────────┘
```

- **Due view (default)** groups by when, not by list: Overdue, Today, This
  week, then Later and No date folded into one line you can open.
- **The list shows as a colored dot (●).** Hover the dot to see the list name.
  Colors come from Settings. Each list's first color comes from `colors.json`.
- **Due label is short.** Overdue shows days late ("38d") in red. Today shows
  "Today" in red. Tomorrow shows "Tmrw" in amber. This week shows the weekday,
  and later dates show "Nov 13", both in gray.
- **≡ marks a task with notes.** The notes do not get their own row.
- **Subtasks fold under their parent** with a count, for example "2/3". Click
  the count to open them.
- **Overdue shows at most 8 rows**, then "… N more". The list never runs off
  the screen.

**Lists view** is the same rows grouped by list. Each list header is one line,
"● Acme 4", and opens or folds that list. Use it to see one client or project.

### Click a row to open it, not to complete it

```
│ ○ ● Review the pricing deck        ≡   12d │
│     Acme · Use last quarter's numbers.     │
│     🔗 docs.example.com/pricing            │
│     [Tomorrow] [Next week] [No date] [↗]   │
```

- **Click the circle (○) to complete a task.** The row shows a strikethrough
  and an Undo button for 4 seconds, then goes away.
- **Click anywhere else on the row to open it in place.** You see the list
  name, the notes, links you can click, and the snooze buttons.
- **The snooze buttons fix the "everything is red" problem.** Tomorrow, Next
  week and No date each set a new due date with one click. ↗ opens the task
  in Google Tasks.
- **Right-click a row** for the same actions plus "Copy title".

### Settings

- Show or hide each list.
- A color for each list.
- What the menu bar number counts: overdue plus today (default), or overdue
  only.
- The ⌘⌥T hotkey, on or off.
- How often to refresh: 1, 5 (default) or 15 minutes.
- Launch at login.
- The folder that holds `token.json`. The installer fills this in.

### States

- **Stale.** If the last fetch failed, the mark is drawn at 50% opacity. The
  popover says since when, and the last good task list stays on screen.
- **Signed out.** If `token.json` is missing or the refresh fails, the popover
  shows one line: "Run `uv run server.py auth` in tasks/".
- **Nothing due.** The popover says "Nothing due this week" above the Later
  line.

## Architecture

```
tasks/
  server.py            MCP server, unchanged except the change signal below
  app/                 new Swift package, same layout as pace/
    Package.swift      TasksCore + TasksApp + TasksCoreTests
    Makefile           copied from pace: build, test, app, app-install
    Resources/         AppInfo.plist (LSUIElement), icon, launchd agent template
    Sources/TasksCore/ no AppKit; unit-tested
      Models.swift       task list, task, subtask tree
      GoogleAuth.swift   reads token.json, refreshes the access token, writes it back
      TasksAPI.swift     list, complete, set due date (URLSession, REST)
      Buckets.swift      overdue / today / this week / later / no date, labels like "38d"
    Sources/TasksApp/
      StatusItemController.swift   based on pace's: autosaveName, popover sizing
      PopoverView.swift, TaskRow.swift, SettingsView.swift
      GlobalHotKey.swift           from recorder/
    Tests/TasksCoreTests/          fixtures with made-up tasks
```

**Auth: use the direct API with the same `token.json` the server uses.** The
Apps Script bridge has lost its Tasks permission, and the direct API works. The
app refreshes the access token with the refresh token itself: one POST to
Google's token endpoint. It writes the result back to `token.json` with an
atomic rename, so the Python server and the app share one login. Google's
`expiry` field has microseconds, so the parser must accept them.

**Change signal: `notifyutil`, not a URL.** After each write, `server.py` runs
`notifyutil -p com.myelin.tasks.changed`. The app listens with
`notify_register_dispatch` and reloads. If the app is not running, nothing
happens. This removes the URL path that crashed SwiftBar.

**Start and restart: keep a launchd agent.** It is the same agent as now
(RunAtLoad, KeepAlive SuccessfulExit=false), pointed at
`/Applications/Tasks.app/Contents/MacOS/TasksApp`. It restarts the app after a
crash, which `SMAppService.mainApp` does not. It was tested on this Mac
today. Because it points at a path and not at a code signature, it still works
after an ad-hoc rebuild.

**No new dependencies.** It uses only Swift, SwiftUI and AppKit, the same as
Pace. Python stays only for the MCP server.

## Build order

Each step ends with a check that must pass before the next step starts.

1. **TasksCore models, buckets and labels.** Check: `make test` passes with
   fixture tasks that cover each bucket, subtasks, and a task 38 days late.
2. **Token refresh and read-only API.** Check: a debug flag prints the bucket
   counts from the real account, and they match `uv run server.py check`.
3. **Status item.** Check: the count shows to the right of the notch on the
   built-in display after a relaunch.
4. **Popover, read-only.** Check: with 25 open tasks the popover is no taller
   than about 600 pt, and no row wraps.
5. **Actions: complete with undo, snooze, open.** Check: test only on a
   throwaway "Scratch" list, never on real tasks.
6. **Change signal.** Check: when Claude creates a task through MCP, the count
   updates within 2 seconds.
7. **Install.** Check: `make app-install` installs and loads the agent. A
   `kill -SEGV` brings the app back. After a reboot, the app is there.
8. **Remove SwiftBar.** Unload `com.myelin.swiftbar`, remove the plugin link
   and `swiftbar/`, and update both READMEs. Uninstalling SwiftBar itself is up
   to you.

Size: TasksCore about 400 lines and TasksApp about 600, well under Pace's 4,200.

## Not in v1

- Adding tasks or editing titles and notes. Claude does that through MCP.
- Reordering by drag, or moving tasks between lists.
- Times of day. Google Tasks does not store them.
- Changes to the desktop widget. It can use TasksCore later.

## Open questions

1. Is the Due view the right default, or do you think by list first?
2. Should tasks more than 14 days late get their own folded "Stale" group, so
   Overdue shows only what is still real?
3. Should Later and No date show in the Due view at all, or only in Lists?
