import SwiftUI

/// One model in a Hugging Face search.
struct HubHit: Identifiable, Hashable, Decodable {
    let id: String
    let downloads: Int?
    let likes: Int?
    let pipeline_tag: String?

    var name: String { id.split(separator: "/").last.map(String.init) ?? id }
    var owner: String { id.split(separator: "/").first.map(String.init) ?? "" }
}

extension HFHub {
    /// Searches Hugging Face for MLX models of one kind, most downloaded first.
    static func search(_ text: String, kind: ModelEntry.Kind) async throws -> [HubHit] {
        var c = URLComponents(string: "https://huggingface.co/api/models")!
        var q = [URLQueryItem(name: "search", value: text), URLQueryItem(name: "library", value: "mlx"),
                 URLQueryItem(name: "sort", value: "downloads"), URLQueryItem(name: "direction", value: "-1"),
                 URLQueryItem(name: "limit", value: "40")]
        switch kind {
        case .voice: q.append(URLQueryItem(name: "pipeline_tag", value: "text-to-speech"))
        case .listening: q.append(URLQueryItem(name: "pipeline_tag", value: "automatic-speech-recognition"))
        case .language: break   // Qwen3.5 and Gemma 4 are tagged image-text-to-text, so filter below instead.
        }
        c.queryItems = q
        let (data, resp) = try await URLSession.shared.data(from: c.url!)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let hits = try JSONDecoder().decode([HubHit].self, from: data)
        guard kind == .language else { return hits }
        let storyTags: Set<String> = ["text-generation", "image-text-to-text", "any-to-any", "text2text-generation"]
        return hits.filter { h in
            guard let t = h.pipeline_tag else { return true }
            return storyTags.contains(t)
        }
    }
}

/// Search Hugging Face by keyword and add a model with one tap. Each result shows its size and
/// whether it fits this device, worked out the same way as the built-in models.
struct ModelSearchSection: View {
    @Environment(AppModel.self) private var app
    @State private var text = ""
    @State private var kind: ModelEntry.Kind = .language
    @State private var hits: [HubHit] = []
    @State private var searching = false
    @State private var message: String?
    @State private var adding: String?

    var body: some View {
        Section {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Keywords, e.g. qwen3.5 uncensored", text: $text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { Task { await run() } }
                if searching { ProgressView() }
            }
            Picker("Looking for a", selection: $kind) {
                Text("Storyteller").tag(ModelEntry.Kind.language)
                Text("Voice").tag(ModelEntry.Kind.voice)
                Text("Listening").tag(ModelEntry.Kind.listening)
            }
            .onChange(of: kind) { if !text.isEmpty { Task { await run() } } }
            if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            ForEach(hits) { HitRow(hit: $0, kind: kind, adding: $adding, message: $message) }
        } header: {
            Text("Find models on Hugging Face")
        } footer: {
            Text("Shows MLX models only, most downloaded first. Sizes and fit appear as each one is checked; 4-bit versions are usually the right size.")
        }
    }

    private func run() async {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        searching = true
        message = nil
        defer { searching = false }
        do {
            hits = try await HFHub.search(q, kind: kind)
            if hits.isEmpty { message = "No MLX models match \"\(q)\". Try fewer or different words." }
        } catch {
            hits = []
            message = "Couldn't reach Hugging Face: \(error.localizedDescription)"
        }
    }
}

private struct HitRow: View {
    @Environment(AppModel.self) private var app
    let hit: HubHit
    let kind: ModelEntry.Kind
    @Binding var adding: String?
    @Binding var message: String?

    private var entry: ModelEntry {
        let gb = app.store.facts[hit.id]?.gb ?? 0
        return ModelEntry(id: hit.id, name: hit.name, blurb: "", kind: kind, approxGB: gb, paramsB: gb * 2, custom: true)
    }

    private var added: Bool { ModelCatalog.entry(hit.id) != nil }

    var body: some View {
        let facts = app.store.facts[hit.id]
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(hit.name).font(.subheadline.bold()).lineLimit(2)
                HStack(spacing: 6) {
                    Text(hit.owner)
                    if let d = hit.downloads { Text("· \(d.formatted(.number.notation(.compactName))) downloads") }
                }
                .font(.caption2).foregroundStyle(.secondary)
                if let facts {
                    if !facts.hasSafetensors {
                        Text("No MLX weights").font(.caption).foregroundStyle(.red)
                    } else {
                        let loaded = app.llm.loadedGB + app.narrator.neuralLoadedGB + app.dictation.loadedGB
                        let r = app.store.report(for: entry, loadedGB: loaded)
                        HStack(spacing: 4) {
                            Image(systemName: r.verdict.symbol)
                            Text(r.verdict.label)
                            Text(String(format: "· %.1f GB", facts.gb)).foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        .foregroundStyle(r.verdict == .comfortable ? .green : r.verdict == .tight ? .orange : .red)
                    }
                } else {
                    Text("Checking size…").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if added {
                Label("Added", systemImage: "checkmark").font(.caption.bold()).foregroundStyle(.secondary)
            } else if adding == hit.id {
                ProgressView()
            } else {
                Button("Add") {
                    adding = hit.id
                    Task {
                        let r = await app.store.addCustom(link: hit.id, kind: kind)
                        adding = nil
                        if case .failed(let m) = r { message = m }
                    }
                }
                .buttonStyle(.bordered)
                .disabled(facts?.hasSafetensors == false)
            }
        }
        .task(id: hit.id) { if app.store.facts[hit.id] == nil { await app.store.loadFacts(entry) } }
    }
}
