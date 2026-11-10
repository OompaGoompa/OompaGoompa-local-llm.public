import Foundation
import llama

/// How the model and its working memory are set up. Changing any of these needs a reload.
struct EngineConfig: Equatable, Sendable {
    var contextSize: Int32 = 2048
    var useGPU = true
    var threads: Int32 = 4
    var compactKV = false
    /// Built-in llama.cpp template name ("chatml", "llama3", ...). Empty = use the one inside the model file.
    var template = ""
}

struct SamplingConfig: Sendable {
    var temperature: Float = 0.7
    var topP: Float = 0.9
    var topK: Int32 = 40
    var repeatPenalty: Float = 1.1
    var maxTokens: Int32 = 512
}

struct ChatTurn: Sendable {
    let role: String
    let content: String
}

struct ModelInfo: Sendable {
    let desc: String
    let sizeBytes: UInt64
    let params: UInt64
    let ctxTrain: Int32
    let ctxUsed: Int32
    let gpu: Bool
    let compactKV: Bool
    let hasTemplate: Bool
}

enum EngineError: LocalizedError {
    case modelLoad, contextInit, notLoaded, decode(Int32), promptTooLong

    var errorDescription: String? {
        switch self {
        case .modelLoad: return "The model file could not be loaded. It may be damaged, not a GGUF file, or too large for this phone."
        case .contextInit: return "The model loaded but there was not enough memory for its working space. Try a smaller context size in Settings."
        case .notLoaded: return "No model is loaded."
        case .decode(let code): return "The model stopped with an error (code \(code)). Try a smaller context size or a new chat."
        case .promptTooLong: return "This message is too long for the context size. Shorten it, attach a smaller file, or raise the context size in Settings."
        }
    }
}

