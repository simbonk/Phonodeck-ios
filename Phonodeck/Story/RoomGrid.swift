import Foundation

// The world as rooms: each room is a grid of 1 m squares, and every person and thing in it stands
// on a square (or on another thing) with its own list of properties. Code reads the grid to work out
// what the player can see, what is in the way, and who is facing whom; the storyteller only ever
// gets that reading in plain words, never the grid itself.

/// One of eight ways to face. North is the top of the map; y grows southward.
enum Facing: Int, Codable, CaseIterable, Hashable {
    case n = 0, ne, e, se, s, sw, w, nw

    var dx: Int { [0, 1, 1, 1, 0, -1, -1, -1][rawValue] }
    var dy: Int { [-1, -1, 0, 1, 1, 1, 0, -1][rawValue] }
    /// Clockwise from north, in radians.
    var angle: Double { Double(rawValue) * .pi / 4 }
    var opposite: Facing { Facing(rawValue: (rawValue + 4) % 8) ?? .s }
    var word: String { ["north", "north-east", "east", "south-east", "south", "south-west", "west", "north-west"][rawValue] }

    /// The facing closest to a direction (nil for no direction).
    static func toward(dx: Int, dy: Int) -> Facing? {
        guard dx != 0 || dy != 0 else { return nil }
        var a = atan2(Double(dx), Double(-dy))   // clockwise from north
        if a < 0 { a += 2 * .pi }
        return Facing(rawValue: Int((a / (.pi / 4)).rounded()) % 8)
    }
}

enum Wall: String, Codable, CaseIterable, Hashable {
    case north, south, east, west
    /// The way you face when you look at this wall from inside the room.
    var facing: Facing { switch self { case .north: .n; case .south: .s; case .east: .e; case .west: .w } }
}

/// A door or a window: a stretch of wall.
struct Opening: Codable, Hashable, Identifiable {
    var id = UUID()
    var wall: Wall
    /// The first square along the wall (from the west for north and south walls, from the north for east and west).
    var at: Int
    var width = 1
    /// A door: the room or place it leads to.
    var leadsTo = ""
    /// A window: what is seen through it.
    var view = ""
}

/// What a thing gets in the way of.
enum Blocks: String, Codable, Hashable {
    case none, way, view, both
    var way: Bool { self == .way || self == .both }
    var view: Bool { self == .view || self == .both }
}

/// A person or object in a room: where it is, and everything known about it.
struct Thing: Codable, Hashable, Identifiable {
    enum Kind: String, Codable { case player, person, object }
    var id = UUID()
    var kind: Kind
    var name: String
    /// The object's kind for the rules and the map's symbol ("bar", "stool", "glass"; "" for people).
    var icon = ""
    var x = 0
    var y = 0
    /// Squares covered (objects only; people take one).
    var w = 1
    var d = 1
    var facing: Facing = .s
    /// The thing this one stands, sits or lies on (a person on a stool, a glass on the bar).
    var on: UUID?
    var blocks: Blocks = .none
    /// Where people need room to walk or work around it, as the model said ("in front", "behind",
    /// "all round"; nil for none). Nothing else is placed there.
    var space: String?
    /// "wall" when the model said its long side runs along a wall (a bar, a bookcase); nil otherwise.
    var along: String?

    // People
    var expression = ""
    var doing = ""
    var feeling = ""
    var wearing = ""
    var holding: [String] = []
    var dialogue: [String] = []
    var backstory = ""
    var pastMoves: [String] = []

    // Objects
    var makeup = ""
    var state = ""

    var isPerson: Bool { kind != .object }
    var cells: [Cell] {
        var out: [Cell] = []
        for i in 0..<max(1, w) { for j in 0..<max(1, d) { out.append(Cell(x: x + i, y: y + j)) } }
        return out
    }
    /// The middle of what it covers, in metres from the room's north-west corner.
    var centre: (x: Double, y: Double) { (Double(x) + Double(max(1, w)) / 2, Double(y) + Double(max(1, d)) / 2) }
    /// A signature of everything shown about it, so the map can tell when it changed.
    var look: String {
        [String(x), String(y), String(w), String(d), String(facing.rawValue), on?.uuidString ?? "", name, expression, doing, feeling,
         wearing, holding.joined(separator: ","), makeup, state, dialogue.last ?? ""].joined(separator: "|")
    }
}

struct Cell: Hashable, Codable {
    var x: Int
    var y: Int
}

