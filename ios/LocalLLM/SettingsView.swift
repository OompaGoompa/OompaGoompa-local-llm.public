import SwiftUI

struct SettingsView: View {
    @AppStorage(Keys.contextSize) private var contextSize = 2048
    @AppStorage(Keys.useGPU) private var useGPU = true
    @AppStorage(Keys.threads) private var threads = Keys.defaultThreads
    @AppStorage(Keys.compactKV) private var compactKV = false
    @AppStorage(Keys.template) private var template = ""
    @AppStorage(Keys.unloadOnBackground) private var unloadOnBackground = true
    @AppStorage(Keys.allowOversized) private var allowOversized = false
    @AppStorage(Keys.temperature) private var temperature = 0.7
    @AppStorage(Keys.topP) private var topP = 0.9
    @AppStorage(Keys.repeatPenalty) private var repeatPenalty = 1.1
    @AppStorage(Keys.maxTokens) private var maxTokens = 512
    @AppStorage(Keys.promptEnabled) private var promptEnabled = true
    @AppStorage(Keys.remoteEnabled) private var remoteEnabled = false

    private let templates = ["chatml", "llama3", "llama4", "gemma", "phi3", "phi4", "mistral-v3", "mistral-v7", "deepseek3", "zephyr", "vicuna", "granite", "gpt-oss"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        PromptView()
                    } label: {
                        LabeledContent("Prompt", value: promptEnabled ? "On" : "Off")
                    }
                } footer: {
                    Text("A fixed instruction the AI follows in every chat.")
                }

                Section {
                    NavigationLink {
                        RemoteView()
                    } label: {
                        LabeledContent("Remote server", value: remoteEnabled ? "On" : "Off")
                    }
                } footer: {
                    Text("Run bigger models on your own computer or a hosted service and chat with them from here.")
                }

                Section {
                    Picker("Context size", selection: $contextSize) {
                        ForEach([1024, 2048, 4096, 8192], id: \.self) { Text("\($0) tokens").tag($0) }
                    }
                    Toggle("Compact working memory", isOn: $compactKV)
                    Toggle("Free memory when leaving the app", isOn: $unloadOnBackground)
                    Toggle("Use the GPU", isOn: $useGPU)
                    Stepper("CPU threads: \(threads)", value: $threads, in: 1...8)
                    Toggle("Allow oversized models", isOn: $allowOversized)
                } header: {
                    Text("Memory and load (on this phone)")
                } footer: {
                    Text("Context size is how much conversation the model keeps in mind: smaller uses less memory, and the oldest messages are forgotten once it is full. Compact working memory stores that conversation in 8-bit form, about half the size (experimental; it is skipped if the model does not support it). The GPU is faster and easier on the battery. Changes apply on the next message.")
                }

                Section {
                    Picker("Longest reply", selection: $maxTokens) {
                        ForEach([128, 256, 512, 1024, 2048], id: \.self) { Text("\($0) tokens").tag($0) }
                    }
                    VStack(alignment: .leading) {
                        Text(String(format: "Creativity (temperature): %.2f", temperature))
                        Slider(value: $temperature, in: 0...1.5, step: 0.05)
                    }
                    VStack(alignment: .leading) {
                        Text(String(format: "Word variety (top-p): %.2f", topP))
                        Slider(value: $topP, in: 0.1...1, step: 0.05)
                    }
                    VStack(alignment: .leading) {
                        Text(String(format: "Repeat penalty: %.2f", repeatPenalty))
                        Slider(value: $repeatPenalty, in: 1...1.5, step: 0.05)
                    }
                } header: {
                    Text("Replies")
                }

                Section {
                    Picker("Chat format", selection: $template) {
                        Text("Automatic (from the model)").tag("")
                        ForEach(templates, id: \.self) { Text($0).tag($0) }
                    }
                } footer: {
                    Text("Leave on Automatic unless replies come out garbled or never stop; then pick the format your model was trained with.")
                }

                Section {
                    LabeledContent("Engine", value: "llama.cpp")
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                } header: {
                    Text("About")
                } footer: {
                    Text("Everything runs on this phone. Chats are stored in On My iPhone › Local LLM › Chats.")
                }
            }
            .navigationTitle("Settings")
        }
    }
}

/// The fixed (system) prompt, plus saved prompts to switch between.
struct PromptView: View {
    @AppStorage(Keys.promptEnabled) private var enabled = true
    @AppStorage(Keys.promptText) private var text = ""
    @AppStorage(Keys.promptPresets) private var presetsData = Data()
    @State private var showNameAlert = false
    @State private var newName = ""

    private var presets: [PromptPreset] {
        (try? JSONDecoder().decode([PromptPreset].self, from: presetsData)) ?? []
    }

    private func store(_ list: [PromptPreset]) {
        presetsData = (try? JSONEncoder().encode(list)) ?? Data()
    }

    var body: some View {
        Form {
            Section {
                Toggle("Use this prompt", isOn: $enabled)
                TextEditor(text: $text)
                    .frame(minHeight: 180)
                    .disabled(!enabled)
                    .opacity(enabled ? 1 : 0.5)
            } header: {
                Text("Fixed prompt")
            } footer: {
                Text("Sent to the AI ahead of every conversation: who it should be, how it should answer, what to avoid. It applies from your next message.")
            }

            Section {
                Button {
                    text = CadClient.designerPrompt
                    enabled = true
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("3D designer (OpenSCAD)").foregroundStyle(.primary)
                            Text("Makes the AI answer with OpenSCAD code for the 3D builder.").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if text == CadClient.designerPrompt { Image(systemName: "checkmark").foregroundStyle(.tint) }
                    }
                }
                Button {
                    text = "You are a helpful assistant."
                    enabled = true
                } label: {
                    HStack {
                        Text("General assistant").foregroundStyle(.primary)
                        Spacer()
                        if text == "You are a helpful assistant." { Image(systemName: "checkmark").foregroundStyle(.tint) }
                    }
                }
            } header: {
                Text("Ready-made prompts")
            }

            Section {
                Button("Save current prompt…") {
                    newName = ""
                    showNameAlert = true
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                ForEach(presets) { preset in
                    Button {
                        text = preset.text
                        enabled = true
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.name).foregroundStyle(.primary)
                                Text(preset.text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer()
                            if preset.text == text { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                    }
                }
                .onDelete { offsets in
                    var list = presets
                    list.remove(atOffsets: offsets)
                    store(list)
                }
            } header: {
                Text("Saved prompts")
            } footer: {
                Text("Tap a saved prompt to use it. Swipe left to delete.")
            }
        }
        .navigationTitle("Prompt")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Clear") { text = "" }.disabled(text.isEmpty)
            }
        }
        .alert("Name this prompt", isPresented: $showNameAlert) {
            TextField("Name", text: $newName)
            Button("Save") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                store(presets + [PromptPreset(name: name.isEmpty ? "Prompt \(presets.count + 1)" : name, text: text)])
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}
