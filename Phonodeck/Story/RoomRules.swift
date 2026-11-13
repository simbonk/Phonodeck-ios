import Foundation

// The room builder's code half: the zones the model picks from, the placement rules every kind of
// object obeys, the solver that turns a zone into squares, and a hand-made template for every type
// of room (used to fill in whatever the model leaves out, and on its own when the model fails).

/// A general area of a room, picked by the model from a list.
enum Zone: Hashable {
    case wall(Wall)
    case window
    case doorCorner
    case farCorner
    case centre
    case beside(String)
    case on(String)
    case behind(String)
    /// At a bar, table or desk, on the open side (where a customer or guest would be).
    case at(String)
    case anywhere

    var text: String {
        switch self {
        case .wall(let w): "by the \(w.rawValue) wall"
        case .window: "near the window"
        case .doorCorner: "the corner by the door"
        case .farCorner: "a far corner"
        case .centre: "the centre"
        case .beside(let n): "beside the \(n)"
        case .on(let n): "on the \(n)"
        case .behind(let n): "behind the \(n)"
        case .at(let n): "at the \(n)"
        case .anywhere: "anywhere"
        }
    }

    /// The zones offered for a room: the fixed areas, then beside, on and behind each object in it.
    static func menu(_ room: Room, people: Bool = false) -> [String] {
        var out: [Zone] = Wall.allCases.map { .wall($0) }
        if !room.windows.isEmpty { out.append(.window) }
        if !room.doors.isEmpty { out.append(.doorCorner) }
        out += [.farCorner, .centre]
        for o in room.objects where o.on == nil && !Rules.rule(o.icon).small {
            out.append(.beside(Self.short(o.name)))
            let n = Self.short(o.name)
            if people {
                // People sit on seats, stand at a bar or table, and work behind a counter; they never stand on furniture.
                if Rules.seats.contains(o.icon) { out.append(.on(n)) }
                if Rules.surfaces.contains(o.icon) { out.append(.at(n)) }
                if Rules.staffed.contains(o.icon) { out.append(.behind(n)) }
            } else if Rules.surfaces.contains(o.icon) {
                out.append(.on(n))
            }
        }
        return out.map(\.text)
    }

    /// A name without its article, lowercased ("The long mahogany bar" → "long mahogany bar").
    static func short(_ name: String) -> String {
        let l = name.lowercased().trimmingCharacters(in: .whitespaces)
        for p in ["the ", "a ", "an "] where l.hasPrefix(p) { return String(l.dropFirst(p.count)) }
        return l
    }

    /// Reads a zone back from the model's words ("by the north wall", "on the bar", "beside Dolores").
    static func parse(_ raw: String) -> Zone? {
        let s = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".\"")))
        guard !s.isEmpty else { return nil }
        for w in Wall.allCases where s.contains(w.rawValue) && s.contains("wall") { return .wall(w) }
        if s.contains("window") { return .window }
        if s.contains("door") && (s.contains("corner") || s.contains("by")) { return .doorCorner }
        if s.contains("far corner") || s == "corner" || s.hasSuffix(" corner") { return .farCorner }
        if s.contains("centre") || s.contains("center") || s.contains("middle") { return .centre }
        func rest(_ p: String) -> String? {
            guard s.hasPrefix(p) else { return nil }
            let n = String(s.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
            let bare = n.hasPrefix("the ") ? String(n.dropFirst(4)) : n
            return bare.isEmpty ? nil : bare
        }
        if let n = rest("behind ") { return .behind(n) }
        if let n = rest("at ") { return .at(n) }
        if let n = rest("sitting on ") ?? rest("on top of ") ?? rest("on ") { return .on(n) }
        if let n = rest("beside ") ?? rest("next to ") ?? rest("near ") ?? rest("by ") { return .beside(n) }
        if s == "anywhere" { return .anywhere }
        return nil
    }
}

/// Where a kind of object may go.
struct Rule {
    enum Place { case wall, staffWall, bareWall, wallOrCorner, corner, open, openFar, anywhere }
    var w: Int
    var d: Int
    var place: Place
    var blocks: Blocks
    /// It may stand in front of a window (a plant, a chair, a desk).
    var windowOK = false
    /// It keeps two squares from any door (a bed).
    var awayFromDoor = false
    /// It goes on a table, the bar or a shelf, never on the floor.
    var small = false

