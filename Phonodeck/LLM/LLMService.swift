import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Observation
import Tokenizers

/// One message in a conversation with the model.
struct ChatTurn: Codable, Hashable {
    enum Role: String, Codable { case user, assistant }
    var role: Role
    var text: String
}

enum LLMError: LocalizedError {
    case noModel, notDownloaded
    case tooBig(String)
    /// The app left the foreground mid-reply, so the GPU work stopped (iOS forbids it there).
    case interrupted

    var errorDescription: String? {
        switch self {
        case .noModel: "No storyteller model is selected yet. Open the Models tab and download one."
        case .notDownloaded: "The selected model is not on this phone. Open the Models tab and download it again."
        case .tooBig(let why): "\(why) Pick a smaller storyteller in the Models tab."
        case .interrupted: "Paused while Phonodeck was in the background."
        }
    }
}

/// Loads and runs the on-device language model on the phone's GPU: MLX for MLX models,
/// llama.cpp (LlamaEngine) for GGUF ones.
///
/// Everything else in the app goes through `stream` (text as it is written) and `complete`
/// (the whole reply), so the inference engine could be swapped later.
@Observable
@MainActor
final class LLMService {
    enum Phase: Equatable { case idle, loading, failed(String) }

    var phase: Phase = .idle
    private(set) var loadedID: String?
    private(set) var busy = false
    var lastTokensPerSecond: Double = 0
    /// Characters of hidden reasoning written so far in the current call (for "thinking" progress).
    private(set) var thoughtChars = 0

    private let store: ModelStore
    private var container: ModelContainer?
    private var llama: LlamaEngine?
    private var loadTask: Task<ModelContainer, Error>?
    private let tokenizerLoader: any TokenizerLoader = #huggingFaceTokenizerLoader()

    init(store: ModelStore) { self.store = store }

    /// Whether the storyteller can reason before it answers (Qwen's thinking mode through MLX).
    /// GGUF models run through llama.cpp, where Phonodeck always turns thinking off.
    var canReason: Bool { !(store.language?.isGGUF ?? false) }

    /// Memory the loaded model holds, for the fit checks.
    var loadedGB: Double { loadedID == nil ? 0 : store.neededGB(loadedID) }

    /// Loads the storyteller now (the Load and Restart buttons), waiting its turn for the GPU.
    func preload() async {
        try? await load()
    }

    /// Loads the storyteller, waiting its turn for the GPU.
    func load() async throws {
        await MLXGate.shared.acquire()
        do {
            if let e = store.language, e.isGGUF { _ = try await ensureLlama(e) } else { _ = try await ensureLoaded() }
            await MLXGate.shared.release()
        } catch {
            await MLXGate.shared.release()
            throw error
        }
    }

    /// UTF-8 bytes per token, for estimating prompt sizes. 3.5 is a cautious guess that overcounts
    /// English prose by about a fifth; a GGUF model replaces it with its own tokenizer's measure
    /// (less 6% for safety) when it loads. The hard limit is still enforced with real token counts
    /// in `llamaPromptWithinBudget` and `prepareWithinBudget`.
    nonisolated(unsafe) static var bytesPerToken = 3.5

    func unload() {
        Self.bytesPerToken = 3.5
        loadTask?.cancel()
        loadTask = nil
        container = nil
        llama = nil
        loadedID = nil
        MLX.Memory.clearCache()
    }

    /// Loads a GGUF storyteller into llama.cpp.
    private func ensureLlama(_ entry: ModelEntry) async throws -> LlamaEngine {
        if let l = llama, loadedID == entry.id { return l }
        guard let path = ModelStore.ggufPath(entry) else { throw LLMError.notDownloaded }
        let fit = store.report(for: entry)
        if fit.verdict == .tooBig { throw LLMError.tooBig(fit.detail) }

        unload()
        phase = .loading
        do {
            let engine = try await Task.detached(priority: .userInitiated) {
                try LlamaEngine(path: path.path, contextTokens: DeviceFit.contextTokens)
            }.value
            llama = engine
            loadedID = entry.id
            // Measure how this model's tokenizer really counts story text, so prompts are packed
            // to the true size of the context instead of a cautious guess (see `bytesPerToken`).
            let sample = Prompts.gmRules + "\n" + Prompts.review
            let count = engine.tokenize(sample).count
            if count > 50 {
                Self.bytesPerToken = max(3.2, min(5.0, Double(sample.utf8.count) / Double(count) * 0.94))
            }
            phase = .idle
            return engine
        } catch {
            phase = .failed("Could not load \(entry.name): \(error.localizedDescription)")
            throw error
        }
    }

