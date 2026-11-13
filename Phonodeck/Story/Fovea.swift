import Foundation

/// The foveated story: how every turn picks what the storyteller sees.
///
/// After the read works out what the player meant, every item on the cards is listed and one
/// short question marks each one yes or no for this moment only. The storyteller then sees just
/// three things that are always true (the year, the time and the room), the person the player is
/// facing, and the items marked yes. Everything else stays on its card, untouched, until a later
/// moment needs it. A glass in your hand is left out when you ask someone's name, and comes back
/// the moment you take a sip.
enum Fovea {
    /// One card item the gate can include or leave out.
    struct Item {
        /// What kind of item it is, so the rebuild knows which questions are still worth asking.
        var kind: String
        var text: String
    }

    static func clip(_ s: String, _ n: Int) -> String { s.count <= n ? s : String(s.prefix(n)) + "…" }

    /// The story's year, from the set-up or the opening ("Los Angeles, 1925"), or "".
    static func year(_ a: Adventure) -> String {
        let pool = [a.setup.world, a.setup.describe, a.bible].joined(separator: " ") + " " + a.facts.joined(separator: " ")
        guard let r = pool.range(of: #"\b(1[0-9]{3}|20[0-9]{2})\b"#, options: .regularExpression) else { return "" }
        return String(pool[r])
    }

    /// The three things every reply gets: the year, the time and the room.
    static func whenWhere(_ a: Adventure) -> String {
        var parts: [String] = []
        let y = year(a)
        if !y.isEmpty { parts.append(y) }
        if !a.storyTime.isEmpty { parts.append(a.storyTime) }
        else if let c = a.clock { parts.append(Continuity.clockText(c)) }
        parts.append(a.location.isEmpty ? "On the move, somewhere new" : a.location)
        return parts.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }.joined(separator: ". ") + "."
    }

    /// The people the player is facing (with them and engaged), not the player.
    static func facing(_ a: Adventure) -> [Whereabout] {
        let me = Cards.first(a.playerName).lowercased()
        return a.whereabouts.filter { w in
            let f = Cards.first(w.name).lowercased()
            return w.here != false && w.engaged == true && !f.isEmpty && f != me && f != "you"
        }
    }

    /// The facing person's card line: who they are and where, never their private life.
    static func facingLine(_ w: Whereabout, in a: Adventure) -> String {
        let c = Cards.card(for: w, in: a)
        let name = c?.name ?? w.name
        var line = name
        if let role = c?.role, !role.isEmpty { line += " (" + role + ")" }
        let pr = Cards.pronoun(name, in: a)
        if !pr.isEmpty { line += ", " + pr }
        if let c, !c.desc.isEmpty { line += ": " + clip(c.desc, 160) }
        if let g = gridSpot(a, name) {
            line += " Now: " + g + (w.doing.isEmpty ? "" : ", " + clip(w.doing, 80)) + "."
            if let r = a.room, let me = r.player, let t = r.named(name), let b = RoomGrid.wayBlocker(r, from: me, to: t) {
                line += " Between you: " + bare(b) + " (you can talk across it, not walk through it)."
            }
            return line
        }
        let spot = Continuity.placed(w.at) + Cards.facing(w) + (w.doing.isEmpty ? "" : ", " + w.doing)
        if !spot.isEmpty { line += " Now: " + clip(spot, 110) + "." }
        return line
    }

    /// "the bar" from "The long mahogany bar" stays as it is; "a stool" reads as "the stool".
    static func bare(_ n: String) -> String {
        let l = n.lowercased()
        if l.hasPrefix("the ") { return l }
        if l.hasPrefix("a ") { return "the " + l.dropFirst(2) }
        if l.hasPrefix("an ") { return "the " + l.dropFirst(3) }
        return "the " + l
    }

