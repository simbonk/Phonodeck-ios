import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLMCommon
import Observation

/// Downloads models from Hugging Face onto the phone, remembers which are installed, and which
/// storyteller and narrator voice are selected.
@Observable
@MainActor
final class ModelStore {
    enum DownloadState: Equatable {
        case idle
        case downloading(id: String, fraction: Double)
        case failed(id: String, message: String)
    }

    var download: DownloadState = .idle
    private(set) var installed: Set<String> = []
    private(set) var facts: [String: ModelFacts] = [:]
    private(set) var customModels: [ModelEntry] = ModelCatalog.custom
    private var downloadTask: Task<Void, Never>?

    /// The language model used for Chat and the Phonodeck.
    var languageID: String? { didSet { UserDefaults.standard.set(languageID, forKey: "activeModel") } }
    /// The narrator voice model; nil means Apple's built-in voices.
    var voiceID: String? { didSet { UserDefaults.standard.set(voiceID, forKey: "activeVoiceModel") } }

    /// The speech recognition model; nil means Apple's on-device dictation.
    var listeningID: String? { didSet { UserDefaults.standard.set(listeningID, forKey: "activeListeningModel") } }

    var language: ModelEntry? { ModelCatalog.entry(languageID) }
    var voiceModel: ModelEntry? { ModelCatalog.entry(voiceID) }
    var listeningModel: ModelEntry? { ModelCatalog.entry(listeningID) }
    var hasLanguageModel: Bool { languageID.map(installed.contains) ?? false }

