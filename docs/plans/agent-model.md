# Plan: choose the model each character runs on

> **Since this was written**, the agents are in three layers: the Team Lead,
> the Builder, the Conservationist and the a*life Engineer (still `engineer`)
> are built into the server (`builtin-agents.yaml`), so their models, roles
> and helpers are fixed by the server and update with it; `agents.yaml` is
> the person's own, which only they edit; and the agents the Team Lead adds
> are in a file of their own, `ALIFE_ADDED_AGENTS_FILE`, where `add-agent`
> writes and `remove-agent` takes away, and which the running server watches
> so agents join and leave at once. Below, "the agents file" is where a
> character's `model` comes from, which for the built-in agents is the
> server's own definition, and "`Cast` only ever adds to it" now holds for
> the added agents file. See "The Team Lead and the added agents" in
> `a-life-server/README.md`.

## The problem

Every character runs on the same model. The person asked: "create a plan
that allows the selection of a model for an agent."

Today the model is one setting for the whole server, `ALIFE_CLAUDE_MODEL`,
or Claude Code's own default when it isn't set. But the characters do very
different jobs: the Engineer and the Flamingo Engineer change code across
repositories, the Apple Specialist answers questions, and the Builder and
the Conservationist write a few lines of YAML into the lot. The person
would want the engineers on a strong model and the lot's characters on a
quick, cheap one, and there is nowhere to say so.

Having read the first version of this plan, the person asked, in their
words: "Please update the plan to have a model picker in the prompt panel.
Keep simple names if possible. Delete the env var alive_claude_model and
set sensible default values like the proposed conservationist/builder
presets. I'd like to see the actual model version in the context panel."

So:

- each agent in the agents file has a `model`, by its simple name (`haiku`,
  `sonnet`, `opus`, `fable`), and every shipped agent has a sensible one;
