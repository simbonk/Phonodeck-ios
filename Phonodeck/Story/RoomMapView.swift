import SwiftUI

/// The World panel's map: the room you are in, drawn from above, one square per metre. People are
/// round tokens with a bright arc on the side they face; two people facing each other are joined by
/// a faint eye-line. Your view cone is shaded. Tap a square and every card on it opens, top down
/// (who is there, what is on things, the furniture under them), and every other card closes. Tap it
/// again to close them. Anything a question changes sparks, on the map and on its card.
struct RoomMapView: View {
    @Environment(AppModel.self) private var app
    /// The room shown (nil: the one you are in).
    @State private var shownID: UUID?
    /// Whose eyes the map is looking through (nil: your eyes).
    @State private var povID: UUID?
    @State private var editing: Thing?
    /// The cards kept open under the map, by name ("you" for the player), newest first.
    @AppStorage("pinnedThings") private var pinnedRaw = "you"
    /// What each thing looked like last time, to tell what changed.
    @State private var looks: [UUID: String] = [:]
    @State private var lit: Set<UUID> = []
    /// Each card row's last value and the beat it last changed on ("id|label"), so a card shows
    /// what just changed at the top.
    @State private var rowWas: [String: String] = [:]
    @State private var rowAt: [String: Date] = [:]
    @State private var beat = 0
    @State private var tickerOpen = false
    /// The map's zoom and pan (pinch and drag on the map only).
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var drag: CGSize = .zero

