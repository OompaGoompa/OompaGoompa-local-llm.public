import Foundation
import Security
import SwiftUI
import UIKit

/// Small wrapper for keeping the server key out of plain settings.
enum Keychain {
    private static func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "localllm", kSecAttrAccount as String: key]
    }

    static func set(_ value: String, for key: String) {
        SecItemDelete(query(key) as CFDictionary)
        guard !value.isEmpty else { return }
        var item = query(key)
        item[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }

    static func get(_ key: String) -> String {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

enum RemoteError: LocalizedError {
    case badAddress, noModel, http(Int, String), noModels

    var errorDescription: String? {
        switch self {
        case .badAddress: return "The server address is not valid. It should look like http://192.168.1.20:11434"
        case .noModel: return "Choose a model for the remote server in Settings › Remote server."
        case .http(let code, let body):
            let hint = code == 401 || code == 403 ? " Check the key." : (code == 404 ? " Check the address and the model name." : "")
            return "The server answered with error \(code).\(hint) \(body.prefix(200))"
        case .noModels: return "The server answered but listed no models."
        }
    }
}

/// Talks to a model running on another computer through the OpenAI-style API that Ollama, LM Studio,
/// llama.cpp's server and most hosted services share.
struct RemoteClient {
    let base: URL
    let key: String
    let model: String

    /// Accepts "192.168.1.20:11434", "http://host:1234/", "https://api.example.com/v1" and returns the API root.
    static func normalize(_ text: String) -> URL? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard var url = URL(string: s), url.host != nil else { return nil }
        if url.path.isEmpty || url.path == "/" { url = url.appendingPathComponent("v1") }
        return url
    }

    static func current(requireModel: Bool = true) throws -> RemoteClient {
        let defaults = UserDefaults.standard
        guard let base = normalize(defaults.string(forKey: Keys.remoteURL) ?? "") else { throw RemoteError.badAddress }
        let model = defaults.string(forKey: Keys.remoteModel) ?? ""
        if requireModel && model.isEmpty { throw RemoteError.noModel }
        return RemoteClient(base: base, key: Keychain.get(Keys.remoteKey), model: model)
    }

    private func request(_ path: String) -> URLRequest {
        var r = URLRequest(url: base.appendingPathComponent(path))
        r.timeoutInterval = 300
        if !key.isEmpty { r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        return r
    }

    func models() async throws -> [String] {
        var r = request("models")
        r.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: r)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw RemoteError.http(http.statusCode, String(decoding: data.prefix(300), as: UTF8.self))
        }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let list = (object?["data"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
        guard !list.isEmpty else { throw RemoteError.noModels }
        return list.sorted()
    }

    func chat(turns: [ChatTurn], sampling: SamplingConfig) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var r = request("chat/completions")
                    r.httpMethod = "POST"
                    r.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    let body: [String: Any] = [
                        "model": model,
                        "stream": true,
                        "messages": turns.map { ["role": $0.role, "content": $0.content] },
                        "max_tokens": Int(sampling.maxTokens),
                        "temperature": Double(sampling.temperature),
                        "top_p": Double(sampling.topP)
                    ]
                    r.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: r)
                    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                        var text = ""
                        for try await line in bytes.lines {
                            text += line
                            if text.count > 300 { break }
                        }
                        throw RemoteError.http(http.statusCode, text)
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choices = object["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any],
                              let piece = delta["content"] as? String, !piece.isEmpty else { continue }
                        continuation.yield(piece)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Settings screen for running the model on another computer.
struct RemoteView: View {
    @AppStorage(Keys.remoteEnabled) private var enabled = false
    @AppStorage(Keys.remoteURL) private var address = ""
    @AppStorage(Keys.remoteModel) private var model = ""
    @State private var key = ""
    @State private var found: [String] = []
    @State private var status = ""
    @State private var busy = false

    var body: some View {
        Form {
            Section {
                Toggle("Run on another computer", isOn: $enabled)
            } footer: {
                Text("When on, chats are sent to the server below instead of the model on this phone. Use it for models too big for the phone. Your messages leave the phone and go to that server.")
            }

            Section {
                NavigationLink("New server (no login needed)") {
                    NewServerView { chosen in
                        address = chosen
                        connect()
                    }
                }
                NavigationLink("Existing server (one command)") {
                    ServerSetupView { chosen in
                        address = chosen
                        connect()
                    }
                }
            } header: {
                Text("Set up my own server")
            } footer: {
                Text("For a cloud VM such as Oracle's, using only this phone.")
            }

            Section {
                TextField("http://192.168.1.20:11434", text: $address)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                SecureField("Key (only if the server needs one)", text: $key)
                    .onChange(of: key) { Keychain.set($0, for: Keys.remoteKey) }
                Button {
                    connect()
                } label: {
                    HStack {
                        Text("Connect and list models")
                        if busy { Spacer(); ProgressView() }
                    }
                }
                .disabled(busy || address.trimmingCharacters(in: .whitespaces).isEmpty)
                if !status.isEmpty { Text(status).font(.footnote).foregroundStyle(.secondary) }
            } header: {
                Text("Server")
            }

            Section {
                NavigationLink("Server models (add or remove)") {
                    ServerModelsView()
                }
                .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
            } footer: {
                Text("Download more models onto your own server, straight from here. Works with servers set up by this app (Ollama).")
            }

            Section {
                if found.isEmpty {
                    TextField("Model name", text: $model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } else {
                    Picker("Model", selection: $model) {
                        if !found.contains(model) { Text(model.isEmpty ? "Choose…" : model).tag(model) }
                        ForEach(found, id: \.self) { Text($0).tag($0) }
                    }
                }
            } header: {
                Text("Model")
            } footer: {
                Text("""
                    On your computer, start one of these, then enter its address with the computer's IP:
                    • Ollama: port 11434. Set OLLAMA_HOST=0.0.0.0 so other devices can reach it.
                    • LM Studio: Developer › start server, turn on "Serve on local network". Port 1234.
                    • llama.cpp: llama-server --host 0.0.0.0. Port 8080.
                    The phone and computer must be on the same Wi-Fi (or the same VPN, such as Tailscale, to use it away from home). Hosted services that use the OpenAI format work too, with their address and key.
                    """)
            }
        }
        .navigationTitle("Remote server")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { key = Keychain.get(Keys.remoteKey) }
    }

    private func connect() {
        busy = true
        status = ""
        Task {
            do {
                let list = try await RemoteClient.current(requireModel: false).models()
                found = list
                if !list.contains(model) { model = list.count == 1 ? list[0] : "" }
                status = "Connected. \(list.count) model\(list.count == 1 ? "" : "s") available."
            } catch {
                found = []
                status = error.localizedDescription
            }
            busy = false
        }
    }
}

/// Walks through turning a cloud VM into a private model server using only the phone.
struct ServerSetupView: View {
    @Environment(\.dismiss) private var dismiss
    let onUse: (String) -> Void
    @State private var copied = false
    @State private var manualIP = ""

    static let command = "curl -fsSL https://raw.githubusercontent.com/OompaGoompa/OompaGoompa-local-llm.public/app/server/setup.sh | bash"

    var body: some View {
        Form {
            Section {
                step(1, "Get two free apps from the App Store", "Tailscale (a private link between your phone and the server) and an SSH app such as Termius (to type one command on the server).")
                step(2, "Add your server in the SSH app", "Address: the server's public IP from your cloud console. Username: ubuntu on Ubuntu, opc on Oracle Linux. Key: the private key file you saved when you created the server.")
                step(3, "Connect and paste this command", "It installs everything and downloads a model sized for the server. It takes about 5 to 15 minutes.")
                Text(Self.command).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                Button {
                    UIPasteboard.general.string = Self.command
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy the command", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                step(4, "Sign in to Tailscale when a link appears", "The command pauses and shows a link. Open it and sign in. Then open the Tailscale app on this phone, sign in with the same account and switch it on.")
                step(5, "Connect this app", "When the command says Done, tap the button below.")
            } header: {
                Text("One-time setup")
            }

            Section {
                Button("Use my server") {
                    onUse("http://llm-server:11434")
                    dismiss()
                }
            } footer: {
                Text("Keep Tailscale switched on whenever you chat with the server.")
            }

            Section {
                TextField("100.x.y.z", text: $manualIP)
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
                Button("Use this address instead") {
                    onUse("http://\(manualIP.trimmingCharacters(in: .whitespaces)):11434")
                    dismiss()
                }
                .disabled(manualIP.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: {
                Text("If it does not connect")
            } footer: {
                Text("Enter the 100.x.y.z address the command printed at the end. It is also shown next to llm-server in the Tailscale app.")
            }
        }
        .navigationTitle("Server setup")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func step(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)").font(.headline).frame(width: 22, height: 22).background(Color.accentColor.opacity(0.2), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

/// For a brand-new cloud VM: builds a startup script that makes the server set itself up on first boot.
struct NewServerView: View {
    @Environment(\.dismiss) private var dismiss
    let onUse: (String) -> Void
    @State private var authKey = ""
    @State private var copied = false
    @State private var manualIP = ""

    private var cleanKey: String {
        authKey.components(separatedBy: .whitespacesAndNewlines).joined()
    }

    private var keyLooksRight: Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return cleanKey.hasPrefix("tskey-") && cleanKey.count > 20 && cleanKey.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private var script: String {
        """
        #!/bin/bash
        # Local LLM server: sets itself up on first boot. Progress is written to /var/log/llm-setup.log
        export HOME=/root
        for i in 1 2 3 4 5 6 7 8 9 10; do
          curl -fsSL https://raw.githubusercontent.com/OompaGoompa/OompaGoompa-local-llm.public/app/server/setup.sh -o /root/llm-setup.sh && break
          sleep 15
        done
        TS_AUTHKEY='\(cleanKey)' bash /root/llm-setup.sh > /var/log/llm-setup.log 2>&1
        """
    }

    var body: some View {
        Form {
            Section {
                Text("1. In the Tailscale app or at login.tailscale.com, sign in. On the website open Settings › Keys and tap Generate auth key. Leave the options as they are and copy the key (it starts with tskey-auth).")
                    .font(.footnote)
                SecureField("Paste the tskey-auth key here", text: $authKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !authKey.isEmpty && !keyLooksRight {
                    Text("That does not look like a Tailscale auth key.").font(.footnote).foregroundStyle(.red)
                }
            } header: {
                Text("Tailscale key")
            }

            Section {
                Button {
                    UIPasteboard.general.string = script
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy startup script", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .disabled(!keyLooksRight)
                Text("2. When creating the VM, open the advanced options, find \"Initialization script\", choose to paste a script, and paste this in. Then create the VM.")
                    .font(.footnote)
            } header: {
                Text("Startup script")
            } footer: {
                Text("The script contains your Tailscale key, so paste it only into your own cloud console.")
            }

            Section {
                Text("3. Wait 10 to 15 minutes while the server installs everything and downloads a model. Turn on the Tailscale app on this phone, then tap below.")
                    .font(.footnote)
                Button("Use my server") {
                    onUse("http://llm-server:11434")
                    dismiss()
                }
            } header: {
                Text("Connect")
            } footer: {
                Text("If it says it cannot connect, the server is probably still setting up. Wait a few minutes and try again. In Tailscale's website, turn off key expiry for llm-server so it stays connected.")
            }

            Section {
                TextField("100.x.y.z", text: $manualIP)
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
                Button("Use this address instead") {
                    onUse("http://\(manualIP.trimmingCharacters(in: .whitespaces)):11434")
                    dismiss()
                }
                .disabled(manualIP.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: {
                Text("If it still does not connect")
            } footer: {
                Text("Enter the 100.x.y.z address shown next to llm-server in the Tailscale app.")
            }
        }
        .navigationTitle("New server")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Talks to Ollama's own management API on the server: list, download and delete models.
struct OllamaAdmin {
    let root: URL

    static func current() throws -> OllamaAdmin {
        guard let base = RemoteClient.normalize(UserDefaults.standard.string(forKey: Keys.remoteURL) ?? "") else {
            throw RemoteError.badAddress
        }
        return OllamaAdmin(root: base.lastPathComponent == "v1" ? base.deletingLastPathComponent() : base)
    }

    struct Item: Identifiable {
        var id: String { name }
        let name: String
        let size: Int64
    }

    struct Progress {
        let status: String
        let fraction: Double?
    }

    private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) throws -> URLRequest {
        var r = URLRequest(url: root.appendingPathComponent(path))
        r.httpMethod = method
        r.timeoutInterval = 600
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return r
    }

    func list() async throws -> [Item] {
        var r = try request("api/tags")
        r.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: r)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw RemoteError.http(http.statusCode, "This server does not look like Ollama.")
        }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let models = object?["models"] as? [[String: Any]] ?? []
        return models.compactMap { m in
            guard let name = m["name"] as? String else { return nil }
            return Item(name: name, size: (m["size"] as? NSNumber)?.int64Value ?? 0)
        }.sorted { $0.name < $1.name }
    }

    func delete(_ name: String) async throws {
        let r = try request("api/delete", method: "DELETE", body: ["model": name, "name": name])
        let (data, response) = try await URLSession.shared.data(for: r)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw RemoteError.http(http.statusCode, String(decoding: data.prefix(200), as: UTF8.self))
        }
    }

    func pull(_ name: String) -> AsyncThrowingStream<Progress, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let r = try request("api/pull", method: "POST", body: ["model": name, "name": name, "stream": true])
                    let (bytes, response) = try await URLSession.shared.bytes(for: r)
                    let failed = (response as? HTTPURLResponse).map { !(200...299).contains($0.statusCode) } ?? false
                    for try await line in bytes.lines {
                        guard let data = line.data(using: .utf8),
                              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        if let message = object["error"] as? String {
                            throw PullError.server(message)
                        }
                        let status = object["status"] as? String ?? ""
                        var fraction: Double?
                        if let total = (object["total"] as? NSNumber)?.doubleValue, total > 0 {
                            fraction = ((object["completed"] as? NSNumber)?.doubleValue ?? 0) / total
                        }
                        continuation.yield(Progress(status: status, fraction: fraction))
                    }
                    if failed { throw PullError.server("The server refused the download.") }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

enum PullError: LocalizedError {
    case server(String)
    var errorDescription: String? {
        switch self {
        case .server(let message):
            if message.contains("not found") || message.contains("does not exist") || message.contains("manifest") {
                return "The server could not find a model with that name. Check the spelling, including the part after the colon."
            }
            return message
        }
    }
}

struct ServerModelsView: View {
    @AppStorage(Keys.remoteModel) private var selected = ""
    @State private var items: [OllamaAdmin.Item] = []
    @State private var status = "Loading…"
    @State private var name = ""
    @State private var pulling: String?
    @State private var pullStatus = ""
    @State private var fraction: Double?
    @State private var pullTask: Task<Void, Never>?

    private let suggestions = [
        ("llama3.2:3b", "Small and quick, about 2 GB"),
        ("gemma3:4b", "Small, about 3 GB"),
        ("qwen2.5:7b", "Mid-size, about 5 GB; needs 8 GB of server memory"),
        ("qwen2.5:14b", "Large, about 9 GB; needs 16 GB of server memory")
    ]

    var body: some View {
        Form {
            Section {
                if items.isEmpty { Text(status).foregroundStyle(.secondary) }
                ForEach(items) { item in
                    Button {
                        selected = item.name
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name).foregroundStyle(.primary)
                                Text(Mem.text(UInt64(max(0, item.size)))).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if selected == item.name { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) { remove(item.name) } label: { Label("Delete", systemImage: "trash") }
                    }
                }
            } header: {
                Text("On the server")
            } footer: {
                Text("Tap a model to chat with it. Swipe left to delete it from the server.")
            }

            Section {
                if let pulling {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Downloading \(pulling) to the server").font(.subheadline)
                        if let fraction {
                            ProgressView(value: min(1, max(0, fraction)))
                            Text(String(format: "%.0f%%  %@", fraction * 100, pullStatus)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        } else {
                            HStack(spacing: 8) { ProgressView(); Text(pullStatus).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        }
                        Button("Cancel", role: .destructive) { pullTask?.cancel() }
                    }
                } else {
                    TextField("Model name, e.g. qwen2.5:7b", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button { add(name) } label: { Label("Download to server", systemImage: "arrow.down.circle") }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Add a model")
            } footer: {
                Text("Use a name from ollama.com/library. For a GGUF file on Hugging Face, type hf.co/ followed by the repository, a colon and the version, for example hf.co/bartowski/Llama-3.2-3B-Instruct-GGUF:Q4_K_M. Keep this screen open while it downloads; if it is interrupted, starting again continues where it stopped.")
            }

            if pulling == nil {
                Section {
                    ForEach(suggestions, id: \.0) { suggestion in
                        Button { add(suggestion.0) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(suggestion.0).foregroundStyle(.primary)
                                Text(suggestion.1).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Suggestions")
                }
            }
        }
        .navigationTitle("Server models")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Something went wrong", isPresented: Binding(get: { lastError != nil }, set: { if !$0 { lastError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(lastError ?? "")
        }
        .task { await refresh() }
        .refreshable { await refresh() }
        .onDisappear { pullTask?.cancel() }
    }

    private func refresh() async {
        do {
            items = try await OllamaAdmin.current().list()
            status = items.isEmpty ? "No models on the server yet." : ""
        } catch {
            items = []
            status = error.localizedDescription
        }
    }

    private func add(_ raw: String) {
        let model = raw.trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty, pulling == nil else { return }
        pulling = model
        pullStatus = "Starting…"
        fraction = nil
        UIApplication.shared.isIdleTimerDisabled = true
        pullTask = Task {
            var failure: String?
            do {
                for try await progress in try OllamaAdmin.current().pull(model) {
                    pullStatus = progress.status
                    fraction = progress.fraction
                }
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { failure = error.localizedDescription }
            }
            UIApplication.shared.isIdleTimerDisabled = false
            pulling = nil
            name = ""
            await refresh()
            if let failure {
                lastError = failure
            } else if items.contains(where: { $0.name == model }) {
                selected = model
            }
        }
    }

    @State private var lastError: String?

    private func remove(_ model: String) {
        Task {
            do {
                try await OllamaAdmin.current().delete(model)
                if selected == model { selected = "" }
            } catch {
                lastError = error.localizedDescription
            }
            await refresh()
        }
    }
}
