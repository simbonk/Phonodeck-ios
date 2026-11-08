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
    /// Asks twice: once for repos tagged MLX, and once without the tag, because many MLX
    /// conversions (4-bit uploads of community fine-tunes especially) aren't tagged. The fit check
    /// then reads each repo's files to tell which really are MLX.
    static func search(_ text: String, kind: ModelEntry.Kind) async throws -> [HubHit] {
        let tagged = try await search(text, kind: kind, mlxOnly: true, limit: 50)
        let untagged = (try? await search(text, kind: kind, mlxOnly: false, limit: 30)) ?? []
        var seen = Set<String>()
        return (tagged + untagged).filter { seen.insert($0.id).inserted }
    }

    private static func search(_ text: String, kind: ModelEntry.Kind, mlxOnly: Bool, limit: Int) async throws -> [HubHit] {
        var c = URLComponents(string: "https://huggingface.co/api/models")!
        var q = [URLQueryItem(name: "search", value: text),
                 URLQueryItem(name: "sort", value: "downloads"), URLQueryItem(name: "direction", value: "-1"),
                 URLQueryItem(name: "limit", value: "\(limit)")]
        if mlxOnly { q.append(URLQueryItem(name: "library", value: "mlx")) }
        switch kind {
        case .voice: q.append(URLQueryItem(name: "pipeline_tag", value: "text-to-speech"))
        case .listening: q.append(URLQueryItem(name: "pipeline_tag", value: "automatic-speech-recognition"))
        case .language: break   // Qwen3.5 and Gemma 4 are tagged image-text-to-text, so filter below instead.
        }
        c.queryItems = q
        let (data, resp) = try await get(c.url!)
        guard resp?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let hits = try JSONDecoder().decode([HubHit].self, from: data)
        guard kind == .language else { return hits }
        let storyTags: Set<String> = ["text-generation", "image-text-to-text", "any-to-any", "text2text-generation"]
        return hits.filter { h in
            guard let t = h.pipeline_tag else { return true }
            return storyTags.contains(t)
        }
    }
}

extension HFHub {
    /// The same search in every format, to tell "no MLX version" apart from "no such model".
    static func searchAnyFormat(_ text: String) async throws -> [HubHit] {
        var c = URLComponents(string: "https://huggingface.co/api/models")!
        c.queryItems = [URLQueryItem(name: "search", value: text), URLQueryItem(name: "sort", value: "downloads"),
                        URLQueryItem(name: "direction", value: "-1"), URLQueryItem(name: "limit", value: "20")]
        let (data, resp) = try await get(c.url!)
        guard resp?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode([HubHit].self, from: data)
    }
}

/// Why a search result is or isn't offered.
enum HitFit: Equatable {
    case checking
    /// Runs well, runs but tight, or fits alone but not beside the chosen voice and listening models.
    case comfortable, tight, crowded
    case noMLX, tooBig, unreadable

    var offered: Bool { self == .comfortable || self == .tight || self == .crowded }
}

