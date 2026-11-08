import Foundation
import os

/// What Hugging Face says about a model: its real download size and, for language
/// models, the shape that decides how much memory the conversation (KV cache) takes.
struct ModelFacts: Codable, Hashable {
    var bytes: Int64
    var layers: Int?
    var kvHeads: Int?
    var headDim: Int?
    var modelType: String?
    var hasSafetensors: Bool
    var looksMLX: Bool

    var gb: Double { Double(bytes) / 1_000_000_000 }
}

enum HFHub {
    static let browseLanguageURL = URL(string: "https://huggingface.co/models?library=mlx&pipeline_tag=text-generation&sort=trending")!
    static let browseVoiceURL = URL(string: "https://huggingface.co/models?library=mlx&pipeline_tag=text-to-speech&sort=trending")!

    private static let cacheKey = "modelFacts"

    static func cached(_ id: String) -> ModelFacts? {
        guard let d = UserDefaults.standard.data(forKey: cacheKey),
              let all = try? JSONDecoder().decode([String: ModelFacts].self, from: d) else { return nil }
        return all[id]
    }

    private static func store(_ id: String, _ facts: ModelFacts) {
        var all: [String: ModelFacts] = [:]
        if let d = UserDefaults.standard.data(forKey: cacheKey),
           let old = try? JSONDecoder().decode([String: ModelFacts].self, from: d) { all = old }
        all[id] = facts
        UserDefaults.standard.set(try? JSONEncoder().encode(all), forKey: cacheKey)
    }

    /// Reads the file list (with sizes) and config.json of a public repo.
    static func facts(_ id: String) async throws -> ModelFacts {
        struct Sibling: Decodable { let rfilename: String; let size: Int64? }
        struct Info: Decodable { let siblings: [Sibling]?; let tags: [String]?; let library_name: String? }
        let infoURL = URL(string: "https://huggingface.co/api/models/\(id)?blobs=true")!
        let (data, resp) = try await URLSession.shared.data(from: infoURL)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "Phonodeck", code: 404, userInfo: [NSLocalizedDescriptionKey: "Hugging Face has no public model called \"\(id)\"."])
        }
        let info = try JSONDecoder().decode(Info.self, from: data)
        let files = info.siblings ?? []
        let wanted = files.filter { f in
            let n = f.rfilename.lowercased()
            return n.hasSuffix(".safetensors") || n.hasSuffix(".json") || n.hasSuffix(".txt") || n.hasSuffix(".model") || n.hasSuffix(".jinja")
        }
        var facts = ModelFacts(
            bytes: wanted.reduce(0) { $0 + ($1.size ?? 0) },
            hasSafetensors: files.contains { $0.rfilename.hasSuffix(".safetensors") },
            looksMLX: (info.tags ?? []).contains("mlx") || info.library_name == "mlx" || id.lowercased().hasPrefix("mlx-community/"))

        if let pair = try? await URLSession.shared.data(from: URL(string: "https://huggingface.co/\(id)/resolve/main/config.json")!),
           (pair.1 as? HTTPURLResponse)?.statusCode == 200,
           var cfg = try? JSONSerialization.jsonObject(with: pair.0) as? [String: Any] {
            if let text = cfg["text_config"] as? [String: Any] { cfg.merge(text) { _, new in new } }
            facts.modelType = cfg["model_type"] as? String
            facts.layers = cfg["num_hidden_layers"] as? Int
            let heads = cfg["num_attention_heads"] as? Int
            facts.kvHeads = (cfg["num_key_value_heads"] as? Int) ?? heads
            if let hd = cfg["head_dim"] as? Int { facts.headDim = hd }
            else if let hidden = cfg["hidden_size"] as? Int, let heads, heads > 0 { facts.headDim = hidden / heads }
        }
        store(id, facts)
        return facts
    }
}

/// Works out whether a model will run comfortably on this phone.
///
/// iOS gives each app a memory budget well below the phone's total RAM. The app asks iOS how
/// much it may still use (`os_proc_available_memory`), adds back what its own loaded models
/// occupy, and compares that budget with what a model needs: its weights, the memory for the
/// conversation it remembers (KV cache), and some working room.
enum DeviceFit {
    enum Verdict: Equatable {
        case comfortable, tight, tooBig
        var label: String {
            switch self {
            case .comfortable: "Runs comfortably"
            case .tight: "Will run, but tight"
            case .tooBig: "Too big for this \(DeviceFit.deviceWord)"
            }
        }
        var symbol: String {
            switch self {
            case .comfortable: "checkmark.circle.fill"
            case .tight: "exclamationmark.triangle.fill"
            case .tooBig: "xmark.octagon.fill"
            }
        }
    }

    struct Report {
        var verdict: Verdict
        var needGB: Double
        var budgetGB: Double
        var wordsPerSecond: Double
        var detail: String
    }

    static let contextTokens = 4096

    static var ramGB: Double { Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824 }

    /// Bytes this app may still allocate before iOS closes it.
    static var availableGB: Double {
        let b = os_proc_available_memory()
        return b > 0 ? Double(b) / 1_073_741_824 : ramGB * 0.55
    }

    static var deviceName: String {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        if let k = knownDevices[machine] { return k }
        return machine.hasPrefix("iPad") ? "iPad" : machine.hasPrefix("iPhone") ? "iPhone" : machine
    }

