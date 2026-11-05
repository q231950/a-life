# a*life

A minimal life-sim sandbox for iOS and macOS, built with SwiftUI and RealityKit. A little character walks around a 16×16 lot. Tap a tile and the character finds its way there with A* pathfinding, around the walls of a small house and some bushes.

## Run it

Open `ALife.xcodeproj` in Xcode 16 or later, pick the **ALife** scheme, and run it on an iPhone/iPad simulator or **My Mac**. To run on a device, set your team under *Signing & Capabilities*.

Requires iOS 18 / macOS 15, the first releases where `RealityView` and entity-targeted gestures work outside visionOS.

| | iOS / iPadOS | macOS |
|---|---|---|
| Walk | Tap a tile | Click a tile |
| Orbit camera | Drag | Drag |
| Zoom | Pinch | Scroll wheel or trackpad pinch |

## How it's put together

| File | What it does |
|---|---|
| `ALifeApp.swift` | App entry point. Registers the custom components and the walk system. |
| `WorldView.swift` | The `RealityView`, plus the gestures and the macOS scroll-wheel monitor. |
| `World.swift` | Builds the lot (tiles, walls, bushes, character, sun) and turns a tapped tile into a walk. |
| `CameraRig.swift` | Orbit camera: a pivot entity that yaws and pitches, with a `PerspectiveCamera` on a boom. |
| `WalkSystem.swift` | ECS: `TileComponent`, `WalkComponent`, and a `System` that moves walkers along their waypoints every frame. |
| `TileGrid.swift` | Plain Swift with no RealityKit: the floor plan and A* (8-directional, no corner cutting). |

Every floor tile is its own entity with a `CollisionComponent` and an `InputTargetComponent`. A tap therefore hits the tile directly, so the code never has to turn a screen point into a world position.

## Ideas for next steps

- Swap `TileGrid` for RealityKit's navigation mesh (`NavigationMeshResource` / `NavigationComponent` / `NavigationController`, new at WWDC26) once you can raise the deployment target. `TileGrid.path` already returns the same thing `computePath` does: `nil` if there's no path, `[]` if you're already there.
- Replace the box character with a rigged USDZ that has walk and idle animations.
- Build mode: snap furniture to the grid and call `grid.block(_:)` for each piece.
- Keyboard camera controls on macOS with `.onKeyPress`.
