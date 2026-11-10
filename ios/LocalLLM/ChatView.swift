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
            Image(systemName: "cpu").font(.largeTitle).foregroundStyle(.secondary)
            if let model = app.selectedModel {
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

    private var isUser: Bool { message.role == "user" }

    var body: some View {
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
                        Button { app.shareFile(named: isUser ? "message" : "reply", text: message.text) } label: { Label("Send as a file", systemImage: "doc") }
                    }
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