    /// "iPad" or "iPhone", for sentences like "Too big for this iPad".
    static let deviceWord: String = {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        if machine.hasPrefix("iPad") { return "iPad" }
        #if targetEnvironment(simulator)
        if let m = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"], m.hasPrefix("iPad") { return "iPad" }
        #endif
        return "iPhone"
    }()

    /// Memory needed for weights plus a 4K-token conversation plus working room, in GB.
    static func need(for entry: ModelEntry, facts: ModelFacts?) -> Double {
        let weights = facts?.gb ?? entry.approxGB
        guard entry.kind == .language else { return weights * 1.25 + 0.25 }
        var kv = 0.45
        if let f = facts, let l = f.layers, let h = f.kvHeads, let d = f.headDim {
            kv = Double(2 * l * h * d * 2 * contextTokens) / 1_000_000_000
        }
        return weights * 1.05 + kv + 0.4
    }

    /// Rough generation speed: a phone reads all the weights once per token, so speed is
    /// memory bandwidth divided by model size. About 0.75 words per token.
    static func wordsPerSecond(for entry: ModelEntry, facts: ModelFacts?) -> Double {
        let gb = max(0.3, facts?.gb ?? entry.approxGB)
        let bandwidth = ramGB >= 7 ? 45.0 : 32.0   // effective GB/s on recent iPhones
        return bandwidth / gb * 0.75
    }

    /// - Parameter otherLoadedGB: memory held by models that stay loaded alongside this one
    ///   (the narrator voice while the storyteller runs, and the other way round).
    /// - Parameter alreadyLoadedGB: memory this app's models hold right now, which counts toward the budget.
    static func report(for entry: ModelEntry, facts: ModelFacts?, otherLoadedGB: Double = 0, alreadyLoadedGB: Double = 0) -> Report {
        let need = need(for: entry, facts: facts)
        let budget = availableGB + alreadyLoadedGB
        let total = need + otherLoadedGB
        let ratio = total / max(budget, 0.1)
        let verdict: Verdict = ratio < 0.7 ? .comfortable : ratio < 0.92 ? .tight : .tooBig
        let wps = wordsPerSecond(for: entry, facts: facts)
        var detail = String(format: "Needs about %.1f GB", need)
        if otherLoadedGB > 0.05 { detail += String(format: " (plus %.1f GB for the other model)", otherLoadedGB) }
        detail += String(format: "; this \(deviceWord) lets the app use about %.1f GB.", budget)
        if entry.kind == .language {
            detail += String(format: " Expect roughly %.0f words a second", wps)
            detail += wps >= 4 ? ", fast enough to narrate as it writes." : ", slower than speech, so replies will pause."
        }
        switch verdict {
        case .comfortable: break
        case .tight: detail += " It may slow down or be closed by iOS when other apps are busy."
        case .tooBig: detail += " iOS will most likely close the app while loading it."
        }
        return Report(verdict: verdict, needGB: need, budgetGB: budget, wordsPerSecond: wps, detail: detail)
    }

    private static let knownDevices: [String: String] = [
        "iPhone13,1": "iPhone 12 mini", "iPhone13,2": "iPhone 12", "iPhone13,3": "iPhone 12 Pro", "iPhone13,4": "iPhone 12 Pro Max",
        "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13", "iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max",
        "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus", "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max",
        "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus", "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max",
        "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus", "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max",
        "iPhone17,5": "iPhone 16e", "iPhone18,3": "iPhone 17", "iPhone18,1": "iPhone 17 Pro", "iPhone18,2": "iPhone 17 Pro Max",
        "iPhone18,4": "iPhone Air",
        "iPad13,16": "iPad Air (M1)", "iPad13,17": "iPad Air (M1)",
        "iPad13,4": "iPad Pro 11\" (M1)", "iPad13,5": "iPad Pro 11\" (M1)", "iPad13,6": "iPad Pro 11\" (M1)", "iPad13,7": "iPad Pro 11\" (M1)",
        "iPad13,8": "iPad Pro 12.9\" (M1)", "iPad13,9": "iPad Pro 12.9\" (M1)", "iPad13,10": "iPad Pro 12.9\" (M1)", "iPad13,11": "iPad Pro 12.9\" (M1)",
        "iPad14,3": "iPad Pro 11\" (M2)", "iPad14,4": "iPad Pro 11\" (M2)", "iPad14,5": "iPad Pro 12.9\" (M2)", "iPad14,6": "iPad Pro 12.9\" (M2)",
        "iPad14,8": "iPad Air 11\" (M2)", "iPad14,9": "iPad Air 11\" (M2)", "iPad14,10": "iPad Air 13\" (M2)", "iPad14,11": "iPad Air 13\" (M2)",
        "iPad15,3": "iPad Air 11\" (M3)", "iPad15,4": "iPad Air 11\" (M3)", "iPad15,5": "iPad Air 13\" (M3)", "iPad15,6": "iPad Air 13\" (M3)",
        "iPad15,7": "iPad (A16)", "iPad15,8": "iPad (A16)",
        "iPad16,1": "iPad mini (A17 Pro)", "iPad16,2": "iPad mini (A17 Pro)",
        "iPad16,3": "iPad Pro 11\" (M4)", "iPad16,4": "iPad Pro 11\" (M4)", "iPad16,5": "iPad Pro 13\" (M4)", "iPad16,6": "iPad Pro 13\" (M4)",
        "arm64": "Simulator", "x86_64": "Simulator",
    ]
}
