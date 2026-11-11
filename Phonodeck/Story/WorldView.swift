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

    var body: some View {
        NavigationStack {
            Group {
                if let a = app.engine.adventure {
                    VStack(spacing: 0) {
                        // The world, as it is this turn (the Mission and Story tabs are gone).
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
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
                    }
                }
            }
            .background(Theme.bg)
            .navigationTitle(app.engine.adventure?.title ?? "World")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { saveBible(); app.engine.setPlayerName(myName); dismiss() }
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
        if !a.frames.isEmpty { turnGuide(a) }
        attributes(a)
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

    /// One turn at a time, as a feed you can watch: the world after that turn, then each question
    /// in the order it was asked. While the questions run, the one just answered shows its answer
    /// and what it changed, then folds down to one line as the next one comes in. When the turn is
    /// done everything is folded; "Expand all" opens it up. A new turn slides in.
    @ViewBuilder
    private func turnGuide(_ a: Adventure) -> some View {
        let last = a.frames.count - 1
        let k = min(max(0, frameAt ?? last), last)
        let f = a.frames[k]
        let asking = k == last && !app.engine.rebuildStep.isEmpty
        let thinking = k == last && !app.engine.stage.isEmpty
        HStack(spacing: 10) {
            Button { withAnimation(.snappy) { frameAt = max(0, k - 1) } } label: { Image(systemName: "chevron.left") }
                .disabled(k == 0)
            VStack(spacing: 1) {
                Text(f.turn == 0 ? "Opening" : "Turn \(f.turn)").font(.headline).foregroundStyle(Theme.accent)
                    .contentTransition(.numericText())
                Text(k == last ? (asking ? "updating now" : "latest") : "\(last - k) turn\(last - k == 1 ? "" : "s") ago")
                    .font(.caption).foregroundStyle(Theme.dim)
            }
            .frame(maxWidth: .infinity)
            Button { withAnimation(.snappy) { frameAt = k + 1 >= last ? nil : k + 1 } } label: { Image(systemName: "chevron.right") }
                .disabled(k == last)
        }
        .buttonStyle(.bordered)
        if thinking {
            // The next turn is being worked out (before the reply): what the storyteller is doing.
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Turn \(f.turn + 1): " + app.engine.stage).font(.caption.bold()).foregroundStyle(Theme.accent)
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
        VStack(alignment: .leading, spacing: 10) {
            card {
                VStack(alignment: .leading, spacing: 6) {
                    attr("Place", f.place.isEmpty ? "On the way somewhere new" : f.place)
                    if let s = f.spot, !s.isEmpty { attr("You are", s) }
                    if !f.time.isEmpty { attr("Time", f.time) }
                    attr("Facing", f.with.isEmpty ? "Nobody in particular" : f.with.map { Continuity.unnamed($0, in: a) }.joined(separator: "\n"))
                    if let s = f.feelings, !s.isEmpty { attr("How they feel", s.map { Continuity.unnamed($0, in: a) }.joined(separator: "\n")) }
                    if !f.room.isEmpty { attr("In the room", f.room.map { Continuity.unnamed($0, in: a) }.joined(separator: "\n")) }
                    if !f.have.isEmpty { attr("You have", f.have.joined(separator: "; ")) }
                    if !f.around.isEmpty { attr("Around", f.around.joined(separator: "; ")) }
                    if let s = f.sound, !s.isEmpty { attr("Background", s) }
                    if let s = f.pending, !s.isEmpty { attr("Still hanging", s.map { Continuity.unnamed($0, in: a) }.joined(separator: "\n")) }
                }
                .animation(.smooth, value: f.asked.count)
            }
            HStack {
                Caps(text: "How the turn was worked out")
                Spacer()
                Button(expandAll ? "Fold all" : "Expand all") { withAnimation(.snappy) { expandAll.toggle() } }
                    .font(.caption.bold())
            }
            .padding(.top, 2)
            if !f.looked.isEmpty {
                step(icon: "eye", question: "Looked up before the reply", answer: f.looked.map { Continuity.unnamed($0, in: a) }.joined(separator: "\n"),
                     changes: [], open: expandAll, a)
            }
            ForEach(Array(f.asked.enumerated()), id: \.offset) { i, line in
                let parts = line.components(separatedBy: " → ")
                let q: String = parts.first ?? line
                let ans: String = parts.dropFirst().joined(separator: " → ")
                let changes: [String] = (f.steps ?? []).indices.contains(i) ? f.steps![i] : []
                // The one just answered stays open while the next question runs.
                let open = expandAll || (asking && i == f.asked.count - 1)
                step(icon: "checkmark.circle.fill", question: q, answer: ans, changes: changes, open: open, a)
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
            }
            if asking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(Continuity.unnamed(app.engine.rebuildStep, in: a)).font(.callout.bold()).foregroundStyle(Theme.accent)
                    Spacer()
                }
                .padding(10)
                .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .id("asking-" + app.engine.rebuildStep)
            }
            if !asking, !f.changed.isEmpty {
                step(icon: "arrow.triangle.2.circlepath", question: "What changed this turn", answer: "",
                     changes: f.changed.map { Continuity.unnamed($0, in: a) }, open: true, a)
            }
        }
        .id(f.id)
        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .move(edge: .leading).combined(with: .opacity)))
        .animation(.spring(duration: 0.45), value: f.asked.count)
        .animation(.spring(duration: 0.45), value: app.engine.rebuildStep)
        .padding(.bottom, 8)
    }

    /// One question in the feed: folded to a line, or open with its answer and what it changed.
    private func step(icon: String, question: String, answer: String, changes: [String], open: Bool, _ a: Adventure) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: icon).font(.caption).foregroundStyle(Theme.accent)
                Text(Continuity.unnamed(question, in: a)).font(open ? .callout.bold() : .caption.bold()).foregroundStyle(Theme.fg)
                if !open, !answer.isEmpty {
                    Text(Continuity.unnamed(answer, in: a)).font(.caption).foregroundStyle(Theme.dim).lineLimit(1)
                }
                Spacer(minLength: 0)
                if !open, !changes.isEmpty {
                    Text("\(changes.count) change\(changes.count == 1 ? "" : "s")").font(.caption2.bold()).foregroundStyle(Theme.accent)
                }
            }
            if open {
                if !answer.isEmpty {
                    Text(Continuity.unnamed(answer, in: a)).font(.callout).foregroundStyle(Theme.fg)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                ForEach(Array(changes.enumerated()), id: \.offset) { _, c in
                    Label(Continuity.unnamed(c, in: a), systemImage: "sparkle").font(.caption).foregroundStyle(Theme.accent)
                        .transition(.scale(scale: 0.9, anchor: .leading).combined(with: .opacity))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, open ? 10 : 6)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(open ? Theme.accent.opacity(0.5) : Theme.line))
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.snappy) { expandAll.toggle() } }
    }

    // MARK: Attributes

    /// Everything the game holds about the world right now, as the world check after each reply
    /// leaves it. It updates while you play.
    @ViewBuilder
    private func attributes(_ a: Adventure) -> some View {
        Caps(text: "You")
        card {
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
        // The scene: where you are and what is around you. Moving to a new room or going outside
        // redraws it; the last place's things stay behind with it.
        Caps(text: "The scene").padding(.top, 8)
        card {
            VStack(alignment: .leading, spacing: 6) {
                attr("Place", a.location.isEmpty ? "On the way somewhere new" : a.location)
                if !a.storyTime.isEmpty { attr("Time", a.storyTime) }
                if !a.scene.isEmpty { attr("What's happening", Continuity.unnamed(a.scene, in: a)) }
                let around = a.location.isEmpty ? [] : (a.placeThings[a.location.lowercased()] ?? a.things)
                if !around.isEmpty { attr("Props here", around.joined(separator: "; ")) }
                let here = a.whereabouts.filter { $0.here != false }.map { display($0.name, a) + ($0.engaged == true ? " (with you)" : "") }
                attr("People here", here.isEmpty ? "Nobody but you" : here.joined(separator: ", "))
            }
        }
        // Only what is in view this turn: people and places out of view drop away here, and stay in
        // the earlier turns of the turn guide (and in the store, where a lookup still finds them).
        let inView = a.cast.filter { p in a.whereabouts.contains { $0.name == p.name && $0.here != false } }
        if !inView.isEmpty {
            Caps(text: "People here").padding(.top, 8)
            ForEach(inView) { p in
                Button { editing = p } label: { card { person(p, a) } }.buttonStyle(.plain)
            }
        }
        // Every place the player has been keeps its own card: what is there and who was left there.
        if !a.location.isEmpty {
            Caps(text: "This place").padding(.top, 8)
            card { placeCard(a.location, a) }
        }
        let away = a.cast.filter { p in !inView.contains { $0.id == p.id } }
        let facts = a.facts.filter { f in !Continuity.elsewhereFact(f, in: a) && !away.contains { Cards.mentions($0, in: f) } }
        if !facts.isEmpty {
            Caps(text: "Facts in view").padding(.top, 8)
            card {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(facts.enumerated()), id: \.offset) { _, f in
                        Text("• " + Continuity.unnamed(f, in: a)).font(.callout).foregroundStyle(Theme.fg)
                    }
                }
            }
        }
        if !a.checks.isEmpty {
            Caps(text: "Last world check").padding(.top, 8)
            card {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(a.checks.enumerated()), id: \.offset) { _, c in
                        Text(Continuity.unnamed(c, in: a)).font(.caption).foregroundStyle(c.hasPrefix("Kept off") ? Theme.dim : Theme.fg)
                    }
                }
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
