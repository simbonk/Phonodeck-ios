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
    /// The repo only has GGUF files (llama.cpp's format), which MLX can't load.
    var ggufOnly: Bool? = nil
    /// Bytes of vision and audio weights that a text-only storyteller downloads but never loads
    /// (Gemma 4 and Qwen3.5 ship with image and sound encoders in the same files).
    var unusedBytes: Int64? = nil
    /// How many layers' worth of conversation memory the model keeps, when it isn't simply `layers`.
    var kvLayers: Double? = nil
    /// The repo asks people to sign in and accept its terms before downloading (a "gated" model).
    var gated: Bool? = nil

    /// Download size.
    var gb: Double { Double(bytes) / 1_000_000_000 }
    /// What the model occupies in memory once loaded.
    var loadedGB: Double { Double(bytes - (unusedBytes ?? 0)) / 1_000_000_000 }
}

enum HFHub {
    static let browseLanguageURL = URL(string: "https://huggingface.co/models?library=mlx&pipeline_tag=text-generation&sort=trending")!
    static let browseVoiceURL = URL(string: "https://huggingface.co/models?library=mlx&pipeline_tag=text-to-speech&sort=trending")!

    /// Bumped when ModelFacts learns something new, so older cached facts are fetched again.
    private static let cacheKey = "modelFacts.v3"

    /// Weight names a text-only model skips when it loads (mirrors MLX's Gemma 4 and Qwen3.5 loaders).
    static let unusedPrefixes = ["vision_tower", "multi_modal_projector", "audio_tower", "embed_audio",
                                 "embed_vision", "vision_embedder", "visual"]

