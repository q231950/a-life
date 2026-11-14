# a-life-server

The backend the a*life front ends talk to. It is a [Vapor](https://vapor.codes) server meant to run on your own Mac and be reached over [Tailscale](https://tailscale.com).

It holds one session per character on the lot. Each session is the character's own, like a separate Claude Code session: its conversation, what it is doing, and any tool call it is waiting on you to allow. Front ends follow every session over a stream of events, and talk to each character directly. No character coordinates the others; that's up to you.

**The characters are dummies for now.** Each one plays a short script for whatever it is told, so the front ends can be run end to end. No model is called and nothing real happens. See [The dummy characters](#the-dummy-characters).

## Run it

You need Swift 6 (Xcode 16 or later) on macOS 14 or later.

```sh
cd a-life-server
swift run ALifeServer
```

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
  -H 'Content-Type: application/json' -d '{"text":"Tidy the lot"}'

# a few seconds later, look up the approval's id ...
curl http://127.0.0.1:8080/v1/sessions/builder

# ... and allow it
curl -X POST http://127.0.0.1:8080/v1/sessions/builder/approvals/<id> \
  -H 'Content-Type: application/json' -d '{"allow":true}'
```

The Gardener's session is at `/v1/sessions/gardener`, and carries on independently.

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
- **There is no login on this server.** Anyone who can reach the address can instruct the characters and answer approvals. With `tailscale serve` that means the devices in your tailnet, subject to its access rules. Don't use `tailscale funnel` for it: that publishes the address to the whole internet.

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
| `GET` | `/v1/sessions` | | Every session as it is right now, one per character: id, name, status, what it is doing, messages, pending approvals, helpers out, last sequence number. |
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

## The dummy characters

`configure.swift` sets up the cast: a `DummyCharacter` for each, with a session of its own.

- The **Gardener** only looks. It reads, then sends two helpers off at once, one to search the flower beds and one to check the hedges, and reports back once both have reported back to it. It never asks for permission, like a Claude Code session in plan mode.
- The **Builder** changes things. It reads, sends a helper off to measure the north corner and waits for it, then asks for approval of a shell command. The session goes idle with `requires_action` and waits for as long as it takes. Once answered, it runs the command (or doesn't) and reports back.

The helpers stand in for a Claude Code session's subagents. Each one is out for a few steps (the Gardener's for four and six, the Builder's for four) and takes no messages of its own; while they are out, the character's activity is `agent`.

Both can be talked to while they work: something said mid-task is answered at the next step ("Still on … Right now I'm …") and the work carries on. Something said after the last step becomes the next instruction. While the Builder waits for an approval, messages to it are refused with `409` until the approval is answered.

Each step takes 1.5 seconds. Set `ALIFE_DUMMY_STEP_MS` to change that:

```sh
ALIFE_DUMMY_STEP_MS=300 swift run ALifeServer
```

An interrupt stops one character and leaves the others be, and calls back any helpers it has out. Nothing is saved: restarting the server starts every session afresh.

To add a character, add a line to `cast` in `configure.swift`. The front ends pick it up when they next connect.

## Putting real sessions behind it

The routes know nothing about the dummies. For each session they talk to two things:

- `SessionHub` keeps the session's event log and its open streams. Whatever drives the session calls `hub.emit(_:)` for each thing that happens.
- `SessionBackend` is the protocol the routes call: `handleMessage`, `interrupt`, `decide`, `reset`.

A real session, such as one Claude Code session per character, is another type that conforms to `SessionBackend` and emits the same events. `configure.swift` is the one place that chooses what each character runs.

## Layout

| File | What it does |
|---|---|
| `entrypoint.swift` | Starts Vapor. |
| `configure.swift` | The cast, a hub and a backend per character, and the routes. |
| `routes.swift` | The HTTP API, including the event streams. |
| `SessionHub.swift` | One session's event log, snapshot, and fan-out to its open streams. |
| `SessionBackend.swift` | The protocol a session's backend implements, and `HostedSession`, which pairs it with its hub. |
| `DummyCharacter.swift` | The scripted stand-in. |

## Tests

```sh
swift test
```

The tests start the server on a free local port and drive it with the real client package: each character in a session of its own, the Builder's approval, the helpers each character sends off, a second front end joining late, starting one session over, interrupting one character while the other carries on (and calling its helpers back), a question answered mid-task, reconnecting mid-session, and bad requests.
