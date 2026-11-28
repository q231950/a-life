import ALifeClient
import SwiftUI

/// What the Builder or the Conservationist can make, in a row above the
/// message field that scrolls sideways: a little picture of each kind the
/// lot draws its own way, with its name under it. Tapping one starts a
/// request for it in the field, such as "Build a barn", to finish or send.
struct LotSuggestionRow: View {
    let suggestions: [LotSuggestion]
    let pick: (LotSuggestion) -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 6) {
                ForEach(suggestions) { suggestion in
                    Button {
                        pick(suggestion)
                    } label: {
                        VStack(spacing: 2) {
                            KindPicture(thing: suggestion.thing)
                                .frame(width: 48, height: 40)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            Text(suggestion.title)
                                .font(.caption2)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .frame(width: 60)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(suggestion.request)
                    .accessibilityLabel(suggestion.title)
                    .accessibilityHint("Starts the message \u{201C}\(suggestion.request)\u{201D}")
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
        .frame(height: 62)
        .opacity(isEnabled ? 1 : 0.4)
    }
}

/// A little picture of a kind of building, plant or animal, as the lot
/// draws it: in the colours `Buildings`, `Plants` and `Animals` give it, in
/// front of a patch of sky and grass.
struct KindPicture: View {
    let thing: LotSuggestion.Thing

    var body: some View {
        let look = Look(thing)
        Canvas { context, size in
            let sketch = Sketch(context: context, size: size)
            sketch.rect(0, 0, 1, 1, Color(red: 0.74, green: 0.86, blue: 0.97))
            sketch.rect(0, 0.88, 1, 0.12, Color(red: 0.45, green: 0.72, blue: 0.32))
            switch look {
            case .building(let style): Draw.building(style, on: sketch)
            case .plant(let shape): Draw.plant(shape, on: sketch)
            case .animal(let animal, let coat): Draw.animal(animal, coat: Color(platform: coat), on: sketch)
            }
        }
        .accessibilityHidden(true)
    }

    /// What to draw: the same style, shape or coat the lot uses.
    private enum Look {
        case building(Buildings.Style)
        case plant(Plants.Shape)
        case animal(LotItem.Animal, coat: PlatformColor)

        @MainActor
        init(_ thing: LotSuggestion.Thing) {
            switch thing {
            case .building(let building): self = .building(Buildings.Style(building))
            case .plant(let plant): self = .plant(Plants.Shape(plant))
            case .animal(let animal): self = .animal(animal, coat: Animals.coats(of: animal).first ?? .gray)
            }
        }
    }
}

private extension Color {
    init(platform color: PlatformColor) {
        #if os(macOS)
        self.init(nsColor: color)
        #else
        self.init(uiColor: color)
        #endif
    }
}

/// Draws on a canvas in fractions of its width and height, from its top
/// left corner.
private struct Sketch {
    let context: GraphicsContext
    let size: CGSize

    func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: x * size.width, y: y * size.height)
    }

    func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ color: Color, corner: CGFloat = 0) {
        let box = CGRect(x: x * size.width, y: y * size.height, width: width * size.width, height: height * size.height)
        context.fill(Path(roundedRect: box, cornerRadius: corner * size.width), with: .color(color))
    }

    /// An oval round `x`, `y`.
    func oval(_ x: CGFloat, _ y: CGFloat, _ radiusX: CGFloat, _ radiusY: CGFloat, _ color: Color) {
        let box = CGRect(x: (x - radiusX) * size.width, y: (y - radiusY) * size.height, width: radiusX * 2 * size.width, height: radiusY * 2 * size.height)
        context.fill(Path(ellipseIn: box), with: .color(color))
    }

    func shape(_ points: [(CGFloat, CGFloat)], _ color: Color) {
        var path = Path()
        path.addLines(points.map { at($0.0, $0.1) })
        path.closeSubpath()
        context.fill(path, with: .color(color))
    }

    func line(_ points: [(CGFloat, CGFloat)], _ color: Color, width: CGFloat) {
        var path = Path()
        path.addLines(points.map { at($0.0, $0.1) })
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width * size.width, lineCap: .round, lineJoin: .round))
    }
}

/// The pictures themselves, each standing on the grass at the bottom.
private enum Draw {
    static let ground: CGFloat = 0.88
    /// Laid over a part to put it in shade, such as an animal's far legs.
    static let shade = Color.black.opacity(0.22)
    static let leaf = Color(red: 0.3, green: 0.6, blue: 0.25)
    static let stem = Color(red: 0.25, green: 0.5, blue: 0.2)
    static let soil = Color(red: 0.42, green: 0.3, blue: 0.2)
    static let glass = Color(red: 0.55, green: 0.75, blue: 0.9)