/// One room of the world.
struct Room: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    /// The room's type from the builder's list ("bar", "bedroom", "street").
    var type = "other"
    var width = 7
    var depth = 6
    var inside = ""
    var outside = ""
    var sound = ""
    var doors: [Opening] = []
    var windows: [Opening] = []
    var things: [Thing] = []
    /// How the room was built and changed, one decision per line, for the map's ticker and replay.
    var log: [String] = []
    /// Laid out by the room builder's questions (false: drawn from its template only, so far).
    var built = false

    var people: [Thing] { things.filter(\.isPerson) }
    var objects: [Thing] { things.filter { !$0.isPerson } }
    var player: Thing? { things.first { $0.kind == .player } }

    func thing(_ id: UUID?) -> Thing? { id.flatMap { i in things.first { $0.id == i } } }
    func index(_ id: UUID) -> Int? { things.firstIndex { $0.id == id } }
    /// A thing by name (whole name, then first word), people and objects alike.
    func named(_ name: String) -> Thing? {
        func strip(_ x: String) -> String {
            let l = x.lowercased().trimmingCharacters(in: .whitespaces)
            for p in ["the ", "a ", "an "] where l.hasPrefix(p) { return String(l.dropFirst(p.count)) }
            return l
        }
        let bare = strip(name)
        guard !bare.isEmpty else { return nil }
        let firstWord = bare.split(separator: " ").first.map(String.init) ?? bare
        return things.first { strip($0.name) == bare }
            ?? things.first { $0.isPerson && (strip($0.name).split(separator: " ").first.map(String.init) ?? "") == firstWord }
            ?? things.first { !$0.isPerson && $0.icon == bare }
            ?? things.first { !$0.isPerson && strip($0.name).hasSuffix(bare) }
            ?? things.first { !$0.isPerson && (strip($0.name).contains(bare) || bare.contains(strip($0.name))) }
    }

    func contains(_ c: Cell) -> Bool { c.x >= 0 && c.y >= 0 && c.x < width && c.y < depth }
    func onEdge(_ c: Cell) -> Bool { c.x == 0 || c.y == 0 || c.x == width - 1 || c.y == depth - 1 }

    /// The square just inside a stretch of wall.
    func cell(on wall: Wall, at i: Int) -> Cell {
        switch wall {
        case .north: Cell(x: i, y: 0)
        case .south: Cell(x: i, y: depth - 1)
        case .west: Cell(x: 0, y: i)
        case .east: Cell(x: width - 1, y: i)
        }
    }
    func length(of wall: Wall) -> Int { wall == .north || wall == .south ? width : depth }
    func cells(of o: Opening) -> [Cell] { (0..<max(1, o.width)).map { cell(on: o.wall, at: o.at + $0) } }
    /// One square further in from a square on a wall.
    func inward(_ c: Cell, from wall: Wall) -> Cell {
        let f = wall.facing.opposite
        return Cell(x: c.x + f.dx, y: c.y + f.dy)
    }
    /// The squares that must stay clear for a door: the doorway and the square in front of it.
    var doorClear: Set<Cell> {
        var s = Set<Cell>()
        for o in doors { for c in cells(of: o) { s.insert(c); s.insert(inward(c, from: o.wall)) } }
        return s
    }
    var windowCells: Set<Cell> { Set(windows.flatMap { cells(of: $0) }) }

    /// Squares covered by something that blocks the way (people and the thing `except` aside).
    func solid(except: Set<UUID> = []) -> Set<Cell> {
        Set(things.filter { !$0.isPerson && $0.blocks.way && $0.on == nil && !except.contains($0.id) }.flatMap(\.cells))
    }
    /// Squares covered by any furniture standing on the floor (things on things aside).
    func floorTaken(except: Set<UUID> = []) -> Set<Cell> {
        Set(things.filter { !$0.isPerson && $0.on == nil && $0.icon != "rug" && !except.contains($0.id) }.flatMap(\.cells))
    }

    /// Everything on a square: what stands on the floor, then what is on it, people last.
    func stack(at c: Cell) -> [Thing] {
        let here = things.filter { $0.cells.contains(c) }
        return here.sorted { a, b in
            func rank(_ t: Thing) -> Int { t.isPerson ? 3 : t.icon == "rug" ? 0 : t.on == nil ? 1 : 2 }
            return rank(a) < rank(b)
        }
    }
}

// MARK: - Seeing, blocking and paths

