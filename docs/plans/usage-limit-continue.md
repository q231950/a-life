# Plan: carry on after the 5-hour usage limit

## The problem

When a character's Claude Code job runs into the 5-hour usage limit, it
stops, and that's it. The conversation ends on an error ("You've hit your
limit · resets 3pm"), the character goes back to the lawn as if it had
finished, and nothing picks the job up again once the limit resets. You have
to notice, remember when it resets, and tell the character to carry on
yourself, perhaps hours later, perhaps in the middle of the night.

## What happens now

In `ClaudeCharacter`, a limit arrives as an assistant message with an
`error` field, shown as an `.error` message, and a result with `is_error`,
after which `handleResult` emits `statusChanged(.idle, stopReason: .endTurn)`.
Nothing schedules anything. The Claude Code session id is only kept in
memory, so after a server restart the session couldn't be resumed even if
something wanted to.

## The plan

### 1. Tell a 5-hour limit when it happens (server)

- Find out what the installed CLI (2.1.323) really writes for a limit, and
  read that, tolerantly:
  - the structured `rate_limit_event`, with `rate_limit_info` (`status`:
    `allowed`, `allowed_warning` or `rejected`; `resetsAt` in unix seconds;
    `rateLimitType` such as `five_hour` or `seven_day`), preferred;
  - an assistant message whose `error` is `rate_limit`;
  - failing those, the text: "You've hit your limit · resets 3pm
    (Europe/Berlin)", or the older "Claude AI usage limit reached|<unix
    time>".
- Only the 5-hour limit is waited out: `five_hour`, or a limit of no known
  type that resets within about five hours. The weekly limits (and spend
  limits, credits and the like) are reported as an error, as now.

### 2. Wait it out, and carry on (server)

- When a turn ends on the 5-hour limit, the character remembers a pending
  continue (its id, its Claude Code session id and the reset time), and its
  status says so: a new `StopReason.usageLimit` (`usage_limit` on the wire),
  and the time it will carry on, `resumes_at`, on `session.status` and in
  `SessionState`. Older front ends decode the stop reason as `.unknown`.
- A minute after the reset, the server says "please continue" into the same
  Claude Code session: on the CLI still running, or a new one started with
  `--resume` if it has exited. The message is in the conversation as an
  ordinary message from you, spoken by "a*life", so it's clear you didn't
  type it.
- If it runs into the limit again, it waits again.
- Telling the character anything yourself, stopping it, or starting it over
  cancels the pending continue.
- The clock and the waiting are injected, so tests don't wait.

### 3. Survive a restart (server)

- Pending continues are kept in a small JSON file, `continues.json`, in the
  server's state directory: `ALIFE_STATE_DIR`, `~/a-life-state` unless it is
  set, like the lot, voice and projects directories.
- On startup the server reads it and waits again for each character still in
  it, showing it as waiting for the limit; if the time has passed already,
  it carries on shortly after starting. Entries go once sent or cancelled.

### 4. Show it in the app

- Where the character's status is shown (the status pill, its button, the
  panel), a character waiting out the limit reads "Back at 15:01" rather
  than idle or an error.
- The log says when a character hit the limit and when it will be back, and
  when a*life told it to carry on.

## Done when

- A turn that ends on the 5-hour limit sends exactly one "please continue",
  a minute after the reset, into the same session, and waits again if it
  hits the limit again.
- Interrupting, starting over or telling the character something cancels it.
- A weekly limit is only reported, as now.
- Pending continues survive a server restart, through the file.
- The app shows when a character is back, and logs the automatic continue.
- Tests cover all of the above, with a clock that doesn't wait, plus
  decoding the new stop reason and time. All tests pass, the app builds, and
  the READMEs say how it works.

## As built