    // MARK: Buildings

    static func building(_ style: Buildings.Style, on s: Sketch) {
        if style.isWindTurbine {
            windTurbine(on: s)
            return
        }
        let tall = CGFloat(min(style.height, 5))
        let height = 0.2 + 0.42 * (tall - 0.8) / 4.2
        let width: CGFloat = style.height >= 2.5 ? 0.44 : 0.64
        let left = 0.5 - width / 2
        let top = ground - height
        let walls = Color(platform: style.walls)

        if style.hasChimney {
            s.rect(left + width * 0.68, top - 0.2, 0.08, 0.2, Color(red: 0.55, green: 0.3, blue: 0.25))
        }
        s.rect(left, top, width, height, walls)

        if style.hasWindowBands {
            var y = ground - 0.12
            while y > top + 0.04 {
                s.rect(left, y, width, 0.035, glass)
                y -= 0.08
            }
        } else if !style.isBarn {
            for x in [left + width * 0.12, left + width * 0.88 - 0.1] {
                s.rect(x, top + height * 0.3, 0.1, 0.09, glass)
            }
        }

        switch style.roof {
        case .flat(let color):
            s.rect(left - 0.02, top - 0.035, width + 0.04, 0.035, Color(platform: color))
        case .pitched(let color):
            s.shape([(left - 0.04, top + 0.005), (0.5, top - 0.2), (left + width + 0.04, top + 0.005)], Color(platform: color))
        }

        if style.hasSpire {
            s.rect(0.42, top - 0.12, 0.16, ground - top + 0.12, walls)
            s.shape([(0.41, top - 0.12), (0.5, top - 0.36), (0.59, top - 0.12)], Color(red: 0.35, green: 0.37, blue: 0.43))
        }

        let doorHeight = min(0.2, height * 0.55)
        if style.isBarn {
            // Big braced doors.
            let doorWidth = width * 0.4
            let doorTop = ground - height * 0.62
            let x = 0.5 - doorWidth / 2
            s.rect(x, doorTop, doorWidth, ground - doorTop, Color(red: 0.55, green: 0.12, blue: 0.1))
            s.line([(x, doorTop), (x + doorWidth, doorTop), (x + doorWidth, ground), (x, ground), (x, doorTop)], .white, width: 0.025)
            s.line([(x, doorTop), (x + doorWidth, ground)], .white, width: 0.025)
            s.line([(x, ground), (x + doorWidth, doorTop)], .white, width: 0.025)
        } else {
            s.rect(0.44, ground - doorHeight, 0.12, doorHeight, Color(platform: style.door))
        }

        if let awning = style.awning {
            let stripes = 7
            let stripe = (width + 0.04) / CGFloat(stripes)
            for index in 0..<stripes {
                let color = index.isMultiple(of: 2) ? Color(platform: awning) : Color(white: 0.97)
                s.rect(left - 0.02 + stripe * CGFloat(index), ground - doorHeight - 0.07, stripe, 0.06, color)
            }
        }
        if style.hasRedCross {
            let red = Color(red: 0.85, green: 0.12, blue: 0.15)
            s.rect(0.44, top + 0.06, 0.12, 0.04, red)
            s.rect(0.48, top + 0.02, 0.04, 0.12, red)
        }
    }

    /// A slender white tower with three blades and a red light on top.
    static func windTurbine(on s: Sketch) {
        let white = Color(white: 0.97)
        let edge = Color(white: 0.62)
        s.shape([(0.47, ground), (0.49, 0.32), (0.51, 0.32), (0.53, ground)], white)
        s.rect(0.45, 0.27, 0.12, 0.06, white, corner: 0.02)
        let hub = (x: CGFloat(0.5), y: CGFloat(0.3))
        for index in 0..<3 {
            let angle = -CGFloat.pi / 2 + CGFloat(index) * 2 * .pi / 3
            let tip = (hub.x + cos(angle) * 0.27, hub.y + sin(angle) * 0.27)
            s.line([(hub.x, hub.y), tip], edge, width: 0.055)
            s.line([(hub.x, hub.y), tip], white, width: 0.035)
        }
        s.oval(hub.x, hub.y, 0.04, 0.04, edge)
        s.oval(hub.x, hub.y, 0.03, 0.03, white)
        s.oval(0.55, 0.26, 0.02, 0.02, Color(red: 1, green: 0.1, blue: 0.1))
    }

