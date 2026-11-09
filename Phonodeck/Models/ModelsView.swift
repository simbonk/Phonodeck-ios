import AVFoundation
import SwiftUI

/// The three jobs a model does, one tab each in Models.
enum ModelsTab: String, CaseIterable, Identifiable {
    case thinking, speaking, listening
    var id: Self { self }

    var title: String {
        switch self {
        case .thinking: "Thinking"
        case .listening: "Listening"
        case .speaking: "Speaking"
        }
    }

    var kind: ModelEntry.Kind {
        switch self {
        case .thinking: .language
        case .listening: .listening
        case .speaking: .voice
        }
    }
}

extension ModelStore {
    /// Whether a model is worth offering on this device: already downloaded, or small enough to
    /// load at all (it may still be tight beside the other models, which the card says).
    func canRun(_ e: ModelEntry) -> Bool {
        installed.contains(e.id) || DeviceFit.report(for: e, facts: facts[e.id]).verdict != .tooBig
    }
}

struct ModelsView: View {
    @Environment(AppModel.self) private var app

    private var store: ModelStore { app.store }

    var body: some View {
        @Bindable var app = app
        NavigationStack {
            List {
                Section {
                    MemoryBar()
                    if MemoryPanel.shows(nil, app) { MemoryPanel() }
                } header: {
                    Text("In memory")
                } footer: {
                    Text("\(DeviceFit.deviceName), \(String(format: "%.0f", DeviceFit.ramGB.rounded())) GB. iOS lets an app use about \(String(format: "%.1f", DeviceFit.modelBudgetGB)) GB for models. If replies get strange or slow, Restart loads the thinking model fresh; models load again by themselves when needed.")
                }

                Section {
                    Picker("Models", selection: $app.modelsTab) {
                        ForEach(ModelsTab.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                } footer: {
                    Text(intro(app.modelsTab))
                }

                downloadStatus

                switch app.modelsTab {
                case .thinking:
                    Section { ThinkingModels() }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                case .listening:
                    Section { ListeningSetup(manage: true, showsIntro: false) }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                case .speaking:
                    Section { NarratorSetup(manage: true, showsIntro: false) }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                    if store.voiceID == nil { AppleVoiceSection() }
                }

                Section {
                    NavigationLink {
                        AddModelPage(kind: app.modelsTab.kind, title: app.modelsTab.title)
                    } label: {
                        Label("Add a custom model…", systemImage: "plus.magnifyingglass")
                    }
                } footer: {
                    Text("Search Hugging Face or paste a link. Models that can't fit on this \(DeviceFit.deviceWord) are left out. Downloads are big, so use Wi-Fi.")
                }
            }
            .buttonStyle(.borderless)   // keeps each button in a row separate
            .navigationTitle("Models")
            .task {
                for e in ModelCatalog.all where store.facts[e.id] == nil { await store.loadFacts(e) }
            }
        }
    }

    private func intro(_ t: ModelsTab) -> String {
        switch t {
        case .thinking: "The language model that writes your stories and chat replies. Bigger ones write better but answer more slowly."
        case .listening: "How Phonodeck hears you in hands-free mode. Say \"\(Dictation.sendPhrase)\" to send."
        case .speaking: "The narrator voice that reads stories and chat replies aloud. Everything here works offline."
        }
    }

    /// Whatever is downloading, wherever it was started, with a way to stop it.
    @ViewBuilder private var downloadStatus: some View {
        if case .downloading(let id, let fraction) = store.download {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: fraction) {
                        Text("Downloading \(ModelCatalog.entry(id)?.name ?? id)").font(.subheadline.bold())
                    } currentValueLabel: {
                        Text(fraction > 0 ? "\(Int(fraction * 100))% · keep Phonodeck open until it finishes" : "Starting…")
                    }
                    Button("Cancel download", role: .cancel) { store.cancelDownload() }.font(.caption)
                }
            }
        } else if case .failed(_, let message) = store.download {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.footnote)
                    Button("Dismiss") { store.dismissDownloadError() }.font(.caption)
                }
            }
        }
    }
}

/// The thinking models as cards: the one in use and any downloaded, then the best suggestions
/// for this device up to three, with the rest behind "More". Models too big to load are left out.
private struct ThinkingModels: View {
    @Environment(AppModel.self) private var app
    @State private var showMore = false

    private var store: ModelStore { app.store }

    var body: some View {
        let all = ModelCatalog.language + store.customModels.filter { $0.kind == .language }
        let runnable = all.filter(store.canRun)
        let hidden = all.count - runnable.count
        let ordered = runnable.sorted { rank($0) < rank($1) }
        let mine = ordered.filter { store.installed.contains($0.id) || $0.id == store.languageID }
        let suggestions = ordered.filter { !mine.contains($0) }
        let firstSuggestions = Array(suggestions.prefix(max(0, 3 - mine.count)))
        let more = Array(suggestions.dropFirst(firstSuggestions.count))

        VStack(alignment: .leading, spacing: 10) {
            ForEach(mine + firstSuggestions) { card($0) }
            if !more.isEmpty {
                Button {
                    withAnimation { showMore.toggle() }
                } label: {
                    Label(showMore ? "Fewer suggestions" : "\(more.count) more suggestion\(more.count == 1 ? "" : "s")",
                          systemImage: showMore ? "chevron.up" : "chevron.down")
                        .font(.subheadline.bold())
                }
                .padding(.horizontal, 4)
                if showMore { ForEach(more) { card($0) } }
            }
            if hidden > 0 {
                Text("\(hidden) larger model\(hidden == 1 ? " is" : "s are") hidden because \(hidden == 1 ? "it needs" : "they need") more memory than this \(DeviceFit.deviceWord) gives an app.")
                    .font(.caption).foregroundStyle(Theme.dim)
                    .padding(.horizontal, 4)
            }
        }
    }

