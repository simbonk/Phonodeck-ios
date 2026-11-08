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
    let downloader: any Downloader = #hubDownloader(HubClient(cache: ModelStore.hubCache))

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
    nonisolated static func repoDirectory(_ id: String) -> URL {
        directory.appending(path: "models--" + id.replacingOccurrences(of: "/", with: "--"), directoryHint: .isDirectory)
    }

    /// A downloaded copy with weights in it. Storytellers also need their config.json; voice and
    /// listening models are packaged in different ways, so any weights file counts for them.
    nonisolated static func snapshotDirectory(_ id: String) -> URL? {
        let snaps = repoDirectory(id).appending(path: "snapshots", directoryHint: .isDirectory)
        let fm = FileManager.default
        guard let revs = try? fm.contentsOfDirectory(at: snaps, includingPropertiesForKeys: nil) else { return nil }
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

    /// Memory the selected models occupy when loaded, used to judge what else fits beside them.
    func neededGB(_ id: String?) -> Double {
        guard let e = ModelCatalog.entry(id) else { return 0 }
        return DeviceFit.need(for: e, facts: facts[e.id])
    }

    func report(for entry: ModelEntry, loadedGB: Double) -> DeviceFit.Report {
        // Everything else that stays loaded while you play.
        let partner = [languageID, voiceID, listeningID]
            .filter { id in ModelCatalog.entry(id)?.kind != entry.kind }
            .reduce(0) { $0 + neededGB($1) }
        return DeviceFit.report(for: entry, facts: facts[entry.id], otherLoadedGB: partner, alreadyLoadedGB: loadedGB)
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
                if entry.kind == .language {
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
                download = .failed(id: entry.id, message: "The download of \(entry.name) stopped: \(error.localizedDescription)")
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
