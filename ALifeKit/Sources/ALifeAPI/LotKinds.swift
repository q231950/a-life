import Foundation

extension LotItem {
    /// The buildings a front end draws, each its own way, in the order their
    /// words are looked for in a kind, so a coffee shop is a cafe and a
    /// workshop a shed. A kind that is none of them is a plain building.
    public enum Building: String, CaseIterable, Sendable {
        /// With a striped awning.
        case restaurant
        /// With a striped awning too, in pink.
        case cafe
        case shed
        /// With a striped awning, in blue.
        case shop
        /// A wind turbine, with blades that turn.
        case tower
        /// A tall block of flats with bands of windows.
        case flats
        /// With bands of windows.
        case office
        /// With a red cross.
        case hospital
        /// With a spire.
        case church
        case school
        /// Comes with a farmyard and horses.
        case barn
        case mill
        /// With a pitched roof and a chimney.
        case house

        /// The first one whose words are in `kind`, such as a restaurant for
        /// `pizzeria`, or `nil` if it is a plain building.
        public init?(kind: String) {
            let kind = KindWords(kind)
            guard let building = Self.allCases.first(where: { kind.isOne(of: $0.words) }) else { return nil }
            self = building
        }

        /// What one is called, such as `wind turbine`.
        public var name: String {
            switch self {
            case .tower: "wind turbine"
            case .flats: "block of flats"
            default: rawValue
            }
        }

        /// The words that make a kind this one, such as `bistro` or `pub` for
        /// a restaurant. Each also matches with an s on the end, and a word
        /// ending in one of four letters or more, as a bookshop is a shop.
        public var words: [String] {
            switch self {
            case .restaurant: ["restaurant", "bistro", "diner", "pizzeria", "trattoria", "pub", "inn", "tavern"]
            case .cafe: ["cafe", "café", "coffee", "bakery", "tea", "ice cream", "patisserie"]
            case .shed: ["shed", "garage", "workshop", "hut", "cabin", "greenhouse"]
            case .shop: ["shop", "store", "market", "grocer", "boutique", "kiosk", "pharmacy"]
            case .tower: ["tower", "turbine"]
            case .flats: ["skyscraper", "apartment", "flats", "block", "hotel"]
            case .office: ["office", "bank", "studio", "lab"]
            case .hospital: ["hospital", "clinic", "surgery"]
            case .church: ["church", "chapel", "temple", "cathedral"]
            case .school: ["school", "library", "town hall", "museum", "university", "college", "station"]
            case .barn: ["barn", "stable", "farm", "farmyard", "ranch", "paddock"]
            case .mill: ["mill"]
            case .house: ["house", "home", "cottage", "bungalow", "villa", "lodge"]
            }
        }
    }

    /// The plants a front end draws, each its own way, in the order their
    /// words are looked for in a kind, so rosemary is a herb rather than a
    /// rose and an apple tree an apple rather than any tree. A kind that is
    /// none of them is a little green plant.
    public enum Plant: String, CaseIterable, Sendable {
        /// Low enough to walk through.
        case grass
        case hedge
        case carrot
        /// Lettuces and herbs.
        case lettuce
        case cabbage
        /// Tomatoes on canes, and strawberries.
        case tomato
        case pumpkin
        /// Potatoes, onions and other low rows.
        case potato
        /// Any other vegetable.
        case vegetable
        /// A tall flower.
        case sunflower
        /// Spikes of purple flowers.
        case lavender
        case daisy
        /// Cup-shaped flowers.
        case tulip
        case rose
        case poppy
        /// Any other flower.
        case flower
        /// Pines, firs and the other conifers.
        case pine
        case palm
        case birch
        /// With red fruit.
        case apple
        /// With orange fruit.
        case orange
        /// With pink blossom.
        case cherry
        /// In autumn colours.
        case maple
        /// Any other tree.
        case oak
        /// A bush with berries.
        case berry
        case bush

        /// The first one whose words are in `kind`, such as a pine for
        /// `spruce`, or `nil` if it is a little green plant. A bed whose kind
        /// is an animal (`LotItem.animal`) is the animal's, not a plant.
        public init?(kind: String) {
            let kind = KindWords(kind)
            guard let plant = Self.allCases.first(where: { kind.isOne(of: $0.words) }) else { return nil }
            self = plant
        }

