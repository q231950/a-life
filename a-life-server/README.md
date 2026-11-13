# a-life-server

The backend the a*life front ends talk to. It is a [Vapor](https://vapor.codes) server meant to run on your own Mac and be reached over [Tailscale](https://tailscale.com).

It holds one session: a team of agents, the conversation with them, and any tool calls waiting for a yes or no. Front ends follow the session over a stream of events and send instructions back.

**The team is a dummy for now.** Every instruction plays the same short script so the front ends can be run end to end. No model is called and nothing real happens. See [The dummy team](#the-dummy-team).

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

In one terminal, follow the session:

```sh
curl -N http://127.0.0.1:8080/v1/session/events
```

In another, send an instruction, then answer the approval the Builder asks for:

```sh
curl -X POST http://127.0.0.1:8080/v1/session/messages \
  -H 'Content-Type: application/json' -d '{"text":"Tidy the lot"}'

# a few seconds later, look up the approval's id ...
curl http://127.0.0.1:8080/v1/session

# ... and allow it
curl -X POST http://127.0.0.1:8080/v1/session/approvals/<id> \
  -H 'Content-Type: application/json' -d '{"allow":true}'
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
- **There is no login on this server.** Anyone who can reach the address can instruct the team and answer approvals. With `tailscale serve` that means the devices in your tailnet, subject to its access rules. Don't use `tailscale funnel` for it: that publishes the address to the whole internet.

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

| Method | Path | Body | What it does |
|---|---|---|---|
| `GET` | `/health` | | `{"status":"ok"}` |
| `GET` | `/v1/session` | | The session right now: status, agents, messages, pending approvals, last sequence number. |
| `GET` | `/v1/session/events` | | The event stream (server-sent events). See below. |
| `POST` | `/v1/session/messages` | `{"text": "…"}` | An instruction for the team lead. Instructions queue while the team is busy. |
| `POST` | `/v1/session/interrupt` | `{"agent_id": "…"}` or nothing | Stops one agent, or the whole team. |
| `POST` | `/v1/session/approvals/{id}` | `{"allow": true}` | Answers a tool call that is waiting. `404` if there is no such approval. |
| `POST` | `/v1/session/reset` | | Ends the session and starts an empty one, for every front end. |

The `POST` routes answer `202 Accepted` as soon as the request is taken; what happens next arrives on the event stream. Errors look like `{"error": true, "reason": "…"}`.

### The event stream

`GET /v1/session/events` stays open and sends one event per thing that happens:

```
id: 5
event: agent.updated
data: {"seq":5,"event":{"type":"agent.updated","agent":{"id":"lead","name":"Team lead","status":"running","is_coordinator":true,"activity":"planning"}}}
```

Every event has a sequence number that only goes up. A client applies events in order to build its picture of the session, and remembers the last number it saw. When it reconnects it passes that number and the session's id:

```
GET /v1/session/events?after=5&session=<session id>
```

The server then sends everything after 5 and carries on live, so nothing is missed or repeated. If the session id isn't the current one (the session was reset, or the server restarted), or none is given, the server sends the current session from its start. A comment line (`: ping`) goes out every 15 seconds to keep the connection open.

| Event | Carries | Meaning |
|---|---|---|
| `session.started` | `session_id` | A new session began. Drop everything known about the old one. |
| `session.status` | `status`, `stop_reason` | The team as a whole is `running` or `idle`. When idle, `stop_reason` is `end_turn`, `requires_action` (an approval is waiting) or `interrupted`. |
| `agent.updated` | `agent` | An agent joined or changed: `id`, `name`, `status`, `is_coordinator`, `activity`. |
| `agent.removed` | `agent_id` | An agent left. |
| `message` | `message` | A line of the conversation: `id`, `kind` (`user`, `agent`, `handoff`, `error`), `speaker`, `text`. |
| `approval.requested` | `approval` | A tool call needs a yes or no: `id`, `agent_id`, `agent_name`, `tool_name`, `input`. |
| `approval.resolved` | `approval_id` | It was answered, or is no longer needed. |

Clients skip event types they don't know, so new ones can be added.

## The dummy team

`DummyTeam` plays this for every instruction:

1. The **Team lead** plans, then hands a task each to the **Gardener** and the **Builder**.
2. The Gardener reports back.
3. The Builder asks for approval of a shell command. The session goes idle with `requires_action` and waits for as long as it takes.
4. Once answered, the Builder reports back (what it says depends on the answer) and the Team lead sums up.

Each step takes 1.5 seconds. Set `ALIFE_DUMMY_STEP_MS` to change that:

```sh
ALIFE_DUMMY_STEP_MS=300 swift run ALifeServer
```

An interrupt stops the whole team, whichever agent it names. Nothing is saved: restarting the server starts a new session.

## Putting a real team behind it

The routes know nothing about the dummy. They talk to two things:

- `SessionHub` keeps the event log and the open streams. Whatever drives the team calls `hub.emit(_:)` for each thing that happens.
- `TeamBackend` is the protocol the routes call: `handleMessage`, `interrupt`, `decide`, `reset`.

A real team is another type that conforms to `TeamBackend` and emits the same events. `configure.swift` is the one place that chooses which to use.

## Layout

| File | What it does |
|---|---|
| `entrypoint.swift` | Starts Vapor. |
| `configure.swift` | Creates the hub and the team, registers the routes. |
| `routes.swift` | The HTTP API, including the event stream. |
| `SessionHub.swift` | Event log, snapshot, and fan-out to the open streams. |
| `TeamBackend.swift` | The protocol a team implements. |
| `DummyTeam.swift` | The scripted stand-in. |

## Tests

```sh
swift test
```

The tests start the server on a free local port and drive it with the real client package: a front end running the dummy team from start to finish, a second front end joining late, interrupting, reconnecting mid-session, and bad requests.
