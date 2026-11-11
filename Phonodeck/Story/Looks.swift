import Foundation

/// Lookups: the small retrieval language the read uses to see the world it needs.
///
/// The world lives in the app. Like an eye in a busy room, the storyteller only sees what it
/// looks at: before a reply, the read picks up to three lookups from a fixed list, code answers
/// each one from the store in a line or two, and the plan and the reply see only those answers
/// (plus the place and whoever the player is facing).
///
///   who is here       everyone in the room with the player, and what they are doing
///   where am I        the place card and the time
///   what I have       what the player has on them
///   what is around    the notable things in this place
///   look at <name>    one card: a person, a place, an item, or a thing here
///   where is <name>   where a person is right now
///   remember <topic>  older moments of the story about a topic
enum Looks {
    enum Kind: String, CaseIterable {
        case whoIsHere = "who is here"
        case whereAmI = "where am I"
        case whatIHave = "what I have"
        case around = "what is around"
        case lookAt = "look at"
        case whereIs = "where is"
        case remember = "remember"

        /// Lookups that take a name or a topic after them.
        var takesTarget: Bool { self == .lookAt || self == .whereIs || self == .remember }
    }

    struct Look: Hashable {
        var kind: Kind
        var target = ""
        /// Added by code (the player named someone, or reached back in time), not asked by the model.
        var byCode = false
        var text: String { target.isEmpty ? kind.rawValue : kind.rawValue + " " + target }
    }

    struct Answer {
        var look: Look
        var lines: [String]
        var text: String { lines.joined(separator: " ") }
    }

