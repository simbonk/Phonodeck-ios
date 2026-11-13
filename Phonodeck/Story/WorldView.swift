import SwiftUI

/// The World button: the world as it is this turn, with a live feed of how each turn was worked
/// out, and the people, place and facts in view.
struct WorldView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var bible = ""
    @State private var editing: LoreEntry?
    /// The bible as the panel shows it (names not said yet are shown as roles), to tell an edit apart.
    @State private var shownBible = ""
    @State private var myName = ""
    /// The turn the turn guide shows (nil: the latest, following play live).
    @State private var frameAt: Int?
    /// Every question in the turn feed open (otherwise only the one just answered is).
    @State private var expandAll = false
    /// The world card's rows shown in full (otherwise clipped to a line or two, to fit one screen).
    @State private var wide = false
    /// Which of the cards under the world card are open.
    @State private var openCards: Set<String> = []
    /// The name as the panel last showed it, to tell the player's own edit apart.
    @State private var shownName = ""

    var body: some View {
        NavigationStack {
            Group {
                if let a = app.engine.adventure {
                    VStack(spacing: 0) {
                        // The world, as it is this turn (the Mission and Story tabs are gone).
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                world(a)
                            }
                            .padding()
                            .frame(maxWidth: 760)
                            .frame(maxWidth: .infinity)
                        }
                        .scrollDismissesKeyboard(.interactively)
                    }
                    .onAppear {
                        shownBible = Continuity.unnamed(a.bible, in: a)
                        bible = shownBible
                        myName = a.playerName
                        shownName = a.playerName
                    }
                    // A name said in the story while the panel is open shows up here too.
                    .onChange(of: a.playerName) { _, n in
                        if myName == shownName { myName = n }
                        shownName = n
                    }
                    // The guide follows play: a new turn brings it back to the latest.
                    .onChange(of: a.frames.count) { _, _ in withAnimation(.snappy) { frameAt = nil } }
                }
            }
            .background(Theme.bg)
            .navigationTitle(app.engine.adventure?.title ?? "World")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { saveBible(); if myName != shownName { app.engine.setPlayerName(myName) }; dismiss() }
                }
            }
            .sheet(item: $editing) { e in
                LoreEditor(entry: e) { app.engine.saveLore($0) } onDelete: { app.engine.deleteLore($0.id) }
            }
        }
    }

    private func saveBible() {
        if app.engine.adventure != nil, bible != shownBible, !bible.isEmpty { app.engine.editBible(bible); shownBible = bible }
    }

    // MARK: World (lore)

    @ViewBuilder
    private func world(_ a: Adventure) -> some View {
        RoomMapView()
        if !a.frames.isEmpty { turnGuide(a) }
        Button {
            editing = LoreEntry(name: "", kind: .person)
        } label: {
            Label("Add a person or thing", systemImage: "plus")
        }
        .buttonStyle(.bordered)
        .padding(.top, 4)
    }

    private func title(_ k: LoreEntry.Kind) -> String {
        switch k {
        case .person: "Characters"
        case .place: "Places"
        case .item: "Items"
        case .faction: "Factions"
        case .other: "Other"
        }
    }

    /// People the story hasn't named yet are shown by their role, so the panel never gives a name away.
    private func hidden(_ e: LoreEntry, _ a: Adventure) -> Bool {
        e.kind == .person && !e.isPlayer && !e.known && !e.byPlayer && (a.nameless || !e.role.isEmpty)
    }

    private func shown(_ e: LoreEntry, _ a: Adventure) -> String {
        if e.isPlayer { return a.playerName.isEmpty ? "You" : a.playerName }
        guard hidden(e, a) else { return e.name }
        let r = a.nameless ? Continuity.roleLabel(e.role) : e.role
        return r.prefix(1).uppercased() + r.dropFirst()
    }

    /// A person's name as the panel shows it.
    private func display(_ name: String, _ a: Adventure) -> String {
        if let e = a.lore.first(where: { $0.name == name && $0.kind == .person }) { return shown(e, a) }
        return Continuity.unnamed(name, in: a)
    }

    // MARK: Turn guide

    /// One turn at a time, on one screen: a one-line ticker of the question being asked (each
    /// answer flicks through it and out of the way), and under it the world card, whose rows
    /// flash as an answer changes them. It follows play live from the moment the player speaks:
    /// first what is worked out before the reply, then the questions asked after it. Every step
    /// is kept, and "Steps" unfolds them.
    @ViewBuilder
    private func turnGuide(_ a: Adventure) -> some View {
        let last = a.frames.count - 1
        let k = min(max(0, frameAt ?? last), last)
        let f = a.frames[k]
        let live = k == last
        let asking: String = live ? (app.engine.rebuildStep.isEmpty ? app.engine.stage : app.engine.rebuildStep) : ""
        let pre: [String] = f.pre ?? []
        let all: [String] = pre + f.asked
        let busy = live && !asking.isEmpty
        HStack(spacing: 8) {
            Button { withAnimation(.snappy) { frameAt = max(0, k - 1) } } label: { Image(systemName: "chevron.left") }
                .disabled(k == 0)
            HStack(spacing: 6) {
                Text(f.turn == 0 ? "Opening" : "Turn \(f.turn)").font(.headline).foregroundStyle(Theme.accent)
                    .contentTransition(.numericText())
                Text(live ? (busy ? "live" : "latest") : "\(last - k) back")
                    .font(.caption2.bold()).foregroundStyle(busy ? Theme.bg : Theme.dim)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(busy ? Theme.accent : Theme.line.opacity(0.5), in: Capsule())
            }
            .frame(maxWidth: .infinity)
            Button { withAnimation(.snappy) { frameAt = k + 1 >= last ? nil : k + 1 } } label: { Image(systemName: "chevron.right") }
                .disabled(k == last)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)

        // Every step of the turn, folded away until asked for.
        Button {
            withAnimation(.snappy) { expandAll.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: expandAll ? "chevron.down" : "chevron.right").font(.caption2.bold())
                Text("Steps this turn (\(all.count))").font(.caption.bold())
                Spacer()
                let n = f.changed.count
                if n > 0 { Text("\(n) change\(n == 1 ? "" : "s")").font(.caption2.bold()) }
            }
            .foregroundStyle(Theme.accent)
        }
        .buttonStyle(.plain)
        if expandAll {
            VStack(alignment: .leading, spacing: 4) {
                if !pre.isEmpty { Text("After you spoke").font(.caption2.bold()).foregroundStyle(Theme.dim) }
                ForEach(Array(pre.enumerated()), id: \.offset) { _, line in
                    step(line, changes: [], a)
                }
                if !f.asked.isEmpty { Text("After the reply").font(.caption2.bold()).foregroundStyle(Theme.dim).padding(.top, 2) }
                ForEach(Array(f.asked.enumerated()), id: \.offset) { i, line in
                    step(line, changes: (f.steps ?? []).indices.contains(i) ? f.steps![i] : [], a)
                }
                if !f.changed.isEmpty {
                    Text("What changed").font(.caption2.bold()).foregroundStyle(Theme.dim).padding(.top, 2)
                    ForEach(Array(f.changed.enumerated()), id: \.offset) { _, c in
                        Label(Continuity.unnamed(c, in: a), systemImage: "sparkle").font(.caption).foregroundStyle(Theme.fg)
                    }
                }
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
            .padding(.bottom, 6)
        }
    }

    /// The ticker's line for a finished step: the question, its answer, and how much it changed.
    private func tickerLine(_ line: String, changes: Int, _ a: Adventure) -> some View {
        let parts = line.components(separatedBy: " → ")
        let q: String = parts.first ?? line
        let ans: String = parts.dropFirst().joined(separator: " → ")
        return HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "checkmark").font(.caption2.bold()).foregroundStyle(Theme.dim)
            Text(Continuity.unnamed(q, in: a)).font(.caption.bold()).foregroundStyle(Theme.dim).lineLimit(1).layoutPriority(1)
            Text(Continuity.unnamed(ans, in: a)).font(.caption).foregroundStyle(Theme.fg).lineLimit(1)
            Spacer(minLength: 0)
            if changes > 0 { Text("+\(changes)").font(.caption2.bold()).foregroundStyle(Theme.accent) }
        }
    }

    /// One step in the unfolded list: the question, its answer, and what it changed.
    private func step(_ line: String, changes: [String], _ a: Adventure) -> some View {
        let parts = line.components(separatedBy: " → ")
        let q: String = parts.first ?? line
        let ans: String = parts.dropFirst().joined(separator: " → ")
        return VStack(alignment: .leading, spacing: 2) {
            Text(Continuity.unnamed(q, in: a)).font(.caption.bold()).foregroundStyle(Theme.dim)
            if !ans.isEmpty { Text(Continuity.unnamed(ans, in: a)).font(.caption).foregroundStyle(Theme.fg) }
            ForEach(Array(changes.enumerated()), id: \.offset) { _, c in
                Label(Continuity.unnamed(c, in: a), systemImage: "sparkle").font(.caption2).foregroundStyle(Theme.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: Cards

    /// Everything the game holds, as cards under the world card: you, the people here, this place,
    /// the facts in view, and what is elsewhere. Each is one line until tapped open, and lights
    /// up with a line saying what changed when a question changes it.
    @ViewBuilder
    private func attributes(_ a: Adventure) -> some View {
        let last = a.frames.count - 1
        let k = a.frames.isEmpty ? -1 : min(max(0, frameAt ?? last), last)
        let changes: [String] = k < 0 ? [] : ((a.frames[k].steps ?? []).flatMap { $0 } + a.frames[k].changed)
        let inView = a.cast.filter { p in a.whereabouts.contains { $0.name == p.name && $0.here != false } }
        let away = a.cast.filter { p in !inView.contains { $0.id == p.id } }

        let mine = latest(changes, a) { $0.hasPrefix("You ") || $0.hasPrefix("Gone from your hands") }
        FoldCard(title: a.playerName.isEmpty ? "You" : a.playerName, tag: "you" + (a.body.isEmpty ? "" : " · " + a.body), marquee: mine,
                 open: openCards.contains("you")) { toggle("you") } content: { youCard(a) }

        ForEach(inView) { p in
            let w = a.whereabouts.first { $0.name == p.name }
            let state: String = w?.engaged == true ? "with you" : "in the room"
            let feels: String = a.feelings[p.name.lowercased()] ?? ""
            let first = Cards.first(p.name)
            FoldCard(title: shown(p, a), tag: [state, feels].filter { !$0.isEmpty }.joined(separator: " · "),
                     marquee: latest(changes, a) { $0.contains(first) }, open: openCards.contains(p.id.uuidString)) { toggle(p.id.uuidString) } content: {
                VStack(alignment: .leading, spacing: 4) {
                    person(p, a)
                    if let want = a.wants[p.name.lowercased()] { attr("Wants", Continuity.unnamed(want, in: a)) }
                    if let knows = a.knows[p.name.lowercased()], !knows.isEmpty { attr("Knows", knows.joined(separator: "; ")) }
                    Button("Edit") { editing = p }.font(.caption.bold()).padding(.top, 2)
                }
            }
        }

        if !a.location.isEmpty {
            let key = a.location.lowercased()
            FoldCard(title: a.location, tag: "this place", marquee: latest(changes, a) { $0.hasPrefix("Props here") || $0.hasPrefix("Background") || $0.hasPrefix("Place") || $0.hasPrefix("New place") || $0.hasPrefix("Moved") || $0.hasPrefix("Arrived") },
                     open: openCards.contains("place")) { toggle("place") } content: {
                VStack(alignment: .leading, spacing: 4) {
                    placeCard(a.location, a)
                    if let sound = a.ambience[key], !sound.isEmpty { attr("Background", sound) }
                }
            }
        }

        let facts = a.facts.filter { f in !Continuity.elsewhereFact(f, in: a) && !away.contains { Cards.mentions($0, in: f) } }
        if !facts.isEmpty {
            FoldCard(title: "Facts in view", tag: "\(facts.count)", marquee: latest(changes, a) { $0.hasPrefix("Fact") || $0.hasPrefix("Learned") },
                     open: openCards.contains("facts")) { toggle("facts") } content: {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(facts.enumerated()), id: \.offset) { _, f in
                        Text("• " + Continuity.unnamed(f, in: a)).font(.caption).foregroundStyle(Theme.fg)
                    }
                }
            }
        }

        // Out of view: people left elsewhere and the other places, kept in one folded card.
        let otherPlaces = a.lore.filter { $0.kind == .place && $0.name.caseInsensitiveCompare(a.location) != .orderedSame }
        if !away.isEmpty || !otherPlaces.isEmpty {
            let names: [String] = away.map { shown($0, a) } + otherPlaces.map(\.name)
            FoldCard(title: "Elsewhere", tag: names.joined(separator: ", "), marquee: latest(changes, a) { $0.hasPrefix("Out of view") },
                     open: openCards.contains("away")) { toggle("away") } content: {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(away) { p in
                        Button { editing = p } label: { person(p, a) }.buttonStyle(.plain)
                    }
                    ForEach(otherPlaces) { p in placeCard(p.name, a) }
                }
            }
        }
    }

    /// The newest change this turn that a card's test picks out, as the panel shows it.
    private func latest(_ changes: [String], _ a: Adventure, _ match: (String) -> Bool) -> String {
        Continuity.unnamed(changes.last(where: match) ?? "", in: a)
    }

    private func toggle(_ key: String) {
        withAnimation(.snappy) {
            if openCards.contains(key) { openCards.remove(key) } else { openCards.insert(key) }
        }
    }

    /// The player's own card: the name, what they have, and who they are.
    @ViewBuilder
    private func youCard(_ a: Adventure) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Name").font(.caption.bold()).foregroundStyle(Theme.dim).frame(width: 92, alignment: .leading)
                TextField("None yet: say it in the story, or type it", text: $myName)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.done)
                    .onSubmit { app.engine.setPlayerName(myName) }
            }
            Text("Only for this story. Characters learn it when you say it to them.").font(.caption).foregroundStyle(Theme.dim)
            Toggle("Hide names until they're said", isOn: Binding(get: { app.engine.adventure?.nameless ?? false },
                                                                 set: { app.engine.setNameless($0) }))
                .font(.subheadline)
                .tint(Theme.accent)
            if !a.carrying.isEmpty { attr("You have", a.carrying.joined(separator: "; ")) }
            if !a.spot.isEmpty { attr("You are", a.spot) }
            if !a.progress.isEmpty { attr("Goal so far", a.progress.joined(separator: " ")) }
            if let me = a.lore.first(where: \.isPlayer) {
                Button { editing = me } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Who you are").font(.caption.bold()).foregroundStyle(Theme.dim).frame(width: 92, alignment: .leading)
                        Text(me.desc.isEmpty ? "Add a line about yourself" : Continuity.unnamed(me.desc, in: a))
                            .font(.callout).foregroundStyle(Theme.fg).multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "pencil").font(.caption).foregroundStyle(Theme.dim)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func placeCard(_ place: String, _ a: Adventure) -> some View {
        let key = place.lowercased()
        let current = a.location.caseInsensitiveCompare(place) == .orderedSame
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(place).font(.headline).foregroundStyle(Theme.accent)
                if current { Text("you are here").font(.caption).foregroundStyle(Theme.dim) }
            }
            let desc = a.lore.first { $0.kind == .place && $0.name.lowercased() == key }?.desc ?? ""
            if !desc.isEmpty { Text(desc).font(.callout).foregroundStyle(Theme.fg) }
            let props = a.placeThings[key] ?? (current ? a.things : [])
            if !props.isEmpty { attr("Props", props.joined(separator: "; ")) }
            let there = a.whereabouts.filter { w in
                current ? w.here != false : (w.leftAt?.lowercased() == key)
            }.map { display($0.name, a) }
            if !there.isEmpty { attr("People", there.joined(separator: ", ")) }
        }
    }

    private func person(_ p: LoreEntry, _ a: Adventure) -> some View {
        let w = a.whereabouts.first { $0.name == p.name }
        let state = w.map { $0.here == false ? "elsewhere" : $0.engaged == true ? "with you" : $0.here == true ? "in the room" : "" } ?? ""
        let pronouns = a.facts.first { $0.hasPrefix(p.name + " uses ") }.map { String($0.dropFirst(p.name.count + 6)).trimmingCharacters(in: CharacterSet(charactersIn: ". ")) } ?? ""
        let first = p.name.split(separator: " ").first.map(String.init) ?? p.name
        let about = a.facts.filter { $0.contains(first) && !$0.hasPrefix(p.name + " uses ") }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(shown(p, a)).font(.headline).foregroundStyle(Theme.accent)
                Text([hidden(p, a) ? "name not said yet" : "name known", pronouns, state].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(Theme.dim)
                Spacer()
                Image(systemName: "pencil").font(.caption).foregroundStyle(Theme.dim)
            }
            if !p.desc.isEmpty { Text(Continuity.unnamed(p.desc, in: a)).font(.callout).foregroundStyle(Theme.fg).multilineTextAlignment(.leading) }
            if p.byPlayer { Text("✎ your edit").font(.caption).foregroundStyle(Theme.dim) }
            if let w, !w.at.isEmpty { attr("Where", w.at) }
            if let w, !w.doing.isEmpty { attr("Doing", Continuity.unnamed(w.doing, in: a)) }
            if let w, !w.heading.isEmpty { attr("Heading to", w.heading) }
            ForEach(Array(about.enumerated()), id: \.offset) { _, f in
                Text("• " + Continuity.unnamed(f, in: a)).font(.caption).foregroundStyle(Theme.fg)
            }
        }
    }

    private func attr(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(.caption.bold()).foregroundStyle(Theme.dim).frame(width: 92, alignment: .leading)
            Text(value).font(.callout).foregroundStyle(Theme.fg).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func loreCard(_ e: LoreEntry, _ a: Adventure) -> some View {
        let masked = hidden(e, a)
        var desc = Continuity.unnamed(e.desc, in: a)
        if masked, !a.nameless {
            for part in [e.name] + e.name.split(separator: " ").map(String.init) where part.count > 2 {
                desc = desc.replacingOccurrences(of: part, with: e.role)
            }
        }
        var tags: [String] = [e.isPlayer ? "main character (you)" : e.label.lowercased()]
        if masked { tags.append("name not revealed yet") }
        if e.byPlayer { tags.append("✎ your edit") } else if let t = e.updatedTurn { tags.append("↻ updated in play (turn \(t))") }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(shown(e, a)).font(.headline).foregroundStyle(Theme.accent)
                Text(tags.joined(separator: " · ")).font(.caption).foregroundStyle(Theme.dim)
                Spacer()
                Image(systemName: "pencil").font(.caption).foregroundStyle(Theme.dim)
            }
            if !desc.isEmpty { Text(desc).font(.callout).foregroundStyle(Theme.fg).multilineTextAlignment(.leading) }
            if !e.wants.isEmpty && !masked { Text("Wants: " + e.wants).font(.caption).foregroundStyle(Theme.dim) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
    }

    private func card<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        c()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
    }
}

