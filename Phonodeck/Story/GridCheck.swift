import Foundation

/// Lightweight spatial grounding and post-reply grid verification.
///
/// The room grid exists to keep the physical world coherent (so people don't teleport, objects
/// don't float across a bar, and someone in another building doesn't speak from the corner),
/// without drowning ordinary conversation in a furniture inventory or rigid stage scripts.
///
/// - Before a reply: `groundingLine` turns the grid into either a light 1-2 sentence anchor
///   (during conversation) or a fuller spatial view (when moving, arriving, or looking around).
/// - After a reply: `check` verifies the prose against the grid in pure code (zero model wait).
///   If it passes, the reply flies untouched. Minor spatial slips become a gentle grounding note
///   for the next turn rather than mutating or censoring the prose.
enum GridCheck {
    struct Report {
        /// Reality breaks that genuinely violate the scene (e.g., someone elsewhere acting here,
        /// or narration putting quoted dialogue in the player's mouth).
        var hardIssues: [String] = []
        /// Minor spatial slips against the grid (e.g., offering a seat while already seated, or
        /// direct physical contact across a bar/distance without crossing). Fed gently to the next turn.
        var softNotes: [String] = []

        var passed: Bool { hardIssues.isEmpty && softNotes.isEmpty }

        var summary: String {
            if passed { return "passed" }
            let all = hardIssues + softNotes
            return all.joined(separator: "; ")
        }
    }

    /// Plain-English spatial grounding read off the room grid.
    /// - `detailed == false` (conversation): just where you and your partner are relative to each
    ///   other, what lies directly between you (if anything), what's in hand, and who else is
    ///   quietly in the room. Keeps the room solid without cluttering a human talk with 10 props.
    /// - `detailed == true` (moving, arriving, interacting with objects, or asking about the room):
    ///   includes the room's feel, things in view, doors, and what is within reach.
    static func grounding(in a: Adventure, focused: [Whereabout], detailed: Bool, showReach: Bool) -> [String] {
        var lines: [String] = []
        let whereWhen = Fovea.whenWhere(a)
        if !whereWhen.isEmpty { lines.append("When and where: " + whereWhen) }

        if let r = a.room, let me = r.player {
            if detailed {
                let room = Fovea.roomLine(a)
                if !room.isEmpty { lines.append("The room: " + room) }
            } else {
                let outside = r.name.caseInsensitiveCompare(a.location) == .orderedSame ? r.outside : ""
                if !outside.isEmpty { lines.append("Outside (already established; don't repeat unless asked): " + Fovea.clip(outside, 100)) }
            }

            // Where you and the person(s) you're with are positioned on the grid.
            let spot = Fovea.youAt(r, me).components(separatedBy: ", facing").first ?? "in the room"
            var pos = "You are " + spot
            if me.on != nil { pos += " (already seated)" }

            if let f = focused.first, let t = r.named(f.name) {
                if let g = Fovea.gridSpot(a, f.name) {
                    pos += "; " + f.name + " is " + g
                }
                let d = RoomGrid.distance(me, t)
                if let blocker = RoomGrid.wayBlocker(r, from: me, to: t) {
                    let b = Fovea.bare(blocker)
                    pos += ". " + b.prefix(1).uppercased() + String(b.dropFirst()) + " is between you"
                } else if d > 2.2 {
                    pos += ". You are a few steps apart across the room"
                }
                if !t.holding.isEmpty {
                    pos += ". In " + Cards.first(f.name) + "'s hands: " + t.holding.joined(separator: ", ")
                }
                if detailed || showReach {
                    let reach = r.objects
                        .filter { $0.icon != "rug" && $0.id != t.on && RoomGrid.distance($0, t) < 1.6 }
                        .map { Fovea.bare($0.name) }
                    var seen = Set<String>()
                    let unique = reach.filter { seen.insert($0.lowercased()).inserted }
                    if !unique.isEmpty {
                        pos += ". Within their reach: " + unique.prefix(5).joined(separator: ", ")
                    }
                }
            }
            lines.append(pos + ".")

            if !a.carrying.isEmpty {
                lines.append("You have with you: " + a.carrying.prefix(6).joined(separator: ", ") + ".")
            }

            // Others in the room: brief and natural (they're real people in the space, not frozen props).
            let focusedIDs = Set(focused.compactMap { r.named($0.name)?.id })
            var others: [String] = []
            for p in r.people where p.id != me.id && !focusedIDs.contains(p.id) {
                let w = a.whereabouts.first { $0.name == p.name && $0.here != false }
                let c = w.flatMap { Cards.card(for: $0, in: a) }
                var o = p.name
                if let role = c?.role, !role.isEmpty { o += " (" + role + ")" }
                let pr = Cards.pronoun(c?.name ?? p.name, in: a)
                if !pr.isEmpty { o += " [" + pr + "]" }
                switch RoomGrid.seen(r, from: me, to: p) {
                case .behind:
                    o += ", behind you (heard, not seen)"
                case .hidden(let by):
                    o += ", out of sight behind " + Fovea.bare(by)
                case .front, .side:
                    if detailed, let g = Fovea.gridSpot(a, p.name) {
                        o += ", " + g
                    }
                    if let doing = w?.doing, !doing.isEmpty {
                        o += ", " + Fovea.clip(doing, 45)
                    }
                }
                others.append(o)
            }
            if !others.isEmpty {
                lines.append("Also in the room (mostly keeping to themselves unless brought in): " + others.joined(separator: "; ") + ".")
            }

            // Full room objects & doors only when looking around, moving, or interacting with space.
            if detailed {
                let inView = r.objects.filter { o in
                    guard o.icon != "rug" else { return false }
                    switch RoomGrid.seen(r, from: me, to: o) { case .front, .side: return true; default: return false }
                }.sorted { RoomGrid.distance($0, me) < RoomGrid.distance($1, me) }
                var seenNames = Set<String>()
                let visible = inView.compactMap { o -> String? in
                    let label = Fovea.bare(o.name)
                    guard seenNames.insert(label.lowercased()).inserted else { return nil }
                    if let owner = o.owner, !owner.isEmpty {
                        return label + " (" + Cards.first(owner) + "'s)"
                    }
                    return label
                }
                if !visible.isEmpty {
                    lines.append("In view around the room: " + visible.prefix(8).joined(separator: ", ") + ".")
                }
                let exits = r.doors.filter { !$0.leadsTo.isEmpty }.map { "a door to " + $0.leadsTo }
                if !exits.isEmpty {
                    lines.append("Ways out: " + exits.joined(separator: ", ") + ".")
                }
            }
        } else {
            // No grid drawn yet: fall back to text spot/place.
            if !a.spot.isEmpty { lines.append("Where you are: " + a.spot + ".") }
            if !a.carrying.isEmpty { lines.append("You have with you: " + a.carrying.prefix(6).joined(separator: ", ") + ".") }
        }

        return lines
    }