- `ALIFE_CLAUDE_MODEL` goes: the agents file (or the app's choice) is the
  only place a model is chosen, and an agent without one runs on Claude
  Code's own default;
- a model picker in the prompt panel, where you type to the character you
  have picked, changes the model it runs on;
- the context panel shows the version the character really runs on, such
  as "Opus 5.5", even when it was chosen as `opus`.

Approving the plan, the person added: "Add to the plan that the context
panel should have an extra line for the model name." So the model gets a
line of its own in the context panel, under the character's name, rather
than being joined onto it with " · ".

## What happens now

- **The setting.** `Players.fromEnvironment(for:lot:logger:)` in
  `a-life-server/Sources/ALifeServer/configure.swift` reads
  `ALIFE_CLAUDE_MODEL` (empty counts as unset) and hands it to
  `ClaudeCode(executable:lot:repository:model:)`. `ClaudeCode`
  (`ClaudeCode.swift`) keeps it as `var model: String?`, and
  `launch(_:in:)` appends `["--model", model]` to every character's
  arguments alike. The `ClaudeCodeLauncher` protocol is only
  `launch(_ arguments: [String], in workspace: Workspace)`.
- **The character's arguments.** `ClaudeCharacter.arguments`
  (`ClaudeCharacter.swift`) is "The CLI's arguments, apart from the model,
  which the launcher adds": `--print`, the stream-json pair, `--verbose`,
  `--permission-prompt-tool stdio`, `--permission-mode`,
  `--append-system-prompt`, `--agents`, and `--resume` once there's a
  session to resume. The CLI starts on the character's first message, and
  again, resumed, if it has stopped. Right after starting, the server sends
  `initialize` and `get_context_usage` control requests; it reads only the
  answer to `get_context_usage` (`handleControlResponse`) and ignores every
  other `control_response`.
- **The helper.** `Helper.definition` (`Cast.swift`) always sends `"model":
  "inherit"`.
- **The agents file.** `Character` (`Cast.swift`) has `id`, `name`,
  `color`, `changesThings`, `permissionMode`, `workspace`, `role` and
  `helper`, all `let`, built in `AgentEntry.init(from:)`. `AgentEntry`'s
  `CodingKeys` are the fields it knows, and `rejectUnknownFields` refuses
  any other, listing them. `permission_mode` is optional
  (`container.optional`, which also refuses it empty) and checked against
  `Cast.permissionModes`: `"\"x\" isn't one of Claude Code's permission
  modes: default, manual, …"`. `HelperEntry` knows `name`, `tools`,
  `description` and `prompt`. `AddAgent.swift` checks a new agent with
  `Cast.decode`, so it takes whatever `AgentEntry` takes. The Team Lead's
  role and its recruiter's prompt in `agents.yaml` list the fields the
  recruiter writes.
- **Where `ALIFE_CLAUDE_MODEL` is mentioned:** `configure.swift` (the
  comment on `fromEnvironment` and the reading of it); `ClaudeCode.model`;
  `LiveClaudeCodeTests` (its comment and `ClaudeCode(…, model:
  environment["ALIFE_CLAUDE_MODEL"])`); `ClaudeCharacterTests`'s
  `testClaudeCodeRunsInTheLotWithHelpersInTheForeground` (`ClaudeCode(…,
  model: "haiku")`, checking `--model haiku`); the server's README
  (Settings, the example under it, the sentence under the agents file's
  table, and the live test's command under Tests); and the a\*life
  expert's prompt in `agents.yaml` ("Its settings are environment
  variables: … ALIFE_CLAUDE_MODEL …"). `docs/plans/session-info.md`
  mentions it too, as history, and stays as it is.
- **The prompt panel.** In `ALife/AgentPanel.swift`, `AgentPanel` shows the
  conversation with the character you've picked as `ConversationView`: a
  header (`CharacterStatus` and a More menu with Start over), the
  conversation (`ConversationHistory`), the last error, and at the bottom
  the row you type in: a `TextField` ("Talk to Builder", or "Answer Builder
  first" while it waits for you), Send, and Stop while it runs or waits.
  That row is the prompt panel. Typing and Send are disabled while the
  character waits for your answer, and the whole row while the server isn't
  connected.
- **Settings for one session, on the wire.** Auto approve is the pattern to
  follow: `PUT /v1/sessions/{id}/auto-approve` (`routes.swift`) calls
  `SessionBackend.setAutoApprove`, the hub emits `session.auto_approve`
  (`SessionEvent.autoApproveChanged`), `SessionState.autoApprove` carries
  it, `ALifeServerClient.setAutoApprove(_:in:)` and
  `AgentSession.setAutoApprove(_:)` call it, and
  `SessionHub.startConversation()` emits it again after starting over,
  since "it is the session's, not the conversation's".
- **What the context panel shows.** `ClaudeCharacter` sets
  `SessionContext.model` from the `system` `init` message, each of the
  character's own `assistant` messages (`message.model`) and
  `get_context_usage`'s answer (`model`), and emits it as
  `session.context`. `ALife/ContextPanel.swift` shows `session.name` and
  `context?.modelName` ("Builder · Opus 4.7"). `modelName`
  (`ALifeKit/Sources/ALifeClient/SessionContextReading.swift`) turns a full
  id into a name: `claude-opus-5-5` is "Opus 5.5", a date at the end is
  dropped, `[1m]` becomes ", 1M", `dummy` is "Dummy", and anything else,
  an alias such as `opus` or `default` included, is shown as it is. Before a
  session starts (`context == nil`) the panel says "Not started", without a
  model.
- **What Claude Code 2.1.323 says about models** (checked on this Mac on
  2026-11-22):
  - `claude --help`: "`--model <model>` Model for the current session.
    Provide an alias for the latest model (e.g. 'fable', 'opus', or
    'sonnet') or a model's full name."
  - The answer to `initialize` has `models`, a list of `{value,
    resolvedModel, displayName, description, …}`. Asked with nothing else
    (no prompt, so no turn), it began with:

    | `value` | `resolvedModel` | `displayName` | `description` |
    |---|---|---|---|
    | `default` | `claude-opus-5-5` | Default (recommended) | Opus 5.5 · Best for everyday, complex tasks |
    | `opus` | `claude-opus-5-5` | Opus 5.5 | For complex work and everyday tasks |
    | `sonnet` | `claude-sonnet-5-5` | Sonnet 5.5 | Most efficient for simpler tasks |
    | `fable` | `claude-fable-5-2` | Fable 5.2 | For your toughest challenges |
    | `haiku` | `claude-haiku-5-5` | Haiku 5.5 | Fastest for quick answers |

    followed by full ids of older versions (`claude-fable-5-1`,
    `claude-opus-4-8`, `claude-haiku-4-5-20251001`, …).
  - The CLI's own code also lists `sonnet[1m]`, `opus[1m]`, `fable[1m]`,
    `best` and `opusplan` among its aliases, and a shorter list of `sonnet`,
    `opus`, `haiku` and `fable`, which looks like the one subagent
    definitions take besides `inherit`.
  - It has a `set_model` control request, `{"subtype": "set_model",
    "model": "opus"}`: "Model to switch to. Omitted, null, or 'default'
    resets to the session default model." It answers with a
    `control_response`, an error if the model isn't a string.

## The plan

### 1. Simple names, shared by the server and the app (ALifeAPI)

A new `ClaudeModel` in `ALifeAPI` (`Models.swift`), the models a character
can be given:

```swift
public enum ClaudeModel: String, Codable, CaseIterable, Sendable {
    case fable, opus, sonnet, haiku
}
```

- **Only Claude Code's four plain aliases**, which always mean the latest
  of each family, so `opus` follows Opus to its next version without
  anyone editing the agents file. They are what the person asked for
  ("simple names"), what `--model` and a subagent's `model` both take, and
  short enough for a menu.
- Each has a `name` for when nothing better is known ("Opus"), and the
  order they're listed in (`allCases`, strongest first).
- **Not offered:** full ids (`claude-opus-5-5`), `default` (leaving the
  model out is the default), `best`, `opusplan` and the `[1m]` variants.
  They would make the list longer and harder to read for little gain.
  Adding one later is one more case.
- **Recommended: the agents file and the picker take only these four
  names.** This turns round the first version of this plan, which took any
  word. With simple names as the rule, a list catches a typo such as `opsu`
  when the server starts, rather than on the character's first turn, and
  the server and the app share one list, so the picker and the file can't
  disagree. The cost is that a new family needs a new case, which is a
  small change in one place.

`ModelOption`, also in `ALifeAPI`, is one entry of the picker: `model`
(a `ClaudeModel`), `name` ("Opus 5.5"), `description` ("For complex work
and everyday tasks") and `resolved` (`claude-opus-5-5`), the last three
optional.

### 2. A `model` for each agent in the agents file (server)

```yaml
  - id: builder
    name: Builder
    model: haiku
    ...
    helper:
      name: construction-worker
      ...
```

- `Character` gains `let model: ClaudeModel?`, "the model Claude Code plays
  the character on, unless it has been changed in the app; `nil` for Claude
  Code's own default". `AgentEntry.CodingKeys` gains `case model` after
  `permission_mode`, so the unknown-field error lists `id, name, color,
  permission_mode, model, works_in, …`.
- It is read with `container.optional(String.self, .model)` (so `model:`
  left empty is refused as the other optional fields are) and checked
  against `ClaudeModel`, as `permission_mode` is against
  `Cast.permissionModes`:

  ```
  agents.yaml: agents[1].model "opus-5" isn't one of the models a character can run on: fable, opus, sonnet or haiku. Leave it out for Claude Code's default.
  ```

- `helper.model`: `Helper` gains `let model: ClaudeModel?`, read and checked
  the same way, with its own message; `definition` sends `"model":
  model?.rawValue ?? "inherit"`, so a helper without one runs on its
  character's model, whatever that is at the time, as now.
  `HelperEntry.CodingKeys` gains `model` after `tools`.
- `CastTests` builds `Character(…)` and `Helper(…)` by hand in a few
  places; they gain `model:` arguments, so every field is spelt out where
  it is checked.
- `add-agent` needs no code: it checks with `Cast.decode`.

### 3. `ALIFE_CLAUDE_MODEL` goes (server)

- `configure.swift`: the line reading it and its entry in the comment on
  `fromEnvironment` go. If it is still set, the server logs a warning once
  at start, "ALIFE_CLAUDE_MODEL isn't read any more: give each agent a
  model in the agents file", so nobody wonders why it has stopped working.
  (A warning rather than refusing to start, since nothing breaks.)
- `ClaudeCode.model` and its `init` argument go.
- **The model moves into the character's arguments.**
  `ClaudeCharacter.arguments` adds `["--model", model.rawValue]` when the
  character has a model (below, the one it runs on now), and its comment
  becomes "The CLI's arguments". With no fallback left in `ClaudeCode`, the
  launcher has nothing to add, so the `ClaudeCodeLauncher` protocol stays as
  it is and `FakeClaudeCode`'s recorded arguments show the model.
- `LiveClaudeCodeTests` loses its model setting: it plays the shipped
  Builder, who now runs on `haiku`, the cheap one, by the agents file.

### 4. The shipped agents' models

Recommended, each with why. Helpers inherit their character's model
unless said otherwise.

| Agent | `model` | Helper | Why |
|---|---|---|---|
| Builder | `haiku` | inherits | Its construction worker writes a few lines of YAML into `buildings/` and checks `lot.md`: quick, small and well described. |
| Conservationist | `haiku` | inherits | The same for its keeper and `garden/`. |
| Team Lead | `sonnet` | inherits | A conversation to find out who the new agent is, and a recruiter writing one careful entry that `add-agent` checks; it needs judgement, not depth. |
| Engineer | `opus` | inherits | Its a\*life expert changes a Swift 6 server, a package and a RealityKit app together, with tests and docs. |
| Flamingo Engineer | `opus` | inherits | Changes that span three repositories and have to fit together. |
| BTLB Engineer | `opus` | inherits | Feature work and fixes in an app it learns as it goes. |
| lo-life | `opus` | inherits | Feature work on a newer framework (Foundation Models), where care matters. |
| Apple Specialist | `opus` | `sonnet` | Its answers have to be right, so the specialist weighs them on `opus`; its researcher mostly fetches pages and type-checks samples, which `sonnet` does well and quicker, and the specialist checks what it brings back. |

`fable` (Fable 5.2, "For your toughest challenges") is offered in the
picker but set on nobody by default, as it is the costliest; the person can
pick it for a hard job, from the app, without touching the file.

The commented App Engineer example at the end of the file gets `model:
opus`, like the other engineers.

### 5. The model picker in the prompt panel (app, client, wire, server)

**Where.** In `ConversationView`'s bottom row, to the left of the text
field: a small borderless `Menu` whose label is the model's short name and
version ("Haiku 5.5", or "Haiku" until the version is known; "Default" for
an agent without one), in `.footnote`, with a `cpu` symbol, so it reads as
part of what you're about to send. On a compact width it shows the family
only ("Haiku"), to leave room for the text field. Its items, strongest
first: one per `ModelOption`, with the name and the description as a
subtitle, and a checkmark on the current one; then a divider and "As in
the agents file (Haiku)" when the app's choice differs from the file's.
The menu has an accessibility label: "Model: Haiku 5.5".

**What it calls.**

- `PUT /v1/sessions/{id}/model` with `{"model": "opus"}`, or `{"model":
  null}` to go back to the agents file's. A name not in `ClaudeModel` is a
  `400` saying which names there are. `SessionBackend` gains
  `setModel(_ model: ClaudeModel?) async`.
- `GET /v1/models`: the `ModelOption`s, for the picker's names and
  descriptions (below).
- `SessionState` gains `model: ClaudeModel?` (what the character runs on
  now) and `fileModel: ClaudeModel?` (the agents file's), as `model` and
  `file_model`, read with `decodeIfPresent`. A new event,
  `SessionEvent.modelChanged(ClaudeModel?)`, `session.model`, sets
  `model`; older front ends skip it. The hub emits it at start, so the
  snapshot has it, and whenever it changes.
- `ALifeServerClient.setModel(_:in:)` and `models()`;
  `AgentSession.setModel(_:)` (setting `state.model` at once and putting it
  back if the call fails, as `setAutoApprove` does), `AgentSession.model`
  and `fileModel`; `ServerConnection.models: [ModelOption]`, fetched when
  it connects.

**The decisions, each recommended:**

1. **How a change applies: at once, with `set_model`, and otherwise at the
   next start.** If the character's CLI is running, the server sends
   `{"type": "control_request", "request": {"subtype": "set_model",
   "model": "opus"}}`, as it sends `interrupt`, and the conversation goes
   on, on the new model, with nothing lost. If it isn't running, the choice
   is kept and passed as `--model` when it next starts (resumed or new).
   *Why not wait for the next start only:* the CLI stays running between
   turns, so "next start" could mean much later, and the picker would seem
   to do nothing. *Why not restart the session:* it interrupts whatever the
   character is doing, for something `set_model` does in place.
   `ClaudeCharacter` reads the answer to its `set_model` (by `request_id`,
   as it does `get_context_usage`'s). On an error it logs it, emits an
   error message in the conversation ("Couldn't switch the Builder to
   Opus: …") and puts `model` back to what it was.
2. **It outlasts a server restart, in `models.json` in the state
   directory**, beside `continues.json` and `usage.json`, by character id,
   such as `{"builder": {"model": "opus", "file_model": "haiku"}}`. A new
   `ModelChoices` actor keeps it, as `PendingContinues` keeps the waits.
   When the server starts, a character runs on its saved choice, **unless
   the agents file's model has changed since the choice was made**
   (`file_model` differs from the file's now): then the file wins and the
   choice is dropped. *Why:* a choice made in the app shouldn't vanish on a
   restart, but an edit to the agents file is the newer word and should
   take effect. Choosing "As in the agents file" removes the entry. The
   agents file itself is never written: `Cast` only ever adds to it, by
   design.
3. **Start over keeps the choice.** It is the character's, not the
   conversation's: `SessionState` keeps `model` and `fileModel` when
   `conversation.started` is applied (rather than the hub saying it again,
   as it does for auto approve), the snapshot carries both, and the new CLI
   starts with `--model`.
4. **While the character waits for your answer, or for the usage limit,
   the picker still works.** `set_model` doesn't touch a pending approval,
   and a character waiting for the limit to reset carries on, on the new
   model, when it says "please continue". So the picker sits outside the
   part of the row that is disabled while it waits for you (typing and
   Send), and is disabled only while the server isn't connected. Mid-turn,
   the change applies from Claude Code's next call to the model (checked;
   see What the live runs showed).
5. **The helpers follow.** A helper without a `model` of its own inherits
   its character's, so it follows the picker from the next helper sent
   off. A helper with its own (the Apple researcher) keeps it; the picker
   is for the character. One already out finishes on the model it started
   with.
6. **The dummies take the choice too, but don't save it.** `DummyCharacter`
   keeps `model`, emits `session.model`, and the picker works against
   `ALIFE_BACKEND=dummy`; its context still says `dummy`, since no model
   runs. With the dummies, nothing is written to `models.json`, as
   `usage.json` isn't, so trying the app doesn't change the real
   characters.

**Where the picker's names come from.** The server reads `models` from
Claude Code's answer to `initialize` (which it sends already, and now reads
the answer to), keeps the entries whose `value` is one of the four aliases,
and serves them at `GET /v1/models` as `ModelOption`s, names, descriptions
and `resolvedModel` included. So that the names and versions are there
before any character has started, the server asks once when it starts: it
launches `claude` in the lot with only `initialize` on its stdin, reads the
answer, and closes it, in the background, without a prompt and so without a
turn. Until then, or if it can't, `GET /v1/models` gives the four with only
their plain names ("Opus"), and the picker works the same. With the
dummies, it gives the plain names and never asks.

### 6. The real version in the context panel, on a line of its own (server, client, app)

What is wrong now: `modelName` already turns a full id into "Opus 5.5", but
anything that isn't one is shown as it is. If Claude Code reports an alias
anywhere a*life reads the model, or `default`, the panel would say "opus";
before a session starts it shows no model at all; and after a switch it
would show the old one until the next reply.

- **The server only ever says a full id.** The live runs showed that
  everything a*life reads the model from (the `init` message,
  `message.model`, `get_context_usage`'s `model`) is already a full id,
  so nothing more is needed there; the aliases' `resolvedModel`s from the
  `initialize` answer are kept for a switch while the CLI isn't running.
- **On a switch**, once `set_model` is answered with success (or straight
  away, if the CLI isn't running), the server sets `context.model` to the
  new alias's `resolvedModel` and emits `session.context`, so the panel
  changes with the picker rather than at the next reply.
- **A line of its own.** Under the character's name (with its shirt's
  dot), the panel has one more line, in the same small, faint type, with
  the model alone: "Haiku 5.5". The panel is then a line taller than the
  usage panel; the two stay as wide as each other.
- **Before the session starts**, the panel says "Not started" with the
  model it will run on on that line: `AgentSession.modelName(among:)` gives
  `context?.modelName`, or else the `name` of `session.model` in
  `server.models` ("Haiku 5.5"), or "Default model" when there's no model. This turns round the decision in
  `session-info.md` ("Not started" rather than the model the server will
  ask for), because the person now asked to see the version.
- **`modelName`** gains one case: a name it can't read is looked up in the
  options (`ModelOption.resolved` or `model`), so an alias still shows as
  "Opus 5.5" if one slips through; otherwise it's shown as it is, as now.
- The accessibility label reads the same name.

### 7. The Team Lead and `add-agent`

- **The recruiter's prompt** gains a line in its list of fields: "model:
  haiku for an agent that works on the lot, sonnet for one that mostly
  talks, opus for an engineer, unless the Team Lead says otherwise; fable
  only if asked." And for the helper: "leave its model out, so it runs on
  its agent's."
- **The Team Lead's role**: in what it works out with the person, "and how
  strong a model it needs, if that isn't clear from what it does", without
  asking when it is.
- `add-agent` refuses a model not in the list, with the same message.

### 8. Tests

Server (`a-life-server/Tests/ALifeServerTests`):

- **`CastTests`**: every field is read, `model` and `helper.model`
  included; both can be left out (`nil`, and `inherit` in `definition`);
  `model:` empty, `model: opus-5`, `model: claude-opus-5-5` and the same on
  the helper are refused with their messages and paths; the unknown-field
  messages list `model`; an agent with a `model` is added by `add-agent`,
  and one with a bad model is refused, leaving the file as it was; **every
  shipped agent has the model in the table above** (in a test reading
  `ShippedCast.swift`'s cast).
- **`ClaudeCharacterTests`**: the Builder starts with `--model haiku`, an
  agent without one with no `--model`; resumed, it keeps it;
  `testClaudeCodeRunsInTheLotWithHelpersInTheForeground` no longer passes
  a model and checks there's no `--model` added by the launcher; the
  `--agents` checks see `inherit` for the shipped helpers and `sonnet` for
  the Apple researcher.
- **A new `ModelTests`**: `setModel` while the CLI runs sends `set_model`
  and emits `session.model`; a success answer sets `context.model` to the
  resolved id; an error answer puts the model back and says so; while it
  isn't running, the next start has the new `--model`; while waiting for an
  approval or the usage limit it still switches, and "please continue"
  goes on the new model; Start over keeps it; `models.json` keeps it across
  a restart and drops it when the file's model has changed; "As in the
  agents file" (`nil`) removes it; the `initialize` answer's models are
  read, and an alias read off the stream becomes the full id; the dummies
  take a choice and don't write it; `PUT …/model` with an unknown name is a
  `400`; `GET /v1/models` gives the four, with versions when known.
- `ALIFE_CLAUDE_MODEL` set logs the warning and changes nothing.

ALifeKit (`ALifeKit/Tests/ALifeKitTests`):

- `session.model` round-trips, `SessionState` keeps `model` and
  `file_model`, decodes without them, and `conversation.started` doesn't
  drop them; `ClaudeModel` and `ModelOption` decode, and an unknown model
  name in a snapshot from a newer server doesn't break the session (decoded
  as `nil` rather than failing);
- `AgentSession.setModel` calls the route and puts the model back if it
  fails; `ServerConnection.models` is fetched on connect;
- `modelName` with an alias and options (`opus` to "Opus 5.5"), and
  without.

App: no tests of its own. Build for macOS and the iOS Simulator, and check
by eye with the dummies: the picker in the prompt panel on an iPad and on
an iPhone held upright, switching while the character works and while it
waits for you, the context panel's name before and after starting.

`swift test --package-path ALifeKit` and `swift test --package-path
a-life-server`. `LiveClaudeCodeTests` isn't run.

### 9. Docs

- **`a-life-server/README.md`**: Settings loses `ALIFE_CLAUDE_MODEL`, and
  the example under it loses it too; "Run it" says the characters use your
  Claude Code login and settings, and each the model the agents file gives
  it. The API gains `PUT /v1/sessions/{id}/model` and `GET /v1/models`, and
  `model` and `file_model` in a session's state; The event stream gains
  `session.model`. The characters: `--model`, `set_model`, `models.json`
  and the start-up question for the names. The agents file: `model:` in
  the sample entry, rows for `model` and `helper.model`, the
  `helper.prompt` row losing "It runs on its character's model", the
  sentence under the table becoming "The lot and the a\*life checkout are
  the same for every character; set them with `ALIFE_LOT_DIR` and
  `ALIFE_REPO_DIR`.", and a model mistake among the example errors. The
  dummy characters: they take a model but don't save it. Layout: the new
  file (`ModelChoices.swift`). Tests: `ModelTests`, and the live test's
  command without `ALIFE_CLAUDE_MODEL`.
- **`agents.yaml`**: the comment at the top gains `model` (one of fable,
  opus, sonnet, haiku; Claude Code's default unless set; the app can change
  it) and `helper.model` (its character's unless set); the a\*life expert's
  prompt loses `ALIFE_CLAUDE_MODEL` from its settings and gains "model"
  among Cast.swift's fields; the recruiter's and the Team Lead's prompts as
  in step 7.
- **`README.md`**: the files table's `AgentPanel.swift` (the model picker
  in the prompt panel) and `ContextPanel.swift` (the version, and the model
  before starting); the ALifeKit section's `ClaudeModel`, `ModelOption`,
  `AgentSession.setModel(_:)`, `model`, `fileModel` and
  `ServerConnection.models`.

## Done when

- Every shipped character starts on the model in the table, and the
  context panel shows its version on a line of its own ("Haiku 5.5"),
  before it starts and while it works.
- `ALIFE_CLAUDE_MODEL` is read nowhere; set, it only brings a warning.
- Picking Opus for the Builder in the prompt panel switches it at once if
  it's running, or from its next start, in every front end; the context
  panel shows "Opus 5.5" straight away; it stays Opus after Start over and
  after a server restart, until the agents file's model for it changes or
  you pick "As in the agents file".
- A model that isn't one of the four stops the server (or `add-agent`)
  with a message that says where.
- Both packages' tests pass, the app builds for macOS and the iOS
  Simulator, and the READMEs and `agents.yaml`'s comment say what the code
  does. The person restarts the server and builds the app again.

## What the live runs showed

Two short runs of the `claude` CLI (2.1.323) on this Mac, on 2026-11-22,
in an empty directory, each with two or three one-word turns on `haiku`
and `sonnet`:

- **`set_model` works in `--print` stream-json mode.** Between turns, it
  was answered with `{"subtype": "success", "response": {"model":
  "claude-sonnet-5-5"}}`, the full id the alias stands for, and the next
  turn ran on it (`system` `init` and the `assistant` messages said
  `claude-sonnet-5-5`), in the same session. Claude Code also writes a
  `user` line, `<local-command-stdout>Set model to `sonnet
  (claude-sonnet-5-5)`</local-command-stdout>`, marked `isReplay`, which
  has no tool results and so changes nothing here.
- **Mid-turn, it bites at the next call.** Sent just after a message that
  had the character run a command, the first call of that turn was still on
  Sonnet, and the call after the command's result was on Haiku.
- **A model Claude Code doesn't know** is refused: `{"subtype": "error",
  "error": "Model 'nonsense-model' not found"}`.
- **Every model read off the stream is a full id**, even when the CLI was
  started with `--model haiku`: `system` `init`, each `assistant` message's
  `message.model` and `get_context_usage`'s `model` all said
  `claude-haiku-5-5`, and `modelUsage` was keyed by full ids. So turning
  aliases into ids from the stream (step 6) wasn't needed, and isn't built;
  the ids for a switch come from `set_model`'s answer, and from the
  `initialize` list only while the CLI isn't running.
- **Asking only `initialize`** was answered at once with the models, and
  nothing else came: no `system` `init`, no `rate_limit_event`, no
  `result`, so no turn and no call to a model.

## As built

- **ALifeAPI.** `ClaudeModel` (`fable`, `opus`, `sonnet`, `haiku`, with
  `name` and `names`), `ModelOption` (with `displayName`) and
  `ModelChoiceRequest` (an unknown name fails to decode, saying which there
  are, which Vapor answers with `400`; `nil` is sent as `null`), in
  `Models.swift`. `SessionEvent.modelChanged` (`session.model`), and
  `SessionState.model` and `fileModel` (`file_model`), kept across
  `conversation.started`; an unknown model decodes as `nil`.
- **ALifeClient.** `ALifeServerClient.setModel(_:in:)` and `models()`
  (leaving out options it can't read); `AgentSession.model`, `fileModel`,
  `setModel(_:)` (shown at once, put back if the call fails) and
  `modelName(among:)`, which `update(from:)` keeps up with the server's list,
  since a conversation's events may not say the model;
  `ServerConnection.models`, fetched on each connect without holding it up;
  `SessionContext.modelName(among:)`.
- **The server.** `Character.model` and `Helper.model` in `Cast.swift`,
  checked by `checkModel`. `ALIFE_CLAUDE_MODEL` and `ClaudeCode.model` are
  gone; `configure` warns if it is set. `ClaudeCharacter` takes its starting
  `model`, `choices` and `models`, adds `--model` to its own `arguments`,
  reads the answers to `initialize` (the models, for the catalog) and to
  `set_model` (`switched`), and on `setModel` saves the choice, says
  `session.model`, and sends `set_model` while its CLI runs, or else puts
  the new model's id in the context if it knows it. Sending `null` (for an
  agent with no model of its own) asks Claude Code for "the session default
  model", which may be the one it was started on; no shipped agent is
  without a model. `DummyCharacter.setModel` only says it. `SessionHub`
  takes the starting model and the file's, and `setModel(_:)`.
  `ModelChoices.swift` has `ModelChoices` (`models.json`, only with Claude
  Code) and `ModelCatalog` (asked once at start in the background;
  `GET /v1/models` waits for that answer, at most 20 seconds). The routes
  `PUT /v1/sessions/{id}/model` and `GET /v1/models`.
- **agents.yaml.** The models in the table in step 4, the Apple researcher
  on `sonnet`, the header comment, the App Engineer example on `opus`, the
  recruiter's and the Team Lead's lines, and the a\*life expert's settings.
- **The app.** `ModelPicker` in `AgentPanel.swift`, left of the message
  field, shown only when the server offers models, and not disabled while
  the character waits for you. `ContextPanel` has the model on a line of its
  own, from `modelName(among:)`.
- **Tests.** Server: a new `ModelTests` (11), and `CastTests` and
  `ClaudeCharacterTests` updated. ALifeKit: `SessionStateTests` (2 new),
  `ServerConnectionTests` (2 new, the stub serving `/v1/models`),
  `SessionContextTests` (1 new).

## Open questions

None left from this plan: the three above were settled by the live runs.
Still to do by eye: the picker and the taller context panel on an iPhone
held upright and an iPad, which were only built here, not looked at.
