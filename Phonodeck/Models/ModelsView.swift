import SwiftUI

struct ModelsView: View {
    @Environment(AppModel.self) private var app
    @State private var link = ""
    @State private var linkKind: ModelEntry.Kind = .language
    @State private var adding = false
    @State private var addError: String?
    @State private var confirmBig: ModelEntry?

    private var store: ModelStore { app.store }

    var body: some View {
        NavigationStack {
            List {
                deviceSection

                if store.hasLanguageModel {
                    Section {
                        MemoryPanel()
                    } header: {
                        Text("In memory")
                    } footer: {
                        Text("If replies get strange or slow, Restart reloads the storyteller fresh. Unloading frees memory; models load again by themselves when needed.")
                    }
                }

                Section {
                    ForEach(ModelCatalog.language + store.customModels.filter { $0.kind == .language }) { row($0) }
                } header: {
                    Text("Storyteller")
                } footer: {
                    Text("The language model that runs your stories and chats. Bigger models write richer stories but answer more slowly.")
                }

                // The same cards as the welcome setup, so choosing and trying a voice works the same way in both.
                Section {
                    NarratorSetup(manage: true).buttonStyle(.borderless)   // keeps each button in the row separate
                } footer: {
                    Text("All of these work offline. Neural voices sound more human but use memory alongside the storyteller.")
                }

                Section {
                    ListeningSetup(manage: true).buttonStyle(.borderless)
                } footer: {
                    Text("Say \"make it so\" to send.")
                }

                ModelSearchSection().buttonStyle(.borderless)
                addSection
                HFTokenSection()
            }
            .navigationTitle("Models")
            .task {
                for e in ModelCatalog.all where store.facts[e.id] == nil { await store.loadFacts(e) }
            }
            .confirmationDialog(
                "This model may not run well on this \(DeviceFit.deviceWord)",
                isPresented: Binding(get: { confirmBig != nil }, set: { if !$0 { confirmBig = nil } }),
                titleVisibility: .visible, presenting: confirmBig
            ) { e in
                Button("Download anyway") { store.startDownload(e) }
                Button("Cancel", role: .cancel) {}
            } message: { e in
                Text(report(e).detail)
            }
        }
    }

    // MARK: Sections