    func ensureLoaded() async throws -> ModelContainer {
        guard let entry = store.language else { throw LLMError.noModel }
        if let c = container, loadedID == entry.id { return c }
        if let t = loadTask { return try await t.value }
        guard let dir = ModelStore.snapshotDirectory(entry.id) else { throw LLMError.notDownloaded }
        // Loading a model over the app's memory limit closes the app instantly, so refuse it.
        let fit = store.report(for: entry)
        if fit.verdict == .tooBig { throw LLMError.tooBig(fit.detail) }

        unload()
        phase = .loading
        MLX.Memory.cacheLimit = 32 * 1024 * 1024
        let known = entry.configuration
        let config = ModelConfiguration(directory: dir, extraEOSTokens: known.extraEOSTokens)
        let downloader = store.downloader, tokenizerLoader = self.tokenizerLoader
        let task = Task {
            try await LLMModelFactory.shared.loadContainer(
                from: downloader, using: tokenizerLoader, configuration: config)
        }
        loadTask = task
        do {
            let c = try await task.value
            container = c
            loadedID = entry.id
            loadTask = nil
            phase = .idle
            return c
        } catch {
            loadTask = nil
            phase = .failed("Could not load \(entry.name): \(error.localizedDescription)")
            throw error
        }
    }

    struct Options {
        var maxTokens = 600
        var temperature: Float = 0.8
        var topP: Float = 0.95
        var repetitionPenalty: Float? = 1.08
        /// Let the model reason privately before it answers (Qwen's thinking mode). The reasoning
        /// counts toward maxTokens and is removed from the output. Models without a thinking mode
        /// give back nothing here, so callers fall back to a call without it.
        var thinking = false
        /// Collects the hidden reasoning, for the story export.
        var thoughts: ThoughtSink? = nil
        /// A GBNF grammar the reply must follow (see `JSONGrammar`). Only llama.cpp (GGUF models)
        /// can enforce one; MLX models ignore it and their output is checked afterwards.
        var grammar: String? = nil
    }

