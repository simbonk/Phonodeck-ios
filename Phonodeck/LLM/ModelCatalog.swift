import Foundation
import MLXLLM
import MLXLMCommon

/// A model the app can download from Hugging Face: a language model (the storyteller),
/// a voice model (the narrator) or a speech recognition model (listening to the player).
struct ModelEntry: Identifiable, Hashable, Codable {
    enum Kind: String, Codable { case language, voice, listening }
    enum Tier: String, Codable { case fast, medium, best }

    let id: String              // Hugging Face repo id, e.g. "mlx-community/Qwen3-4B-4bit"
    var name: String
    var blurb: String
    var kind: Kind
    /// Approximate download size in GB, used until the real size is fetched from Hugging Face.
    var approxGB: Double
    /// Approximate parameter count in billions (for the speed estimate when nothing else is known).
    var paramsB: Double
    var tier: Tier? = nil
    var custom = false
    /// Default voice name for voice models (e.g. "af_heart" for Kokoro).
    var defaultVoice: String? = nil
    var voices: [String] = []

    var url: URL { URL(string: "https://huggingface.co/\(id)")! }

    /// The configuration MLX uses to load a language model. Known models carry their own
    /// end-of-turn tokens; models added from a link rely on their tokenizer's settings.
    var configuration: ModelConfiguration {
        var c = LLMRegistry.shared.configuration(id: id)
        // Qwen chat models end their turn with <|im_end|>; MLX's registry only lists some of them.
        if c.extraEOSTokens.isEmpty, id.lowercased().contains("qwen") { c.extraEOSTokens = ["<|im_end|>"] }
        return c
    }
}

enum ModelCatalog {
    /// Sizes are the Hugging Face download. Gemma 4 and Qwen3.5 also download image and sound
    /// encoders the storyteller never loads; the fit check measures and leaves those out.
    static let language: [ModelEntry] = [
        ModelEntry(
            id: "mlx-community/Llama-3.2-3B-Instruct-4bit", name: "Llama 3.2 3B",
            blurb: "Small and quick. The pick for phones with 6 GB of memory.",
            kind: .language, approxGB: 1.8, paramsB: 3.2),
        ModelEntry(
            id: "mlx-community/Qwen3.5-4B-MLX-4bit", name: "Qwen3.5 4B",
            blurb: "Recommended. The newer Qwen: follows the story and your choices far better than Qwen3, and stays quick on an 8 GB iPhone or iPad.",
            kind: .language, approxGB: 2.9, paramsB: 4.0),
        ModelEntry(
            id: "mlx-community/gemma-4-e2b-it-4bit", name: "Gemma 4 E2B",
            blurb: "Google's smallest Gemma 4. Warm, natural prose and very light on memory; a little less clever with plots.",
            kind: .language, approxGB: 3.6, paramsB: 2.3),
        ModelEntry(
            id: "mlx-community/gemma-4-e4b-it-4bit", name: "Gemma 4 E4B",
            blurb: "Google's small open model. Warm, natural prose; try it if Qwen feels flat. Wants about 5 GB free.",
            kind: .language, approxGB: 5.1, paramsB: 4.0),
        ModelEntry(
            id: "mlx-community/Qwen3.5-9B-MLX-4bit", name: "Qwen3.5 9B",
            blurb: "The best storyteller that fits on a phone: richer, more consistent stories. Wants 12 GB (iPhone 17 Pro, or an iPad Pro with 16 GB).",
            kind: .language, approxGB: 5.9, paramsB: 9.0),
        ModelEntry(
            id: "mlx-community/Qwen3-4B-4bit", name: "Qwen3 4B",
            blurb: "The older Qwen. Quick, but its stories wander; Qwen3.5 4B replaces it.",
            kind: .language, approxGB: 2.3, paramsB: 4.0),
        ModelEntry(
            id: "mlx-community/Qwen3-8B-4bit", name: "Qwen3 8B",
            blurb: "The older, larger Qwen. Qwen3.5 9B writes better at about the same size.",
            kind: .language, approxGB: 4.6, paramsB: 8.2),
    ]

    static let voice: [ModelEntry] = [
        ModelEntry(
            id: "mlx-community/Kokoro-82M-bf16", name: "Kokoro",
            blurb: "Medium: a natural, pleasant narrator that keeps up with the story. Small download.",
            kind: .voice, approxGB: 0.35, paramsB: 0.08, tier: .medium, defaultVoice: "af_heart",
            voices: ["af_heart", "af_bella", "af_nicole", "af_sarah", "am_michael", "am_adam", "am_fenrir",
                     "bf_emma", "bf_isabella", "bm_george", "bm_fable", "bm_lewis"]),
        ModelEntry(
            id: "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-bf16", name: "Qwen3-TTS",
            blurb: "Good and slow: the most expressive narrator, with emotion in the voice. Starts later and uses more memory.",
            kind: .voice, approxGB: 1.9, paramsB: 0.6, tier: .best, defaultVoice: "Ryan",
            voices: ["Ryan", "Aiden"]),
    ]

    /// Offline speech recognition. Apple's on-device dictation is the built-in quick option.
    static let listening: [ModelEntry] = [
        ModelEntry(
            id: "mlx-community/parakeet-tdt_ctc-110m", name: "Parakeet Small",
            blurb: "Light: a small offline speech model, quick even on older phones.",
            kind: .listening, approxGB: 0.45, paramsB: 0.11, tier: .medium),
        ModelEntry(
            id: "mlx-community/parakeet-tdt-0.6b-v3", name: "Parakeet",
            blurb: "Better and still fast: NVIDIA's open model, more accurate with names and quiet voices.",
            kind: .listening, approxGB: 2.5, paramsB: 0.6, tier: .best),
    ]

    static let recommendedLanguageID = "mlx-community/Qwen3.5-4B-MLX-4bit"

    /// The welcome offers the first of these that runs comfortably on the device.
    static let storytellerPreference = [
        "mlx-community/Qwen3.5-9B-MLX-4bit", "mlx-community/Qwen3.5-4B-MLX-4bit",
        "mlx-community/gemma-4-e2b-it-4bit", "mlx-community/Llama-3.2-3B-Instruct-4bit",
    ]

    static var custom: [ModelEntry] {
        get {
            guard let d = UserDefaults.standard.data(forKey: "customModels"),
                  let list = try? JSONDecoder().decode([ModelEntry].self, from: d) else { return [] }
            return list
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "customModels") }
    }

    static var all: [ModelEntry] { language + voice + listening + custom }

    static func entry(_ id: String?) -> ModelEntry? { all.first { $0.id == id } }

    /// Accepts "https://huggingface.co/org/name", "huggingface.co/org/name/tree/main" or "org/name".
    static func repoID(from text: String) -> String? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = s.range(of: "huggingface.co/") { s = String(s[r.upperBound...]) }
        let parts = s.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        guard parts.count >= 2 else { return nil }
        let ok = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard parts[0].unicodeScalars.allSatisfy(ok.contains), parts[1].unicodeScalars.allSatisfy(ok.contains) else { return nil }
        return parts[0] + "/" + parts[1]
    }
}