/// One model + one context, used from one place at a time. All llama.cpp calls go through here.
actor LlamaEngine {
    private var model: OpaquePointer?
    private var ctx: OpaquePointer?
    private var vocab: OpaquePointer?
    private var nCtx: Int32 = 0
    private var nBatch: Int32 = 512
    private var template = ""
    /// Tokens currently held in the model's working memory, so a follow-up message only processes what is new.
    private var cached: [llama_token] = []
    /// Remembers how many old turns were dropped for the current chat, so the cut point stays put between messages.
    private var dropAnchor = ""
    private var dropCount = 0

    private static let backend: Void = { llama_backend_init() }()

    var isLoaded: Bool { ctx != nil }

    func load(path: String, config: EngineConfig) throws -> ModelInfo {
        unload()
        _ = Self.backend

        var mp = llama_model_default_params()
        #if targetEnvironment(simulator)
        mp.n_gpu_layers = 0
        #else
        mp.n_gpu_layers = config.useGPU ? 999 : 0
        #endif
        // Memory-map the file: iOS pages weights in from storage on demand instead of copying it all into RAM.
        mp.load_mode = LLAMA_LOAD_MODE_MMAP

        guard let m = llama_model_load_from_file(path, mp) else { throw EngineError.modelLoad }

        let train = llama_model_n_ctx_train(m)
        let n = train > 0 ? min(config.contextSize, train) : config.contextSize
        let batch = min(Int32(512), n)

        func makeContext(compact: Bool) -> OpaquePointer? {
            var cp = llama_context_default_params()
            cp.n_ctx = UInt32(n)
            cp.n_batch = UInt32(batch)
            cp.n_ubatch = UInt32(batch)
            cp.n_threads = config.threads
            cp.n_threads_batch = config.threads
            cp.offload_kqv = config.useGPU
            if compact {
                // 8-bit working memory: roughly halves the KV cache. Needs flash attention.
                cp.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_ENABLED
                cp.type_k = GGML_TYPE_Q8_0
                cp.type_v = GGML_TYPE_Q8_0
            }
            return llama_init_from_model(m, cp)
        }

        var compact = config.compactKV
        var c = makeContext(compact: compact)
        if c == nil && compact {
            compact = false
            c = makeContext(compact: false)
        }
        guard let c else {
            llama_model_free(m)
            throw EngineError.contextInit
        }

        model = m
        ctx = c
        vocab = llama_model_get_vocab(m)
        nCtx = Int32(llama_n_ctx(c))
        nBatch = batch
        template = config.template
        cached = []
        dropAnchor = ""
        dropCount = 0

        var buf = [CChar](repeating: 0, count: 256)
        _ = llama_model_desc(m, &buf, 256)
        return ModelInfo(
            desc: String(cString: buf),
            sizeBytes: llama_model_size(m),
            params: llama_model_n_params(m),
            ctxTrain: train,
            ctxUsed: nCtx,
            gpu: config.useGPU,
            compactKV: compact,
            hasTemplate: llama_model_chat_template(m, nil) != nil
        )
    }

    func unload() {
        if let ctx { llama_free(ctx) }
        if let model { llama_model_free(model) }
        ctx = nil
        model = nil
        vocab = nil
        cached = []
    }

    /// Streams the reply piece by piece. Cancelling the task that reads the stream stops generation.
    nonisolated func generate(turns: [ChatTurn], sampling: SamplingConfig) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.run(turns, sampling) { _ = continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Generation

    private func run(_ turnsIn: [ChatTurn], _ s: SamplingConfig, emit: @Sendable (String) -> Void) throws {
        guard let ctx, let vocab else { throw EngineError.notLoaded }

        // Leave room for the reply; the rest of the context is for the conversation.
        let reserve = max(64, min(Int(s.maxTokens), Int(nCtx) / 3))
        let budget = Int(nCtx) - reserve

        var turns = turnsIn
        let anchor = turns.first(where: { $0.role != "system" })?.content ?? ""
        if anchor != dropAnchor {
            dropAnchor = anchor
            dropCount = 0
        }
        func dropOldest(_ list: inout [ChatTurn]) -> Bool {
            guard let i = list.firstIndex(where: { $0.role != "system" }), i < list.count - 1 else { return false }
            list.remove(at: i)
            return true
        }
        for _ in 0..<dropCount { _ = dropOldest(&turns) }

        var tokens = tokenize(applyTemplate(turns))
        if tokens.count > budget {
            // Forget the oldest messages, and cut a bit extra so this does not happen on every message.
            let target = budget * 7 / 10
            while tokens.count > target {
                guard dropOldest(&turns) else { break }
                dropCount += 1
                tokens = tokenize(applyTemplate(turns))
            }
        }
        guard tokens.count <= budget, !tokens.isEmpty else { throw EngineError.promptTooLong }

        // Reuse whatever part of the conversation is already in working memory.
        var common = 0
        let limit = min(cached.count, tokens.count)
        while common < limit && cached[common] == tokens[common] { common += 1 }
        if common == tokens.count { common -= 1 }
        let mem = llama_get_memory(ctx)
        if !llama_memory_seq_rm(mem, 0, Int32(common), -1) {
            llama_memory_clear(mem, true)
            common = 0
        }
        cached = Array(tokens[0..<common])

        var batch = llama_batch_init(nBatch, 0, 1)
        defer { llama_batch_free(batch) }

        var i = common
        while i < tokens.count {
            try Task.checkCancellation()
            let end = min(i + Int(nBatch), tokens.count)
            batch.n_tokens = 0
            for j in i..<end {
                Self.add(&batch, tokens[j], Int32(j), j == tokens.count - 1)
            }
            let r = llama_decode(ctx, batch)
            guard r == 0 else {
                llama_memory_clear(mem, true)
                cached = []
                throw EngineError.decode(r)
            }
            cached.append(contentsOf: tokens[i..<end])
            i = end
        }

        let chain = llama_sampler_chain_init(llama_sampler_chain_default_params())!
        defer { llama_sampler_free(chain) }
        if s.repeatPenalty > 1.0 {
            llama_sampler_chain_add(chain, llama_sampler_init_penalties(llama_vocab_n_tokens(vocab), 64, s.repeatPenalty, 0, 0))
        }
        if s.temperature <= 0.01 {
            llama_sampler_chain_add(chain, llama_sampler_init_greedy())
        } else {
            llama_sampler_chain_add(chain, llama_sampler_init_top_k(s.topK))
            llama_sampler_chain_add(chain, llama_sampler_init_top_p(s.topP, 1))
            llama_sampler_chain_add(chain, llama_sampler_init_temp(s.temperature))
            llama_sampler_chain_add(chain, llama_sampler_init_dist(UInt32.random(in: 0..<UInt32.max)))
        }

        var pos = Int32(tokens.count)
        var pending: [UInt8] = []
        var produced: Int32 = 0
        while produced < s.maxTokens && pos < nCtx {
            if Task.isCancelled { break }
            let tok = llama_sampler_sample(chain, ctx, -1)
            if llama_vocab_is_eog(vocab, tok) { break }

            // A character can span several tokens, so only emit once the bytes form valid text.
            pending.append(contentsOf: piece(tok))
            if !pending.isEmpty {
                if let text = String(bytes: pending, encoding: .utf8) {
                    emit(text)
                    pending.removeAll()
                } else if pending.count > 12 {
                    emit(String(decoding: pending, as: UTF8.self))
                    pending.removeAll()
                }
            }

            batch.n_tokens = 0
            Self.add(&batch, tok, pos, true)
            let r = llama_decode(ctx, batch)
            guard r == 0 else {
                llama_memory_clear(mem, true)
                cached = []
                throw EngineError.decode(r)
            }
            cached.append(tok)
            pos += 1
            produced += 1
        }
        if !pending.isEmpty { emit(String(decoding: pending, as: UTF8.self)) }
    }

    private static func add(_ batch: inout llama_batch, _ token: llama_token, _ pos: llama_pos, _ wantsOutput: Bool) {
        let n = Int(batch.n_tokens)
        batch.token[n] = token
        batch.pos[n] = pos
        batch.n_seq_id[n] = 1
        batch.seq_id[n]![0] = 0
        batch.logits[n] = wantsOutput ? 1 : 0
        batch.n_tokens += 1
    }

    private func tokenize(_ text: String) -> [llama_token] {
        guard let vocab else { return [] }
        let n = Int32(text.utf8.count)
        var toks = [llama_token](repeating: 0, count: Int(n) + 16)
        var count = llama_tokenize(vocab, text, n, &toks, Int32(toks.count), true, true)
        if count < 0 && count != Int32.min {
            toks = [llama_token](repeating: 0, count: Int(-count))
            count = llama_tokenize(vocab, text, n, &toks, Int32(toks.count), true, true)
        }
        return count > 0 ? Array(toks[0..<Int(count)]) : []
    }

    private func piece(_ token: llama_token) -> [UInt8] {
        guard let vocab else { return [] }
        var buf = [CChar](repeating: 0, count: 64)
        var n = llama_token_to_piece(vocab, token, &buf, 64, 0, false)
        if n < 0 {
            buf = [CChar](repeating: 0, count: Int(-n))
            n = llama_token_to_piece(vocab, token, &buf, -n, 0, false)
        }
        guard n > 0 else { return [] }
        return buf[0..<Int(n)].map { UInt8(bitPattern: $0) }
    }

    // MARK: - Prompt format

    private func applyTemplate(_ turns: [ChatTurn]) -> String {
        let cStrings: [UnsafeMutablePointer<CChar>?] = turns.flatMap { [strdup($0.role), strdup($0.content)] }
        defer { cStrings.forEach { free($0) } }
        var msgs: [llama_chat_message] = []
        for i in 0..<turns.count {
            msgs.append(llama_chat_message(role: UnsafePointer(cStrings[2 * i]), content: UnsafePointer(cStrings[2 * i + 1])))
        }
        let total = turns.reduce(0) { $0 + $1.role.utf8.count + $1.content.utf8.count }

        func apply(_ tmpl: UnsafePointer<CChar>?) -> String? {
            guard tmpl != nil else { return nil }
            var buf = [CChar](repeating: 0, count: total * 2 + 2048)
            var n = llama_chat_apply_template(tmpl, msgs, msgs.count, true, &buf, Int32(buf.count))
            if n > Int32(buf.count) {
                buf = [CChar](repeating: 0, count: Int(n) + 1)
                n = llama_chat_apply_template(tmpl, msgs, msgs.count, true, &buf, Int32(buf.count))
            }
            guard n >= 0 else { return nil }
            return String(decoding: buf[0..<Int(n)].map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }

        var result: String?
        if !template.isEmpty {
            result = template.withCString { apply($0) }
        } else if let model {
            result = apply(llama_model_chat_template(model, nil))
        }
        if let result { return result }

        // Unknown format: fall back to ChatML, the most common one.
        var text = ""
        for t in turns { text += "<|im_start|>\(t.role)\n\(t.content)<|im_end|>\n" }
        return text + "<|im_start|>assistant\n"
    }
}