        /// What one is called, such as `cherry tree`.
        public var name: String {
            switch self {
            case .vegetable: "vegetables"
            case .pine, .palm, .apple, .orange, .cherry: rawValue + " tree"
            case .berry: "berry bush"
            default: rawValue
            }
        }

        /// Several of them, such as `cherry trees` or `tomatoes`.
        public var plural: String {
            switch self {
            case .grass, .lavender, .vegetable: name
            case .tomato, .potato, .bush: name + "es"
            case .daisy, .poppy: String(name.dropLast()) + "ies"
            case .berry: "berry bushes"
            case .birch: "birch trees"
            case .maple, .oak: name + " trees"
            default: name + "s"
            }
        }

        /// The words that make a kind this one, such as `spruce` or `cedar`
        /// for a pine. Each also matches with an s on the end, and a word
        /// ending in one of four letters or more, as a wildflower is a flower.
        public var words: [String] {
            switch self {
            case .grass: ["grass", "lawn", "meadow", "clover", "moss", "turf"]
            case .hedge: ["hedge", "hedgerow", "privet"]
            case .carrot: ["carrot", "parsnip", "radish"]
            case .lettuce: ["lettuce", "salad", "spinach", "kale", "chard", "herb", "basil", "parsley", "rosemary", "thyme", "mint", "sage"]
            case .cabbage: ["cabbage", "broccoli", "cauliflower", "sprout"]
            case .tomato: ["tomato", "tomatoes", "pepper", "chilli", "chili", "strawberry"]
            case .pumpkin: ["pumpkin", "squash", "melon", "courgette", "zucchini", "gourd"]
            case .potato: ["potato", "potatoes", "onion", "garlic", "leek", "beet", "beetroot", "turnip"]
            case .vegetable: ["vegetable", "veg", "veggie", "bean", "pea", "corn", "cucumber"]
            case .sunflower: ["sunflower"]
            case .lavender: ["lavender", "foxglove", "lupin", "lupine", "salvia", "delphinium", "heather"]
            case .daisy: ["daisy", "daisies", "chamomile", "camomile", "aster"]
            case .tulip: ["tulip", "lily", "crocus", "daffodil", "narcissus", "bluebell"]
            case .rose: ["rose"]
            case .poppy: ["poppy", "poppies", "marigold", "nasturtium"]
            case .flower: ["flower", "bloom", "peony", "dahlia", "orchid", "pansy", "violet", "iris", "carnation", "geranium", "petunia", "begonia", "hibiscus", "wildflower"]
            case .pine: ["pine", "fir", "spruce", "conifer", "cedar", "cypress", "yew", "larch"]
            case .palm: ["palm", "coconut"]
            case .birch: ["birch", "aspen", "poplar"]
            case .apple: ["apple", "orchard", "pear", "plum"]
            case .orange: ["orange", "lemon", "citrus"]
            case .cherry: ["cherry", "blossom", "sakura", "magnolia"]
            case .maple: ["maple", "acer", "autumn"]
            case .oak: ["oak", "tree", "willow", "elm", "beech", "chestnut", "ash", "lime", "linden", "sycamore"]
            case .berry: ["berry", "blueberry", "raspberry", "blackberry", "currant", "holly"]
            case .bush: ["bush", "bushes", "shrub", "boxwood", "box", "topiary", "fern", "hydrangea", "rhododendron"]
            }
        }
    }

    /// The building it is, if it is one a front end draws its own way.
    public var building: Building? {
        category == .building ? Building(kind: kind) : nil
    }

    /// The plant it is a bed of, if it is one a front end draws its own way
    /// and not a bed of animals.
    public var plant: Plant? {
        category == .plant && animal == nil ? Plant(kind: kind) : nil
    }
}

/// The words of a kind of building or plant, such as `apple tree` or
/// `bookshop`, to tell which it is.
struct KindWords {
    private let text: String
    private let words: [Substring]

    init(_ text: String) {
        self.text = text.lowercased()
        words = self.text.split { !$0.isLetter }
    }

    /// Whether it is one of these: one of its words is one of them, with or
    /// without an s, or ends in one, as a bookshop is a shop. Two words, such
    /// as `town hall`, have to be in it as they are.
    func isOne(of names: [String]) -> Bool {
        names.contains { name in
            if name.contains(" ") { return text.contains(name) }
            return words.contains { $0 == name || $0 == name + "s" || ($0.count > name.count + 2 && name.count >= 4 && $0.hasSuffix(name)) }
        }
    }
}
