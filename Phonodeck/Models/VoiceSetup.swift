import SwiftUI

/// Choose, download and audition the narrator voice. Apple's voice is the default;
/// Kokoro (medium) and Qwen3-TTS (good, slower) can be downloaded and heard right here.
struct NarratorSetup: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Caps(text: "Narrator voice")
            Text("Who reads the story aloud. Tap Listen to hear each one; downloaded voices work offline.")
                .font(.subheadline).foregroundStyle(Theme.dim)
            OptionCard(title: "Apple voice", tier: "Fast", blurb: "Built in. Starts instantly, no download.",
                       entry: nil, selected: app.store.voiceID == nil,
                       listen: { toggleListen(nil) }, listening: app.narrator.auditioningID == "apple",
                       use: { app.narrator.unloadNeural(); app.store.voiceID = nil })
            ForEach(ModelCatalog.voice) { e in
                OptionCard(title: e.name, tier: e.tier == .best ? "Good, slower" : "Medium", blurb: e.blurb,
                           entry: e, selected: app.store.voiceID == e.id,
                           listen: { toggleListen(e) }, listening: app.narrator.auditioningID == e.id,
                           use: { app.narrator.unloadNeural(); app.store.voiceID = e.id })
                if app.store.installed.contains(e.id), e.voices.count > 1, app.store.voiceID == e.id {
                    VoiceChips(entry: e)
                }
            }
            if app.narrator.preparing || (app.narrator.auditioningID != nil && app.narrator.auditioningID != "apple" && !app.narrator.playing) {
                HStack(spacing: 8) {
                    HoloCore(size: 18)
                    Text(app.narrator.preparing ? "Loading the voice. The first time takes a little while." : "Getting ready to speak…")
                        .font(.caption).foregroundStyle(Theme.dim)
                }
            }
            if let err = app.narrator.lastError { Text(err).font(.caption).foregroundStyle(Theme.warn) }
        }
        .onDisappear { if app.narrator.auditioningID != nil { app.narrator.stop() } }
    }

    private func toggleListen(_ e: ModelEntry?) {
        let id = e?.id ?? "apple"
        if app.narrator.auditioningID == id { app.narrator.stop() } else { app.narrator.lastError = nil; app.narrator.audition(e) }
    }
}

/// The voices inside one narrator model, as chips: tap one to choose it and hear it.
struct VoiceChips: View {
    @Environment(AppModel.self) private var app
    let entry: ModelEntry
    @State private var chosen = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(entry.name) voices: tap one to hear it").font(.caption).foregroundStyle(Theme.dim)
            FlowLayout(spacing: 8) {
                ForEach(entry.voices, id: \.self) { v in
                    Chip(text: voiceLabel(v), selected: v == chosen) {
                        chosen = v
                        Narrator.setNeuralVoice(v, for: entry)
                        app.narrator.lastError = nil
                        app.narrator.audition(entry)
                    }
                }
            }
        }
        .padding(.leading, 12)
        .onAppear { chosen = Narrator.neuralVoice(for: entry) }
    }
}