    /// Checks a finished reply against the room grid and current world state.
    /// Fast, deterministic, zero LLM calls.
    static func check(reply: String, in a: Adventure, focus: String) -> Report {
        var report = Report()
        let narration = reply.replacingOccurrences(of: #""[^"]*"|“[^”]*”"#, with: " ", options: .regularExpression)

        // 1. Hard check: speaking for the player or calling them "the player".
        if Continuity.speaksForPlayer(reply) {
            report.hardIssues.append("Put spoken words in the player's mouth (\"...\", you say).")
        }
        if narration.range(of: #"(?i)\bthe (player|player character|protagonist)\b"#, options: .regularExpression) != nil {
            report.hardIssues.append("Called the player \"the player\" instead of \"you\".")
        }

        // 2. Hard check: someone who is actually elsewhere (another place) acting in this room.
        let away = a.whereabouts.filter { $0.here == false }
        let arrivalRe = #"(?i)\b(arrives?|enters?|walks? in|steps? in|comes? in|returns?|opens? the door|calls? from|on the phone)\b"#
        for w in away {
            let first = Cards.first(w.name)
            guard first.count >= 3 else { continue }
            let esc = NSRegularExpression.escapedPattern(for: first)
            let actsPattern = #"\b"# + esc + #"\b(?!['’]s)\s+(?:[a-z]+ly\s+)?(?:[a-z]+s|is|has)\b"#
            if narration.range(of: actsPattern, options: .regularExpression) != nil,
               narration.range(of: arrivalRe, options: .regularExpression) == nil {
                report.hardIssues.append("\(w.name) is elsewhere (\(Continuity.placed(w.at))), not in this room.")
            }
        }

        // 3. Soft grid checks (gentle grounding notes for next turn, never destructive).
        if let r = a.room, let me = r.player {
            // 3a. Offering a seat when already seated.
            if me.on != nil {
                let seatOffer = #"(?i)\b(have a seat|take a seat|pull up a (stool|chair)|sit down|gestures? (to|at|toward) an? (empty |open )?(stool|chair|seat))\b"#
                if reply.range(of: seatOffer, options: .regularExpression) != nil {
                    let seatName = r.thing(me.on).map { Fovea.bare($0.name) } ?? "a seat"
                    report.softNotes.append("You are already sitting on \(seatName); no need to offer a seat.")
                }
            }

            // 3b. Direct touch across a physical barrier (like a bar/counter) or wide gap without crossing.
            if !focus.isEmpty, let them = r.named(focus), them.isPerson {
                let dist = RoomGrid.distance(me, them)
                let blocker = RoomGrid.wayBlocker(r, from: me, to: them)
                let directTouch = #"(?i)\b(puts? (his|her|their) (hand|arm) on your|places? (his|her|their) hand on your|rests? (his|her|their) hand on your|pats? your (shoulder|back|arm)|hugs? you|wraps? (his|her|their) arms? around you)\b"#
                let crosses = #"(?i)\b(comes? around|walks? around|steps? around|crosses? the|walks? over|steps? over|comes? over|leans? (far )?across)\b"#
                if (blocker != nil || dist > 2.2),
                   narration.range(of: directTouch, options: .regularExpression) != nil,
                   narration.range(of: crosses, options: .regularExpression) == nil {
                    if let blocker {
                        let b = Fovea.bare(blocker)
                        let cap = b.prefix(1).uppercased() + String(b.dropFirst())
                        report.softNotes.append("\(cap) is between you and \(focus), so they'd have to lean across or come around to reach you.")
                    } else {
                        report.softNotes.append("You and \(focus) are across the room from each other unless someone walks over.")
                    }
                }
            }

            // 3c. Describing the face/expression of someone who is behind you on the grid.
            for p in r.people where p.id != me.id && p.name.caseInsensitiveCompare(focus) != .orderedSame {
                guard case .behind = RoomGrid.seen(r, from: me, to: p) else { continue }
                let first = Cards.first(p.name)
                guard first.count >= 3 else { continue }
                let esc = NSRegularExpression.escapedPattern(for: first)
                let seesFace = #"\b"# + esc + #"\b[^.?!]{0,40}\b(smiles?|frowns?|grins?|winks?|raises? (an|his|her) eyebrow|narrows? (his|her) eyes|met your eyes|meets? your gaze)\b"#
                if narration.range(of: seesFace, options: [.regularExpression, .caseInsensitive]) != nil {
                    report.softNotes.append("\(p.name) is behind you on the room map (heard, not seen unless you turn).")
                }
            }
        }

        return report
    }
}
