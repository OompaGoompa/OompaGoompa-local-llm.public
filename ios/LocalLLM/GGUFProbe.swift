import Foundation

/// Reads the start of a GGUF file (from a link, before downloading it) and judges whether it will run here.
struct ModelReport {
    enum Level { case ok, warn, bad }
    struct Line: Identifiable {
        let id = UUID()
        let level: Level
        let title: String
        let detail: String
    }

    var url: URL
    var fileName: String
    var lines: [Line] = []

    var worst: Level {
        if lines.contains(where: { $0.level == .bad }) { return .bad }
        if lines.contains(where: { $0.level == .warn }) { return .warn }
        return .ok
    }
}

enum GGUFProbe {
    /// Model architectures the bundled llama.cpp (b12242) can run.
    static let supported: Set<String> = Set("clip llama llama4 deci falcon grok gpt2 gptj gptneox mpt baichuan starcoder refact bert modern-bert nomic-bert nomic-bert-moe neo-bert jina-bert-v2 jina-bert-v3 eurobert bloom stablelm qwen qwen2 qwen2moe qwen2vl sensenova_u1 qwen3 flint qwen3moe clover_moe qwen3next qwen3vl qwen3vlmoe qwen35 qwen35moe clef vllm-decision2 qwen4exp phi2 phi3 phimoe plamo plamo2 plamo3 codeshell orion internlm2 minicpm minicpm3 gemma gemma2 gemma3 gemma3n gemma4 gemma4-assistant gemma-embedding gemma-embedding2 starcoder2 mamba mamba2 maple jamba falcon-h1 xverse command-r cohere2 cohere2moe dbrx olmo olmo2 olmoe muse-glimmer muse-spark openelm arctic deepseek deepseek2 deepseek2-ocr deepseek32 deepseek4 deepseek41 xing4_0 chatglm glm4 glm4moe glm-dsa bitnet t5 t5encoder jais jais2 nemotron nemotron_h nemotron_h_moe metis16 exaone exaone4 exaone-moe rwkv6 rwkv6qwen2 rwkv7 arwkv7 granite granitemoe granitehybrid graniteswitch granite_swa chameleon wavtokenizer-dec plm bailingmoe bailingmoe2 bailingmoe3 dots1 dots3note arcee afmoe laguna ernie4_5 ernie4_5-moe hunyuan-moe hunyuan-dense hunyuan_vl hy_v3 hy_v4 smollm3 gpt-oss lfm2 lfm2moe lfm3 dream smallthinker llada llada-moe seed_oss grovemoe apertus minimax-01 hrm_text limite minimax-m2 minimax-m3 cogvlm rnd1 pangu-embedded mistral3 eagle3 dflash mistral4 mistral-large4 paddleocr mimo2 step35 spark2_5 llama-embed maincoder maion-coder kimi-linear kimi-k3 kimi-k31 glm5-next talkie mellum nanbeige qwen3tts pockettts k2-horizon beam kolibri1 ricursive".split(separator: " ").map(String.init))

    static let fileTypes: [UInt64: String] = [
        0: "F32", 1: "F16", 2: "Q4_0", 3: "Q4_1", 7: "Q8_0", 8: "Q5_0", 9: "Q5_1", 10: "Q2_K", 11: "Q3_K_S", 12: "Q3_K_M",
        13: "Q3_K_L", 14: "Q4_K_S", 15: "Q4_K_M", 16: "Q5_K_S", 17: "Q5_K_M", 18: "Q6_K", 19: "IQ2_XXS", 20: "IQ2_XS",
        21: "Q2_K_S", 22: "IQ3_XS", 23: "IQ3_XXS", 24: "IQ1_S", 25: "IQ4_NL", 26: "IQ3_S", 27: "IQ3_M", 28: "IQ2_S",
        29: "IQ2_M", 30: "IQ4_XS", 31: "IQ1_M", 32: "BF16", 36: "TQ1_0", 37: "TQ2_0", 38: "MXFP4", 39: "NVFP4",
        40: "Q1_0", 41: "Q2_0", 42: "F8_E4M3"
    ]

