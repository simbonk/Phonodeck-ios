import Foundation

/// The grounded engine's world store and its fetch.
///
/// The world lives in the app as cards: a place card for each place, a card for each person, item
/// and faction (the lore), the facts, who is where, what the player has and what each place holds.
/// Facts are filed under the card they are about by name, the way the World panel shows them.
///
/// Each reply the storyteller sees only the cards the player's action touches: the place they are
/// in, the person they are dealing with (with that person's facts), one line for anyone else in
/// the room, and whatever the player's message is about. Everything else stays in the app.
enum Cards {
    /// What was fetched for one reply, and why (the "why" lines go into the story export).
    struct Pick {
        /// The place card: its name and what it is like.
        var place = ""
        /// Full cards: the people the player is dealing with right now.
        var with: [String] = []
        /// One line each: people in the room the player is not dealing with.
        var background: [String] = []
        /// People somewhere else whom the player's message mentions.
        var away: [String] = []
        /// Other cards the message is about (a place, an item, someone not placed yet).
        var about: [String] = []
        /// Facts that are not about any person fetched above, picked for this moment.
        var facts: [String] = []
        /// The notable things in the place.
        var props: [String] = []
        /// Every fact fetched (people's included), for the read's KNOWN list.
        var known: [String] = []
        /// The message reaches for something with no card: older moments are searched.
        var recall = false
        /// One line per fetched card: what it was and why it was fetched.
        var why: [String] = []
    }

    static func clip(_ s: String, _ n: Int) -> String { s.count <= n ? s : String(s.prefix(n)) + "…" }
    static func first(_ name: String) -> String { name.split(separator: " ").first.map(String.init) ?? name }

    /// Words worth matching on: four letters or more, and not the small words every sentence has.
    static func keywords(_ s: String) -> Set<String> {
        let plain: Set<String> = ["that", "this", "with", "from", "have", "what", "when", "where", "there", "their", "they", "them", "then",
                                  "about", "would", "could", "should", "which", "after", "before", "other", "these", "those", "while",
                                  "every", "under", "really", "think", "going", "something", "anything", "right", "still", "again", "your",
                                  "yours", "just", "like", "into", "over", "some", "here", "back", "want", "tell", "know", "look", "said",
                                  "says", "asks", "does", "will", "been", "were", "very", "much", "more", "also", "only", "even"]
        return Continuity.wordSet(s).filter { $0.count >= 4 && !plain.contains($0) }
    }

    /// Whether a text speaks of a person: their full name, their first name, or their role.
    static func mentions(_ p: LoreEntry, in text: String) -> Bool {
        let t = text.lowercased()
        if !p.name.isEmpty, t.contains(p.name.lowercased()) { return true }
        let f = first(p.name).lowercased()
        if f.count >= 3, Continuity.wordSet(t).contains(f) { return true }
        guard !p.role.isEmpty else { return false }
        let role = Continuity.roleLabel(p.role).lowercased().replacingOccurrences(of: "the ", with: "")
        return role.count >= 4 && t.contains(role)
    }

    /// "she/her" from "Dolores Vega uses she/her.", or "".
    static func pronoun(_ name: String, in a: Adventure) -> String {
        guard let f = a.facts.first(where: { $0.hasPrefix(name + " uses ") }) else { return "" }
        return String(f.dropFirst(name.count + 6)).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    }

    /// The facts filed under a person (their pronoun fact aside: the card shows it).
    static func facts(about p: LoreEntry, in a: Adventure) -> [String] {
        a.facts.filter { !$0.hasPrefix(p.name + " uses ") && mentions(p, in: $0) }
    }

    /// The card a whereabouts line belongs to.
    static func card(for w: Whereabout, in a: Adventure) -> LoreEntry? {
        a.cast.first { $0.name.caseInsensitiveCompare(w.name) == .orderedSame }
            ?? a.cast.first { first($0.name).caseInsensitiveCompare(first(w.name)) == .orderedSame }
    }

