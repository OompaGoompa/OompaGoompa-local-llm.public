import Foundation
import PDFKit
import os

// MARK: - Data

struct ChatMessage: Identifiable, Codable, Equatable {
    var id = UUID()
    var role: String
    var text: String
    var attachmentName: String?
    var attachmentText: String?
    var stats: String?

    /// What the model actually sees for this message.
    var promptContent: String {
        guard let attachmentText, let attachmentName else { return text }
        let question = text.isEmpty ? "Here is a file." : text
        return "File \"\(attachmentName)\":\n```\n\(attachmentText)\n```\n\n\(question)"
    }
}

struct Conversation: Identifiable, Codable {
    var id = UUID()
    var title = "New chat"
    var messages: [ChatMessage] = []
    var updated = Date()

    var asText: String {
        messages.map { m in
            let who = m.role == "user" ? "You" : "AI"
            let file = m.attachmentName.map { " [file: \($0)]" } ?? ""
            return "\(who)\(file):\n\(m.text)"
        }.joined(separator: "\n\n")
    }
}

struct ModelFile: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let url: URL
    let size: Int64
}

struct PromptPreset: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var text: String
}

struct Attachment: Equatable {
    let name: String
    let text: String
    let wasCut: Bool
}

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct LinkCheck: Identifiable {
    enum State {
        case checking
        case done(ModelReport)
        case failed(String)
    }
    let id = UUID()
    let state: State
}

// MARK: - Settings keys (stored in UserDefaults; views bind with @AppStorage)

enum Keys {
    static let selectedModel = "selectedModel"
    static let contextSize = "contextSize"
    static let useGPU = "useGPU"
    static let threads = "threads"
    static let compactKV = "compactKV"
    static let template = "template"
    static let unloadOnBackground = "unloadOnBackground"
    static let allowOversized = "allowOversized"
    static let temperature = "temperature"
    static let topP = "topP"
    static let repeatPenalty = "repeatPenalty"
    static let maxTokens = "maxTokens"
    static let promptEnabled = "promptEnabled"
    static let promptText = "promptText"
    static let promptPresets = "promptPresets"

    static var defaultThreads: Int { max(2, min(4, ProcessInfo.processInfo.activeProcessorCount - 2)) }

    static func registerDefaults() {
        // Smaller context on phones with less memory.
        let gb = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        UserDefaults.standard.register(defaults: [
            contextSize: gb > 7 ? 4096 : 2048,
            useGPU: true,
            threads: defaultThreads,
            compactKV: false,
            template: "",
            unloadOnBackground: true,
            allowOversized: false,
            temperature: 0.7,
            topP: 0.9,
            repeatPenalty: 1.1,
            maxTokens: 512,
            promptEnabled: true,
            promptText: "You are a helpful assistant."
        ])
    }
}

// MARK: - Memory

enum Mem {
    /// Memory this app is using right now, as iOS counts it.
    static var used: UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    }

    /// Memory iOS will still let this app take before closing it.
    static var free: UInt64 { UInt64(os_proc_available_memory()) }

    static var deviceGB: Double { Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824 }

    static func text(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        return gb >= 1 ? String(format: "%.2f GB", gb) : String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }
}

// MARK: - Files

enum Files {
    static let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    static let models = documents.appendingPathComponent("Models", isDirectory: true)
    static let chats = documents.appendingPathComponent("Chats", isDirectory: true)

    static func prepare() {
        for dir in [models, chats] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    static func isGGUF(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let magic = (try? handle.read(upToCount: 4)) ?? Data()
        return magic == Data("GGUF".utf8)
    }

    /// Reads a text or PDF file so it can be put in front of the model.
    static func readAttachment(_ url: URL, maxChars: Int) throws -> Attachment {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        var text: String?
        if url.pathExtension.lowercased() == "pdf" {
            text = PDFDocument(url: url)?.string
        } else {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count < 20_000_000 else { throw AttachmentError.tooBig }
            text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16)
        }
        guard var text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AttachmentError.notText
        }
        var cut = false
        if text.count > maxChars {
            text = String(text.prefix(maxChars))
            cut = true
        }
        return Attachment(name: url.lastPathComponent, text: text, wasCut: cut)
    }

    /// Writes text to a temporary file so it can go through the share sheet as a real file.
    static func exportFile(named name: String, text: String) -> URL? {
        let safe = name.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>\n")).joined(separator: " ")
        let trimmed = safe.trimmingCharacters(in: .whitespaces)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent((trimmed.isEmpty ? "chat" : trimmed) + ".txt")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}

enum AttachmentError: LocalizedError {
    case notText, tooBig
    var errorDescription: String? {
        switch self {
        case .notText: return "That file has no readable text. Text files, code, CSV, JSON and PDFs with real text work; images and scans do not."
        case .tooBig: return "That file is too big to attach."
        }
    }
}

// MARK: - Downloads

/// Downloads one model file straight into the Models folder, reporting progress.
final class Downloader: NSObject, URLSessionDownloadDelegate {
    var onProgress: ((Int64, Int64) -> Void)?
    var onDone: ((Result<URL, Error>) -> Void)?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var finished = false

    func start(_ url: URL) {
        let s = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        session = s
        task = s.downloadTask(with: url)
        task?.resume()
    }

    func cancel() {
        task?.cancel()
        session?.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        onProgress?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        finished = true
        if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            onDone?(.failure(DownloadError.http(http.statusCode)))
            return
        }
        guard Files.isGGUF(location) else {
            onDone?(.failure(DownloadError.notGGUF))
            return
        }
        var name = downloadTask.response?.suggestedFilename ?? downloadTask.originalRequest?.url?.lastPathComponent ?? "model.gguf"
        if !name.lowercased().hasSuffix(".gguf") { name += ".gguf" }
        let dest = Files.models.appendingPathComponent(name)
        do {
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.moveItem(at: location, to: dest)
            onDone?(.success(dest))
        } catch {
            onDone?(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, !finished { onDone?(.failure(error)) }
        session.finishTasksAndInvalidate()
    }
}

enum DownloadError: LocalizedError {
    case http(Int), notGGUF, badLink
    var errorDescription: String? {
        switch self {
        case .http(let code): return "The download failed (the server answered \(code)). Check the link, and that the file does not need a sign-in."
        case .notGGUF: return "That link did not lead to a GGUF model file. Use the direct link to the .gguf file itself."
        case .badLink: return "That does not look like a web link."
        }
    }
}
