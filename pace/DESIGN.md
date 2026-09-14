# Pace — design

A macOS menu bar app that tells you, at a glance, whether you are burning your
Claude usage budget at the right speed to hit 100% exactly when the limit
resets. Status: design settled 2026-09-08 after ten rounds of rendered mockups;
this document is the spec the implementation follows. It is the living doc for
`myelin/pace/`; update it when the app changes.

## Goal

Geoff checks claude.ai → Settings → Usage many times a day to make sure he runs
out of weekly budget right at the deadline, not early (forced downtime) and not
late (budget wasted). Pace puts that answer in the menu bar, three icons wide,
and makes the size of the miss visible. Everything about the schedule and the
look is configurable; nothing is hardcoded to Anthropic, to a time zone, or to
one set of meters.

## Non-goals for v1

- No Codex or other providers yet. The provider protocol exists so one can be
  added later without touching the UI.
- No burn history or charts. The app keeps no log of past snapshots.
- No refreshing of the OAuth token. The app only reads it.
- No extra-usage or spend display.

## What the user sees

### Menu bar glyph

Real size is about 94×20 pt in a 22 pt menu bar. Left to right:

1. **The Clawd mark**, 19×12 pt, Claude orange `#D97757`, drawn from a 16×10
   pixel grid (see `GlyphView`). Optional, on by default. 4 pt gap after it.
2. **Three rows**, top to bottom **Sess**, **Week**, **Fable**, each 6 pt tall
   with 1 pt between rows, no separator. A row is a label column then a bar.
   - Label column: 19 pt wide, 6 pt semibold text, 80% ink. Setting "Labels"
     switches between words (Sess, Week, Fable) and letters (S, W, F). Letters
     shrink the column to 7 pt.
   - Bar: 50 pt wide, 6 pt tall, blocks with 1 pt gaps, 1.5 pt corner radius,
     empty track at 28% ink.
3. Optional **hours left** text after the bars, 13 pt: "74h". Off by default.

Rows:

- **Sess**: 5 blocks, one per hour of the 5-hour session window. First block
  carries the label "1h" in 5 pt bold. Fill follows the three-color rule.
  White tick at the current time position.
- **Week**: one block per working day inside the weekly window, 5 by default,
  7 with weekends on. Widths proportional to that day's working hours, which
  makes them equal in the normal case. First block carries "1d". Fill follows
  the three-color rule. White tick at the current time position.
- **Model rows**, one per per-model weekly limit the account reports. Today
  that is Fable. Same day blocks as Week, single-color fill in the model's
  color, **no tick**, no unit label. Fable's color is Claude orange.

**Three-color fill** for Sess and Week, with `u` = percent used and `t` = the
tick position in percent:

- green from 0 to `min(u, t)` — used on schedule
- yellow from `u` to `t` when `u < t` — unspent so far, exactly the size of the miss
- red from `t` to `u` when `u > t` — spent ahead, exactly the size of the miss
- the white tick is always drawn at `t`

