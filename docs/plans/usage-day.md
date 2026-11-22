# Plan: show the usage, and let a day on the lot be a 5-hour window

## The problem

You can't see from the lot how much of Claude's 5-hour usage you've used,
or when it resets. You only find out when a character runs into the limit
and sits waiting with "Back at 15:01". Meanwhile the lot's day is already
five hours long, but it has nothing to do with the usage window: its
midnight is a fixed moment in 2001, so dawn and dusk come at times that
mean nothing.

The person asked for two things:

- a small ring showing the share of the 5-hour window used, its outer edge
  filling with colour, and the time until the window resets;
- the day and night to follow the window: midnight when a window starts,
  the day spread over its five hours, and the next midnight when it resets,
  so a day on the lot is one window.

They wrote "when the 4 hour cycle starts"; this plan takes that to mean the
5-hour usage window, as everything else they said does.

## What happens now

- **The day.** `DayClock` (`ALifeKit/Sources/ALifeClient/DayClock.swift`)
  is five hours long (`dayLength`), and its `midnight` defaults to
  `Date(timeIntervalSinceReferenceDate: 0)`, so the time of day follows
  from the date alone and is the same on every front end. `SkyBox` makes a
  `DayClock()` with that default and keeps it in `SkyComponent.clock`, a
  `let`, so it can't change while the app runs. `DaySystem` reads
  `state.clock.sky(at:)` twice a second for the sun, moon, stars, sky
  colours and lights, and every frame for the clouds' drift, which is a
  whole number of turns a day (`Clouds.turnsPerDay`), so it carries on
  smoothly from one day to the next. Nothing else on the lot needs the
  clock.
- **What Claude Code tells us.** Claude Code reads the
  `anthropic-ratelimit-unified-5h-*` and `-7d-*` headers of each response
  itself; the server never sees the HTTP. But it passes them on in
  stream-json: every turn, even an ordinary allowed one (checked with CLI
  2.1.323), writes a `rate_limit_event` such as:

  ```json
  {"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1795366800,"rateLimitType":"five_hour","overageStatus":"rejected","isUsingOverage":false,"unifiedWindows":{"five_hour":{"utilization":0.46,"resetsAt":1795366800,"status":"allowed"},"seven_day":{"utilization":0.51,"resetsAt":1795395600,"status":"allowed"}}}}
  ```

  `utilization` is a share: 0.46 is 46%.
- **What the server does with it.** `ClaudeCharacter.handle` reads the
  event into `UsageLimit.Info` (`status`, `resetsAt`, `rateLimitType`) and
  keeps the last one per character in `rateLimit`, only to tell whether a
  turn ended on the 5-hour limit and when to carry on. It ignores
  `unifiedWindows` and `utilization`, and nothing about usage reaches the
  front ends apart from a character's `usage_limit` stop and `resumes_at`.
- **The status pill.** `SessionStatusBar` (in `ALife/AgentPanel.swift`) is
  the capsule at the top of `WorldView` (`.overlay(alignment: .top)`): a
  dot for the connection, the status text, the Log button with its badge,
  and Settings. The lot comes to front ends as whole snapshots on its own
  stream, `GET /v1/lot` and `GET /v1/lot/events` (`LotHub`), and
  `ServerConnection.followLot` returns `nil` on a 404, so a front end still
  works with a server from before the lot.

## The plan

### 1. Keep track of the usage (server)

- **Read it from the characters' runs.** `UsageLimit.Info` also reads
  `unifiedWindows`: for `five_hour` and `seven_day`, `utilization`,
  `resetsAt` and `status`, tolerantly (unknown fields and windows are
  skipped). `seven_day` is parsed but not used: a second ring for the
  weekly limit is out of scope for now. A reading of the 5-hour window comes from `unifiedWindows.five_hour`
  if it is there; failing that, from a top-level `rateLimitType`
  `five_hour` with its `resetsAt`, with the utilization unknown (or full, if
  its `status` is `rejected`).
- **One reading for the whole server.** A small actor, `UsageHub`
  (`Usage.swift`), keeps the latest 5-hour window: `utilization` (0 to 1,
  or unknown), `resetsAt`, `startedAt` (`resetsAt` less five hours), and
  `readAt`, when it arrived. Every character hands it each reading, and the
  latest to arrive wins, whoever it came from: they all share one account
  and one window. A turn that ends on the 5-hour limit counts as a reading
  of full.
