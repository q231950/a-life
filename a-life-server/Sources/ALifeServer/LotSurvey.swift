import ALifeAPI
import Foundation
import Yams

/// What the characters have built and planted, read from the lot's
/// directory. A building is a Markdown file in `buildings/`, and a bed of
/// plants one in `garden/`; it stands on the lot once its file starts with
/// a few lines of YAML that say what it is and where:
///
/// ```
/// ---
/// kind: restaurant
/// x: 38
/// y: 22
/// width: 5
/// depth: 4
/// ---
/// # Luigi's
/// ```
///
/// An empty file stands for nothing. Without a `width` and `depth`, a building takes 3 by 3 tiles and a plant
/// one. Plants can have a `color` too, and anything can have a `name`;
/// without one, the file's first heading names it. A bed whose kind is an
/// animal (see `LotItem.Animal`), such as a foal, a bear or a stegosaurus, has one
/// on each tile, and no more than `LotPlan.mostAnimals` of them.
enum LotSurvey {
    /// One file in `buildings/` or `garden/`.
    struct Entry: Equatable {
        /// Its path in the lot, such as `buildings/restaurant.md`.
        let id: String
        let category: LotItem.Category
        let text: String
        let modified: Date
    }

    /// The folders things are kept in, and what they hold.
    static let folders: [(name: String, category: LotItem.Category)] = [("buildings", .building), ("garden", .plant)]

    /// The name of the report the server keeps in the lot, for the helpers to read.
    static let reportName = "lot.md"

    /// The Markdown files in the lot's `buildings/` and `garden/`.
    static func entries(in directory: URL) -> [Entry] {
        let files = FileManager.default
        var entries: [Entry] = []
        for folder in folders {
            let url = directory.appendingPathComponent(folder.name)
            guard let names = try? files.contentsOfDirectory(atPath: url.path) else { continue }
            for name in names.sorted() where name.lowercased().hasSuffix(".md") {
                let file = url.appendingPathComponent(name)
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                let modified = (try? files.attributesOfItem(atPath: file.path)[.modificationDate] as? Date) ?? .distantPast
                entries.append(Entry(id: "\(folder.name)/\(name)", category: folder.category, text: text, modified: modified))
            }
        }
        return entries
    }

