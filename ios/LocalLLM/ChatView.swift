import SwiftUI
import UniformTypeIdentifiers

struct ChatView: View {
    @EnvironmentObject private var app: AppState
    @State private var input = ""
    @State private var attachment: Attachment?
    @State private var showFilePicker = false
    @State private var showChats = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                messages
                statusLine
                inputBar
            }
            .navigationTitle(app.current.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showChats = true } label: { Image(systemName: "list.bullet") }
                        .accessibilityLabel("Chats")
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button { app.shareFile(named: app.current.title, text: app.current.asText) } label: { Image(systemName: "square.and.arrow.up") }
                        .disabled(app.current.messages.isEmpty || app.isGenerating)
                        .accessibilityLabel("Send chat as a file")
                    Button { app.newChat() } label: { Image(systemName: "square.and.pencil") }
                        .disabled(app.isGenerating)
                        .accessibilityLabel("New chat")
                }
            }
            .sheet(isPresented: $showChats) { ChatListView() }
            .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.text, .pdf, .json, .xml, .data]) { result in
                guard case .success(let url) = result else { return }
                do {
                    attachment = try Files.readAttachment(url, maxChars: app.attachmentCharLimit)
                } catch {
                    app.errorText = error.localizedDescription
                }
            }
        }
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if app.current.messages.isEmpty { emptyState }
                    ForEach(app.current.messages) { message in
                        MessageRow(message: message, isLast: message.id == app.current.messages.last?.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: app.current.messages.last?.text) { _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: app.currentID) { _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: app.remoteOn ? "network" : "cpu").font(.largeTitle).foregroundStyle(.secondary)
            if app.remoteOn {
                Text(app.remoteModelName.isEmpty ? "Remote server" : app.remoteModelName).font(.headline).multilineTextAlignment(.center)
                Text("Runs on your remote server. Messages are sent there.").font(.footnote).foregroundStyle(.secondary)
            } else if let model = app.selectedModel {
                Text(model).font(.headline).multilineTextAlignment(.center)
                Text("Runs entirely on this phone. Nothing leaves it.").font(.footnote).foregroundStyle(.secondary)
            } else {
                Text("No model yet").font(.headline)
                Text("Open the Models tab to import or download a .gguf model.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    @ViewBuilder private var statusLine: some View {
        if app.isLoading {
            HStack(spacing: 8) {
                ProgressView()
                Text("Loading \(app.selectedModel ?? "model")…").font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.vertical, 6)
        }
    }

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let attachment {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text")
                    Text(attachment.name).lineLimit(1)
                    if attachment.wasCut { Text("(cut to fit)").foregroundStyle(.secondary) }
                    Spacer()
                    Button { self.attachment = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Remove file")
                }
                .font(.footnote)
                .padding(8)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
            }
            HStack(alignment: .bottom, spacing: 8) {
                Button { showFilePicker = true } label: { Image(systemName: "paperclip").font(.title3) }
                    .disabled(app.isGenerating)
                    .accessibilityLabel("Attach a file")
                    .padding(.bottom, 6)
                TextField("Message", text: $input, axis: .vertical)
                    .lineLimit(1...6)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                    .focused($inputFocused)
                if app.isGenerating {
                    Button { app.stop() } label: { Image(systemName: "stop.circle.fill").font(.title) }
                        .tint(.red)
                        .accessibilityLabel("Stop")
                } else {
                    Button { sendNow() } label: { Image(systemName: "arrow.up.circle.fill").font(.title) }
                        .disabled(!canSend)
                        .accessibilityLabel("Send")
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var canSend: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachment != nil
    }

    private func sendNow() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        app.send(text, attachment: attachment)
        input = ""
        attachment = nil
    }
}

struct MessageRow: View {
    @EnvironmentObject private var app: AppState
    let message: ChatMessage
    let isLast: Bool

    @State private var showFiles = false
    @State private var viewing: ViewedModel?
    @State private var building = false
    @State private var buildError: String?
    @State private var buildErrorIsCode = false

    private var isUser: Bool { message.role == "user" }

    var body: some View {
        let files = replyFiles
        let fileCount = files.count
        let model = files.first(where: { $0.mesh != nil })
        let scad = files.last(where: { $0.isScad })
        VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
            if let name = message.attachmentName {
                Label(name, systemImage: "doc.text").font(.caption).foregroundStyle(.secondary)
            }
            if message.text.isEmpty && !isUser {
                ProgressView().padding(10)
            } else if !message.text.isEmpty {
                bubbleContent
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .foregroundStyle(isUser ? Color.white : Color.primary)
                    .background(isUser ? Color.accentColor : Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                    .contextMenu {
                        Button { UIPasteboard.general.string = message.text } label: { Label("Copy", systemImage: "doc.on.doc") }
                        ShareLink(item: message.text) { Label("Share text", systemImage: "square.and.arrow.up") }
                        Button { showFiles = true } label: { Label("Save as file…", systemImage: "square.and.arrow.down") }
                    }
            }
            if fileCount > 0 {
                HStack(spacing: 8) {
                    if let model, let mesh = model.mesh {
                        Button { viewing = ViewedModel(mesh: mesh, title: model.name) } label: {
                            Label("View in 3D", systemImage: "rotate.3d")
                        }
                    }
                    if let scad {
                        Button { build(scad) } label: {
                            if building {
                                HStack(spacing: 6) { ProgressView(); Text("Building…") }
                            } else {
                                Label("Build 3D model", systemImage: "cube")
                            }
                        }
                        .disabled(building)
                    }
                    Button { showFiles = true } label: {
                        Label(fileCount == 1 ? "Save as file" : "Save as files (\(fileCount))", systemImage: "square.and.arrow.down")
                    }
                }
                .font(.caption)
                .buttonStyle(.bordered)
            }
            if !isUser, isLast, !app.isGenerating, !message.text.isEmpty {
                HStack(spacing: 12) {
                    if let stats = message.stats { Text(stats) }
                    Button { app.regenerate() } label: { Label("Retry", systemImage: "arrow.clockwise") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .sheet(isPresented: $showFiles) { SaveFilesView(replyText: message.text) }
        .sheet(item: $viewing) { model in
            ModelPreviewView(mesh: model.mesh, title: model.title)
        }
        .alert("The 3D model could not be built", isPresented: Binding(get: { buildError != nil }, set: { if !$0 { buildError = nil } })) {
            if buildErrorIsCode {
                Button("Ask the AI to fix it") {
                    let message = "OpenSCAD could not build that code. It reported:\n\n\(buildError ?? "")\n\nFix the problem and send the full corrected OpenSCAD code in one code block."
                    app.send(message, attachment: nil)
                }
            }
            Button("Copy the message") { UIPasteboard.general.string = buildError }
            Button("OK", role: .cancel) {}
        } message: {
            Text(String((buildError ?? "").suffix(600)))
        }
    }

    /// Sends the OpenSCAD code to the server's 3D builder and opens the result in the viewer.
    private func build(_ file: ReplyFile) {
        building = true
        Task {
            do {
                let mesh = try await CadClient.render(file.content)
                viewing = ViewedModel(mesh: mesh, title: file.name)
            } catch let error as CadError {
                if case .build = error { buildErrorIsCode = true } else { buildErrorIsCode = false }
                buildError = error.localizedDescription
            } catch {
                buildErrorIsCode = false
                buildError = error.localizedDescription
            }
            building = false
        }
    }

    /// The code or data blocks the reply holds. Skipped while the reply is still being written.
    private var replyFiles: [ReplyFile] {
        guard !isUser, !message.text.isEmpty, !(isLast && app.isGenerating), message.text.contains("```") else { return [] }
        return ReplyFiles.extract(from: message.text)
    }

    /// Ordinary text and code blocks are shown differently: code keeps its line breaks and scrolls sideways.
    @ViewBuilder private var bubbleContent: some View {
        let parts = isUser ? [ReplyPart(id: 0, isCode: false, text: message.text)] : ReplyPart.split(message.text)
        if parts.count == 1, !parts[0].isCode {
            Text(Self.markdown(parts[0].text))
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(parts) { part in
                    if part.isCode {
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(part.text).font(.system(.footnote, design: .monospaced))
                        }
                        .padding(8)
                        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                    } else {
                        Text(Self.markdown(part.text))
                    }
                }
            }
        }
    }

    /// Bold, italics, inline code and links are shown; anything that is not valid Markdown stays as plain text.
    private static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

struct ChatListView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(app.conversations.filter { !$0.messages.isEmpty }) { chat in
                    Button {
                        app.selectChat(chat.id)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(chat.title).lineLimit(1).foregroundStyle(.primary)
                            Text(chat.updated, style: .date).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) { app.deleteChat(chat.id) } label: { Label("Delete", systemImage: "trash") }
                    }
                }
            }
            .overlay {
                if app.conversations.allSatisfy({ $0.messages.isEmpty }) {
                    Text("No saved chats yet").foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Chats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

/// A stretch of a reply: either ordinary text or the inside of a ``` code block.
struct ReplyPart: Identifiable {
    let id: Int
    let isCode: Bool
    let text: String

    static func split(_ text: String) -> [ReplyPart] {
        var parts: [ReplyPart] = []
        var lines: [String] = []
        var inCode = false

        func flush() {
            let joined = lines.joined(separator: "\n")
            lines = []
            let shown = inCode ? joined : joined.trimmingCharacters(in: .whitespacesAndNewlines)
            if !shown.isEmpty { parts.append(ReplyPart(id: parts.count, isCode: inCode, text: shown)) }
        }

        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                flush()
                inCode.toggle()
            } else {
                lines.append(line)
            }
        }
        flush()
        return parts.isEmpty ? [ReplyPart(id: 0, isCode: false, text: text)] : parts
    }
}