    /// Model files live in Application Support (Caches may be purged by iOS) and are kept out of iCloud backups.
    nonisolated static let directory: URL = {
        let url = URL.applicationSupportDirectory.appending(path: "models", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var u = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? u.setResourceValues(values)
        return url
    }()

    nonisolated static let hubCache = HubCache(cacheDirectory: directory)
    /// Signs downloads with the person's Hugging Face token when they've added one (for gated models).
    let downloader: any Downloader = #hubDownloader(HubClient(
        host: HubClient.defaultHost, tokenProvider: .custom { HFToken.value }, cache: ModelStore.hubCache))

    init() {
        languageID = UserDefaults.standard.string(forKey: "activeModel")
        voiceID = UserDefaults.standard.string(forKey: "activeVoiceModel")
        listeningID = UserDefaults.standard.string(forKey: "activeListeningModel")
        refreshInstalled()
        if !hasLanguageModel, let first = (ModelCatalog.language + customModels).first(where: { installed.contains($0.id) }) {
            languageID = first.id
        }
        if let v = voiceID, !installed.contains(v) { voiceID = nil }
        if let l = listeningID, !installed.contains(l) { listeningID = nil }
        for e in ModelCatalog.all { if let f = HFHub.cached(e.id) { facts[e.id] = f } }
    }

    // MARK: Files

    /// The Hugging Face cache layout: models--org--name/snapshots/<revision>/
    /// The downloaded .gguf file of a GGUF storyteller.
    nonisolated static func ggufPath(_ entry: ModelEntry) -> URL? {
        guard let file = entry.ggufFile, let dir = snapshotDirectory(entry.id) else { return nil }
        return dir.appending(path: file)
    }

    nonisolated static func repoDirectory(_ id: String) -> URL {
        directory.appending(path: "models--" + id.replacingOccurrences(of: "/", with: "--"), directoryHint: .isDirectory)
    }

    /// A downloaded copy with weights in it. Storytellers also need their config.json; voice and
    /// listening models are packaged in different ways, so any weights file counts for them.
    nonisolated static func snapshotDirectory(_ id: String) -> URL? {
        let snaps = repoDirectory(id).appending(path: "snapshots", directoryHint: .isDirectory)
        let fm = FileManager.default
        guard let revs = try? fm.contentsOfDirectory(at: snaps, includingPropertiesForKeys: nil) else { return nil }
        // A GGUF storyteller is one file and nothing else.
        if let file = ModelCatalog.entry(id)?.ggufFile {
            return revs.first { fm.fileExists(atPath: $0.appending(path: file).path) }
        }
        let needsConfig = ModelCatalog.entry(id).map { $0.kind == .language } ?? true
        let weights = [".safetensors", ".bin", ".npz", ".pth", ".gguf"]
        return revs.first { rev in
            (!needsConfig || fm.fileExists(atPath: rev.appending(path: "config.json").path))
                && ((try? fm.subpathsOfDirectory(atPath: rev.path))?.contains { p in weights.contains { p.hasSuffix($0) } } ?? false)
        }
    }

    func refreshInstalled() {
        installed = Set(ModelCatalog.all.map(\.id).filter { Self.snapshotDirectory($0) != nil })
    }

    // MARK: Facts (size and shape from Hugging Face)

    func loadFacts(_ entry: ModelEntry) async {
        if let f = try? await HFHub.facts(entry.id) { facts[entry.id] = f }
    }

    func setFacts(_ f: ModelFacts, for id: String) { facts[id] = f }

    /// Download size shown in the lists.
    func downloadGB(_ e: ModelEntry) -> Double { e.isGGUF ? e.approxGB : facts[e.id]?.gb ?? e.approxGB }

    /// GGUF repos hold one file per quantization. Picks the one to offer: Q4_K_M when it fits
    /// (the usual best balance of quality, speed and size), otherwise the next best that fits.
    /// Returns nil when even the smallest is too big for this device.
    func bestGGUF(id: String, facts f: ModelFacts) -> ModelEntry? {
        guard let files = f.ggufFiles, !files.isEmpty else { return nil }
        let preference = ["Q4_K_M", "Q4_K_S", "IQ4_XS", "IQ4_NL", "Q4_0", "Q5_K_M", "Q5_K_S", "Q3_K_L", "Q3_K_M", "IQ3_M", "Q6_K", "Q3_K_S", "IQ3_XS"]
        let name = id.split(separator: "/").last.map(String.init) ?? id
        func entry(_ g: GGUFFile) -> ModelEntry {
            ModelEntry(id: id, name: name.replacingOccurrences(of: "-GGUF", with: "", options: .caseInsensitive) + " (\(g.quant))",
                       blurb: "GGUF from Hugging Face, run with llama.cpp.", kind: .language,
                       approxGB: g.gb, paramsB: g.gb * 2, custom: true, ggufFile: g.name)
        }
        func fits(_ e: ModelEntry) -> Bool { DeviceFit.report(for: e, facts: f).verdict != .tooBig }
        for q in preference {
            if let g = files.first(where: { $0.quant == q }), fits(entry(g)) { return entry(g) }
        }
        return files.sorted { $0.bytes < $1.bytes }.map(entry).first(where: fits)
    }

    /// Memory the selected models occupy when loaded, used to judge what else fits beside them.
    func neededGB(_ id: String?) -> Double {
        guard let e = ModelCatalog.entry(id) else { return 0 }
        return DeviceFit.need(for: e, facts: facts[e.id])
    }

    func report(for entry: ModelEntry) -> DeviceFit.Report {
        // Everything else that stays loaded while you play.
        let partner = [languageID, voiceID, listeningID]
            .filter { id in ModelCatalog.entry(id)?.kind != entry.kind }
            .reduce(0) { $0 + neededGB($1) }
        return DeviceFit.report(for: entry, facts: facts[entry.id], otherLoadedGB: partner)
    }

    // MARK: Custom models from a link

    enum AddResult { case added(ModelEntry), failed(String) }

    func addCustom(link: String, kind: ModelEntry.Kind) async -> AddResult {
        guard let id = ModelCatalog.repoID(from: link) else {
            return .failed("That doesn't look like a Hugging Face model link. It should look like huggingface.co/mlx-community/Qwen3-4B-4bit.")
        }
        if let existing = ModelCatalog.entry(id) { return .added(existing) }
        let f: ModelFacts
        do { f = try await HFHub.facts(id) } catch { return .failed(error.localizedDescription) }
        if f.usesGGUF {
            let name = id.split(separator: "/").last.map(String.init) ?? id
            guard kind == .language else {
                return .failed("\(name) is a GGUF model. Phonodeck runs GGUF storytellers, but voices and listening models need MLX versions.")
            }
            guard let entry = bestGGUF(id: id, facts: f) else {
                let smallest = f.ggufFiles?.map(\.gb).min() ?? 0
                return .failed(smallest > 0
                    ? String(format: "Even the smallest version of %@ (%.1f GB) is too big for this %@.", name, smallest, DeviceFit.deviceWord)
                    : "\(name) has no GGUF file Phonodeck can use.")
            }
            facts[id] = f
            customModels.append(entry)
            ModelCatalog.custom = customModels
            return .added(entry)
        }
        guard f.hasSafetensors else {
            return .failed("\(id) has no .safetensors weights, so it can't run here. Look for an MLX version, usually under mlx-community.")
        }
        guard f.looksMLX else {
            return .failed("\(id) isn't marked as an MLX model. iPhone needs MLX weights: search Hugging Face for the same model under mlx-community.")
        }
        let name = id.split(separator: "/").last.map(String.init) ?? id
        let entry = ModelEntry(
            id: id, name: name, blurb: "Added from Hugging Face.", kind: kind,
            approxGB: f.gb, paramsB: f.gb * 2, custom: true)
        facts[id] = f
        customModels.append(entry)
        ModelCatalog.custom = customModels
        return .added(entry)
    }

    func removeCustom(_ entry: ModelEntry) {
        delete(entry)
        customModels.removeAll { $0.id == entry.id }
        ModelCatalog.custom = customModels
    }

    /// Adds a search result to the lists (if it isn't there yet) and starts downloading it.
    /// Returns a message when it can't.
    func addAndDownload(id: String, kind: ModelEntry.Kind) async -> String? {
        let entry: ModelEntry
        switch await addCustom(link: id, kind: kind) {
        case .failed(let m): return m
        case .added(let e): entry = e
        }
        if installed.contains(entry.id) { return nil }
        if isDownloading { return "Another model is downloading. Wait for it to finish, or cancel it at the top of this page." }
        startDownload(entry)
        return nil
    }

    func dismissDownloadError() { if case .failed = download { download = .idle } }

    /// What went wrong, in words that say what to do about it.
    private func explain(_ error: Error, _ entry: ModelEntry) -> String {
        let text = error.localizedDescription
        let lower = text.lowercased()
        let refused = ["401", "403", "unauthorized", "forbidden", "gated", "authentication"].contains { lower.contains($0) }
        if refused || (facts[entry.id]?.gated == true && HFToken.value == nil) {
            return HFToken.value == nil
                ? "Hugging Face refused to send \(entry.name). It's gated: add a Hugging Face token at the bottom of this page, accept the model's terms on its page, then try again."
                : "Hugging Face refused to send \(entry.name) with your token. Open the model's page, accept its terms, and try again."
        }
        if (error as? URLError)?.code == .notConnectedToInternet { return "The download of \(entry.name) stopped: there's no internet connection." }
        if lower.contains("space") && lower.contains("disk") || (error as NSError).code == NSFileWriteOutOfSpaceError {
            return "There isn't enough free storage for \(entry.name). Free some space in the \(DeviceFit.deviceWord)'s Settings > General > Storage."
        }
        return "The download of \(entry.name) stopped: \(text)"
    }

    // MARK: Download, select, delete

    var isDownloading: Bool { if case .downloading = download { return true } else { return false } }

    func startDownload(_ entry: ModelEntry) {
        guard !isDownloading else { return }
        download = .downloading(id: entry.id, fraction: 0)
        let downloader = self.downloader
        downloadTask = Task {
            let progress: @Sendable (Progress) -> Void = { p in
                let f = p.fractionCompleted
                Task { @MainActor in
                    if case .downloading(let id, _) = self.download, id == entry.id {
                        self.download = .downloading(id: entry.id, fraction: f)
                    }
                }
            }
            do {
                if let file = entry.ggufFile {
                    _ = try await downloader.download(
                        id: entry.id, revision: "main", matching: [file], useLatest: false, progressHandler: progress)
                } else if entry.kind == .language {
                    _ = try await MLXLMCommon.resolve(
                        configuration: entry.configuration, from: downloader, useLatest: false, progressHandler: progress)
                } else {
                    _ = try await downloader.download(
                        id: entry.id, revision: "main", matching: ["*"], useLatest: false, progressHandler: progress)
                }
                refreshInstalled()
                if !installed.contains(entry.id) {
                    download = .failed(id: entry.id, message: "\(entry.name) downloaded, but its files don't look like a model Phonodeck can load.")
                    return
                }
                download = .idle
                if entry.kind == .language, !hasLanguageModel { languageID = entry.id }
                if entry.kind == .voice, voiceID == nil { voiceID = entry.id }
                if entry.kind == .listening, listeningID == nil { listeningID = entry.id }
                if entry.id.contains("Kokoro") { await Self.prefetchKokoroText() }
            } catch is CancellationError {
                download = .idle
            } catch {
                download = .failed(id: entry.id, message: explain(error, entry))
            }
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        download = .idle
    }

    func delete(_ entry: ModelEntry) {
        try? FileManager.default.removeItem(at: Self.repoDirectory(entry.id))
        refreshInstalled()
        if languageID == entry.id {
            languageID = (ModelCatalog.language + customModels).first { $0.kind == .language && installed.contains($0.id) }?.id
        }
        if voiceID == entry.id { voiceID = nil }
        if listeningID == entry.id { listeningID = nil }
    }

    /// Kokoro turns text into sounds with a pronunciation dictionary it fetches on first use.
    /// Loading it once right after the download stores the dictionary, so it works offline later.
    static func prefetchKokoroText() async {
        guard let entry = ModelCatalog.voice.first(where: { $0.id.contains("Kokoro") }),
              let dir = snapshotDirectory(entry.id) else { return }
        _ = try? await NeuralVoiceWarmup.warm(directory: dir)
    }

    func diskUsage(_ id: String) -> Int64 {
        guard let e = FileManager.default.enumerator(
            at: Self.repoDirectory(id), includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isSymbolicLinkKey])
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e {
            let v = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isSymbolicLinkKey])
            if v?.isSymbolicLink == true { continue }
            total += Int64(v?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
