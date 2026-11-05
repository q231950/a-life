/// A cell on the world's floor plan.
struct Tile: Hashable, Sendable {
    var x: Int
    var z: Int
}

/// The walkable floor plan of the world and A* pathfinding over it.
///
/// Pure Swift on purpose: no RealityKit in here, so it can be unit tested
/// and later swapped for RealityKit's navigation mesh without touching it.
struct TileGrid: Sendable {
    let width: Int
    let depth: Int
    private(set) var blocked: Set<Tile> = []

    init(width: Int, depth: Int) {
        self.width = width
        self.depth = depth
    }

    var allTiles: [Tile] {
        (0..<depth).flatMap { z in (0..<width).map { x in Tile(x: x, z: z) } }
    }

    func contains(_ tile: Tile) -> Bool {
        (0..<width).contains(tile.x) && (0..<depth).contains(tile.z)
    }

    func isWalkable(_ tile: Tile) -> Bool {
        contains(tile) && !blocked.contains(tile)
    }

    mutating func block(_ tile: Tile) {
        blocked.insert(tile)
    }

    /// Up to eight neighbours with their step cost. A diagonal step is only
    /// allowed when both straight tiles next to it are free, so nobody cuts
    /// a corner through a wall.
    func neighbours(of tile: Tile) -> [(tile: Tile, cost: Double)] {
        var result: [(tile: Tile, cost: Double)] = []
        for dz in -1...1 {
            for dx in -1...1 where dx != 0 || dz != 0 {
                let next = Tile(x: tile.x + dx, z: tile.z + dz)
                guard isWalkable(next) else { continue }
                if dx != 0 && dz != 0 {
                    guard isWalkable(Tile(x: tile.x + dx, z: tile.z)),
                          isWalkable(Tile(x: tile.x, z: tile.z + dz)) else { continue }
                    result.append((tile: next, cost: 2.0.squareRoot()))
                } else {
                    result.append((tile: next, cost: 1.0))
                }
            }
        }
        return result
    }

    /// A* from `start` to `goal`.
    ///
    /// - Returns: The tiles to walk through, excluding `start` and including
    ///   `goal`. `nil` if the goal can't be reached, an empty array if
    ///   `start == goal` (the same contract as RealityKit's `computePath`).
    func path(from start: Tile, to goal: Tile) -> [Tile]? {
        guard isWalkable(goal) else { return nil }
        if start == goal { return [] }

        var open: Set<Tile> = [start]
        var cameFrom: [Tile: Tile] = [:]
        var costSoFar: [Tile: Double] = [start: 0]
        var estimate: [Tile: Double] = [start: heuristic(start, goal)]

        while let current = open.min(by: { estimate[$0, default: .infinity] < estimate[$1, default: .infinity] }) {
            if current == goal {
                return reconstruct(cameFrom, to: goal)
            }
            open.remove(current)

            for (next, stepCost) in neighbours(of: current) {
                let cost = costSoFar[current, default: .infinity] + stepCost
                if cost < costSoFar[next, default: .infinity] {
                    cameFrom[next] = current
                    costSoFar[next] = cost
                    estimate[next] = cost + heuristic(next, goal)
                    open.insert(next)
                }
            }
        }
        return nil
    }

    /// Octile distance: exact for an empty 8-connected grid, so A* stays optimal.
    private func heuristic(_ a: Tile, _ b: Tile) -> Double {
        let dx = Double(abs(a.x - b.x))
        let dz = Double(abs(a.z - b.z))
        return max(dx, dz) + (2.0.squareRoot() - 1) * min(dx, dz)
    }

    private func reconstruct(_ cameFrom: [Tile: Tile], to goal: Tile) -> [Tile] {
        var path = [goal]
        var current = goal
        while let previous = cameFrom[current], cameFrom[previous] != nil {
            path.append(previous)
            current = previous
        }
        return path.reversed()
    }
}