    /// Why a spot that breaks the place rule was refused.
    var need: String {
        switch place {
        case .wall: "it needs a wall"
        case .staffWall: "it needs a wall, with room behind it for staff"
        case .bareWall: "it needs a wall with no door or window"
        case .wallOrCorner: "it needs a wall or a corner"
        case .corner: "it belongs in a corner"
        case .open: "it needs open floor"
        case .openFar: "it needs open floor away from the walls"
        case .anywhere: "there's no room there"
        }
    }
}

enum Rules {
    /// The object kinds the model picks from, in the order the builder offers them.
    static let kinds = ["bar", "counter", "table", "chair", "stool", "sofa", "bed", "piano", "shelf", "fireplace", "desk",
                        "crate", "plant", "lamp", "rug", "pillar", "small", "other"]
    static let seats: Set<String> = ["chair", "stool", "sofa", "bed", "piano", "bench", "crate"]
    static let surfaces: Set<String> = ["table", "bar", "counter", "shelf", "desk"]
    static let staffed: Set<String> = ["bar", "counter", "desk"]

    static func rule(_ icon: String) -> Rule {
        switch icon {
        // Where a bar goes, and whether someone works behind it, is the model's call (its zone and its space).
        case "bar", "counter": Rule(w: 3, d: 1, place: .anywhere, blocks: .way)
        case "bed": Rule(w: 2, d: 2, place: .wall, blocks: .way, awayFromDoor: true)
        case "sofa", "bench": Rule(w: 2, d: 1, place: .wall, blocks: .way)
        case "fireplace": Rule(w: 2, d: 1, place: .bareWall, blocks: .way)
        case "piano": Rule(w: 2, d: 1, place: .wallOrCorner, blocks: .way)
        case "shelf": Rule(w: 2, d: 1, place: .wall, blocks: .way)
        case "table": Rule(w: 1, d: 1, place: .open, blocks: .none)
        case "chair", "stool": Rule(w: 1, d: 1, place: .anywhere, blocks: .none, windowOK: true)
        case "desk": Rule(w: 2, d: 1, place: .wall, blocks: .none, windowOK: true)
        case "lamp", "plant": Rule(w: 1, d: 1, place: .corner, blocks: .none, windowOK: true)
        case "rug": Rule(w: 2, d: 2, place: .open, blocks: .none, windowOK: true)
        case "pillar": Rule(w: 1, d: 1, place: .openFar, blocks: .view)
        case "crate": Rule(w: 1, d: 1, place: .wallOrCorner, blocks: .way)
        case "small": Rule(w: 1, d: 1, place: .anywhere, blocks: .none, windowOK: true, small: true)
        default: Rule(w: 1, d: 1, place: .anywhere, blocks: .none)
        }
    }

