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
                Text("PHONODECK")
                    .font(.system(size: 30, weight: .bold))
                    .tracking(4)
                    .foregroundStyle(Theme.accent)
                    .shadow(color: Theme.accent.opacity(0.5), radius: 8)
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
                        Text("A few quick questions: your time, a little about you, then a curated world or one you build yourself.")
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

                Caps(text: "Shared experiences", color: Theme.dim).padding(.top, 14)
                Text("Experiences travel as small .phonodeck files. Share one from a story's menu; anyone with Phonodeck can open it. Experiences shared with you appear in the set-up, next to the curated ones.")
                    .font(.footnote).foregroundStyle(Theme.dim)
                Button {
                    importing = true
                } label: {
                    Label("Import an experience file", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
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

    private func adventureRow(_ a: Adventure) -> some View {
        HStack(spacing: 8) {
            Button {
                app.engine.open(a)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(a.report?.title ?? a.title).font(.headline).foregroundStyle(Theme.fg)
                    Text(subtitle(a)).font(.caption).foregroundStyle(Theme.dim).lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
            }
            .buttonStyle(.plain)
            Menu {
                if let url = app.library.exportFile(a.setup) {
                    ShareLink(item: url) { Label("Share this experience", systemImage: "square.and.arrow.up") }
                }
                Button(role: .destructive) { app.library.delete(a) } label: { Label("Delete", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis").frame(width: 36, height: 44)
            }
        }
    }

    private func subtitle(_ a: Adventure) -> String {
        var bits = [a.setup.simulator ? "Experience" : "Story"]
        if a.ended {
            bits.append("Finished" + (a.report.map { " · you got \($0.player.grade)" } ?? ""))
        } else {
            bits.append("\(Int(a.elapsed / 60)) of \(a.minutes) min")
        }
        if !a.setup.feeling.isEmpty { bits.append(a.setup.feeling) }
        if !a.location.isEmpty { bits.append(a.location) }
        bits.append(a.updated.formatted(date: .abbreviated, time: .omitted))
        return bits.joined(separator: " · ")
    }
}

/// The recommended storyteller, with its fit on this device and a download button. Used on the
/// start screen and in the welcome until a storyteller is installed.
struct StorytellerCard: View {
    @Environment(AppModel.self) private var app

    private var entry: ModelEntry {
        let rec = ModelCatalog.entry(ModelCatalog.recommendedLanguageID) ?? ModelCatalog.language[0]
        let r = app.store.report(for: rec, loadedGB: 0)
        if r.verdict == .tooBig, let small = ModelCatalog.language.first { return small }
        return rec
    }

    var body: some View {
        let e = entry
        let r = app.store.report(for: e, loadedGB: 0)
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
                    Button("Other models") { app.tab = .models }.font(.footnote)
                }
                Text("Downloads are big, so use Wi-Fi. After this, Phonodeck works in Airplane Mode.").font(.caption).foregroundStyle(Theme.dim)
            }
        }
        .padding(16)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.accent.opacity(0.6)))
        .task { if app.store.facts[e.id] == nil { await app.store.loadFacts(e) } }
    }
}
