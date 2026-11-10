import SwiftUI
import UIKit

enum CadError: LocalizedError {
    case noServer
    case unreachable(String)
    case build(String)
    case empty

    var errorDescription: String? {
        switch self {
        case .noServer:
            return "Set up your remote server first (Settings › Remote server). The 3D builder runs on it."
        case .unreachable(let detail):
            return "The 3D builder on your server did not answer. Check that Tailscale is on and that the 3D builder is installed (Settings › Remote server › 3D builder). \(detail)"
        case .build(let message):
            return message
        case .empty:
            return "The code ran but produced no shape."
        }
    }
}

/// Sends OpenSCAD code to the converter on the user's server and gets a finished shape back.
enum CadClient {
    static let port = 11435

    static func baseURL() throws -> URL {
        guard let api = RemoteClient.normalize(UserDefaults.standard.string(forKey: Keys.remoteURL) ?? ""),
              var parts = URLComponents(url: api, resolvingAgainstBaseURL: false), parts.host != nil else {
            throw CadError.noServer
        }
        parts.scheme = "http"
        parts.port = port
        parts.path = ""
        guard let url = parts.url else { throw CadError.noServer }
        return url
    }

    static func health() async throws -> String {
        var request = URLRequest(url: try baseURL().appendingPathComponent("health"))
        request.timeoutInterval = 10
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CadError.unreachable("") }
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
            return lines.count > 1 ? String(lines[1]) : "ready"
        } catch let error as CadError {
            throw error
        } catch {
            throw CadError.unreachable(error.localizedDescription)
        }
    }

    static func render(_ code: String) async throws -> ThreeMF.Mesh {
        var request = URLRequest(url: try baseURL().appendingPathComponent("render"))
        request.httpMethod = "POST"
        request.timeoutInterval = 240
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(code.utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw CadError.unreachable(error.localizedDescription)
        }
        let text = String(decoding: data, as: UTF8.self)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw CadError.build(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let mesh = ThreeMF.parseSTL(text)
        guard !mesh.triangles.isEmpty else { throw CadError.empty }
        return mesh
    }

    /// The fixed prompt that makes a model answer with OpenSCAD.
    static let designerPrompt = """
        You are a 3D design assistant for 3D printing. When asked for a part, answer with complete OpenSCAD code \
        in a single ```openscad code block, plus at most one short sentence. Use millimetres. Put the key \
        dimensions in named variables at the top and set $fn = 64; for smooth curves. Build the part from cube, \
        cylinder, sphere, polygon, linear_extrude, rotate_extrude, hull, union, difference and intersection. The \
        part must be one connected solid resting on z = 0. Make holes slightly longer than the material they cut \
        through. Do not use import(), surface(), text() or external libraries. When given an error message, send \
        the full corrected code again.
        """
}

/// Settings screen: install and check the 3D builder on the server.
struct CadSetupView: View {
    @AppStorage(Keys.promptText) private var promptText = ""
    @AppStorage(Keys.promptEnabled) private var promptEnabled = true
    @State private var copied = false
    @State private var status = ""
    @State private var busy = false
    @State private var promptSet = false

    static let command = "curl -fsSL https://raw.githubusercontent.com/OompaGoompa/OompaGoompa-local-llm.public/app/server/cad-setup.sh | bash"

    var body: some View {
        Form {
            Section {
                Text("The AI is good at writing OpenSCAD, a small language that describes parts. The 3D builder on your server turns that code into a solid, printable shape, which you can view here and save as .3mf.")
                    .font(.footnote)
            }

            Section {
                Text("Connect to your server in your SSH app and paste this command. It takes a few minutes and finishes by building a test cube.")
                    .font(.footnote)
                Text(Self.command).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                Button {
                    UIPasteboard.general.string = Self.command
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy the command", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
            } header: {
                Text("1. Install on the server (once)")
            }

            Section {
                Button {
                    check()
                } label: {
                    HStack {
                        Text("Check the 3D builder")
                        if busy { Spacer(); ProgressView() }
                    }
                }
                .disabled(busy)
                if !status.isEmpty { Text(status).font(.footnote).foregroundStyle(.secondary) }
            } header: {
                Text("2. Check it")
            }

            Section {
                Button(promptSet ? "3D designer prompt is on" : "Use the 3D designer prompt") {
                    promptText = CadClient.designerPrompt
                    promptEnabled = true
                    promptSet = true
                }
            } header: {
                Text("3. Tell the AI to write OpenSCAD")
            } footer: {
                Text("This replaces your fixed prompt (Settings › Prompt) with one that makes the AI answer with OpenSCAD code. Then ask for a part in plain words, for example \"a 40 by 20 mm plate, 3 mm thick, with two 4 mm holes\", and tap Build 3D model under the reply. A coding model such as qwen3-coder works best.")
            }
        }
        .navigationTitle("3D builder")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { promptSet = promptText == CadClient.designerPrompt && promptEnabled }
    }

    private func check() {
        busy = true
        status = ""
        Task {
            do {
                status = "Working: " + (try await CadClient.health())
            } catch {
                status = error.localizedDescription
            }
            busy = false
        }
    }
}
