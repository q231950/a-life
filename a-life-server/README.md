# a-life-server

The backend the a*life front ends talk to. It is a [Vapor](https://vapor.codes) server meant to run on your own Mac and be reached over [Tailscale](https://tailscale.com).

It holds one session per character on the lot. **Each character is a Claude Code session of its own**, run by the Claude Code installed on your Mac: its conversation, what it is doing, the helpers (subagents) it has sent off, and any tool call it is waiting on you to allow. Front ends follow every session over a stream of events, and talk to each character directly. No character coordinates the others; that's up to you.

The characters work on a *lot*: a directory they share, `~/a-life-lot` unless you say otherwise. The Builder's buildings and the Conservationist's beds are Markdown files in it, and the server sends the front ends what stands where, so a restaurant the Builder builds appears on the lot in the app. See [The lot](#the-lot). The Engineer works on a\*life itself instead, in your a\*life checkout. See [The characters](#the-characters).

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

The Conservationist's session is at `/v1/sessions/conservationist`, and carries on independently. Ask it to plant something or put out animals and it sends its keeper off.

See what stands on the lot, and follow it as it changes:

```sh
curl http://127.0.0.1:8080/v1/lot
curl -N http://127.0.0.1:8080/v1/lot/events
```

### Settings

All optional, as environment variables:

| Variable | What it does |
|---|---|
| `ALIFE_LOT_DIR` | The directory the characters work in, and whose buildings and beds the front ends show. `~/a-life-lot` unless set; it is made if it isn't there. The dummy characters don't change it, but the front ends still show what's on it. |
| `ALIFE_REPO_DIR` | The a\*life checkout the Engineer works in. The checkout the server was built from unless set. See [The Engineer and the a\*life checkout](#the-engineer-and-the-alife-checkout). |
| `ALIFE_CLAUDE_PATH` | The `claude` command, if the server doesn't find it by itself. |
| `ALIFE_CLAUDE_MODEL` | The model for every character, such as `sonnet` or `haiku`. Claude Code's own default unless set. The helpers use their character's model. |
| `ALIFE_BACKEND` | `claude` (the default), or `dummy` for the scripted dummies. |
| `ALIFE_AGENTS_FILE` | The agents file, which lists the characters, and which the Team Lead adds agents to. Unless set, [`Sources/ALifeServer/agents.yaml`](Sources/ALifeServer/agents.yaml) in the checkout the server was built from, or the copy the server ships with if that checkout is gone. See [The agents file](#the-agents-file). |
| `ALIFE_VOICE_DIR` | The voice model the server offers the front ends, for the characters to speak with. `~/a-life-voice` unless set. See [Voices](#voices). |
| `ALIFE_PROJECTS_DIR` | Where the server clones the projects that are git repositories, one directory per character, named after its id (with a clone of each repository in it, for a project of several). `~/a-life-projects` unless set. See [A character for another project](#a-character-for-another-project). |

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

A session's `{id}` is its character's, such as `builder` or `engineer`, and never changes.

| Method | Path | Body | What it does |
|---|---|---|---|
| `GET` | `/health` | | `{"status":"ok"}` |
| `GET` | `/v1/sessions` | | Every session as it is right now, one per character: id, name, colour (`#RRGGBB`, the character's shirt), status, what it is doing, messages, pending approvals, the whole conversation (`conversation`, see below), helpers out, whether auto approve is on (`auto_approve`), last sequence number. |
| `GET` | `/v1/sessions/{id}` | | One session as it is right now. |
| `GET` | `/v1/sessions/{id}/events` | | The session's event stream (server-sent events). See below. |
| `POST` | `/v1/sessions/{id}/messages` | `{"text": "…"}` | Says something to the character. Works while it is busy: it answers at its next step. `409` while it waits for an approval. |
| `POST` | `/v1/sessions/{id}/interrupt` | | Stops whatever the character is doing, and withdraws a pending approval. |
| `POST` | `/v1/sessions/{id}/approvals/{approval id}` | `{"allow": true}` | Answers a tool call that is waiting. `404` if there is no such approval. |
| `PUT` | `/v1/sessions/{id}/auto-approve` | `{"enabled": true}` | Turns auto approve on or off for this character only. While it's on, each tool call that asks is allowed straight away, and still shows in the conversation, settled as `auto_approved`. Turning it on allows whatever is waiting, too. It stays as it is when the session is started over, and is off when the server starts. |
| `POST` | `/v1/sessions/{id}/reset` | | Ends the session's conversation and starts an empty one, for every front end. The other sessions carry on. |
| `GET` | `/v1/lot` | | Everything built and planted on the lot. See [below](#the-lot-and-its-stream). |
| `GET` | `/v1/lot/events` | | The lot's stream (server-sent events): the lot as it is now, then again each time it changes. |
| `GET` | `/v1/voice/{path}` | | The voice model's files, as they are in `ALIFE_VOICE_DIR`: `bundle.json`, then each file it lists. `404` for anything else, and for everything if there's no model. See [Voices](#voices). |

An unknown session id gets a `404`. The `POST` and `PUT` routes answer `202 Accepted` as soon as the request is taken; what happens next arrives on the event stream. Errors look like `{"error": true, "reason": "…"}`.

### The event stream

`GET /v1/sessions/{id}/events` stays open and sends one event per thing that happens in that session:

```
id: 4
event: session.activity
data: {"seq":4,"event":{"type":"session.activity","activity":"read"},"time":1795000000.25}
```

Every event has a sequence number that only goes up within its session. Its `time` is when it happened, by the server's clock, in seconds since 1970, so a front end catching up on what it missed can say when; servers from before it leave it out. A client applies events in order to build its picture of the session, and remembers the last number it saw. When it reconnects it passes that number and the conversation's id:

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
| `message` | `message` | A line of the conversation: `id`, `kind` (`user`, `agent`, `error`), `speaker`, `text`. Everything the character says is one, along the way as well as at the end. |
| `tool.used` | `tool_use` | The character used a tool, so you can follow along: `id`, `tool_name`, `input` (a few words of what it does, such as a command or a file's path). Its helpers' tools aren't sent. |
| `approval.requested` | `approval` | A tool call needs a yes or no: `id`, `tool_name`, `input`, and `tool_use_id`, the call it asks about. |
| `approval.resolved` | `approval_id`, `outcome` | It was settled. `outcome` is `allowed` or `denied` when you answered, `auto_approved` when auto approve allowed it, and `withdrawn` when it no longer needed an answer, such as after Stop or Start over. Older servers leave `outcome` out. |
| `subagent.started` | `subagent` | The character sent a helper (a subagent) off to do part of its work: `id`, `task`. |
| `subagent.finished` | `subagent_id` | The helper reported back to the character, or was called back because the character was stopped or started over. |
| `session.auto_approve` | `auto_approve` | Auto approve was turned on (`true`) or off for the session. A new conversation starts with it off, so a server that keeps it on sends this again straight after `conversation.started`. |

Clients skip event types they don't know, so new ones can be added.

A session's `conversation` is the whole conversation so far, oldest first, built from these events: each entry has a `type` of `message` (with `message`), `tool_use` (with `tool_use`) or `approval` (with `approval`, and `outcome` once it was settled). An approval takes the place of the `tool_use` with its `tool_use_id`, so a call that asks first is in the conversation once. Answered approvals stay in it; `approvals` lists only the ones still waiting. Clients skip entries they don't know, and make a conversation from `messages` and `approvals` if a server from before it doesn't send one.

### The lot and its stream

`GET /v1/lot` answers with everything built and planted:

```json
{
  "revision": 3,
  "items": [
    {"id": "buildings/restaurant.md", "category": "building", "kind": "restaurant", "name": "Luigi's",
     "x": 38, "y": 22, "width": 5, "depth": 4},
    {"id": "garden/roses.md", "category": "plant", "kind": "rose", "name": "Rose bed",
     "x": 20, "y": 30, "width": 3, "depth": 1, "color": "#D7263D"}
  ],
  "problems": ["buildings/office.md: it isn't on the lot: it doesn't start with the lines that say its kind and where it stands. See lot.md."]
}
```

Each item is a file in the lot: its `category` is `building` or `plant`, its `kind` is in lowercase, `x` and `y` are its top left tile and `width` and `depth` how many tiles it covers, and `color` is `#RRGGBB` if it was given one. `problems` says what couldn't be put on the lot, and why. `revision` goes up by one each time anything changes; it is 1 once the server has looked at the lot, and starts again when the server restarts.

`GET /v1/lot/events` sends the whole lot as one `lot` event when it connects, and again each time it changes:

```
id: 3
event: lot
data: {"revision":3,"items":[…],"problems":[]}
```

There is nothing to catch up on: a client that reconnects is sent the lot as it is. Older front ends don't ask for the lot, and newer ones carry on without it if a server doesn't have one.

## Voices

The app says what the characters say out loud, while you stand near them, with [Phonon](https://github.com/gradium-ai/xn-ptts) text to speech on the device. It needs a voice model, which it downloads from the server the first time: Phonon 31m, English, under the Apache 2.0 licence, with several dozen voices, a few of which go to the characters. Fetch it onto this Mac once:

```sh
./fetch-voice.sh
```

That downloads the model from the Phonon release the app is built against, checks it, and unpacks it into `~/a-life-voice` (or `ALIFE_VOICE_DIR`). Restart the server: it says whether it has found the model, and offers it at `/v1/voice/`. The app downloads it from there (about 160 MB, checked file by file), keeps it in its Application Support, and doesn't download it again unless the model there changes. Without a model the server answers `404`, and the characters keep quiet. Any other Phonon Core ML model bundle will do in its place, such as one you exported with voices of your own.

## The characters

The characters are listed in the [agents file](#the-agents-file). Each character is one Claude Code session, started the way the Agent SDK starts one: the `claude` CLI in print mode, with stream-json going in on its stdin and coming out of its stdout, in the lot's directory (the Engineer's in your a\*life checkout). Each character is told who it is (`--append-system-prompt`), and has one helper of its own, a subagent defined for its session with `--agents`:

| Character | Its helper | What the helper does | Asks you before |
|---|---|---|---|
| **Builder** | `construction-worker` | Builds buildings: reads `lot.md` for room, then writes `buildings/<name>.md` with its kind and where it stands at the top, so it appears on the lot, and its rooms and a floor plan; or edits one that's there. | every change (Claude Code's `default` permission mode) |
| **Engineer** | `a-life-expert` | Changes a\*life itself, the app, `ALifeKit` and this server, in your a\*life checkout: knows its way around all of it, makes the change, keeps the tests and READMEs in step, and runs the tests. | every change and command (`default`) |
| **Flamingo Engineer** | `flamingo-expert` | Changes Flamingo Chess, in its three repositories cloned side by side: `flamingo` (the iOS app), `flamingo-chess-light` (the Light Phone app) and `neoneon` (the server). Keeps a change that spans them in step, runs their tests. See [A character for another project](#a-character-for-another-project). | every change and command (`default`) |
| **Team Lead** | `recruiter` | Adds a new agent to the agents file: reads it, writes the new agent as the others are written, and adds it with the server's `add-agent` command, which checks it and leaves everyone else as they are. See [The Team Lead and the agents file](#the-team-lead-and-the-agents-file). | every command (`default`) |

Each character has a colour of its own, which the front ends dress it in: the Builder's shirt is orange, the Engineer's purple, the Flamingo Engineer's pink, the Team Lead's teal and the Conservationist's green. Its helpers' sheep wear the same colour. Each speaks in a voice of its own too, chosen by its place in the agents file.

Say "build me an office" to the Builder and it sends its construction worker off to build it: Claude Code calls its `Agent` tool with `subagent_type` `construction-worker`, which a front end sees as `subagent.started`, a sheep on the lot. The construction worker asks before it writes the file, as an approval on the Builder's session, labelled with who is asking (`construction-worker: buildings/office.md`). Once it reports back (`subagent.finished`), the Builder tells you what was built. The Conservationist works the same way with its keeper, but its changes to files on the lot go ahead without asking. Their helpers have only Read, Glob, Grep, Write and Edit, and the characters are told to leave the building and the planting to them.

How a session maps onto the events:

| Claude Code | Event |
|---|---|
| Something you say | `message` from `You`, sent to the CLI as a user message. Said mid-turn, Claude Code takes it up at its next step. |
| A text reply from the character | `message` from the character, each one in a turn, not only the last. Its helpers' own replies stay with the character. |
| A tool call | `tool.used`, and `session.activity`: the tool's name, such as `bash`, or `agent` while a helper is out |
| A call to the `Agent` tool, or `Task` in older versions | `subagent.started`, until the call returns or Claude Code reports the task done: `subagent.finished` |
| A permission request (`can_use_tool`) | `approval.requested`, and the session is idle with `requires_action` until you answer. Allowing or denying goes back to Claude Code as the answer, and is `approval.resolved` with `allowed` or `denied`; with auto approve on, Claude Code is told yes at once and it is `auto_approved`, without waiting; one Claude Code no longer needs is `withdrawn`. |
| The end of a turn (`result`) | `session.status` idle with `end_turn`. If it ended in an error, such as not being logged in, the error is a `message` of kind `error`. |

- **Talking to a character** while it works is fine: Claude Code takes what you say up at its next step. While it waits for an approval, messages to it are refused with `409` until the approval is answered.
- **Interrupting** stops the character's turn, withdraws a pending approval and calls its helpers back. The others carry on.
- **Starting over** stops the character's Claude Code session; the next thing you say starts a new one. What was built stays on the lot.
- **If Claude Code stops by itself**, the error is shown in the conversation and the next thing you say resumes the same session (`--resume`).
- Helpers run in the foreground (`CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1`): the character waits for its helper to report back before it carries on, so it stays at work in the house meanwhile. Helpers that Claude Code runs in the background anyway are followed until they report back.
- Each session is saved like any other Claude Code session. The server logs each one's id when it starts, so `claude --resume <id>` in the directory the character works in (the lot, or the Engineer's a\*life checkout) picks the conversation up in a terminal. The server itself keeps nothing: after a restart, every character starts a new session.

### The Engineer and the a\*life checkout

The Engineer doesn't work on the lot. It works on a\*life itself, the app, `ALifeKit` and this server, as an ordinary Claude Code session in your a\*life checkout (`works_in: a-life` in the [agents file](#the-agents-file)). That is the checkout the server was built from, the one you ran `swift run` in, unless you point `ALIFE_REPO_DIR` at another, such as a second clone or a worktree that you'd rather it changed:

```sh
ALIFE_REPO_DIR=~/code/a-life-workshop swift run ALifeServer
```

The server says where the Engineer works when it starts, or warns that it can't find a checkout; the Engineer can't start until it has one.

Tell it "make the sheep jump when they take off" and it works out what's wanted and sends its a\*life expert off: the `a-life-expert` subagent, which knows a\*life inside out, from what each file of the app, the package and the server does to how the code and its READMEs are written and which tests cover what. The Engineer sends it for anything that changes a\*life, and answers questions about how a\*life works itself, by reading the code. The a\*life expert has Read, Glob, Grep, Write, Edit and Bash. It looks at `git status` first, so it doesn't undo changes of your own, makes the change with its tests, runs `swift test` for the packages it touched, and reports back what it changed and how the tests went. The Engineer's session runs in the `default` permission mode, so its changes and commands ask you first, labelled with who is asking (`a-life-expert: swift test --package-path a-life-server`).

It leaves its changes in the working tree for you to look over, and doesn't commit, push or switch branches unless you ask it to. A change to the server takes effect once you restart it, and a change to the app once you build it again.

### A character for another project

A character can work on a project of your own instead of the lot or a\*life, so that you can hand it the work on another app: give it a `project` in the [agents file](#the-agents-file) instead of `works_in`. Its session is an ordinary Claude Code session in the project's directory, as the Engineer's is in the a\*life checkout, with its own helper, and it walks the lot like everyone else. The project is either a directory that is already on your Mac:

```yaml
  - id: app-engineer
    name: App Engineer
    project:
      path: ~/Development/my-app
    ...
```

or a git repository, at its ssh address (`git@...`, not `https://...`), which the server clones for it:

```yaml
    project:
      repo: git@github.com:you/my-app.git   # its ssh address, not https://
      branch: main                          # optional: the repository's default unless set
```

or several git repositories, such as an app and its server, which the server clones side by side so that the character can work on them all at once:

```yaml
    project:
      repos:
        - repo: git@github.com:you/my-app.git
        - repo: git@github.com:you/my-server.git
          branch: main                      # optional, for each repo
```

A `path` is a full path, or one from `~`, and has to be there when the server starts; the server won't start if it isn't. A `repo` is cloned the first time the server starts with it, into `~/a-life-projects/<id>` (or under `ALIFE_PROJECTS_DIR`), at its `branch` if there is one. On later starts the server uses that clone as it is: it doesn't fetch, pull or switch branches, so whatever the character or you did in it is kept. `repos` are cloned the same way, each into `~/a-life-projects/<id>/<name>`, where its name is the last part of its address without `.git`, as `git clone` would name it (`my-app` and `my-server` above), and the character's session works in `~/a-life-projects/<id>`, with all of them; no two of a character's repos can have the same name. To start afresh, delete the clone and restart the server. If something that isn't a git checkout is in its place, the server leaves it alone. The clone runs `git` with your own ssh key, without asking for a password, so give each repository's ssh address, such as `git@github.com:you/my-app.git`, and have a key that works without you (in `ssh-agent` or without a passphrase). An `https://` address would ask for a password nobody is there to type in, so the clone would fail and the character would have nothing to work on; the server won't start with one, and says which ssh address to use instead.

When it starts, the server says which directory each character works in, and whether it cloned a project just now or found it from before. If a clone fails, even one of a character's several, it says why and carries on: the others work as usual, and that character says why when you talk to it, until the clone works on a later start.

The shipped [`agents.yaml`](Sources/ALifeServer/agents.yaml) has such a character, the Flamingo Engineer, who looks after Flamingo Chess: its iOS app, `flamingo`, its Light Phone app, `flamingo-chess-light`, and its server, `neoneon`, cloned into `~/a-life-projects/flamingo-engineer`. It sends its helper, the `flamingo-expert`, for every change, and the expert keeps a change that spans the repositories, such as one to the server's API and the apps that use it, in step. The file ends with another, the App Engineer, commented out: take the `#`s off, point it at your project, and restart the server.

### The Team Lead and the agents file

The Team Lead adds new agents to the [agents file](#the-agents-file), so that you can have someone new on the lot without writing their entry yourself. Tell it "I'd like a Painter who paints the houses" and it works out with you who they are: their name, what they do, where they work (the lot, a\*life, or a project of yours, a directory or a git repository's ssh address), their colour and how careful they should be. Then it sends its recruiter off, the `recruiter` subagent, which reads the agents file, writes the new agent the way the others are written, with a role and a helper of its own, and adds it with the server's own command:

```sh
"$ALIFE_SERVER_COMMAND" add-agent <<'AGENT'
id: painter
name: Painter
color: "#3366CC"
...
AGENT
```

The server gives every Claude Code session it starts `ALIFE_AGENTS_FILE`, the agents file it read the cast from, and `ALIFE_SERVER_COMMAND`, its own command. `add-agent` takes a new agent's fields on its standard input (or from the file named after it), as an agent in the file has them, with or without the `- ` in front. It checks the new agent as the server checks the whole file when it starts, and also that no other agent has its id or its name, then adds it after the last agent, before any comments at the end of the file, such as the App Engineer example. The other agents and the file's comments stay as they are, word for word: if the new agent can't be added without changing them, or anything about it is wrong, the file isn't touched, and the command says what's wrong and where, so the recruiter can fix it and try again. You can run it yourself, too, as `swift run ALifeServer add-agent < painter.yaml`; nothing else of the server starts.

The Team Lead works on the lot but leaves it alone, and its recruiter has Read, Glob, Grep and Bash but neither Write nor Edit: it never writes the agents file itself, and can't change or take away an agent that's there. Its session runs in the `default` permission mode, so `add-agent` asks you first (`recruiter: "$ALIFE_SERVER_COMMAND" add-agent ...`), and you see the new agent before it's added. Restart the server and the new agent joins the lot; the front ends pick it up when they reconnect.

Unless `ALIFE_AGENTS_FILE` is set, the agents file is the one in the a\*life checkout the server was built from, `Sources/ALifeServer/agents.yaml`, so a new agent is a change in that checkout, there for you to look over and commit, and joins the lot without building the server again. If that checkout is gone, the server reads, and the Team Lead adds to, the copy it was built with.

### The agents file

The cast is a YAML file, read once when the server starts. The server ships with [`Sources/ALifeServer/agents.yaml`](Sources/ALifeServer/agents.yaml): the Builder, the Engineer, the Flamingo Engineer, the Team Lead and the Conservationist above, among others. Edit it and restart the server to change what a character is told, its colour, its helper, its permission mode or where it works (the lot, a\*life or a project of your own), or to add or take away a character; or have the [Team Lead](#the-team-lead-and-the-agents-file) add one. Or keep a file of your own and point `ALIFE_AGENTS_FILE` at it:

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
    works_in: lot           # optional: lot, or a-life for your a*life checkout; lot unless set
    # project: {path: ~/Development/my-app}  # optional, instead of works_in: a project of your own
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
| `name` | required | What the front ends call the character. No two agents can share one, whatever their capitals. |
| `color` | optional | Its shirt on the lot, which its helper's sheep wear too, as `"#RRGGBB"`. Quote it: in YAML, `#` starts a comment. Without one, the front ends choose. |
| `permission_mode` | optional | [Claude Code's permission mode](https://code.claude.com/docs/en/permission-modes) for the session, which decides what it asks you before doing: `default` (or `manual`) asks before every change, `acceptEdits` lets changes to files go ahead, and `plan`, `auto`, `dontAsk` and `bypassPermissions` are also taken. `default` unless set. |
| `works_in` | optional | Where the character's session works: `lot`, the directory the characters share, or `a-life`, your a\*life checkout, as the [Engineer](#the-engineer-and-the-alife-checkout) does. `lot` unless set, or unless it has a `project`. |
| `project` | optional | Instead of `works_in`: a project of your own for the character to work on. See [A character for another project](#a-character-for-another-project). |
| `project.path` | | A directory on your Mac, as a full path or from `~`. It has to be there. |
| `project.repo` | | Instead of `path`: a git repository's ssh address, such as `git@github.com:you/app.git` (`ssh://`, `git://` and `file://` addresses do too, but not `https://` or `http://`, which can't be cloned without a password), which the server clones into `ALIFE_PROJECTS_DIR`. |
| `project.branch` | optional | Only with `repo`: the branch to clone. The repository's default unless set. |
| `project.repos` | | Instead of `path` or `repo`: a list of git repositories, each a `repo` at its ssh address with a `branch` if need be, which the server clones side by side into `ALIFE_PROJECTS_DIR/<id>`, for the character to work on them all. At least one, and no two with the same name. |
| `changes_things` | optional | Only for the [dummy characters](#the-dummy-characters): `true` plays the script that asks for approval, like the Builder's. `false` unless set. |
| `role` | required | Who the character is, added to Claude Code's own system prompt (`--append-system-prompt`). |
| `helper.name` | required | The subagent's name, which the character uses to send it off: lowercase letters, digits and hyphens. |
| `helper.tools` | required | The Claude Code tools the helper may use, such as `[Read, Write]`. At least one. |
| `helper.description` | required | When to send the helper. Claude Code reads it to decide. |
| `helper.prompt` | required | The helper's own system prompt. It runs on its character's model. |

Text is passed on as written, without the line break a `|` block ends with. Write each paragraph on one line, as the shipped file does: a line break inside a `|` block reaches Claude Code as a line break. The model, the lot and the a\*life checkout are the same for every character; set them with `ALIFE_CLAUDE_MODEL`, `ALIFE_LOT_DIR` and `ALIFE_REPO_DIR`.

The server checks the whole file when it starts and won't start if anything is wrong, saying what and where:

```
agents.yaml: agents[2].color should be a colour like "#8050C8", not "purple".
agents.yaml: agents[0].permision_mode isn't a field of an agent. The fields are id, name, color, permission_mode, works_in, project, changes_things, role and helper.
agents.yaml: agents[3].project.path /Users/you/Development/my-app isn't a directory on this machine. A project's path has to be there already; for one that isn't, give its repo instead.
agents.yaml: agents[3].project.repos[0].repo "https://github.com/you/my-app.git" is an https address, which the server can't clone: it clones without asking for a password. Use the repository's ssh address instead, such as git@github.com:you/my-app.git.
agents.yaml: agents[1].id "builder" is agents[0]'s id too. Each agent needs an id of its own.
agents.yaml: agents[5].name "Painter" is agents[4]'s name too. Each agent needs a name of its own.
```

A field it doesn't know is refused rather than ignored, so a typo doesn't quietly leave a character with a default.

## The lot

The lot is 64 by 64 tiles. `x` is the column, from 0 on the left to 63 on the right, and `y` the row, from 0 at the top to 63 at the bottom; in the app, the bottom is the side the house's door faces. The house the characters work in stands in the middle, with the lawn they wait on in front of it, and nothing can be built or planted on it or the path round it: x 28 to 35, y 25 to 36. The front ends and the server share this layout, as `LotPlan` in `ALifeAPI`.

A building is a Markdown file in the lot's `buildings/`, and a bed of plants one in `garden/`. It stands on the lot once it starts with a few lines of YAML that say what it is and where:

```markdown
---
kind: restaurant
x: 38
y: 22
width: 5
depth: 4
---
# Luigi's

A little trattoria by the house. …
```

| Field | | What it is |
|---|---|---|
| `kind` | required | What it is, such as `restaurant`, `house`, `rose` or `oak`. The front ends draw the kinds they know, and anything else as a plain building or plant, so any kind will do. |
| `x`, `y` | required | Its top left tile. |
| `width`, `depth` | optional | How many tiles it covers along `x` and along `y`, each 1 to 16. A building is 3 by 3 and a plant one tile unless set. A bed has one plant on each tile. |
| `color` | optional | For plants: a colour by name (`red`, `pink`, `white`, `yellow`, `orange`, `purple`, `blue` and a few more, and coats such as `chestnut`, `bay`, `grey` and `palomino` for foals, `cinnamon` for bears, `silver` for unicorns, and hides such as `olive`, `sand`, `rust` and `slate` for dinosaurs) or as `"#RRGGBB"`. A colour it doesn't know is left to the front end. |
| `name` | optional | What the front ends call it. The file's first `# ` heading unless set, or else its file name. |

The kinds the app draws:

| | Kinds |
|---|---|
| Buildings | house, restaurant, cafe, shop, office, tower, school, library, barn, shed, church, hospital, and words like them (a bistro is a restaurant, a bookshop a shop). A barn (or a stable or a farm) comes with a pen of chickens and goats, a lunging ring and horses that gallop round the lot, so it wants room: about 13 by 5, with the row in front of it free. |
| Plants | flowers (rose, tulip, daisy, sunflower, lavender, poppy, or any other flower), trees (oak, maple, birch, apple, cherry, palm, pine), bush, hedge, grass, and vegetables (carrot, lettuce, cabbage, tomato, pumpkin, potato, or any other vegetable) |
| Animals | foal (and pony, colt, filly or baby horse), bear, polar-bear, bird, unicorn, pegasus, and the dinosaurs stegosaurus, diplodocus, pterosaur (and pterosaurus or pterodactyl), triceratops and tyrannosaurus (and T. rex) (`LotItem.Animal`): one on each tile of the bed, at most 6 to a bed (`LotPlan.mostAnimals`), in its colour or a coat of its own. They graze, trot, frisk and lie down within a few tiles of their bed; birds, pegasuses and pterosaurs fly up and round over it too, hover and land, and a tyrannosaurus roars. Anyone can walk across their patch, but it still takes up its tiles. Only in `garden/`. |

The server looks at `buildings/` and `garden/` every second. A file that runs off the lot, is on the house, is bigger than 16 tiles a side, is a bed of more than 6 animals, or is missing its kind, `x` or `y`, stays off the lot. If two things would share a tile, the one that was there first (whose file changed longest ago) stays, and the other stays off. An empty file stands for nothing, so emptying one pulls the building down or digs the bed up. Files without the lines at the top, such as ones written before the lot could be built on, stay off it too, until a character adds them.

After each look, the server writes `lot.md` in the lot: what stands where, what couldn't be put on the lot and why, which animals the app draws and what colours they come in, and a map of every tile, with `.` for free ones. The construction worker and the keeper read it to find room before they build or plant, and again afterwards to check that what they made is on the lot. Don't edit it: the server writes it again.

## The dummy characters

With `ALIFE_BACKEND=dummy`, each character is a `DummyCharacter` instead, which plays a short script for whatever it is told. No model is called and nothing real happens, so the front ends can be worked on without spending tokens.

- A character that doesn't change things (`changes_things: false`) only looks. It reads, then sends two helpers off at once, one to search the flower beds and one to check the hedges, and reports back once both have reported back to it. It never asks for permission.
- The **Builder** changes things. It reads, sends a helper off to measure the north corner and waits for it, then asks for approval of a shell command. The session goes idle with `requires_action` and waits for as long as it takes. Once answered, it runs the command (or doesn't) and reports back. Every character that changes things, such as the **Engineer**, the **Team Lead** and the **Conservationist**, plays the same script.

Each helper is out for a few steps (the looker's for four and six, the Builder's for four); while they are out, the character's activity is `agent`.

Both can be talked to while they work: something said mid-task is answered at the next step ("Still on … Right now I'm …") and the work carries on. Something said after the last step becomes the next instruction. While the Builder waits for an approval, messages to it are refused with `409` until the approval is answered.

Each step takes 1.5 seconds.

```sh
ALIFE_BACKEND=dummy swift run ALifeServer
```

An interrupt stops one character and leaves the others be, and calls back any helpers it has out.

## How it fits together

The routes know nothing about what plays a character. For each session they talk to two things:

- `SessionHub` keeps the session's event log and its open streams. Whatever drives the session calls `hub.emit(_:)` for each thing that happens.
- `SessionBackend` is the protocol the routes call: `handleMessage`, `interrupt`, `decide`, `setAutoApprove`, `reset`, and `shutdown` when the server stops.

The lot has a hub of its own, `LotHub`, which keeps what stands on the lot, looks at the lot's directory every second, and sends the lot to its open streams when it changes.

`ClaudeCharacter` and `DummyCharacter` both conform to `SessionBackend` and emit the same events. `configure.swift` is the one place that chooses which plays the characters.

## Layout

| File | What it does |
|---|---|
| `entrypoint.swift` | Starts Vapor, or runs `add-agent` without it. |
| `configure.swift` | Reads the settings, sets up a hub and a backend per character, the lot's hub, and the routes. |
| `agents.yaml` | The cast the server ships with: who each character is, its colour, its permission mode and its helper. See [The agents file](#the-agents-file). |
| `Cast.swift` | Reads and checks the agents file into `Character`s, each with its `Helper` and where it works, its `Workspace`, and adds a new agent after the last one without changing the others. |
| `AddAgent.swift` | The `add-agent` command, which the Team Lead's recruiter runs to add an agent to the agents file. See [The Team Lead and the agents file](#the-team-lead-and-the-agents-file). |
| `routes.swift` | The HTTP API, including the event streams and the lot's, and the voice model's files. |
| `SessionHub.swift` | One session's event log, snapshot, and fan-out to its open streams. |
| `LotSurvey.swift` | Reads the buildings and beds in the lot's `buildings/` and `garden/`, checks them against the lot's edges, the house, each other and how many animals fit in a bed, and writes `lot.md`, with the animals the app draws. |
| `LotHub.swift` | What stands on the lot: looks at it every second and sends it to the clients following it when it changes. |
| `SessionBackend.swift` | The protocol a session's backend implements, and `HostedSession`, which pairs it with its hub. |
| `ClaudeCharacter.swift` | A character played by a Claude Code session: turns its stream-json into the session's events, and approvals, interrupts and starting over into what the CLI expects. |
| `ClaudeCode.swift` | Finds the `claude` CLI and the a\*life checkout, clones the projects that are git repositories (one, or several side by side), starts the CLI where its character works, with the agents file and the server's command in its environment, and reads and writes its stream-json, one message per line. |
| `JSONValue.swift` | Plain JSON, for reading Claude Code's messages. |
| `DummyCharacter.swift` | The scripted stand-in. |
| `fetch-voice.sh` | Not in `Sources`: fetches the voice model into `ALIFE_VOICE_DIR`. See [Voices](#voices). |

## Tests

```sh
swift test
```

The tests start the server on a free local port with the dummy characters and drive it with the real client package: each character in a session of its own, the Builder's approval, the helpers each character sends off, a second front end joining late, auto approve in one session and not the others, starting one session over, interrupting one character while the other carries on (and calling its helpers back), a question answered mid-task, reconnecting mid-session, and bad requests.

`ClaudeCharacterTests` play Claude Code's side of the stream-json with lines like the ones it really writes: "build me an office" sending the Builder's construction worker off and its approval going back to Claude Code, the Conservationist's keeper, the Engineer sending its a\*life expert off in the a\*life checkout, the Team Lead sending its recruiter off to add an agent, denying, auto approve, interrupting with a helper out, Claude Code stopping and being resumed, starting over, helpers in the background, and errors. `ClaudeCodeProcessTests` check the pipes to a real child process, which directory each character works in, the agents file and the server's command each session is given, finding the a\*life checkout, and a project's repository being cloned once from a bare repository on disk and then reused as it is, at a branch, and when it can't be cloned, and a project's several repositories cloned side by side the same way.

`LotTests` put buildings and beds on a temporary lot: what a file says and what it can leave out, kinds nobody knows, the Conservationist's foals, bears, polar bears, birds, unicorns, pegasuses and dinosaurs and how many fit in a bed, what keeps a file off the lot and what the server says about it, the older of two overlapping things staying, emptied files, the list and map in `lot.md`, the hub sending each change, the construction worker and the keeper being told where the house is, the keeper being told about every animal the app draws, and a front end seeing a restaurant and an oak appear.

`VoiceModelTests` fetch a voice model's files from the address the client package gives, names with spaces in them included, and check that nothing outside it, and no hidden file, is served, and that a server without a model has nothing to fetch.

`CastTests` read the agents file: the shipped one and what is in it, every field, what an agent can leave out, the mistakes the server refuses and what it says about each, projects on a path, in a repository or in several, and the mistakes in them, such as an https address, the Flamingo Engineer, the Team Lead and its recruiter, the App Engineer in the shipped file once its comments are taken off, adding an agent (after the last one, leaving the others and the comments as they are, and refusing one whose id or name is taken or whose fields are wrong, without touching the file), the `add-agent` command, `ALIFE_AGENTS_FILE` and the checkout's agents file, and a server with a cast of its own.

One test runs the Builder on the Claude Code installed on your Mac, tells it to build an office, allows whatever it asks, and checks that its construction worker was sent off and a building is on a temporary lot. It costs a little, so it only runs when asked:

```sh
ALIFE_LIVE_CLAUDE=1 ALIFE_CLAUDE_MODEL=haiku swift test --filter LiveClaudeCodeTests
```