    var body: some View {
        if let a = app.engine.adventure, !a.location.isEmpty, !a.rooms.contains(where: { $0.name.caseInsensitiveCompare(a.location) == .orderedSame }) {
            HStack(spacing: 8) {
                HoloCore(size: 16)
                Text("Drawing " + a.location + "…").font(.subheadline).foregroundStyle(Theme.fg)
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
        } else if let a = app.engine.adventure, !a.rooms.isEmpty {
            let here = a.room
            let room = a.rooms.first { $0.id == (shownID ?? here?.id) } ?? here ?? a.rooms[0]
            let pov = activePOV(in: room)
            VStack(alignment: .leading, spacing: 8) {
                header(a, room: room, here: here)
                ticker(a, room)
                perspectiveBar(a, room: room, pov: pov)
                map(a, room: room, live: room.id == here?.id, pov: pov)
                    .onAppear { looks = Dictionary(room.things.map { ($0.id, $0.look) }, uniquingKeysWith: { a, _ in a }) }
                    .onChange(of: room.things.map(\.look)) { _, _ in spark(room) }
                    .onAppear { track(a, room, mark: false) }
                    .onChange(of: signature(a, room)) { _, _ in track(a, room, mark: true) }
                    .onChange(of: room.id) { _, _ in povID = nil }
                sightlineBar(a, room: room, pov: pov)
                pinnedCards(a, room)
            }
            .padding(10)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
            .sheet(item: $editing) { t in
                ThingCard(thing: t, room: room, details: rows(t, a, room)) { app.engine.saveThing($0, in: room.id) }
            }
        }
    }

    // MARK: Header: the room picker and Travel here

    @ViewBuilder
    private func header(_ a: Adventure, room: Room, here: Room?) -> some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(a.rooms) { r in
                    Button {
                        withAnimation(.snappy) { shownID = r.id == here?.id ? nil : r.id }
                    } label: {
                        Label(r.name, systemImage: r.id == here?.id ? "location.fill" : "square.grid.3x3")
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "square.grid.3x3.fill").font(.caption)
                    Text(room.name).font(.subheadline.bold()).lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption2)
                }
                .foregroundStyle(Theme.accent)
            }
            Text("\(room.width) × \(room.depth) m").font(.caption).foregroundStyle(Theme.dim)
            Spacer(minLength: 0)
            if room.id == here?.id {
                Text("you are here").font(.caption).foregroundStyle(Theme.dim)
            } else {
                Button {
                    app.engine.send("I go to " + (room.name.lowercased().hasPrefix("the ") ? "" : "the ") + room.name + ".")
                    withAnimation(.snappy) { shownID = nil }
                } label: {
                    Label("Travel here", systemImage: "figure.walk").font(.caption.bold())
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(app.engine.busy)
            }
        }
        if !room.inside.isEmpty || !room.outside.isEmpty {
            Text([room.inside, room.outside.isEmpty ? "" : "Outside: " + room.outside].filter { !$0.isEmpty }.joined(separator: " "))
                .font(.caption).foregroundStyle(Theme.dim).lineLimit(2)
        }
    }

    /// Everything that changes, scrolling along the top of the map: the room's recent decisions,
    /// then this turn's questions with their answers and what they changed, then the question
    /// being asked right now. The strip keeps itself scrolled to the newest line.
    private func feed(_ a: Adventure, _ room: Room) -> [(text: String, kind: Int)] {
        var out: [(text: String, kind: Int)] = room.log.suffix(8).map { (Self.logText($0), $0.hasPrefix("refuse") ? 2 : 0) }
        if let f = a.frames.last {
            for line in f.pre ?? [] { out.append((Continuity.unnamed(line, in: a), 1)) }
            for (i, line) in f.asked.enumerated() {
                out.append((Continuity.unnamed(line, in: a), 1))
                if let steps = f.steps, steps.indices.contains(i) {
                    for c in steps[i] { out.append((Continuity.unnamed(c, in: a), 0)) }
                }
            }
            for c in f.changed where !out.contains(where: { $0.text == c }) { out.append((Continuity.unnamed(c, in: a), 0)) }
        }
        return out
    }

    private static let answerColor = Color(hex: 0xF2B66D)

    private static func split(_ t: String) -> (String, String) {
        // Only a question splits: "What is the bar? → a thing in the room". A change stays one line.
        if let r = t.range(of: " → "), t[..<r.lowerBound].hasSuffix("?") { return (String(t[..<r.lowerBound]), String(t[r.upperBound...])) }
        return ("", t)
    }

    private func pair(_ q: String, _ ans: String, kind: Int, live: Bool) -> some View {
        let answerColor = Self.answerColor
        return VStack(alignment: .leading, spacing: 3) {
            if !q.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Q").font(.caption2.bold().monospaced()).foregroundStyle(Theme.accent)
                    Text(q).font(.caption.bold()).foregroundStyle(Theme.accent).lineLimit(2)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(q.isEmpty ? "✦" : "A").font(.caption2.bold().monospaced())
                    .foregroundStyle(kind == 2 ? Color.red.opacity(0.9) : answerColor)
                if live {
                    HoloCore(size: 12)
                    Text("thinking…").font(.caption).foregroundStyle(Theme.dim)
                } else {
                    Text(ans).font(.caption).foregroundStyle(kind == 2 ? Color.red.opacity(0.9) : (q.isEmpty ? Theme.fg : answerColor)).lineLimit(2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The question being asked, or the last one answered, as two lines: the question in one
    /// colour, the answer under it in another. Tap for the last few.
    @ViewBuilder
    private func ticker(_ a: Adventure, _ room: Room) -> some View {
        let asking = app.engine.rebuildStep.isEmpty ? app.engine.stage : app.engine.rebuildStep
        let items = feed(a, room)
        if !items.isEmpty || !asking.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if tickerOpen {
                    ForEach(Array(items.suffix(8).dropLast(1).enumerated()), id: \.offset) { _, item in
                        let qa = Self.split(item.text)
                        pair(qa.0, qa.1, kind: item.kind, live: false).opacity(0.6)
                    }
                }
                // The question shows the instant it is asked; the answers stream past under it.
                if !asking.isEmpty {
                    pair(Continuity.unnamed(asking, in: a), "", kind: 1, live: true)
                }
                if let last = items.last {
                    let qa = Self.split(last.text)
                    pair(qa.0, qa.1, kind: last.kind, live: false).opacity(asking.isEmpty ? 1 : 0.7)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.snappy) { tickerOpen.toggle() } }
        }
    }

    /// A build-log line as it reads on screen ("place: the bar → by the north wall").
    static func logText(_ l: String) -> String {
        guard let i = l.firstIndex(of: ":") else { return l }
        let kind = l[..<i]
        let rest = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
        switch kind {
        case "shell": return "Walls up: " + rest
        case "place": return "Placed " + rest
        case "move": return "Moved " + rest
        case "refuse": return "Refused " + rest
        case "ask": return rest.prefix(1).uppercased() + rest.dropFirst()
        case "enter": return rest.contains(" ") ? rest.prefix(1).uppercased() + rest.dropFirst() : rest + " comes in"
        case "leave": return rest + " leaves"
        case "edit": return "Edited " + rest
        case "size": return "Size: " + rest
        default: return l
        }
    }

    // MARK: Perspective (Look through anyone's eyes)

    private func activePOV(in room: Room) -> Thing? {
        if let id = povID, let found = room.people.first(where: { $0.id == id }) { return found }
        return room.player ?? room.people.first
    }

    private func displayName(_ p: Thing, in a: Adventure) -> String {
        if p.kind == .player { return "You" }
        let raw = a.nameless ? Continuity.unnamed(p.name, in: a) : p.name
        return raw.caseInsensitiveCompare(p.name) == .orderedSame ? Cards.first(p.name) : raw
    }

    private func isDimmed(_ t: Thing, in room: Room, from pov: Thing?) -> Bool {
        guard let pov, t.id != pov.id, t.id != pov.on, t.icon != "rug" else { return false }
        switch RoomGrid.seen(room, from: pov, to: t) {
        case .behind, .hidden: return true
        case .front, .side: return false
        }
    }

    @ViewBuilder
    private func perspectiveBar(_ a: Adventure, room: Room, pov: Thing?) -> some View {
        let people = room.people.sorted { ($0.kind == .player ? 0 : 1, $0.name) < ($1.kind == .player ? 0 : 1, $1.name) }
        if people.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Image(systemName: "eye")
                        .font(.caption)
                        .foregroundStyle(Theme.dim)
                    ForEach(people) { p in
                        let selected = pov?.id == p.id
                        let isPlayer = p.kind == .player
                        let tint = isPlayer ? Theme.accent : Color(red: 0.95, green: 0.72, blue: 0.42)
                        Button {
                            withAnimation(.snappy) {
                                povID = (povID == p.id || isPlayer) ? nil : p.id
                            }
                        } label: {
                            HStack(spacing: 4) {
                                if selected {
                                    Image(systemName: "eye.fill").font(.system(size: 10))
                                }
                                Text(displayName(p, in: a))
                                    .font(.caption.weight(selected ? .semibold : .regular))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .foregroundStyle(selected ? Theme.bg : Theme.fg)
                            .background(selected ? tint : Theme.bg.opacity(0.65), in: Capsule())
                            .overlay(Capsule().stroke(selected ? tint : Theme.line, lineWidth: 0.8))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("View from \(displayName(p, in: a))'s eyes")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func sightlineBar(_ a: Adventure, room: Room, pov: Thing?) -> some View {
        if let pov {
            let pts = GridCheck.saccades(for: pov, in: room, adventure: a)
            if !pts.isEmpty {
                let isPlayer = pov.kind == .player
                let tint = isPlayer ? Theme.accent : Color(red: 0.95, green: 0.72, blue: 0.42)
                let who = isPlayer ? "Your sightline" : displayName(pov, in: a) + "'s sightline"
                HStack(spacing: 6) {
                    Image(systemName: "eye.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(tint)
                    Text(who + ":")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.fg)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(pts) { pt in
                                let rawLabel = a.nameless ? Continuity.unnamed(pt.shortLabel, in: a) : pt.shortLabel
                                HStack(spacing: 3) {
                                    Text("\(pt.id)")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(Theme.bg)
                                        .frame(width: 14, height: 14)
                                        .background(tint, in: Circle())
                                    Text(rawLabel)
                                        .font(.caption2)
                                        .foregroundStyle(Theme.dim)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Theme.bg.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: The map

    private func map(_ a: Adventure, room: Room, live: Bool, pov: Thing?) -> some View {
        let saccades: [GridCheck.Saccade] = pov.map { GridCheck.saccades(for: $0, in: room, adventure: a) } ?? []
        return GeometryReader { g in
            let s = max(12, min(44, (g.size.width - 8) / CGFloat(max(1, room.width))))
            let ox = (g.size.width - s * CGFloat(room.width)) / 2
            let oy: CGFloat = 4
            ZStack(alignment: .topLeading) {
                floor(room, s: s, ox: ox, oy: oy, live: live, pov: pov, saccades: saccades)
                ForEach(room.objects.filter { $0.on == nil }) { t in
                    objectView(t, s: s, dimmed: isDimmed(t, in: room, from: pov))
                        .position(x: ox + CGFloat(t.centre.x) * s, y: oy + CGFloat(t.centre.y) * s)
                }
                ForEach(room.objects.filter { $0.on != nil }) { t in
                    smallView(t, room: room, s: s, dimmed: isDimmed(t, in: room, from: pov))
                        .position(x: ox + (CGFloat(t.x) + 0.72) * s, y: oy + (CGFloat(t.y) + 0.3) * s)
                }
                ForEach(room.people) { p in
                    token(p, room: room, s: s, pov: pov, a: a)
                        .position(x: ox + CGFloat(p.centre.x) * s, y: oy + CGFloat(p.centre.y) * s)
                }
                saccadeDots(saccades, pov: pov, s: s, ox: ox, oy: oy)
                badges(room, s: s, ox: ox, oy: oy)
            }
            .contentShape(Rectangle())
            .onTapGesture { pt in
                // A tap on or just beside a wall opens the room's own card.
                let fx = (pt.x - ox) / s, fy = (pt.y - oy) / s
                let w = CGFloat(room.width), d = CGFloat(room.depth), edge: CGFloat = 0.3
                // A tap by a door opens the door's card.
                if let door = room.doors.min(by: { Self.doorGap($0, fx, fy, room) < Self.doorGap($1, fx, fy, room) }),
                   Self.doorGap(door, fx, fy, room) < 0.9 {
                    show([Self.doorKey + door.id.uuidString])
                    return
                }
                if fx > -1, fy > -1, fx < w + 1, fy < d + 1, fx < edge || fy < edge || fx > w - edge || fy > d - edge {
                    show([Self.roomKey])
                    return
                }
                let c = Cell(x: Int(fx), y: Int(fy))
                guard room.contains(c) else { return }
                // Everything on the square, from the top down: a person, what sits on things, then the furniture.
                let stack = room.stack(at: c).reversed().map(key)
                show(stack)
            }
            .animation(.spring(response: 0.5, dampingFraction: 0.8), value: room.things.map(\.look))
            .animation(.snappy, value: povID)
            // Pinch to zoom and drag to look around, on the map only; double-tap to fit it again.
            .scaleEffect(zoom * pinch)
            .offset(x: pan.width + drag.width, y: pan.height + drag.height)
            .gesture(
                MagnifyGesture()
                    .updating($pinch) { v, st, _ in st = v.magnification }
                    .onEnded { v in
                        zoom = min(4, max(1, zoom * v.magnification))
                        if zoom == 1 { withAnimation(.snappy) { pan = .zero } }
                    }
            )
            // Dragging pans only while zoomed in, so the page still scrolls otherwise.
            .gesture(
                DragGesture(minimumDistance: 8)
                    .updating($drag) { v, st, _ in st = v.translation }
                    .onEnded { v in pan.width += v.translation.width; pan.height += v.translation.height },
                including: zoom > 1 ? .all : .subviews
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded { withAnimation(.snappy) { zoom = 1; pan = .zero } })
        }
        .clipped()
        .overlay(alignment: .bottomTrailing) {
            if zoom > 1 {
                Text(String(format: "%.1f×", zoom)).font(.caption2.monospacedDigit()).foregroundStyle(Theme.dim)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(Theme.bg.opacity(0.8), in: Capsule()).padding(4)
            }
        }
        .aspectRatio(CGFloat(max(1, room.width)) / (CGFloat(max(1, room.depth)) + 0.8), contentMode: .fit)
        .frame(maxHeight: 44 * CGFloat(room.depth) + 26)
    }

    /// Numbered 1 -> 2 -> 3 gaze bounce badges for the active POV's three eye fixations.
    private func saccadeDots(_ saccades: [GridCheck.Saccade], pov: Thing?, s: CGFloat, ox: CGFloat, oy: CGFloat) -> some View {
        let tint = (pov?.kind == .player) ? Theme.accent : Color(red: 0.95, green: 0.72, blue: 0.42)
        return ForEach(saccades) { pt in
            Text("\(pt.id)")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Theme.bg)
                .frame(width: 13, height: 13)
                .background(tint, in: Circle())
                .overlay(Circle().stroke(Theme.bg, lineWidth: 1))
                .position(x: ox + CGFloat(pt.x) * s + 7, y: oy + CGFloat(pt.y) * s - 7)
                .allowsHitTesting(false)
        }
    }

    /// The floor, walls, windows, doors, the active POV's view cone, 3-point saccade lines and eye-lines.
    private func floor(_ room: Room, s: CGFloat, ox: CGFloat, oy: CGFloat, live: Bool, pov: Thing?, saccades: [GridCheck.Saccade]) -> some View {
        Canvas { ctx, _ in
            let W = CGFloat(room.width) * s, D = CGFloat(room.depth) * s
            let box = CGRect(x: ox, y: oy, width: W, height: D)
            ctx.fill(Path(box), with: .color(Theme.bg))
            // The squares.
            var grid = Path()
            for i in 1..<max(2, room.width) { grid.move(to: CGPoint(x: ox + CGFloat(i) * s, y: oy)); grid.addLine(to: CGPoint(x: ox + CGFloat(i) * s, y: oy + D)) }
            for j in 1..<max(2, room.depth) { grid.move(to: CGPoint(x: ox, y: oy + CGFloat(j) * s)); grid.addLine(to: CGPoint(x: ox + W, y: oy + CGFloat(j) * s)) }
            ctx.stroke(grid, with: .color(Theme.line.opacity(0.6)), lineWidth: 0.5)
            // Active POV's 120-degree view cone, out to the walls.
            if let viewer = pov, live || povID != nil {
                let c = CGPoint(x: ox + CGFloat(viewer.centre.x) * s, y: oy + CGFloat(viewer.centre.y) * s)
                let start = Angle(radians: viewer.facing.angle - .pi / 2 - .pi / 3)
                let end = Angle(radians: viewer.facing.angle - .pi / 2 + .pi / 3)
                let coneTint = viewer.kind == .player ? Theme.accent : Color(red: 0.95, green: 0.72, blue: 0.42)
                var cone = Path()
                cone.move(to: c)
                cone.addArc(center: c, radius: max(W, D) * 1.5, startAngle: start, endAngle: end, clockwise: false)
                cone.closeSubpath()
                var clipped = ctx
                clipped.clip(to: Path(box))
                clipped.fill(cone, with: .color(coneTint.opacity(0.13)))

                // 3-point saccade bounce path (viewer -> 1 -> 2 -> 3).
                if !saccades.isEmpty {
                    var bounce = Path()
                    bounce.move(to: c)
                    for pt in saccades {
                        bounce.addLine(to: CGPoint(x: ox + CGFloat(pt.x) * s, y: oy + CGFloat(pt.y) * s))
                    }
                    ctx.stroke(bounce, with: .color(coneTint.opacity(0.55)), style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
                }
            }
            // Eye-lines between people facing each other.
            let people = room.people
            for i in people.indices { for j in people.indices where j > i {
                let a = people[i], b = people[j]
                guard RoomGrid.faceEachOther(a, b) else { continue }
                var l = Path()
                l.move(to: CGPoint(x: ox + CGFloat(a.centre.x) * s, y: oy + CGFloat(a.centre.y) * s))
                l.addLine(to: CGPoint(x: ox + CGFloat(b.centre.x) * s, y: oy + CGFloat(b.centre.y) * s))
                ctx.stroke(l, with: .color(Theme.accent.opacity(0.45)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            } }
            // Walls, with gaps for doors.
            let doorCells = Set(room.doors.flatMap { room.cells(of: $0) })
            func segment(_ wall: Wall, _ i: Int) -> (CGPoint, CGPoint) {
                switch wall {
                case .north: return (CGPoint(x: ox + CGFloat(i) * s, y: oy), CGPoint(x: ox + CGFloat(i + 1) * s, y: oy))
                case .south: return (CGPoint(x: ox + CGFloat(i) * s, y: oy + D), CGPoint(x: ox + CGFloat(i + 1) * s, y: oy + D))
                case .west: return (CGPoint(x: ox, y: oy + CGFloat(i) * s), CGPoint(x: ox, y: oy + CGFloat(i + 1) * s))
                case .east: return (CGPoint(x: ox + W, y: oy + CGFloat(i) * s), CGPoint(x: ox + W, y: oy + CGFloat(i + 1) * s))
                }
            }
            let outdoor = RoomBuilder.outdoor.contains(room.type)
            // In the open air there are no walls: only a faint edge to the map.
            if outdoor {
                ctx.stroke(Path(box), with: .color(Theme.line.opacity(0.4)), style: StrokeStyle(lineWidth: 0.5, dash: [2, 6]))
            }
            for wall in Wall.allCases where !outdoor {
                for i in 0..<room.length(of: wall) where !doorCells.contains(room.cell(on: wall, at: i)) {
                    let (p, q) = segment(wall, i)
                    var l = Path(); l.move(to: p); l.addLine(to: q)
                    ctx.stroke(l, with: .color(Theme.dim.opacity(outdoor ? 0.35 : 0.9)), style: StrokeStyle(lineWidth: outdoor ? 1 : 3, lineCap: .square, dash: outdoor ? [4, 4] : []))
                }
            }
            // Windows: blue strips on the wall.
            for o in room.windows { for i in 0..<max(1, o.width) {
                let (p, q) = segment(o.wall, o.at + i)
                var l = Path(); l.move(to: p); l.addLine(to: q)
                ctx.stroke(l, with: .color(Color(red: 0.45, green: 0.75, blue: 1)), lineWidth: 4)
            } }
            // Doors: a thin line swung open into the room (none in the open air).
            for o in outdoor ? [] : room.doors { for i in 0..<max(1, o.width) {
                let (p, q) = segment(o.wall, o.at + i)
                let inward = o.wall.facing.opposite
                var l = Path(); l.move(to: p)
                l.addLine(to: CGPoint(x: p.x + CGFloat(inward.dx) * s * 0.8 + (q.x - p.x) * 0.2, y: p.y + CGFloat(inward.dy) * s * 0.8 + (q.y - p.y) * 0.2))
                ctx.stroke(l, with: .color(Theme.fg.opacity(0.8)), lineWidth: 1)
            } }
            // Doors: a small icon just inside the wall (tap it for where it leads).
            for o in room.doors {
                let (p, q) = segment(o.wall, o.at)
                let mid = CGPoint(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2)
                // Drawn just inside the wall, reading away from it, so the map's edge never cuts it off.
                let off: CGPoint
                let anchor: UnitPoint
                switch o.wall {
                case .north: off = CGPoint(x: 0, y: 6); anchor = .top
                case .south: off = CGPoint(x: 0, y: -6); anchor = .bottom
                case .west: off = CGPoint(x: 5, y: 0); anchor = .leading
                case .east: off = CGPoint(x: -5, y: 0); anchor = .trailing
                }
                let icon = o.open == true ? "door.left.hand.open" : "door.left.hand.closed"
                ctx.draw(Text(Image(systemName: icon)).font(.system(size: 11)).foregroundColor(Theme.dim), at: CGPoint(x: mid.x + off.x, y: mid.y + off.y), anchor: anchor)
            }
        }
    }

    private func objectView(_ t: Thing, s: CGFloat, dimmed: Bool) -> some View {
        let w = CGFloat(max(1, t.w)) * s, d = CGFloat(max(1, t.d)) * s
        let on = lit.contains(t.id)
        return ZStack {
            RoundedRectangle(cornerRadius: t.icon == "rug" ? 2 : 5)
                .fill(t.icon == "rug" ? Theme.accent.opacity(0.06) : Theme.line.opacity(0.9))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(on ? Theme.accent : Theme.dim.opacity(0.4), lineWidth: on ? 2 : 0.5))
                .frame(width: w - 3, height: d - 3)
            VStack(spacing: 0) {
                Image(systemName: Rules.symbol(t.icon)).font(.system(size: min(14, s * 0.4))).foregroundStyle(Theme.dim)
                Text(label(t.name)).font(.system(size: 8)).foregroundStyle(Theme.fg.opacity(0.85))
                    .lineLimit(w > s ? 1 : 2).minimumScaleFactor(0.5).multilineTextAlignment(.center)
                    .frame(maxWidth: w - 4)
            }
        }
        .opacity(dimmed ? 0.36 : 1)
        .scaleEffect(on ? 1.06 : 1)
        .allowsHitTesting(false)
    }

    private func smallView(_ t: Thing, room: Room, s: CGFloat, dimmed: Bool) -> some View {
        let on = lit.contains(t.id)
        return Image(systemName: Rules.symbol(t.icon))
            .font(.system(size: max(7, s * 0.24)))
            .foregroundStyle(on ? Theme.accent : Theme.fg.opacity(0.7))
            .opacity(dimmed ? 0.32 : 1)
            .scaleEffect(on ? 1.4 : 1)
            .allowsHitTesting(false)
    }

    /// A person: a round token with a bright arc on the side they face, their initial, and their name under it.
    private func token(_ p: Thing, room: Room, s: CGFloat, pov: Thing?, a: Adventure) -> some View {
        let size = max(14, s * 0.72)
        let me = p.kind == .player
        let on = lit.contains(p.id)
        let isPOV = pov?.id == p.id
        let colour = me ? Theme.accent : Color(red: 0.95, green: 0.72, blue: 0.42)
        let hidden = isDimmed(p, in: room, from: pov)
        return ZStack {
            Circle().fill(Theme.bg).frame(width: size, height: size)
            Circle().stroke(colour.opacity(isPOV ? 0.95 : (hidden ? 0.3 : 0.55)), lineWidth: isPOV ? 2 : 1.5).frame(width: size, height: size)
            // The facing arc, like a compass bezel.
            Circle().trim(from: 0, to: 0.25)
                .stroke(colour, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .frame(width: size, height: size)
                .rotationEffect(.radians(p.facing.angle - .pi / 2 - .pi / 4))
            Text(me ? "You".prefix(1) : p.name.prefix(1)).font(.system(size: size * 0.45, weight: .bold)).foregroundStyle(colour.opacity(hidden ? 0.45 : 1))
            if !p.holding.isEmpty {
                Circle().fill(Theme.fg).frame(width: 4, height: 4)
                    .offset(x: size * 0.5)
                    .rotationEffect(.radians(p.facing.angle - .pi / 2 + .pi / 3))
            }
            Text(me ? "You" : label(displayName(p, in: a))).lineLimit(1).font(.system(size: 9, weight: isPOV ? .bold : .regular)).foregroundStyle(Theme.fg.opacity(hidden ? 0.5 : 1))
                .lineLimit(1).fixedSize()
                .offset(y: size * 0.5 + 7)
        }
        .scaleEffect(on ? 1.25 : 1)
        .shadow(color: on ? colour : (isPOV ? colour.opacity(0.35) : .clear), radius: on ? 6 : 4)
        .allowsHitTesting(false)
    }

    /// A count badge on squares holding more than one thing.
    private func badges(_ room: Room, s: CGFloat, ox: CGFloat, oy: CGFloat) -> some View {
        var counts: [Cell: Int] = [:]
        for t in room.things where t.icon != "rug" { for c in t.cells { counts[c, default: 0] += 1 } }
        // A big piece of furniture alone doesn't count as a stack.
        let stacked = counts.filter { $0.value > 1 }.map(\.key).sorted { ($0.y, $0.x) < ($1.y, $1.x) }
        return ForEach(stacked, id: \.self) { c in
            Text("\(counts[c] ?? 0)")
                .font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.bg)
                .padding(.horizontal, 3)
                .background(Theme.accent, in: Capsule())
                .position(x: ox + (CGFloat(c.x) + 0.85) * s, y: oy + (CGFloat(c.y) + 0.15) * s)
                .allowsHitTesting(false)
        }
    }

    private func label(_ name: String) -> String {
        let n = name.hasPrefix("the ") || name.hasPrefix("The ") ? String(name.dropFirst(4)) : name
        let bare = n.hasPrefix("a ") ? String(n.dropFirst(2)) : n.hasPrefix("an ") ? String(n.dropFirst(3)) : n
        return bare.count > 14 ? String(bare.prefix(13)) + "…" : bare
    }

    // MARK: Cards kept open under the map

    private var pinned: [String] { pinnedRaw.split(separator: "|").map(String.init).filter { !$0.isEmpty } }
    private func key(_ t: Thing) -> String { t.kind == .player ? "you" : t.name.lowercased() }

    /// Opens exactly these cards, in this order, and closes every other one. Tapping the same
    /// square again (or an empty one) closes them all.
    private func show(_ keys: [String]) {
        var seen = Set<String>()
        let list = keys.filter { seen.insert($0).inserted }
        withAnimation(.snappy) { pinnedRaw = (list == pinned ? [] : list).joined(separator: "|") }
    }

    private static let roomKey = "#room"
    private static let doorKey = "#door:"

    /// How far a tap (in squares) is from the middle of a door.
    private static func doorGap(_ o: Opening, _ fx: CGFloat, _ fy: CGFloat, _ room: Room) -> CGFloat {
        let along = CGFloat(o.at) + CGFloat(max(1, o.width)) / 2
        let p: CGPoint
        switch o.wall {
        case .north: p = CGPoint(x: along, y: 0)
        case .south: p = CGPoint(x: along, y: CGFloat(room.depth))
        case .west: p = CGPoint(x: 0, y: along)
        case .east: p = CGPoint(x: CGFloat(room.width), y: along)
        }
        return hypot(p.x - fx, p.y - fy)
    }

    private func unpin(_ k: String) {
        withAnimation(.snappy) { pinnedRaw = pinned.filter { $0 != k }.joined(separator: "|") }
    }

    @ViewBuilder
    private func pinnedCards(_ a: Adventure, _ room: Room) -> some View {
        let shown: [Thing] = pinned.compactMap { k in room.things.first { key($0) == k } }
        if pinned.contains(Self.roomKey) {
            roomCard(a, room).transition(.move(edge: .top).combined(with: .opacity))
        }
        ForEach(room.doors.filter { pinned.contains(Self.doorKey + $0.id.uuidString) }) { o in
            doorCard(o).transition(.move(edge: .top).combined(with: .opacity))
        }
        ForEach(shown) { t in
            thingCard(t, a, room)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    /// Every row a person's or thing's card can show, in its usual order: the map's own fields,
    /// then what their story card holds.
    private func rows(_ t: Thing, _ a: Adventure, _ room: Room) -> [(String, String)] {
        var spot: String = Fovea.gridSpot(a, t.name) ?? ""
        if t.kind == .player {
            spot = Fovea.youAt(room, t)
        } else if room.player == nil {
            spot = "at \(t.x), \(t.y)"
        }
        // Most important first: with nothing changing, a card shows its top five.
        var out: [(String, String)] = []
        if t.isPerson {
            if t.kind == .player {
                out += [("Where", spot), ("Doing", t.doing), ("Feels", t.feeling), ("You have", a.carrying.joined(separator: ", ")),
                        ("Holding", t.holding.joined(separator: ", ")), ("Wearing", t.wearing), ("Expression", t.expression)]
            } else {
                let k = t.name.lowercased()
                let card = a.lore.first(where: { $0.name == t.name })
                out += [("Doing", t.doing), ("Said", t.dialogue.last ?? ""), ("Feels", t.feeling), ("Wants", a.wants[k] ?? card?.wants ?? ""), ("Where", spot),
                        ("Holding", t.holding.joined(separator: ", ")), ("Wearing", Fovea.outfit(t, card)), ("Expression", t.expression),
                        ("Knows of you", (a.knows[k] ?? []).joined(separator: "; ")), ("Between you", (a.between[k] ?? []).joined(separator: "; "))]
                if let c = a.lore.first(where: { $0.name == t.name }) {
                    out += [("Who", c.desc), ("Looks", c.looks), ("Voice", c.voice), ("Habit", c.habit)]
                }
            }
        } else {
            let on = room.things.filter { $0.on == t.id }.map { $0.kind == .player ? "you" : $0.name }
            out += [("Where", spot), ("Made of", t.makeup), ("State", t.state), ("On it", on.joined(separator: ", ")), ("Size", "\(t.w) × \(t.d) m")]
        }
        return out
    }

    /// Everything the cards could show, as one string: when it changes, `track` finds which rows did.
    private func signature(_ a: Adventure, _ room: Room) -> String {
        room.things.map { t in rows(t, a, room).map(\.1).joined(separator: "|") }.joined(separator: "#")
    }

    /// Notes which rows changed, so each card brings them to the top.
    private func track(_ a: Adventure, _ room: Room, mark: Bool) {
        let now = Date()
        var at = rowAt
        for t in room.things {
            for (label, value) in rows(t, a, room) {
                let k = t.id.uuidString + "|" + label
                if mark, let was = rowWas[k], was != value, !value.isEmpty { at[k] = now }
                rowWas[k] = value
            }
        }
        withAnimation(.snappy) { rowAt = at }
    }

    /// One open card, small enough to sit under the map. While the model is writing to it, the
    /// rows it just changed (in the last half minute) light up and move to the top; otherwise it
    /// shows its five most important rows. View opens everything.
    private func thingCard(_ t: Thing, _ a: Adventure, _ room: Room) -> some View {
        let all = rows(t, a, room).filter { !$0.1.isEmpty }
        let base = Dictionary(all.enumerated().map { ($0.element.0, $0.offset) }, uniquingKeysWith: { a, _ in a })
        func when(_ label: String) -> Double {
            guard let d = rowAt[t.id.uuidString + "|" + label], Date().timeIntervalSince(d) < 30 else { return 0 }
            return d.timeIntervalSince1970
        }
        let shown = all.sorted { x, y in
            let wx = when(x.0), wy = when(y.0)
            return wx != wy ? wx > wy : (base[x.0] ?? 0) < (base[y.0] ?? 0)
        }.prefix(5)
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 8) {
                Image(systemName: t.isPerson ? "person.fill" : Rules.symbol(t.icon)).font(.caption).foregroundStyle(Theme.accent)
                Text(t.kind == .player ? (a.playerName.isEmpty ? "You" : a.playerName) : t.name).font(.subheadline.bold()).foregroundStyle(Theme.fg).lineLimit(1)
                Spacer(minLength: 0)
                if t.isPerson {
                    let looking = (povID == nil && t.kind == .player) || povID == t.id
                    Button {
                        withAnimation(.snappy) {
                            povID = (povID == t.id || t.kind == .player) ? nil : t.id
                        }
                    } label: {
                        Image(systemName: looking ? "eye.fill" : "eye")
                            .font(.caption.bold())
                            .foregroundStyle(looking ? Theme.accent : Theme.dim)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Look through \(displayName(t, in: a))'s eyes")
                }
                Button(all.count > 5 ? "View all \(all.count)" : "View") { editing = t }.font(.caption.bold())
                Button { unpin(key(t)) } label: { Image(systemName: "xmark").font(.caption.bold()) }
                    .foregroundStyle(Theme.dim)
            }
            .padding(.bottom, 3)
            ForEach(Array(shown), id: \.0) { row in
                FlashRow(label: row.0, value: row.1, lines: 2)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.snappy, value: shown.map(\.0))
        .padding(10)
        .background(Theme.bg.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(lit.contains(t.id) ? Theme.accent : Theme.line))
    }

    private func roomCard(_ a: Adventure, _ room: Room) -> some View {
        let doors = room.doors.map { ($0.leadsTo.isEmpty ? "a door" : "to " + $0.leadsTo) + " (" + $0.wall.rawValue + ")" }
        let sound = room.sound.isEmpty ? (a.ambience[a.location.lowercased()] ?? "") : room.sound
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 8) {
                Image(systemName: "square.dashed").font(.caption).foregroundStyle(Theme.accent)
                Text(room.name).font(.subheadline.bold()).foregroundStyle(Theme.fg).lineLimit(1)
                Spacer(minLength: 0)
                Button { unpin(Self.roomKey) } label: { Image(systemName: "xmark").font(.caption.bold()) }
                    .foregroundStyle(Theme.dim)
            }
            .padding(.bottom, 3)
            FlashRow(label: "Outside", value: room.outside, lines: 2)
            FlashRow(label: "Inside", value: room.inside, lines: 2)
            FlashRow(label: "Sounds", value: sound, lines: 2)
            FlashRow(label: "Size", value: "\(room.width) × \(room.depth) m", lines: 1)
            FlashRow(label: "Doors", value: doors.joined(separator: ", "), lines: 2)
            if !room.windows.isEmpty { FlashRow(label: "Windows", value: "\(room.windows.count)", lines: 1) }
        }
        .padding(10)
        .background(Theme.bg.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
    }

    private func doorCard(_ o: Opening) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 8) {
                Image(systemName: o.open == true ? "door.left.hand.open" : "door.left.hand.closed").font(.caption).foregroundStyle(Theme.accent)
                Text("Door").font(.subheadline.bold()).foregroundStyle(Theme.fg).lineLimit(1)
                Spacer(minLength: 0)
                Button { unpin(Self.doorKey + o.id.uuidString) } label: { Image(systemName: "xmark").font(.caption.bold()) }
                    .foregroundStyle(Theme.dim)
            }
            .padding(.bottom, 3)
            FlashRow(label: "Leads to", value: o.leadsTo, lines: 2)
            FlashRow(label: "State", value: o.open == true ? "open" : "closed", lines: 1)
            FlashRow(label: "Wall", value: o.wall.rawValue, lines: 1)
        }
        .padding(10)
        .background(Theme.bg.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
    }

    /// Lights up whatever changed since last time, for a beat.
    private func spark(_ room: Room) {
        var changed: Set<UUID> = []
        for t in room.things where looks[t.id] != t.look { changed.insert(t.id) }
        looks = Dictionary(room.things.map { ($0.id, $0.look) }, uniquingKeysWith: { a, _ in a })
        guard !changed.isEmpty else { return }
        beat += 1
        let mine = beat
        withAnimation(.easeOut(duration: 0.15)) { lit.formUnion(changed) }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3.5))
            if mine == beat { withAnimation(.easeInOut(duration: 0.9)) { lit = [] } }
        }
    }
}

/// The card of a person or thing on the map: every property, editable. Your edit wins.
struct ThingCard: View {
    @Environment(\.dismiss) private var dismiss
    @State var thing: Thing
    let room: Room
    /// Everything the card under the map knows about them, shown read-only at the top.
    var details: [(String, String)] = []
    let onSave: (Thing) -> Void

    var body: some View {
        NavigationStack {
            Form {
                if details.contains(where: { !$0.1.isEmpty }) {
                    Section("Everything known") {
                        ForEach(details.filter { !$0.1.isEmpty }, id: \.0) { row in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.0).font(.caption.bold()).foregroundStyle(.secondary)
                                Text(row.1).font(.callout)
                            }
                        }
                    }
                }
                Section("Edit") {
                    TextField("Name", text: $thing.name)
                    if !thing.isPerson {
                        Picker("Kind", selection: $thing.icon) { ForEach(Rules.kinds, id: \.self) { Text($0).tag($0) } }
                    }
                    LabeledContent("Square", value: "\(thing.x + 1), \(thing.y + 1)" + (thing.w > 1 || thing.d > 1 ? " (\(thing.w) × \(thing.d) m)" : ""))
                    if let o = room.thing(thing.on) { LabeledContent(thing.isPerson ? "Sitting on" : "On", value: o.name) }
                    if thing.isPerson {
                        Picker("Facing", selection: $thing.facing) { ForEach(Facing.allCases, id: \.self) { Text($0.word).tag($0) } }
                    }
                }
                if thing.isPerson {
                    Section("Now") {
                        field("Expression", $thing.expression)
                        field("Doing", $thing.doing)
                        field("Feeling", $thing.feeling)
                        field("Wearing", $thing.wearing)
                        field("Holding", Binding(get: { thing.holding.joined(separator: "; ") },
                                                 set: { thing.holding = $0.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }))
                    }
                    if thing.kind != .player {
                        Section("Backstory") {
                            TextField("Who they are", text: $thing.backstory, axis: .vertical).lineLimit(2...8)
                        }
                    }
                    if !thing.dialogue.isEmpty {
                        Section("Said") { ForEach(Array(thing.dialogue.enumerated()), id: \.offset) { _, l in Text("“" + l + "”").font(.callout) } }
                    }
                    if !thing.pastMoves.isEmpty {
                        Section("Past moves") { ForEach(Array(thing.pastMoves.enumerated()), id: \.offset) { _, l in Text(l).font(.callout) } }
                    }
                } else {
                    Section("Details") {
                        field("Made of", $thing.makeup)
                        field("State", $thing.state)
                        Picker("Blocks", selection: $thing.blocks) {
                            Text("nothing").tag(Blocks.none); Text("the way").tag(Blocks.way); Text("the view").tag(Blocks.view); Text("both").tag(Blocks.both)
                        }
                    }
                    let on = room.things.filter { $0.on == thing.id }
                    if !on.isEmpty { Section("On it") { ForEach(on) { Text($0.kind == .player ? "You" : $0.name) } } }
                }
            }
            .navigationTitle(thing.kind == .player ? "You" : thing.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { onSave(thing); dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func field(_ label: String, _ text: Binding<String>) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.caption.bold()).foregroundStyle(.secondary).frame(width: 82, alignment: .leading)
            TextField(label, text: text, axis: .vertical)
        }
    }
}
