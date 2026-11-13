import SwiftUI

/// The World panel's map: the room you are in, drawn from above, one square per metre. People are
/// round tokens with a bright arc on the side they face; two people facing each other are joined by
/// a faint eye-line. Your view cone is shaded. Tap a square to see everything on it, and tap a person
/// or thing to open its card. Anything a question changes sparks.
struct RoomMapView: View {
    @Environment(AppModel.self) private var app
    /// The room shown (nil: the one you are in).
    @State private var shownID: UUID?
    @State private var editing: Thing?
    @State private var stackAt: StackPick?
    /// What each thing looked like last time, to tell what changed.
    @State private var looks: [UUID: String] = [:]
    @State private var lit: Set<UUID> = []
    @State private var beat = 0
    /// The map's zoom and pan (pinch and drag on the map only).
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var drag: CGSize = .zero

    struct StackPick: Identifiable { var id: String { "\(cell.x),\(cell.y)" }; var cell: Cell }

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
            VStack(alignment: .leading, spacing: 8) {
                header(a, room: room, here: here)
                ticker(a, room)
                map(room, live: room.id == here?.id)
                    .onAppear { looks = Dictionary(room.things.map { ($0.id, $0.look) }, uniquingKeysWith: { a, _ in a }) }
                    .onChange(of: room.things.map(\.look)) { _, _ in spark(room) }
            }
            .padding(10)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
            .sheet(item: $editing) { t in
                ThingCard(thing: t, room: room) { app.engine.saveThing($0, in: room.id) }
            }
            .sheet(item: $stackAt) { pick in
                stackList(room, pick.cell)
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

    @ViewBuilder
    private func ticker(_ a: Adventure, _ room: Room) -> some View {
        let asking = app.engine.rebuildStep.isEmpty ? app.engine.stage : app.engine.rebuildStep
        let items = feed(a, room)
        if !items.isEmpty || !asking.isEmpty {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                            HStack(spacing: 4) {
                                Image(systemName: item.kind == 1 ? "checkmark" : (item.kind == 2 ? "xmark" : "sparkle"))
                                    .font(.caption2.bold())
                                    .foregroundStyle(item.kind == 2 ? Color.red.opacity(0.9) : (item.kind == 1 ? Theme.dim : Theme.accent))
                                Text(item.text).font(.caption)
                                    .foregroundStyle(item.kind == 2 ? Color.red.opacity(0.9) : Theme.fg)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(Theme.accent.opacity(item.kind == 0 ? 0.12 : 0.06), in: Capsule())
                            .id(i)
                        }
                        if !asking.isEmpty {
                            HStack(spacing: 4) {
                                HoloCore(size: 14)
                                Text(Continuity.unnamed(asking, in: a)).font(.caption.bold()).foregroundStyle(Theme.accent).lineLimit(1)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(Theme.accent.opacity(0.15), in: Capsule())
                            .id(-1)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .onAppear { proxy.scrollTo(asking.isEmpty ? items.count - 1 : -1, anchor: .trailing) }
                .onChange(of: items.count) { _, n in
                    withAnimation(.snappy) { proxy.scrollTo(asking.isEmpty ? n - 1 : -1, anchor: .trailing) }
                }
                .onChange(of: asking) { _, q in
                    withAnimation(.snappy) { proxy.scrollTo(q.isEmpty ? items.count - 1 : -1, anchor: .trailing) }
                }
            }
            .animation(.snappy, value: asking)
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
        case "ask": return "Asked again: " + rest
        case "enter": return rest.prefix(1).uppercased() + rest.dropFirst()
        case "leave": return rest + " leaves"
        case "edit": return "Edited " + rest
        default: return l
        }
    }

    // MARK: The map

    private func map(_ room: Room, live: Bool) -> some View {
        GeometryReader { g in
            let s = max(12, min(44, (g.size.width - 8) / CGFloat(max(1, room.width))))
            let ox = (g.size.width - s * CGFloat(room.width)) / 2
            let oy: CGFloat = 4
            ZStack(alignment: .topLeading) {
                floor(room, s: s, ox: ox, oy: oy, live: live)
                ForEach(room.objects.filter { $0.on == nil }) { t in
                    objectView(t, s: s).position(x: ox + CGFloat(t.centre.x) * s, y: oy + CGFloat(t.centre.y) * s)
                }
                ForEach(room.objects.filter { $0.on != nil }) { t in
                    smallView(t, room: room, s: s).position(x: ox + (CGFloat(t.x) + 0.72) * s, y: oy + (CGFloat(t.y) + 0.3) * s)
                }
                ForEach(room.people) { p in
                    token(p, room: room, s: s).position(x: ox + CGFloat(p.centre.x) * s, y: oy + CGFloat(p.centre.y) * s)
                }
                badges(room, s: s, ox: ox, oy: oy)
            }
            .contentShape(Rectangle())
            .onTapGesture { pt in
                let c = Cell(x: Int((pt.x - ox) / s), y: Int((pt.y - oy) / s))
                guard room.contains(c) else { return }
                let stack = room.stack(at: c)
                if stack.count == 1 { editing = stack[0] } else if stack.count > 1 { stackAt = StackPick(cell: c) }
            }
            .animation(.spring(response: 0.5, dampingFraction: 0.8), value: room.things.map(\.look))
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

    /// The floor, walls, windows, doors, your view cone and the eye-lines.
    private func floor(_ room: Room, s: CGFloat, ox: CGFloat, oy: CGFloat, live: Bool) -> some View {
        Canvas { ctx, _ in
            let W = CGFloat(room.width) * s, D = CGFloat(room.depth) * s
            let box = CGRect(x: ox, y: oy, width: W, height: D)
            ctx.fill(Path(box), with: .color(Theme.bg))
            // The squares.
            var grid = Path()
            for i in 1..<max(2, room.width) { grid.move(to: CGPoint(x: ox + CGFloat(i) * s, y: oy)); grid.addLine(to: CGPoint(x: ox + CGFloat(i) * s, y: oy + D)) }
            for j in 1..<max(2, room.depth) { grid.move(to: CGPoint(x: ox, y: oy + CGFloat(j) * s)); grid.addLine(to: CGPoint(x: ox + W, y: oy + CGFloat(j) * s)) }
            ctx.stroke(grid, with: .color(Theme.line.opacity(0.6)), lineWidth: 0.5)
            // Your view cone: 120 degrees, out to the walls.
            if live, let me = room.player {
                let c = CGPoint(x: ox + CGFloat(me.centre.x) * s, y: oy + CGFloat(me.centre.y) * s)
                let start = Angle(radians: me.facing.angle - .pi / 2 - .pi / 3)
                let end = Angle(radians: me.facing.angle - .pi / 2 + .pi / 3)
                var cone = Path()
                cone.move(to: c)
                cone.addArc(center: c, radius: max(W, D) * 1.5, startAngle: start, endAngle: end, clockwise: false)
                cone.closeSubpath()
                var clipped = ctx
                clipped.clip(to: Path(box))
                clipped.fill(cone, with: .color(Theme.accent.opacity(0.10)))
            }
            // Eye-lines between people facing each other.
            let people = room.people
            for i in people.indices { for j in people.indices where j > i {
                let a = people[i], b = people[j]
                guard RoomGrid.faceEachOther(a, b) else { continue }
                var l = Path()
                l.move(to: CGPoint(x: ox + CGFloat(a.centre.x) * s, y: oy + CGFloat(a.centre.y) * s))
                l.addLine(to: CGPoint(x: ox + CGFloat(b.centre.x) * s, y: oy + CGFloat(b.centre.y) * s))
                ctx.stroke(l, with: .color(Theme.accent.opacity(0.55)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
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
            for wall in Wall.allCases {
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
            // Doors: a thin line swung open into the room.
            for o in room.doors { for i in 0..<max(1, o.width) {
                let (p, q) = segment(o.wall, o.at + i)
                let inward = o.wall.facing.opposite
                var l = Path(); l.move(to: p)
                l.addLine(to: CGPoint(x: p.x + CGFloat(inward.dx) * s * 0.8 + (q.x - p.x) * 0.2, y: p.y + CGFloat(inward.dy) * s * 0.8 + (q.y - p.y) * 0.2))
                ctx.stroke(l, with: .color(Theme.fg.opacity(0.8)), lineWidth: 1)
            } }
            // Door labels: where they lead.
            for o in room.doors where !o.leadsTo.isEmpty {
                let (p, q) = segment(o.wall, o.at)
                let mid = CGPoint(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2)
                let off: CGPoint
                switch o.wall {
                case .north: off = CGPoint(x: 0, y: -7)
                case .south: off = CGPoint(x: 0, y: 9)
                case .west: off = CGPoint(x: 4, y: 0)
                case .east: off = CGPoint(x: -4, y: 0)
                }
                ctx.draw(Text("→ " + o.leadsTo).font(.system(size: 9)).foregroundColor(Theme.dim), at: CGPoint(x: mid.x + off.x, y: mid.y + off.y))
            }
        }
    }

    private func objectView(_ t: Thing, s: CGFloat) -> some View {
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
        .scaleEffect(on ? 1.06 : 1)
        .allowsHitTesting(false)
    }

    private func smallView(_ t: Thing, room: Room, s: CGFloat) -> some View {
        let on = lit.contains(t.id)
        return Image(systemName: Rules.symbol(t.icon))
            .font(.system(size: max(7, s * 0.24)))
            .foregroundStyle(on ? Theme.accent : Theme.fg.opacity(0.7))
            .scaleEffect(on ? 1.4 : 1)
            .allowsHitTesting(false)
    }

    /// A person: a round token with a bright arc on the side they face, their initial, and their name under it.
    private func token(_ p: Thing, room: Room, s: CGFloat) -> some View {
        let size = max(14, s * 0.72)
        let me = p.kind == .player
        let on = lit.contains(p.id)
        let colour = me ? Theme.accent : Color(red: 0.95, green: 0.72, blue: 0.42)
        let heard: Bool = {
            guard !me, let you = room.player else { return false }
            if case .behind = RoomGrid.seen(room, from: you, to: p) { return true }
            if case .hidden = RoomGrid.seen(room, from: you, to: p) { return true }
            return false
        }()
        return ZStack {
            Circle().fill(Theme.bg).frame(width: size, height: size)
            Circle().stroke(colour.opacity(heard ? 0.35 : 0.5), lineWidth: 1.5).frame(width: size, height: size)
            // The facing arc, like a compass bezel.
            Circle().trim(from: 0, to: 0.25)
                .stroke(colour, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .frame(width: size, height: size)
                .rotationEffect(.radians(p.facing.angle - .pi / 2 - .pi / 4))
            Text(me ? "You".prefix(1) : p.name.prefix(1)).font(.system(size: size * 0.45, weight: .bold)).foregroundStyle(colour.opacity(heard ? 0.5 : 1))
            if !p.holding.isEmpty {
                Circle().fill(Theme.fg).frame(width: 4, height: 4)
                    .offset(x: size * 0.5)
                    .rotationEffect(.radians(p.facing.angle - .pi / 2 + .pi / 3))
            }
            Text(me ? "You" : label(p.name)).font(.system(size: 9, weight: me ? .bold : .regular)).foregroundStyle(Theme.fg)
                .lineLimit(1).fixedSize()
                .offset(y: size * 0.5 + 7)
        }
        .scaleEffect(on ? 1.25 : 1)
        .shadow(color: on ? colour : .clear, radius: on ? 6 : 0)
        .allowsHitTesting(false)
    }

    /// A count badge on squares holding more than one thing.
    private func badges(_ room: Room, s: CGFloat, ox: CGFloat, oy: CGFloat) -> some View {
        var counts: [Cell: Int] = [:]
        for t in room.things { for c in t.cells { counts[c, default: 0] += 1 } }
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

    private func stackList(_ room: Room, _ c: Cell) -> some View {
        NavigationStack {
            List(room.stack(at: c)) { t in
                Button {
                    stackAt = nil
                    Task { @MainActor in try? await Task.sleep(for: .seconds(0.35)); editing = t }
                } label: {
                    HStack {
                        Image(systemName: t.isPerson ? "person.fill" : Rules.symbol(t.icon)).foregroundStyle(Theme.accent).frame(width: 24)
                        VStack(alignment: .leading) {
                            Text(t.kind == .player ? "You" : t.name).foregroundStyle(Theme.fg)
                            if let o = room.thing(t.on) { Text("on " + o.name).font(.caption).foregroundStyle(Theme.dim) }
                        }
                    }
                }
            }
            .navigationTitle("On this square")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
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
            try? await Task.sleep(for: .seconds(1.8))
            if mine == beat { withAnimation(.easeInOut(duration: 0.9)) { lit = [] } }
        }
    }
}

/// The card of a person or thing on the map: every property, editable. Your edit wins.
struct ThingCard: View {
    @Environment(\.dismiss) private var dismiss
    @State var thing: Thing
    let room: Room
    let onSave: (Thing) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
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