Defaults: green `#0CA30C`, yellow `#FAB219`, red `#D03B3B`. All four colors
(these three plus each model's) are settings.

**Ink follows the menu bar appearance.** Labels, unit text on empty blocks,
tracks and ticks use white on a dark menu bar and black on a light one, read
from the status item's effective appearance. Fill colors do not change.

**Tooltip** on hover lists every row with elapsed, remaining and reset time,
for example "Week · 94h elapsed · 74h remaining · resets Fri 5:00 pm".

**Stale state**: when the last fetch failed or the token is expired, the glyph
draws at 50% opacity and the tooltip and popover say since when.

### Popover

Opens on click, 360 pt wide, standard vibrancy. Row columns are name 48 pt,
bar 142 pt, percent 40 pt, verdict 74 pt with 4 pt gaps, which fits "Session",
"100%" and "−44 under" without wrapping. Top to bottom:

- Header: the Clawd mark, a chip with provider and plan ("Claude · Sample"),
  "updated 12 s ago" right-aligned, a gear that opens Settings.
- **USAGE** group, marked by the word running vertically in a 14 pt gutter.
  - "SESSION" line: `1h 21m elapsed · 3h 39m remaining · resets 6:31 pm`.
  - Session row: name, the 5-block bar at 150×9 pt with "1h", percent,
    verdict text with a swatch.
  - Caption: "one hour per block · ■ used ■ unspent ■ over".
  - "WEEK" line: `94h elapsed · 74h remaining · resets Fri 5:00 pm`.
  - Week row: day letters (Mo Tu We Th Fr) above the blocks, "1d" in the first
    block, percent, verdict.
  - Caption: "one working day per block · tick = now, Tue 2:52 pm".
- Hairline.
- **MODELS** group, vertical word.
  - "WEEKLY resets with Week".
  - One row per model, day letters above, single-color fill, no tick, percent,
    verdict text colored by pace.
- Footer: "Settings…", "Refresh", "Quit".

No projection line. The popover uses the same math, colors and formats as the
glyph.

**Verdict text**: `d = round(u − t)`. Within the on-pace band (default ±5) it
reads "on pace" in green. Otherwise "+d over" in red or "−d under" in amber
(`#9A6B00` on light, `#FAB219` on dark). The band affects only this text; fills
are exact.

### Settings window

Opened from the gear or the footer. Groups and controls, all persisted:

- **Menu bar**: Mark on/off (on). Labels words/letters (words). Hours left
  on/off (off). Model rows: all reported / most constrained only / a fixed
  model (all). "Most constrained" is the model whose `u − t` is largest.
- **Colors**: used, unspent, over, and one well per model. Defaults above.
- **Pace model**: Week starts: from account reset (default, shows the derived
  value, e.g. "Fri 5:00 pm") or a custom weekday and time. Custom only changes
  how the day blocks and the tick are laid out; the percent used always comes
  from the provider. It exists for providers that report no reset and for
  anyone who wants the blocks anchored to their own week. Working days: Mon–Fri
  with an "include weekends" checkbox (off). Working hours: start and end
  (9 and 17). On-pace band: ±0–15 points (5).
- **Providers**: Anthropic on/off with status line ("via Claude Code login ·
  token fresh" or "stale since 9:12 am"). Poll every 30/60/120/300 s (60).
- **General**: Launch at login.

### States

- **No active session**: the API returns 0% and a null reset. Sess row shows
  empty blocks, no tick, label at 50% ink. Popover says "no active session".
- **Stale**: see above. The last good snapshot stays on screen.
- **Not logged in**: keychain item missing or token expired with no snapshot
  yet. Glyph shows the mark, labels and empty tracks at half opacity, so its
  shape stays put; tooltip and popover say "Open Claude Code and log in".
- **Locked** (`locked_reason` present or 100%): the bar is fully red and the
  verdict reads "locked · resets …".

## Pace model

All times in the Mac's local zone. Reset instants come from the provider and
are rounded to the minute for display.

- **Weekly window** `[R − 7 d, R]` where `R` is the weekly `resets_at`.
  Working days are the calendar days inside the window whose weekday is
  enabled; each contributes the overlap of its working hours `[start, end)`
  with the window. Blocks are those days in order; block share = that day's
  hours / total working hours. With a Friday 5:00 pm reset and 9–17 hours this
  is exactly Mon–Fri, five equal blocks. If the reset time falls inside working
  hours, the first and last days are partial and get proportionally narrower
  blocks; the day letter still labels them.
- **Week tick** `t = 100 × (working hours elapsed so far) / (total working
  hours in the window)`. It moves only during working hours, so it is frozen
  overnight and, with weekends off, all weekend. Monday 9:00 am is the left
  edge of Monday's block.
- **Session window** `[R − 5 h, R]`. Session tick `t = 100 × elapsed / 5 h`,
  linear.
- **Model rows** use the week tick only for the verdict text.
- **Formats**: durations of 10 h or more as whole hours ("74h"), under 10 h as
  hours and minutes ("3h 39m"), under an hour as minutes ("39m"). Clock times
  as "Fri 5:00 pm" or "6:31 pm" when the day is today.

There is no off-hours reserve. Anything burned outside working hours shows as
red until the next working day catches up; the band absorbs a modest amount.
A possible later setting is invisible slack: tick stays at true time, red
starts only past `t + allowance`. Not built.

## Data

### Provider protocol

```swift
protocol UsageProvider {
    var id: String { get }              // "anthropic"
    var displayName: String { get }     // "Claude"
    func fetch() async throws -> UsageSnapshot
}
struct UsageSnapshot { let fetchedAt: Date; let plan: String?; let meters: [Meter] }
struct Meter {
    enum Kind { case session, weekly, weeklyModel(name: String) }
    let kind: Kind
    let percent: Double          // 0…100
    let resetsAt: Date?          // nil when no window is active
    let windowLength: TimeInterval   // 5 h or 7 d
    let locked: Bool
}
```

The UI never sees provider-specific fields.

### Anthropic provider

1. Read the login keychain item named `Claude Code-credentials` by running
   `/usr/bin/security find-generic-password -s "Claude Code-credentials" -w`.
   The value is JSON; use `claudeAiOauth.accessToken`, and `subscriptionType`
   for the plan chip ("team" → "Team"). Using the `security` binary rather
   than the Security framework avoids a keychain prompt, because Claude Code
   wrote the item with the same tool.
2. `GET https://api.anthropic.com/api/oauth/usage` with headers
   `Authorization: Bearer <token>`, `anthropic-beta: oauth-2025-04-20`,
   `Accept: application/json`.
3. Parse the `limits` array. Each entry has `kind` (`session`, `weekly_all`,
   `weekly_scoped`), `percent`, `resets_at` (ISO 8601 with offset, may be
   null), `scope.model.display_name` for scoped entries, and `severity`.
   Map to `Meter`: session → `.session` with 5 h; weekly_all → `.weekly` with
   7 d; weekly_scoped → `.weeklyModel(name)` with 7 d. If `limits` is absent,
   fall back to `five_hour`, `seven_day`, and any non-null `seven_day_<model>`
   fields, which carry `utilization` and `resets_at`.
4. On HTTP 401 or a missing token, throw; the app enters the stale or
   not-logged-in state. The app never calls the token refresh endpoint.

A synthetic response from 2026-09-08 is checked in as a test fixture.

### Polling

Fetch every N seconds (default 120), on popover open and the Refresh button
(spaced at least 30 s apart), and on wake from sleep. The endpoint answers
HTTP 429 to sustained one-a-minute polling, so any failure backs the next
attempt off: base interval doubled per consecutive failure, capped at 30 min,
`Retry-After` honored when present. A failure never blanks the screen; the
last snapshot stays and the glyph dims only once its data is older than 15
minutes. Independently, re-render the glyph every 60 s so the tick moves.
Countdowns in the popover tick every second while it is open.

## Architecture

Swift Package Manager, macOS 14 or later, no third-party dependencies.

- `Sources/PaceCore` — library, fully unit-tested, no AppKit.
  - `Model.swift`: `Meter`, `UsageSnapshot`, `UsageProvider`.
  - `Schedule.swift`: `PaceSettings` (working days, hours, band, week start
    override), day-block computation, week and session tick.
  - `Fill.swift`: the three-color rule as data (`[FillRange]`), verdict.
  - `Formatting.swift`: duration and clock formats.
  - `Providers/AnthropicProvider.swift`, `Providers/Keychain.swift`.
- `Sources/PaceApp` — executable.
  - `App.swift`: `@main`, `NSApplicationDelegateAdaptor`, no dock icon
    (`LSUIElement`), `Settings` scene.
  - `StatusItemController.swift`: owns the `NSStatusItem`, renders
    `GlyphView` to an `NSImage` with `ImageRenderer` at the screen's backing
    scale (non-template so colors survive), sets the tooltip, toggles an
    `NSPopover` hosting `PopoverView`.
  - `UsageStore.swift`: `@Observable` state, polling timers, stale tracking,
    sleep/wake observer.
  - `GlyphView.swift`, `BarView.swift` (blocks, fills, tick, unit label, day
    letters), `ClawdMark.swift`, `PopoverView.swift`, `SettingsView.swift`,
    `AppSettings.swift` (Codable, stored in `UserDefaults`), `Theme.swift`
    (colors, appearance-aware ink).
  - Launch at login via `SMAppService.mainApp`.
- `Tests/PaceCoreTests` — schedule, fill, verdict, formatting, provider
  parsing against the fixture and the fallback shape.
- `Resources/AppInfo.plist`, `Resources/AppIcon.icns` (the Clawd mark in
  orange, generated by `Resources/make_icon.swift` like the recorder).
- `Makefile`: `build`, `test`, `app`, `app-install`, `app-zip`, `clean`.
  `app-install` builds, ad-hoc signs, copies to `/Applications/Pace.app` and
  launches. `app-zip` writes `~/Downloads/Pace.zip`.
- `install.sh`: checks macOS 14+ and Xcode Command Line Tools, runs
  `make app-install`, prints what to expect.
- `README.md`: install, what the glyph means, settings, second-Mac notes.

The status item is AppKit rather than SwiftUI `MenuBarExtra` because the
glyph needs exact pixel dimensions, non-template color, a tooltip and a
re-render on a timer, all of which `MenuBarExtra` labels handle poorly.

## Testing

- Unit tests use Swift Testing, not XCTest, because the Command Line Tools do
  not ship XCTest; `make test` adds the framework search flags the CLT needs.
  They cover: five equal blocks Mo–Fr for a
  Fri 5:00 pm reset with 9–17 hours; seven blocks with weekends; partial edge
  blocks for a reset inside working hours; the week tick at Monday 9:00 am
  (0%), Tuesday 2:52 pm (34%), Friday 5:00 pm (100%), and frozen over a
  weekend; session tick; fill ranges for under, over, equal and the 0 and 100
  edges; verdict band edges; duration and clock formats; provider parsing of
  the fixture (three meters: session 3%, weekly 4%, Fable 3%) and of the
  legacy fallback shape; a null `resets_at` yielding an inactive session.
- Manual checks: debug states are forced with `PACE_DEBUG_STATE`
  (`sample`, `nosession`, `stale`, `loggedout`, `locked`), and the glyph,
  popover and settings can be rendered offscreen to PNG with
  `PACE_DEBUG_DUMP`, `PACE_DEBUG_DUMP_POPOVER`, `PACE_DEBUG_DUMP_SETTINGS`,
  which is how the pixels were checked without screen recording. Still to
  eyeball by hand: the glyph on a light menu bar, launch at login, and the
  zip on a second Mac.

## Distribution

- This Mac: `cd pace && make app-install`.
- Second Mac: clone or copy the `pace/` folder and run `./install.sh`, which
  needs Xcode Command Line Tools. Or copy `~/Downloads/Pace.zip`, unzip, run
  `xattr -dr com.apple.quarantine Pace.app`, move to Applications. Either way
  the Mac must have Claude Code installed and logged in, because that is where
  the token comes from.

## Later

Codex provider reading `~/.codex/auth.json`; invisible slack allowance; extra
usage and spend; a week chart of burn against the ideal from logged snapshots;
the three-color rule on model rows; per-model letters when a name collides
with S (Sonnet → "Sn").
