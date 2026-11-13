import Foundation

/// Templates for every type of room, and building a room from a template or from the model's answers.
enum RoomBuilder {
    static let types = ["bar", "café", "kitchen", "bedroom", "office", "shop", "hall", "corridor", "ship's deck", "street", "garden",
                        "clearing", "other"]
    static let sizes: [(String, Int, Int)] = [("small", 4, 4), ("medium", 7, 6), ("large", 10, 8), ("huge", 14, 12)]
    static let outdoor: Set<String> = ["street", "garden", "clearing", "ship's deck"]

    /// One object of a template: its name, kind and zone.
    struct Piece { var name: String; var icon: String; var zone: Zone }

    /// The hand-made layout for each type: its usual size and what is always in it.
    static func template(_ type: String) -> (size: String, pieces: [Piece]) {
        func p(_ n: String, _ i: String, _ z: Zone) -> Piece { Piece(name: n, icon: i, zone: z) }
        switch type {
        case "bar":
            return ("large", [p("the bar", "bar", .wall(.north)), p("bar stool", "stool", .beside("the bar")), p("another bar stool", "stool", .beside("the bar")),
                              p("a table", "table", .centre), p("a chair", "chair", .beside("a table")), p("a corner table", "table", .farCorner),
                              p("bottles", "small", .on("the bar"))])
        case "café":
            return ("medium", [p("the counter", "counter", .wall(.north)), p("a small table", "table", .window), p("a chair", "chair", .beside("a small table")),
                               p("another table", "table", .centre), p("a plant", "plant", .doorCorner)])
        case "kitchen":
            return ("medium", [p("the stove", "fireplace", .wall(.north)), p("the kitchen table", "table", .centre), p("a chair", "chair", .beside("the kitchen table")),
                               p("a cupboard", "shelf", .wall(.east))])
        case "bedroom":
            return ("medium", [p("the bed", "bed", .wall(.north)), p("a wardrobe", "shelf", .wall(.east)), p("a chair", "chair", .window), p("a lamp", "lamp", .farCorner)])
        case "office":
            return ("medium", [p("the desk", "desk", .window), p("a chair", "chair", .beside("the desk")), p("a bookshelf", "shelf", .wall(.east)),
                               p("a lamp", "lamp", .farCorner)])
        case "shop":
            return ("medium", [p("the counter", "counter", .wall(.north)), p("shelves", "shelf", .wall(.east)), p("more shelves", "shelf", .wall(.west))])
        case "hall":
            return ("huge", [p("a long table", "table", .centre), p("a bench", "sofa", .wall(.north)), p("the fireplace", "fireplace", .wall(.east)),
                             p("a pillar", "pillar", .centre)])
        case "corridor":
            return ("small", [p("a lamp", "lamp", .farCorner)])
        case "ship's deck":
            return ("large", [p("the mast", "pillar", .centre), p("crates", "crate", .wall(.east)), p("barrels", "crate", .wall(.west))])
        case "street":
            return ("large", [p("a lamp post", "lamp", .farCorner), p("a bench", "sofa", .wall(.north))])
        case "garden":
            return ("large", [p("a bench", "sofa", .wall(.north)), p("a tree", "plant", .farCorner), p("flower beds", "plant", .doorCorner)])
        case "clearing":
            return ("large", [p("a fallen log", "sofa", .centre), p("a tree", "plant", .farCorner)])
        default:
            return ("medium", [])
        }
    }

