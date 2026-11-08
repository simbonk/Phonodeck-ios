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

    var errorDescription: String? {
        switch self {
        case .noModel: "No storyteller model is selected yet. Open the Models tab and download one."
        case .notDownloaded: "The selected model is not on this phone. Open the Models tab and download it again."
        }
    }
}

/// Loads and runs the on-device language model (MLX on the phone's GPU).
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

    private let store: ModelStore
    private var container: ModelContainer?
    private var loadTask: Task<ModelContainer, Error>?
    private let tokenizerLoader: any TokenizerLoader = #huggingFaceTokenizerLoader()

    init(store: ModelStore) { self.store = store }

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
            _ = try await ensureLoaded()
            await MLXGate.shared.release()
        } catch {
            await MLXGate.shared.release()
            throw error
        }
    }

    func unload() {
        loadTask?.cancel()
        loadTask = nil
        container = nil
        loadedID = nil
        MLX.Memory.clearCache()
    }

    func ensureLoaded() async throws -> ModelContainer {
        guard let entry = store.language else { throw LLMError.noModel }
        if let c = container, loadedID == entry.id { return c }
        if let t = loadTask { return try await t.value }
        guard let dir = ModelStore.snapshotDirectory(entry.id) else { throw LLMError.notDownloaded }

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
                    let container = try await self.ensureLoaded()
                    let prepared = try await Self.prepareWithinBudget(container, system: system, history: history, maxTokens: options.maxTokens)
                    let params = GenerateParameters(
                        maxTokens: options.maxTokens, temperature: options.temperature, topP: options.topP,
                        repetitionPenalty: options.repetitionPenalty, repetitionContextSize: 64)
                    let events = try await container.generate(input: prepared, parameters: params)
                    var filter = ThinkFilter()
                    for await event in events {
                        if Task.isCancelled { break }
                        switch event {
                        case .chunk(let text):
                            let out = filter.feed(text)
                            if !out.isEmpty { continuation.yield(out) }
                        case .info(let info):
                            self.lastTokensPerSecond = info.tokensPerSecond
                        default:
                            break
                        }
                    }
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

    /// The memory for a conversation grows with every token in it, and DeviceFit only promised
    /// that `DeviceFit.contextTokens` would fit beside the model. So the prompt plus the longest
    /// reply never goes over that: the oldest turns are dropped first, and if one message alone is
    /// too long its middle is cut. This is what keeps extra calls (memory, showrunner notes, the
    /// bible refresh) from ever raising peak memory above a normal turn.
    static let contextBudget = DeviceFit.contextTokens

    private static func prepareWithinBudget(_ container: ModelContainer, system: String?, history: [ChatTurn], maxTokens: Int) async throws -> LMInput {
        let limit = max(512, contextBudget - maxTokens - 32)
        var system = system
        var turns = history
        func input() -> UserInput {
            var chat: [Chat.Message] = []
            if let system, !system.isEmpty { chat.append(.system(system)) }
            for t in turns { chat.append(t.role == .user ? .user(t.text) : .assistant(t.text)) }
            return UserInput(chat: chat, additionalContext: ["enable_thinking": false])
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

/// Removes <think>…</think> reasoning from a token stream, even when a tag is split across chunks.
struct ThinkFilter {
    private var buffer = ""
    private var thinking = false

    mutating func feed(_ text: String) -> String {
        buffer += text
        var out = ""
        while true {
            if thinking {
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