    /// Items and factions the story has not brought up yet stay locked: the read can't pick them
    /// and nothing offers them to the storyteller.
    static func locked(_ a: Adventure, spoken: String) -> Set<String> {
        Set(a.lore.filter { ($0.kind == .item || $0.kind == .faction) && !$0.byPlayer && !Continuity.names(place: $0.name, in: spoken) }
            .map { $0.name.lowercased() })
    }

    /// The names the read may say a message is about: every card the world holds (people, places,
    /// items) and the things in this place, minus what is still locked.
    static func menu(_ a: Adventure, input: String) -> [String] {
        let spoken = a.transcript.map(\.text).joined(separator: " ") + " " + input
        let shut = locked(a, spoken: spoken)
        var out: [String] = []
        func add(_ s: String) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, !shut.contains(t.lowercased()), !out.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) else { return }
            out.append(t)
        }
        for e in a.lore where !e.isPlayer { add(e.name) }
        for p in a.places { add(p) }
        for t in props(a) { add(t) }
        return Array(out.prefix(30))
    }

    /// The things in the place the player is in. A place keeps its own things; they never follow
    /// the player from one place into the next.
    static func props(_ a: Adventure) -> [String] {
        a.location.isEmpty ? a.things : (a.placeThings[a.location.lowercased()] ?? (a.placeThings.isEmpty ? a.things : []))
    }

    /// The place card for where the player is, if the world has one.
    static func placeCard(_ a: Adventure) -> LoreEntry? {
        guard !a.location.isEmpty else { return nil }
        return a.lore.first { $0.kind == .place && $0.name.caseInsensitiveCompare(a.location) == .orderedSame }
            ?? a.lore.first { $0.kind == .place && Continuity.names(place: $0.name, in: a.location) }
    }

    /// The premise: two or three sentences that say what this story is and who the player is.
    /// It stands in for the long story bible, whose prose goes stale as soon as the player moves.
    static func premise(_ a: Adventure) -> String {
        var s: [String] = []
        let world = [a.setup.world, a.setup.describe].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !world.isEmpty {
            s.append(clip(world.joined(separator: ". "), 280))
        } else if !a.bible.isEmpty {
            let lead = PresenceFilter.sentences(a.bible).prefix(2).joined(separator: " ")
            s.append(clip(lead, 280))
        }
        let me = a.lore.first(where: \.isPlayer)?.desc ?? ""
        let who = a.setup.who.isEmpty ? me : a.setup.who + (a.setup.traits.isEmpty ? "" : ". " + a.setup.traits)
        if !who.isEmpty { s.append("The player is " + clip(who, 220)) }
        if a.setup.simulator, !a.setup.goal.isEmpty { s.append("What they came for: " + clip(a.setup.goal, 200)) }
        return s.joined(separator: "\n")
    }

    /// Picks the cards for this moment. `about` is what the read said the message is about;
    /// `opening` paints the whole room, so everyone placed there gets their full card.
    static func pick(_ a: Adventure, input: String, about: [String], opening: Bool) -> Pick {
        var p = Pick()
        let me = first(a.playerName).lowercased()
        var fetched: [LoreEntry] = []

        // The place.
        if !a.location.isEmpty {
            let card = placeCard(a)
            p.place = a.location + (card.map { $0.desc.isEmpty ? "" : ": " + clip($0.desc, 260) } ?? "")
            p.why.append("Place card: " + a.location + (card == nil || card?.desc.isEmpty == true ? " (no description yet)" : ""))
            if let card { fetched.append(card) }
        } else {
            p.why.append("Place: not named yet (the player is on the move)")
        }
        p.props = Array(props(a).prefix(6))
        if !p.props.isEmpty { p.why.append("Props here: \(p.props.count)") }

        // The people: full cards for whoever the player is dealing with, one line for the rest of
        // the room, and someone elsewhere only when the message mentions them.
        let others = a.whereabouts.filter { w in
            let f = first(w.name).lowercased()
            return !f.isEmpty && f != me && f != "you"
        }
        let dealing = others.contains { $0.here != false && $0.engaged == true }
        for w in others {
            let c = card(for: w, in: a)
            let name = c?.name ?? w.name
            let pr = pronoun(name, in: a)
            let spot = Continuity.placed(w.at) + (w.doing.isEmpty ? "" : ", " + w.doing)
            let named = c.map { mentions($0, in: input) } ?? input.lowercased().contains(first(w.name).lowercased())
            if w.here != false, opening || !dealing || w.engaged == true || named {
                var line = name + (c.map { $0.role.isEmpty ? "" : " (\($0.role))" } ?? "") + (pr.isEmpty ? "" : ", " + pr)
                if let c, !c.desc.isEmpty { line += ": " + clip(c.desc, 240) }
                line += " Now: " + clip(spot, 140) + "."
                let theirs = c.map { Array(facts(about: $0, in: a).suffix(4)) } ?? []
                if !theirs.isEmpty { line += " Known: " + theirs.map { clip($0, 150) }.joined(separator: " ") }
                p.with.append(line)
                p.known += theirs
                if let c { fetched.append(c) }
                let reason = opening ? "in the opening scene" : w.engaged == true ? "you are dealing with them" : named ? "your message names them" : "in the room with you"
                p.why.append("\(name): full card, \(reason) (\(theirs.count) fact\(theirs.count == 1 ? "" : "s"))")
            } else if w.here != false {
                p.background.append(name + (pr.isEmpty ? "" : " (" + pr + ")") + ": " + clip(spot, 100))
                p.why.append("\(name): one line, in the background")
            } else if named {
                p.away.append("\(name) is \(Continuity.placed(w.at)), not here: they can be talked about, not seen or heard.")
                if let c { fetched.append(c) }
                p.why.append("\(name): elsewhere, mentioned in your message")
            }
        }

        // Whatever the message is about: what the read picked, and any card the message names.
        var wanted = about
        for e in a.lore where !e.isPlayer && !fetched.contains(where: { $0.id == e.id }) {
            let hit = e.kind == .person ? mentions(e, in: input) : Continuity.names(place: e.name, in: input)
            if hit, !wanted.contains(where: { $0.caseInsensitiveCompare(e.name) == .orderedSame }) { wanted.append(e.name) }
        }
        for w in wanted.prefix(4) {
            if let e = a.lore.first(where: { $0.name.caseInsensitiveCompare(w) == .orderedSame && !$0.isPlayer }) {
                guard !fetched.contains(where: { $0.id == e.id }) else { continue }
                fetched.append(e)
                let theirs = Array((e.kind == .person ? facts(about: e, in: a) : a.facts.filter { Continuity.names(place: e.name, in: $0) }).suffix(2))
                var line = e.name + (e.kind == .person && !e.role.isEmpty ? " (\(e.role))" : " (\(e.kind.rawValue))")
                if !e.desc.isEmpty { line += ": " + clip(e.desc, 220) }
                if !theirs.isEmpty { line += " Known: " + theirs.map { clip($0, 150) }.joined(separator: " ") }
                if e.kind == .person, let spot = a.whereabouts.first(where: { card(for: $0, in: a)?.id == e.id }), spot.here == false {
                    line += " (Not here: " + Continuity.placed(spot.at) + ".)"
                }
                p.about.append(line)
                p.known += theirs
                p.why.append("\(e.name): \(e.kind.rawValue) card, your message is about it")
            } else if p.props.contains(where: { $0.caseInsensitiveCompare(w) == .orderedSame }) {
                p.why.append("\(w): a prop here, already in the scene")
            } else {
                p.recall = true
                p.why.append("\(w): no card, older moments searched")
            }
        }

        // Facts not about anyone fetched above: only those that share a telling word with the
        // message (or what it is about). The opening paints the world, so it gets a few more.
        let kw = keywords(input + " " + wanted.joined(separator: " "))
        let general = a.facts.filter { f in
            !a.cast.contains { f.hasPrefix($0.name + " uses ") || mentions($0, in: f) } && !Continuity.elsewhereFact(f, in: a)
        }
        let hits = general.filter { !keywords($0).isDisjoint(with: kw) }
        p.facts = opening ? Array(general.prefix(5)) : Array(hits.suffix(3))
        for f in p.facts {
            let shared = keywords(f).intersection(kw).sorted().prefix(2).joined(separator: ", ")
            p.why.append("Fact: \"\(clip(f, 70))\"" + (opening ? " (opening)" : " (shares: \(shared))"))
        }
        p.known += p.facts

        // Asking after the past reaches for older moments.
        let past = #"(?i)\b(remember|earlier|before|last time|again|back then|yesterday|used to|you said|told me)\b"#
        if !opening, input.range(of: past, options: .regularExpression) != nil {
            p.recall = true
            p.why.append("Your message reaches back: older moments searched")
        }
        return p
    }

    /// The scene as the storyteller reads it: the fetched cards, then the notes, then this moment
    /// (last, right before the player's words, because small models follow what they read last).
    static func briefing(_ a: Adventure, pick p: Pick, memories: [String], extra: [String], notes: [String], moment: String) -> String {
        var l: [String] = ["THE SCENE (the reply must agree with every line)"]
        if !p.place.isEmpty { l.append("- Place: " + p.place) }
        if !a.storyTime.isEmpty { l.append("- Time: " + a.storyTime + (a.clock.map { ". " + Continuity.skyHint($0) } ?? "")) }
        if !p.with.isEmpty {
            l.append("- With you (only they speak and act):")
            l += p.with.map { "  - " + $0 }
        } else if !a.whereabouts.isEmpty {
            l.append("- With you: nobody in particular.")
        }
        if !p.background.isEmpty { l.append("- In the background (there and quiet; they don't join in): " + p.background.joined(separator: "; ")) }
        l += p.away.map { "- " + $0 }
        l.append("- You have (nothing else): " + (a.carrying.isEmpty ? "nothing in particular" : a.carrying.prefix(6).joined(separator: "; ")))
        if !p.props.isEmpty { l.append("- Around you (use one only if the moment calls for it): " + p.props.joined(separator: "; ")) }
        if !p.about.isEmpty { l += ["", "ALSO RELEVANT"] + p.about.map { "- " + $0 } }
        if !p.facts.isEmpty { l += ["", "FACTS (always true)"] + p.facts.map { "- " + $0 } }
        if !memories.isEmpty { l += ["", "EARLIER MOMENTS (from older turns)"] + memories.map { "- " + $0 } }
        if !extra.isEmpty { l += [""] + extra.map { "- " + $0 } }
        if !notes.isEmpty { l += ["", "NOTES"] + notes.map { "- " + $0 } }
        if !moment.isEmpty { l += ["", "THIS MOMENT (write exactly this)", moment] }
        return l.joined(separator: "\n")
    }

    /// The scene line for the World panel, written in code from the cards.
    static func sceneLine(_ a: Adventure) -> String {
        let me = first(a.playerName).lowercased()
        let others = a.whereabouts.filter { let f = first($0.name).lowercased(); return f != me && f != "you" }
        let with = others.filter { $0.here != false && $0.engaged == true }.map(\.name)
        let room = others.filter { $0.here != false && $0.engaged != true }.map(\.name)
        var s = a.location.isEmpty ? "You are on the move." : "You are at " + a.location + "."
        if !with.isEmpty { s += " With you: " + with.joined(separator: " and ") + "." }
        if !room.isEmpty { s += " Also here: " + room.joined(separator: " and ") + "." }
        return s
    }
}