    // MARK: Plants

    static func plant(_ shape: Plants.Shape, on s: Sketch) {
        switch shape {
        case .flower(let usual, let flower):
            s.rect(0.08, 0.84, 0.84, 0.08, soil, corner: 0.02)
            let bloom = Color(platform: usual)
            if flower == .tall {
                s.line([(0.5, 0.86), (0.5, 0.3)], stem, width: 0.04)
                s.oval(0.4, 0.62, 0.08, 0.04, leaf)
                s.oval(0.5, 0.28, 0.17, 0.17, bloom)
                s.oval(0.5, 0.28, 0.07, 0.07, Color(red: 0.4, green: 0.25, blue: 0.1))
                return
            }
            let spots: [(CGFloat, CGFloat)] = [(0.28, 0.5), (0.5, 0.42), (0.72, 0.52)]
            for (x, y) in spots {
                s.line([(x, 0.86), (x, y)], stem, width: 0.03)
                switch flower {
                case .spike:
                    s.rect(x - 0.045, y - 0.2, 0.09, 0.24, bloom, corner: 0.04)
                case .daisy:
                    s.oval(x, y, 0.1, 0.06, bloom)
                    s.oval(x, y, 0.035, 0.035, Color(red: 0.98, green: 0.8, blue: 0.1))
                case .cup:
                    s.rect(x - 0.06, y - 0.1, 0.12, 0.13, bloom, corner: 0.05)
                case .round, .tall:
                    s.oval(x + 0.05, y + 0.18, 0.05, 0.03, leaf)
                    s.oval(x, y, 0.08, 0.08, bloom)
                }
            }

        case .tree(let crown, let trunk, let fruit):
            s.rect(0.45, 0.5, 0.1, 0.38, Color(platform: trunk))
            let green = Color(platform: crown)
            s.oval(0.5, 0.34, 0.26, 0.24, green)
            s.oval(0.68, 0.46, 0.17, 0.15, green)
            s.oval(0.32, 0.44, 0.17, 0.15, green)
            if let fruit {
                let spots: [(CGFloat, CGFloat)] = [(0.34, 0.42), (0.55, 0.28), (0.68, 0.5), (0.46, 0.5), (0.64, 0.36)]
                for (x, y) in spots {
                    s.oval(x, y, 0.035, 0.035, Color(platform: fruit))
                }
            }

        case .conifer:
            s.rect(0.46, 0.72, 0.08, 0.16, Color(red: 0.4, green: 0.27, blue: 0.18))
            let green = Color(red: 0.13, green: 0.38, blue: 0.22)
            s.shape([(0.22, 0.76), (0.5, 0.46), (0.78, 0.76)], green)
            s.shape([(0.28, 0.58), (0.5, 0.3), (0.72, 0.58)], green)
            s.shape([(0.34, 0.4), (0.5, 0.1), (0.66, 0.4)], green)

        case .palm:
            s.line([(0.44, ground), (0.5, 0.6), (0.56, 0.3)], Color(red: 0.6, green: 0.45, blue: 0.3), width: 0.06)
            let fronds = Color(red: 0.25, green: 0.62, blue: 0.25)
            let tips: [(CGFloat, CGFloat)] = [(0.22, 0.42), (0.32, 0.2), (0.58, 0.1), (0.84, 0.2), (0.9, 0.42), (0.7, 0.46)]
            for (x, y) in tips {
                s.line([(0.56, 0.28), ((0.56 + x) / 2, min(0.28, y) - 0.05), (x, y)], fronds, width: 0.05)
            }
            s.oval(0.55, 0.32, 0.03, 0.03, Color(red: 0.45, green: 0.3, blue: 0.15))
            s.oval(0.6, 0.33, 0.03, 0.03, Color(red: 0.45, green: 0.3, blue: 0.15))

        case .bush(let berries):
            let green = Color(red: 0.2, green: 0.5, blue: 0.25)
            s.oval(0.44, 0.64, 0.28, 0.24, green)
            s.oval(0.66, 0.72, 0.2, 0.16, green)
            if let berries {
                let spots: [(CGFloat, CGFloat)] = [(0.3, 0.58), (0.46, 0.5), (0.6, 0.62), (0.72, 0.72), (0.4, 0.72)]
                for (x, y) in spots {
                    s.oval(x, y, 0.035, 0.035, Color(platform: berries))
                }
            }

        case .hedge:
            s.rect(0.1, 0.5, 0.8, 0.38, Color(red: 0.16, green: 0.4, blue: 0.2), corner: 0.08)

        case .grass:
            let blades = Color(red: 0.38, green: 0.7, blue: 0.24)
            for index in 0..<9 {
                let x = 0.1 + CGFloat(index) * 0.1
                let tip: CGFloat = index.isMultiple(of: 2) ? 0.56 : 0.66
                s.shape([(x - 0.035, ground), (x + 0.02, tip), (x + 0.035, ground)], blades)
            }

        case .vegetable(let vegetable):
            s.rect(0.08, 0.84, 0.84, 0.08, soil, corner: 0.02)
            for x: CGFloat in [0.3, 0.7] {
                switch vegetable {
                case .carrot:
                    s.line([(x, 0.82), (x - 0.05, 0.6)], leaf, width: 0.03)
                    s.line([(x, 0.82), (x + 0.05, 0.6)], leaf, width: 0.03)
                    s.oval(x, 0.84, 0.06, 0.035, Color(red: 0.95, green: 0.5, blue: 0.1))
                case .lettuce:
                    s.oval(x, 0.74, 0.14, 0.11, Color(red: 0.55, green: 0.85, blue: 0.35))
                    s.oval(x, 0.72, 0.07, 0.06, Color(red: 0.7, green: 0.92, blue: 0.5))
                case .cabbage:
                    s.oval(x, 0.72, 0.15, 0.13, Color(red: 0.45, green: 0.65, blue: 0.5))
                    s.oval(x, 0.68, 0.08, 0.07, Color(red: 0.6, green: 0.78, blue: 0.6))
                case .tomato:
                    s.line([(x, 0.86), (x, 0.3)], Color(red: 0.55, green: 0.42, blue: 0.28), width: 0.025)
                    s.oval(x, 0.52, 0.1, 0.15, leaf)
                    let spots: [(CGFloat, CGFloat)] = [(x - 0.06, 0.62), (x + 0.06, 0.5), (x, 0.4)]
                    for (dx, dy) in spots {
                        s.oval(dx, dy, 0.04, 0.04, Color(red: 0.9, green: 0.15, blue: 0.1))
                    }
                case .pumpkin:
                    s.oval(x, 0.75, 0.16, 0.1, Color(red: 0.95, green: 0.55, blue: 0.1))
                    s.rect(x - 0.015, 0.6, 0.03, 0.06, stem)
                case .potato:
                    s.rect(x - 0.13, 0.72, 0.26, 0.13, Color(red: 0.35, green: 0.62, blue: 0.3), corner: 0.05)
                case .other:
                    s.rect(x - 0.1, 0.7, 0.2, 0.15, leaf, corner: 0.06)
                }
            }

        case .plant:
            s.line([(0.5, ground), (0.5, 0.5)], stem, width: 0.04)
            s.oval(0.5, 0.48, 0.16, 0.14, leaf)
        }
    }