    /// The lookup a grammar-locked string stands for, matched to what exists.
    static func parse(_ raw: String, cards: [String], people: [String]) -> Look? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for k in Kind.allCases where !k.takesTarget {
            if s.caseInsensitiveCompare(k.rawValue) == .orderedSame { return Look(kind: k) }
        }
        for k in Kind.allCases where k.takesTarget {
            guard s.lowercased().hasPrefix(k.rawValue + " ") else { continue }
            let t = String(s.dropFirst(k.rawValue.count + 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            switch k {
            case .lookAt:
                if let c = cards.first(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) { return Look(kind: k, target: c) }
            case .whereIs:
                if let p = people.first(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) { return Look(kind: k, target: p) }
            default:
                if t.count >= 3 { return Look(kind: k, target: String(t.prefix(40))) }
            }
        }
        return nil
    }

    /// Lookups code adds on its own: the person the player turns to, any card the message names,
    /// what the player has when the message mentions it, and older moments when the message
    /// reaches back in time.
    static func auto(_ a: Adventure, input: String, to: String, asked: [Look]) -> [Look] {
        var out: [Look] = []
        func has(_ k: Kind, _ t: String = "") -> Bool {
            (asked + out).contains { $0.kind == k && $0.target.caseInsensitiveCompare(t) == .orderedSame }
        }
        if !to.isEmpty, !has(.lookAt, to) { out.append(Look(kind: .lookAt, target: to, byCode: true)) }
        let menu = Cards.menu(a, input: input)
        for e in a.lore where !e.isPlayer && menu.contains(where: { $0.caseInsensitiveCompare(e.name) == .orderedSame }) {
            let hit = e.kind == .person ? Cards.mentions(e, in: input) : Continuity.names(place: e.name, in: input)
            if hit, !has(.lookAt, e.name), !(asked + out).contains(where: { $0.target.caseInsensitiveCompare(e.name) == .orderedSame }) {
                out.append(Look(kind: .lookAt, target: e.name, byCode: true))
            }
        }
        let words = Continuity.wordSet(input)
        let mine = a.carrying.contains { h in
            let noun = h.lowercased().split(whereSeparator: { !$0.isLetter }).last.map(String.init) ?? ""
            return noun.count >= 3 && words.contains(noun)
        }
        if mine || input.range(of: #"(?i)\b(my pocket|my bag|i have|i've got|i carry|i check my)\b"#, options: .regularExpression) != nil,
           !has(.whatIHave) {
            out.append(Look(kind: .whatIHave, byCode: true))
        }
        let past = #"(?i)\b(remember|earlier|before|last time|back then|yesterday|used to|you said|told me)\b"#
        if input.range(of: past, options: .regularExpression) != nil, !(asked + out).contains(where: { $0.kind == .remember }) {
            out.append(Look(kind: .remember, target: Cards.clip(input, 60), byCode: true))
        }
        return Array(out.prefix(3))
    }

    /// Code's answer to one lookup, from the store. `remember` is answered by the engine (it
    /// searches older moments); here it only finds facts on file that share a word with the topic.
    static func answer(_ look: Look, in a: Adventure) -> Answer {
        let me = Cards.first(a.playerName).lowercased()
        let others = a.whereabouts.filter { w in
            let f = Cards.first(w.name).lowercased()
            return !f.isEmpty && f != me && f != "you"
        }
        switch look.kind {
        case .whoIsHere:
            let here = others.filter { $0.here != false }
            guard !here.isEmpty else { return Answer(look: look, lines: ["Nobody but you."]) }
            return Answer(look: look, lines: here.map { w in
                let c = Cards.card(for: w, in: a)
                var l: String = c?.name ?? w.name
                if let role = c?.role, !role.isEmpty { l += " (" + role + ")" }
                let pr = Cards.pronoun(c?.name ?? w.name, in: a)
                if !pr.isEmpty { l += ", " + pr }
                l += w.engaged == true ? ": with you" : ": in the room"
                if !w.doing.isEmpty { l += ", " + Cards.clip(w.doing, 80) }
                return l + "."
            })
        case .whereAmI:
            var l: [String] = []
            if a.location.isEmpty {
                l.append("On the way somewhere new; the place has no name yet.")
            } else {
                let desc: String = Cards.placeCard(a)?.desc ?? ""
                l.append(a.location + (desc.isEmpty ? "." : ": " + Cards.clip(desc, 240)))
            }
            if !a.storyTime.isEmpty { l.append("Time: " + a.storyTime + ".") }
            return Answer(look: look, lines: l)
        case .whatIHave:
            return Answer(look: look, lines: [a.carrying.isEmpty ? "Nothing in particular." : a.carrying.prefix(8).joined(separator: "; ") + "."])
        case .around:
            let props = Cards.props(a)
            return Answer(look: look, lines: [props.isEmpty ? "Nothing notable shown here yet." : props.prefix(8).joined(separator: "; ") + "."])
        case .whereIs:
            guard let w = others.first(where: { Cards.first($0.name).caseInsensitiveCompare(Cards.first(look.target)) == .orderedSame }) else {
                return Answer(look: look, lines: ["Not placed anywhere yet."])
            }
            var spot: String = w.engaged == true ? "here, with you" : "here, in the room"
            if w.here == false {
                let at: String = w.leftAt.map { "at " + $0 } ?? Continuity.placed(w.at)
                spot = "elsewhere: " + at + "; not here, so not seen or heard"
            }
            var l: String = w.name + " is " + spot
            if !w.doing.isEmpty { l += ", " + Cards.clip(w.doing, 80) }
            return Answer(look: look, lines: [l + "."])
        case .lookAt:
            return Answer(look: look, lines: [card(look.target, in: a)])
        case .remember:
            let kw = Cards.keywords(look.target)
            let hits = a.facts.filter { !Cards.keywords($0).isDisjoint(with: kw) }.suffix(2).map { Cards.clip($0, 160) }
            return Answer(look: look, lines: Array(hits))
        }
    }

    /// One card as a lookup answers it.
    static func card(_ name: String, in a: Adventure) -> String {
        if let e = a.lore.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame && !$0.isPlayer }) {
            switch e.kind {
            case .person:
                var l: String = e.name
                if !e.role.isEmpty { l += " (" + e.role + ")" }
                let pr = Cards.pronoun(e.name, in: a)
                if !pr.isEmpty { l += ", " + pr }
                if !e.desc.isEmpty { l += ": " + Cards.clip(e.desc, 220) }
                if let w = a.whereabouts.first(where: { Cards.card(for: $0, in: a)?.id == e.id }) {
                    var now: String = w.engaged == true ? "with you" : "in the room"
                    if w.here == false {
                        let at: String = w.leftAt.map { "at " + $0 } ?? Continuity.placed(w.at)
                        now = "elsewhere, " + at + " (not here)"
                    }
                    if !w.doing.isEmpty { now += ", " + Cards.clip(w.doing, 80) }
                    l += " Now: " + now + "."
                }
                if let feels = a.feelings[e.name.lowercased()] { l += " Feels about you: " + feels + "." }
                let theirs = Cards.facts(about: e, in: a).suffix(3).map { Cards.clip($0, 150) }
                if !theirs.isEmpty { l += " Known: " + theirs.joined(separator: " ") }
                return l
            case .place:
                var l: String = e.name + " (place)"
                if !e.desc.isEmpty { l += ": " + Cards.clip(e.desc, 220) }
                let key = e.name.lowercased()
                let props = a.placeThings[key] ?? []
                if !props.isEmpty { l += " Things there: " + props.prefix(5).joined(separator: "; ") + "." }
                let left = a.whereabouts.filter { $0.here == false && $0.leftAt?.lowercased() == key }.map(\.name)
                if !left.isEmpty { l += " Left there: " + left.joined(separator: ", ") + "." }
                if a.location.caseInsensitiveCompare(e.name) == .orderedSame { l += " You are here." }
                return l
            default:
                var l: String = e.name + " (" + e.kind.rawValue + ")"
                if !e.desc.isEmpty { l += ": " + Cards.clip(e.desc, 220) }
                let theirs = a.facts.filter { Continuity.names(place: e.name, in: $0) }.suffix(2).map { Cards.clip($0, 150) }
                if !theirs.isEmpty { l += " Known: " + theirs.joined(separator: " ") }
                return l
            }
        }
        if Cards.props(a).contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            return name + ": here, in this place."
        }
        if a.carrying.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            return name + ": you have it."
        }
        return name + ": nothing on file."
    }
}