- **Kept across a restart.** The hub writes its reading to `usage.json` in
  `ALIFE_STATE_DIR` (`~/a-life-state`), next to `continues.json`, written
  atomically, and reads it when the server starts, so the gauge and the
  day are there straight away rather than after the first run.
- **To the front ends** the usage goes the way the lot does, because it is
  the server's rather than a character's: `GET /v1/usage`, and
  `GET /v1/usage/events`, which sends the usage as it is now and again each
  time it changes (`usage` events). A `null` window means none has been
  read yet. This is instead of a `usage.changed` session event: a session's
  events are about one character, and putting the same thing in every
  session's log and snapshot would repeat it once per character.
- With `ALIFE_BACKEND=dummy`, the dummy characters hand the hub a made-up
  reading as they run, so the gauge and the sky can be tried without a
  model.
- The clock and the state directory are injected, so tests don't wait or
  write to the person's home.

### 2. The gap, honestly

The server only sees a reading when one of its characters runs a turn. The
person's other Claude sessions (in a terminal, on claude.ai) use up the
same window without the server hearing of it. So:

- **While nobody here is running,** the gauge shows the last reading as
  long as its window lasts, and once it is older than 30 minutes,
  says when it was taken ("as of 14:02") and is dimmed, so it doesn't pass
  for live.
- **Once `resetsAt` has passed,** that window is over, whatever was used
  since: the gauge goes away, and the lot holds at midnight, until a run
  reports a new window. A window started elsewhere isn't seen until a
  character runs.

### 3. The usage in ALifeKit

- `ALifeAPI`: `Usage` with an optional `UsageWindow` (`utilization`, which
  may be `nil`, `resetsAt`, `startedAt`, `readAt`), dates in seconds since
  1970 as with `resumes_at`, decoded tolerantly.
- `ALifeClient`: `ALifeServerClient.usage()` and `usageChanges()`, and
  `ServerConnection.usage`, followed like `lot`, with `followUsage`
  returning `nil` on a 404 so older servers still work.
- Plain helpers, tested:
  - `UsageWindow.remaining(at:)` and a countdown text: "2h 14m", "14m",
    "under a minute", and nothing once it has reset;
  - `UsageWindow.isCurrent(at:)`, false once `resetsAt` has passed, and
    `isStale(at:)`, true once `readAt` is more than 30 minutes ago;
  - `DayClock(window:)`: `midnight` at `startedAt`, `length` five hours.

### 4. The gauge (app)

- A new `UsageGauge.swift`: a ring whose outer edge fills clockwise from
  the top with the share used (`Circle().trim` over a faint track), the
  percentage in the middle, and the colour going from green through amber
  (from about 70%) to red (from about 90%). Beside it, the countdown to the
  reset, brought up to date each minute (a `TimelineView` on the minute).
  A stale reading is dimmed and says "as of 14:02"; an unknown utilization
  shows the track with a "?".