    // MARK: Animals

    /// One of the animals, side on and facing right.
    static func animal(_ animal: LotItem.Animal, coat: Color, on s: Sketch) {
        switch animal {
        case .foal:
            horse(coat, mane: Color(red: 0.22, green: 0.15, blue: 0.1), on: s)
        case .unicorn:
            horse(coat, mane: Color(red: 0.95, green: 0.62, blue: 0.82), on: s)
            s.shape([(0.71, 0.21), (0.8, 0.03), (0.76, 0.22)], Color(red: 0.95, green: 0.78, blue: 0.3))
        case .pegasus:
            horse(coat, mane: Color(white: 0.85), wing: true, on: s)
        case .bear:
            bear(coat, polar: false, on: s)
        case .polarBear:
            bear(coat, polar: true, on: s)
        case .bird:
            bird(coat, on: s)
        case .stegosaurus:
            stegosaurus(coat, on: s)
        case .diplodocus:
            diplodocus(coat, on: s)
        case .pterosaur:
            pterosaur(coat, on: s)
        case .triceratops:
            triceratops(coat, on: s)
        case .tyrannosaurus:
            tyrannosaurus(coat, on: s)
        }
    }

    /// Four legs, the far two in shade.
    static func legs(_ coat: Color, far: [CGFloat], near: [CGFloat], top: CGFloat, width: CGFloat, on s: Sketch) {
        for x in far {
            s.rect(x, top, width, ground - top, coat, corner: 0.02)
            s.rect(x, top, width, ground - top, shade, corner: 0.02)
        }
        for x in near {
            s.rect(x, top, width, ground - top, coat, corner: 0.02)
        }
    }