    /// Where someone or something is, as the player would put it, read from the room grid: "in front
    /// of you, 1 m, on the bar stool, facing you, a tired half-smile". Nil without a grid.
    static func gridSpot(_ a: Adventure, _ name: String) -> String? {
        guard let r = a.room, let me = r.player, let t = r.named(name), t.id != me.id else { return nil }
        var s = RoomGrid.whereFrom(me, to: t)
        if let seat = r.thing(t.on) {
            s += (t.isPerson ? ", sitting on " : ", on ") + bare(seat.name)
        } else if t.isPerson, let by = r.objects.filter({ $0.on == nil && !Rules.rule($0.icon).small && $0.icon != "rug" })
                    .min(by: { RoomGrid.distance($0, t) < RoomGrid.distance($1, t) }), RoomGrid.distance(by, t) < 1.6 {
            let staff = Rules.staffed.contains(by.icon) && Placer.cells(.behind(by.name), in: r).contains(Cell(x: t.x, y: t.y))
            s += (staff ? ", behind " : ", by ") + bare(by.name)
        }
        if t.isPerson {
            if RoomGrid.faces(t, me) {
                s += ", facing you"
            } else if let other = r.things.filter({ $0.id != t.id && $0.id != me.id && $0.icon != "rug" && !Rules.rule($0.icon).small })
                        .filter({ RoomGrid.faces(t, $0) }).min(by: { RoomGrid.distance($0, t) < RoomGrid.distance($1, t) }) {
                s += ", facing " + (other.isPerson ? other.name : bare(other.name))
            } else if abs(RoomGrid.angle(from: t, to: me)) > 110 {
                s += ", turned away from you"
            }
            if !t.expression.isEmpty { s += ", " + clip(t.expression, 60) }
            if !t.holding.isEmpty { s += ", holding " + t.holding.prefix(2).joined(separator: " and ") }
        } else if !t.makeup.isEmpty {
            s += " (" + clip(t.makeup, 50) + ")"
        }
        return s
    }

    /// The room in one line: its name and size, what is happening inside and beyond the windows.
    static func roomLine(_ a: Adventure) -> String {
        guard let r = a.room else { return "" }
        var s = r.name + ", \(r.width) m by \(r.depth) m"
        if !r.inside.isEmpty { s += ". Inside: " + clip(r.inside, 120) }
        if !r.outside.isEmpty { s += ". Outside" + (r.windows.isEmpty ? "" : " the window") + ": " + clip(r.outside, 120) }
        return s + "."
    }

    /// The room as code reads it off the grid, in plain words: the room, where you are and what
    /// you face, each person here, and what is in view, nearest first.
    static func roomView(_ a: Adventure) -> [String] {
        guard let r = a.room, let me = r.player else { return [] }
        var l: [String] = ["THE ROOM: " + roomLine(a)]
        l.append("YOU: " + youAt(r, me) + ".")
        for p in r.people where p.id != me.id {
            switch RoomGrid.seen(r, from: me, to: p) {
            case .hidden(let by): l.append(p.name + ": out of sight behind " + bare(by) + ".")
            default: l.append(p.name + ": " + (gridSpot(a, p.name) ?? "in the room") + ".")
            }
        }
        let inView = r.objects.filter { o in
            guard o.icon != "rug" else { return false }
            switch RoomGrid.seen(r, from: me, to: o) { case .front, .side: return true; default: return false }
        }.sorted { RoomGrid.distance($0, me) < RoomGrid.distance($1, me) }
        if !inView.isEmpty { l.append("IN VIEW: " + inView.prefix(6).map { $0.name + " (" + (gridSpot(a, $0.name) ?? "") + ")" }.joined(separator: "; ") + ".") }
        return l
    }

    /// Where the player is, in words: "at the long mahogany bar, facing the bartender".
    static func youAt(_ r: Room, _ me: Thing) -> String {
        var you: String
        if let seat = r.thing(me.on) { you = "sitting on " + bare(seat.name) } else if let by = r.objects.filter({ $0.on == nil && !Rules.rule($0.icon).small && $0.icon != "rug" })
            .min(by: { RoomGrid.distance($0, me) < RoomGrid.distance($1, me) }), RoomGrid.distance(by, me) < 1.6 {
            you = "at " + bare(by.name)
        } else { you = "standing in the room" }
        if let f = r.people.filter({ $0.id != me.id }).first(where: { RoomGrid.faces(me, $0) }) { you += ", facing " + f.name } else { you += ", facing " + me.facing.word }
        return you
    }

