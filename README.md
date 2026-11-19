# a*life

A minimal life-sim sandbox for iOS and macOS, built with SwiftUI and RealityKit. A little character walks around a 64×64 lot. Tap a tile and the character finds its way there with A* pathfinding, around the walls of a small house in the middle of the lot, and around whatever has been built and planted there.

The lot also shows your agents: one character per session. Each character is a Claude Code session of its own, run by the Claude Code on your Mac: you talk to it directly, it asks you before it does anything risky, and what you tell one never reaches the others. A character walks into the house while it works, stays at its desk with a "!" over its head while it waits for your answer, and waits on the lawn otherwise. When a character sends a helper off to do part of its work (a subagent, in Claude Code terms), a little sheep in the character's colour pops up beside it and wanders the lot. Once the helper has reported back, the sheep walks back to its character, stays a moment, then spins and flies up into the sky until it's out of sight. What the Builder builds and the Gardener plants appears on the lot: tell the Builder to build a restaurant and a restaurant pops up, with a striped awning and its name over it, or a barn, with chickens and goats in a pen and horses that gallop round the lot and come back to feed; ask the Gardener for roses or an oak and they grow there, or for foals, which trot, frisk, graze and lie down round their patch. The sessions live on a small server you run yourself, [`a-life-server`](a-life-server), which the apps reach over Tailscale.

## Run it

Open `ALife.xcodeproj` in Xcode 16 or later, pick the **ALife** scheme, and run it on an iPhone/iPad simulator or **My Mac**. To run on a device, set your team under *Signing & Capabilities*.

Requires iOS 18 / macOS 15, the first releases where `RealityView` and entity-targeted gestures work outside visionOS.

| | iOS / iPadOS | macOS |
|---|---|---|
| Walk | Tap a tile | Click a tile |
| Orbit camera | Drag | Drag |
| Zoom | Pinch | Scroll wheel or trackpad pinch |

The camera glides after you to wherever you walk, and over to anything that has just been built or planted. Zoom all the way out to see the whole lot.

## The agents

The front ends don't run agents themselves. They follow each character's session on the server and send it what you say.

