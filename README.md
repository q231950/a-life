# a*life

A minimal life-sim sandbox for iOS and macOS, built with SwiftUI and RealityKit. A little character walks around a 16×16 lot. Tap a tile and the character finds its way there with A* pathfinding, around the walls of a small house and some bushes.

On an iPhone or iPad the lot sits on your real table, about 50 cm across, seen through the camera. It stays in place while you walk around it. On the Mac and in the iOS Simulator it fills the window instead, with an orbit camera.

## Run it

Open `ALife.xcodeproj` in Xcode 16 or later, pick the **ALife** scheme, and run it on an iPhone/iPad simulator or **My Mac**. To see the lot on a table, run it on a real iPhone or iPad: set your team under *Signing & Capabilities* and allow camera access when asked.

Requires iOS 18 / macOS 15, the first releases where `RealityView` and entity-targeted gestures work outside visionOS.

| | iPhone / iPad | Mac, iOS Simulator |
|---|---|---|
| Place the lot | Point the camera at a table and move it slowly | — |
| Walk | Tap a tile | Click or tap a tile |
| Look around | Walk around the table | Drag to orbit |
| Zoom | Move closer | Scroll wheel or pinch |

If camera access is turned off, the iPhone or iPad falls back to the window with the orbit camera.

## How it's put together

| File | What it does |
|---|---|
| `ALifeApp.swift` | App entry point. Registers the custom components and the walk system. |
| `Stage.swift` | Decides at launch whether the lot goes on a table (AR) or in a window, asking for camera access on iOS. |
| `WorldView.swift` | The `RealityView` for either stage, plus the gestures and the macOS scroll-wheel monitor. |
| `World.swift` | Builds the lot (tiles, walls, bushes, character, sun), turns a tapped tile into a walk, and sets the lot up for a window or a table. |
| `CameraRig.swift` | Orbit camera for the window: a pivot entity that yaws and pitches, with a `PerspectiveCamera` on a boom. |
| `WalkSystem.swift` | ECS: `TileComponent`, `WalkComponent`, and a `System` that moves walkers along their waypoints every frame. |
| `TileGrid.swift` | Plain Swift with no RealityKit: the floor plan and A* (8-directional, no corner cutting). |

Every floor tile is its own entity with a `CollisionComponent` and an `InputTargetComponent`. A tap therefore hits the tile directly, so the code never has to turn a screen point into a world position. That works the same way in AR.

### On a table

`WorldView` sets `content.camera = .spatialTracking`, and `World.contentForTable()` puts the lot under an `AnchorEntity(.plane(.horizontal, classification: .table, …))`. RealityKit runs its default AR session, finds a table and keeps the anchor fixed there. The lot is scaled down to 0.5 m. The walk system works in the lot's own space, so walking needs no changes.

The orbit camera's `PerspectiveCamera` is left out of the tree in AR. With a camera entity under the anchor, RealityKit pins the content to the screen instead of the table ([Apple Developer Forums](https://developer.apple.com/forums/thread/820385)).

## Ideas for next steps

- Swap `TileGrid` for RealityKit's navigation mesh (`NavigationMeshResource` / `NavigationComponent` / `NavigationController`, new at WWDC26) once you can raise the deployment target. `TileGrid.path` already returns the same thing `computePath` does: `nil` if there's no path, `[]` if you're already there.
- Replace the box character with a rigged USDZ that has walk and idle animations.
- Build mode: snap furniture to the grid and call `grid.block(_:)` for each piece.
- Keyboard camera controls on macOS with `.onKeyPress`.
- Let the player pick the spot on the table. Right now the lot lands on the first table RealityKit finds. Tapping a point on the real surface needs an ARKit raycast (`ARView.raycast(from:allowing:alignment:)` → `AnchorEntity(raycastResult:)`).
- Drag to rotate or slide the lot on the table, and pinch to resize it.
