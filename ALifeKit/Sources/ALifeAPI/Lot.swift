import Foundation

/// A rectangle of tiles on the lot: `width` tiles along x from `x`, and
/// `depth` tiles along y from `y`. On a plan of the lot, x runs from left
/// to right and y from top to bottom.
public struct LotArea: Codable, Equatable, Hashable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var depth: Int

    public init(x: Int, y: Int, width: Int = 1, depth: Int = 1) {
        self.x = x
        self.y = y
        self.width = width
        self.depth = depth
    }

    /// The columns it covers.
    public var xs: Range<Int> { x..<(x + width) }
    /// The rows it covers.
    public var ys: Range<Int> { y..<(y + depth) }

    public func contains(x: Int, y: Int) -> Bool {
        xs.contains(x) && ys.contains(y)
    }

    /// Whether it shares a tile with `other`.
    public func overlaps(_ other: LotArea) -> Bool {
        xs.overlaps(other.xs) && ys.overlaps(other.ys)
    }

    /// Every tile it covers, as `(x, y)`, row by row.
    public var tiles: [(x: Int, y: Int)] {
        ys.flatMap { y in xs.map { x in (x: x, y: y) } }
    }
}

/// The lot's fixed layout, which the server and the front ends share: how
/// big it is, and the house the characters work in, with the lawn in front
/// of it where they wait. Nothing can be built or planted on `reserved`.
public enum LotPlan {
    /// Tiles along x.
    public static let width = 64
    /// Tiles along y.
    public static let depth = 64
    /// The most tiles a building or a bed can stretch along either side.
    public static let largestSide = 16

    /// The whole lot.
    public static let bounds = LotArea(x: 0, y: 0, width: width, depth: depth)

    /// The house's walls go round the edge of this, in the middle of the lot.
    public static let house = LotArea(x: 29, y: 26, width: 6, depth: 6)
    /// The gap in the house's front wall, the side towards larger y.
    public static let doorway: [(x: Int, y: Int)] = [(x: 31, y: 31), (x: 32, y: 31)]
    /// Where the characters wait in front of the house when they aren't working.
    public static let lawn = LotArea(x: 29, y: 33, width: 6, depth: 3)
    /// Two bushes either side of the path from the door to the lawn.
    public static let bushes: [(x: Int, y: Int)] = [(x: 29, y: 32), (x: 34, y: 32)]

    /// The house, the lawn and the bushes, with a path all the way round
    /// them, so the characters can always get in and out.
    public static let reserved = LotArea(x: 28, y: 25, width: 8, depth: 12)
}

/// Something on the lot: a building the Builder built, or a bed the
/// Gardener planted, such as a row of roses or an oak tree.
public struct LotItem: Codable, Identifiable, Equatable, Sendable {
    public enum Category: String, Codable, Sendable {
        case building, plant
        /// A value this version doesn't know.
        case unknown

        public init(from decoder: Decoder) throws {
            self = Category(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    /// The file on the lot it comes from, such as `buildings/restaurant.md`.
    public let id: String
    public let category: Category
    /// What it is, in lowercase, such as `restaurant`, `rose` or `oak`. A
    /// front end shows kinds it doesn't know as a plain building or plant.
    public let kind: String
    /// What it is called, such as `Luigi's`.
    public let name: String
    public let x: Int
    public let y: Int
    public let width: Int
    public let depth: Int
    /// Its colour as `#RRGGBB`, such as a rose's, if it was given one.
    public let color: String?

    public init(id: String, category: Category, kind: String, name: String, area: LotArea, color: String? = nil) {
        self.id = id
        self.category = category
        self.kind = kind
        self.name = name
        x = area.x
        y = area.y
        width = area.width
        depth = area.depth
        self.color = color
    }

    /// The tiles it covers.
    public var area: LotArea { LotArea(x: x, y: y, width: width, depth: depth) }
}

/// Everything on the lot that the characters have built and planted.
public struct Lot: Codable, Equatable, Sendable {
    /// Goes up by one each time something on the lot changes. It is 1 or
    /// more once the server has looked at the lot, and starts again when the
    /// server restarts.
    public var revision: Int
    public var items: [LotItem]
    /// What couldn't be put on the lot, and why, one line per file.
    public var problems: [String]

    public init(revision: Int = 0, items: [LotItem] = [], problems: [String] = []) {
        self.revision = revision
        self.items = items
        self.problems = problems
    }
}