    /// What stands on the lot, and why the rest doesn't. Where two things
    /// would share a tile, the one that was there first stays.
    static func survey(_ entries: [Entry]) -> (items: [LotItem], problems: [String]) {
        var items: [LotItem] = []
        var problems: [String] = []
        let oldestFirst = entries.sorted { ($0.modified, $0.id) < ($1.modified, $1.id) }
        // An empty file is something pulled down or dug up.
        for entry in oldestFirst where !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do {
                let item = try item(from: entry)
                if let other = items.first(where: { $0.area.overlaps(item.area) }) {
                    throw Problem("it overlaps \(other.id), which is at \(describe(other.area)).")
                }
                items.append(item)
            } catch let problem as Problem {
                problems.append("\(entry.id): \(problem.description)")
            } catch {
                problems.append("\(entry.id): \(error)")
            }
        }
        return (items.sorted { $0.id < $1.id }, problems.sorted())
    }

    /// The building or bed `entry` describes, checked against the lot's
    /// edges and the house, but not against anything else on it.
    static func item(from entry: Entry) throws -> LotItem {
        guard let (yaml, body) = frontMatter(of: entry.text) else {
            throw Problem("it isn't on the lot: it doesn't start with the lines that say its kind and where it stands. See \(reportName).")
        }
        let fields: [String: Any]
        do {
            guard let loaded = try Yams.load(yaml: yaml) as? [String: Any] else {
                throw Problem("the lines at the top should be fields like kind: and x:.")
            }
            fields = loaded
        } catch let problem as Problem {
            throw problem
        } catch {
            throw Problem("the lines at the top aren't YAML: \(error)")
        }

        guard let kind = (fields["kind"] as? String)?.trimmingCharacters(in: .whitespaces).lowercased(), !kind.isEmpty else {
            throw Problem("it needs a kind, such as \(entry.category == .plant ? "rose or oak" : "restaurant or house").")
        }
        let x = try whole(fields["x"], "x", "the column of its left edge")
        let y = try whole(fields["y"], "y", "the row of its top edge")
        let side = entry.category == .building ? 3 : 1 // unless it says
        let width = try whole(fields["width"] ?? side, "width", "how many tiles it spans along x")
        let depth = try whole(fields["depth"] ?? side, "depth", "how many tiles it spans along y")
        let largest = 1...LotPlan.largestSide
        guard largest.contains(width), largest.contains(depth) else {
            throw Problem("its width and depth can each be 1 to \(LotPlan.largestSide), not \(width) by \(depth).")
        }

        let area = LotArea(x: x, y: y, width: width, depth: depth)
        let bounds = LotPlan.bounds
        guard bounds.xs.contains(area.xs.lowerBound), bounds.xs.contains(area.xs.upperBound - 1),
              bounds.ys.contains(area.ys.lowerBound), bounds.ys.contains(area.ys.upperBound - 1) else {
            throw Problem("at \(describe(area)) it runs off the lot, where x and y each go from 0 to \(LotPlan.width - 1).")
        }
        guard !area.overlaps(LotPlan.reserved) else {
            throw Problem("at \(describe(area)) it is on the house or the lawn in front of it, \(describe(LotPlan.reserved)), where nothing can go.")
        }

        if let animal = LotItem(id: entry.id, category: entry.category, kind: kind, name: "", area: area).animal,
           width * depth > LotPlan.mostAnimals {
            throw Problem("a bed of \(animal.plural) has a \(animal.name) on each tile, and can have at most \(LotPlan.mostAnimals) of them, not \(width * depth) (\(width) by \(depth)).")
        }

        let name = (fields["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? heading(in: body)
            ?? title(fromFile: entry.id)
        return LotItem(
            id: entry.id,
            category: entry.category,
            kind: kind,
            name: name,
            area: area,
            color: (fields["color"] ?? fields["colour"]).flatMap { color($0) }
        )
    }

    // MARK: The report

    /// `lot.md`: what is on the lot, what couldn't go on it, and a map of
    /// the tiles, so the helpers can find room for what they build next.
    static func report(_ lot: Lot) -> String {
        let symbols = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        // Swift's, not a character on the lot.
        typealias Letter = Swift.Character
        func symbol(_ index: Int) -> Letter { index < symbols.count ? symbols[index] : "*" }

        var text = """
            # The lot

            a-life-server keeps this file up to date from buildings/ and garden/. Don't edit it: change those instead.

            The lot is \(LotPlan.width) by \(LotPlan.depth) tiles. x is the column, from 0 on the left to \(LotPlan.width - 1) on the right, and y the row, from 0 at the top to \(LotPlan.depth - 1) at the bottom. The house the characters work in, and the lawn in front of it, take up \(describe(LotPlan.reserved)), and nothing can go there.

            A file in buildings/ or garden/ stands on the lot once it starts like this, with x and y its top left tile:

            ```
            ---
            kind: restaurant
            x: 38
            y: 22
            width: 5
            depth: 4
            ---
            ```

            Plants can have a color, such as red, too. Nothing can share a tile with anything else; where two things would, the one that was there first stays.

            ## Animals

            a*life draws these animals in garden/, each in a bed of its own kind with one on each tile, at most \(LotPlan.mostAnimals) to a bed, so the bed is as big as the number of animals. They are all in the bed's color if it has one, or each in a coat of its own. They play round their bed, and anyone can walk across it.


            """
        for animal in LotItem.Animal.allCases {
            text += "- kind: \(animal.kind). \(about(animal))\n"
        }
        text += "\n## On the lot\n\n"
        if lot.items.isEmpty {
            text += "Nothing yet.\n"
        }
        for (index, item) in lot.items.enumerated() {
            let color = item.color.map { ", \($0)" } ?? ""
            text += "- \(symbol(index)): \(item.name), a \(item.kind)\(color), at \(describe(item.area)), from \(item.id)\n"
        }
        if !lot.problems.isEmpty {
            text += "\n## Not on the lot\n\n"
            for problem in lot.problems {
                text += "- \(problem)\n"
            }
        }

        text += "\n## Map\n\n. is free, # is the house and its lawn, and each letter is one of the things above.\n\n```\n"
        var rows: [[Letter]] = Array(repeating: Array(repeating: ".", count: LotPlan.width), count: LotPlan.depth)
        for tile in LotPlan.reserved.tiles {
            rows[tile.y][tile.x] = "#"
        }
        for (index, item) in lot.items.enumerated() {
            for tile in item.area.tiles {
                rows[tile.y][tile.x] = symbol(index)
            }
        }
        let columns = 0..<LotPlan.width
        let tens = columns.map { $0.isMultiple(of: 10) ? String($0 / 10) : " " }
        let units = columns.map { String($0 % 10) }
        text += "   " + tens.joined() + "\n"
        text += "   " + units.joined() + "\n"
        for (y, row) in rows.enumerated() {
            let number = String(y)
            text += String(repeating: " ", count: 2 - number.count) + number + " " + String(row) + "\n"
        }
        text += "```\n"
        return text
    }

    /// What a bed of `animal` looks like on the lot, and the colours it
    /// comes in, for the report.
    static func about(_ animal: LotItem.Animal) -> String {
        switch animal {
        case .foal:
            "Baby horses, which graze, trot, frisk and lie down. Colors such as chestnut, bay, brown, black, grey, white, palomino or dun."
        case .bear:
            "Brown bears, which amble about, sniff around, rear up and lie down. Colors such as brown, black, cinnamon or golden."
        case .polarBear:
            "Polar bears, bigger than bears, which amble about, sniff around, rear up and lie down. White or cream."
        case .bird:
            "Small birds, which hop and peck about, flutter up, fly round the bed, hover and land again. Any color, such as red, blue, yellow, brown, black or white."
        case .unicorn:
            "Horses with a golden horn and a pastel mane, which graze, trot, rear and lie down. Colors such as white, cream, silver, grey, lilac or pink."
        case .pegasus:
            "Horses with wings, which walk, graze and buck, and fly up over the bed, hover and land again. Colors such as white, silver, grey, palomino or black."
        case .stegosaurus:
            "Dinosaurs with two rows of plates down their backs and spikes on their tails, which plod about, browse low and swing their tails. Colors such as olive, green, sand, rust or grey."
        case .diplodocus:
            "Big dinosaurs with very long necks and tails, which plod about, browse, rear up and lie down. Colors such as grey, olive, sand, slate or green."
        case .pterosaur:
            "Flying reptiles with a crest and leathery wings, which waddle and peck about, and fly up over the bed, hover and land again. Colors such as rust, sand, grey, brown or olive."
        case .triceratops:
            "Dinosaurs with a frill and three horns, which graze, trot, lower their horns and kick up their heels, and lie down. Colors such as sand, olive, brown, grey or rust."
        case .tyrannosaurus:
            "Dinosaurs that walk on two legs, with a big head and small arms, which stalk about, sniff around, roar and lie down. Colors such as green, olive, brown, grey or rust."
        }
    }

    // MARK: Reading a file

    /// What is wrong with a file, which keeps it off the lot.
    struct Problem: Error, CustomStringConvertible {
        let description: String

        init(_ description: String) {
            self.description = description
        }
    }

    /// The YAML between the `---` lines a file starts with, and the rest of it.
    static func frontMatter(of text: String) -> (yaml: String, body: String)? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasSuffix("\r") ? String($0.dropLast()) : String($0) }
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return nil }
        return (lines[1..<end].joined(separator: "\n"), lines[(end + 1)...].joined(separator: "\n"))
    }

    private static func whole(_ value: Any?, _ field: String, _ meaning: String) throws -> Int {
        if let number = value as? Int { return number }
        if let text = value as? String, let number = Int(text.trimmingCharacters(in: .whitespaces)) { return number }
        if value == nil {
            throw Problem("it needs \(field), \(meaning).")
        }
        throw Problem("\(field) should be a whole number, \(meaning), not \(value.map { "\($0)" } ?? "nothing").")
    }

    /// The first `# ` heading in `body`.
    private static func heading(in body: String) -> String? {
        body.split(separator: "\n")
            .first { $0.hasPrefix("# ") }
            .map { $0.dropFirst(2).trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    /// `garden/rose-bed.md` becomes `Rose bed`.
    private static func title(fromFile id: String) -> String {
        let name = ((id as NSString).lastPathComponent as NSString).deletingPathExtension
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// The colours a plant, or an animal's coat, can be given by name.
    static let colors: [String: String] = [
        "red": "#D7263D", "crimson": "#B0182E", "scarlet": "#E0301E",
        "pink": "#F28AB2", "rose": "#E8638B", "magenta": "#D1338F",
        "white": "#F7F4EC", "cream": "#F3E7C4",
        "yellow": "#F5D130", "gold": "#E8B923", "golden": "#E8B923",
        "orange": "#F28C28", "peach": "#F7B58B", "coral": "#F27B6B",
        "purple": "#8E4FC2", "violet": "#7F4FD6", "lilac": "#B79BE0", "lavender": "#A88AD8",
        "blue": "#3F6FD8", "sky blue": "#79B4F0",
        "green": "#4E9A3A", "brown": "#8A5A32", "black": "#2B2730",
        "grey": "#BDBAB4", "gray": "#BDBAB4",
        // Coats, for foals, bears, unicorns and pegasuses.
        "chestnut": "#8C4A23", "bay": "#52321F", "palomino": "#D9B26F", "dun": "#B89A6A",
        "cinnamon": "#9A5B2E", "silver": "#C8CCD2",
        // Hides, for dinosaurs and pterosaurs.
        "olive": "#6B7A3A", "sand": "#C9AE7C", "rust": "#A0522D", "slate": "#6E7B86",
    ]

    /// A colour given by name, such as `red`, or as `#RRGGBB`, as
    /// `#RRGGBB`. `nil` for anything else, which leaves it to the front end.
    static func color(_ value: Any) -> String? {
        guard let text = value as? String else { return nil }
        let name = text.trimmingCharacters(in: .whitespaces).lowercased()
        if let known = colors[name] { return known }
        let digits = name.hasPrefix("#") ? name.dropFirst() : Substring(name)
        guard digits.count == 6, UInt32(digits, radix: 16) != nil else { return nil }
        return "#" + digits.uppercased()
    }

    /// `x 3 to 7, y 10 to 12`, or `x 3, y 10` for a single tile.
    static func describe(_ area: LotArea) -> String {
        func span(_ range: Range<Int>) -> String {
            range.count == 1 ? "\(range.lowerBound)" : "\(range.lowerBound) to \(range.upperBound - 1)"
        }
        return "x \(span(area.xs)), y \(span(area.ys))"
    }
}