    /// Streams the reply a few characters at a time. Hidden <think> reasoning is removed.
    func stream(system: String?, history: [ChatTurn], options: Options = .init()) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                self.busy = true
                defer { self.busy = false }
                await MLXGate.shared.acquire()
                do {
                    defer { Task { await MLXGate.shared.release() } }
                    if let entry = self.store.language, entry.isGGUF {
                        try await self.streamLlama(entry, system: system, history: history, options: options, into: continuation)
                        continuation.finish()
                        return
                    }
                    let container = try await self.ensureLoaded()
                    let prepared = try await Self.prepareWithinBudget(container, system: system, history: history, maxTokens: options.maxTokens,
                                                                      thinking: options.thinking)
                    let params = GenerateParameters(
                        maxTokens: options.maxTokens, temperature: options.temperature, topP: options.topP,
                        repetitionPenalty: options.repetitionPenalty, repetitionContextSize: 64)
                    if AppActivity.shared.inBackground { throw LLMError.interrupted }
                    let events = try await container.generate(input: prepared, parameters: params)
                    // In thinking mode the template may already have opened the <think> block, so start inside it.
                    var filter = ThinkFilter(startInside: options.thinking)
                    self.thoughtChars = 0
                    var interrupted = false
                    for await event in events {
                        if Task.isCancelled { break }
                        // Stop between tokens the moment the app leaves the foreground.
                        if AppActivity.shared.inBackground { interrupted = true; break }
                        switch event {
                        case .chunk(let text):
                            if filter.inside { self.thoughtChars += text.count; options.thoughts?.add(text) }
                            let out = filter.feed(text)
                            if !out.isEmpty { continuation.yield(out) }
                        case .info(let info):
                            self.lastTokensPerSecond = info.tokensPerSecond
                        default:
                            break
                        }
                    }
                    if interrupted { throw LLMError.interrupted }
                    let rest = filter.flush()
                    if !rest.isEmpty { continuation.yield(rest) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The same reply through llama.cpp, for GGUF storytellers.
    private func streamLlama(_ entry: ModelEntry, system: String?, history: [ChatTurn], options: Options,
                             into continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        let engine = try await ensureLlama(entry)
        let prompt = Self.llamaPromptWithinBudget(engine, system: system, history: history, maxTokens: options.maxTokens)
        let flag = CancelFlag()
        let speed = try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                var filter = ThinkFilter()
                let speed = try engine.generate(
                    prompt: prompt, maxTokens: options.maxTokens, temperature: options.temperature,
                    topP: options.topP, repetitionPenalty: options.repetitionPenalty, grammar: options.grammar
                ) { text in
                    let out = filter.feed(text)
                    if !out.isEmpty { continuation.yield(out) }
                    return !flag.isSet
                }
                let rest = filter.flush()
                if !rest.isEmpty { continuation.yield(rest) }
                return speed
            }.value
        } onCancel: {
            flag.set()
        }
        lastTokensPerSecond = speed
    }

    /// llama.cpp's version of `prepareWithinBudget`: drops the oldest turns, then squeezes one long
    /// message, until the prompt and the longest reply fit the 4K conversation memory.
    private static func llamaPromptWithinBudget(_ engine: LlamaEngine, system: String?, history: [ChatTurn], maxTokens: Int) -> [Int32] {
        let limit = max(512, contextBudget - maxTokens - 32)
        var system = system
        var turns = history
        var tokens = engine.tokenize(engine.format(system: system, turns: turns))
        var squeezes = 0
        while tokens.count > limit {
            let over = tokens.count
            if turns.count > 1 {
                turns.removeFirst()
                while turns.count > 1, turns.first?.role == .assistant { turns.removeFirst() }
            } else if squeezes < 4 {
                squeezes += 1
                let keep = Double(limit) / Double(over) * 0.9
                if let s = system, s.count > (turns.first?.text.count ?? 0) {
                    system = squeezeMiddle(s, keep: keep)
                } else if !turns.isEmpty {
                    turns[0].text = squeezeMiddle(turns[0].text, keep: keep)
                }
            } else {
                break
            }
            tokens = engine.tokenize(engine.format(system: system, turns: turns))
        }
        return tokens
    }

    /// The memory for a conversation grows with every token in it, and DeviceFit only promised
    /// that `DeviceFit.contextTokens` would fit beside the model. So the prompt plus the longest
    /// reply never goes over that: the oldest turns are dropped first, and if one message alone is
    /// too long its middle is cut. This is what keeps extra calls (memory, showrunner notes, the
    /// bible refresh) from ever raising peak memory above a normal turn.
    static let contextBudget = DeviceFit.contextTokens

    private static func prepareWithinBudget(_ container: ModelContainer, system: String?, history: [ChatTurn], maxTokens: Int,
                                            thinking: Bool = false) async throws -> LMInput {
        let limit = max(512, contextBudget - maxTokens - 32)
        var system = system
        var turns = history
        func input() -> UserInput {
            var chat: [Chat.Message] = []
            if let system, !system.isEmpty { chat.append(.system(system)) }
            for t in turns { chat.append(t.role == .user ? .user(t.text) : .assistant(t.text)) }
            return UserInput(chat: chat, additionalContext: ["enable_thinking": thinking])
        }
        var prepared = try await container.prepare(input: input())
        var squeezes = 0
        while prepared.text.tokens.size > limit {
            let over = prepared.text.tokens.size
            if turns.count > 1 {
                // Drop the oldest turn, and keep the conversation starting with the player.
                turns.removeFirst()
                while turns.count > 1, turns.first?.role == .assistant { turns.removeFirst() }
            } else if squeezes < 4 {
                // One long message (or a long system prompt): keep its start and end, cut the middle.
                squeezes += 1
                let keep = Double(limit) / Double(over) * 0.9
                if let s = system, s.count > (turns.first?.text.count ?? 0) {
                    system = squeezeMiddle(s, keep: keep)
                } else if !turns.isEmpty {
                    turns[0].text = squeezeMiddle(turns[0].text, keep: keep)
                }
            } else {
                break
            }
            prepared = try await container.prepare(input: input())
        }
        return prepared
    }

