# a*life

A minimal life-sim sandbox for iOS and macOS, built with SwiftUI and RealityKit. A little character walks around a 16×16 lot. Tap a tile and the character finds its way there with A* pathfinding, around the walls of a small house and some bushes.

On an iPhone or iPad you put the lot on any flat surface around you, seen through the camera: a table, the floor or a wall. It's about 50 cm across and stays in place while you walk around it. On the Mac and in the iOS Simulator it fills the window instead, with an orbit camera.

## Run it

Open `ALife.xcodeproj` in Xcode 16 or later, pick the **ALife** scheme, and run it on an iPhone/iPad simulator or **My Mac**. To put the lot on a real surface, run it on a real iPhone or iPad: set your team under *Signing & Capabilities* and allow camera access when asked.

Requires iOS 18 / macOS 15, the first releases where `RealityView` and entity-targeted gestures work outside visionOS.

| | iPhone / iPad | Mac, iOS Simulator |
|---|---|---|
| Place the lot | Aim the circle at a table, floor or wall, then tap | — |
| Move it | Tap **Move**, aim again, tap | — |
| Walk | Tap a tile | Click or tap a tile |
| Look around | Walk around it | Drag to orbit |
| Zoom | Move closer | Scroll wheel or pinch |

If camera access is turned off, the iPhone or iPad falls back to the window with the orbit camera.

## How it's put together

| File | What it does |
|---|---|
| `ALifeApp.swift` | App entry point. Registers the custom components and the walk system. |
| `Stage.swift` | Decides at launch whether the lot goes on a real surface (AR) or in a window, asking for camera access on iOS. |
| `SurfacePlacement.swift` | iOS only. Runs the ARKit session, moves a see-through lot onto the surface in the middle of the screen, and pins it there with an anchor on tap. Also wraps Apple's coaching overlay. |
| `WorldView.swift` | The `RealityView` for either stage, plus the gestures, the on-screen hints and the macOS scroll-wheel monitor. |
| `World.swift` | Builds the lot (tiles, walls, bushes, character, sun), turns a tapped tile into a walk, and sets the lot up for a window or a surface. |
| `CameraRig.swift` | Orbit camera for the window: a pivot entity that yaws and pitches, with a `PerspectiveCamera` on a boom. |
| `WalkSystem.swift` | ECS: `TileComponent`, `WalkComponent`, and a `System` that moves walkers along their waypoints every frame. |
| `TileGrid.swift` | Plain Swift with no RealityKit: the floor plan and A* (8-directional, no corner cutting). |

Every floor tile is its own entity with a `CollisionComponent` and an `InputTargetComponent`. A tap therefore hits the tile directly, so the code never has to turn a screen point into a world position. That works the same way in AR.

### On a real surface

`WorldView` sets `content.camera = .spatialTracking`. `SurfacePlacement` creates the `ARSession` and hands it to RealityKit with `SpatialTrackingSession.run(_:session:arConfiguration:)`, with horizontal and vertical plane detection. Owning the session lets it ask ARKit what's under the middle of the screen every frame: an `ARFrame.raycastQuery` against planes ARKit has already mapped, falling back to an estimated plane, which a LiDAR device finds almost at once.

The hit becomes the preview's pose. The lot's up is the surface's normal: up on a floor or table, out of a wall. On a floor or table its front edge faces you; on a wall its front edge is at the bottom, like a map hung on a wall. A tap adds an `ARAnchor` at that pose and moves the lot under an `AnchorEntity(anchor:)`. ARKit keeps refining where that anchor is, so the lot stays put while you walk around it.

The lot is scaled down to 0.5 m. The walk system works in the lot's own space, so walking needs no changes. While placing, the lot is see-through (`OpacityComponent`) and its tiles' `InputTargetComponent`s are disabled, so the placing tap can't also start a walk.

The orbit camera's `PerspectiveCamera` is left out of the tree in AR. With a camera entity under the anchor, RealityKit pins the content to the screen instead of the surface ([Apple Developer Forums](https://developer.apple.com/forums/thread/820385)).

## Ideas for next steps

- Swap `TileGrid` for RealityKit's navigation mesh (`NavigationMeshResource` / `NavigationComponent` / `NavigationController`, new at WWDC26) once you can raise the deployment target. `TileGrid.path` already returns the same thing `computePath` does: `nil` if there's no path, `[]` if you're already there.
- Replace the box character with a rigged USDZ that has walk and idle animations.
- Build mode: snap furniture to the grid and call `grid.block(_:)` for each piece.
- Keyboard camera controls on macOS with `.onKeyPress`.
- Drag to turn the lot on its surface, and pinch to resize it.
- On LiDAR devices, add `.occlusion` to the `SpatialTrackingSession` configuration so real objects (your hand, a mug) hide the lot behind them. It's left off for now: a lot lying flat on a surface can flicker against the scanned mesh of that surface.