/// Search Hugging Face by keyword and download a model with one tap. Results this device can't
/// run (no MLX weights, or too big for the memory iOS gives the app) are left out, and the count
/// of what was left out is shown instead.
struct ModelSearchSection: View {
    @Environment(AppModel.self) private var app
    @State private var text = ""
    @State private var kind: ModelEntry.Kind = .language
    @State private var hits: [HubHit] = []
    @State private var searching = false
    @State private var checking = 0
    @State private var message: String?
    @State private var errors: [String: String] = [:]
    @State private var lastQuery = ""

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
            ForEach(shown) { HitRow(hit: $0, kind: kind, fit: fit($0), candidate: candidate($0), error: $errors[$0.id]) }
            if !hits.isEmpty { summary }
        } header: {
            Text("Find models on Hugging Face")
        } footer: {
            Text("Most downloaded first. Only models that run on this \(DeviceFit.deviceWord) are listed. Storytellers can be MLX or GGUF (run with llama.cpp); for GGUF, Phonodeck picks the size that fits, usually Q4_K_M.")
        }
    }

    private var shown: [HubHit] {
        hits.filter { fit($0).offered }
    }

    @ViewBuilder private var summary: some View {
        let fits = hits.map(fit)
        let noMLX = fits.filter { $0 == .noMLX || $0 == .unreadable }.count
        let big = fits.filter { $0 == .tooBig }.count
        if checking > 0 {
            HStack(spacing: 8) {
                ProgressView()
                Text("Checking \(checking) more for size and format…")
            }
            .font(.footnote).foregroundStyle(.secondary)
        }
        if noMLX + big > 0 {
            let parts = [noMLX > 0 ? "\(noMLX) in formats Phonodeck can't run" : nil,
                         big > 0 ? "\(big) too big for this \(DeviceFit.deviceWord)" : nil].compactMap { $0 }
            Text("Hidden: \(parts.joined(separator: " and ")).\(shown.isEmpty && checking == 0 ? " Try adding \"4bit\" or \"mlx\" to the search, or ask for a smaller size (for example 4B instead of 9B)." : "")")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    /// What a result would be added as: the MLX weights, or for a GGUF storyteller the
    /// quantization that fits best. Nil when nothing in it can run here.
    private func candidate(_ hit: HubHit) -> ModelEntry? {
        if let existing = ModelCatalog.entry(hit.id) { return existing }
        guard let f = app.store.facts[hit.id] else { return nil }
        if f.usesGGUF { return kind == .language ? app.store.bestGGUF(id: hit.id, facts: f) : nil }
        if f.ggufOnly == true || !f.hasSafetensors || !f.looksMLX { return nil }
        let e = HitRow.entry(hit, kind: kind, facts: f)
        return DeviceFit.report(for: e, facts: f).verdict == .tooBig ? nil : e
    }

    /// Whether a result can be offered, from what Hugging Face says about its files.
    private func fit(_ hit: HubHit) -> HitFit {
        guard let f = app.store.facts[hit.id] else { return checked.contains(hit.id) ? .unreadable : .checking }
        let runnable = f.usesGGUF ? kind == .language : !(f.ggufOnly == true || !f.hasSafetensors || !f.looksMLX)
        if !runnable { return .noMLX }
        // Hide only what can't run at all; what fits alone but not beside the chosen voice and
        // listening models is shown with a warning, since those can be switched.
        guard let e = candidate(hit) else { return .tooBig }
        switch app.store.report(for: e).verdict {
        case .comfortable: return .comfortable
        case .tight: return .tight
        case .tooBig: return .crowded
        }
    }

    @State private var checked: Set<String> = []

    private func run() async {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        lastQuery = q
        searching = true
        message = nil
        errors = [:]
        defer { searching = false }
        do {
            let found = try await HFHub.search(q, kind: kind)
            guard lastQuery == q else { return }
            hits = found
            if hits.isEmpty {
                // Many community models (uncensored and roleplay fine-tunes especially) are only
                // published as GGUF for llama.cpp. Say so, rather than suggesting nothing exists.
                let others = (try? await HFHub.searchAnyFormat(q)) ?? []
                if others.isEmpty {
                    message = "Nothing on Hugging Face matches \"\(q)\". Try fewer or different words."
                } else {
                    let names = others.prefix(3).map(\.name).joined(separator: ", ")
                    message = "No MLX version matches \"\(q)\" yet. \(others.count == 20 ? "20+" : "\(others.count)") models match in other formats (usually GGUF, for llama.cpp apps), such as \(names). Phonodeck can't run those until someone converts them to MLX."
                }
                return
            }
            await checkAll(found, query: q)
        } catch {
            hits = []
            message = "Couldn't reach Hugging Face: \(error.localizedDescription)"
        }
    }

    /// Reads every result's file list and config, eight at a time, so the list can hide what won't run.
    private func checkAll(_ found: [HubHit], query: String) async {
        let todo = found.map(\.id).filter { app.store.facts[$0] == nil }
        checking = todo.count
        await withTaskGroup(of: (String, ModelFacts?).self) { group in
            var i = 0
            while i < min(8, todo.count) {
                let id = todo[i]
                group.addTask { (id, try? await HFHub.facts(id)) }
                i += 1
            }
            while let (id, f) = await group.next() {
                if let f { app.store.setFacts(f, for: id) }
                checked.insert(id)
                if lastQuery == query { checking = max(0, checking - 1) }
                if i < todo.count {
                    let next = todo[i]
                    group.addTask { (next, try? await HFHub.facts(next)) }
                    i += 1
                }
            }
        }
        if lastQuery == query { checking = 0 }
    }
}

private struct HitRow: View {
    @Environment(AppModel.self) private var app
    let hit: HubHit
    let kind: ModelEntry.Kind
    let fit: HitFit
    let candidate: ModelEntry?
    @Binding var error: String?
    @State private var starting = false

    static func entry(_ hit: HubHit, kind: ModelEntry.Kind, facts: ModelFacts?) -> ModelEntry {
        let gb = facts?.gb ?? 0
        return ModelEntry(id: hit.id, name: hit.name, blurb: "", kind: kind, approxGB: gb, paramsB: gb * 2, custom: true)
    }

    private var installed: Bool { app.store.installed.contains(hit.id) }
    private var progress: Double? {
        if case .downloading(let id, let f) = app.store.download, id == hit.id { return f } else { return nil }
    }
    private var failure: String? {
        if case .failed(let id, let m) = app.store.download, id == hit.id { return m } else { return nil }
    }

    var body: some View {
        let facts = app.store.facts[hit.id]
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(hit.name).font(.subheadline.bold()).lineLimit(2)
                    HStack(spacing: 6) {
                        Text(hit.owner)
                        if let d = hit.downloads { Text("· \(d.formatted(.number.notation(.compactName))) downloads") }
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                    if let facts { fitLine(facts) }
                    if facts?.gated == true {
                        Label(HFToken.value == nil ? "Gated: needs a Hugging Face token (below)" : "Gated: accept its terms on Hugging Face first",
                              systemImage: "lock.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                Spacer()
                action
            }
            if let p = progress {
                ProgressView(value: p) {
                    Text(p > 0 ? "Downloading… \(Int(p * 100))%" : "Starting download…").font(.caption)
                }
            }
            if let m = failure ?? error {
                Text(m).font(.caption).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder private func fitLine(_ facts: ModelFacts) -> some View {
        let look = style
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: look.symbol)
            Text(look.label)
            if let c = candidate {
                Text(String(format: "· %.1f GB", app.store.downloadGB(c))).foregroundStyle(.secondary)
                if let q = c.ggufFile.map({ GGUFFile(name: $0, bytes: 0).quant }) {
                    Text("· GGUF \(q)").foregroundStyle(.secondary)
                }
            }
        }
        .font(.caption)
        .foregroundStyle(look.color)
    }

    private var style: (symbol: String, label: String, color: Color) {
        switch fit {
        case .comfortable: ("checkmark.circle.fill", "Runs comfortably", .green)
        case .tight: ("exclamationmark.triangle.fill", "Will run, but tight", .orange)
        case .crowded: ("exclamationmark.triangle.fill", "Fits, but not beside your neural voice and listening models", .orange)
        default: ("questionmark.circle", "", .secondary)
        }
    }

    @ViewBuilder private var action: some View {
        if installed {
            Label("Installed", systemImage: "checkmark.circle.fill").font(.caption.bold()).foregroundStyle(.green)
        } else if progress != nil {
            Button { app.store.cancelDownload() } label: {
                Label("Cancel", systemImage: "xmark.circle.fill").font(.caption.bold())
            }
            .buttonStyle(.bordered)
        } else if starting {
            ProgressView()
        } else {
            Button(failure != nil ? "Retry" : "Download") {
                starting = true
                error = nil
                app.store.dismissDownloadError()
                Task {
                    error = await app.store.addAndDownload(id: hit.id, kind: kind)
                    starting = false
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(app.store.isDownloading)
        }
    }
}

/// An optional Hugging Face token, for gated models (ones that make you accept terms first).
struct HFTokenSection: View {
    @State private var draft = ""
    @State private var saved = HFToken.value != nil
    @State private var editing = false

    var body: some View {
        Section {
            if saved && !editing {
                LabeledContent("Token", value: "Saved")
                Button("Replace token") { editing = true }
                Button("Remove token", role: .destructive) { HFToken.value = nil; saved = false }
            } else {
                SecureField("Paste a token (starts with hf_)", text: $draft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Save token") {
                    HFToken.value = draft
                    saved = HFToken.value != nil
                    draft = ""
                    editing = false
                }
                .disabled(!draft.trimmingCharacters(in: .whitespaces).hasPrefix("hf_"))
            }
            Link("Make a token on Hugging Face", destination: URL(string: "https://huggingface.co/settings/tokens")!)
        } header: {
            Text("Hugging Face token (optional)")
        } footer: {
            Text("Only needed for gated models, which show a lock in search. Most models, including mlx-community's, download without one. To make one: sign in at huggingface.co, open Settings > Access Tokens, tap Create new token, choose Read, create it and copy it here. For a gated model, also open its page and accept its terms. The token stays in this \(DeviceFit.deviceWord)'s Keychain.")
        }
    }
}