/// Add or edit one entry of the world.
struct LoreEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var entry: LoreEntry
    var onSave: (LoreEntry) -> Void
    var onDelete: (LoreEntry) -> Void
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $entry.name)
                    if !entry.isPlayer {
                        Picker("Type", selection: $entry.kind) {
                            ForEach(LoreEntry.Kind.allCases, id: \.self) { k in
                                Text(k == .person ? "Character" : k.rawValue.capitalized).tag(k)
                            }
                        }
                    }
                    TextField("Description", text: $entry.desc, axis: .vertical).lineLimit(3...10)
                }
                if entry.kind == .person && !entry.isPlayer {
                    Section {
                        TextField("How you first know them, e.g. the old fisherman", text: $entry.role)
                        Toggle("You know their name", isOn: $entry.known)
                        TextField("What they want", text: $entry.wants, axis: .vertical)
                    } footer: {
                        Text("Until the story reveals a name, the World panel shows the person by their role.")
                    }
                }
                if !entry.isPlayer && !entry.name.isEmpty {
                    Section {
                        Button("Delete from the world", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .navigationTitle(entry.name.isEmpty ? "New entry" : entry.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(entry); dismiss() }
                        .disabled(entry.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .confirmationDialog("Delete \"\(entry.name)\" from the world?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { onDelete(entry); dismiss() }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// One row of the turn guide's world card. It lights up when its value changes, then settles.
private struct FlashRow: View {
    let label: String
    let value: String
    /// How many lines the value may take (nil: all of them).
    var lines: Int?
    @State private var lit = false
    @State private var beat = 0

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(.caption2.bold()).foregroundStyle(lit ? Theme.accent : Theme.dim).frame(width: 74, alignment: .leading)
            Text(value.isEmpty ? "–" : value)
                .font(.footnote)
                .foregroundStyle(value.isEmpty ? Theme.dim : Theme.fg)
                .lineLimit(lines)
                .contentTransition(.opacity)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Theme.accent.opacity(lit ? 0.22 : 0), in: RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(Theme.accent).frame(width: 3).opacity(lit ? 1 : 0)
        }
        .scaleEffect(lit ? 1.015 : 1, anchor: .leading)
        .animation(.easeOut(duration: 0.2), value: value)
        .onChange(of: value) { _, _ in
            beat += 1
            let mine = beat
            withAnimation(.easeOut(duration: 0.15)) { lit = true }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.6))
                // A newer change keeps the row lit for its own full beat.
                if mine == beat { withAnimation(.easeInOut(duration: 0.9)) { lit = false } }
            }
        }
    }
}

