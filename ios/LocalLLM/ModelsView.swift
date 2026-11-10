import SwiftUI
import UniformTypeIdentifiers

struct ModelsView: View {
    @EnvironmentObject private var app: AppState
    @State private var showImporter = false
    @State private var link = ""

    var body: some View {
        NavigationStack {
            List {
                memorySection
                modelsSection
                addSection
            }
            .navigationTitle("Models")
            .refreshable { app.refreshModels() }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data]) { result in
                if case .success(let url) = result { app.importModel(from: url) }
            }
        }
    }

    private var memorySection: some View {
        Section {
            LabeledContent("App is using", value: Mem.text(app.memUsed))
            LabeledContent("Still available", value: Mem.text(app.memFree))
            if let name = app.loadedModel {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Loaded: \(name)").font(.subheadline)
                    if let info = app.loadedInfo {
                        Text("\(info.desc) · context \(info.ctxUsed) · \(info.gpu ? "GPU" : "CPU")\(info.compactKV ? " · compact memory" : "")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button("Unload to free memory", role: .destructive) {
                    Task { await app.unloadModel() }
                }
            } else {
                Text(app.isLoading ? "Loading…" : "No model loaded. It loads when you send a message.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Memory")
        } footer: {
            Text(String(format: "This phone has %.0f GB of memory. Model files up to about %.1f GB run well; bigger ones may be closed by iOS.", Mem.deviceGB.rounded(.up), Mem.deviceGB.rounded(.up) * 0.55))
        }
    }

    private var modelsSection: some View {
        Section {
            if app.models.isEmpty {
                Text("No models yet. Add a .gguf file below.").foregroundStyle(.secondary)
            }
            ForEach(app.models) { model in
                Button {
                    app.selectedModel = model.name
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.name).foregroundStyle(.primary).lineLimit(2)
                            Text(Mem.text(UInt64(model.size)) + (app.loadedModel == model.name ? " · loaded" : ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if app.selectedModel == model.name {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { app.deleteModel(model) } label: { Label("Delete", systemImage: "trash") }
                }
                .swipeActions(edge: .leading) {
                    Button { app.shareItem = ShareItem(url: model.url) } label: { Label("Send", systemImage: "square.and.arrow.up") }
                        .tint(.blue)
                }
            }
        } header: {
            Text("Your models")
        } footer: {
            Text("Tap to choose a model. Swipe left to delete, swipe right to send the file to another device or app.")
        }
    }

    private var addSection: some View {
        Section {
            if let status = app.importStatus {
                HStack(spacing: 8) { ProgressView(); Text(status).lineLimit(1) }
            } else {
                Button { showImporter = true } label: { Label("Import from Files", systemImage: "folder") }
            }

            if let name = app.downloadName {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Downloading \(name)").font(.subheadline).lineLimit(1)
                    if app.downloadTotal > 0 {
                        ProgressView(value: Double(app.downloadDone), total: Double(app.downloadTotal))
                        Text("\(Mem.text(UInt64(app.downloadDone))) of \(Mem.text(UInt64(app.downloadTotal)))")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                    }
                    Button("Cancel", role: .destructive) { app.cancelDownload() }
                }
            } else {
                TextField("Link to a .gguf file", text: $link)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Button { app.startDownload(link); link = "" } label: { Label("Download from link", systemImage: "arrow.down.circle") }
                    .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Add a model")
        } footer: {
            Text("Importing copies the file into the app. To skip the copy, move .gguf files straight into On My iPhone › Local LLM › Models in the Files app, then pull down here to refresh. Keep the app open during a download.")
        }
    }
}
