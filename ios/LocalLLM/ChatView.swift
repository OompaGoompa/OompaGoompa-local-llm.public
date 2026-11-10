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

    private var isUser: Bool { message.role == "user" }

    var body: some View {
        let files = replyFiles
        let fileCount = files.count
        let model = files.first(where: { $0.mesh != nil })
        VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
            if let name = message.attachmentName {
                Label(name, systemImage: "doc.text").font(.caption).foregroundStyle(.secondary)
            }
            if message.text.isEmpty && !isUser {
                ProgressView().padding(10)
            } else if !message.text.isEmpty {
                Text(rendered)
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
    }

    /// The code or data blocks the reply holds. Skipped while the reply is still being written.
    private var replyFiles: [ReplyFile] {
        guard !isUser, !message.text.isEmpty, !(isLast && app.isGenerating), message.text.contains("```") else { return [] }
        return ReplyFiles.extract(from: message.text)
    }

    /// Bold, italics, code and links are shown; anything that is not valid Markdown stays as plain text.
    private var rendered: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: message.text, options: options)) ?? AttributedString(message.text)
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