    static func eye(_ x: CGFloat, _ y: CGFloat, on s: Sketch) {
        s.oval(x, y, 0.018, 0.018, .black)
    }

    /// A foal, a unicorn or a pegasus.
    static func horse(_ coat: Color, mane: Color, wing: Bool = false, on s: Sketch) {
        s.line([(0.27, 0.48), (0.18, 0.6), (0.2, 0.74)], mane, width: 0.05)
        legs(coat, far: [0.34, 0.62], near: [0.27, 0.56], top: 0.54, width: 0.06, on: s)
        s.oval(0.47, 0.5, 0.22, 0.11, coat)
        s.shape([(0.58, 0.5), (0.66, 0.24), (0.77, 0.26), (0.7, 0.54)], coat)
        s.shape([(0.67, 0.2), (0.76, 0.19), (0.93, 0.33), (0.89, 0.39), (0.7, 0.33)], coat)
        s.shape([(0.69, 0.22), (0.7, 0.13), (0.74, 0.2)], coat)
        s.line([(0.6, 0.47), (0.67, 0.22)], mane, width: 0.035)
        eye(0.76, 0.27, on: s)
        if wing {
            let feathers = Color(white: 0.98)
            s.shape([(0.38, 0.46), (0.24, 0.14), (0.46, 0.06), (0.56, 0.44)], feathers)
            s.line([(0.38, 0.46), (0.24, 0.14), (0.46, 0.06), (0.56, 0.44)], Color.black.opacity(0.18), width: 0.015)
            s.line([(0.42, 0.36), (0.36, 0.18)], Color.black.opacity(0.12), width: 0.012)
            s.line([(0.48, 0.36), (0.46, 0.14)], Color.black.opacity(0.12), width: 0.012)
        }
    }

    /// A bear, or a polar bear with a longer neck.
    static func bear(_ coat: Color, polar: Bool, on s: Sketch) {
        legs(coat, far: [0.32, 0.6], near: [0.22, 0.52], top: 0.62, width: 0.1, on: s)
        s.oval(0.46, 0.6, 0.28, 0.17, coat)
        s.oval(0.36, 0.5, 0.13, 0.09, coat)
        let head: (x: CGFloat, y: CGFloat) = polar ? (x: 0.8, y: 0.52) : (x: 0.76, y: 0.48)
        if polar {
            s.oval(0.7, 0.54, 0.1, 0.09, coat)
        }
        s.oval(head.x - 0.06, head.y - 0.09, 0.035, 0.035, coat)
        s.oval(head.x, head.y, 0.12, 0.1, coat)
        let muzzle = polar ? Color(white: 0.86) : Color(red: 0.76, green: 0.6, blue: 0.45)
        s.oval(head.x + 0.09, head.y + 0.03, 0.055, 0.045, muzzle)
        s.oval(head.x + 0.135, head.y + 0.02, 0.018, 0.018, .black)
        eye(head.x + 0.02, head.y - 0.03, on: s)
    }

    static func bird(_ feathers: Color, on s: Sketch) {
        let orange = Color(red: 0.95, green: 0.6, blue: 0.15)
        s.line([(0.46, 0.68), (0.44, 0.86)], orange, width: 0.02)
        s.line([(0.54, 0.68), (0.56, 0.86)], orange, width: 0.02)
        s.shape([(0.34, 0.58), (0.14, 0.44), (0.2, 0.62)], feathers)
        s.oval(0.48, 0.6, 0.18, 0.13, feathers)
        s.oval(0.66, 0.44, 0.1, 0.1, feathers)
        s.shape([(0.74, 0.41), (0.87, 0.46), (0.74, 0.49)], orange)
        s.oval(0.44, 0.58, 0.12, 0.07, shade)
        eye(0.68, 0.42, on: s)
    }

    static func stegosaurus(_ hide: Color, on s: Sketch) {
        let plates = Color(red: 0.82, green: 0.48, blue: 0.25)
        let backs: [(CGFloat, CGFloat)] = [(0.28, 0.1), (0.38, 0.15), (0.49, 0.17), (0.6, 0.13)]
        for (x, height) in backs {
            s.shape([(x - 0.05, 0.5), (x, 0.46 - height), (x + 0.05, 0.5)], plates)
        }
        s.shape([(0.28, 0.54), (0.04, 0.68), (0.3, 0.66)], hide)
        s.line([(0.09, 0.65), (0.05, 0.56)], Color(white: 0.92), width: 0.02)
        s.line([(0.14, 0.63), (0.12, 0.54)], Color(white: 0.92), width: 0.02)
        legs(hide, far: [0.32, 0.58], near: [0.26, 0.52], top: 0.62, width: 0.08, on: s)
        s.oval(0.46, 0.6, 0.24, 0.14, hide)
        s.shape([(0.66, 0.56), (0.8, 0.62), (0.78, 0.71), (0.64, 0.68)], hide)
        s.oval(0.82, 0.67, 0.08, 0.05, hide)
        eye(0.83, 0.65, on: s)
    }

