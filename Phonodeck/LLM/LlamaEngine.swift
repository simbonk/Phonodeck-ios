import Foundation
import llama

/// Runs a GGUF storyteller with llama.cpp (github.com/ggml-org/llama.cpp, MIT license) on the
/// GPU through Metal. MLX can't read GGUF, and many community fine-tunes (uncensored and
/// roleplay models especially) are only published that way.
///
/// One instance holds one model and one 4K-token conversation. Calls are not reentrant:
/// LLMService only uses it while holding MLXGate, so it never runs beside a neural voice.
final class LlamaEngine: @unchecked Sendable {
    enum Failure: LocalizedError {
        case load(String), context, decode(Int32)
        var errorDescription: String? {
            switch self {
            case .load(let name): "llama.cpp couldn't open \(name). The file may be damaged or use a model type this version doesn't know; try deleting and downloading it again."
            case .context: "llama.cpp couldn't set aside memory for the conversation."
            case .decode(let code): "llama.cpp stopped while reading the story (code \(code))."
            }
        }
    }

    private let model: OpaquePointer
    private let ctx: OpaquePointer
    private let vocab: OpaquePointer
    /// The chat template stored in the GGUF file (Jinja), if any.
    private let template: String?
    let contextTokens: Int

    private static let backend: Void = { llama_backend_init() }()

    init(path: String, contextTokens: Int) throws {
        _ = Self.backend
        var mp = llama_model_default_params()
        #if targetEnvironment(simulator)
        mp.n_gpu_layers = 0
        #else
        mp.n_gpu_layers = 999   // everything on the GPU
        #endif
        guard let m = llama_model_load_from_file(path, mp) else {
            throw Failure.load((path as NSString).lastPathComponent)
        }
        var cp = llama_context_default_params()
        cp.n_ctx = UInt32(contextTokens)
        cp.n_batch = 512
        cp.n_ubatch = 512
        let threads = Int32(max(1, min(4, ProcessInfo.processInfo.activeProcessorCount - 2)))
        cp.n_threads = threads
        cp.n_threads_batch = threads
        guard let c = llama_init_from_model(m, cp) else {
            llama_model_free(m)
            throw Failure.context
        }
        model = m
        ctx = c
        vocab = llama_model_get_vocab(m)
        template = llama_model_chat_template(m, nil).map { String(cString: $0) }
        self.contextTokens = contextTokens
    }

    deinit {
        llama_free(ctx)
        llama_model_free(model)
    }

    // MARK: Prompt

    /// The conversation in the model's own chat format, ending where the model should reply.
    func format(system: String?, turns: [ChatTurn]) -> String {
        var roles: [String] = []
        var contents: [String] = []
        if let system, !system.isEmpty { roles.append("system"); contents.append(system) }
        for t in turns { roles.append(t.role == .user ? "user" : "assistant"); contents.append(t.text) }

        // C strings that live until the end of this call.
        let cRoles = roles.map { strdup($0) }
        let cContents = contents.map { strdup($0) }
        defer { (cRoles + cContents).forEach { free($0) } }
        let messages = zip(cRoles, cContents).map { llama_chat_message(role: UnsafePointer($0), content: UnsafePointer($1)) }
        let total = contents.reduce(0) { $0 + $1.utf8.count }

        func apply(_ tmpl: String?) -> String? {
            var size = max(4096, total * 2 + 512)
            for _ in 0..<2 {
                var buf = [CChar](repeating: 0, count: size)
                let n: Int32 = withOptionalCString(tmpl) { t in
                    messages.withUnsafeBufferPointer { m in
                        llama_chat_apply_template(t, m.baseAddress, m.count, true, &buf, Int32(size))
                    }
                }
                if n < 0 { return nil }
                if Int(n) <= size {
                    return String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                }
                size = Int(n) + 1
            }
            return nil
        }
        // Templates llama.cpp doesn't recognise fall back to ChatML, which most fine-tunes use.
        var prompt = apply(template) ?? apply("chatml") ?? contents.joined(separator: "\n\n")
        // Qwen3 and Qwen3.5 think out loud first unless the reply starts with an empty
        // thinking block (what their template does for enable_thinking = false).
        if prompt.hasSuffix("<|im_start|>assistant\n"), template?.contains("<think>") ?? false {
            prompt += "<think>\n\n</think>\n\n"
        }
        return prompt
    }