/// Choose and download how Phonodeck hears you, with a live test.
struct ListeningSetup: View {
    @Environment(AppModel.self) private var app
    @State private var testing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Caps(text: "Listening")
            Text("How Phonodeck hears you in hands-free mode. Apple's dictation is quick; the Parakeet models listen fully offline.")
                .font(.subheadline).foregroundStyle(Theme.dim)
            OptionCard(title: "Apple dictation", tier: "Quick", blurb: "Built in. Shows words as you speak.",
                       entry: nil, selected: app.store.listeningID == nil,
                       use: { stopTest(); app.dictation.unloadModel(); app.store.listeningID = nil })
            ForEach(ModelCatalog.listening) { e in
                OptionCard(title: e.name, tier: e.tier == .best ? "Better" : "Light", blurb: e.blurb,
                           entry: e, selected: app.store.listeningID == e.id,
                           use: { stopTest(); app.dictation.unloadModel(); app.store.listeningID = e.id })
            }
            test
        }
        .onDisappear { stopTest() }
    }

    private var test: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    if testing { stopTest() } else { startTest() }
                } label: {
                    Label(testing ? "Stop" : "Try listening", systemImage: testing ? "stop.fill" : "mic.fill")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(testing ? Theme.rec : Theme.accent)
                .foregroundStyle(testing ? Color.white : Theme.onAccent)
                .modifier(Pulse(active: testing && app.dictation.listening))
                if app.dictation.transcribing { HoloCore(size: 18) }
                Spacer()
            }
            if testing || !app.dictation.text.isEmpty {
                Text(app.dictation.text.isEmpty ? "Say something…" : app.dictation.text)
                    .font(.callout)
                    .foregroundStyle(app.dictation.text.isEmpty ? Theme.dim : Theme.fg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Theme.bg, in: RoundedRectangle(cornerRadius: 8))
            }
            if let err = app.dictation.error { Text(err).font(.caption).foregroundStyle(Theme.warn) }
        }
        .padding(.top, 4)
    }

    private func startTest() {
        app.narrator.stop()
        app.dictation.clear()
        app.dictation.error = nil
        testing = true
        Task { await app.dictation.start(); if !app.dictation.listening { testing = false } }
    }

    private func stopTest() {
        guard testing else { return }
        testing = false
        app.dictation.stop()
    }
}

/// One choice of model: what it is, whether it fits, and Download / Listen / Use.
struct OptionCard<Extra: View>: View {
    @Environment(AppModel.self) private var app
    let title: String
    let tier: String
    let blurb: String
    let entry: ModelEntry?
    let selected: Bool
    var listen: (() -> Void)?
    var listening = false
    let use: () -> Void
    @ViewBuilder var extra: () -> Extra

    private var installed: Bool { entry.map { app.store.installed.contains($0.id) } ?? true }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.headline).foregroundStyle(Theme.fg)
                Text(tier).font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Theme.accent.opacity(0.18), in: Capsule()).foregroundStyle(Theme.accent)
                Spacer()
                if selected && installed { Label("In use", systemImage: "checkmark.circle.fill").font(.caption.bold()).foregroundStyle(Theme.accent) }
            }
            Text(blurb).font(.caption).foregroundStyle(Theme.dim)
            if let e = entry, !installed {
                let r = app.store.report(for: e, loadedGB: app.llm.loadedGB)
                HStack(spacing: 4) {
                    Image(systemName: r.verdict.symbol)
                    Text(r.verdict.label)
                    Text(String(format: "· %.1f GB download", app.store.facts[e.id]?.gb ?? e.approxGB)).foregroundStyle(Theme.dim)
                }
                .font(.caption)
                .foregroundStyle(r.verdict == .comfortable ? .green : r.verdict == .tight ? .orange : .red)
            }
            if let e = entry, case .downloading(let id, let f) = app.store.download, id == e.id {
                ShimmerBar(fraction: f)
                HStack {
                    Text("Downloading… \(Int(f * 100))%").font(.caption).foregroundStyle(Theme.dim)
                    Spacer()
                    Button("Cancel") { app.store.cancelDownload() }.font(.caption)
                }
            } else {
                HStack(spacing: 10) {
                    if !installed, let e = entry {
                        Button {
                            app.store.startDownload(e)
                        } label: { Label("Download", systemImage: "arrow.down.circle") }
                        .buttonStyle(.bordered)
                        .disabled(app.store.isDownloading)
                        if app.store.isDownloading { Text("after the current download").font(.caption2).foregroundStyle(Theme.dim) }
                    } else {
                        if let listen {
                            Button(action: listen) {
                                Label(listening ? "Stop" : "Listen", systemImage: listening ? "stop.fill" : "play.fill")
                            }
                            .buttonStyle(.bordered)
                        }
                        if !selected {
                            Button("Use this", action: use).buttonStyle(.borderedProminent).tint(Theme.accent).foregroundStyle(Theme.onAccent)
                        }
                        extra()
                    }
                    Spacer(minLength: 0)
                }
                .font(.subheadline)
            }
        }
        .padding(12)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected && installed ? Theme.accent.opacity(0.7) : Theme.line))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture { if installed && !selected { use() } }
        .task { if let e = entry, app.store.facts[e.id] == nil { await app.store.loadFacts(e) } }
    }
}