    /// The likely type of a place from its name and description.
    static func type(for text: String) -> String {
        let w = Set(text.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init))
        let table: [(String, [String])] = [
            ("bar", ["bar", "pub", "tavern", "saloon", "speakeasy", "inn", "lounge", "club", "cantina"]),
            ("café", ["café", "cafe", "coffee", "tearoom", "diner", "restaurant", "bistro", "bakery"]),
            ("kitchen", ["kitchen", "galley", "scullery"]),
            ("bedroom", ["bedroom", "bedchamber", "cabin", "quarters", "dormitory", "suite", "hotel"]),
            ("office", ["office", "study", "library", "station", "precinct", "lab", "laboratory", "bridge"]),
            ("shop", ["shop", "store", "market", "boutique", "pharmacy", "bookshop", "stall"]),
            ("hall", ["hall", "ballroom", "church", "chapel", "temple", "throne", "lobby", "foyer", "museum", "gallery", "warehouse", "barn"]),
            ("corridor", ["corridor", "hallway", "passage", "tunnel", "stairs", "staircase", "alley"]),
            ("ship's deck", ["deck", "ship", "boat", "pier", "dock", "docks", "wharf", "harbour", "harbor"]),
            ("street", ["street", "road", "avenue", "boulevard", "square", "plaza", "platform", "town", "city", "village"]),
            ("garden", ["garden", "park", "courtyard", "yard", "terrace", "rooftop", "balcony", "orchard"]),
            ("clearing", ["clearing", "forest", "woods", "beach", "field", "meadow", "camp", "cave", "desert", "shore", "hill", "mountain"]),
        ]
        for (t, keys) in table where !w.isDisjoint(with: keys) { return t }
        return "other"
    }

    static func size(_ word: String) -> (Int, Int) {
        let s = sizes.first { word.lowercased().contains($0.0) } ?? sizes[1]
        return (s.1, s.2)
    }

    /// A bare room of a type: walls, one door toward where the player came from, and a window.
    static func shell(name: String, type: String, size: String, from: String) -> Room {
        let (w, d) = Self.size(size)
        var r = Room(name: name, type: type, width: w, depth: d)
        r.doors = [Opening(wall: .south, at: w / 2, leadsTo: from.isEmpty ? "outside" : from)]
        if !outdoor.contains(type), w >= 4 { r.windows = [Opening(wall: .north, at: max(0, w / 2 - 1 + (w > 6 ? 2 : 0)), width: 2)] }
        return r
    }

    /// Puts each template piece in its zone (or the nearest legal spot), logging every decision.
    static func furnish(_ r: inout Room, _ pieces: [Piece]) {
        for pc in pieces {
            guard r.objects.count < 10 else { break }
            let t = Thing(kind: .object, name: pc.name, icon: pc.icon)
            let out = Placer.place(&r, t, zone: pc.zone)
            if out.placed {
                r.log.append("place: " + pc.name + " → " + pc.zone.text)
            } else {
                Placer.fallback(&r, t, near: pc.zone)
                r.log.append("move: " + pc.name + " → " + pc.zone.text + " refused (" + out.reason + "), nearest allowed spot")
            }
        }
    }

    /// A room from its template alone (the model's answers missing or unusable).
    static func fromTemplate(name: String, about: String, from: String) -> Room {
        let ty = type(for: name + " " + about)
        let tp = template(ty)
        var r = shell(name: name, type: ty, size: tp.size, from: from)
        r.inside = about
        r.log.append("shell: " + name + " (" + ty + ", \(r.width) × \(r.depth) m, from the template)")
        furnish(&r, tp.pieces)
        return r
    }

    /// The zone an object most likely goes in when nobody said (its kind's usual place).
    static func defaultZone(_ icon: String, in r: Room) -> Zone {
        switch Rules.rule(icon).place {
        case .wall, .staffWall, .bareWall, .wallOrCorner: return .wall(.east)
        case .corner: return .farCorner
        case .open, .openFar: return .centre
        case .anywhere:
            if Rules.rule(icon).small, let s = r.objects.first(where: { Rules.surfaces.contains($0.icon) }) { return .on(s.name) }
            return .centre
        }
    }

    /// The square just inside a door, for someone coming in through it.
    static func entrance(_ r: Room, from: String) -> Cell {
        let door = r.doors.first { $0.leadsTo.caseInsensitiveCompare(from) == .orderedSame } ?? r.doors.first
        guard let d = door, let c = r.cells(of: d).first else { return Cell(x: r.width / 2, y: r.depth - 1) }
        let inner = r.inward(c, from: d.wall)
        return r.contains(inner) ? inner : c
    }
}

// MARK: - Keeping the grid in step with the story

extension Adventure {
    /// The room the player is in.
    var room: Room? {
        get { roomID.flatMap { id in rooms.first { $0.id == id } } }
        set {
            guard let n = newValue else { return }
            if let i = rooms.firstIndex(where: { $0.id == n.id }) { rooms[i] = n } else { rooms.append(n) }
            roomID = n.id
        }
    }

