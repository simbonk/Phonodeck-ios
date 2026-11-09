import SwiftUI
import UniformTypeIdentifiers

/// The Phonodeck tab: the start screen (set up a new experience, continue one), the build screen,
/// and the story itself.
struct PhonodeckHome: View {
    @Environment(AppModel.self) private var app
    @State private var curator = false
    @State private var curatorStart: Experience?
    @State private var importing = false
    @State private var showContinue = true
    /// The finished or saved story a "Same cast, new story" sheet is open for.
    @State private var sameCast: Adventure?

    var body: some View {
        NavigationStack {
            ZStack {
                if app.engine.adventure != nil {
                    StoryView()
                } else {
                    home
                }
                if let forge = app.engine.forge, !forge.finished {
                    ForgeView(forge: forge) { app.engine.stopAll(); app.engine.close() }
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
            .background(Theme.bg)
        }
        .fullScreenCover(isPresented: $curator) {
            CuratorView(start: curatorStart)
        }
        .sheet(item: $sameCast) { src in
            SameCastSheet(source: src) { link, hook, minutes in
                sameCast = nil
                app.engine.createSequel(from: src, link: link, hook: hook, minutes: minutes)
            }
        }
        .onChange(of: app.pendingExperience) { _, e in
            if let e { open(e); app.pendingExperience = nil }
        }
        .onAppear {
            if let e = app.pendingExperience { open(e); app.pendingExperience = nil }
        }
    }

    private func open(_ e: Experience?) {
        curatorStart = e
        curator = true
    }

    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center) {
                    Text("PHONODECK")
                        .font(.system(size: 30, weight: .bold))
                        .tracking(4)
                        .foregroundStyle(Theme.accent)
                        .shadow(color: Theme.accent.opacity(0.5), radius: 8)
                    Spacer()
                    importMenu
                }
                .padding(.top, 12)
                Text("Your story, your vibe. Everything is remembered, and it all happens on this device.")
                    .font(.subheadline).foregroundStyle(Theme.dim)

                if !app.store.hasLanguageModel {
                    StorytellerCard()
                        .padding(.top, 8)
                }

                BigCard(primary: true) {
                    open(nil)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Set up a new experience").font(.title3.bold())
                        Text("A few quick questions: your time, then a curated world or one you build yourself.")
                            .font(.subheadline).opacity(0.8)
                    }
                }
                .disabled(!app.store.hasLanguageModel)
                .opacity(app.store.hasLanguageModel ? 1 : 0.5)
                .padding(.top, 8)

                let inProgress = app.library.adventures.filter { !$0.ended }
                if !inProgress.isEmpty {
                    BigCard {
                        withAnimation { showContinue.toggle() }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Continue an experience").font(.title3.bold())
                                Text("\(inProgress.count) in progress").font(.subheadline).foregroundStyle(Theme.dim)
                            }
                            Spacer()
                            Image(systemName: showContinue ? "chevron.up" : "chevron.down").foregroundStyle(Theme.dim)
                        }
                    }
                    if showContinue {
                        ForEach(inProgress) { a in adventureRow(a) }
                    }
                }

                let finished = app.library.adventures.filter(\.ended)
                if !finished.isEmpty {
                    Caps(text: "Finished", color: Theme.dim).padding(.top, 14)
                    ForEach(finished) { a in adventureRow(a) }
                }
            }
            .padding(20)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.bg)
        .toolbar(.hidden, for: .navigationBar)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.phonodeckExperience, .json]) { result in
            if case .success(let url) = result { app.importFile(url) }
        }
    }

    /// Importing a shared experience is occasional, so it sits behind a small button by the title.
    private var importMenu: some View {
        Menu {
            Section("Experiences travel as small .phonodeck files. Share one from a story's ••• menu. Ones shared with you appear in the set-up.") {
                Button { importing = true } label: { Label("Import an experience file", systemImage: "square.and.arrow.down") }
            }
        } label: {
            Image(systemName: "square.and.arrow.down")
                .font(.title3)
                .foregroundStyle(Theme.accent)
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel("Import an experience")
    }

    private func adventureRow(_ a: Adventure) -> some View {
        HStack(spacing: 8) {
            Button {
                app.engine.open(a)
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(a.report?.title ?? a.title).font(.headline).foregroundStyle(Theme.fg)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 4)
                        Text(a.updated.formatted(.dateTime.month(.abbreviated).day()))
                            .font(.caption).foregroundStyle(Theme.dim)
                    }
                    if let line = subtitle(a) {
                        Text(line).font(.subheadline).foregroundStyle(Theme.dim).lineLimit(1)
                    }
                    let tags = badges(a)
                    if !tags.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(tags, id: \.self) { t in
                                Text(t).font(.caption2.bold()).lineLimit(1)
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Theme.accent.opacity(0.14), in: Capsule())
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
            }
            .buttonStyle(.plain)
            Menu {
                if app.store.hasLanguageModel {
                    Button { sameCast = a } label: { Label("Remix story", systemImage: "arrow.triangle.2.circlepath") }
                }
                if let url = app.library.exportFile(a.setup) {
                    ShareLink(item: url) { Label("Share this experience", systemImage: "square.and.arrow.up") }
                }
                Button(role: .destructive) { app.library.delete(a) } label: { Label("Delete", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis").frame(width: 36, height: 44)
            }
        }
    }

    /// Where the story is now, and for one in progress how far through it is.
    private func subtitle(_ a: Adventure) -> String? {
        var bits: [String] = []
        if !a.ended { bits.append("\(Int(a.elapsed / 60)) of \(a.minutes) min") }
        if !a.location.isEmpty { bits.append(a.location) }
        return bits.isEmpty ? nil : bits.joined(separator: " · ")
    }

    /// The vibe, and the grade a finished story earned.
    private func badges(_ a: Adventure) -> [String] {
        var tags: [String] = []
        if !a.setup.feeling.isEmpty { tags.append(a.setup.feeling) }
        if a.ended, let g = a.report?.player.grade { tags.append("Grade \(g)") }
        return tags
    }
}

