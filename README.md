# a*life

A minimal life-sim sandbox for iOS and macOS, built with SwiftUI and RealityKit. A little character walks around a 16×16 lot. Tap a tile and the character finds its way there with A* pathfinding, around the walls of a small house and some bushes.

The lot also shows a team of [Claude Managed Agents](https://platform.claude.com/docs/en/managed-agents/quickstart): one character per agent in a multiagent session. An agent walks into the house while it is working and waits on the lawn while it is idle. This part is a proof of concept.

## Run it

Open `ALife.xcodeproj` in Xcode 16 or later, pick the **ALife** scheme, and run it on an iPhone/iPad simulator or **My Mac**. To run on a device, set your team under *Signing & Capabilities*.

Requires iOS 18 / macOS 15, the first releases where `RealityView` and entity-targeted gestures work outside visionOS.

| | iOS / iPadOS | macOS |
|---|---|---|
| Walk | Tap a tile | Click a tile |
| Orbit camera | Drag | Drag |
| Zoom | Pinch | Scroll wheel or trackpad pinch |

## The agents

Open the settings (the gear at the top) and paste an Anthropic API key. It is kept in the Keychain and sent only to `api.anthropic.com`. Only do this in builds you run yourself: a key inside an app can be read by whoever has the app, so anything you distribute should go through a backend that holds the key.

The first connection creates three things in the key's workspace and stores their IDs:

- a cloud **environment**, the sandbox the agents share;
- a coordinator **agent** ("Team lead", on Claude Opus 5.5) that can hand work to copies of itself or to agents it defines;
- a **session**, the running instance, with a $5 spend cap.

The session lives on Anthropic's side. Later launches reattach to it, replay its history and follow its live event stream. Type an instruction in the field at the bottom; it goes to the coordinator. Tool calls the server won't decide on its own show up with Allow and Deny buttons.

Things that cost money: nothing runs until you send an instruction, and the session pauses at its cap. Dynamic workflows are on, which lets the coordinator fan a big job out to many agents at once; set `workflowsEnabled` to `false` in `TeamBlueprint` to turn that off, and change `sessionBudgetCents` to move the cap. Both apply to agents and sessions created afterwards.

## How it's put together

| File | What it does |
|---|---|
| `ALifeApp.swift` | App entry point. Registers the custom components and the walk system, and owns the `AgentSession`. |
| `WorldView.swift` | The `RealityView`, plus the gestures and the macOS scroll-wheel monitor. |
| `World.swift` | Builds the lot (tiles, walls, bushes, character, sun), turns a tapped tile into a walk, and keeps one character per agent. |
| `AgentPanel.swift` | The status pill, the last few messages, tool approvals and the instruction field. |
| `SettingsView.swift` | Sets the API key and shows the stored IDs. |
| `CameraRig.swift` | Orbit camera: a pivot entity that yaws and pitches, with a `PerspectiveCamera` on a boom. |
| `WalkSystem.swift` | ECS: `TileComponent`, `WalkComponent`, and a `System` that moves walkers along their waypoints every frame. |
| `TileGrid.swift` | Plain Swift with no RealityKit: the floor plan and A* (8-directional, no corner cutting). |

Every floor tile is its own entity with a `CollisionComponent` and an `InputTargetComponent`. A tap therefore hits the tile directly, so the code never has to turn a screen point into a world position.

### The `ManagedAgents` package

`ManagedAgents/` is a local Swift package with no dependencies. There is no official Swift SDK for the API, so it talks to the REST endpoints with `URLSession`.

| Type | What it does |
|---|---|
| `AgentSession` | Observable handle on one multiagent session: `connect()`, `send(_:)`, `interrupt(_:)`, `respond(to:allow:)`, `startNewSession()`, and the state to draw (`agents`, `transcript`, `pendingApprovals`, `phase`, `status`). |
| `ManagedAgentsClient` | The HTTP calls: create environment, agent and session; list threads and events; send events; stream events. |
| `TeamBlueprint` | The agent and environment that get created on first run. |
| `KeychainAPIKeyStore`, `UserDefaultsSessionReferenceStore` | Where the key and the IDs are kept. Both sit behind protocols, with in-memory versions for tests. |

The event stream has no replay, so on every connect `AgentSession` opens the stream first, then loads the history, and applies each event once by ID. If the stream drops it reconnects the same way.

Run the package's tests with `swift test --package-path ManagedAgents`. They drive `AgentSession` against a stubbed API.

## Ideas for next steps

- Swap `TileGrid` for RealityKit's navigation mesh (`NavigationMeshResource` / `NavigationComponent` / `NavigationController`, new at WWDC26) once you can raise the deployment target. `TileGrid.path` already returns the same thing `computePath` does: `nil` if there's no path, `[]` if you're already there.
- Replace the box character with a rigged USDZ that has walk and idle animations.
- Build mode: snap furniture to the grid and call `grid.block(_:)` for each piece.
- Keyboard camera controls on macOS with `.onKeyPress`.