- **What the CLI says, checked.** In the installed Claude Code (2.1.323)
  the SDK schema has a `rate_limit_event` message ("emitted when rate limit
  info changes") with `rate_limit_info`: `status` (`allowed`,
  `allowed_warning`, `rejected`), `resetsAt` (integer, seconds since 1970),
  `rateLimitType` (`five_hour`, `seven_day`, `seven_day_opus`,
  `seven_day_sonnet`, `seven_day_overage_included`, `overage`), plus
  `utilization`, `isUsingOverage` and the like. A refused request becomes an
  assistant message with `error: "rate_limit"` and a line such as "You've
  hit your session limit · resets 3pm (Europe/Berlin)" (the 5-hour limit is
  called the "session limit" or "5-hour limit" there; the others "weekly
  limit", "Opus limit" and so on), then an error `result`. This was read
  from the CLI's bundled code, not seen live: running into the limit on
  purpose wasn't possible here. "Claude AI usage limit reached|<time>" isn't
  in this version any more, but is still read, for older ones.
- **Telling the limit** is `UsageLimit` (`UsageLimit.swift`). The last
  `rate_limit_event` is kept; a turn counts as stopped by a limit if an
  assistant message with an `error` is `rate_limit` or reads like a limit,
  or the `result` is an error that does, or that comes with a `rejected`
  event. `fiveHourReset` then prefers the event (a `rejected` `five_hour`;
  no type and a reset within 5 hours 5 minutes; any other type is not
  waited out) and falls back to the text: "…|<seconds>", or "resets 3pm",
  "3:30pm", "15:00" or "Nov 25, 3pm", in the time zone in brackets if
  there is one. Text that mentions the week, Opus, Sonnet, months, spend,
  credits or budgets isn't waited out. A transient "rate limited" error
  with no reset time stays an error.
- **Waiting** is in `ClaudeCharacter`. The limit's line is held back until
  the turn ends; waited out, it isn't shown, and the session goes idle with
  `usage_limit` and `resumes_at` (the reset plus 60 seconds). Otherwise it
  is shown as an error, once, as before. A task waits on an injected
  `WakeClock` (`SystemWakeClock` wakes at least once a minute to look at the
  time, so a Mac that slept through the reset carries on when it wakes),
  then says "please continue" through the same path as your messages, with
  `Message.aLife` ("a*life") as the speaker, so it is a `user` message in
  the conversation that you can tell from yours. The CLI is still running in
  print mode after a limit, so it usually goes to the same process; if it
  has exited, the session is resumed with `--resume`. A message from you,
  an interrupt (which then says `interrupted`, even with no turn running)
  or a reset calls it off; `shutdown` only stops the task, so the file
  keeps it for the next start.
- **The file** is `PendingContinues` (`PendingContinues.swift`):
  `continues.json` in `ALIFE_STATE_DIR`, `~/a-life-state` unless set, an
  array of `{character, claude_session_id, resets_at}` with `resets_at` in
  seconds since 1970, written atomically and removed once empty.
  `configure` reads it before the characters' first reset (which forgets
  what each waited for) and hands each its entry with `carryOn(after:)`,
  which waits again, or carries on ten seconds after starting if the reset
  has passed. With `players` given (the tests) and no `stateDirectory`,
  nothing is written.
- **The wire format.** `StopReason.usageLimit` (`usage_limit`), and
  `SessionEvent.statusChanged` has a third value, `resumesAt` (default
  `nil`), sent as `resumes_at` in seconds since 1970 and kept in
  `SessionState.resumesAt`, which now encodes itself so the snapshot uses
  seconds whatever the encoder's date strategy. Older front ends see the
  stop reason as `.unknown` and ignore `resumes_at`.
- **The app.** `AgentSession.resumesAt` is set while waiting. A character's
  status reads "Back at 15:01" with an hourglass; the status pill says who
  is waiting for the usage limit and when the first is back, when nobody is
  working or waiting for you. The log has two new kinds: `.usageLimit`
  ("Hit the 5-hour usage limit. Back at 15:01.") and `.continued` ("Told to
  carry on: please continue").
- **Tests.** `UsageLimitTests` (server) use a `TestClock` that only moves
  when the test moves it, with the fake CLI: exactly one "please continue"
  a minute after the reset and not a second before; resuming with
  `--resume` after the CLI exits; waiting again on a second limit; a
  message, an interrupt and a reset each calling it off; the weekly limit
  only reported; the reset read from the old text; the file round-tripping
  across a restart and going once sent; and a limit that reset while the
  server was down. ALifeKit tests decode `usage_limit` and `resumes_at` in
  events and snapshots, and check the log entries.