enum RoomGrid {
    /// How the player perceives someone or something in the room.
    enum Seen: Equatable {
        /// In front, within the view cone and not hidden.
        case front
        /// To one side: at the edge of view.
        case side
        /// Behind the player: heard, not seen.
        case behind
        /// In the cone but hidden behind something (its name).
        case hidden(String)
    }

    /// Straight-line squares between two squares, ends excluded (Bresenham).
    static func line(_ a: Cell, _ b: Cell) -> [Cell] {
        var out: [Cell] = []
        var x = a.x, y = a.y
        let dx = abs(b.x - a.x), dy = -abs(b.y - a.y)
        let sx = a.x < b.x ? 1 : -1, sy = a.y < b.y ? 1 : -1
        var err = dx + dy
        while !(x == b.x && y == b.y) {
            let e2 = 2 * err
            if e2 >= dy { err += dy; x += sx }
            if e2 <= dx { err += dx; y += sy }
            if !(x == b.x && y == b.y) { out.append(Cell(x: x, y: y)) }
        }
        return out
    }

    /// The angle in degrees between where `from` faces and the direction to `to` (0 straight ahead, 180 behind).
    static func angle(from: Thing, to: Thing) -> Double {
        let (fx, fy) = from.centre
        let (tx, ty) = to.centre
        let vx = tx - fx, vy = ty - fy
        guard vx != 0 || vy != 0 else { return 0 }
        var a = atan2(vx, -vy) - from.facing.angle
        while a > .pi { a -= 2 * .pi }
        while a < -.pi { a += 2 * .pi }
        return a * 180 / .pi
    }

    static func distance(_ a: Thing, _ b: Thing) -> Double {
        let (ax, ay) = a.centre, (bx, by) = b.centre
        return ((ax - bx) * (ax - bx) + (ay - by) * (ay - by)).squareRoot()
    }

    /// What stands between two things and hides one from the other (its name), or nil.
    static func viewBlocker(_ room: Room, from a: Thing, to b: Thing) -> String? {
        let skip = Set([a.id, b.id] + [a.on, b.on].compactMap { $0 })
        let between = line(Cell(x: a.x, y: a.y), Cell(x: b.x, y: b.y))
        for c in between {
            if let t = room.things.first(where: { !$0.isPerson && $0.blocks.view && !skip.contains($0.id) && $0.cells.contains(c) }) { return t.name }
        }
        return nil
    }

    /// How the one at `from` (usually the player) perceives `to`.
    static func seen(_ room: Room, from: Thing, to: Thing) -> Seen {
        if to.on == from.id || from.on == to.id { return .front }
        let a = abs(angle(from: from, to: to))
        if a > 110 { return .behind }
        if let b = viewBlocker(room, from: from, to: to) { return .hidden(b) }
        return a <= 60 ? .front : .side
    }

    /// "in front of you, 2 m", "to your left, 3 m", "behind you".
    static func whereFrom(_ from: Thing, to: Thing) -> String {
        let a = angle(from: from, to: to)
        let m = max(1, Int(distance(from, to).rounded()))
        let side: String
        if abs(a) <= 30 { side = "in front of you" }
        else if abs(a) <= 110 { side = a < 0 ? "to your left" : "to your right" }
        else { side = "behind you" }
        return side + ", \(m) m"
    }

    /// Whether `a` is turned toward `b` (within 45 degrees).
    static func faces(_ a: Thing, _ b: Thing) -> Bool { abs(angle(from: a, to: b)) <= 45 }
    static func faceEachOther(_ a: Thing, _ b: Thing) -> Bool { faces(a, b) && faces(b, a) }

    /// The way from one square to another on foot, avoiding whatever blocks the way (nil if there is none).
    static func path(_ room: Room, from a: Cell, to b: Cell, ignoring: Set<UUID> = []) -> [Cell]? {
        let solid = room.solid(except: ignoring)
        guard room.contains(a), room.contains(b) else { return nil }
        var prev: [Cell: Cell] = [:]
        var seen: Set<Cell> = [a]
        var queue = [a]
        var i = 0
        while i < queue.count {
            let c = queue[i]; i += 1
            if c == b {
                var out = [b]
                var k = b
                while let p = prev[k], p != a { out.append(p); k = p }
                return out.reversed()
            }
            for f in [Facing.n, .e, .s, .w] {
                let n = Cell(x: c.x + f.dx, y: c.y + f.dy)
                guard room.contains(n), !seen.contains(n), !solid.contains(n) || n == b else { continue }
                seen.insert(n); prev[n] = c; queue.append(n)
            }
        }
        return nil
    }

