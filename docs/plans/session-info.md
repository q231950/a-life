# Plan: show how close the character you're talking to is to compacting

## The problem

You can't see from the app how full a character's Claude Code session is,
or which model plays it. A long job slowly fills the context, Claude Code
compacts the conversation by itself once it reaches a threshold, and you
only notice because the character seems to have forgotten something.
Which model it runs on is whatever `ALIFE_CLAUDE_MODEL` says, or Claude
Code's default, and neither the server nor the app ever shows it.

The person first asked for an info item in the conversation's More menu.
Having read the first version of this plan, they asked for this instead,
in their words: "Instead of the more menu please place a similar ring
like the 5 hour window panel so the context usage (token usage until auto
compaction) is visible below the existing panel in the top left of the
screen for the selected agent's section."

So:

- a second ring, looking like the 5-hour usage ring, on a panel of its own
  directly under the usage panel at the top left;
- always there while there is a character to talk to, and following the
  one you've picked in the agent panel;
- measuring the tokens the character's context holds against the point
  where Claude Code compacts it automatically, not against the model's
  whole window;
- with the model as a small label, where it fits.

The More menu stays as it is, with only Start over.

## What happens now

- **The top left.** `WorldView` lays `UsagePanel(width: $usagePanelWidth)`
  (`ALife/UsageGauge.swift`) over the lot with
  `.overlay(alignment: .topLeading)` and `.padding()`. The panel is only
  there while the server has a current 5-hour window. It reports its width
  through `onGeometryChange`, and the status pill's `.overlay(alignment:
  .top)` gets that width plus 8 points of horizontal padding on both sides,
  so the pill stays centred and clear of it. `UsageRing` draws a 34-point
  ring trimmed to a `UsageWindow`'s `utilization`, green, orange from 70%
  and red from 90% (`UsageWindow.band`), with the percentage or "?" in the
  middle.
- **Who is picked.** `WorldView` owns `@State private var selectedID:
  String?` and hands it to `AgentPanel` as a binding. `nil` means the first
  character: `server.session(selectedBy: selectedID)` (in
  `AgentPanel.swift`) returns the session with that id, or the first one.
  `WorldView.selected` already uses it for the ring under the character on
  the lot.
- **How a session runs.** `ClaudeCharacter`
  (`a-life-server/Sources/ALifeServer/ClaudeCharacter.swift`) starts the
  `claude` CLI with `--print --input-format stream-json --output-format
  stream-json --verbose …`, and `ClaudeCode.launch` adds `--model` only if
  `ALIFE_CLAUDE_MODEL` is set. It starts the CLI with a character's first
  message, and sends it a `control_request` `initialize` straight away.
  `handle(_:from:)` reads each line by its `type`: `rate_limit_event`,
  `assistant`, `user`, `system` (only the `task_*` subtypes), `result`,
  `control_request` and `control_cancel_request`. Everything else,
  including every `control_response` and the `system` `init` message, is
  dropped. The control requests it sends (`initialize`, `interrupt`,
  `stop_task`) get a fresh `request_id` and their answers are never read.
- **What Claude Code says** (checked in the 2.1.323 CLI's own code, not yet
  in a captured run):
  - The `system` `init` message has `model`, the main loop's model id as
    Claude Code resolved it.
  - Every `assistant` message has `message.model` and `message.usage`
    (`input_tokens`, `cache_creation_input_tokens`,
    `cache_read_input_tokens`, `output_tokens`). The character's own have
    no `parent_tool_use_id`; its helpers' have one, and contexts of their
    own.
  - The `result` at the end of a turn has `modelUsage`, keyed by model,
    each with `contextWindow`.
  - The control request `{"subtype": "get_context_usage"}` (the Agent SDK's
    `getContextUsage()`) is answered with what `/context` shows:
    `totalTokens`, `maxTokens` (the window auto-compact works within),
    `rawMaxTokens`, `percentage`, `model`, `autocompactSource`,
    `isAutoCompactEnabled`, and `autoCompactThreshold`, the token count at
    which it compacts (left out when there is none), with a breakdown by
    category and `apiUsage`, the last call's usage. The CLI counts it among
    the requests it answers while it is busy. It can be refused ("not
    supported in this context").
  - **How Claude Code works out the threshold.** The window it compacts in
    is the model's window, unless `CLAUDE_CODE_AUTO_COMPACT_WINDOW`, the
    `autoCompactWindow` setting (also per model, and set with
    `/autocompact`), server-side client data or an experiment says
    otherwise, clamped to the model's window; the threshold is that window
    less a buffer for the summary, lowered further by
    `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE`. Auto-compact is off with the
    `autoCompactEnabled` setting false, or with `DISABLE_AUTO_COMPACT` or
    `DISABLE_COMPACT` set. And in some modes compaction is left to the API
    turning a prompt away as too long, so there is no threshold it fires
    at.
- **The wire.** A session travels as `SessionState`
  (`ALifeKit/Sources/ALifeAPI/SessionEvent.swift`), built by applying
  `SessionEvent`s. Unknown event types decode as `.unknown` and are
  skipped, and `SessionState` decodes missing fields tolerantly, so a new
  event and a new optional field work both ways with older servers and
  front ends. `AgentSession.record` writes chosen events to the `EventLog`
  and leaves the rest out (`default: entry = nil`).

## The plan

### 1. The compaction point: ask Claude Code (server)

**Decided: the threshold comes from Claude Code itself, through
`get_context_usage`; a*life doesn't work it out.** Working it out would
mean copying Claude Code's rules: the model's window, the buffer, two
environment variables, a setting per model in any of the settings files,
the `/autocompact` command, and server-side client data and experiments
a*life can't see. Any of them can change with a new release, and a
threshold that's off by the buffer makes the ring say 90% when Claude Code
is about to compact, or 100% when it isn't. `get_context_usage` gives the
figure Claude Code acts on, and says when there is none.

- **Asking.** `ClaudeCharacter` sends `{"type": "control_request",
  "request_id": …, "request": {"subtype": "get_context_usage"}}`:
  - once the CLI has started (after `initialize`), so the ring has its
    threshold and model before the first turn ends;
  - after each `result`, since a turn can change the model, the settings or
    what's in the context;
  - after a `compact_boundary` (a `system` message), since compacting
    empties most of it.

  At most one at a time: if one is out, another is only noted, and sent
  when the answer comes.
- **Answers.** `handle` gets a case for `control_response`: an answer whose
  `request_id` is the one asked about is read, and any other is still
  ignored, as now. From a `success` it takes `model`, `totalTokens`,
  `autoCompactThreshold`, `isAutoCompactEnabled` and `maxTokens`. An
  `error` (refused, or a CLI from before the request) is logged once and
  not asked again for this run: the ring then measures against the window
  (below).
- **Between answers, live from the stream.** The threshold only changes
  with the model or the settings, but the tokens change with every call.
  So, as the character works, `usedTokens` comes from each `assistant`
  message without a `parent_tool_use_id`: `input_tokens +
  cache_creation_input_tokens + cache_read_input_tokens + output_tokens`,
  the same last-call usage Claude Code counts towards its threshold
  (`get_context_usage`'s `apiUsage`). Helpers' messages are left out. The
  model also comes from `init` and `message.model`, and the window from
  `result.modelUsage`, so there is something to show if
  `get_context_usage` is refused.
- **Said as an event.** A new `SessionEvent.contextChanged(SessionContext)`,
  `session.context` on the wire, emitted whenever what it says changes,
  and not when a message repeats the last (Claude Code writes one
  `assistant` line per content block, with the same usage on each).
- **Starting over** forgets it with the rest of the conversation: `reset()`
  clears it, and `conversation.started` drops it from `SessionState`. **A
  resumed session** (the CLI stopped, and the next message resumes it)
  keeps the last reading until the new run says otherwise.
- **Kept in the snapshot**, so a front end has it the moment it connects.
  Nothing is written to disk: like the rest of a session, it starts afresh
  when the server does.

### 2. The wire (ALifeAPI)

- `SessionContext` in `ALifeAPI` (`Models.swift`), every field optional, so
  a reading says what it knows:

  ```json
  {"model": "claude-opus-4-7", "used_tokens": 84213, "compacts_at": 167000,
   "context_window": 200000, "auto_compact": true}
  ```

  `compacts_at` is `autoCompactThreshold`; `context_window` is
  `maxTokens`, or the `modelUsage` window if Claude Code wasn't asked;
  `auto_compact` is `isAutoCompactEnabled`. Decoded tolerantly.
- `SessionEvent.contextChanged(SessionContext)`, type `session.context`,
  under the key `context`.
- `SessionState.context: SessionContext?`, set by the event, dropped by
  `conversation.started`, written with `encodeIfPresent` and read with
  `decodeIfPresent` (older servers don't send it).
- An event rather than a route of its own, because it is about one
  character, like everything else in a session, it reaches every front end
  live without polling, and older front ends skip it. The cost is one more
  event per call while a character works, about as many as its tool uses
  already make.

### 3. The client (ALifeClient)

- `AgentSession.context: SessionContext?`, read off `state` like the
  others. No new call on `ALifeServerClient`: the event stream brings it.
  `AgentSession.record` leaves `session.context` out of the log.
- Plain helpers, in a new `ALifeClient/SessionContextReading.swift`,
  tested:
  - `measure`: what the ring measures against: `.compaction(at:)` when
    there is a `compacts_at`, `.window(of:)` when auto-compact is off or
    there's no threshold but a window is known, and `nil` otherwise;
  - `share` (`used_tokens` over the measure, clamped to 1, as it can run a
    little past before Claude Code compacts), `percent`, and `band`, with
    the same thresholds as `UsageWindow.band`, so both rings mean the same
    by their colours;
  - `tokensText`: "84k of 167k", "84k" with no measure, "1.2M" for the
    long context, and a spoken form;
  - `modelName`: "Opus 4.7" for `claude-opus-4-7`, "Opus 4.7, 1M" for
    `claude-opus-4-7[1m]`, "Dummy" for `dummy`, and the id as it is for
    anything it can't read.

### 4. The context panel (app)

- **Sharing the ring.** `UsageRing`'s drawing moves into
  `ShareRing(share: Double?, band:, size:, lineWidth:)` in
  `UsageGauge.swift`. `UsageRing` wraps it unchanged, and the new panel
  uses it too, so the two look the same.
- **The panel.** A new `ALife/ContextPanel.swift`, `ContextPanel(session:)`,
  on the same `.thinMaterial` rounded rectangle as `UsagePanel`, with the
  same padding:
  - the ring (34 points), with the share of the way to compacting in the
    middle;
  - beside it, on the first line, a dot in the character's shirt colour
    (from `\.shirts`, as the menus have it) and its name, so it's clear whose
    it is; on the second, "84k of 167k until compacting" in `.footnote`; on
    a third, the model in `.caption2`, secondary.
  - When it measures against the window instead, the second line says "84k
    of 200k, no auto-compact".
  - On a compact width (an iPhone held upright) the panel is shown in full
    as well, ring and model name included: the text goes under the ring, as
    the usage panel's countdown does, with the name, "84k/167k" and the
    model.
- **Under the usage panel.** `WorldView`'s `.overlay(alignment:
  .topLeading)` becomes a `VStack(alignment: .leading, spacing: 8)` with
  `UsagePanel` and then `ContextPanel(session: selected)`, padded as now.
  When the usage panel isn't there (no current window), the context panel
  moves up into its place. The two have their own widths, left-aligned.
- **Keeping clear of the pill.** The width the pill keeps clear of is now
  the column's, measured on the `VStack`, rather than the usage panel's.
  `UsagePanel`'s `width` binding goes, and `usagePanelWidth` becomes
  `topLeftWidth`. To be checked in the iPhone Simulator held upright,
  where the column is taller than the pill and the pill's text can run to
  two lines.
- **Following who you've picked.** `WorldView` passes `selected`, which
  follows `selectedID`, as the agent panel's buttons, the log and tapping a
  character on the lot change it. `ContextPanel` reads `session.context`
  off the observable `AgentSession`, so it fills as the character works,
  with `.animation(.easeInOut, value:)` as the usage ring has, and switches
  at once (no animation) when you pick someone else.
- **Over the panel**, a tap or a scroll doesn't reach the lot, as with the
  usage panel.
- **Accessibility.** One element: "Builder's context: 50 percent of the way
  to compacting, 84 thousand of 167 thousand tokens, Opus 4.7".

### 5. When there's nothing to show, or it isn't known

- **No characters** (not connected yet, or no one on the lot; `selected` is
  `nil`): no context panel.
- **A character with no session yet** (nothing said since the server
  started or since starting over; `context` is `nil`): the panel is there,
  with the empty ring, a "–" in the middle, the name, and "Not started", so
  it doesn't jump in and out as you pick characters.
- **Started, threshold not yet known** (asked, not yet answered): the
  tokens so far, "12k", with "?" in the ring.
- **Auto-compact off, or no threshold** (`auto_compact` false, or Claude
  Code compacts only when the API turns a prompt away): against the window,
  as above.
- **An older server** sends no `context`: that looks like no session yet,
  which says nothing wrong.
- **A dummy character** shows its made-up figures, with "Dummy" as its
  model.

The panel has no "as of" or dimming: a context doesn't go stale while the
character is idle, it stays as full as it was.

### 6. The dummy characters

`DummyCharacter` emits `session.context` too, so the panel can be tried with
`ALIFE_BACKEND=dummy`: `model` `dummy`, `context_window` 200,000,
`compacts_at` 167,000, `auto_compact` true, and `used_tokens` starting at
about 15,000 with the first message and going up by a few thousand at each
step of its script, so a few instructions take the ring past amber and red.
Once it would pass `compacts_at`, it "compacts" back down to about 20,000,
as Claude Code would. Starting over begins again with none.

### Not doing, and why

- **Working out the threshold in a*life** from the window and the buffer:
  see the decision in step 1.
- **Reading `autocompact_state`.** Claude Code has a message with exactly
  this (the window, the threshold, whether it fires), but it is internal,
  and only sent by its cloud workers, not by the CLI the server runs.
- **The More menu's Session info and its sheet**, from the first version of
  this plan: replaced by the panel.
- **Choosing the model from the app** (`set_model`): the person asked to see
  it, not change it.

## Done when

- **Server** (`ClaudeCharacterTests`, with `FakeClaudeCLI.say` and what it
  was `sent`):
  - `get_context_usage` is asked once the CLI starts, after each `result`
    and after a `compact_boundary`, never two at a time, and an answer
    sets `model`, `used_tokens`, `compacts_at`, `context_window` and
    `auto_compact`;
  - an answer to another request is ignored; an `error` answer stops the
    asking for that run, and the reading falls back to the `modelUsage`
    window;
  - a main-thread `assistant` message's usage updates `used_tokens` live,
    a helper's changes nothing, and a repeated line emits nothing;
  - `reset()` forgets it; a resumed CLI keeps it until it says otherwise;
  - the dummies' context grows with each step, "compacts", and is gone
    after starting over; and a front end following the dummies sees it end
    to end (in `ALifeServerTests`, giving Vapor arguments of its own, as the
    usage test does).
- **ALifeKit** (`SessionStateTests`, a new `SessionContextTests`,
  `ServerConnectionTests`):
  - `session.context` round-trips, decodes with fields missing, and an
    unknown event type is still skipped;
  - `SessionState` keeps the context, drops it on `conversation.started`,
    and decodes a snapshot without one;
  - `measure` (threshold, window when auto-compact is off, nothing),
    `share` clamped, `percent`, `band`, `tokensText` and `modelName`,
    including ids it can't read;
  - `AgentSession.context` follows the stream, and the event doesn't reach
    the log.
- **App**: the context panel sits under the usage panel, or in its place
  when there's no window; it follows the character picked; it fills live;
  the cases in step 5 read as written; the pill stays clear of the column
  on an iPhone upright; it builds for macOS and the iOS Simulator.
- **Docs**: the server's README (The API: `context` in the session's
  state; The event stream: `session.context`; The characters: where the
  figures come from and `get_context_usage`; The dummy characters: their
  made-up context; Layout, if a file is added) and README.md's files table
  (`WorldView.swift`: the column at the top left; `ContextPanel.swift`;
  `UsageGauge.swift`: `ShareRing`; and the `ALifeKit` section's
  `AgentSession.context`).

## Decided

- The ring measures the context against Claude Code's auto-compact
  threshold, not the model's whole window (the person's call), and against
  the window only when there is no threshold.
- The threshold comes from `get_context_usage`, not from a*life's own
  sums.
- The panel sits under the usage panel at the top left, follows the
  character you've picked, and replaces the More menu idea.
- On an iPhone held upright the second panel is shown in full too, ring
  and model name, not shrunk to a ring alone.
- The characters compact by the person's own Claude Code settings; nothing
  in the agents file sets them.
- Before a session begins the panel says "Not started", rather than the
  model the server will ask for.

## Open questions

- **Does `get_context_usage` work with the server's CLI?** To check in a
  captured run (it costs a little usage): that it is answered in
  `--print` stream-json mode rather than refused, that it is answered
  mid-turn as well as between turns, and whether answering it calls the
  API to count tokens. If it does, asking once per turn is still cheap; if
  it is refused, the panel can only measure against the window, and
  working the threshold out ourselves would have to be looked at again.
- **Does the live figure agree with the threshold?** That the four usage
  figures on the latest main-thread `assistant` message add up to what
  Claude Code compares with `autoCompactThreshold` (its `totalTokens` or
  `apiUsage`), and that stream-json's `assistant` lines carry the final
  `output_tokens` rather than a partial count. If they differ much, the
  ring would jump each time an answer comes.

## As built

- **The server.** `ClaudeCharacter` keeps a `SessionContext` and emits it as
  `session.context` whenever it changes (`sayContext`), never an empty one.
  It asks `get_context_usage` right after `initialize`, after each `result`
  and after a `compact_boundary`, with one question out at a time
  (`contextQuestion`; asked meanwhile, it asks once more when the answer
  comes). A `control_response` to that question sets `model`, `usedTokens`
  (`totalTokens`), `autoCompact`, `compactsAt` (none while auto-compact is
  off) and `contextWindow` (`maxTokens`). An error answer is logged, and it
  isn't asked again until the CLI starts again. The `init` message and each
  of the character's own `assistant` messages (not `<synthetic>` ones, nor
  its helpers') set the model and the tokens (`usedTokens(_:)`), and each
  `result` the window from `modelUsage` (`contextWindow(in:for:)`, matching
  the model with or without a suffix such as `[1m]`, and taking the only
  entry when the model isn't known), used unless Claude Code has said
  `maxTokens`. `reset()` forgets it all; a CLI that exits keeps the reading
  and asks afresh when it starts again. `JSONValue` gained `object`.
- **The dummies.** `DummyCharacter` fills a made-up context: 15,000 tokens
  with the first message, 12,000 a step and 2,000 a reply or message,
  dropping to 20,000 once it would pass 167,000, in a 200,000 window, as
  model `dummy`. Starting over empties it.
- **The wire and the client** are as planned: `SessionContext` in
  `Models.swift`, `SessionEvent.contextChanged` (`session.context`),
  `SessionState.context`, `AgentSession.context`, and the helpers in
  `SessionContextReading.swift`. `band` reuses `UsageWindow.Band`.
- **The app.** `ShareRing` in `UsageGauge.swift` draws both rings, at
  one size for both on every screen (`ShareRing.size`, 34 points, and
  `ShareRing.lineWidth`, 4, which neither panel can change);
  `UsageRing` wraps it. Both panels are laid out by one `TopLeftPanel`,
  so they are the same size whatever they say: the ring, then a headline
  (`.footnote`, or `.caption` on a compact width) and a detail line
  (`.caption2`, secondary), in the same padding and material. The usage
  panel's detail is "5-hour usage", or "as of 14:02" when stale; the
  context panel's headline is the tokens and its detail the name by its
  shirt's dot with the model ("Builder · Opus 4.7"), so the model shows on
  an iPhone held upright too. Each panel stretches to the width it is
  given, and the column is an `EqualWidthColumn`, a small `Layout` that
  asks each panel how wide it would like to be, gives every one the widest
  of those, and stacks them 8 points apart (`EqualWidthColumn.spacing`),
  skipping a panel with nothing to show, so there's no gap while the usage
  panel isn't there. (A `VStack` made `fixedSize` across, with the panels
  stretching to it, didn't keep the widths equal in the Simulator.) (Before this, the context panel had three lines to the usage
  panel's one or two, so it was the taller, and its longer words made it
  the wider too.) `UsagePanel` lost its `width` binding and keeps 8
  points under itself while it shows. `WorldView`'s top-left overlay is a
  column of `UsagePanel` and `ContextPanel(session: selected)`, the latter
  with `.id(selected.id)` so it switches at once, measured as a whole
  (`topLeftWidth`) for the pill to keep clear of: on both sides on a wide
  screen, so it stays centred, and only on the left on a compact width,
  where the column is wide enough that a centred pill was squeezed to
  "Buil de…". `ContextPanel` shows the
  ring ("–" before the session starts, "?" until there's something to
  measure against), "84k of 167k until compacting" or "…, no
  auto-compact", and the name by a dot in the shirt's colour with the
  model; on a compact width the words go under the ring, with "84k/167k",
  and the model is still shown.
- **Tests.** Server `ContextTests` (13) and the updated handshake in
  `ClaudeCharacterTests`; ALifeKit `SessionContextTests` (10) and a
  `ServerConnectionTests` case. `get_context_usage` is only exercised
  against the stand-in CLI: **the live check of the open questions above is
  still to be done.**
- **Checked by eye** in the Simulator with the dummy characters: on an
  iPhone 17 held upright and an iPad Air 11-inch, the usage and context
  panels were the same width (and height), the context panel alone
  ("Not started") sat at the top with no gap, and the status pill was clear
  of the column. Not checked by eye on macOS, which only builds; it uses
  the same layout as the iPad.
