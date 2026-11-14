# a-life-server

The backend the a*life front ends talk to. It is a [Vapor](https://vapor.codes) server meant to run on your own Mac and be reached over [Tailscale](https://tailscale.com).

It holds one session per character on the lot. **Each character is a Claude Code session of its own**, run by the Claude Code installed on your Mac: its conversation, what it is doing, the helpers (subagents) it has sent off, and any tool call it is waiting on you to allow. Front ends follow every session over a stream of events, and talk to each character directly. No character coordinates the others; that's up to you.

The characters work on a *lot*: a directory they share, `~/a-life-lot` unless you say otherwise. The Builder's buildings and the Gardener's beds are Markdown files in it. The Engineer works on a\*life itself instead, by handing jobs to a Claude Code session in the a\*life cloud environment. See [The characters](#the-characters).

If you'd rather not spend tokens, the server can also run dummy characters that play a short script. See [The dummy characters](#the-dummy-characters).

## Run it

You need Swift 6 (Xcode 16 or later) on macOS 14 or later, and [Claude Code](https://code.claude.com) installed and logged in: `claude` in a terminal should start a session. The characters use that login, its settings and its model, and what they do counts towards your usage like any other Claude Code session.

```sh
cd a-life-server
swift run ALifeServer
```

The server finds the `claude` command on your `PATH`, or where its installer puts it, and says which one it uses and where the lot is when it starts. It starts a character's session with the first thing you say to it.

The server listens on `http://127.0.0.1:8080`, which only this Mac can reach. Check it:

```sh
curl http://127.0.0.1:8080/health
# {"status":"ok"}
```

To use another port: `swift run ALifeServer serve --port 9000`.

### Try it without a front end

See who is on the lot:

```sh
curl http://127.0.0.1:8080/v1/sessions
```

In one terminal, follow the Builder's session:

```sh
curl -N http://127.0.0.1:8080/v1/sessions/builder/events
```

In another, tell the Builder what to do, then answer the approval it asks for:

```sh
curl -X POST http://127.0.0.1:8080/v1/sessions/builder/messages \
  -H 'Content-Type: application/json' -d '{"text":"Build me an office"}'

# the Builder sends its construction worker off (subagent.started), which
# asks before it writes buildings/office.md; look up the approval's id ...
curl http://127.0.0.1:8080/v1/sessions/builder

# ... and allow it
curl -X POST http://127.0.0.1:8080/v1/sessions/builder/approvals/<id> \
  -H 'Content-Type: application/json' -d '{"allow":true}'
```

The Gardener's session is at `/v1/sessions/gardener`, and carries on independently. Ask it to plant something and it sends its planter off.

### Settings

All optional, as environment variables:

| Variable | What it does |
|---|---|
| `ALIFE_LOT_DIR` | The directory the characters work in. `~/a-life-lot` unless set; it is made if it isn't there. |
| `ALIFE_CLAUDE_PATH` | The `claude` command, if the server doesn't find it by itself. |
| `ALIFE_CLAUDE_MODEL` | The model for every character, such as `sonnet` or `haiku`. Claude Code's own default unless set. The helpers use their character's model. |
| `ALIFE_BACKEND` | `claude` (the default), or `dummy` for the scripted dummies. |
| `ALIFE_AGENTS_FILE` | The agents file, which lists the characters. The shipped [`Sources/ALifeServer/agents.yaml`](Sources/ALifeServer/agents.yaml) unless set. See [The agents file](#the-agents-file). |
| `ALIFE_CLOUD_SESSION` | The cloud session the Engineer sends its jobs to: its ID (`session_...`) or its claude.ai/code link. See [The Engineer and the a\*life cloud environment](#the-engineer-and-the-alife-cloud-environment). |

```sh
ALIFE_CLAUDE_MODEL=haiku ALIFE_LOT_DIR=~/Desktop/lot swift run ALifeServer
```

## Make it reachable over Tailscale

The front ends on your other devices reach the server through your tailnet. `tailscale serve` puts an HTTPS address in front of the local port, so the server itself can keep listening on `127.0.0.1` only.

1. Install Tailscale on this Mac and on each device that runs a front end, and sign them in to the same tailnet.
2. In the Tailscale admin console, on the DNS page, turn on **MagicDNS** and **HTTPS Certificates**. `tailscale serve` needs both.
3. Start the server (`swift run ALifeServer`).
4. Share the port with the tailnet:

   ```sh
   tailscale serve --bg 8080
   ```

   It prints the address, which looks like `https://my-mac.my-tailnet.ts.net`. `--bg` keeps it running after the terminal closes and across restarts.
5. From another device on the tailnet, check it: open `https://my-mac.my-tailnet.ts.net/health`.
6. In the app, open the settings (the gear at the top), enter that address and press **Connect**.

Useful afterwards:

```sh
tailscale serve status   # what is being shared
tailscale serve reset    # stop sharing
```

Notes:

- If the `tailscale` command isn't found, the Mac app ships it at `/Applications/Tailscale.app/Contents/MacOS/Tailscale`; the app's settings can also install the command for you.
- These commands are for current Tailscale versions. If yours differs, `tailscale serve --help` shows the syntax.
- **There is no login on this server.** Anyone who can reach the address can instruct the characters and answer their approvals, and the characters are Claude Code sessions on your Mac, using your login: whoever can reach the server can have them run commands there. With `tailscale serve` that means the devices in your tailnet, subject to its access rules. Don't use `tailscale funnel` for it: that publishes the address to the whole internet.

### Without HTTPS

If you can't turn on HTTPS certificates, the server can listen on the Mac's Tailscale address directly:

```sh
tailscale ip -4                                              # e.g. 100.101.102.103
swift run ALifeServer serve --hostname 100.101.102.103 --port 8080
```

Then use `http://100.101.102.103:8080` in the app. The app allows plain HTTP to IP addresses and local names for this purpose. Traffic inside a tailnet is encrypted by Tailscale either way.

### On the same Mac

The macOS app and the iOS simulator can use `http://localhost:8080` with no Tailscale involved. The settings have a button for it.

## The API

All bodies are JSON. The types are defined once, in the `ALifeAPI` module of [`../ALifeKit`](../ALifeKit), and used by both the server and the clients.

A session's `{id}` is its character's, such as `gardener` or `builder`, and never changes.

| Method | Path | Body | What it does |
|---|---|---|---|
| `GET` | `/health` | | `{"status":"ok"}` |
| `GET` | `/v1/sessions` | | Every session as it is right now, one per character: id, name, colour (`#RRGGBB`, the character's shirt), status, what it is doing, messages, pending approvals, helpers out, last sequence number. |
| `GET` | `/v1/sessions/{id}` | | One session as it is right now. |
| `GET` | `/v1/sessions/{id}/events` | | The session's event stream (server-sent events). See below. |
| `POST` | `/v1/sessions/{id}/messages` | `{"text": "…"}` | Says something to the character. Works while it is busy: it answers at its next step. `409` while it waits for an approval. |
| `POST` | `/v1/sessions/{id}/interrupt` | | Stops whatever the character is doing, and withdraws a pending approval. |
| `POST` | `/v1/sessions/{id}/approvals/{approval id}` | `{"allow": true}` | Answers a tool call that is waiting. `404` if there is no such approval. |
| `POST` | `/v1/sessions/{id}/reset` | | Ends the session's conversation and starts an empty one, for every front end. The other sessions carry on. |

An unknown session id gets a `404`. The `POST` routes answer `202 Accepted` as soon as the request is taken; what happens next arrives on the event stream. Errors look like `{"error": true, "reason": "…"}`.

### The event stream

`GET /v1/sessions/{id}/events` stays open and sends one event per thing that happens in that session:

```
id: 4
event: session.activity
data: {"seq":4,"event":{"type":"session.activity","activity":"read"}}
```

Every event has a sequence number that only goes up within its session. A client applies events in order to build its picture of the session, and remembers the last number it saw. When it reconnects it passes that number and the conversation's id:

```
GET /v1/sessions/builder/events?after=4&conversation=<conversation id>
```

The server then sends everything after 4 and carries on live, so nothing is missed or repeated. If the conversation id isn't the current one (the session was started over, or the server restarted), or none is given, the server sends the current conversation from its start. A comment line (`: ping`) goes out every 15 seconds to keep the connection open.

A front end follows every session at once: it reads `GET /v1/sessions` to learn who is on the lot, then opens one stream per session.

| Event | Carries | Meaning |
|---|---|---|
| `conversation.started` | `conversation_id` | A new conversation began in the session. Drop everything known about the old one. |
| `session.status` | `status`, `stop_reason` | The character is `running` or `idle`. When idle, `stop_reason` is `end_turn`, `requires_action` (an approval is waiting) or `interrupted`. |
| `session.activity` | `activity` | What the character is doing right now, such as the tool it is using. Absent when it isn't doing anything in particular. |
| `message` | `message` | A line of the conversation: `id`, `kind` (`user`, `agent`, `error`), `speaker`, `text`. |
| `approval.requested` | `approval` | A tool call needs a yes or no: `id`, `tool_name`, `input`. |
| `approval.resolved` | `approval_id` | It was answered, or is no longer needed. |
| `subagent.started` | `subagent` | The character sent a helper (a subagent) off to do part of its work: `id`, `task`. |
| `subagent.finished` | `subagent_id` | The helper reported back to the character, or was called back because the character was stopped or started over. |

Clients skip event types they don't know, so new ones can be added.

## The characters

The characters are listed in the [agents file](#the-agents-file). Each character is one Claude Code session, started the way the Agent SDK starts one: the `claude` CLI in print mode, with stream-json going in on its stdin and coming out of its stdout, in the lot's directory. Each character is told who it is (`--append-system-prompt`), and has one helper of its own, a subagent defined for its session with `--agents`:

| Character | Its helper | What the helper does | Asks you before |
|---|---|---|---|
| **Builder** | `construction-worker` | Builds buildings: writes `buildings/<name>.md` with where on the lot it stands, its rooms and a floor plan, or edits one that's there. | every change (Claude Code's `default` permission mode) |
| **Gardener** | `planter` | Plants plants: writes `garden/<bed>.md` with what grows where, how many and how far apart, or edits a bed that's there. | anything but changes to files on the lot (`acceptEdits`) |
| **Engineer** | `technician` | Takes a job on a\*life itself (the app and server in `q231950/a-life`) to a Claude Code session in the a\*life cloud environment, with `claude -p --cloud`. | every command (`default`) |

Each character has a colour of its own, which the front ends dress it in: the Gardener's shirt is red, the Builder's orange and the Engineer's purple. Its helpers' sheep wear the same colour.

Say "build me an office" to the Builder and it sends its construction worker off to build it: Claude Code calls its `Agent` tool with `subagent_type` `construction-worker`, which a front end sees as `subagent.started`, a sheep on the lot. The construction worker asks before it writes the file, as an approval on the Builder's session, labelled with who is asking (`construction-worker: buildings/office.md`). Once it reports back (`subagent.finished`), the Builder tells you what was built. The Gardener works the same way with its planter, but its changes to files on the lot go ahead without asking. Their helpers have only Read, Glob, Grep, Write and Edit, and the characters are told to leave the building and the planting to them. The Engineer's technician has only Bash, for the one command that hands a job to the cloud.

### The Engineer and the a\*life cloud environment

The Engineer doesn't work on the lot. It works on a\*life itself, the app and this server, in your **a\*life** cloud environment: the [cloud environment](https://code.claude.com/docs/en/cloud-environments) on claude.ai that has the `q231950/a-life` repository. Tell it "make the sheep jump when they take off" and it writes the job up so that it stands on its own, and sends its technician off. The technician runs

```sh
claude -p --cloud "${ALIFE_CLOUD_SESSION:?not set}" <<'ALIFE_JOB'
<the job>
ALIFE_JOB
```

which asks you first, like every command the Engineer's session runs (`technician: claude -p --cloud …`). Once allowed, the job is [queued in the cloud session](https://code.claude.com/docs/en/claude-code-on-the-web#send-follow-ups-from-the-cli), and Claude Code takes it up there with the repository checked out: changing the code, running the tests and pushing a branch, as the job says. The Engineer tells you what it sent, with a link to the session on claude.ai/code. Follow the work there or in the Claude app; what the cloud session does doesn't come back to the lot.

Claude Code can only start a new cloud session from an interactive terminal, so the Engineer sends every job to one session you start yourself:

1. Start a session in the a\*life environment: at [claude.ai/code](https://claude.ai/code) or in the Claude app, pick the **a\*life** environment and the `q231950/a-life` repository and say something like "You're the a\*life Engineer's workshop. Jobs will come in as messages; do each one on a branch of its own and push it." Or, in a terminal in your a\*life checkout, run `/remote-env` once to pick **a\*life**, then `claude --cloud "..."`.
2. Copy its ID (`session_...`) or its link.
3. Start the server with it:

   ```sh
   ALIFE_CLOUD_SESSION=session_... swift run ALifeServer
   ```

   The server says which session the Engineer sends its jobs to when it starts, or warns that it has none. Without one, the technician's command fails and the Engineer tells you so.

`claude -p --cloud` needs the CLI to be signed in with your claude.ai account (`claude auth login`), not an API key, and cloud sessions to be allowed for your account. The jobs count towards your usage like any other cloud session. The characters' shells find `claude` where the server found it.

How a session maps onto the events:

| Claude Code | Event |
|---|---|
| Something you say | `message` from `You`, sent to the CLI as a user message. Said mid-turn, Claude Code takes it up at its next step. |
| A text reply from the character | `message` from the character. Its helpers' own replies stay with the character. |
| A tool call | `session.activity`: the tool's name, such as `bash`, or `agent` while a helper is out |
| A call to the `Agent` tool, or `Task` in older versions | `subagent.started`, until the call returns or Claude Code reports the task done: `subagent.finished` |
| A permission request (`can_use_tool`) | `approval.requested`, and the session is idle with `requires_action` until you answer. Allowing or denying goes back to Claude Code as the answer. |
| The end of a turn (`result`) | `session.status` idle with `end_turn`. If it ended in an error, such as not being logged in, the error is a `message` of kind `error`. |

- **Talking to a character** while it works is fine: Claude Code takes what you say up at its next step. While it waits for an approval, messages to it are refused with `409` until the approval is answered.
- **Interrupting** stops the character's turn, withdraws a pending approval and calls its helpers back. The others carry on.
- **Starting over** stops the character's Claude Code session; the next thing you say starts a new one. What was built stays on the lot.
- **If Claude Code stops by itself**, the error is shown in the conversation and the next thing you say resumes the same session (`--resume`).
- Helpers run in the foreground (`CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1`): the character waits for its helper to report back before it carries on, so it stays at work in the house meanwhile. Helpers that Claude Code runs in the background anyway are followed until they report back.
- Each session is saved like any other Claude Code session. The server logs each one's id when it starts, so `claude --resume <id>` in the lot's directory picks the conversation up in a terminal. The server itself keeps nothing: after a restart, every character starts a new session.

### The agents file

The cast is a YAML file, read once when the server starts. The server ships with [`Sources/ALifeServer/agents.yaml`](Sources/ALifeServer/agents.yaml): the Gardener, the Builder and the Engineer above. Edit it and restart the server to change what a character is told, its colour, its helper or its permission mode, or to add or take away a character. Or keep a file of your own and point `ALIFE_AGENTS_FILE` at it:

```sh
ALIFE_AGENTS_FILE=~/my-agents.yaml swift run ALifeServer
```

The front ends pick the cast up when they next connect. Each character is one entry under `agents`, in the order the front ends list them:

```yaml
agents:
  - id: painter             # the session's id, used in its URLs
    name: Painter           # what the front ends call it
    color: "#3366CC"        # optional: its shirt, which its helper's sheep wear too
    permission_mode: acceptEdits  # optional: what Claude Code asks you before doing; default unless set
    changes_things: true    # optional: the dummy's script; false unless set
    role: |                 # who it is, added to Claude Code's system prompt
      You are the Painter, a character in a*life, a little life sim. ...
    helper:                 # the subagent it sends off to do its work
      name: brush
      tools: [Read, Glob, Grep, Write, Edit]
      description: |        # when to send it; Claude Code reads this to decide
        The Painter's brush. Paints the walls of buildings on the lot.
      prompt: |             # the helper's own system prompt
        You are the Painter's brush in a*life, a little life sim. ...
```

| Field | | What it is |
|---|---|---|
| `id` | required | The session's id, which its URLs use, such as `/v1/sessions/painter`: lowercase letters, digits and hyphens. No two agents can share one. |
| `name` | required | What the front ends call the character. |
| `color` | optional | Its shirt on the lot, which its helper's sheep wear too, as `"#RRGGBB"`. Quote it: in YAML, `#` starts a comment. Without one, the front ends choose. |
| `permission_mode` | optional | [Claude Code's permission mode](https://code.claude.com/docs/en/permission-modes) for the session, which decides what it asks you before doing: `default` (or `manual`) asks before every change, `acceptEdits` lets changes to files go ahead, and `plan`, `auto`, `dontAsk` and `bypassPermissions` are also taken. `default` unless set. |
| `changes_things` | optional | Only for the [dummy characters](#the-dummy-characters): `true` plays the script that asks for approval, like the Builder's. `false` unless set. |
| `role` | required | Who the character is, added to Claude Code's own system prompt (`--append-system-prompt`). |
| `helper.name` | required | The subagent's name, which the character uses to send it off: lowercase letters, digits and hyphens. |
| `helper.tools` | required | The Claude Code tools the helper may use, such as `[Read, Write]`. At least one. |
| `helper.description` | required | When to send the helper. Claude Code reads it to decide. |
| `helper.prompt` | required | The helper's own system prompt. It runs on its character's model. |

Text is passed on as written, without the line break a `|` block ends with. Write each paragraph on one line, as the shipped file does: a line break inside a `|` block reaches Claude Code as a line break. The model and the lot are the same for every character; set them with `ALIFE_CLAUDE_MODEL` and `ALIFE_LOT_DIR`.

The server checks the whole file when it starts and won't start if anything is wrong, saying what and where:

```
agents.yaml: agents[2].color should be a colour like "#8050C8", not "purple".
agents.yaml: agents[0].permision_mode isn't a field of an agent. The fields are id, name, color, permission_mode, changes_things, role and helper.
agents.yaml: agents[1].id "builder" is agents[0]'s id too. Each agent needs an id of its own.
```

A field it doesn't know is refused rather than ignored, so a typo doesn't quietly leave a character with a default. If a character's instructions use `ALIFE_CLOUD_SESSION`, as the Engineer's technician's do, the server says at startup where those jobs go, or warns that it isn't set.

## The dummy characters

With `ALIFE_BACKEND=dummy`, each character is a `DummyCharacter` instead, which plays a short script for whatever it is told. No model is called and nothing real happens, so the front ends can be worked on without spending tokens.

- The **Gardener** only looks. It reads, then sends two helpers off at once, one to search the flower beds and one to check the hedges, and reports back once both have reported back to it. It never asks for permission.
- The **Builder** changes things. It reads, sends a helper off to measure the north corner and waits for it, then asks for approval of a shell command. The session goes idle with `requires_action` and waits for as long as it takes. Once answered, it runs the command (or doesn't) and reports back. The **Engineer** plays the same script.

Each helper is out for a few steps (the Gardener's for four and six, the Builder's for four); while they are out, the character's activity is `agent`.

Both can be talked to while they work: something said mid-task is answered at the next step ("Still on … Right now I'm …") and the work carries on. Something said after the last step becomes the next instruction. While the Builder waits for an approval, messages to it are refused with `409` until the approval is answered.

Each step takes 1.5 seconds.

```sh
ALIFE_BACKEND=dummy swift run ALifeServer
```

An interrupt stops one character and leaves the others be, and calls back any helpers it has out.

## How it fits together

The routes know nothing about what plays a character. For each session they talk to two things:

- `SessionHub` keeps the session's event log and its open streams. Whatever drives the session calls `hub.emit(_:)` for each thing that happens.
- `SessionBackend` is the protocol the routes call: `handleMessage`, `interrupt`, `decide`, `reset`, and `shutdown` when the server stops.

`ClaudeCharacter` and `DummyCharacter` both conform to `SessionBackend` and emit the same events. `configure.swift` is the one place that chooses which plays the characters.

## Layout

| File | What it does |
|---|---|
| `entrypoint.swift` | Starts Vapor. |
| `configure.swift` | Reads the settings, sets up a hub and a backend per character, and the routes. |
| `agents.yaml` | The cast the server ships with: who each character is, its colour, its permission mode and its helper. See [The agents file](#the-agents-file). |
| `Cast.swift` | Reads and checks the agents file into `Character`s, each with its `Helper`. |
| `routes.swift` | The HTTP API, including the event streams. |
| `SessionHub.swift` | One session's event log, snapshot, and fan-out to its open streams. |
| `SessionBackend.swift` | The protocol a session's backend implements, and `HostedSession`, which pairs it with its hub. |
| `ClaudeCharacter.swift` | A character played by a Claude Code session: turns its stream-json into the session's events, and approvals, interrupts and starting over into what the CLI expects. |
| `ClaudeCode.swift` | Finds and starts the `claude` CLI, and reads and writes its stream-json, one message per line. |
| `JSONValue.swift` | Plain JSON, for reading Claude Code's messages. |
| `DummyCharacter.swift` | The scripted stand-in. |

## Tests

```sh
swift test
```

The tests start the server on a free local port with the dummy characters and drive it with the real client package: each character in a session of its own, the Builder's approval, the helpers each character sends off, a second front end joining late, starting one session over, interrupting one character while the other carries on (and calling its helpers back), a question answered mid-task, reconnecting mid-session, and bad requests.

`ClaudeCharacterTests` play Claude Code's side of the stream-json with lines like the ones it really writes: "build me an office" sending the Builder's construction worker off and its approval going back to Claude Code, the Gardener's planter, denying, interrupting with a helper out, Claude Code stopping and being resumed, starting over, helpers in the background, and errors. `ClaudeCodeProcessTests` check the pipes to a real child process.

`CastTests` read the agents file: the shipped one and what is in it, every field, what an agent can leave out, the mistakes the server refuses and what it says about each, `ALIFE_AGENTS_FILE`, and a server with a cast of its own.

One test runs the Builder on the Claude Code installed on your Mac, tells it to build an office, allows whatever it asks, and checks that its construction worker was sent off and a building is on a temporary lot. It costs a little, so it only runs when asked:

```sh
ALIFE_LIVE_CLAUDE=1 ALIFE_CLAUDE_MODEL=haiku swift test --filter LiveClaudeCodeTests
```