    func tokenize(_ text: String) -> [llama_token] {
        let count = Int32(text.utf8.count)
        var tokens = [llama_token](repeating: 0, count: Int(count) + 16)
        var n = llama_tokenize(vocab, text, count, &tokens, Int32(tokens.count), true, true)
        if n < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-n))
            n = llama_tokenize(vocab, text, count, &tokens, Int32(tokens.count), true, true)
        }
        return Array(tokens.prefix(Int(max(0, n))))
    }

    // MARK: Generation

    /// Writes a reply to `prompt`, passing text to `onText` as it comes. `onText` returns false
    /// to stop early. Returns the speed in tokens per second.
    func generate(prompt: [llama_token], maxTokens: Int, temperature: Float, topP: Float,
                  repetitionPenalty: Float?, onText: (String) -> Bool) throws -> Double {
        // Each reply starts from a clean conversation memory.
        llama_memory_clear(llama_get_memory(ctx), true)

        var i = 0
        while i < prompt.count {
            var chunk = Array(prompt[i..<min(i + 512, prompt.count)])
            let r = chunk.withUnsafeMutableBufferPointer { llama_decode(ctx, llama_batch_get_one($0.baseAddress, Int32($0.count))) }
            if r != 0 { throw Failure.decode(r) }
            i += 512
        }

        let chain = llama_sampler_chain_init(llama_sampler_chain_default_params())
        defer { llama_sampler_free(chain) }
        if let p = repetitionPenalty, p != 1 { llama_sampler_chain_add(chain, llama_sampler_init_penalties(64, p, 0, 0)) }
        if temperature <= 0 {
            llama_sampler_chain_add(chain, llama_sampler_init_greedy())
        } else {
            llama_sampler_chain_add(chain, llama_sampler_init_top_k(64))
            llama_sampler_chain_add(chain, llama_sampler_init_top_p(topP, 1))
            llama_sampler_chain_add(chain, llama_sampler_init_temp(temperature))
            llama_sampler_chain_add(chain, llama_sampler_init_dist(UInt32.random(in: 0...UInt32.max)))
        }

        let start = Date()
        var produced = 0
        var pending: [UInt8] = []   // a character can be split across tokens
        var position = prompt.count
        while produced < maxTokens, position < contextTokens - 1 {
            var token = llama_sampler_sample(chain, ctx, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            produced += 1

            var buf = [CChar](repeating: 0, count: 64)
            var n = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, false)
            if n < 0 {
                buf = [CChar](repeating: 0, count: Int(-n))
                n = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, false)
            }
            pending += buf.prefix(Int(max(0, n))).map { UInt8(bitPattern: $0) }
            if let text = String(bytes: pending, encoding: .utf8) {
                pending = []
                if !text.isEmpty, !onText(text) { break }
            } else if pending.count > 8 {
                let text = String(decoding: pending, as: UTF8.self)
                pending = []
                if !onText(text) { break }
            }

            let r = llama_decode(ctx, llama_batch_get_one(&token, 1))
            if r != 0 { throw Failure.decode(r) }
            position += 1
        }
        if !pending.isEmpty { _ = onText(String(decoding: pending, as: UTF8.self)) }
        let seconds = Date().timeIntervalSince(start)
        return seconds > 0 ? Double(produced) / seconds : 0
    }
}

/// Set from one task, read from another, to stop a reply that's being written.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

private func withOptionalCString<R>(_ s: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
    guard let s else { return body(nil) }
    return s.withCString { body($0) }
}
