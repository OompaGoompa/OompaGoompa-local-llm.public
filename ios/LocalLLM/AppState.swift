import SwiftUI
import UIKit

@MainActor
final class AppState: ObservableObject {
    @Published var models: [ModelFile] = []
    @Published var selectedModel: String? {
        didSet { UserDefaults.standard.set(selectedModel, forKey: Keys.selectedModel) }
    }
    @Published var loadedModel: String?
    @Published var loadedInfo: ModelInfo?
    @Published var isLoading = false
    @Published var isGenerating = false
    @Published var errorText: String?

    @Published var conversations: [Conversation] = []
    @Published var currentID = UUID()

    @Published var importStatus: String?
    @Published var downloadName: String?
    @Published var downloadDone: Int64 = 0
    @Published var downloadTotal: Int64 = 0

    @Published var shareItem: ShareItem?
    @Published var linkCheck: LinkCheck?

    @Published var memUsed: UInt64 = 0
    @Published var memFree: UInt64 = 0

    private let engine = LlamaEngine()
    private var loadedConfig: EngineConfig?
    private var genTask: Task<Void, Never>?
    private var generatingRemotely = false
    private var downloader: Downloader?
    private var memTimer: Timer?

    init() {
        Keys.registerDefaults()
        Files.prepare()
        selectedModel = UserDefaults.standard.string(forKey: Keys.selectedModel)
        refreshModels()
        loadChats()
        if let first = conversations.first, first.messages.isEmpty {
            currentID = first.id
        } else {
            newChat()
        }
        refreshMemory()
        memTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshMemory() }
        }
    }

    // MARK: - Settings snapshot

    private var defaults: UserDefaults { .standard }

    var engineConfig: EngineConfig {
        EngineConfig(
            contextSize: Int32(defaults.integer(forKey: Keys.contextSize)),
            useGPU: defaults.bool(forKey: Keys.useGPU),
            threads: Int32(max(1, defaults.integer(forKey: Keys.threads))),
            compactKV: defaults.bool(forKey: Keys.compactKV),
            template: defaults.string(forKey: Keys.template) ?? ""
        )
    }

    var samplingConfig: SamplingConfig {
        SamplingConfig(
            temperature: Float(defaults.double(forKey: Keys.temperature)),
            topP: Float(defaults.double(forKey: Keys.topP)),
            topK: 40,
            repeatPenalty: Float(defaults.double(forKey: Keys.repeatPenalty)),
            maxTokens: Int32(max(16, defaults.integer(forKey: Keys.maxTokens)))
        )
    }

    /// Rough number of characters of attached file that fit next to a question and a reply.
    var attachmentCharLimit: Int {
        let ctx = defaults.integer(forKey: Keys.contextSize)
        let reply = min(defaults.integer(forKey: Keys.maxTokens), ctx / 3)
        return max(1000, (ctx - reply - 400) * 3)
    }

    /// True when chats go to a model on another computer instead of the one on this phone.
    var remoteOn: Bool { defaults.bool(forKey: Keys.remoteEnabled) }
    var remoteModelName: String { defaults.string(forKey: Keys.remoteModel) ?? "" }

    // MARK: - Sending files out

    /// Opens the share sheet with the text as a .txt file (AirDrop, Save to Files, Mail, ...).
    func shareFile(named name: String, text: String) {
        guard let url = Files.exportFile(named: name, text: text) else {
            errorText = "The file could not be written."
            return
        }
        shareItem = ShareItem(url: url)
    }

    // MARK: - Memory

    func refreshMemory() {
        memUsed = Mem.used
        memFree = Mem.free
    }

    private func setBusy(_ busy: Bool) {
        UIApplication.shared.isIdleTimerDisabled = busy
    }

    // MARK: - Models

    func refreshModels() {
        let keys: [URLResourceKey] = [.fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: Files.models, includingPropertiesForKeys: keys)) ?? []
        models = urls
            .filter { $0.pathExtension.lowercased() == "gguf" }
            .map { url in
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return ModelFile(name: url.lastPathComponent, url: url, size: Int64(size))
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if let selected = selectedModel, !models.contains(where: { $0.name == selected }) {
            selectedModel = nil
        }
        if selectedModel == nil, models.count == 1 {
            selectedModel = models[0].name
        }
    }

    func importModel(from url: URL) {
        guard url.pathExtension.lowercased() == "gguf" else {
            errorText = "That is not a GGUF file. This app runs models in the GGUF format (file names ending in .gguf)."
            return
        }
        let dest = Files.models.appendingPathComponent(url.lastPathComponent)
        if url.standardizedFileURL.path == dest.standardizedFileURL.path {
            refreshModels()
            return
        }
        importStatus = "Copying \(url.lastPathComponent)…"
        setBusy(true)
        Task {
            let failure: String? = await Task.detached(priority: .userInitiated) {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    guard Files.isGGUF(url) else { return "That file is not a valid GGUF model." }
                    if FileManager.default.fileExists(atPath: dest.path) {
                        try FileManager.default.removeItem(at: dest)
                    }
                    try FileManager.default.copyItem(at: url, to: dest)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            importStatus = nil
            setBusy(isGenerating)
            if let failure { errorText = failure }
            refreshModels()
            if failure == nil { selectedModel = dest.lastPathComponent }
        }
    }

    func deleteModel(_ model: ModelFile) {
        Task {
            if loadedModel == model.name { await unloadModel() }
            try? FileManager.default.removeItem(at: model.url)
            refreshModels()
        }
    }

    private var checkTask: Task<Void, Never>?

    /// "Add from URL": looks at the start of the file behind the link and reports whether it will run on this phone.
    func checkLink(_ link: String) {
        var text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        // A Hugging Face page link ("/blob/") shows a web page; "/resolve/" is the file itself.
        if text.contains("huggingface.co") { text = text.replacingOccurrences(of: "/blob/", with: "/resolve/") }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            errorText = DownloadError.badLink.errorDescription
            return
        }
        linkCheck = LinkCheck(state: .checking)
        refreshMemory()
        let room = memUsed + memFree
        let context = defaults.integer(forKey: Keys.contextSize)
        checkTask?.cancel()
        checkTask = Task {
            do {
                let head = try await GGUFProbe.fetchHead(url)
                try Task.checkCancellation()
                let header = GGUFProbe.parse(head.data)
                let report = GGUFProbe.report(url: url, name: head.name, header: header, total: head.total, room: room, contextSetting: context)
                if linkCheck != nil { linkCheck = LinkCheck(state: .done(report)) }
            } catch is CancellationError {
            } catch {
                if linkCheck != nil { linkCheck = LinkCheck(state: .failed(error.localizedDescription)) }
            }
        }
    }

    func cancelCheck() {
        checkTask?.cancel()
        linkCheck = nil
    }

    func startDownload(_ url: URL) {
        linkCheck = nil
        downloader?.cancel()
        let d = Downloader()
        downloader = d
        if downloadName == nil { BackgroundKeeper.shared.begin() }
        downloadName = url.lastPathComponent
        downloadDone = 0
        downloadTotal = 0
        setBusy(true)
        d.onProgress = { [weak self] done, total in
            Task { @MainActor in
                guard let self, self.downloadName != nil else { return }
                self.downloadDone = done
                self.downloadTotal = total
            }
        }
        d.onDone = { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                let wasActive = self.downloadName != nil
                self.downloadName = nil
                self.downloader = nil
                self.setBusy(self.isGenerating)
                if wasActive {
                    if case .success(let file) = result {
                        BackgroundKeeper.shared.notify(title: "Model downloaded", body: file.lastPathComponent)
                    }
                    BackgroundKeeper.shared.end()
                }
                switch result {
                case .success(let dest):
                    self.refreshModels()
                    self.selectedModel = dest.lastPathComponent
                case .failure(let error):
                    if (error as NSError).code != NSURLErrorCancelled {
                        self.errorText = error.localizedDescription
                    }
                }
            }
        }
        d.start(url)
    }

    func cancelDownload() {
        downloader?.cancel()
        downloader = nil
        if downloadName != nil { BackgroundKeeper.shared.end() }
        downloadName = nil
        setBusy(isGenerating)
    }

    func unloadModel() async {
        stop()
        await engine.unload()
        loadedModel = nil
        loadedInfo = nil
        loadedConfig = nil
        refreshMemory()
    }

    /// Loads the selected model if it is not already loaded with the current settings.
    private func ensureLoaded() async throws {
        guard let name = selectedModel, let file = models.first(where: { $0.name == name }) else {
            throw AppError.noModel
        }
        let config = engineConfig
        if loadedModel == name, loadedConfig == config { return }

        if loadedModel != nil {
            await engine.unload()
            loadedModel = nil
            loadedInfo = nil
        }
        refreshMemory()
        let room = memUsed + memFree
        if !defaults.bool(forKey: Keys.allowOversized), room > 0, UInt64(file.size) > room {
            throw AppError.tooBig(model: UInt64(file.size), room: room)
        }

        isLoading = true
        defer { isLoading = false }
        let info = try await engine.load(path: file.url.path, config: config)
        loadedModel = name
        loadedInfo = info
        loadedConfig = config
        refreshMemory()
    }

    // MARK: - Chats

    var current: Conversation {
        conversations.first(where: { $0.id == currentID }) ?? Conversation()
    }

    private func mutateCurrent(_ change: (inout Conversation) -> Void) {
        guard let i = conversations.firstIndex(where: { $0.id == currentID }) else { return }
        change(&conversations[i])
    }

    func newChat() {
        if let empty = conversations.first(where: { $0.messages.isEmpty }) {
            currentID = empty.id
            return
        }
        let chat = Conversation()
        conversations.insert(chat, at: 0)
        currentID = chat.id
    }

    func selectChat(_ id: UUID) {
        guard !isGenerating else { return }
        currentID = id
    }

    func deleteChat(_ id: UUID) {
        if isGenerating && id == currentID { stop() }
        conversations.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: chatURL(id))
        if id == currentID { newChat() }
    }

    private func chatURL(_ id: UUID) -> URL {
        Files.chats.appendingPathComponent("\(id.uuidString).json")
    }

    private func loadChats() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: Files.chats, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        conversations = urls
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(Conversation.self, from: Data(contentsOf: $0)) }
            .sorted { $0.updated > $1.updated }
    }

    private func save(_ id: UUID) {
        guard let chat = conversations.first(where: { $0.id == id }) else { return }
        guard !chat.messages.isEmpty, let data = try? JSONEncoder().encode(chat) else { return }
        try? data.write(to: chatURL(chat.id), options: .atomic)
    }

    // MARK: - Talking to the model

    func send(_ text: String, attachment: Attachment?) {
        guard !isGenerating else { return }
        guard remoteOn || selectedModel != nil else {
            errorText = AppError.noModel.errorDescription
            return
        }
        mutateCurrent { chat in
            if chat.messages.isEmpty {
                let base = text.isEmpty ? (attachment?.name ?? "New chat") : text
                chat.title = String(base.prefix(40))
            }
            chat.messages.append(ChatMessage(role: "user", text: text, attachmentName: attachment?.name, attachmentText: attachment?.text))
            chat.messages.append(ChatMessage(role: "assistant", text: ""))
            chat.updated = Date()
        }
        respond()
    }

    /// Drops the last reply and asks again.
    func regenerate() {
        guard !isGenerating, current.messages.last?.role == "assistant" else { return }
        mutateCurrent { chat in
            chat.messages[chat.messages.count - 1].text = ""
            chat.messages[chat.messages.count - 1].stats = nil
        }
        respond()
    }

    private func respond() {
        isGenerating = true
        setBusy(true)
        let chatID = currentID
        // A reply coming from the server can carry on while the app is in the background.
        let remote = remoteOn
        generatingRemotely = remote
        if remote { BackgroundKeeper.shared.begin() }
        genTask = Task {
            var pieces = 0
            let started = Date()
            var firstPiece: Date?
            do {
                var turns: [ChatTurn] = []
                let prompt = (defaults.string(forKey: Keys.promptText) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if defaults.bool(forKey: Keys.promptEnabled), !prompt.isEmpty {
                    turns.append(ChatTurn(role: "system", content: prompt))
                }
                for m in current.messages.dropLast() where !(m.role == "assistant" && m.text.isEmpty) {
                    turns.append(ChatTurn(role: m.role, content: m.promptContent))
                }

                let stream: AsyncThrowingStream<String, Error>
                if remoteOn {
                    stream = try RemoteClient.current().chat(turns: turns, sampling: samplingConfig)
                } else {
                    try await ensureLoaded()
                    try Task.checkCancellation()
                    stream = engine.generate(turns: turns, sampling: samplingConfig)
                }
                for try await piece in stream {
                    if firstPiece == nil { firstPiece = Date() }
                    pieces += 1
                    appendToReply(piece, chatID: chatID)
                }
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { errorText = error.localizedDescription }
            }
            if let firstPiece, pieces > 1 {
                let seconds = max(0.001, Date().timeIntervalSince(firstPiece))
                let wait = firstPiece.timeIntervalSince(started)
                let stats = String(format: "%.1f tokens/s · %.1fs to first word", Double(pieces) / seconds, wait)
                if let i = conversations.firstIndex(where: { $0.id == chatID }), let last = conversations[i].messages.indices.last {
                    conversations[i].messages[last].stats = stats
                }
            }
            // An empty reply (error or stopped before the first word) is not worth keeping.
            if let i = conversations.firstIndex(where: { $0.id == chatID }),
               let last = conversations[i].messages.last, last.role == "assistant", last.text.isEmpty {
                conversations[i].messages.removeLast()
            }
            isGenerating = false
            generatingRemotely = false
            setBusy(downloadName != nil || importStatus != nil)
            save(chatID)
            refreshMemory()
            if remote {
                let reply = conversations.first(where: { $0.id == chatID })?.messages.last
                if let reply, reply.role == "assistant", !reply.text.isEmpty {
                    BackgroundKeeper.shared.notify(title: "Reply ready", body: reply.text)
                } else if errorText != nil {
                    BackgroundKeeper.shared.notify(title: "The reply stopped", body: errorText ?? "")
                }
                BackgroundKeeper.shared.end()
            }
        }
    }

    private func appendToReply(_ piece: String, chatID: UUID) {
        guard let i = conversations.firstIndex(where: { $0.id == chatID }),
              let last = conversations[i].messages.indices.last else { return }
        conversations[i].messages[last].text += piece
    }

    func stop() {
        genTask?.cancel()
    }

    // MARK: - App lifecycle

    /// iOS does not allow GPU work in the background, so generation always stops; the model is freed if the setting is on.
    func didEnterBackground() {
        let app = UIApplication.shared
        var token = UIBackgroundTaskIdentifier.invalid
        token = app.beginBackgroundTask { app.endBackgroundTask(token) }

        // A reply from the server keeps streaming in the background. A reply from the on-phone model has to
        // stop, because iOS does not allow the GPU to be used by an app that is not on screen.
        let keepGoing = isGenerating && generatingRemotely && defaults.bool(forKey: Keys.keepAlive)
        let work = genTask
        if !keepGoing { stop() }
        Task {
            if !keepGoing { await work?.value }
            save(currentID)
            if defaults.bool(forKey: Keys.unloadOnBackground) {
                if keepGoing {
                    // Free the on-phone model without touching the server reply that is still running.
                    await engine.unload()
                    loadedModel = nil
                    loadedInfo = nil
                    loadedConfig = nil
                } else {
                    await unloadModel()
                }
            }
            app.endBackgroundTask(token)
        }
    }

    func didReceiveMemoryWarning() {
        guard !isGenerating, !isLoading, loadedModel != nil else { return }
        Task { await unloadModel() }
    }
}

enum AppError: LocalizedError {
    case noModel
    case tooBig(model: UInt64, room: UInt64)

    var errorDescription: String? {
        switch self {
        case .noModel:
            return "Add a model first: open the Models tab and import or download a .gguf file."
        case .tooBig(let model, let room):
            return "This model is \(Mem.text(model)), but iOS only gives this app about \(Mem.text(room)) on this phone. Use a smaller or more compressed version (for example Q4_K_M), or turn on \"Allow oversized models\" in Settings to try anyway."
        }
    }
}
