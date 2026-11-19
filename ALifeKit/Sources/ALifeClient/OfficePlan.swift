import ALifeAPI

/// The office the characters work in, on the house's tiles in the middle of
/// the lot: a lobby on the ground floor, with the door at the front and a
/// lift at the back, and above it a storey for every two characters, each
/// with a room of its own on the left or the right. A character takes the
/// lift up to its room while it works, and sits at its desk by the front
/// window, where you can see it through the glass, with its helpers' sheep
/// round it.
///
/// Spots in the office are in tiles, as on a plan of the lot: x across and y
/// down, so that the middle of tile (31, 27) is at x 31, y 27, and the
/// house's front edge is at y 31.5. Heights are in metres.
public enum OfficePlan {
    /// A spot on the plan, in tiles; it needn't be the middle of one.
    public struct Spot: Equatable, Sendable {
        public var x: Float
        public var y: Float

        public init(x: Float, y: Float) {
            self.x = x
            self.y = y
        }
    }

    /// One character's room.
    public struct Room: Equatable, Sendable {
        /// The slot of the character it belongs to.
        public let slot: Int
        /// Which storey it is on: 1 for the first floor, over the lobby.
        public let storey: Int
        /// 0 for the room on the left, 1 for the one on the right.
        public let side: Int
        /// The tiles under it.
        public let area: LotArea
        /// The height of its floor above the grass.
        public let floor: Float

        /// Its walls' inner faces on the plan: from `minX` to `maxX` across,
        /// and from `minY` at the back to `maxY` at the front window.
        public var minX: Float { Float(area.x) - 0.5 }
        public var maxX: Float { Float(area.xs.upperBound) - 0.5 }
        public var minY: Float { Float(area.y) - 0.5 }
        public var maxY: Float { Float(area.ys.upperBound) - 0.5 }

        /// Where its character sits, facing the front window.
        public var desk: Spot {
            Spot(x: (minX + maxX) / 2, y: maxY - OfficePlan.deskSetBack)
        }

        /// Whether `spot` is inside it, at least `margin` from its walls.
        public func contains(_ spot: Spot, margin: Float = 0) -> Bool {
            spot.x >= minX + margin && spot.x <= maxX - margin && spot.y >= minY + margin && spot.y <= maxY - margin
        }
    }

    /// The house's tiles, which the office stands on.
    public static let footprint = LotPlan.house
    /// How tall each storey is, from floor to floor: room for a character,
    /// its name and the "!" over its head while it waits for you.
    public static let storeyHeight: Float = 1.75
    /// Rooms side by side on each storey.
    public static let roomsPerStorey = 2
    /// How far back from the front window a character sits.
    static let deskSetBack: Float = 0.9
    /// How close to a room's walls a helper's sheep stands, and to its
    /// character.
    static let sheepMargin: Float = 0.3
    static let sheepRoom: Float = 0.55

    /// The storeys for `rooms` rooms: the lobby, and as many floors of rooms
    /// over it as they need, one at least.
    public static func storeys(forRooms rooms: Int) -> Int {
        1 + max(1, (rooms + roomsPerStorey - 1) / roomsPerStorey)
    }

    /// How tall the office is with `rooms` rooms, up to its roof.
    public static func height(forRooms rooms: Int) -> Float {
        Float(storeys(forRooms: rooms)) * storeyHeight
    }

    /// The room for the character in `slot`: the first two on the first
    /// floor, left then right, the next two on the floor above, and so on.
    public static func room(forSlot slot: Int) -> Room {
        let slot = max(slot, 0)
        let storey = 1 + slot / roomsPerStorey
        let side = slot % roomsPerStorey
        let width = footprint.width / roomsPerStorey
        let area = LotArea(x: footprint.x + side * width, y: footprint.y, width: width, depth: footprint.depth)
        return Room(slot: slot, storey: storey, side: side, area: area, floor: Float(storey) * storeyHeight)
    }

    /// The rooms of an office with a room for each slot in `tints`, from
    /// slot 0 up to the highest, each with its character's tint (the colour
    /// of its shirt), or `nil` for a room nobody has at the moment.
    public static func rooms<Tint>(tintedBy tints: [Int: Tint]) -> [(room: Room, tint: Tint?)] {
        let count = (tints.keys.max() ?? -1) + 1
        return (0..<count).map { (room: room(forSlot: $0), tint: tints[$0]) }
    }

    /// The tile at the back of the lobby where the character in `slot`
    /// steps into the lift, and steps out again.
    public static func lift(forSlot slot: Int) -> (x: Int, y: Int) {
        let middle = footprint.x + footprint.width / 2
        return (x: middle - 1 + max(slot, 0) % 2, y: footprint.y + 1)
    }

    /// Where the `place`th of a character's helpers' sheep stands in its
    /// room: round the desk, nearest first, inside the walls and out of the
    /// character's way. Past the last free spot, they start again.
    public static func sheepSpot(in room: Room, place: Int) -> Spot {
        let spots = sheepSpots(in: room)
        guard !spots.isEmpty else { return room.desk }
        return spots[max(place, 0) % spots.count]
    }

    /// The spots for sheep in `room`, on a grid round the desk, nearest first.
    static func sheepSpots(in room: Room) -> [Spot] {
        let desk = room.desk
        func spot(_ step: (column: Int, row: Int)) -> Spot {
            Spot(x: desk.x + Float(step.column) * sheepRoom, y: desk.y + Float(step.row) * sheepRoom)
        }
        // Beside the character and behind it, but not on it, nor at the
        // desk between it and the window.
        let steps = (-12...0).flatMap { row in (-8...8).map { (column: $0, row: row) } }.filter {
            ($0.row < 0 || $0.column != 0) && room.contains(spot($0), margin: sheepMargin)
        }
        // Nearest first; of two as near, the one further forward, then the left.
        return steps.sorted {
            let a = $0.column * $0.column + $0.row * $0.row, b = $1.column * $1.column + $1.row * $1.row
            if a != b { return a < b }
            if $0.row != $1.row { return $0.row > $1.row }
            return $0.column < $1.column
        }.map(spot)
    }
}