    /// People who work behind a bar or counter.
    static func isStaff(_ role: String) -> Bool {
        let w = Set(role.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
        return !w.isDisjoint(with: ["bartender", "barkeep", "barkeeper", "barman", "barmaid", "publican", "innkeeper", "shopkeeper", "clerk",
                                    "cashier", "cook", "chef", "pharmacist", "teller", "receptionist", "landlord", "landlady", "baker", "grocer"])
    }
    /// The bar or counter staff work behind, if the room has one.
    static func staffPost(_ room: Room) -> Thing? { room.objects.first { staffed.contains($0.icon) && $0.on == nil } }

    /// Words for what people wear: never an object on the floor.
    static let clothing: Set<String> = ["coat", "overcoat", "raincoat", "jacket", "vest", "waistcoat", "overalls", "dress", "gown", "shirt",
        "blouse", "skirt", "trousers", "pants", "jeans", "boots", "shoes", "heels", "hat", "fedora", "cap", "scarf", "gloves", "cloak",
        "uniform", "apron", "suit", "tie", "sweater", "cardigan", "shawl", "stockings", "robe", "tunic", "bonnet", "veil"]
    /// Words for what is on the ceiling or above: not on a floor plan.
    static let overhead: Set<String> = ["skylight", "skylights", "ceiling", "chandelier", "rafters", "beams", "roof", "sky", "stars", "moon"]

    /// Whether a name belongs on the floor plan (not clothing, not something overhead, not a sound or a smell).
    static func onPlan(_ name: String) -> Bool {
        let words = Set(name.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
        let senses: Set<String> = ["smell", "smells", "scent", "aroma", "odour", "odor", "stench", "perfume", "sound", "sounds", "music", "hum", "light",
            "lamplight", "candlelight", "glow", "air", "smoke", "rain", "noise", "silence", "warmth", "heat", "chill", "cold", "damp", "darkness",
            "shadow", "shadows", "steam", "mist", "fog", "haze", "laughter", "chatter", "voices", "murmur", "jazz", "melody", "tune", "rhythm",
            "drumming", "crackle", "crackling", "buzz", "buzzing", "whir", "clink", "clinking", "patter", "echo", "echoes", "thunder", "lightning", "storm", "wind", "breeze", "atmosphere", "mood", "feeling"]
        // A material on its own is what something is made of, not a thing ("polished wood", "brass tiles").
        let stuff: Set<String> = ["wood", "wool", "dust", "tiles", "tile", "brass", "leather", "velvet", "silk", "stone", "marble", "iron",
            "copper", "tin", "plaster", "paint", "wallpaper", "floorboards", "floor", "floors", "wall", "walls", "dirt", "mud", "grime", "polish",
            "varnish", "tobacco", "whiskey", "gin", "linen", "cotton", "satin", "lace", "mahogany", "oak", "pine"]
        let last = name.lowercased().split(whereSeparator: { !$0.isLetter }).last.map(String.init) ?? ""
        return words.isDisjoint(with: clothing) && words.isDisjoint(with: overhead) && words.isDisjoint(with: senses) && !stuff.contains(last)
    }

    /// The kind of object a name most likely is ("a dusty upright piano" is a piano).
    static func icon(for name: String) -> String {
        let words = Set(name.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
        let table: [(String, [String])] = [
            ("bar", ["bar", "bartop"]), ("counter", ["counter", "till", "register", "reception"]),
            ("piano", ["piano", "harpsichord", "organ"]), ("fireplace", ["fireplace", "hearth", "stove", "fire"]),
            ("bed", ["bed", "cot", "bunk", "hammock"]), ("sofa", ["sofa", "couch", "settee", "divan", "bench", "pew"]),
            ("shelf", ["shelf", "shelves", "bookcase", "bookshelf", "cabinet", "dresser", "wardrobe", "cupboard"]),
            ("desk", ["desk", "workbench", "bureau"]), ("table", ["table", "booth"]),
            ("stool", ["stool", "stools"]), ("chair", ["chair", "chairs", "armchair", "seat"]),
            ("crate", ["crate", "crates", "barrel", "barrels", "chest", "trunk", "box", "boxes", "sack", "sacks"]),
            ("plant", ["plant", "fern", "palm", "flowers", "tree", "pot"]), ("lamp", ["lamp", "lantern", "sconce", "candelabra"]),
            ("rug", ["rug", "carpet", "mat"]), ("pillar", ["pillar", "column", "post", "beam", "statue"]),
            ("small", ["glass", "glasses", "bottle", "bottles", "cup", "mug", "book", "books", "candle", "candles", "letter", "key",
                       "keys", "plate", "knife", "photo", "photograph", "phone", "radio", "record", "gramophone", "ashtray", "vase",
                       "newspaper", "map", "pen", "note", "wallet", "coin", "coins", "cigarette", "cigar", "tray", "jar", "lantern"]),
        ]
        for (icon, keys) in table where !words.isDisjoint(with: keys) { return icon }
        return "other"
    }

    /// The map's symbol for a kind of object (SF Symbols).
    static func symbol(_ icon: String) -> String {
        switch icon {
        case "bar", "counter": "wineglass"
        case "table": "square.fill"
        case "chair": "chair.fill"
        case "stool": "circle.fill"
        case "sofa", "bench": "sofa.fill"
        case "bed": "bed.double.fill"
        case "piano": "pianokeys"
        case "shelf": "books.vertical.fill"
        case "fireplace": "fireplace.fill"
        case "desk": "table.furniture.fill"
        case "crate": "shippingbox.fill"
        case "plant": "leaf.fill"
        case "lamp": "lamp.floor.fill"
        case "rug": "square.dashed"
        case "pillar": "building.columns.fill"
        case "small": "cup.and.saucer.fill"
        default: "cube.fill"
        }
    }
}

// MARK: - The solver

enum Placer {
    /// A place for an object: its corner and size.
    struct Spot: Hashable { var x: Int; var y: Int; var w: Int; var d: Int
        var cells: [Cell] { var o: [Cell] = []; for i in 0..<w { for j in 0..<d { o.append(Cell(x: x + i, y: y + j)) } }; return o }
    }

    /// The squares a zone covers, for an object (`forPeople`: the squares people stand on).
    static func cells(_ zone: Zone, in room: Room, forPeople: Bool = false) -> [Cell] {
        var all: [Cell] = []
        for x in 0..<room.width { for y in 0..<room.depth { all.append(Cell(x: x, y: y)) } }
        func near(_ c: Cell, _ r: Int) -> [Cell] { all.filter { abs($0.x - c.x) <= r && abs($0.y - c.y) <= r } }
        let corners = [Cell(x: 0, y: 0), Cell(x: room.width - 1, y: 0), Cell(x: 0, y: room.depth - 1), Cell(x: room.width - 1, y: room.depth - 1)]
        switch zone {
        case .wall(let w):
            return all.filter { c in
                switch w {
                case .north: c.y <= 1
                case .south: c.y >= room.depth - 2
                case .west: c.x <= 1
                case .east: c.x >= room.width - 2
                }
            }
        case .window:
            return room.windows.flatMap { o in room.cells(of: o).flatMap { c in [c, room.inward(c, from: o.wall)] } }
        case .doorCorner:
            let doorCells = room.doors.flatMap { room.cells(of: $0) }
            guard !doorCells.isEmpty else { return near(corners[0], 1) }
            func gap(_ c: Cell) -> Int { doorCells.map { abs($0.x - c.x) + abs($0.y - c.y) }.min() ?? 0 }
            let best: Cell = corners.min { gap($0) < gap($1) } ?? corners[0]
            return near(best, 1)
        case .farCorner:
            let doorCells = room.doors.flatMap { room.cells(of: $0) }
            func gap(_ c: Cell) -> Int { doorCells.map { abs($0.x - c.x) + abs($0.y - c.y) }.min() ?? 0 }
            let best: Cell = corners.max { gap($0) < gap($1) } ?? corners[3]
            return near(best, 1)
        case .centre:
            let x0 = room.width / 3, x1 = max(x0, room.width - 1 - room.width / 3)
            let y0 = room.depth / 3, y1 = max(y0, room.depth - 1 - room.depth / 3)
            return all.filter { $0.x >= x0 && $0.x <= x1 && $0.y >= y0 && $0.y <= y1 }
        case .beside(let n):
            if let t = room.named(n) {
                let mine = Set(t.cells)
                let side = Array(Set(t.cells.flatMap { near($0, 1) })).filter { !mine.contains($0) }
                // Beside a bar means the guests' side: the staff side stays for whoever works there.
                if Rules.staffed.contains(t.icon) {
                    let staff = Set(cells(.behind(n), in: room))
                    let open = side.filter { !staff.contains($0) }
                    return open.isEmpty ? side : open
                }
                return side
            }
            return all
        case .on(let n):
            return room.named(n)?.cells ?? []
        case .at(let n):
            guard let t = room.named(n) else { return [] }
            let mine = Set(t.cells)
            let side = Array(Set(t.cells.flatMap { near($0, 1) })).filter { !mine.contains($0) }
            if Rules.staffed.contains(t.icon) {
                let staff = Set(cells(.behind(n), in: room))
                let open = side.filter { !staff.contains($0) }
                return open.isEmpty ? side : open
            }
            return side
        case .behind(let n):
            guard let t = room.named(n) else { return [] }
            // The long side of it that faces its nearest wall (the staff side of a bar), never
            // its ends: someone behind a bar stands along it, between it and the wall.
            let back = pad(x: t.x, y: t.y, w: t.w, d: t.d, space: "behind", room: room).filter { room.contains($0) }
            if !back.isEmpty { return Array(back) }
            let mine = Set(t.cells)
            let side = Array(Set(t.cells.flatMap { near($0, 1) })).filter { !mine.contains($0) }
            func wallDist(_ c: Cell) -> Int { min(c.x, c.y, room.width - 1 - c.x, room.depth - 1 - c.y) }
            let m = side.map(wallDist).min() ?? 0
            return side.filter { wallDist($0) == m }
        case .anywhere:
            return forPeople ? all : all
        }
    }

    /// The squares kept clear around a thing: in front (the side facing into the room), behind
    /// (the side toward its nearest wall) or all round. Squares outside the room are included,
    /// so a thing whose space would fall outside can't go there.
    static func pad(x: Int, y: Int, w: Int, d: Int, space: String?, room: Room) -> Set<Cell> {
        guard let sp = space?.lowercased(), !sp.isEmpty, sp != "none" else { return [] }
        var sides: [(Int, Int)] = []
        if sp.contains("all") || sp.contains("round") || sp.contains("around") {
            sides = [(0, -1), (0, 1), (-1, 0), (1, 0)]
        } else {
            // The nearest wall decides which way is "behind".
            // A long thing's back is one of its long sides, never an end.
            let big = 1 << 20
            let dN = w < d ? big : y, dS = w < d ? big : room.depth - (y + d)
            let dW = w > d ? big : x, dE = w > d ? big : room.width - (x + w)
            let m = min(dN, dS, dW, dE)
            let back: (Int, Int) = m == dN ? (0, -1) : m == dS ? (0, 1) : m == dW ? (-1, 0) : (1, 0)
            sides = [sp.contains("behind") ? back : (-back.0, -back.1)]
        }
        var out = Set<Cell>()
        for (dx, dy) in sides {
            for i in 0..<max(1, w) { for j in 0..<max(1, d) {
                let c = Cell(x: x + i + dx, y: y + j + dy)
                if !(c.x >= x && c.x < x + w && c.y >= y && c.y < y + d) { out.insert(c) }
            } }
        }
        return out
    }

    static func centroid(_ cells: [Cell]) -> (Double, Double) {
        guard !cells.isEmpty else { return (0, 0) }
        return (Double(cells.map(\.x).reduce(0, +)) / Double(cells.count) + 0.5, Double(cells.map(\.y).reduce(0, +)) / Double(cells.count) + 0.5)
    }

    /// Whether a spot keeps the rules for this object; nil when it does, or why it doesn't.
    static func breaks(_ s: Spot, rule r: Rule, thing t: Thing, room: Room) -> String? {
        let cells = s.cells
        guard cells.allSatisfy({ room.contains($0) }) else { return "there's no room there" }
        // The space the model said people need around a thing is kept clear of other things.
        for o in room.objects where o.space != nil && o.on == nil && o.id != t.id {
            let pad = Self.pad(x: o.x, y: o.y, w: o.w, d: o.d, space: o.space, room: room)
            if cells.contains(where: { pad.contains($0) }) { return "that's the space kept clear " + (o.space ?? "") + " the " + Zone.short(o.name) }
        }
        // And this thing's own space has to be in the room and free.
        if t.space != nil {
            let pad = Self.pad(x: s.x, y: s.y, w: s.w, d: s.d, space: t.space, room: room)
            let taken = room.floorTaken(except: [t.id]).union(room.doorClear)
            if pad.isEmpty || pad.contains(where: { !room.contains($0) || taken.contains($0) }) {
                return "it needs space " + (t.space ?? "") + " it for people to walk or work"
            }
        }
        let flushN = s.y == 0, flushS = s.y + s.d == room.depth, flushW = s.x == 0, flushE = s.x + s.w == room.width
        let long = s.w != s.d
        // Long things run along their wall.
        func along(_ wall: Wall) -> Bool { !long || ((wall == .north || wall == .south) ? s.w > s.d : s.d > s.w) }
        var flushWalls: [Wall] = []
        if flushN { flushWalls.append(.north) }
        if flushS { flushWalls.append(.south) }
        if flushW { flushWalls.append(.west) }
        if flushE { flushWalls.append(.east) }
        switch r.place {
        case .wall, .bareWall:
            let ok = flushWalls.filter(along)
            if ok.isEmpty { return r.need }
            if r.place == .bareWall {
                let openings = room.doorClear.union(room.windowCells)
                var span = Set<Cell>()
                for c in cells { for dx in -1...1 { for dy in -1...1 { span.insert(Cell(x: c.x + dx, y: c.y + dy)) } } }
                if !span.isDisjoint(with: openings) { return r.need }
            }
        case .staffWall:
            // One square off a wall, with that strip free for whoever works behind it.
            var strip: [Cell]? = nil
            if s.y == 1, s.w > s.d { strip = (0..<s.w).map { Cell(x: s.x + $0, y: 0) } }
            else if s.y + s.d == room.depth - 1, s.w > s.d { strip = (0..<s.w).map { Cell(x: s.x + $0, y: room.depth - 1) } }
            else if s.x == 1, s.d > s.w { strip = (0..<s.d).map { Cell(x: 0, y: s.y + $0) } }
            else if s.x + s.w == room.width - 1, s.d > s.w { strip = (0..<s.d).map { Cell(x: room.width - 1, y: s.y + $0) } }
            guard let st = strip else { return r.need }
            let taken = room.floorTaken(except: [t.id]).union(room.doorClear)
            if st.contains(where: { taken.contains($0) }) { return r.need }
        case .wallOrCorner:
            if flushWalls.filter(along).isEmpty { return r.need }
        case .corner:
            if flushWalls.count < 2 { return r.need }
        case .open:
            if cells.contains(where: { room.onEdge($0) }) { return r.need }
        case .openFar:
            let far = room.width >= 5 && room.depth >= 5
            if cells.contains(where: { far ? (min($0.x, $0.y, room.width - 1 - $0.x, room.depth - 1 - $0.y) < 2) : room.onEdge($0) }) { return r.need }
        case .anywhere:
            break
        }
        let set = Set(cells)
        if t.icon != "rug", !set.isDisjoint(with: room.floorTaken(except: [t.id])) { return "there's no room there" }
        if t.icon == "rug", !set.isDisjoint(with: Set(room.objects.filter { $0.icon == "rug" && $0.id != t.id }.flatMap(\.cells))) { return "there's no room there" }
        if !set.isDisjoint(with: room.doorClear) { return "it would block the door" }
        if r.awayFromDoor {
            let doorCells = room.doors.flatMap { room.cells(of: $0) }
            if cells.contains(where: { c in doorCells.contains { abs($0.x - c.x) <= 2 && abs($0.y - c.y) <= 2 } }) { return "it can't go by the door" }
        }
        if !r.windowOK, t.blocks != .none, !set.isDisjoint(with: room.windowCells) { return "it would cover the window" }
        if t.blocks.way, !RoomGrid.doorsConnected(room, solid: room.solid(except: [t.id]).union(set)) { return "it would cut off the way between the doors" }
        // Nobody ends up inside furniture.
        if t.blocks.way, room.people.contains(where: { $0.on == nil && set.contains(Cell(x: $0.x, y: $0.y)) }) { return "someone is standing there" }
        return nil
    }

    /// Every spot that keeps the rules, in either orientation.
    static func legal(_ t: Thing, rule given: Rule, room: Room) -> [Spot] {
        var out: [Spot] = []
        var r = given
        // The model's own size for it, when it gave one.
        if t.w > 1 || t.d > 1 { r.w = max(t.w, t.d); r.d = min(t.w, t.d) }
        // A bar or counter runs along most of its wall in a bigger room.
        if r.place == .staffWall, t.w <= 1, t.d <= 1 { r.w = max(r.w, min(6, max(room.width, room.depth) / 2)) }
        let sizes = Set([[r.w, r.d], [r.d, r.w]].map { $0 })
        for sz in sizes {
            let w = min(sz[0], room.width), d = min(sz[1], room.depth)
            guard w > 0, d > 0 else { continue }
            for x in 0...(room.width - w) { for y in 0...(room.depth - d) {
                let s = Spot(x: x, y: y, w: w, d: d)
                // Long side along a wall, as the model said: lengthwise to the nearest wall, and near it.
                if t.along == "wall", w != d {
                    let gaps = [(s.y, true), (room.depth - s.y - s.d, true), (s.x, false), (room.width - s.x - s.w, false)]
                    guard let near = gaps.min(by: { $0.0 < $1.0 }), near.0 <= 2, near.1 == (w > d) else { continue }
                }
                if breaks(s, rule: r, thing: t, room: room) == nil { out.append(s) }
            } }
        }
        return out
    }

    static func score(_ s: Spot, to target: (Double, Double)) -> Double {
        let cx = Double(s.x) + Double(s.w) / 2, cy = Double(s.y) + Double(s.d) / 2
        return (cx - target.0) * (cx - target.0) + (cy - target.1) * (cy - target.1)
    }

    /// The outcome of placing one object.
    struct Outcome {
        /// Placed where asked.
        var placed: Bool
        /// Why the asked zone was refused ("" when it was not).
        var reason = ""
    }

    /// Puts an object in its zone if the rules allow it there. On a refusal the object is not placed,
    /// so the builder can push back and ask again.
    @discardableResult
    static func place(_ room: inout Room, _ t: Thing, zone: Zone) -> Outcome {
        var t = t
        let r = Rules.rule(t.icon)
        if t.blocks == .none { t.blocks = r.blocks }
        // Small things go on a surface.
        if r.small {
            let surface: Thing?
            if case .on(let n) = zone { surface = room.named(n) } else { surface = nil }
            let target = centroid(cells(zone, in: room))
            var pick: Thing? = nil
            if let sf = surface, Rules.surfaces.contains(sf.icon) || sf.icon == "other" { pick = sf }
            if pick == nil {
                var best = Double.infinity
                for o in room.objects where Rules.surfaces.contains(o.icon) && o.on == nil {
                    let d = score(Spot(x: o.x, y: o.y, w: o.w, d: o.d), to: target)
                    if d < best { best = d; pick = o }
                }
            }
            guard let s = pick else { return Outcome(placed: false, reason: "it belongs on a table, a bar or a shelf") }
            let used = Set(room.objects.filter { $0.on == s.id }.map { Cell(x: $0.x, y: $0.y) })
            let c = s.cells.first { !used.contains($0) } ?? s.cells[0]
            t.x = c.x; t.y = c.y; t.w = 1; t.d = 1; t.on = s.id
            room.things.append(t)
            return Outcome(placed: true)
        }
        let zc = cells(zone, in: room)
        guard !zc.isEmpty else { return Outcome(placed: false, reason: "there's no such place in this room") }
        let zset = Set(zc)
        let target = centroid(zc)
        let ok = legal(t, rule: r, room: room)
        let inZone = ok.filter { !Set($0.cells).isDisjoint(with: zset) }
        if let best = inZone.min(by: { score($0, to: target) < score($1, to: target) }) {
            t.x = best.x; t.y = best.y; t.w = best.w; t.d = best.d
            room.things.append(t)
            return Outcome(placed: true)
        }
        // Why not: the most common reason among the spots in the zone.
        var counts: [String: Int] = [:]
        let sizes = [[r.w, r.d], [r.d, r.w]]
        for z in zc { for sz in sizes {
            let s = Spot(x: z.x, y: z.y, w: sz[0], d: sz[1])
            if let why = breaks(s, rule: r, thing: t, room: room) { counts[why, default: 0] += 1 }
        } }
        let reason = counts.max { a, b in a.value < b.value }?.key ?? "there's no room there"
        return Outcome(placed: false, reason: reason)
    }

    /// The zones where an object could go, for the push-back question.
    static func allowed(_ t: Thing, in room: Room) -> [String] {
        Zone.menu(room).filter { z in
            guard let zone = Zone.parse(z) else { return false }
            var trial = room
            return place(&trial, t, zone: zone).placed
        }
    }

    /// The nearest legal spot to a zone, rules first; then anywhere free; the thing always lands.
    static func fallback(_ room: inout Room, _ t: Thing, near zone: Zone) {
        var t = t
        let r = Rules.rule(t.icon)
        if t.blocks == .none { t.blocks = r.blocks }
        if r.small {
            if place(&room, t, zone: zone).placed { return }
            // No surface anywhere: it lies on the floor near the middle.
            let free = freeCells(room)
            let target = centroid(cells(.centre, in: room))
            if let c = free.min(by: { cellScore($0, target) < cellScore($1, target) }) { t.x = c.x; t.y = c.y }
            room.things.append(t)
            return
        }
        let target = centroid(cells(zone, in: room))
        if let best = legal(t, rule: r, room: room).min(by: { score($0, to: target) < score($1, to: target) }) {
            t.x = best.x; t.y = best.y; t.w = best.w; t.d = best.d
            room.things.append(t)
            return
        }
        // Still nothing: a long piece gets a metre shorter at a time, keeping every rule, before it
        // gives up being long (a bar squeezed to one square reads as a box).
        let full = max(t.w, t.d, r.w, min(6, max(room.width, room.depth) / 2))
        if full > 2 {
            for len in stride(from: full - 1, through: 2, by: -1) {
                for keepAlong in [true, false] where keepAlong || t.along != nil {
                    var t2 = t
                    t2.w = len; t2.d = min(max(1, min(t.w, t.d, r.d)), len)
                    if !keepAlong { t2.along = nil }
                    var r2 = r; r2.w = len; r2.d = t2.d
                    if let best = legal(t2, rule: r2, room: room).min(by: { score($0, to: target) < score($1, to: target) }) {
                        t2.x = best.x; t2.y = best.y; t2.w = best.w; t2.d = best.d
                        room.things.append(t2)
                        return
                    }
                }
            }
        }
        // Nothing keeps every rule: a single free square, out of the doorways.
        var loose = Rule(w: 1, d: 1, place: .anywhere, blocks: .none, windowOK: true)
        loose.awayFromDoor = false
        var t1 = t; t1.w = 1; t1.d = 1; t1.blocks = .none
        if let best = legal(t1, rule: loose, room: room).min(by: { score($0, to: target) < score($1, to: target) }) {
            t.x = best.x; t.y = best.y; t.w = 1; t.d = 1
            room.things.append(t)
        }
        // Even then it is not dropped: it takes any free square, so what the story named is on the map.
        if let c = freeCells(room).min(by: { cellScore($0, target) < cellScore($1, target) }) {
            t.x = c.x; t.y = c.y; t.w = 1; t.d = 1; t.blocks = .none
            room.things.append(t)
        }
    }

    static func cellScore(_ c: Cell, _ t: (Double, Double)) -> Double {
        let x = Double(c.x) + 0.5, y = Double(c.y) + 0.5
        return (x - t.0) * (x - t.0) + (y - t.1) * (y - t.1)
    }

    /// Squares a person can stand on: not furniture, not another person, not a doorway.
    static func freeCells(_ room: Room, except: UUID? = nil) -> [Cell] {
        let taken = room.floorTaken().union(Set(room.people.filter { $0.id != except }.map { Cell(x: $0.x, y: $0.y) }))
        var out: [Cell] = []
        for x in 0..<room.width { for y in 0..<room.depth {
            let c = Cell(x: x, y: y)
            if !taken.contains(c) { out.append(c) }
        } }
        return out
    }

    /// Puts a person in a zone: on a seat, behind a bar, beside someone, or in an area. Returns a
    /// note when the zone couldn't be met and the nearest free square was used instead.
    @discardableResult
    static func placePerson(_ room: inout Room, _ p: Thing, zone: Zone) -> String {
        var p = p
        var note = ""
        p.on = nil
        var zone = zone
        // Nobody stands on a bar or a table: they stand at it.
        if case .on(let n) = zone, let thing = room.named(n), !thing.isPerson, !Rules.seats.contains(thing.icon) { zone = .at(n) }
        // At a bar or table with a free stool or chair there: they sit on it.
        if case .at = zone {
            let zc = Set(cells(zone, in: room, forPeople: true))
            let taken = Set(room.people.filter { $0.id != p.id }.compactMap(\.on))
            if let seat = room.objects.first(where: { Rules.seats.contains($0.icon) && $0.on == nil && !taken.contains($0.id) && zc.contains(Cell(x: $0.x, y: $0.y)) }) {
                p.x = seat.x; p.y = seat.y; p.on = seat.id
                put(&room, p)
                return ""
            }
        }
        if case .on(let n) = zone, let seat = room.named(n), !seat.isPerson {
            let sitting = Set(room.people.filter { $0.on == seat.id && $0.id != p.id }.map { Cell(x: $0.x, y: $0.y) })
            if let c = seat.cells.first(where: { !sitting.contains($0) }) {
                p.x = c.x; p.y = c.y; p.on = seat.id
                put(&room, p)
                return ""
            }
            note = seat.name + " is taken"
        }
        let zc = Set(cells(zone, in: room, forPeople: true))
        let free = freeCells(room, except: p.id)
        let target = centroid(Array(zc))
        let inZone = free.filter { zc.contains($0) && !room.doorClear.contains($0) }
        let pool = inZone.isEmpty ? free.filter { !room.doorClear.contains($0) } : inZone
        if inZone.isEmpty, note.isEmpty { note = "no room " + zone.text }
        if let c = (pool.isEmpty ? free : pool).min(by: { cellScore($0, target) < cellScore($1, target) }) {
            p.x = c.x; p.y = c.y
        }
        put(&room, p)
        return note
    }

    static func put(_ room: inout Room, _ t: Thing) {
        if let i = room.index(t.id) { room.things[i] = t } else { room.things.append(t) }
    }

    /// Turns someone toward a person or thing (by name; "you" is the player).
    static func turn(_ room: inout Room, _ id: UUID, toward name: String) {
        guard let i = room.index(id) else { return }
        let n = name.lowercased()
        var target: Thing?
        if ["you", "the player", "player"].contains(n) {
            target = room.player
        } else if n.contains("door"), let d = room.doors.first {
            let c = room.cells(of: d)[0]
            target = Thing(kind: .object, name: "door", x: c.x, y: c.y)
        } else if n.contains("window"), let o = room.windows.first {
            let c = room.cells(of: o)[0]
            target = Thing(kind: .object, name: "window", x: c.x, y: c.y)
        } else {
            target = room.named(name)
        }
        guard let t = target, t.id != id else { return }
        let me = room.things[i]
        let (mx, my) = me.centre, (tx, ty) = t.centre
        if let f = Facing.toward(dx: Int((tx - mx).rounded()), dy: Int((ty - my).rounded())) { room.things[i].facing = f }
    }
}