    /// A request to Hugging Face, signed with the person's token when they've added one.
    static func request(_ url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        if let t = HFToken.value { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        return req
    }

    static func get(_ url: URL) async throws -> (Data, HTTPURLResponse?) {
        let (data, resp) = try await URLSession.shared.data(for: request(url))
        return (data, resp as? HTTPURLResponse)
    }

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
        struct Info: Decodable {
            let siblings: [Sibling]?; let tags: [String]?; let library_name: String?
            /// false, or "auto"/"manual" when the repo is gated.
            let gated: Bool?
            enum CodingKeys: String, CodingKey { case siblings, tags, library_name, gated }
            init(from d: Decoder) throws {
                let c = try d.container(keyedBy: CodingKeys.self)
                siblings = try? c.decode([Sibling].self, forKey: .siblings)
                tags = try? c.decode([String].self, forKey: .tags)
                library_name = try? c.decode(String.self, forKey: .library_name)
                if let b = try? c.decode(Bool.self, forKey: .gated) { gated = b }
                else if (try? c.decode(String.self, forKey: .gated)) != nil { gated = true }
                else { gated = nil }
            }
        }
        let infoURL = URL(string: "https://huggingface.co/api/models/\(id)?blobs=true")!
        let (data, resp) = try await get(infoURL)
        switch resp?.statusCode ?? 0 {
        case 200: break
        case 401, 403:
            throw NSError(domain: "Phonodeck", code: 401, userInfo: [NSLocalizedDescriptionKey: HFToken.value == nil
                ? "\(id) is private or gated. Add a Hugging Face token (Models tab, at the bottom) and try again."
                : "Hugging Face won't show \(id) to your token. If it's gated, open its page and accept its terms first."])
        default:
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
        facts.ggufOnly = !facts.hasSafetensors && files.contains { $0.rfilename.lowercased().hasSuffix(".gguf") }
        facts.gated = info.gated

        if let pair = try? await get(URL(string: "https://huggingface.co/\(id)/resolve/main/config.json")!),
           pair.1?.statusCode == 200,
           let top = try? JSONSerialization.jsonObject(with: pair.0) as? [String: Any] {
            var cfg = top
            if let text = cfg["text_config"] as? [String: Any] { cfg.merge(text) { _, new in new } }
            facts.modelType = cfg["model_type"] as? String
            // MLX conversions record how they were quantized ("bits" and "group_size"), even when
            // the uploader forgot to tag the repo as MLX.
            if let q = top["quantization"] as? [String: Any], q["group_size"] != nil, q["bits"] != nil {
                facts.looksMLX = true
            }
            facts.layers = cfg["num_hidden_layers"] as? Int
            let heads = cfg["num_attention_heads"] as? Int
            facts.kvHeads = (cfg["num_key_value_heads"] as? Int) ?? heads
            if let hd = cfg["head_dim"] as? Int { facts.headDim = hd }
            else if let hidden = cfg["hidden_size"] as? Int, let heads, heads > 0 { facts.headDim = hidden / heads }

            // Layers that keep a growing memory of the conversation. Sliding-window layers only
            // remember their window, layers that share another layer's cache keep none, and
            // linear-attention layers (Qwen3.5) keep a small fixed state.
            if let types = cfg["layer_types"] as? [String], !types.isEmpty {
                let shared = cfg["num_kv_shared_layers"] as? Int ?? 0
                let own = types.prefix(max(0, types.count - shared))
                let window = Double(cfg["sliding_window"] as? Int ?? DeviceFit.contextTokens)
                let slidingShare = min(1, window / Double(DeviceFit.contextTokens))
                var kvLayers = 0.0
                for t in own {
                    if t == "full_attention" { kvLayers += 1 } else if t == "sliding_attention" { kvLayers += slidingShare }
                }
                facts.kvLayers = kvLayers
            }

            // Multimodal checkpoints: measure the vision and audio weights the storyteller never loads.
            if top["vision_config"] != nil || top["audio_config"] != nil {
                var unused: Int64 = 0
                for f in files where f.rfilename.hasSuffix(".safetensors") {
                    if let n = try? await unusedBytes(id, file: f.rfilename) { unused += n }
                }
                if unused > 0, unused < facts.bytes { facts.unusedBytes = unused }
            }
        }
        store(id, facts)
        return facts
    }

    /// Reads just the header of a .safetensors file (two small range requests) and adds up the
    /// tensors a text-only model skips.
    static func unusedBytes(_ id: String, file: String) async throws -> Int64 {
        let path = file.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file
        let url = URL(string: "https://huggingface.co/\(id)/resolve/main/\(path)")!
        func range(_ from: Int, _ to: Int) async throws -> Data {
            var req = request(url)
            req.setValue("bytes=\(from)-\(to)", forHTTPHeaderField: "Range")
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 206, data.count == to - from + 1 else {
                throw URLError(.badServerResponse)
            }
            return data
        }
        let lenData = try await range(0, 7)
        var len: UInt64 = 0
        for (i, byte) in lenData.enumerated() { len |= UInt64(byte) << (8 * UInt64(i)) }
        guard len > 0, len < 50_000_000 else { return 0 }
        let header = try await range(8, 8 + Int(len) - 1)
        guard let json = try JSONSerialization.jsonObject(with: header) as? [String: Any] else { return 0 }
        var total: Int64 = 0
        for (name, value) in json where name != "__metadata__" {
            var key = name
            if key.hasPrefix("model.") { key.removeFirst("model.".count) }
            guard unusedPrefixes.contains(where: { key.hasPrefix($0) }),
                  let t = value as? [String: Any], let offs = t["data_offsets"] as? [NSNumber], offs.count == 2 else { continue }
            total += offs[1].int64Value - offs[0].int64Value
        }
        return total
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

    /// Memory this app is using right now (what iOS counts against its limit).
    /// In decimal GB, like the model sizes, so the two compare directly.
    static var footprintGB: Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return r == KERN_SUCCESS ? Double(info.phys_footprint) / 1_000_000_000 : 0
    }

    /// Room the app has for models: its whole memory limit (what it uses now plus what it may
    /// still take) less about 0.6 GB for the app itself, sound and the screen. Using the whole
    /// limit means a voice sample that just played doesn't make a model look too big.
    ///
    /// iOS caps each app far below the phone's RAM: about 6 GB on a 12 GB iPhone 17 Pro Max,
    /// whatever the entitlements. Going over it closes the app without warning, so the checks
    /// below leave a wide margin.
    static var modelBudgetGB: Double {
        let b = os_proc_available_memory()
        let limit = b > 0 ? Double(b) / 1_000_000_000 + footprintGB : min(ramGB * 0.5, 6)
        return max(0.5, limit - 0.6)
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
        let weights = facts?.loadedGB ?? entry.approxGB
        guard entry.kind == .language else { return weights * 1.25 + 0.25 }
        var kv = 0.45
        if let f = facts, let l = f.layers, let h = f.kvHeads, let d = f.headDim {
            let layers = f.kvLayers ?? Double(l)
            kv = layers * Double(2 * h * d * 2 * contextTokens) / 1_000_000_000
        }
        // Loading briefly needs more than the weights (MLX evaluates them in chunks, and the
        // tokenizer and prompt cache sit beside them), hence the 10% and 0.6 GB of working room.
        return weights * 1.1 + kv + 0.6
    }

    /// Rough generation speed: a phone reads all the weights once per token, so speed is
    /// memory bandwidth divided by model size. About 0.75 words per token.
    static func wordsPerSecond(for entry: ModelEntry, facts: ModelFacts?) -> Double {
        let gb = max(0.3, facts?.loadedGB ?? entry.approxGB)
        let bandwidth = ramGB >= 7 ? 45.0 : 32.0   // effective GB/s on recent iPhones
        return bandwidth / gb * 0.75
    }

    /// - Parameter otherLoadedGB: memory held by models that stay loaded alongside this one
    ///   (the narrator voice while the storyteller runs, and the other way round).
    static func report(for entry: ModelEntry, facts: ModelFacts?, otherLoadedGB: Double = 0) -> Report {
        let need = need(for: entry, facts: facts)
        let budget = modelBudgetGB
        let total = need + otherLoadedGB
        let ratio = total / max(budget, 0.1)
        let verdict: Verdict = ratio < 0.75 ? .comfortable : ratio < 0.9 ? .tight : .tooBig
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

/// An optional Hugging Face access token, kept in the Keychain. Only gated or private models
/// need one; everything else downloads without signing in.
enum HFToken {
    private static let key = "huggingFaceToken"
    static var value: String? {
        get { Keychain.read(key).flatMap { $0.isEmpty ? nil : $0 } }
        set {
            let t = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if t.isEmpty { Keychain.delete(key) } else { Keychain.write(key, t) }
        }
    }
}