    /// What is in the way of walking straight from `a` to `b` (the first thing that blocks the way), or nil.
    static func wayBlocker(_ room: Room, from a: Thing, to b: Thing) -> String? {
        let skip = Set([a.id, b.id] + [a.on, b.on].compactMap { $0 })
        for c in line(Cell(x: a.x, y: a.y), Cell(x: b.x, y: b.y)) {
            if let t = room.things.first(where: { !$0.isPerson && $0.blocks.way && !skip.contains($0.id) && $0.cells.contains(c) }) { return t.name }
        }
        return nil
    }

    /// Whether every door can still be reached from every other one.
    static func doorsConnected(_ room: Room, solid: Set<Cell>) -> Bool {
        let starts = room.doors.map { room.cells(of: $0).first ?? Cell(x: 0, y: 0) }
        guard let first = starts.first, starts.count > 1 else { return true }
        var seen: Set<Cell> = [first]
        var queue = [first]
        var i = 0
        while i < queue.count {
            let c = queue[i]; i += 1
            for f in [Facing.n, .e, .s, .w] {
                let n = Cell(x: c.x + f.dx, y: c.y + f.dy)
                guard room.contains(n), !seen.contains(n), !solid.contains(n) else { continue }
                seen.insert(n); queue.append(n)
            }
        }
        return starts.allSatisfy { seen.contains($0) }
    }

    /// The room as text, for the story export: one character per square.
    static func ascii(_ room: Room) -> String {
        // Columns and rows are numbered (x across from the west wall, y down from the north wall).
        var rows = Array(repeating: Array(repeating: Character("."), count: room.width), count: room.depth)
        var key: [String] = []
        for o in room.windows { for c in room.cells(of: o) where room.contains(c) { rows[c.y][c.x] = "=" } }
        for o in room.doors { for c in room.cells(of: o) where room.contains(c) { rows[c.y][c.x] = "+" } }
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        var letterOf: [UUID: Character] = [:]
        for (n, t) in room.objects.enumerated() {
            let ch = n < letters.count ? letters[n] : "#"
            letterOf[t.id] = ch
        }
        for t in room.objects where t.on == nil { for c in t.cells where room.contains(c) { rows[c.y][c.x] = letterOf[t.id] ?? "#" } }
        for t in room.objects where t.on != nil { if room.contains(Cell(x: t.x, y: t.y)) { rows[t.y][t.x] = letterOf[t.id] ?? "o" } }
        var used: Set<Character> = Set(letters)
        used.formUnion(["+", "=", ".", "@", "#"])
        for t in room.people {
            guard room.contains(Cell(x: t.x, y: t.y)) else { continue }
            var ch: Character = "@"
            if t.kind != .player {
                let initial = t.name.uppercased().first ?? "P"
                ch = used.contains(initial) ? (Array("PQRSTUVWXYZ").first { !used.contains($0) } ?? "P") : initial
                used.insert(ch)
            }
            rows[t.y][t.x] = ch
            var line = "\(ch) \(t.kind == .player ? "you" : t.name) at (\(t.x),\(t.y)), facing \(t.facing.word)"
            if let seat = room.thing(t.on) { line += ", on " + seat.name }
            if !t.holding.isEmpty { line += ", holding " + t.holding.joined(separator: ", ") }
            key.append(line)
        }
        for t in room.objects {
            var line = "\(letterOf[t.id] ?? "#") \(t.name) [\(t.icon)] at (\(t.x),\(t.y))"
            if t.w > 1 || t.d > 1 { line += ", \(t.w)×\(t.d) m" }
            if let base = room.thing(t.on) { line += ", on " + base.name }
            switch t.blocks { case .both: line += ", blocks way and view"; case .way: line += ", blocks the way"; case .view: line += ", blocks the view"; case .none: break }
            key.append(line)
        }
        for d in room.doors { key.append("+ door, \(d.wall.rawValue) wall at \(d.at)" + (d.leadsTo.isEmpty ? "" : " → " + d.leadsTo)) }
        for w in room.windows { key.append("= window, \(w.wall.rawValue) wall at \(w.at)" + (w.view.isEmpty ? "" : ": " + w.view)) }
        let head = "   " + (0..<room.width).map { String($0 % 10) }.joined()
        let body = rows.enumerated().map { String(format: "%2d ", $0.offset) + String($0.element) }
        return ([head] + body).joined(separator: "\n") + "\n" + key.joined(separator: "\n")
    }
}