    struct Header {
        var isGGUF = false
        var version: UInt32 = 0
        var strings: [String: String] = [:]
        var numbers: [String: UInt64] = [:]
    }

    // MARK: - Network

    /// Fetches the first part of the file and its total size without downloading the whole thing.
    static func fetchHead(_ url: URL, limit: Int = 768 * 1024) async throws -> (data: Data, total: Int64?, name: String) {
        var request = URLRequest(url: url)
        request.setValue("bytes=0-\(limit - 1)", forHTTPHeaderField: "Range")
        request.timeoutInterval = 30
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        var total: Int64?
        if let http = response as? HTTPURLResponse {
            guard (200...299).contains(http.statusCode) else { throw DownloadError.http(http.statusCode) }
            if http.statusCode == 206, let range = http.value(forHTTPHeaderField: "Content-Range"), let slash = range.lastIndex(of: "/") {
                total = Int64(range[range.index(after: slash)...])
            } else if http.statusCode == 200, response.expectedContentLength > 0 {
                total = response.expectedContentLength
            }
        }
        var data = Data()
        data.reserveCapacity(limit)
        for try await byte in bytes {
            data.append(byte)
            if data.count >= limit { break }
        }
        var name = url.lastPathComponent
        if let suggested = response.suggestedFilename, suggested.lowercased().hasSuffix(".gguf") { name = suggested }
        return (data, total, name)
    }

    // MARK: - Parsing

    /// Reads as many settings from the file header as the fetched bytes hold. The useful ones come first.
    static func parse(_ data: Data) -> Header {
        var h = Header()
        var r = Reader(data: data)
        guard let magic = r.bytes(4), magic == Data("GGUF".utf8), let version = r.u32() else { return h }
        h.isGGUF = true
        h.version = version
        guard version >= 2, r.u64() != nil, let count = r.u64() else { return h }

        for _ in 0..<min(count, 100_000) {
            guard let key = r.string(), let type = r.u32() else { break }
            switch type {
            case 8:
                guard let value = r.string() else { return h }
                if value.count < 300 { h.strings[key] = value }
            case 9:
                guard r.skipArray() else { return h }
            default:
                guard let value = r.scalar(type) else { return h }
                h.numbers[key] = value
            }
        }
        return h
    }

    private struct Reader {
        let data: Data
        var pos = 0

        mutating func bytes(_ n: Int) -> Data? {
            guard n >= 0, pos + n <= data.count else { return nil }
            defer { pos += n }
            return data.subdata(in: (data.startIndex + pos)..<(data.startIndex + pos + n))
        }

        mutating func int(_ size: Int) -> UInt64? {
            guard let b = bytes(size) else { return nil }
            var value: UInt64 = 0
            for (i, byte) in b.enumerated() { value |= UInt64(byte) << (8 * UInt64(i)) }
            return value
        }

        mutating func u32() -> UInt32? { int(4).map { UInt32($0) } }
        mutating func u64() -> UInt64? { int(8) }

        mutating func string() -> String? {
            guard let length = u64(), length < 16_000_000, let b = bytes(Int(length)) else { return nil }
            return String(decoding: b, as: UTF8.self)
        }

        static func size(of type: UInt32) -> Int? {
            switch type {
            case 0, 1, 7: return 1
            case 2, 3: return 2
            case 4, 5, 6: return 4
            case 10, 11, 12: return 8
            default: return nil
            }
        }

        mutating func scalar(_ type: UInt32) -> UInt64? {
            guard let size = Self.size(of: type) else { return nil }
            return int(size)
        }

        mutating func skipArray() -> Bool {
            guard let type = u32(), let count = u64() else { return false }
            if type == 8 {
                for _ in 0..<count { guard string() != nil else { return false } }
                return true
            }
            if type == 9 {
                for _ in 0..<count { guard skipArray() else { return false } }
                return true
            }
            guard let size = Self.size(of: type), count < UInt64(Int.max / 8) else { return false }
            return bytes(Int(count) * size) != nil
        }
    }

