import SwiftUI

/// The World button: the web app's Mission, Story and World tabs in one panel.
/// Mission: the feeling meter, the mission track (or your goal) and what has happened.
/// Story: the story bible, editable. World: every person, place and thing the story has collected.
struct WorldView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var tab = Tab.world
    @State private var bible = ""
    @State private var editing: LoreEntry?
    /// The bible as the panel shows it (names not said yet are shown as roles), to tell an edit apart.
    @State private var shownBible = ""
    @State private var myName = ""

    enum Tab: String, CaseIterable { case mission = "Mission", story = "Story", world = "World" }

    var body: some View {
        NavigationStack {
            Group {
                if let a = app.engine.adventure {
                    VStack(spacing: 0) {
                        Picker("Panel", selection: $tab) {
                            ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                switch tab {
                                case .mission: mission(a)
                                case .story: story(a)
                                case .world: world(a)
                                }
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

    // MARK: Mission

    @ViewBuilder
    private func mission(_ a: Adventure) -> some View {
        Caps(text: "The feeling")
        card {
            VStack(alignment: .leading, spacing: 6) {
                Text(a.setup.feeling.isEmpty ? "Whatever fits best" : a.setup.feeling).font(.headline).foregroundStyle(Theme.accent)
                if let f = a.mood.feeling {
                    HStack(spacing: 3) {
                        ForEach(0..<10, id: \.self) { k in
                            Circle().fill(k < f ? Theme.accent : Theme.line).frame(width: 9, height: 9)
                        }
                        Text("\(f)/10 last reading" + (a.mood.enjoying.isEmpty ? "" : " · enjoying \(a.mood.enjoying)"))
                            .font(.caption).foregroundStyle(Theme.dim).padding(.leading, 6)
                    }
                } else {
                    Text("Readings appear as you play.").font(.caption).foregroundStyle(Theme.dim)
                }
            }
        }
        Text("\(a.setup.simulator ? "Experience simulator" : "Curated story") · \(Int(a.elapsed / 60)) of \(a.minutes) minutes played" + (a.left.map { a.ended ? "" : " · about \($0) more turn\($0 == 1 ? "" : "s")" } ?? ""))
            .font(.footnote).foregroundStyle(Theme.dim)
        if !a.storyTime.isEmpty || !a.whereabouts.isEmpty {
            Caps(text: "Right now").padding(.top, 8)
            if !a.storyTime.isEmpty {
                // The story's clock as one badge, above who is where.
                Label(a.storyTime, systemImage: "clock")
                    .font(.subheadline.bold())
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Theme.accent.opacity(0.14), in: Capsule())
            }
            if !a.whereabouts.isEmpty {
            card {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(a.whereabouts) { w in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(display(w.name, a)).font(.subheadline.bold()).foregroundStyle(Theme.fg)
                            Text([w.at, w.doing].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(Theme.dim)
                            if !w.heading.isEmpty { Text("Heading to " + w.heading).font(.caption).foregroundStyle(Theme.accent) }
                        }
                    }
                }
            }
            }
        }
        if !a.timeline.isEmpty {
            Caps(text: "Timeline").padding(.top, 8)
            card {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(a.timeline.enumerated()), id: \.offset) { _, t in
                        Text(Continuity.unnamed(t, in: a)).font(.caption).foregroundStyle(Theme.fg)
                    }
                }
            }
        }
        if a.setup.simulator {
            Caps(text: "Your goal").padding(.top, 8)
            card {
                VStack(alignment: .leading, spacing: 4) {
                    Text(a.setup.goal.isEmpty ? "(open: follow your nose)" : a.setup.goal).foregroundStyle(Theme.fg)
                    if !a.goalProgress.isEmpty { Text("So far: " + a.goalProgress).font(.caption).foregroundStyle(Theme.dim) }
                }
            }
        } else {
            Caps(text: "Mission track").padding(.top, 8)
            if !a.location.isEmpty { Text("Current location: " + a.location).font(.footnote).foregroundStyle(Theme.dim) }
            if a.beats.isEmpty {
                Text("Mission steps will appear here.").font(.footnote).foregroundStyle(Theme.dim)
            } else {
                let active = a.beats.firstIndex { !$0.done }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(a.beats.enumerated()), id: \.offset) { k, b in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(spacing: 0) {
                                Circle()
                                    .fill(b.done ? Theme.accent : Theme.bg)
                                    .overlay(Circle().stroke(b.done || k == active ? Theme.accent : Theme.dim, lineWidth: 2))
                                    .shadow(color: k == active ? Theme.accent : .clear, radius: 6)
                                    .frame(width: 14, height: 14)
                                    .padding(.top, 3)
                                if k < a.beats.count - 1 { Rectangle().fill(Theme.line).frame(width: 2).frame(maxHeight: .infinity) }
                            }
                            .frame(width: 14)
                            Text(b.text)
                                .strikethrough(b.done)
                                .foregroundStyle(b.done ? Theme.dim : Theme.fg)
                                .padding(.bottom, 14)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
        let visited = a.lore.filter { $0.kind == .place }.map(\.name)
        if !visited.isEmpty {
            Caps(text: a.setup.simulator ? "Places" : "On the map").padding(.top, 8)
            Text(visited.joined(separator: " · ")).foregroundStyle(Theme.fg)
        }
        if !a.links.isEmpty {
            Caps(text: "Routes taken").padding(.top, 8)
            Text(a.links.suffix(8).map { "\($0.from) → \($0.to)" }.joined(separator: "\n")).font(.callout).foregroundStyle(Theme.fg)
        }
        if !a.chapters.isEmpty {
            Caps(text: "Chapters").padding(.top, 8)
            ForEach(Array(a.chapters.enumerated()), id: \.offset) { _, c in card { Text(c).font(.callout).foregroundStyle(Theme.fg) } }
        }
        if !a.events.isEmpty {
            Caps(text: a.setup.simulator ? "Moments captured" : "Recent events").padding(.top, 8)
            card {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(a.events.suffix(10).enumerated()), id: \.offset) { _, e in Text("• " + e).font(.callout).foregroundStyle(Theme.fg) }
                }
            }
        }
    }

    // MARK: Story bible

    @ViewBuilder
    private func story(_ a: Adventure) -> some View {
        Text("Edit by hand any time. Your changes win over anything the story said before, from your next message on.")
            .font(.footnote).foregroundStyle(Theme.dim)
        TextEditor(text: $bible)
            .font(.callout)
            .foregroundStyle(Theme.fg)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 360)
            .padding(8)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(bible == shownBible ? Theme.line : Theme.accent.opacity(0.6)))
        // Save appears only once something has been changed.
        if bible != shownBible {
            HStack {
                Button("Save story") { saveBible() }
                    .buttonStyle(.borderedProminent).tint(Theme.accent).foregroundStyle(Theme.onAccent)
                Button("Discard changes") { bible = shownBible }
                    .buttonStyle(.bordered)
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private func saveBible() {
        if app.engine.adventure != nil, bible != shownBible, !bible.isEmpty { app.engine.editBible(bible); shownBible = bible }
    }

    // MARK: World (lore)

    @ViewBuilder
    private func world(_ a: Adventure) -> some View {
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
                let away = a.whereabouts.filter { $0.here == false }.map { w in display(w.name, a) + (w.leftAt.map { " (at " + $0 + ")" } ?? "") }
                if !away.isEmpty { attr("Elsewhere", away.joined(separator: ", ")) }
            }
        }
        if !a.cast.isEmpty {
            Caps(text: "People").padding(.top, 8)
            ForEach(a.cast) { p in
                Button { editing = p } label: { card { person(p, a) } }.buttonStyle(.plain)
            }
        }
        // Every place the player has been keeps its own card: what is there and who was left there.
        let visited = a.places.filter { !$0.isEmpty }
        if !visited.isEmpty {
            Caps(text: "Places").padding(.top, 8)
            ForEach(visited, id: \.self) { place in
                card { placeCard(place, a) }
            }
        }
        let facts = a.facts.filter { !Continuity.elsewhereFact($0, in: a) }
        if !facts.isEmpty {
            Caps(text: "Facts").padding(.top, 8)
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