    /// Every card item that could matter to this moment, for the gate to mark.
    static func items(_ a: Adventure, input: String, asking: Bool) -> [Item] {
        var out: [Item] = []
        func add(_ kind: String, _ text: String) {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.count > 2, !out.contains(where: { $0.text == t }) else { return }
            // Near-copies ("a crackling jazz record", "a cracking jazz record"; "You have: wet boots"
            // and "You are wearing wet boots") are offered once.
            let words = Cards.keywords(t)
            if words.count >= 2, out.contains(where: { o in
                let w = Cards.keywords(o.text)
                return Double(words.intersection(w).count) >= Double(min(words.count, w.count)) * 0.6
            }) { return }
            out.append(Item(kind: kind, text: clip(t, 170)))
        }
        let faced = facing(a)
        let facedCards: [LoreEntry] = faced.compactMap { Cards.card(for: $0, in: a) }
        for c in facedCards {
            for f in Cards.facts(about: c, in: a).suffix(3) { add("person", f) }
            if let x = a.feelings[c.name.lowercased()] { add("feeling", c.name + " feels " + x + " about you") }
            if let x = a.wants[c.name.lowercased()] { add("want", c.name + " wants " + x + " (it shows in what they do; unsaid unless asked)") }
            if let b = a.between[c.name.lowercased()], !b.isEmpty { add("between", "Between you and " + c.name + " so far: " + b.suffix(3).joined(separator: "; ")) }
            if let k = a.knows[c.name.lowercased()], !k.isEmpty { add("knows", c.name + " knows about you: " + k.suffix(3).joined(separator: "; ")) }
            // Their private life is always offered (hearing it is often why the player came); the
            // pass lets it in when the moment turns to their life, and they share only a little.
            if !c.privateLife.isEmpty { add("private", c.name + "'s private life (shared a little, only if the player asks about their life, work, hopes or plans): " + c.privateLife) }
        }
        // Everyone else keeps their own card; it is offered as one item each.
        let me = Cards.first(a.playerName).lowercased()
        for w in a.whereabouts {
            let f = Cards.first(w.name).lowercased()
            guard !f.isEmpty, f != me, f != "you", !faced.contains(where: { $0.name == w.name }) else { continue }
            let c = Cards.card(for: w, in: a)
            let name = c?.name ?? w.name
            let role: String = c.map { $0.role.isEmpty ? "" : " (" + $0.role + ")" } ?? ""
            let theirs: [String] = c.map { Array(Cards.facts(about: $0, in: a).suffix(2)) } ?? []
            if w.here == false {
                guard c.map({ Cards.mentions($0, in: input) }) ?? input.lowercased().contains(f) else { continue }
                add("other", name + role + " is " + Continuity.placed(w.at) + ", not here: they can be talked about, not seen or heard.")
            } else if let r = a.room, let you = r.player, let t = r.named(name) {
                // The grid decides what the player can perceive.
                switch RoomGrid.seen(r, from: you, to: t) {
                case .behind:
                    add("other", name + role + " is behind you, out of sight: only heard, never described.")
                case .hidden(let by):
                    add("other", name + role + " is behind " + bare(by) + ": you can hear them, not see them.")
                case .front, .side:
                    let doing = w.doing.isEmpty ? "" : ", " + w.doing
                    add("other", name + role + " is " + (gridSpot(a, name) ?? "in the room") + doing + (theirs.isEmpty ? "." : ". " + theirs.joined(separator: " ")))
                }
            } else if Cards.behindPlayer(w) {
                add("other", name + role + " is behind you, out of sight: only heard, never described.")
            } else {
                let doing = w.doing.isEmpty ? "" : ", " + w.doing
                add("other", name + role + " is also in the room" + doing + (theirs.isEmpty ? "." : ". " + theirs.joined(separator: " ")))
            }
        }
        // Who the player is: offered, not always sent (it matters when someone asks about them).
        let whoAmI: String = Cards.premise(a).components(separatedBy: "\n").first(where: { $0.hasPrefix("The player is ") }) ?? ""
        if !whoAmI.isEmpty { add("you", "Who you are: " + String(whoAmI.dropFirst("The player is ".count))) }
        for t in a.carrying.prefix(6) { add("have", "You have: " + t) }
        if let r = a.room, let you = r.player {
            // What the player can see from where they stand, nearest first; hidden things stay out.
            let inView = r.objects.filter { o in
                guard o.icon != "rug" else { return false }
                switch RoomGrid.seen(r, from: you, to: o) { case .front, .side: return true; default: return false }
            }.sorted { RoomGrid.distance($0, you) < RoomGrid.distance($1, you) }
            for o in inView.prefix(5) { add("around", "Around you: " + o.name + ", " + (gridSpot(a, o.name) ?? "")) }
            for d in r.doors where !d.leadsTo.isEmpty { add("around", "A door on the " + d.wall.rawValue + " side leads to " + d.leadsTo) }
            for w in r.windows where !w.view.isEmpty { add("around", "Through the window: " + w.view) }
        } else {
            for t in Cards.props(a).prefix(4) { add("around", "Around you: " + t) }
        }
        for p in a.pending { add("hanging", "Still hanging: " + p) }
        if !a.spot.isEmpty { add("spot", "Where you are in the room: " + a.spot) }
        if let s = a.ambience[a.location.lowercased()], !a.location.isEmpty, !s.isEmpty { add("sound", "The background: " + s) }
        if !a.body.isEmpty { add("body", "How you are: " + a.body) }
        if !a.feels.isEmpty { add("feels", "How you feel: " + a.feels) }
        if let p = a.progress.last { add("goal", "Toward what you came for so far: " + p) }
        let general = a.facts.filter { f in
            !a.cast.contains { f.hasPrefix($0.name + " uses ") || Cards.mentions($0, in: f) } && !Continuity.elsewhereFact(f, in: a)
        }
        for f in general.prefix(4) { add("fact", f) }
        return Array(out.prefix(24))
    }