    static func diplodocus(_ hide: Color, on s: Sketch) {
        s.line([(0.32, 0.58), (0.16, 0.62), (0.03, 0.72)], hide, width: 0.06)
        legs(hide, far: [0.34, 0.52], near: [0.28, 0.46], top: 0.62, width: 0.07, on: s)
        s.oval(0.42, 0.6, 0.18, 0.12, hide)
        s.line([(0.54, 0.56), (0.68, 0.4), (0.78, 0.18)], hide, width: 0.07)
        s.oval(0.83, 0.16, 0.07, 0.045, hide)
        eye(0.84, 0.14, on: s)
    }

    /// Flying, over the grass.
    static func pterosaur(_ hide: Color, on s: Sketch) {
        s.shape([(0.46, 0.5), (0.2, 0.16), (0.34, 0.5)], hide)
        s.shape([(0.46, 0.5), (0.2, 0.16), (0.34, 0.5)], shade)
        s.shape([(0.52, 0.5), (0.08, 0.36), (0.3, 0.56)], hide)
        s.oval(0.5, 0.5, 0.13, 0.05, hide)
        s.shape([(0.62, 0.43), (0.48, 0.3), (0.6, 0.46)], hide)
        s.oval(0.65, 0.45, 0.05, 0.04, hide)
        s.shape([(0.68, 0.43), (0.9, 0.48), (0.68, 0.48)], Color(red: 0.9, green: 0.75, blue: 0.4))
        eye(0.66, 0.44, on: s)
    }

    static func triceratops(_ hide: Color, on s: Sketch) {
        let bone = Color(red: 0.94, green: 0.9, blue: 0.8)
        s.shape([(0.26, 0.56), (0.06, 0.68), (0.28, 0.66)], hide)
        legs(hide, far: [0.3, 0.54], near: [0.24, 0.48], top: 0.62, width: 0.08, on: s)
        s.oval(0.42, 0.6, 0.22, 0.14, hide)
        s.oval(0.66, 0.5, 0.11, 0.15, hide)
        s.oval(0.66, 0.5, 0.11, 0.15, shade)
        s.shape([(0.66, 0.5), (0.88, 0.58), (0.84, 0.68), (0.66, 0.66)], hide)
        s.shape([(0.72, 0.53), (0.84, 0.38), (0.77, 0.55)], bone)
        s.shape([(0.86, 0.59), (0.92, 0.49), (0.9, 0.61)], bone)
        eye(0.74, 0.57, on: s)
    }

    /// Upright on two legs, with tiny arms.
    static func tyrannosaurus(_ hide: Color, on s: Sketch) {
        s.shape([(0.42, 0.48), (0.04, 0.72), (0.44, 0.6)], hide)
        s.line([(0.44, 0.58), (0.5, 0.74), (0.44, ground - 0.02)], hide, width: 0.07)
        s.line([(0.44, 0.58), (0.5, 0.74), (0.44, ground - 0.02)], shade, width: 0.07)
        s.oval(0.5, 0.52, 0.17, 0.12, hide)
        s.line([(0.5, 0.56), (0.6, 0.72), (0.54, ground - 0.02)], hide, width: 0.08)
        s.rect(0.5, ground - 0.04, 0.12, 0.04, hide, corner: 0.02)
        s.line([(0.62, 0.55), (0.68, 0.61)], hide, width: 0.025)
        s.shape([(0.56, 0.47), (0.62, 0.32), (0.72, 0.38), (0.66, 0.53)], hide)
        s.shape([(0.6, 0.34), (0.66, 0.22), (0.9, 0.26), (0.93, 0.35), (0.66, 0.42)], hide)
        s.shape([(0.66, 0.41), (0.88, 0.38), (0.86, 0.45), (0.68, 0.47)], hide)
        s.line([(0.7, 0.4), (0.88, 0.37)], Color(white: 0.95), width: 0.012)
        eye(0.72, 0.28, on: s)
    }
}
