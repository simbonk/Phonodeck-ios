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
    /// The month a season part names ("late autumn" → November), for the opening's date line.
    /// Read straight off the story's own time words; empty when they name no season.
    static func monthOf(_ storyTime: String) -> String {
        let t = storyTime.lowercased()
        let table: [(String, [String])] = [
            ("spring", ["March", "April", "May"]), ("summer", ["June", "July", "August"]),
            ("autumn", ["September", "October", "November"]), ("fall", ["September", "October", "November"]),
            ("winter", ["December", "January", "February"]),
        ]
        for (season, months) in table where t.contains(season) {
            if t.contains("early " + season) { return months[0] }
            if t.contains("late " + season) { return months[2] }
            return months[1]
        }
        return ""
    }

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
    /// `full`: their whole look (the opening or a new room). Otherwise only their voice, as a
    /// thing to keep, so the reply doesn't paint the same face and habit every turn.
    static func facingLine(_ w: Whereabout, in a: Adventure, full: Bool = true) -> String {
        let c = Cards.card(for: w, in: a)
        let name = c?.name ?? w.name
        var line = name
        if let role = c?.role, !role.isEmpty { line += " (" + role + ")" }
        let pr = Cards.pronoun(name, in: a)
        if !pr.isEmpty { line += ", " + pr }
        if let c, !c.desc.isEmpty { line += ": " + clip(c.desc, 160) }
        if let c { line += full ? presence(c) : (c.voice.isEmpty ? "" : " Voice (keep it, never describe it again): " + clip(c.voice, 80) + ".") }
        if let g = gridSpot(a, name) {
            line += " Now: " + g + "."
            // What they wear and hold, from the map: only these, so no glasses or hat appear from nowhere.
            if let t = a.room?.named(name) {
                let dress = outfit(t, c)
                let on = [dress.isEmpty ? "" : "wearing " + dress, t.holding.isEmpty ? "" : "holding " + t.holding.joined(separator: " and ")].filter { !$0.isEmpty }
                line += " On them: " + (on.isEmpty ? "only what the card above says" : on.joined(separator: "; ")) + " (nothing more)."
            }
            if let r = a.room, let me = r.player, let t = r.named(name), let b = RoomGrid.wayBlocker(r, from: me, to: t) {
                line += " Between you: " + bare(b) + " (you can talk across it, not walk through it)."
            }
            return line
        }
        let spot = Continuity.placed(w.at) + Cards.facing(w) + (w.doing.isEmpty ? "" : ", " + w.doing)
        if !spot.isEmpty { line += " Now: " + clip(spot, 110) + "." }
        return line
    }

    /// Everything someone has on: their outfit from their card ("an oversized wool cardigan over a
    /// simple dress") plus whatever the map has added since ("a hat"), once.
    static func outfit(_ t: Thing, _ c: LoreEntry?) -> String {
        let base = (c?.wears ?? "").trimmingCharacters(in: .whitespaces)
        let now = t.wearing.trimmingCharacters(in: .whitespaces)
        if base.isEmpty { return now }
        if now.isEmpty || now.lowercased().contains(base.lowercased().prefix(20)) { return now.isEmpty ? base : now }
        if base.lowercased().contains(now.lowercased()) { return base }
        return base + ", " + now
    }

    /// How a person comes across, from their card: look, voice, habit (what they wear is on the
    /// map). Empty when the card has none.
    static func presence(_ c: LoreEntry) -> String {
        let parts = [c.looks.isEmpty ? "" : "Looks: " + clip(c.looks, 90), c.voice.isEmpty ? "" : "Voice: " + clip(c.voice, 80), c.habit.isEmpty ? "" : "Habit: " + clip(c.habit, 80)].filter { !$0.isEmpty }
        return parts.isEmpty ? "" : " " + parts.joined(separator: ". ") + "."
    }

    /// "the bar" from "The long mahogany bar" stays as it is; "a stool" reads as "the stool".
    static func bare(_ n: String) -> String {
        let l = n.lowercased()
        if l.hasPrefix("the ") { return l }
        // "Dolores's chair" stays hers: never "the dolores's chair".
        if n.range(of: #"^[A-Z][a-z]+'s "#, options: .regularExpression) != nil { return n }
        if l.hasPrefix("a ") { return "the " + l.dropFirst(2) }
        if l.hasPrefix("an ") { return "the " + l.dropFirst(3) }
        return "the " + l
    }

    /// Where someone or something is, as the player would put it, read from the room grid: "in front
    /// of you, within reach, on the bar stool, facing you, a tired half-smile". Nil without a grid.
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
        let open = RoomBuilder.outdoor.contains(r.type)
        var s = r.name + ", " + (open ? "in the open air" : RoomGrid.feel(width: r.width, depth: r.depth))
        if !r.inside.isEmpty { s += (open ? ". Here: " : ". Inside: ") + clip(r.inside, 120) }
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
            if kind != "private", words.count >= 2, out.contains(where: { o in
                let w = Cards.keywords(o.text)
                return Double(words.intersection(w).count) >= Double(min(words.count, w.count)) * 0.6
            }) { return }
            // What someone keeps close can hold three sentences; everything else is one short line.
            out.append(Item(kind: kind, text: clip(t, kind == "private" ? 600 : 170)))
        }
        let faced = facing(a)
        let facedCards: [LoreEntry] = faced.compactMap { Cards.card(for: $0, in: a) }
        for c in facedCards {
            // Core lore first (including age, tenure, and origin), then the latest
            // three things learned in talk: what is learned never pushes out who they are.
            let key = c.name.lowercased()
            let theirs = Cards.facts(about: c, in: a)
            let core = Set(a.coreFacts)
            for f in theirs.filter({ core.contains($0) }).prefix(5) { add("person", f) }
            for f in theirs.filter({ !core.contains($0) }).suffix(3) { add("person", f) }
            if let x = a.feelings[key] { add("feeling", c.name + " feels " + x + " about you") }
            if let x = a.wants[key] ?? (c.wants.isEmpty ? nil : c.wants) {
                add("want", "What drives " + c.name + ": " + x + " (let it quietly colour how they listen and speak)")
            }
            if let b = a.between[key], !b.isEmpty { add("between", "Between you and " + c.name + " so far: " + b.suffix(4).joined(separator: "; ")) }
            if let k = a.knows[key], !k.isEmpty { add("knows", c.name + " knows about you: " + k.suffix(4).joined(separator: "; ")) }
            if !c.ties.isEmpty { add("ties", c.name + " and the others here: " + c.ties) }
            // What they carry privately, as deep as the talk has earned: the first always, one more
            // each time the conversation invites them to open up.
            let open = c.depths.prefix(1 + (a.opened[key] ?? 0))
            if !open.isEmpty {
                let cue = open.count > 1
                    ? " (the last one has just come close to the surface; let it come out naturally in their own words if the talk leans there)"
                    : " (colours how they talk; let it surface naturally when the conversation invites it)"
                add("private", "On " + c.name + "'s mind" + cue + ": " + open.joined(separator: " "))
            } else if !c.privateLife.isEmpty {
                add("private", "What " + c.name + " carries privately (shared naturally when the conversation invites it): " + c.privateLife)
            }
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
            for d in r.doors where !d.leadsTo.isEmpty { add("around", "A door on the " + d.wall.rawValue + " side leads to " + d.leadsTo + (d.view.isEmpty ? "" : " (" + clip(d.view, 100) + ")")) }
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
        var p = "You help run an interactive audio story. The player just spoke. Below is every item on the story's cards. For THIS moment only, mark each item \"yes\" if the storyteller needs it to answer exactly what the player said or did, or \"no\" if it does not matter right now. Mark \"yes\" what is about the person they face or what they are talking about. Something the player holds or something around them is \"yes\" only when the player uses it, mentions it, or it is what they asked about."
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

    /// The storyteller's craft guidelines: short, warm, and positive so a small on-device model
    /// stays in natural conversational flow rather than freezing under dozens of prohibitions.
    static func system(_ a: Adventure, nameless: Bool, playerNamed: Bool, age: Int, talk: Bool = false) -> String {
        var s = talk ? """
        You are telling an intimate, grounded audio story in second person, present tense ("you" for the player; spoken dialogue in quotation marks; plain, vivid words that sound great read aloud).

        This is a real conversation between real people, not a script. Let the person the player is talking with feel genuinely alive—warm, specific, opinionated, funny, tired, or guarded in their own distinct voice. They listen closely to what the player actually said, react naturally (a small gesture or look if it fits, then their real spoken words), and follow the human thread of the talk. They share stories, memories, opinions, small details from their life, tease, disagree, or ask something back whenever it genuinely fits the moment.

        Keep the rhythm brisk and conversational for audio: get to their reaction and spoken words quickly instead of pausing for long narrator preamble, and let ordinary back-and-forth land around 70–140 words (longer only when they're truly telling a story).

        Keep it grounded:
        - Stay true to the setting and positions below so nobody teleports and nothing appears from nowhere; don't re-describe scenery or clothes the player already knows unless asked.
        - Never write the player's own spoken words, choices, or feelings, and never call them "the player".
        - Leave natural room for the player to answer—never a list of options.
        """ : """
        You are telling an immersive, grounded audio story in second person, present tense ("you" for the player; spoken dialogue in quotation marks; plain, vivid words that sound great read aloud).

        Make the place and the people feel unmistakably real—ordinary, solid humans with their own rhythms, small habits, and distinct voices. Paint the place richly when the player arrives or looks around; otherwise focus on what changes and how the people react in their own words.

        Keep it grounded:
        - Keep to the physical layout and people below so nothing teleports or appears from nowhere.
        - People react naturally to what the player actually did and said, with real spoken words in quotes.
        - Never write the player's own spoken words, choices, or feelings, and never call them "the player".
        - Leave natural room for the player to respond—never a list of options.
        """
        if nameless { s += "\n- " + Prompts.namelessRule }
        if playerNamed, !a.playerName.isEmpty { s += "\n- The player's name is \(a.playerName) (that is \"you\"; use the name only in other characters' spoken dialogue)." }
        let saved = PlayerDetails.saved
        let pGender = saved.gender.trimmingCharacters(in: .whitespacesAndNewlines)
        let pRomance = a.setup.romance.trimmingCharacters(in: .whitespacesAndNewlines)
        let pInterest = saved.interest.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pGender.isEmpty {
            s += "\n- The player is \(pGender); characters see and address them naturally as such."
        }
        if pRomance.caseInsensitiveCompare("No romance") == .orderedSame {
            s += "\n- Keep the story strictly non-romantic."
        } else {
            let drawn = !pRomance.isEmpty ? pRomance : (!pInterest.isEmpty ? "attracted to \(pInterest)" : "")
            if !drawn.isEmpty {
                s += "\n- Quiet background about the player (never mention directly or push romance): \(drawn). Stay natural and platonic unless the player steers toward flirtation or romance; if they do, let any chemistry match this."
            }
        }
        let feeling = a.setup.feeling.isEmpty ? "whatever the player came for" : a.setup.feeling
        s += "\n\nFEELING TO ACHIEVE: " + feeling
        if age > 0 { s += "\n\n" + Prompts.ageRules(age) }
        var limits: [String] = []
        if !a.setup.avoid.isEmpty { limits.append("The player asked: " + a.setup.avoid) }
        if a.setup.simulator { limits.append("This is an experience with no threat, danger, villain or mystery.") }
        if !limits.isEmpty { s += "\n\nLIMITS:\n" + limits.map { "- " + $0 }.joined(separator: "\n") }
        return s
    }

    /// Clean, human-readable scene & character grounding appended to the `SYSTEM` prompt rather
    /// than stuffed into the user's message. This lets the model treat the conversation history
    /// as a real dialogue while still staying anchored to the room grid and character cards.
    static func sceneContext(_ a: Adventure, arrived: Bool, roomAsked: Bool, talk: Bool,
                             events: [String], kept: [Item], talkTo: String? = nil,
                             also: String = "", reach showReach: Bool = false) -> String {
        var sections: [String] = []

        // 1. Who the player is with right now.
        var faced = facing(a)
        if let to = talkTo, !to.isEmpty {
            let one = faced.filter { Cards.first($0.name).lowercased() == Cards.first(to).lowercased() || $0.name.lowercased().contains(to.lowercased()) }
            if !one.isEmpty { faced = Array(one.prefix(1)) } else { faced = Array(faced.prefix(1)) }
        }
        if !also.isEmpty, !faced.contains(where: { $0.name.caseInsensitiveCompare(also) == .orderedSame }),
           let w = a.whereabouts.first(where: { $0.here != false && $0.name.caseInsensitiveCompare(also) == .orderedSame }) {
            faced.append(w)
        }

        // 2. Spatial grounding from the 1m grid: concise during talk, full room view when moving/exploring/asking.
        let detailed = !talk || arrived || roomAsked
        let ground = GridCheck.grounding(in: a, focused: faced, detailed: detailed, showReach: showReach)
        if !ground.isEmpty {
            sections.append("## RIGHT NOW\n" + ground.joined(separator: "\n"))
        }

        // 3. Arriving in a new place: paint it vividly in natural order.
        if arrived {
            let y = year(a)
            let time = a.storyTime.isEmpty ? (a.clock.map { Continuity.clockText($0) } ?? "") : a.storyTime
            let when = [y, time].filter { !$0.isEmpty }.joined(separator: ", ")
            let r = a.room.flatMap { $0.name.caseInsensitiveCompare(a.location) == .orderedSame ? $0 : nil }
            var arrive = "ARRIVING AT " + (a.location.isEmpty ? "A NEW PLACE" : a.location.uppercased())
                + ": bring the place to life in vivid, sensory prose ("
                + [when.isEmpty ? "" : when, (r?.outside ?? "").isEmpty ? "" : "outside: " + clip(r!.outside, 100), (r?.inside ?? "").isEmpty ? "" : "inside: " + clip(r!.inside, 100)]
                    .filter { !$0.isEmpty }.joined(separator: "; ")
                + ")."
            if let card = Cards.placeCard(a), !card.desc.isEmpty { arrive += " " + clip(card.desc, 200) }
            sections.append(arrive)
        }

        // 4. The person(s) you're with: living portrait (who they are, voice, motivation, relationship, inner life).
        if !faced.isEmpty {
            var who: [String] = []
            for w in faced {
                let c = Cards.card(for: w, in: a)
                let name = c?.name ?? w.name
                var line = name
                if let role = c?.role, !role.isEmpty { line += " (" + role + ")" }
                let pr = Cards.pronoun(name, in: a)
                if !pr.isEmpty { line += ", " + pr }
                if let c, !c.desc.isEmpty {
                    let d = clip(c.desc, 180)
                    line += ": " + d + (d.hasSuffix(".") || d.hasSuffix("!") || d.hasSuffix("?") ? "" : ".")
                }
                if let c {
                    if arrived {
                        line += presence(c)
                    } else {
                        let bits = [c.voice.isEmpty ? "" : "Voice: " + clip(c.voice, 140), c.habit.isEmpty ? "" : "Habit: " + clip(c.habit, 120)].filter { !$0.isEmpty }
                        if !bits.isEmpty { line += " " + bits.joined(separator: ". ") + "." }
                    }
                }
                who.append(line)
            }
            let facingWords = Continuity.wordSet(who.joined(separator: " "))
            let kept1 = kept.filter { !Continuity.grounded($0.text, in: facingWords, share: 0.75) }
            if !kept1.isEmpty {
                who += kept1.map { "- " + $0.text }
            }
            sections.append("## WHO YOU'RE WITH\n" + who.joined(separator: "\n"))
        } else if !kept.isEmpty {
            sections.append("## RELEVANT DETAILS\n" + kept.map { "- " + $0.text }.joined(separator: "\n"))
        }

        // 5. Real events or lookups for this moment (only when non-empty).
        let cleanEvents = events.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !cleanEvents.isEmpty {
            sections.append("## THIS MOMENT\n" + cleanEvents.map { "- " + $0 }.joined(separator: "\n"))
        }

        return sections.joined(separator: "\n\n")
    }

    /// The player's actual turn as the final `user` message: clean and natural so it matches the
    /// preceding conversation history, without wrapping it in a 600-token meta-form.
    static func playerTurn(input: String, parts: (did: String, said: String)?, to: String, also: String) -> String {
        if let p = parts {
            let did = p.did.trimmingCharacters(in: .whitespacesAndNewlines)
            let said = p.said.trimmingCharacters(in: .whitespacesAndNewlines)
            var out: [String] = []
            if !did.isEmpty {
                out.append(did.hasSuffix(".") || did.hasSuffix("!") || did.hasSuffix("?") ? did : did + ".")
            }
            if !said.isEmpty {
                let target = also.isEmpty || to.isEmpty ? to : to + " and " + also
                let lead = out.isEmpty ? "I say" : "Then I say"
                out.append(lead + (target.isEmpty ? "" : " to " + target) + ": \"" + said.replacingOccurrences(of: "\"", with: "'") + "\"")
            } else if !did.isEmpty {
                out.append("(I say nothing aloud.)")
            }
            if !out.isEmpty { return out.joined(separator: " ") }
        }
        return input.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The private note before the player's words: when and where, who they face, this turn's
    /// events from code, and the items marked yes.
    static func lead(_ a: Adventure, input: String, arrived: Bool, events: [String], kept: [Item], instruction: Bool = false, talkTo: String? = nil,
                     to: String = "", also: String = "", reach showReach: Bool = true,
                     parts: (did: String, said: String)? = nil) -> String {
        var l: [String] = ["[FOR THIS MOMENT: private, never mention it]", "WHEN AND WHERE: " + whenWhere(a)]
        // Talking to one person: only fixed facts typed straight in (the city, the weather), the two
        // of you, and nothing else in the room.
        let talk = talkTo != nil
        if talk {
            if !a.setup.place.isEmpty { l.append("CITY: " + clip(a.setup.place, 80)) }
            let outside = a.room.flatMap { $0.name.caseInsensitiveCompare(a.location) == .orderedSame ? $0.outside : nil } ?? ""
            if !outside.isEmpty { l.append("WEATHER (known to the player; don't describe it unless it changes or they ask): " + clip(outside, 100)) }
        } else {
            let room = roomLine(a)
            if !room.isEmpty { l.append((arrived ? "THE ROOM: " : "THE ROOM (already painted; only what changed or what is asked about): ") + room) }
        }
        if arrived {
            // Every new room is grounded first, always in this order: when, outside, inside.
            let y = year(a)
            let time = a.storyTime.isEmpty ? (a.clock.map { Continuity.clockText($0) } ?? "") : a.storyTime
            let when = [y, time].filter { !$0.isEmpty }.joined(separator: ", ")
            let r = a.room.flatMap { $0.name.caseInsensitiveCompare(a.location) == .orderedSame ? $0 : nil }
            // Every new room, the opening included, is grounded the same way and said plainly: the
            // date, the city, the weather, the room. It is an interactive story, and the feeling is
            // what it is for.
            let month = monthOf(a.storyTime)
            let date = [y, month, a.storyTime.components(separatedBy: ",").first ?? ""].filter { !$0.isEmpty }.joined(separator: ", ")
            var g = (instruction ? "OPENING" : "ARRIVING") + ": this is an interactive audio story; the player hears it and answers you, so it ends with room for them. Make it feel completely real, like stepping into a film: weave these into living prose, in this order, never as a list: "
            g += "1) the date and the time of day" + (date.isEmpty ? (when.isEmpty ? "" : " (" + when + ")") : " (" + date + ")") + "; "
            let cityFrom = a.setup.world.isEmpty ? a.setup.place : a.setup.world
            g += "2) the city" + (cityFrom.isEmpty ? "" : " (as the story gives it: " + clip(cityFrom, 60) + ")") + "; "
            g += "3) the weather outside" + ((r?.outside ?? "").isEmpty ? "" : " (" + clip(r!.outside, 120) + ")") + "; "
            // Everyone the map has in the room, by name (names the player hasn't heard become roles
            // later), with what they are doing: each gets a line, even someone behind you.
            var here: [String] = []
            if let r, let me = r.player {
                for p in r.people where p.id != me.id && p.kind == .person {
                    let d = a.whereabouts.first { $0.name == p.name && $0.here != false }?.doing ?? p.doing
                    here.append(p.name + (gridSpot(a, p.name).map { ", " + $0 } ?? "") + (d.isEmpty ? "" : ", " + clip(d, 60)))
                }
            }
            g += "4) inside " + (a.location.isEmpty ? "this place" : a.location) + ((r?.inside ?? "").isEmpty ? "" : " (" + clip(r!.inside, 120) + ")") + ": "
                + (here.isEmpty ? "who is here and what they are doing, as the map has it. " : "everyone here, each caught in one true detail (their look, their voice, a habit): " + here.joined(separator: "; ") + ". ")
                + "People move and talk like real people: their own rhythm and words, small imperfect habits, things left unsaid. "
            g += "Then the rest. Every line serves the feeling: " + (a.setup.feeling.isEmpty ? "what the player came for" : a.setup.feeling) + "."
            l.append(g)
            if let card = Cards.placeCard(a), !card.desc.isEmpty { l.append("THE PLACE: " + clip(card.desc, 200)) }
        }
        var faced = facing(a)
        if let to = talkTo, !to.isEmpty {
            let one = faced.filter { Cards.first($0.name).lowercased() == Cards.first(to).lowercased() || $0.name.lowercased().contains(to.lowercased()) }
            if !one.isEmpty { faced = Array(one.prefix(1)) } else { faced = Array(faced.prefix(1)) }
        }
        // Spoken to together with them ("both of you"): the second person is in the moment too,
        // not one of the quiet others.
        if !also.isEmpty, !faced.contains(where: { $0.name.caseInsensitiveCompare(also) == .orderedSame }),
           let w = a.whereabouts.first(where: { $0.here != false && $0.name.caseInsensitiveCompare(also) == .orderedSame }) {
            faced.append(w)
        }
        // Always: where you are and where the person you face is, read off the map, and whether
        // they can reach you. The reply keeps to it (no offering a seat to someone already seated,
        // no touching across a bar).
        if let r = a.room, let me = r.player {
            // Without the "facing <name>" part: a name the player hasn't heard stays out of the reply.
            let spot = youAt(r, me).components(separatedBy: ", facing").first ?? ""
            var line = "WHERE YOU ARE (from the map, always true): you are " + spot
            if let f = faced.first, let t = r.named(f.name) {
                line += "; the person you face is " + (gridSpot(a, f.name) ?? "near you")
                let d = RoomGrid.distance(me, t)
                if d > 1.5 {
                    // Said as a stage direction, not a rule: a small storyteller echoes rules into the prose.
                    line += d > 3 ? ". You talk across the room; to hand you something they would walk over" : ". A few steps apart; to hand you something they would come round"
                    if let between = r.objects.first(where: { Rules.staffed.contains($0.icon) && $0.on == nil && RoomGrid.distance($0, me) < 1.6 && RoomGrid.distance($0, t) < 1.6 }) {
                        line += " or slide it across " + bare(between.name)
                    }
                }
                if me.on != nil { line += ". You are already seated" }
                // Straight from the grid, no question asked: what lies between you, and what is
                // within their reach (on the bar, in their hands).
                let (ax, ay) = me.centre, (bx, by) = t.centre
                func offLine(_ o: Thing) -> Double {
                    let dx = bx - ax, dy = by - ay, len2 = max(0.0001, dx * dx + dy * dy)
                    let k = max(0, min(1, ((o.centre.x - ax) * dx + (o.centre.y - ay) * dy) / len2))
                    return hypot(o.centre.x - (ax + k * dx), o.centre.y - (ay + k * dy))
                }
                let between = r.objects.filter { o in o.icon != "rug" && o.id != me.on && o.id != t.on && o.on == nil && offLine(o) < 0.8 }.map { bare($0.name) }
                // Whose each thing is, when it is someone's: "the ledger (theirs)", "the needle (Dolores's)".
                func whose(_ o: Thing) -> String {
                    guard let w = o.owner, !w.isEmpty, !bare(o.name).lowercased().hasPrefix(Cards.first(w).lowercased() + "'s") else { return bare(o.name) }
                    return bare(o.name) + (w == t.name ? " (theirs)" : " (" + Cards.first(w) + "'s)")
                }
                let reach = r.objects.filter { o in o.icon != "rug" && o.id != t.on && RoomGrid.distance(o, t) < 1.6 }.map(whose) + t.holding
                var seenNames = Set<String>()
                let between1 = between.filter { seenNames.insert($0.lowercased()).inserted }
                let reach1 = reach.filter { seenNames.insert($0.lowercased()).inserted }
                if !between1.isEmpty { line += ". Between you: " + between1.prefix(4).joined(separator: ", ") }
                // Only on a turn where something is picked up, put down, fetched or walked to. In
                // plain talk the room's props stay out of it (tongs within reach ended up in a
                // story about a storm); just what is in their hands.
                if showReach {
                    if !reach1.isEmpty { line += ". Within their reach: " + reach1.prefix(6).joined(separator: ", ") }
                } else if !t.holding.isEmpty {
                    line += ". In their hands: " + t.holding.joined(separator: ", ")
                }
            }
            l.append(line + ".")
            // Always, on every turn: everyone else in the room and what is in it, one short line,
            // straight from the map. A sudden "who else is here?" or "what's that music?" finds
            // its answer here, and nobody is invented.
            let facedIDs = Set(faced.compactMap { r.named($0.name)?.id })
            var others: [String] = []
            for p in r.people where p.id != me.id && !facedIDs.contains(p.id) {
                let w = a.whereabouts.first { $0.name == p.name && $0.here != false }
                let c = w.flatMap { Cards.card(for: $0, in: a) }
                var o = p.name
                if let role = c?.role, !role.isEmpty { o += " (" + role + ")" }
                // So a quiet bystander keeps the right "he" or "she" when the reply mentions them.
                let pr = Cards.pronoun(c?.name ?? p.name, in: a)
                if !pr.isEmpty { o += " [" + pr + "]" }
                o += ": " + (gridSpot(a, p.name) ?? "in the room")
                if let d = w?.doing, !d.isEmpty { o += ", " + clip(d, 50) }
                if let c, !c.looks.isEmpty { o += " (" + clip(c.looks, 70) + ")" }
                others.append(o)
            }
            l.append("ALSO HERE (from the map; they stay quiet unless the player turns to them): " + (others.isEmpty ? "nobody else." : others.joined(separator: "; ") + "."))
            let things = r.objects.filter { $0.icon != "rug" }.map { o -> String in
                guard let w = o.owner, !w.isEmpty, !bare(o.name).lowercased().hasPrefix(Cards.first(w).lowercased() + "'s") else { return bare(o.name) }
                return bare(o.name) + " (" + Cards.first(w) + "'s)"
            }
            var seenThing = Set<String>()
            let things1 = things.filter { seenThing.insert($0.lowercased()).inserted }
            if !things1.isEmpty { l.append("IN THE ROOM: " + things1.prefix(10).joined(separator: ", ") + ".") }
        }
        // A card line the FACING line already says ("saves every nickel") isn't given twice: said
        // twice in the prompt, it came back twice in the story.
        let facingWords = Continuity.wordSet(faced.map { facingLine($0, in: a) + " " + $0.name }.joined(separator: " "))
        let kept1 = kept.filter { faced.isEmpty || !Continuity.grounded($0.text, in: facingWords, share: 0.75) }
        if talk {
            // A talk is laid out in three parts that don't overlap: the scene (above), the person
            // you face with everything on their card, then what this turn asks of them, last, right
            // above the player's words.
            l.insert("[THE SCENE]", at: 1)
            l.append("")
            l.append("[THE PERSON YOU FACE]")
            l += faced.isEmpty ? ["Nobody in particular."] : faced.map { facingLine($0, in: a, full: arrived) }
            if !kept1.isEmpty { l.append("What they know and what is on their card (true; they keep to it):"); l += kept1.map { "- " + $0.text } }
            if !events.isEmpty {
                l.append("")
                l.append("[THIS TURN]")
                l += events.map { "- " + $0 }
            }
        } else {
            if faced.isEmpty {
                l.append("FACING: nobody in particular.")
            } else {
                l.append("FACING (they react: first what they do, then what they say):")
                l += faced.map { "- " + facingLine($0, in: a, full: arrived) }
            }
            if !events.isEmpty { l += events.map { "- " + $0 } }
            if !kept1.isEmpty { l.append("ALSO RELEVANT:"); l += kept1.map { "- " + $0.text } }
        }
        l.append("[END]")
        if instruction { return l.joined(separator: "\n") + "\n\nINSTRUCTION: " + input }
        // The hand-off: the player's own words, exactly as they sent them, to the person they
        // face, then the narrator's turn. A small model answers a line of dialogue far better than
        // a summary of one.
        let who = also.isEmpty || to.isEmpty ? to : to + " and " + also  // a name not said yet is swapped for their role with the rest of the prompt
        let pr = to.isEmpty || !also.isEmpty ? "" : Cards.pronoun(to, in: a)
        let words = input.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\"", with: "'")
        var tail = "PLAYER" + (who.isEmpty ? "" : " (to " + who + ")") + ": \"" + words + "\""
        tail += "\nNARRATOR (" + (who.isEmpty ? "what happens next"
            : who + (pr.isEmpty ? "" : " (" + pr + ")") + "'s brief physical reaction, then their spoken answer in quotes, straight to what the player said") + "; never write \"I say\"):"
        // Hands-free in two parts: the silent action plainly, the spoken words in quotes, never mixed.
        if let p = parts {
            let did = p.did.replacingOccurrences(of: "\"", with: "'")
            let said = p.said.replacingOccurrences(of: "\"", with: "'")
            var t: [String] = []
            if !did.isEmpty { t.append("PLAYER ACTION OR WHAT HAPPENS (silent, not spoken aloud; if someone arrives or something happens, show it happening): " + did) }
            if !said.isEmpty { t.append("PLAYER (speaking aloud" + (who.isEmpty ? "" : " to " + who) + "): \"" + said + "\"") }
            let reply: String
            if said.isEmpty {
                reply = "the action happening, then " + (who.isEmpty ? "how the room answers it" : who + " reacting to the gesture") + ". Nobody answers the action as if it were spoken: the player said nothing"
            } else {
                reply = who.isEmpty ? "what happens next" : (did.isEmpty ? "" : "the action, then ") + who + (pr.isEmpty ? "" : " (" + pr + ")") + "'s brief reaction and spoken answer in quotes, to the words alone"
            }
            tail = t.joined(separator: "\n") + "\nNARRATOR (" + reply + "; never write \"I say\"):"
        }
        return l.joined(separator: "\n") + "\n\n" + tail
    }
}