    /// Brings the grid up to date with where the story says everyone is: the player's room (laid
    /// out from its template the first time), the people in it and the things the story has shown.
    /// Positions already on the grid are kept; only what changed moves. Returns whether anything changed.
    @discardableResult
    mutating func syncGrid() -> Bool {
        let place = location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !place.isEmpty else { return false }
        let beforeRooms = rooms
        let beforeID = roomID
        let previous = room
        var r: Room
        if let found = rooms.first(where: { $0.name.caseInsensitiveCompare(place) == .orderedSame }) {
            r = found
        } else {
            let about: String = Cards.placeCard(self)?.desc ?? ""
            r = RoomBuilder.fromTemplate(name: place, about: about, from: previous?.name ?? "")
        }
        let moved = previous.map { $0.id != r.id } ?? true

        // The player leaves the room they were in and comes in through the door.
        if moved, var old = previous {
            old.things.removeAll { $0.kind == .player }
            if let i = rooms.firstIndex(where: { $0.id == old.id }) { rooms[i] = old }
        }
        let me = playerName.isEmpty ? "You" : playerName
        var player: Thing
        if let p = r.player {
            player = p
        } else {
            player = Thing(kind: .player, name: me)
            let c = RoomBuilder.entrance(r, from: previous?.name ?? "")
            player.x = c.x; player.y = c.y
            player.facing = Facing.toward(dx: r.width / 2 - c.x, dy: r.depth / 2 - c.y) ?? .n
            r.things.append(player)
            r.log.append("enter: you come in")
        }
        player.name = me
        player.holding = carrying
        player.feeling = feels
        player.doing = body
        Placer.put(&r, player)

        // The people here.
        let myFirst = Cards.first(playerName).lowercased()
        let present = whereabouts.filter { w in
            let f = Cards.first(w.name).lowercased()
            return w.here != false && !f.isEmpty && f != myFirst && f != "you"
        }
        let names = Set(present.map { (Cards.card(for: $0, in: self)?.name ?? $0.name).lowercased() })
        let gone = r.things.filter { $0.kind == .person && !names.contains($0.name.lowercased()) }
        for g in gone { r.log.append("leave: " + g.name) }
        r.things.removeAll { $0.kind == .person && !names.contains($0.name.lowercased()) }
        for w in present {
            let card = Cards.card(for: w, in: self)
            let name = card?.name ?? w.name
            guard let pl = r.player else { break }
            var t: Thing
            let isNew: Bool
            if let have = r.things.first(where: { $0.kind == .person && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                t = have; isNew = false
            } else {
                t = Thing(kind: .person, name: name); isNew = true
            }
            let wasAt = t.pastMoves.first ?? ""
            t.doing = w.doing
            t.feeling = feelings[name.lowercased()] ?? t.feeling
            if let c = card, t.backstory.isEmpty { t.backstory = c.desc + (c.privateLife.isEmpty ? "" : " Private: " + c.privateLife) }
            if !w.at.isEmpty, w.at != wasAt { t.pastMoves.insert(w.at, at: 0); t.pastMoves = Array(t.pastMoves.prefix(8)) }
            let engaged = w.engaged == true
            let behind = Cards.behindPlayer(w)
            if isNew {
                if behind {
                    let target = Cell(x: pl.x - pl.facing.dx * 2, y: pl.y - pl.facing.dy * 2)
                    Self.standNear(&r, &t, target)
                } else if engaged {
                    let target = Cell(x: pl.x + pl.facing.dx, y: pl.y + pl.facing.dy)
                    Self.standNear(&r, &t, target)
                } else if let z = Self.zone(from: w.at, in: r) {
                    Placer.placePerson(&r, t, zone: z)
                    let tid = t.id
                    t = r.things.first { $0.id == tid } ?? t
                } else {
                    Placer.placePerson(&r, t, zone: .farCorner)
                    let tid = t.id
                    t = r.things.first { $0.id == tid } ?? t
                }
                r.log.append("enter: " + name + (engaged ? ", with you" : ""))
            } else if engaged, RoomGrid.distance(t, pl) > 2.2 {
                // Turned to: they come within talking distance.
                let target = Cell(x: pl.x + pl.facing.dx, y: pl.y + pl.facing.dy)
                Self.standNear(&r, &t, target)
                r.log.append("move: " + name + " comes over to you")
            }
            Placer.put(&r, t)
            if engaged {
                Placer.turn(&r, t.id, toward: "you")
            }
        }
        // The player turns to whoever they are dealing with (the first of them).
        if let p = r.player, let first = present.first(where: { $0.engaged == true }) {
            let name = Cards.card(for: first, in: self)?.name ?? first.name
            Placer.turn(&r, p.id, toward: name)
        }

        // The things the story has shown here.
        for item in Cards.props(self).prefix(8) where r.named(item) == nil {
            let icon = Rules.icon(for: item)
            let z = RoomBuilder.defaultZone(icon, in: r)
            let t = Thing(kind: .object, name: item, icon: icon)
            let out = Placer.place(&r, t, zone: z)
            if !out.placed { Placer.fallback(&r, t, near: z) }
            r.log.append("place: " + item + " → " + z.text)
        }
        r.log = Array(r.log.suffix(60))
        room = r
        return rooms != beforeRooms || roomID != beforeID
    }

    /// The zone a whereabouts line puts someone in ("at the bar", "by the window"), if it names one.
    static func zone(from at: String, in r: Room) -> Zone? {
        let s = at.lowercased()
        if let z = Zone.parse(s) {
            switch z {
            case .on(let n), .beside(let n), .behind(let n): return r.named(n) == nil ? nil : z
            default: return z
            }
        }
        for o in r.objects where !Rules.rule(o.icon).small {
            let key = o.name.lowercased().replacingOccurrences(of: "the ", with: "")
            if s.contains(key) || s.contains(o.icon) {
                if s.contains("behind"), Rules.staffed.contains(o.icon) { return .behind(o.name) }
                if Rules.seats.contains(o.icon), s.contains("on") || s.contains("sit") { return .on(o.name) }
                return .beside(o.name)
            }
        }
        return nil
    }

    /// Stands someone on the free square nearest a target square.
    static func standNear(_ r: inout Room, _ t: inout Thing, _ target: Cell) {
        let free = Placer.freeCells(r, except: t.id).filter { !r.doorClear.contains($0) }
        let pool = free.isEmpty ? Placer.freeCells(r, except: t.id) : free
        let goal = (Double(target.x) + 0.5, Double(target.y) + 0.5)
        if let c = pool.min(by: { Placer.cellScore($0, goal) < Placer.cellScore($1, goal) }) { t.x = c.x; t.y = c.y; t.on = nil }
    }
}