    /// The gate's question: every item, numbered, marked yes or no for this moment.
    static func gatePrompt(_ a: Adventure, input: String, intent: String, lastReply: String, items: [Item]) -> String {
        var faced: [String] = []
        for w in facing(a) {
            if let c = Cards.card(for: w, in: a), !c.role.isEmpty { faced.append(Continuity.roleLabel(c.role)) } else { faced.append(w.name) }
        }
        var p = "You help run an interactive audio story. The player just spoke. Below is every item on the story's cards. For THIS moment only, mark each item \"yes\" if the storyteller needs it to answer exactly what the player said or did, or \"no\" if it does not matter right now. Most items are \"no\". Something the player holds or something around them is \"yes\" only when the player uses it, mentions it, or it is what they asked about."
        p += "\n\nWHEN AND WHERE: " + whenWhere(a)
        p += "\nTHE PLAYER IS FACING: " + (faced.isEmpty ? "nobody in particular" : faced.joined(separator: ", "))
        if !lastReply.isEmpty { p += "\n\nTHE STORY JUST SAID (context only):\n…" + String(lastReply.suffix(350)) }
        p += "\n\nTHE PLAYER'S NEW MESSAGE: " + clip(input, 600)
        if !intent.isEmpty { p += "\nWHAT THEY ARE DOING: " + intent }
        p += "\n\nITEMS:\n" + items.enumerated().map { "\($0.offset + 1). " + $0.element.text }.joined(separator: "\n")
        p += "\n\nOutput ONLY one JSON object with \"yes\" or \"no\" for every item number.\nThe form:"
        return p
    }

    /// Which items the gate marked yes. Anything the player's own words name is always yes; with
    /// no usable answer, only those are kept.
    static func chosen(_ items: [Item], answer m: [String: Any], input: String) -> [Bool] {
        let said = Cards.keywords(input)
        var out: [Bool] = []
        for (i, item) in items.enumerated() {
            let named = !said.isDisjoint(with: Cards.keywords(item.text))
            let yes = ((m[String(i + 1)] as? String) ?? "").lowercased() == "yes"
            out.append(named || yes)
        }
        return out
    }

    /// What the read says the player is doing, in one plain line, from its fixed fields.
    static func intent(_ r: PlayerIntent) -> String {
        var parts: [String] = []
        if !r.to.isEmpty { parts.append("speaking to " + r.to) }
        if !r.going.isEmpty { parts.append("going " + (r.going == "somewhere new" ? (r.newPlace.isEmpty ? "somewhere new" : "to " + r.newPlace) : "to " + r.going)) }
        if !r.takes.isEmpty { parts.append("taking " + r.takes) }
        if !r.putsDown.isEmpty { parts.append("putting down " + r.putsDown) }
        if !r.tells.isEmpty { parts.append("telling them " + r.tells) }
        return parts.joined(separator: "; ")
    }

