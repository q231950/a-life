# a*life

A minimal life-sim sandbox for iOS and macOS, built with SwiftUI and RealityKit. A little character walks around a 16×16 lot. Tap a tile and the character finds its way there with A* pathfinding, around the walls of a small house and some bushes.

The lot also shows a team of agents: one character per agent. An agent walks into the house while it is working and waits on the lawn while it is idle. The team lives on a small server you run yourself, [`a-life-server`](a-life-server), which the apps reach over Tailscale. For now the team is a dummy that plays a fixed script.

## Run it

Open `ALife.xcodeproj` in Xcode 16 or later, pick the **ALife** scheme, and run it on an iPhone/iPad simulator or **My Mac**. To run on a device, set your team under *Signing & Capabilities*.

Requires iOS 18 / macOS 15, the first releases where `RealityView` and entity-targeted gestures work outside visionOS.

| | iOS / iPadOS | macOS |
|---|---|---|
| Walk | Tap a tile | Click a tile |
| Orbit camera | Drag | Drag |
| Zoom | Pinch | Scroll wheel or trackpad pinch |

## The agents

The front ends don't run agents themselves. They follow a session on the server and send it instructions.

1. Start the server on your Mac: `cd a-life-server && swift run ALifeServer`.
2. Run the app, open the settings (the gear at the top) and set the server's address. On the same Mac or in the simulator, press **Use this machine**. From another device, enter the HTTPS address `tailscale serve` gives you; [`a-life-server/README.md`](a-life-server/README.md) walks through that.
3. Type an instruction in the field at the bottom. The team lead hands work to the Gardener and the Builder, the Builder asks for approval of a command (Allow or Deny), and the team lead sums up.

Every front end connected to the same server sees the same session. If the connection drops, the app reconnects and the server sends what it missed.

## How it's put together

| File | What it does |
|---|---|
| `ALifeApp.swift` | App entry point. Registers the custom components and the walk system, and owns the `AgentSession`. |
| `WorldView.swift` | The `RealityView`, plus the gestures and the macOS scroll-wheel monitor. |
| `World.swift` | Builds the lot (tiles, walls, bushes, character, sun), turns a tapped tile into a walk, and keeps one character per agent. |
| `AgentPanel.swift` | The status pill, the last few messages, tool approvals and the instruction field. |
| `SettingsView.swift` | Sets the server's address. |
| `CameraRig.swift` | Orbit camera: a pivot entity that yaws and pitches, with a `PerspectiveCamera` on a boom. |
| `WalkSystem.swift` | ECS: `TileComponent`, `WalkComponent`, and a `System` that moves walkers along their waypoints every frame. |
| `TileGrid.swift` | Plain Swift with no RealityKit: the floor plan and A* (8-directional, no corner cutting). |

Every floor tile is its own entity with a `CollisionComponent` and an `InputTargetComponent`. A tap therefore hits the tile directly, so the code never has to turn a screen point into a world position.

### The `ALifeKit` package

`ALifeKit/` is a local Swift package with no dependencies and two modules.

| Module | What it holds |
|---|---|
| `ALifeAPI` | The wire format: `Agent`, `Message`, `Approval`, `SessionEvent`, the request bodies, and `SessionState`, which turns a sequence of events into what a front end shows. The server uses this module too, so the two can't drift apart. |
| `ALifeClient` | What a front end uses. `AgentSession` is the observable handle on the session: `connect()`, `send(_:)`, `interrupt(_:)`, `respond(to:allow:)`, `startNewSession()`, `setServerURL(_:)`, and the state to draw (`agents`, `transcript`, `pendingApprovals`, `phase`, `status`). `ALifeServerClient` makes the HTTP calls and reads the event stream. |

### The server

[`a-life-server/`](a-life-server) is a separate Swift package (Vapor). Its README covers running it, Tailscale, the API and where a real team would plug in.

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