1. Start the server on your Mac: `cd a-life-server && swift run ALifeServer`. It needs [Claude Code](https://code.claude.com) installed and logged in; the characters use your login and count towards your usage. (`ALIFE_BACKEND=dummy` runs scripted stand-ins instead, which cost nothing.)
2. Run the app, open the settings (the gear at the top) and set the server's address. On the same Mac or in the simulator, press **Use this machine**. From another device, enter the HTTPS address `tailscale serve` gives you; [`a-life-server/README.md`](a-life-server/README.md) walks through that.
3. Tap a character, or its name in the panel at the bottom, and tell it what to do. Tell the **Builder** "build a restaurant" and it sends its construction worker off, a helper that builds the restaurant as a file in the lot's `buildings/` directory; the construction worker asks before it writes (Allow or Deny), and the Builder can't be told anything else until you answer. Once it is written, the restaurant appears on the lot. Ask the **Gardener** to plant roses or an oak, or to put out a few foals, and it sends its planter off, which plants them in `garden/`, and they grow on the lot; changes to the lot go ahead without asking. The **Engineer**, in the purple shirt, works on a\*life itself rather than on the lot: its session works in your a\*life checkout, and when you ask it to fix or add something in the app or the server it sends its a\*life expert off, a helper that knows a\*life inside out, to make the change and run the tests. The a\*life expert asks before every change and command, and leaves its changes in your checkout for you to look over; [the server's README](a-life-server/README.md#the-engineer-and-the-alife-checkout) has more. You can talk to a character while it works, too: Claude Code takes it up at its next step and carries on.

The characters share the lot, a directory on your Mac (`~/a-life-lot` unless you set `ALIFE_LOT_DIR`), so the Gardener can see where the Builder has built. Each building and bed starts with a few lines that say what it is and where it stands; the server reads them, keeps the two from landing on each other or on the house, and sends the lot to the apps. [The server's README](a-life-server/README.md#the-lot) has the details. There is no team lead: you are the one handing out work and carrying news between characters. Who is on the lot, and what each one is told, is set in the server's agents file, [`agents.yaml`](a-life-server/Sources/ALifeServer/agents.yaml): change a character, add one or take one away there, and restart the server ([its README](a-life-server/README.md#the-agents-file) describes the format). A character there can also work on a project of your own rather than the lot, a directory on your Mac or one or more git repositories the server clones, so that you can hand it the work on another app; [A character for another project](a-life-server/README.md#a-character-for-another-project) shows how. The **Flamingo Engineer**, in pink, is one: it looks after Flamingo Chess, whose iOS app, Light Phone app and server the server clones side by side for it. Your own character, the one labelled "You", is the one that walks where you tap.

Every front end connected to the same server sees the same sessions. If the connection drops, the app reconnects and the server sends what it missed.

### Hearing them

The characters say what they have to say out loud, each in a voice of its own, but only while your character stands within 3 tiles of theirs: walk over to the house to hear the one at its desk. Out of earshot, they keep quiet, and a line said while you were away isn't saved for later. Walk away mid-sentence and the character stops. Only what a character says to you is spoken, read as plain prose: not your own messages, its tool calls, its errors, or its code. Lines are said one at a time, in the order they came.

The voices are [Phonon](https://github.com/gradium-ai/xn-ptts) text to speech, which runs on the device, on Apple silicon. The app downloads the voice model (about 160 MB) from the server the first time, and keeps it; for that, fetch it onto the server's Mac once with `a-life-server/fetch-voice.sh` and restart the server ([Voices](a-life-server/README.md#voices) has the details). Settings shows how the voices are getting on, the last line said out loud, and why a line wasn't, if one wasn't. On an iPhone or iPad the voices play with the silent switch on, at the media volume, alongside whatever else is playing.

## How it's put together

| File | What it does |
|---|---|
| `ALifeApp.swift` | App entry point. Registers the custom components and systems, and owns the `ServerConnection`. |
| `WorldView.swift` | The `RealityView`, plus the gestures (tap a character to talk to it, a tile to walk there) and the macOS scroll-wheel monitor. Hands the world the sessions and the lot, and the narrator what the characters say and who is in earshot. |
| `World.swift` | Builds the 64×64 lot from `LotPlan` (the floor, walls, bushes, your character, sun), turns a tapped tile into a walk, shows what's built and planted, and keeps one character per session, with a ring under the one you're talking to and a sheep beside it for each helper it sends off. |
| `Buildings.swift` | The Builder's buildings, drawn by kind: a house with a pitched roof and a chimney, a restaurant, cafe or shop with a striped awning, an office or a block of flats with bands of windows, a tower as a wind turbine with turning blades and a blinking red light on top, a school or shed, a barn with its farmyard and horses (see `Barn.swift`), a church with a spire, a hospital with a red cross, and a plain building for anything else, each with its name over it. |
| `Plants.swift` | The Gardener's beds, drawn by kind, one plant on each tile: flowers in their colour (roses, tulips, daisies, tall sunflowers, lavender), trees (oak, birch, apple, cherry, maple, pine, palm), bushes, hedges, grass and vegetables (carrots, lettuces, cabbages, tomatoes, pumpkins), and a little green plant for anything else. |
| `AgentPanel.swift` | The status pill, a button per character, and the conversation with the one you picked, which folds down to a bar of the characters' statuses: the whole conversation in a view that scrolls (what was said, the tools the character used, and its requests for a yes or no, with Allow and Deny while they wait and what was chosen afterwards), the message field, Stop and Start over. |
| `SettingsView.swift` | Sets the server's address, and shows how the voices are getting on and the last line they said. |
| `Voices.swift` | The characters' voices: downloads the Phonon voice model from the server once, loads it, and speaks a line in the voice that goes with each character, through the `SpeechEngine` protocol the `Narrator` uses. |
| `CameraRig.swift` | Orbit camera: a pivot entity that yaws and pitches, with a `PerspectiveCamera` on a boom, which glides over the lot to where it's told to look. |
| `WalkSystem.swift` | ECS: `TileComponent`, `LotComponent` (the floor plan, on the lot's root, with routes between tiles), `WalkComponent`, and a `System` that moves walkers along their waypoints every frame. |
| `SheepSystem.swift` | ECS: `SheepComponent` and a `System` that takes each helper's sheep from popping up, through wandering to random tiles nearby, back to its character once the helper has reported back, to spinning off into the sky until the camera can't see it. |
| `Foals.swift` | The Gardener's foals: a bed whose kind is a foal (or a pony, a colt, a filly or a baby horse) has one on each tile, on a patch of long grass that anyone can walk across. Each is built like a barn's horse at half the size, with long legs, a short body, a big head and a stubby tail, in the bed's colour or a coat of its own, as the bed's child. |
| `Barn.swift` | A barn (or a stable or a farm) and its farmyard, on the barn's own tiles: a red barn with big braced doors and a hayloft, a trough of hay in front, a fenced pen of chickens and goats beside it and, if there's room, a round lunging ring with a sand floor. Two or three horses come with it, as the barn's children, so they go when it does. |
| `BarnSystem.swift` | ECS: `HorseComponent`, `FoalComponent`, `PenAnimalComponent` and a `System` that takes each horse from feeding at the trough, head down, to galloping off to a few places round the lot (on routes round whatever stands there), back to the trough, and now and then, one at a time, through the gate and round the lunging ring; their legs swing and their bodies bob as they go. The foals stay within a few tiles of their bed: they graze, trot or dash off, buck and kick up their heels, and lie down for a rest. The chickens potter about the pen, pecking, and the goats graze. |
| `TurbineSystem.swift` | ECS: `SpinComponent`, `BlinkComponent` and a `System` that turns a wind turbine's rotor and blinks the red light on top of it every frame. |
| `TileGrid.swift` | Plain Swift with no RealityKit: the floor plan and A* (8-directional, no corner cutting). |

Every floor tile is its own entity with a `CollisionComponent` and an `InputTargetComponent`. A tap therefore hits the tile directly, so the code never has to turn a screen point into a world position. The grass itself is drawn as two meshes, one for the light tiles and one for the dark, so the 4,096 tiles don't cost 4,096 draw calls.

### The `ALifeKit` package

`ALifeKit/` is a local Swift package with no dependencies and two modules. The app also uses Phonon's `ptts` package for its voices; it is Apple silicon only, so the app isn't built for Intel.

| Module | What it holds |
|---|---|
| `ALifeAPI` | The wire format: `Message`, `Approval`, `Subagent`, `SessionEvent`, the request bodies, and `SessionState`, which turns a session's events into what a front end shows of that character; and the lot: `LotPlan` (its size, and the house and lawn in the middle), `LotArea`, and `Lot` with its `LotItem`s, everything built and planted, with `isFoals` for a bed of the Gardener's foals. The server uses this module too, so the two can't drift apart. |
| `ALifeClient` | What a front end uses. `ServerConnection` follows every session on a server: `connect()`, `setServerURL(_:)`, `startEverySessionOver()`, `phase`, `sessions`, one `AgentSession` per character, and `lot`, what's built and planted. An `AgentSession` is the observable handle on one character: `send(_:)`, `interrupt()`, `respond(to:allow:)`, `startOver()`, and the state to draw (`status`, `activity`, `transcript`, `conversation`, `pendingApprovals`, `isWaitingForYou`, `subagents`, `lastError`). `ALifeServerClient` makes the HTTP calls and reads the event streams. `Narrator` says the characters' new lines (an `AgentSession`'s `newMessages`) out loud through a `SpeechEngine`, while they are within `Earshot.distance` of you, and `SpokenText` turns a message's Markdown into what is said. |

### The server

[`a-life-server/`](a-life-server) is a separate Swift package (Vapor). Its README covers running it, Tailscale, the API, and how each character's Claude Code session and its helper are set up.

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