    private var deviceSection: some View {
        Section {
            LabeledContent("This \(DeviceFit.deviceWord)", value: DeviceFit.deviceName)
            LabeledContent("Memory", value: String(format: "%.0f GB", DeviceFit.ramGB.rounded()))
            LabeledContent("Room for models", value: String(format: "about %.1f GB", DeviceFit.modelBudgetGB))
            // Whatever is downloading, wherever it was started, with a way to stop it.
            if case .downloading(let id, let fraction) = store.download {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: fraction) {
                        Text("Downloading \(ModelCatalog.entry(id)?.name ?? id)").font(.subheadline.bold())
                    } currentValueLabel: {
                        Text(fraction > 0 ? "\(Int(fraction * 100))% · keep Phonodeck open until it finishes" : "Starting…")
                    }
                    Button("Cancel download", role: .cancel) { store.cancelDownload() }.font(.caption)
                }
            }
            if case .failed(_, let message) = store.download {
                VStack(alignment: .leading, spacing: 6) {
                    Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.footnote)
                    Button("Dismiss") { store.dismissDownloadError() }.font(.caption)
                }
            }
        } footer: {
            Text("iOS gives each app only part of the \(DeviceFit.deviceWord)'s memory. Each model below shows whether it fits alongside the others you've picked. Downloads are big, so use Wi-Fi.")
        }
    }

    private var addSection: some View {
        Section {
            TextField("huggingface.co/mlx-community/…", text: $link)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Picker("It is a", selection: $linkKind) {
                Text("Storyteller").tag(ModelEntry.Kind.language)
                Text("Voice").tag(ModelEntry.Kind.voice)
                Text("Listening").tag(ModelEntry.Kind.listening)
            }
            Button {
                adding = true
                addError = nil
                Task {
                    let r = await store.addCustom(link: link, kind: linkKind)
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
            Link("Browse storyteller models on Hugging Face", destination: HFHub.browseLanguageURL)
            Link("Browse voice models on Hugging Face", destination: HFHub.browseVoiceURL)
        } header: {
            Text("Add any model from Hugging Face")
        } footer: {
            Text("Paste a link to an MLX model (most are under mlx-community, and 4-bit versions are the right size for a phone). Phonodeck checks its size against this \(DeviceFit.deviceWord) before you download it.")
        }
    }

    // MARK: Rows

    private func report(_ e: ModelEntry) -> DeviceFit.Report {
        store.report(for: e)
    }

    private func isSelected(_ e: ModelEntry) -> Bool {
        switch e.kind {
        case .language: store.languageID == e.id
        case .voice: store.voiceID == e.id
        case .listening: store.listeningID == e.id
        }
    }

    private func select(_ e: ModelEntry) {
        switch e.kind {
        case .language:
            store.languageID = e.id
            app.llm.unload()
        case .voice:
            app.narrator.unloadNeural()
            store.voiceID = e.id
        case .listening:
            app.dictation.unloadModel()
            store.listeningID = e.id
        }
    }

    @ViewBuilder
    private func row(_ e: ModelEntry) -> some View {
        let installed = store.installed.contains(e.id)
        let r = report(e)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(e.name).font(.headline)
                if e.id == ModelCatalog.recommendedLanguageID { Text("Recommended").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2).background(Theme.accent.opacity(0.25), in: Capsule()) }
                if let t = e.tier { Text(t == .best ? "Good, slower" : t == .medium ? "Medium" : "Fast").font(.caption2).foregroundStyle(.secondary) }
                Spacer()
                if isSelected(e) && installed { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent) }
            }
            Text(e.blurb).font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Image(systemName: r.verdict.symbol).foregroundStyle(color(r.verdict))
                Text(r.verdict.label).font(.caption.bold()).foregroundStyle(color(r.verdict))
                Text("·").foregroundStyle(.secondary)
                Text(String(format: "%.1f GB", store.facts[e.id]?.gb ?? e.approxGB)).font(.caption).foregroundStyle(.secondary)
            }
            Text(r.detail).font(.caption).foregroundStyle(.secondary)

            if case .downloading(let id, let fraction) = store.download, id == e.id {
                ProgressView(value: fraction) { Text("Downloading… \(Int(fraction * 100))%").font(.caption) }
                Button("Cancel download", role: .cancel) { store.cancelDownload() }.font(.caption)
            } else {
                HStack {
                    if installed {
                        if e.kind == .voice { listenButton(e.id, e) }
                        if !isSelected(e) { Button("Use") { select(e) }.buttonStyle(.borderedProminent) }
                        Button("Delete", role: .destructive) {
                            if isSelected(e) {
                                if e.kind == .language { app.llm.unload() }
                                if e.kind == .voice { app.narrator.unloadNeural() }
                                if e.kind == .listening { app.dictation.unloadModel() }
                            }
                            store.delete(e)
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button("Download") {
                            if r.verdict == .comfortable { store.startDownload(e) } else { confirmBig = e }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.isDownloading)
                    }
                    Spacer()
                    Link(destination: e.url) { Image(systemName: "arrow.up.right.square") }
                    if e.custom {
                        // Removes the files too, including a half-finished download.
                        Button(role: .destructive) {
                            if isSelected(e) && e.kind == .language { app.llm.unload() }
                            store.removeCustom(e)
                        } label: { Label("Remove", systemImage: "trash") }
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
    }

    /// Plays a sample in that voice without changing the chosen one.
    private func listenButton(_ id: String, _ e: ModelEntry?) -> some View {
        let on = app.narrator.auditioningID == id
        return Button {
            if on { app.narrator.stop() } else { app.narrator.audition(e) }
        } label: {
            Label(on ? "Stop" : "Listen", systemImage: on ? "stop.fill" : "play.fill")
        }
        .buttonStyle(.bordered)
    }

    private func color(_ v: DeviceFit.Verdict) -> Color {
        switch v {
        case .comfortable: .green
        case .tight: .orange
        case .tooBig: .red
        }
    }
}