/// A card that is one line until tapped open. When something about it changes, it lights up and
/// shows a line saying what changed.
private struct FoldCard<Content: View>: View {
    let title: String
    let tag: String
    /// The latest change to this card this turn ("" for none).
    let marquee: String
    let open: Bool
    let toggle: () -> Void
    @ViewBuilder var content: () -> Content
    @State private var lit = false
    @State private var beat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: toggle) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption2.bold()).foregroundStyle(Theme.dim)
                    Text(title).font(.subheadline.bold()).foregroundStyle(Theme.accent).lineLimit(1).layoutPriority(1)
                    Text(tag).font(.caption).foregroundStyle(Theme.dim).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !marquee.isEmpty {
                Label(marquee, systemImage: "sparkle")
                    .font(.caption2).foregroundStyle(lit ? Theme.accent : Theme.dim).lineLimit(open ? nil : 1)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
            if open { content().padding(.top, 4).transition(.opacity.combined(with: .move(edge: .top))) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Theme.accent.opacity(lit ? 0.14 : 0))
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(lit ? Theme.accent : Theme.line, lineWidth: lit ? 1.5 : 1))
        .animation(.easeOut(duration: 0.25), value: marquee)
        .onChange(of: marquee) { _, new in
            guard !new.isEmpty else { return }
            beat += 1
            let mine = beat
            withAnimation(.easeOut(duration: 0.15)) { lit = true }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2.2))
                if mine == beat { withAnimation(.easeInOut(duration: 0.9)) { lit = false } }
            }
        }
    }
}