    /// In use first, then downloaded, then the welcome's order of preference, then the rest.
    private func rank(_ e: ModelEntry) -> Int {
        if e.id == store.languageID { return 0 }
        if store.installed.contains(e.id) { return 1 }
        if let i = ModelCatalog.storytellerPreference.firstIndex(of: e.id) { return 10 + i }
        if e.custom { return 100 }
        return 50 + (ModelCatalog.language.firstIndex(of: e) ?? 0)
    }

    private func card(_ e: ModelEntry) -> some View {
        OptionCard(title: e.name, tier: tier(e), blurb: e.blurb, entry: e,
                   selected: store.languageID == e.id,
                   use: { store.languageID = e.id; app.llm.unload() }) {
            DeleteModelButton(entry: e) { if store.languageID == e.id || app.llm.loadedID == e.id { app.llm.unload() } }
        }
    }

    private func tier(_ e: ModelEntry) -> String {
        if e.id == ModelCatalog.recommendedLanguageID { return "Recommended" }
        if e.custom { return e.isGGUF ? "Added · GGUF" : "Added" }
        return ""
    }
}

/// Search Hugging Face, paste a link, or set a token, for one kind of model.
private struct AddModelPage: View {
    let kind: ModelEntry.Kind
    let title: String

    var body: some View {
        List {
            ModelSearchSection(kind: kind)
            AddByLinkSection(kind: kind)
        }
        .buttonStyle(.borderless)
        .navigationTitle("Add a \(title.lowercased()) model")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// How much of the memory iOS gives the app the loaded models take, with Unload all.
private struct MemoryBar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let used = usedGB
        let budget = DeviceFit.modelBudgetGB
        let f = min(1, used / max(budget, 0.1))
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(String(format: "%.1f of %.1f GB used", used, budget)).font(.subheadline.bold().monospacedDigit())
                Spacer()
                Button("Unload all") {
                    app.llm.unload()
                    app.narrator.unloadNeural()
                    app.dictation.unloadModel()
                }
                .font(.caption)
                .buttonStyle(.bordered)
                .disabled(used < 0.05 || app.llm.busy || app.engine.busy || app.dictation.listening)
            }
            ProgressView(value: f)
                .tint(f < 0.75 ? Theme.accent : f < 0.9 ? .orange : .red)
        }
    }

    private var usedGB: Double {
        app.llm.loadedGB + app.narrator.neuralLoadedGB + app.dictation.loadedGB
    }
}

/// Apple's built-in voice: which one, and how fast it speaks. Shown only while it is the narrator.
private struct AppleVoiceSection: View {
    @AppStorage("appleVoice") private var appleVoice = ""
    @AppStorage("speechRate") private var speechRate = 0.5

    var body: some View {
        Section {
            NavigationLink {
                AppleVoicePicker(selection: $appleVoice)
            } label: {
                LabeledContent("Voice", value: appleVoiceName)
            }
            VStack(alignment: .leading) {
                Text("Speed")
                Slider(value: $speechRate, in: 0.35...0.6)
            }
        } header: {
            Text("Apple voice settings")
        } footer: {
            Text("For a better Apple voice, download a Premium or Enhanced one in the iPhone's Settings > Accessibility > Spoken Content > Voices.")
        }
    }

    private var appleVoiceName: String {
        AVSpeechSynthesisVoice(identifier: appleVoice).map { "\($0.name) (\(Narrator.qualityLabel($0)))" } ?? "Automatic"
    }
}

/// Paste a Hugging Face link, plus the optional token for gated models. Tucked away, since search covers most needs.
private struct AddByLinkSection: View {
    @Environment(AppModel.self) private var app
    let kind: ModelEntry.Kind
    @State private var link = ""
    @State private var adding = false
    @State private var addError: String?
    @State private var open = false

    var body: some View {
        Section {
            DisclosureGroup("Add from a link", isExpanded: $open) {
                TextField("huggingface.co/mlx-community/…", text: $link)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Button {
                    adding = true
                    addError = nil
                    Task {
                        let r = await app.store.addCustom(link: link, kind: kind)
                        adding = false
                        switch r {
                        case .added: link = ""
                        case .failed(let m): addError = m
                        }
                    }
                } label: {
                    HStack { Text("Check and add"); if adding { Spacer(); ProgressView() } }
                }
                .disabled(link.isEmpty || adding)
                if let addError { Text(addError).foregroundStyle(.red).font(.footnote) }
                Link("Browse on Hugging Face", destination: kind == .language ? HFHub.browseLanguageURL : HFHub.browseVoiceURL)
            }
            NavigationLink {
                Form { HFTokenSection() }.navigationTitle("Hugging Face token")
            } label: {
                LabeledContent("Hugging Face token", value: HFToken.value == nil ? "None" : "Saved")
            }
        } footer: {
            Text("Paste a link to an MLX model (4-bit versions are the right size for a phone). Phonodeck checks it fits before you download. A token is only needed for gated models.")
        }
    }
}
