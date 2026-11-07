import SwiftUI
import UniformTypeIdentifiers

/// The Phonodeck tab: pick or build an experience, or continue one.
struct PhonodeckHome: View {
    @Environment(AppModel.self) private var app
    @State private var setup: Experience?
    @State private var importing = false

    var body: some View {
        NavigationStack {
            Group {
                if app.engine.adventure != nil {
                    StoryView()
                } else if app.engine.building {
                    BuildingView()
                } else if !app.store.hasLanguageModel {
                    NeedsModelBanner()
                } else {
                    home
                }
            }
        }
        .sheet(item: $setup) { e in
            SetupView(experience: e)
        }
        .onChange(of: app.pendingExperience) { _, e in
            if let e { setup = e; app.pendingExperience = nil }
        }
        .onAppear {
            if let e = app.pendingExperience { setup = e; app.pendingExperience = nil }
        }
    }

    private var home: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Step into a story").font(.title2.bold())
                    Text("Say how long you have and the feeling you want. A Game Master builds a world for you, tells it aloud, and lands a real ending in time.")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
                Button {
                    setup = Experience()
                } label: {
                    Label("Build the world myself", systemImage: "sparkles")
                }
            }

            let open = app.library.adventures.filter { !$0.ended }
            if !open.isEmpty {
                Section("Continue") {
                    ForEach(open) { a in adventureRow(a) }
                        .onDelete { idx in idx.map { open[$0] }.forEach(app.library.delete) }
                }
            }

            Section("Curated experiences") {
                ForEach(CuratedExperiences.all) { e in experienceRow(e) }
            }

            Section {
                ForEach(app.library.imported) { e in experienceRow(e) }
                    .onDelete { idx in idx.map { app.library.imported[$0] }.forEach(app.library.deleteImported) }
                Button {
                    importing = true
                } label: {
                    Label("Import an experience file", systemImage: "square.and.arrow.down")
                }
            } header: {
                Text("Shared with you")
            } footer: {
                Text("Experiences are small .phonodeck files. Share one from its set-up screen; anyone with Phonodeck can open it.")
            }

            let finished = app.library.adventures.filter(\.ended)
            if !finished.isEmpty {
                Section("Finished") {
                    ForEach(finished) { a in adventureRow(a) }
                        .onDelete { idx in idx.map { finished[$0] }.forEach(app.library.delete) }
                }
            }
        }
        .navigationTitle("Phonodeck")
        .fileImporter(isPresented: $importing, allowedContentTypes: [.phonodeckExperience, .json]) { result in
            if case .success(let url) = result { app.importFile(url) }
        }
    }

    private func experienceRow(_ e: Experience) -> some View {
        Button {
            setup = e
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(e.title).font(.headline)
                Text(e.feeling).font(.subheadline).foregroundStyle(Theme.accent)
                Text(e.describe).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Text("\(e.minutes) min · \(e.simulator ? "Experience" : "Story")\(e.author.isEmpty ? "" : " · by \(e.author)")")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.primary)
    }

    private func adventureRow(_ a: Adventure) -> some View {
        Button {
            app.engine.open(a)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(a.report?.title ?? a.title).font(.headline)
                Text(a.ended ? "Finished · \(a.report?.player.grade ?? "")" : "\(Int(app.engine.secsLeft(a, live: false) / 60)) min left · \(a.playerTurns) replies")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.primary)
    }
}

/// Fill in or edit an experience, then build the world.
struct SetupView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State var experience: Experience
    @State private var more = false
    @State private var shareURL: URL?

    private let lengths = [10, 15, 20, 30, 45, 60, 90]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $experience.title)
                    TextField("Describe what you'd like to experience", text: $experience.describe, axis: .vertical)
                        .lineLimit(3...8)
                }
                Section {
                    TextField("The feeling you want to come away with", text: $experience.feeling, axis: .vertical)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(Prompts.feelingIdeas, id: \.self) { f in
                                Button(f) { experience.feeling = f }
                                    .font(.caption)
                                    .buttonStyle(.bordered)
                            }
                        }
                    }
                } header: {
                    Text("The feeling comes first")
                }
                Section {
                    Picker("Length", selection: $experience.minutes) {
                        ForEach(lengths, id: \.self) { Text($0 >= 60 ? "\($0 / 60) h\($0 % 60 == 0 ? "" : " \($0 % 60) min")" : "\($0) min").tag($0) }
                        if !lengths.contains(experience.minutes) { Text("\(experience.minutes) min").tag(experience.minutes) }
                    }
                    Picker("How to play", selection: $experience.simulator) {
                        Text("A story with a plot").tag(false)
                        Text("An experience, no plot").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
                Section(isExpanded: $more) {
                    TextField("World and era", text: $experience.world, axis: .vertical)
                    TextField("Where it begins", text: $experience.place, axis: .vertical)
                    TextField("Who you are", text: $experience.who, axis: .vertical)
                    TextField("Your strengths and flaws", text: $experience.traits, axis: .vertical)
                    if experience.simulator {
                        TextField("Your goal", text: $experience.goal, axis: .vertical)
                    } else {
                        TextField("The hook", text: $experience.hook, axis: .vertical)
                        TextField("What stands in the way", text: $experience.threat, axis: .vertical)
                    }
                    TextField("Companions", text: $experience.allies, axis: .vertical)
                    TextField("Mood (e.g. cozy, funny)", text: $experience.vibe)
                    TextField("Style of play", text: $experience.play)
                    TextField("Keep it… (content limits)", text: $experience.avoid, axis: .vertical)
                    TextField("Secret guide for the Game Master", text: $experience.beats, axis: .vertical)
                    TextField("Your name as author (for sharing)", text: $experience.author)
                } header: {
                    Text("Details (optional)")
                }
            }
            .navigationTitle(experience.title.isEmpty ? "New experience" : experience.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    if let url = shareURL {
                        ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    var e = experience
                    if e.title.isEmpty { e.title = "My experience" }
                    app.engine.create(e, player: PlayerDetails.saved)
                    dismiss()
                } label: {
                    Text("Build my world").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .padding()
                .disabled(experience.describe.isEmpty && experience.world.isEmpty && experience.feeling.isEmpty)
            }
            .onAppear {
                more = !experience.world.isEmpty
                shareURL = app.library.exportFile(experience)
            }
            .onChange(of: experience) { _, e in shareURL = app.library.exportFile(e) }
        }
    }
}