    static func squeezeMiddle(_ s: String, keep: Double) -> String {
        let n = Int(Double(s.count) * min(1, max(0.1, keep)))
        guard n < s.count else { return s }
        return String(s.prefix(n * 2 / 3)) + "\n…\n" + String(s.suffix(n / 3))
    }

    /// The whole reply as one string.
    func complete(system: String?, prompt: String, options: Options = .init()) async throws -> String {
        var out = ""
        for try await piece in stream(system: system, history: [ChatTurn(role: .user, text: prompt)], options: options) {
            out += piece
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The model's hidden reasoning from one call, kept for the story export.
final class ThoughtSink: @unchecked Sendable {
    private(set) var text = ""
    func add(_ s: String) { if text.count < 12000 { text += s } }
    /// The reasoning without its tags.
    var clean: String {
        text.replacingOccurrences(of: "<think>", with: "").replacingOccurrences(of: "</think>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Removes <think>…</think> reasoning from a token stream, even when a tag is split across chunks.
struct ThinkFilter {
    private var buffer = ""
    private var thinking = false

    init(startInside: Bool = false) { thinking = startInside }

    /// True while the stream is inside a reasoning block.
    var inside: Bool { thinking }

    mutating func feed(_ text: String) -> String {
        buffer += text
        var out = ""
        while true {
            if thinking {
                // A model that opens the block itself, after the template already did.
                if let open = buffer.range(of: "<think>") { buffer.removeSubrange(open) }
                guard let end = buffer.range(of: "</think>") else {
                    buffer = String(buffer.suffix(8))
                    return out
                }
                buffer = String(buffer[end.upperBound...])
                thinking = false
            } else if let start = buffer.range(of: "<think>") {
                out += buffer[..<start.lowerBound]
                buffer = String(buffer[start.upperBound...])
                thinking = true
            } else {
                if let lt = buffer.lastIndex(of: "<"), "<think>".hasPrefix(buffer[lt...]) {
                    out += buffer[..<lt]
                    buffer = String(buffer[lt...])
                } else {
                    out += buffer
                    buffer = ""
                }
                return out
            }
        }
    }

    mutating func flush() -> String {
        defer { buffer = "" }
        return thinking ? "" : buffer
    }
}

/// Pulls the first JSON object out of a model reply (models often wrap it in prose or code fences).
enum JSONExtract {
    static func object(_ text: String) -> [String: Any]? {
        var s = text
        if let r = s.range(of: "```json") { s = String(s[r.upperBound...]) } else if let r = s.range(of: "```") { s = String(s[r.upperBound...]) }
        guard let start = s.firstIndex(of: "{") else { return nil }
        var depth = 0, inString = false, escaped = false
        var end: String.Index?
        for i in s[start...].indices {
            let c = s[i]
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                continue
            }
            if c == "\"" { inString = true } else if c == "{" { depth += 1 } else if c == "}" {
                depth -= 1
                if depth == 0 { end = i; break }
            }
        }
        var candidate = end.map { String(s[start...$0]) } ?? String(s[start...]) + String(repeating: "}", count: max(depth, 0))
        // Small models often leave trailing commas.
        candidate = candidate.replacingOccurrences(of: ",\\s*([}\\]])", with: "$1", options: .regularExpression)
        guard let data = candidate.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func decode<T: Decodable>(_ type: T.Type, from text: String) -> T? {
        guard let obj = object(text), let data = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