- **Decided: a small panel of its own at the top left.** `WorldView` lays
  its overlays over the `RealityView` (which ignores the safe area):
  `.overlay(alignment: .top)` with `SessionStatusBar`, centred, and
  `.overlay(alignment: .bottom)` with `AgentPanel` (at most 520 points
  wide). Nothing sits at the top left now. The gauge gets its own
  `.overlay(alignment: .topLeading)` in `WorldView`, padded like the
  others (`.padding()`, so inside the safe area, clear of the notch and
  the Mac's title bar), on the same `.thinMaterial` as the pill, in a
  rounded rectangle: the ring, about 32 points, with the countdown beside
  it.
- **Keeping clear of the pill.** On a wide window the two are far apart.
  On a narrow one, an iPhone upright, the centred pill (whose text can run
  to two lines) could reach under the panel, so while the panel shows,
  the top overlay keeps the pill out of its way: it gets a horizontal
  padding of the panel's width on both sides, keeping it centred, read
  from the panel with `onGeometryChange`. On narrow widths
  (`horizontalSizeClass == .compact`) the countdown goes under the ring
  instead of beside it, to keep the panel narrow. Both are to be checked
  in the iPhone Simulator.
- **Decided: hidden unless a current value is known.** The panel isn't
  there at all when no reading has ever been taken, or when the window's
  `resetsAt` has passed; it comes back when a run reports a new window.
  A reading that is old but still inside its window stays, dimmed, with
  "as of 14:02".
- Over the panel, a tap or a scroll doesn't reach the lot, as with the
  pill (on macOS, `NSEvent.isOverLot` already leaves SwiftUI's overlays
  out of scroll-zooming).
- Its accessibility label reads "Usage: 37 percent, resets in 2 hours 14
  minutes", with "as of 14:02" when stale.

### 5. The day follows the window (app)

- `SkyComponent.clock` becomes a `var`, and `WorldView` hands the world a
  new clock when `server.usage` changes: midnight at the window's start,
  sunrise at 1¼ hours, noon at 2½ hours, sunset at 3¾ hours, and the next
  midnight at the reset.
- **The default: when the window changes, the sky eases rather than
  jumps.** Within a
  window the clock doesn't move, but it does when a window first becomes
  known (on connecting, after the fixed clock), or when a new window turns
  up while the old one's day was still going. `DaySystem` then carries the
  phase forward to the new one over about ten seconds, the short way
  round, so the sun sweeps rather than leaps, and the clouds drift along
  with it.
- **Decided: with no window going** (the last one has reset and no run has
  reported a new one), the lot holds at midnight: moon high, stars out,
  clouds drifting, until the next window turns up, when the night goes on
  into a new day.
- **With no usage ever read** (an older server, or a new one whose
  characters haven't run yet), the day runs on today's fixed clock, as now.

### Not doing, and why

Claude Code's own `/usage` screen asks `api.anthropic.com/api/oauth/usage`,
which would keep the gauge current even when no character runs. It isn't a
documented API, could change without notice, and would need the person's
Claude Code login from the Keychain. The `rate_limit_event` comes from the
same response headers through a channel the server already reads, so this
plan does without it.

## Done when

- `UsageLimit.Info` reads `unifiedWindows` (`five_hour` and `seven_day`),
  and falls back to a top-level `five_hour` with no utilization; tests use
  the event above, and ones with missing and unknown fields.
- A character's reading reaches `UsageHub`; the latest one wins across
  characters; a turn ending on the limit reads as full.
- `usage.json` round-trips across a restart, and the server starts with
  the reading it had.
- `GET /v1/usage` and its stream send the usage, and changes, and the
  client follows them, still working with a server that has neither.
- ALifeKit tests cover decoding `Usage`, the countdown text, `isCurrent`,
  `isStale`, and `DayClock(window:)`: phase 0 at the start, 0.5 (the sun in
  the south) at 2½ hours, back to 0 at the reset; and the fixed clock when
  there's no usage.
- The app shows the ring and the countdown on their own panel at the top
  left, dimmed with "as of" when stale, and hides the panel when there's no
  reading or its window is over; the panel and the status pill don't
  overlap on an iPhone upright; the sky follows the window, eases when it
  changes and holds at midnight between windows; and it builds for macOS
  and the iOS Simulator.
- README.md (the files table: `UsageGauge.swift`, `SkyBox.swift`,
  `DaySystem.swift`, `ALifeClient`'s `DayClock` and `usage`) and the
  server's README (The API: the usage and its stream; The usage limit:
  `unifiedWindows` and `usage.json`; Layout: `Usage.swift`) say how it
  works.

## Decided

- A reading is dimmed, with "as of 14:02", once it is older than 30
  minutes.
- A second ring for the weekly limit is out of scope for now; `seven_day`
  is only parsed.

## As built

- **Reading it (server).** `UsageLimit.Info` (`UsageLimit.swift`) now also
  reads `unifiedWindows` into `windows`, by name, each with `utilization`,
  `resetsAt` and `status`; entries it can't read are skipped. `seven_day`
  is read but not used. `fiveHourWindow(readAt:)` makes a reading of the
  5-hour window from `windows["five_hour"]`, or else from a top-level
  `rateLimitType` of `five_hour` with the utilization unknown (or 1 if it is
  `rejected`). `ClaudeCharacter` hands each reading to the `UsageHub` as
  the `rate_limit_event` arrives, read at its `WakeClock`'s time, and a
  turn it waits out on the limit records the window as all used.
- **The hub.** `UsageHub` (`Usage.swift`) keeps `usage`, a `Usage` with a
  `revision` and the last `UsageWindow`. `record` takes the latest reading
  to arrive, whoever it came from; one with no utilization keeps what the
  last said about the same window, and a reading the same as the last
  changes nothing. Each change goes to every stream and to `usage.json` in
  `ALIFE_STATE_DIR` (the window as on the wire, written atomically), which
  is read back at start as revision 1. With the dummies, `DummyCharacter`
  calls `recordMadeUpUse(at:)` for each message (4% more each time, in a
  window that starts with the first), and nothing is written to the file.
- **The wire.** `Usage` and `UsageWindow` are in `ALifeAPI` (`Usage.swift`):
  `{"revision", "window": {"utilization", "resets_at", "read_at",
  "started_at"}}`, dates in seconds since 1970, `started_at` written only for
  people reading it with curl (it is `resets_at` less five hours).
  Decoding is tolerant: no `revision` is 0, a `window` it can't read is
  none, no `read_at` counts as read when the window started. The server
  serves `GET /v1/usage` and `GET /v1/usage/events` (`usage` events, with
  the revision as their id), like the lot.
- **The client.** `ALifeServerClient.usage()` and `usageChanges()`, and
  `ServerConnection.usage`, followed alongside the lot; `followUsage`
  returns `nil` on a 404, and a new server address forgets it. Helpers in
  `ALifeClient/UsageReading.swift`: `UsageWindow.isCurrent(at:)`,
  `isStale(at:)` (over `staleAfter`, 30 minutes), `remaining(at:)`,
  `countdown(at:)` ("2h 14m", "14m", "under a minute", `nil` once reset),
  `spokenCountdown(at:)`, `percent`, and `band` (`plenty`, `getting` from
  70%, `nearlyFull` from 90%); `Usage.currentWindow(at:)`; and
  `DayClock(window:)` and `DayClock.lot(for:)`.
- **The day.** `DayClock` has `until`: from then on `phase` is 0, so the
  lot holds at midnight, while `runningPhase` carries on for the clouds'
  drift. `DayClock(window:)` puts midnight at the window's start and
  `until` at its reset; `lot(for:)` falls back to `DayClock()` when no window
  was ever read. A new `SkyClock` wraps the clock the sky follows: `change(to:at:eases:)`
  starts a 10-second ease (`SkyClock.easing`) from where the sky is to
  where the new clock says, the short way round with a smoothstep, for the
  day's phase and the clouds' alike; the same clock again changes nothing.
  `SkyComponent.clock` is a `SkyClock`, `World.setDayClock` changes it,
  `WorldView` sets it straight away when the world is made and eases on
  every change of `server.usage`, and `DaySystem` updates every frame while
  it eases. As planned, this means the sun sweeps over for ten seconds
  after each launch, once the window comes in on connecting.
- **The panel.** `UsagePanel` and `UsageRing` (`ALife/UsageGauge.swift`),
  in a `TimelineView(.everyMinute)`: shown only for
  `server.usage.currentWindow(at:)`, on `.thinMaterial` in a rounded
  rectangle, with the ring (34 points, a 4-point edge trimmed to the
  utilization from the top, green, orange or red, the percentage or "?" in
  the middle) and "Resets in 2h 14m"; on a compact width (iOS) the
  countdown goes under the ring as "2h 14m". A stale reading is at 55%
  opacity with "as of 14:02". It is a `.overlay(alignment: .topLeading)` in
  `WorldView`, padded like the others, and reports its width through
  `onGeometryChange`; while it shows, the status pill's overlay gets that
  width plus 8 points of padding on both sides, so the pill stays centred
  and clear of it.
- **Tests.** ALifeKit `UsageTests`: the wire round trip and tolerant
  decoding, clamping, the countdown and its spoken form, `isCurrent`,
  `isStale` at 30 minutes, percent and bands, `DayClock(window:)` (0 at
  the start, 0.5 with the sun in the south at 2½ hours, 0 at the reset),
  holding at midnight with the clouds' phase carrying on, the fixed clock
  with no window, and `SkyClock` easing the short way round over midnight.
  `ServerConnectionTests` follow the usage, forget it with a new address,
  and carry on with a server without it. Server `UsageTests`: the
  windows from the 2.1.323 event, the fallbacks, what can't be read, the
  latest reading winning, followers, `usage.json` across a restart (and a
  broken one), the dummies' made-up use, a turn's event and a turn ending
  on the limit reaching the hub, and a front end following the dummies'
  usage end to end.
- **Not checked by eye.** The app builds for macOS and the iOS Simulator,
  but the panel's look and its spacing beside the pill on an iPhone held
  upright weren't checked in the Simulator.
- **Tests on this Mac.** With Swift 6.4.2, the server tests that start
  Vapor with `.testing` fail here, on main as well ("Unknown command
  `…/ALifeServerTests.xctest`"): the test runner's path no longer ends in
  `/usr/bin/xctest`, so Vapor doesn't drop the bundle from its arguments.
  The new end-to-end test gives Vapor arguments of its own, so it runs.
