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
    /// One visual fixation point in a person's sightline (eyes -> hands/near -> background).
    /// Computed purely in Swift off `RoomGrid.seen` (< 1 ms, zero extra model calls), giving both
    /// the storyteller and the room map genuine per-character visual acuity.
    struct Saccade: Identifiable {
        enum Kind: String { case eyes, hands, background }
        let id: Int
        let kind: Kind
        /// Concise name for the map UI caption.
        let shortLabel: String
        /// Natural phrase for the storyteller prompt.
        let detail: String
        /// Coordinate in room metres (for drawing the 1 -> 2 -> 3 gaze bounce path on the map).
        let x: Double
        let y: Double
        let targetID: UUID?
    }

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

    /// Computes up to three natural eye-fixation bounce points (eyes, hands/near, background)
    /// strictly from what `viewer` can actually see inside their 120° view cone on the room grid.
    static func saccades(for viewer: Thing, in room: Room, adventure a: Adventure) -> [Saccade] {
        var out: [Saccade] = []
        var usedIDs: Set<UUID> = [viewer.id]
        if let seat = viewer.on { usedIDs.insert(seat) }

        func isVisible(_ target: Thing) -> Bool {
            switch RoomGrid.seen(room, from: viewer, to: target) {
            case .front, .side: return true
            case .behind, .hidden: return false
            }
        }

        func openingPoint(_ o: Opening) -> (Double, Double) {
            let along = Double(o.at) + Double(max(1, o.width)) / 2.0
            switch o.wall {
            case .north: return (along, 0.15)
            case .south: return (along, Double(room.depth) - 0.15)
            case .west: return (0.15, along)
            case .east: return (Double(room.width) - 0.15, along)
            }
        }

        func angleToPoint(_ x: Double, _ y: Double) -> Double {
            let (fx, fy) = viewer.centre
            let vx = x - fx, vy = y - fy
            guard vx != 0 || vy != 0 else { return 0 }
            var ang = atan2(vx, -vy) - viewer.facing.angle
            while ang > .pi { ang -= 2 * .pi }
            while ang < -.pi { ang += 2 * .pi }
            return abs(ang * 180 / .pi)
        }

        // 1. EYES / FOCUS: primary person in front of `viewer` (preferring the player if viewer is an NPC
        // facing them), or nearest focal object in view if alone.
        let visiblePeople = room.people.filter { $0.id != viewer.id && isVisible($0) }
        let primaryPerson: Thing? = visiblePeople.min { lhs, rhs in
            let lPlayer = viewer.kind != .player && lhs.kind == .player && RoomGrid.faces(viewer, lhs)
            let rPlayer = viewer.kind != .player && rhs.kind == .player && RoomGrid.faces(viewer, rhs)
            if lPlayer != rPlayer { return lPlayer }
            let lFront = RoomGrid.seen(room, from: viewer, to: lhs) == .front
            let rFront = RoomGrid.seen(room, from: viewer, to: rhs) == .front
            if lFront != rFront { return lFront }
            return RoomGrid.distance(viewer, lhs) < RoomGrid.distance(viewer, rhs)
        }

        if let p = primaryPerson {
            usedIDs.insert(p.id)
            let (px, py) = p.centre
            if p.kind == .player {
                let cue = a.body.isEmpty ? "" : " (" + Fovea.clip(a.body, 40) + ")"
                let spot = p.on != nil ? "seated" : "standing"
                out.append(Saccade(id: 1, kind: .eyes, shortLabel: "You",
                                   detail: "you, " + spot + cue, x: px, y: py, targetID: p.id))
            } else {
                let w = a.whereabouts.first { $0.name.caseInsensitiveCompare(p.name) == .orderedSame && $0.here != false }
                let expr = !p.expression.isEmpty ? p.expression : (w?.doing ?? p.doing)
                let cue = expr.isEmpty ? "" : " (" + Fovea.clip(expr, 42) + ")"
                out.append(Saccade(id: 1, kind: .eyes, shortLabel: Cards.first(p.name),
                                   detail: p.name + cue, x: px, y: py, targetID: p.id))
            }
        } else if let obj = room.objects
            .filter({ $0.icon != "rug" && !usedIDs.contains($0.id) && isVisible($0) })
            .min(by: { RoomGrid.distance(viewer, $0) < RoomGrid.distance(viewer, $1) }) {
            usedIDs.insert(obj.id)
            let (ox, oy) = obj.centre
            let b = Fovea.bare(obj.name)
            out.append(Saccade(id: 1, kind: .eyes, shortLabel: b, detail: b, x: ox, y: oy, targetID: obj.id))
        }

        // 2. HANDS / IMMEDIATE: something held or within arm's reach in front of `viewer` or the person they face.
        let nearSmall = room.objects
            .filter { $0.icon != "rug" && !usedIDs.contains($0.id) && Rules.rule($0.icon).small && isVisible($0) && RoomGrid.distance(viewer, $0) <= 2.1 }
            .min { RoomGrid.distance(viewer, $0) < RoomGrid.distance(viewer, $1) }
        if let item = nearSmall {
            usedIDs.insert(item.id)
            let (ix, iy) = item.centre
            let b = Fovea.bare(item.name)
            let onThing = item.on.flatMap { room.thing($0) }.map { " on " + Fovea.bare($0.name) } ?? ""
            out.append(Saccade(id: out.count + 1, kind: .hands, shortLabel: b,
                               detail: b + onThing, x: ix, y: iy, targetID: item.id))
        } else if let held = viewer.holding.first, !held.isEmpty {
            let (vx, vy) = viewer.centre
            let hx = min(Double(room.width) - 0.25, max(0.25, vx + Double(viewer.facing.dx) * 0.45))
            let hy = min(Double(room.depth) - 0.25, max(0.25, vy + Double(viewer.facing.dy) * 0.45))
            let b = Fovea.bare(held)
            out.append(Saccade(id: out.count + 1, kind: .hands, shortLabel: b,
                               detail: b + " in hand", x: hx, y: hy, targetID: nil))
        } else if let p = primaryPerson {
            let carried = p.kind == .player ? a.carrying.first : p.holding.first
            if let item = carried, !item.isEmpty {
                let (px, py) = p.centre
                let b = Fovea.bare(item)
                let owner = p.kind == .player ? "your " : Cards.first(p.name) + "'s "
                out.append(Saccade(id: out.count + 1, kind: .hands, shortLabel: b,
                                   detail: owner + b, x: px, y: py, targetID: p.id))
            }
        }

        // 3. BACKGROUND / PERIPHERAL: another visible person deeper in the cone, a visible window/door,
        // or a distinct background object across the room.
        if let other = visiblePeople
            .filter({ !usedIDs.contains($0.id) })
            .min(by: { RoomGrid.distance(viewer, $0) < RoomGrid.distance(viewer, $1) }) {
            usedIDs.insert(other.id)
            let (ox, oy) = other.centre
            let w = a.whereabouts.first { $0.name.caseInsensitiveCompare(other.name) == .orderedSame && $0.here != false }
            let doing = w?.doing ?? other.doing
            let cue = doing.isEmpty ? "" : " (" + Fovea.clip(doing, 42) + ")"
            let label = other.kind == .player ? "You" : Cards.first(other.name)
            let who = other.kind == .player ? "you" : other.name
            out.append(Saccade(id: out.count + 1, kind: .background, shortLabel: label,
                               detail: "further in view, " + who + cue, x: ox, y: oy, targetID: other.id))
        } else {
            let visibleWindow = room.windows.first { w in
                let (wx, wy) = openingPoint(w)
                return angleToPoint(wx, wy) <= 100
            }
            let visibleDoor = room.doors.first { d in
                let (dx, dy) = openingPoint(d)
                return angleToPoint(dx, dy) <= 100
            }
            if let win = visibleWindow {
                let (wx, wy) = openingPoint(win)
                let viewText = win.view.isEmpty ? "the window" : "the window (" + Fovea.clip(win.view, 45) + ")"
                out.append(Saccade(id: out.count + 1, kind: .background, shortLabel: "window",
                                   detail: viewText, x: wx, y: wy, targetID: nil))
            } else if let door = visibleDoor {
                let (dx, dy) = openingPoint(door)
                let toText = door.leadsTo.isEmpty ? "the door" : "the door to " + Fovea.bare(door.leadsTo)
                out.append(Saccade(id: out.count + 1, kind: .background, shortLabel: door.leadsTo.isEmpty ? "door" : Fovea.bare(door.leadsTo),
                                   detail: toText, x: dx, y: dy, targetID: nil))
            } else if let farObj = room.objects
                .filter({ $0.icon != "rug" && !usedIDs.contains($0.id) && isVisible($0) && RoomGrid.distance(viewer, $0) >= 1.8 })
                .max(by: { RoomGrid.distance(viewer, $0) < RoomGrid.distance(viewer, $1) }) {
                let (fx, fy) = farObj.centre
                let b = Fovea.bare(farObj.name)
                out.append(Saccade(id: out.count + 1, kind: .background, shortLabel: b,
                                   detail: b + " across the room", x: fx, y: fy, targetID: farObj.id))
            }
        }

        return out
    }

    /// Formats a character's 3-point sightline into one compact, optional grounding cue (~35 tokens).
    static func saccadeLine(for viewer: Thing, in room: Room, adventure a: Adventure) -> String {
        let pts = saccades(for: viewer, in: room, adventure: a)
        guard pts.count >= 2 else { return "" }
        let parts = pts.map { s -> String in
            let tag = s.kind == .eyes ? "focus" : s.kind == .hands ? "hands/near" : "background"
            return "(\(s.id)) \(tag): \(s.detail)"
        }
        return "From \(viewer.name)'s eyes (what's actually in their sightline; weave a glance in only if it fits): " + parts.joined(separator: "; ") + "."
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

            var partnerThing: Thing? = nil
            if let f = focused.first, let t = r.named(f.name) {
                partnerThing = t
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

            if let t = partnerThing {
                let cue = saccadeLine(for: t, in: r, adventure: a)
                if !cue.isEmpty { lines.append(cue) }
            }

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
                let seatOffer = #"(?i)\b(have a seat|take a seat|pull up a (stool|chair)|sit down|(gestures?|motions?|nods?|waves?|points?) (to|at|towards?) (an?|the|another) (empty |open |free |vacant )?(stool|chair|seat|booth)|waiting for you to (sit|settle in|take a seat))\b"#
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