    // MARK: - Verdict

    static func report(url: URL, name: String, header: Header, total: Int64?, room: UInt64, contextSetting: Int) -> ModelReport {
        var report = ModelReport(url: url, fileName: name)
        func add(_ level: ModelReport.Level, _ title: String, _ detail: String) {
            report.lines.append(.init(level: level, title: title, detail: detail))
        }

        guard header.isGGUF else {
            add(.bad, "Not a GGUF model", "This link does not lead to a .gguf file. Use the direct link to the file itself, not to a web page about it.")
            return report
        }
        if header.version < 2 || header.version > 3 {
            add(.bad, "Unsupported file version", "GGUF version \(header.version) cannot be read by this app.")
        } else {
            add(.ok, "File format", "GGUF version \(header.version)")
        }

        if name.range(of: #"-\d{5}-of-\d{5}\.gguf$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            add(.bad, "Split file", "This model comes in several parts. Find a single-file version.")
        }

        let kind = header.strings["general.type"] ?? "model"
        if kind != "model" {
            add(.bad, "Not a full model", "This file is a \"\(kind)\" add-on, not a model you can chat with.")
        }

        if let arch = header.strings["general.architecture"] {
            let notChat = ["bert", "clip", "t5encoder", "wavtokenizer", "embed", "tts", "ocr"].contains { arch.contains($0) }
            if !supported.contains(arch) {
                add(.bad, "Model type not supported", "\"\(arch)\" is not a model type this app's engine can run.")
            } else if notChat {
                add(.warn, "Not a chat model", "\"\(arch)\" models are made for other jobs (search, images or speech), so chatting will not work well.")
            } else {
                let label = [header.strings["general.name"], header.strings["general.size_label"]].compactMap { $0 }.joined(separator: " · ")
                add(.ok, "Model type", label.isEmpty ? arch : "\(arch) (\(label))")
            }
            if let trained = header.numbers["\(arch).context_length"], trained > 0, trained < UInt64(contextSetting) {
                add(.ok, "Context", "This model handles up to \(trained) tokens; the app will use that instead of your \(contextSetting) setting.")
            }
        } else {
            add(.warn, "Model type unknown", "The file does not say what kind of model it is. It may still work.")
        }

        if let type = header.numbers["general.file_type"] {
            let quant = fileTypes[type] ?? "type \(type)"
            if [0, 1, 32].contains(type) {
                add(.warn, "Not compressed", "\(quant) is a full-precision file: large and slow on a phone. A Q4_K_M version is about a quarter of the size.")
            } else {
                add(.ok, "Compression", quant)
            }
        }

        if let total, total > 0 {
            let size = UInt64(total)
            let sizeText = Mem.text(size)
            if room > 0, size > room {
                add(.bad, "Too big for this phone's memory", "The file is \(sizeText) but iOS gives this app about \(Mem.text(room)). Pick a smaller or more compressed version.")
            } else if room > 0, Double(size) > Double(room) * 0.75 {
                add(.warn, "Tight on memory", "The file is \(sizeText) of about \(Mem.text(room)) available. It may run slowly or be closed by iOS; use a small context size.")
            } else {
                add(.ok, "Memory", "\(sizeText) fits in the roughly \(Mem.text(room)) this app can use.")
            }

            let values = try? Files.documents.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            if let free = values?.volumeAvailableCapacityForImportantUsage {
                if free < total + 300_000_000 {
                    add(.bad, "Not enough storage", "The download needs \(sizeText) but only \(Mem.text(UInt64(max(0, free)))) is free on this phone.")
                } else {
                    add(.ok, "Storage", "\(Mem.text(UInt64(free))) free")
                }
            }
        } else {
            add(.warn, "Size unknown", "The server did not say how big the file is, so memory and storage could not be checked.")
        }
        return report
    }
}