    /// The read's fields the intent line uses (kept apart from the engine's private type).
    struct PlayerIntent {
        var to = "", going = "", newPlace = "", takes = "", putsDown = "", tells = ""
    }

    /// The storyteller's rules in this mode: short, and the facing person always reacts with what
    /// they do, then what they say.
    static func system(_ a: Adventure, nameless: Bool, playerNamed: Bool, age: Int) -> String {
        var s = """
        You are the storyteller of an audio story the player hears read aloud: their vacation from reality.

        - Second person, present tense: the player is "you". 60 to 140 words of plain, vivid words that are easy to hear. No headings, lists or notes.
        - The person the player is facing reacts to exactly what the player said or did: first what they do, then what they say. Let them be warm, real and specific, with their own way of talking.
        - Never speak, choose or feel for the player.
        - Use only the people and things given for this moment. Anyone else stays quiet and out of the way, and nothing appears from nowhere.
        - People keep their private lives to themselves unless the player asks.
        - End on the person turned to the player, leaving room to answer. Never a list of options.
        """
        if nameless { s += "\n- " + Prompts.namelessRule }
        if playerNamed, !a.playerName.isEmpty { s += "\n- The player character is \(a.playerName), and that is \"you\". The name appears only in other characters' dialogue." }
        let feeling = a.setup.feeling.isEmpty ? "whatever the player came for" : a.setup.feeling
        s += "\n\nFEELING TO ACHIEVE: " + feeling
        if age > 0 { s += "\n\n" + Prompts.ageRules(age) }
        var limits: [String] = []
        if !a.setup.avoid.isEmpty { limits.append("The player asked: " + a.setup.avoid) }
        if a.setup.simulator { limits.append("This is an experience with no threat, danger, villain or mystery.") }
        if !limits.isEmpty { s += "\n\nLIMITS (never break them):\n" + limits.map { "- " + $0 }.joined(separator: "\n") }
        return s
    }

    /// The private note before the player's words: when and where, who they face, this turn's
    /// events from code, and the items marked yes.
    static func lead(_ a: Adventure, input: String, arrived: Bool, events: [String], kept: [Item], instruction: Bool = false) -> String {
        var l: [String] = ["[FOR THIS MOMENT: private, never mention it]", "WHEN AND WHERE: " + whenWhere(a)]
        let room = roomLine(a)
        if !room.isEmpty { l.append("THE ROOM: " + room) }
        if arrived {
            // Every new room is grounded first, always in this order: when, outside, inside.
            let y = year(a)
            let time = a.storyTime.isEmpty ? (a.clock.map { Continuity.clockText($0) } ?? "") : a.storyTime
            let when = [y, time].filter { !$0.isEmpty }.joined(separator: ", ")
            let r = a.room.flatMap { $0.name.caseInsensitiveCompare(a.location) == .orderedSame ? $0 : nil }
            var g = "ARRIVING: ground the listener first, in this order, a sentence each: "
            g += "1) the date and time" + (when.isEmpty ? "" : " (" + when + ")") + "; "
            g += "2) what is happening outside" + ((r?.outside ?? "").isEmpty ? " (the weather, the street)" : " (" + clip(r!.outside, 120) + ")") + "; "
            g += "3) what is happening inside " + (a.location.isEmpty ? "this place" : a.location) + ((r?.inside ?? "").isEmpty ? " (who is here and what they are doing)" : " (" + clip(r!.inside, 120) + ")") + ". Then the rest."
            l.append(g)
            if let card = Cards.placeCard(a), !card.desc.isEmpty { l.append("THE PLACE: " + clip(card.desc, 200)) }
        }
        let faced = facing(a)
        if faced.isEmpty {
            l.append("FACING: nobody in particular.")
        } else {
            l.append("FACING (they react: first what they do, then what they say):")
            l += faced.map { "- " + facingLine($0, in: a) }
        }
        if !events.isEmpty { l += events.map { "- " + $0 } }
        if !kept.isEmpty { l.append("ALSO RELEVANT:"); l += kept.map { "- " + $0.text } }
        l.append("[END]")
        return l.joined(separator: "\n") + "\n\n" + (instruction ? "INSTRUCTION: " : "THE PLAYER: ") + input
    }
}
