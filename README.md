# a*life

A minimal life-sim sandbox for iOS and macOS, built with SwiftUI and RealityKit. A little character walks around a 16×16 lot. Tap a tile and the character finds its way there with A* pathfinding, around the walls of a small house and some bushes.

The lot also shows your agents: one character per session. Each character is a session of its own, like a separate Claude Code session: you talk to it directly, it asks you before it does anything risky, and what you tell one never reaches the others. A character walks into the house while it works, stays at its desk with a "!" over its head while it waits for your answer, and waits on the lawn otherwise. When a character sends a helper off to do part of its work (a subagent, in Claude Code terms), a little sheep in the character's colour pops up beside it and wanders the lot. Once the helper has reported back, the sheep walks back to its character, stays a moment, then spins and flies up into the sky until it's out of sight. The sessions live on a small server you run yourself, [`a-life-server`](a-life-server), which the apps reach over Tailscale. For now every character is a dummy that plays a short script.

## Run it

Open `ALife.xcodeproj` in Xcode 16 or later, pick the **ALife** scheme, and run it on an iPhone/iPad simulator or **My Mac**. To run on a device, set your team under *Signing & Capabilities*.

Requires iOS 18 / macOS 15, the first releases where `RealityView` and entity-targeted gestures work outside visionOS.

| | iOS / iPadOS | macOS |
|---|---|---|
| Walk | Tap a tile | Click a tile |
| Orbit camera | Drag | Drag |
| Zoom | Pinch | Scroll wheel or trackpad pinch |

## The agents

The front ends don't run agents themselves. They follow each character's session on the server and send it what you say.

1. Start the server on your Mac: `cd a-life-server && swift run ALifeServer`.
2. Run the app, open the settings (the gear at the top) and set the server's address. On the same Mac or in the simulator, press **Use this machine**. From another device, enter the HTTPS address `tailscale serve` gives you; [`a-life-server/README.md`](a-life-server/README.md) walks through that.
3. Tap a character, or its name in the panel at the bottom, and tell it what to do. The **Gardener** looks around, sends two helpers off to search and reports back once both have; it never needs permission. The **Builder** sends a helper off to measure, then asks for approval of a command (Allow or Deny), and can't be told anything else until you answer. You can talk to a character while it works, too: it answers at its next step and carries on.

There is no team lead: you are the one handing out work and carrying news between characters. Your own character, the one labelled "You", is the one that walks where you tap.

Every front end connected to the same server sees the same sessions. If the connection drops, the app reconnects and the server sends what it missed.

## How it's put together

| File | What it does |
|---|---|
| `ALifeApp.swift` | App entry point. Registers the custom components and the walk system, and owns the `ServerConnection`. |
| `WorldView.swift` | The `RealityView`, plus the gestures (tap a character to talk to it, a tile to walk there) and the macOS scroll-wheel monitor. |
| `World.swift` | Builds the lot (tiles, walls, bushes, your character, sun), turns a tapped tile into a walk, and keeps one character per session, with a ring under the one you're talking to and a sheep beside it for each helper it sends off. |
| `AgentPanel.swift` | The status pill, a button per character, and the conversation with the one you picked: its last few messages, tool approvals, the message field, Stop and Start over. |
| `SettingsView.swift` | Sets the server's address. |
| `CameraRig.swift` | Orbit camera: a pivot entity that yaws and pitches, with a `PerspectiveCamera` on a boom. |
| `WalkSystem.swift` | ECS: `TileComponent`, `LotComponent` (the floor plan, on the lot's root, with routes between tiles), `WalkComponent`, and a `System` that moves walkers along their waypoints every frame. |
| `SheepSystem.swift` | ECS: `SheepComponent` and a `System` that takes each helper's sheep from popping up, through wandering to random tiles, back to its character once the helper has reported back, to spinning off into the sky until the camera can't see it. |
| `TileGrid.swift` | Plain Swift with no RealityKit: the floor plan and A* (8-directional, no corner cutting). |

Every floor tile is its own entity with a `CollisionComponent` and an `InputTargetComponent`. A tap therefore hits the tile directly, so the code never has to turn a screen point into a world position.

### The `ALifeKit` package

`ALifeKit/` is a local Swift package with no dependencies and two modules.

| Module | What it holds |
|---|---|
| `ALifeAPI` | The wire format: `Message`, `Approval`, `Subagent`, `SessionEvent`, the request bodies, and `SessionState`, which turns a session's events into what a front end shows of that character. The server uses this module too, so the two can't drift apart. |
| `ALifeClient` | What a front end uses. `ServerConnection` follows every session on a server: `connect()`, `setServerURL(_:)`, `startEverySessionOver()`, `phase`, and `sessions`, one `AgentSession` per character. An `AgentSession` is the observable handle on one character: `send(_:)`, `interrupt()`, `respond(to:allow:)`, `startOver()`, and the state to draw (`status`, `activity`, `transcript`, `pendingApprovals`, `isWaitingForYou`, `subagents`, `lastError`). `ALifeServerClient` makes the HTTP calls and reads the event streams. |

### The server

[`a-life-server/`](a-life-server) is a separate Swift package (Vapor). Its README covers running it, Tailscale, the API and where real sessions would plug in.

### Tests

```sh
swift test --package-path ALifeKit        # the client against a stubbed server
swift test --package-path a-life-server   # the client against the real server
```

## Ideas for next steps

- Swap `TileGrid` for RealityKit's navigation mesh (`NavigationMeshResource` / `NavigationComponent` / `NavigationController`, new at WWDC26) once you can raise the deployment target. `TileGrid.path` already returns the same thing `computePath` does: `nil` if there's no path, `[]` if you're already there.
- Replace the box character with a rigged USDZ that has walk and idle animations.
- Build mode: snap furniture to the grid and call `grid.block(_:)` for each piece.
- Keyboard camera controls on macOS with `.onKeyPress`.