extension OptionCard where Extra == EmptyView {
    init(title: String, tier: String, blurb: String, entry: ModelEntry?, selected: Bool,
         listen: (() -> Void)? = nil, listening: Bool = false, use: @escaping () -> Void) {
        self.init(title: title, tier: tier, blurb: blurb, entry: entry, selected: selected,
                  listen: listen, listening: listening, use: use, extra: { EmptyView() })
    }
}

/// What is in memory right now, with Load, Unload and Restart, for when things go squirrelly.
struct MemoryPanel: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let busy = app.llm.busy || app.engine.busy
        VStack(alignment: .leading, spacing: 12) {
            if let e = app.store.language, app.store.hasLanguageModel {
                row(icon: "brain", name: "Storyteller: " + e.name, state: llmState) {
                    if app.llm.loadedID == nil {
                        Button("Load") { Task { await app.llm.preload() } }.disabled(app.llm.phase == .loading)
                    } else {
                        Button("Unload") { app.llm.unload() }.disabled(busy)
                        Button("Restart") { app.llm.unload(); Task { await app.llm.preload() } }.disabled(busy)
                    }
                }
            }
            if let v = app.store.voiceModel {
                row(icon: "speaker.wave.2", name: "Narrator: " + v.name,
                    state: app.narrator.preparing ? "Loading…" : app.narrator.loadedVoiceID == v.id ? String(format: "In memory · about %.1f GB", app.narrator.neuralLoadedGB) : "Not loaded (loads when it first speaks)") {
                    if app.narrator.loadedVoiceID != nil { Button("Unload") { app.narrator.unloadNeural() } }
                }
            }
            if let l = app.store.listeningModel {
                row(icon: "mic", name: "Listening: " + l.name,
                    state: app.dictation.loadedModelID == l.id ? "In memory" : "Not loaded (loads when you speak)") {
                    if app.dictation.loadedModelID != nil { Button("Unload") { app.dictation.unloadModel() }.disabled(app.dictation.listening) }
                }
            }
            if case .failed(let m) = app.llm.phase { Text(m).font(.caption).foregroundStyle(Theme.warn) }
            if busy { Text("The storyteller is busy; Unload and Restart are available when it finishes.").font(.caption).foregroundStyle(Theme.dim) }
        }
    }

    private var llmState: String {
        if app.llm.phase == .loading { return "Loading…" }
        if app.llm.loadedID != nil {
            let speed = app.llm.lastTokensPerSecond > 0 ? String(format: " · last reply %.0f tokens/s", app.llm.lastTokensPerSecond) : ""
            return String(format: "In memory · about %.1f GB", app.llm.loadedGB) + speed
        }
        return "Not loaded (loads when a story starts)"
    }

    private func row<B: View>(icon: String, name: String, state: String, @ViewBuilder buttons: () -> B) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon).foregroundStyle(Theme.accent).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.subheadline.bold())
                Text(state).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) { buttons() }.buttonStyle(.bordered).font(.caption)
        }
    }
}

/// "af_heart" → "Heart (American, female)"; other names are shown as they are.
func voiceLabel(_ v: String) -> String {
    let parts = v.split(separator: "_")
    guard parts.count == 2, parts[0].count == 2 else { return v }
    let p = Array(parts[0])
    let accent = p[0] == "a" ? "American" : p[0] == "b" ? "British" : String(p[0])
    let sex = p[1] == "f" ? "female" : p[1] == "m" ? "male" : String(p[1])
    return parts[1].prefix(1).uppercased() + parts[1].dropFirst() + " (\(accent), \(sex))"
}