/// The recommended storyteller, with its fit on this device and a download button. Used on the
/// start screen and in the welcome until a storyteller is installed.
struct StorytellerCard: View {
    @Environment(AppModel.self) private var app
    /// Set in the welcome, where the Models tab is hidden behind it: opens the full list in a sheet.
    var showOthers: (() -> Void)? = nil

    /// The best storyteller that runs comfortably here, best first; then one that is tight.
    private var entry: ModelEntry {
        let order = ModelCatalog.storytellerPreference.compactMap { ModelCatalog.entry($0) }
        if let e = order.first(where: { app.store.report(for: $0).verdict == .comfortable }) { return e }
        if let e = order.first(where: { app.store.report(for: $0).verdict == .tight }) { return e }
        return ModelCatalog.language[0]
    }

    var body: some View {
        let e = entry
        let r = app.store.report(for: e)
        let installed = app.store.installed.contains(e.id)
        VStack(alignment: .leading, spacing: 8) {
            Caps(text: "Step 1: download your storyteller")
            Text(e.name).font(.title3.bold()).foregroundStyle(Theme.fg)
            Text(e.blurb).font(.subheadline).foregroundStyle(Theme.dim)
            HStack(spacing: 6) {
                Image(systemName: r.verdict.symbol)
                Text(r.verdict.label).bold()
                Text(String(format: "· %.1f GB", app.store.facts[e.id]?.gb ?? e.approxGB)).foregroundStyle(Theme.dim)
            }
            .font(.caption)
            .foregroundStyle(r.verdict == .comfortable ? .green : r.verdict == .tight ? .orange : .red)
            if case .downloading(let id, let f) = app.store.download, id == e.id {
                ShimmerBar(fraction: f)
                HStack {
                    Text("Downloading… \(Int(f * 100))%. You can keep using the app.").font(.caption).foregroundStyle(Theme.dim)
                    Spacer()
                    Button("Cancel") { app.store.cancelDownload() }.font(.caption)
                }
            } else if installed {
                Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.accent)
            } else {
                if case .failed(_, let m) = app.store.download { Text(m).font(.caption).foregroundStyle(Theme.warn) }
                HStack {
                    Button {
                        app.store.startDownload(e)
                    } label: {
                        Text("Download").bold().padding(.horizontal, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .foregroundStyle(Theme.onAccent)
                    .disabled(app.store.isDownloading)
                    Spacer()
                    Button("Other models") { if let showOthers { showOthers() } else { app.tab = .models } }.font(.footnote)
                }
                Text("Downloads are big, so use Wi-Fi. After this, Phonodeck works in Airplane Mode.").font(.caption).foregroundStyle(Theme.dim)
            }
        }
        .padding(16)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.accent.opacity(0.6)))
        .task {
            for id in ModelCatalog.storytellerPreference where app.store.facts[id] == nil {
                if let e = ModelCatalog.entry(id) { await app.store.loadFacts(e) }
            }
        }
    }
}

/// "Same cast, new story": a short set-up for a new story with a saved story's cast and world.
/// The new story remembers the old one: recall searches its chapters and turns as you play.
struct SameCastSheet: View {
    let source: Adventure
    let build: (_ link: String, _ hook: String, _ minutes: Int) -> Void
    @State private var link = Prompts.sequelLinks[0]
    @State private var hook = ""
    @State private var minutes = 20
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("How it connects", selection: $link) {
                        ForEach(Prompts.sequelLinks, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("How does the new story connect?")
                } footer: {
                    Text("Same cast and world either way. In a sequel or years later, the new story remembers the old one and can look back through it when you ask about the past.")
                }
                Section("What happens this time? (optional)") {
                    TextField("Leave blank to be surprised", text: $hook, axis: .vertical)
                        .lineLimit(2...4)
                }
                Section("Length") {
                    Picker("Minutes", selection: $minutes) {
                        ForEach([10, 15, 20, 30, 45, 60], id: \.self) { Text("\($0) minutes").tag($0) }
                    }
                }
            }
            .navigationTitle(source.report?.title ?? source.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Build") { build(link, hook, minutes) } }
            }
        }
        .onAppear { minutes = [10, 15, 20, 30, 45, 60].min { abs($0 - source.minutes) < abs($1 - source.minutes) } ?? 20 }
    }
}
