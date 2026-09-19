# Pace

A menu bar app that shows whether you are burning your Claude usage budget at
the right speed to hit 100% exactly when the limit resets. Three bars, one per
limit your account has, each block a unit of time, colored by how far ahead or
behind pace you are.

![Pace in the menu bar: the mark, then Sess, Week and Fable bars](docs/menu-bar.png)

Design and decisions: [DESIGN.md](DESIGN.md).

## Install

```bash
cd pace && ./install.sh          # or: make app-install
```

Builds `Pace.app`, installs it to `/Applications`, and launches it. Needs
macOS 14 or later and Command Line Tools 16 or later — the package is
`swift-tools-version: 6.0`, so Swift 5.x tools stop with a "using Swift tools
version 6.0.0 but the installed version is 5.9.0" error. Check with `swift
--version`; the root README has the upgrade command. Pace reads the login token
that Claude Code keeps in your keychain, so the Mac must have Claude Code
installed and logged in. Pace never writes or refreshes that token.

**Another Mac:** clone or copy this folder and run `./install.sh` there. Or run
`make app-zip` here, copy `~/Downloads/Pace.zip` over, unzip, then:

```bash
xattr -dr com.apple.quarantine Pace.app && mv Pace.app /Applications/
```

## Reading the glyph

Top to bottom: **Sess**, five blocks of one hour each. **Week**, one block per
working day. **Fable**, the same days for Fable's own weekly limit. The first
block of a row names its unit.

- The **white tick** is now. On Sess it is the time elapsed in the five-hour
  session. On Week it is how far through your working week you are: it moves
  only during working hours, so it is frozen overnight and, with weekends off,
  all weekend.
- **Green** is budget used up to the tick, on schedule.
- **Yellow** appears from your usage to the tick when you are behind. Its length
  is what you have left unspent so far.
- **Red** appears from the tick to your usage when you are ahead. Its length is
  the overshoot.
- **Fable** is always orange and has no tick. Its verdict is in the popover.
- A half-transparent glyph means the last fetch failed. Hover for the reason.

Hovering shows elapsed, remaining and reset time per row. Clicking opens the
popover with the same bars at a readable size, day letters, percentages and a
verdict per row: "on pace", "+9 over" or "−9 under".


## Settings

The gear in the popover opens them. Everything is stored in UserDefaults.

- **Menu bar**: the mark on or off, word or letter labels, hours-left text after
  the bars, which model rows to show.
- **Colors**: used, unspent, over, and one per model.
- **Pace model**: week start from the account's reset or a custom weekday and
  time, working days with an "include weekends" box, working hours, and the
  on-pace band that decides when the verdict says "on pace".
- **Providers**: Anthropic on or off, status, poll interval.
- **General**: launch at login.

## Where the numbers come from

Claude Code stores an OAuth token in the keychain item `Claude Code-credentials`.
Pace reads it with `/usr/bin/security`, the same tool Claude Code used to write
it, so no keychain prompt appears. It then calls the private endpoint that
powers `/usage` in Claude Code and maps the `limits` array to meters. The token
lives about eight hours and Claude Code refreshes it whenever it runs.

Pace polls every 3 minutes by default, plus when you open the popover, at most
once every 30 seconds. The endpoint rate-limits aggressive polling with HTTP
429; on any failure Pace keeps the last good numbers on screen and backs off,
doubling the wait up to 30 minutes, honoring `Retry-After` when sent. The glyph
dims only when its data is more than 15 minutes old, and the tooltip then says
why and when the next try is.

## Development

```bash
make test        # unit tests for the schedule, fill rule, formats, provider parsing
swift build      # debug build
make run-sample  # run with the mockup's sample numbers, no network
```

Debug states, no network: `PACE_DEBUG_STATE=sample|nosession|stale|loggedout|locked`.
Offscreen renders for checking pixels: `PACE_DEBUG_DUMP=glyph.png`,
`PACE_DEBUG_DUMP_POPOVER=popover.png`, `PACE_DEBUG_DUMP_SETTINGS=settings.png`.

The Command Line Tools ship Swift Testing outside the default search path;
`make test` passes the flags. With full Xcode, plain `swift test` works too.

Layout: `Sources/PaceCore` is the tested library (model, schedule, fill,
formatting, providers), `Sources/PaceApp` is the AppKit + SwiftUI app.
