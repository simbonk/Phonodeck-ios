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
                    .onAppear { bible = a.bible }
                }
            }
            .background(Theme.bg)
            .navigationTitle(app.engine.adventure?.title ?? "World")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { saveBible(); dismiss() }
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
            card {
                VStack(alignment: .leading, spacing: 6) {
                    if !a.storyTime.isEmpty {
                        Label(a.storyTime, systemImage: "clock").font(.subheadline).foregroundStyle(Theme.accent)
                    }
                    ForEach(a.whereabouts) { w in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(w.name).font(.subheadline.bold()).foregroundStyle(Theme.fg)
                            Text([w.at, w.doing].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(Theme.dim)
                            if !w.heading.isEmpty { Text("Heading to " + w.heading).font(.caption).foregroundStyle(Theme.accent) }
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
                        Text(t).font(.caption).foregroundStyle(Theme.fg)
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
            .scrollContentBackground(.hidden)
            .frame(minHeight: 360)
            .padding(8)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
        HStack {
            Button("Save story") { saveBible() }
                .buttonStyle(.borderedProminent).tint(Theme.accent).foregroundStyle(Theme.onAccent)
                .disabled(bible == a.bible)
            if bible == a.bible { Text("Up to date.").font(.caption).foregroundStyle(Theme.dim) }
        }
    }

    private func saveBible() {
        if let a = app.engine.adventure, bible != a.bible, !bible.isEmpty { app.engine.editBible(bible) }
    }

    // MARK: World (lore)

    @ViewBuilder
    private func world(_ a: Adventure) -> some View {
        HStack {
            Text("\(a.lore.count) entries, collected as you play. Edit any of them; your words always win.")
                .font(.footnote).foregroundStyle(Theme.dim)
            Spacer()
            Button {
                editing = LoreEntry(name: "", kind: .person)
            } label: {
                Label("Add", systemImage: "plus")
            }
            .buttonStyle(.bordered)
        }
        let order: [LoreEntry.Kind] = [.person, .place, .item, .faction, .other]
        ForEach(order, id: \.self) { kind in
            let list = a.lore.filter { $0.kind == kind }.sorted { ($0.isPlayer ? 0 : 1, shown($0, a)) < ($1.isPlayer ? 0 : 1, shown($1, a)) }
            if !list.isEmpty {
                Caps(text: title(kind)).padding(.top, 8)
                ForEach(list) { e in
                    Button { editing = e } label: { loreCard(e, a) }.buttonStyle(.plain)
                }
            }
        }
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
        e.kind == .person && !e.isPlayer && !e.known && !e.role.isEmpty && !e.byPlayer
    }

    private func shown(_ e: LoreEntry, _ a: Adventure) -> String {
        hidden(e, a) ? e.role.prefix(1).uppercased() + e.role.dropFirst() : e.name
    }

    private func loreCard(_ e: LoreEntry, _ a: Adventure) -> some View {
        let masked = hidden(e, a)
        var desc = e.desc
        if masked {
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
