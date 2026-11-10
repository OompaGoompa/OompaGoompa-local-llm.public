import SwiftUI
import UIKit

/// A file found inside a reply: the contents of one code block, with a name and the right extension.
struct ReplyFile: Identifiable {
    let id = UUID()
    var name: String
    let language: String
    let content: String
}

enum ReplyFiles {
    private static let extensions: [String: String] = [
        "html": "html", "htm": "html", "css": "css", "javascript": "js", "js": "js", "jsx": "jsx",
        "typescript": "ts", "ts": "ts", "tsx": "tsx", "python": "py", "py": "py", "json": "json", "csv": "csv",
        "tsv": "tsv", "xml": "xml", "svg": "svg", "markdown": "md", "md": "md", "bash": "sh", "sh": "sh",
        "shell": "sh", "zsh": "sh", "swift": "swift", "java": "java", "c": "c", "cpp": "cpp", "c++": "cpp",
        "h": "h", "csharp": "cs", "cs": "cs", "go": "go", "rust": "rs", "rs": "rs", "php": "php", "ruby": "rb",
        "rb": "rb", "sql": "sql", "yaml": "yaml", "yml": "yaml", "toml": "toml", "kotlin": "kt", "kt": "kt",
        "lua": "lua", "r": "r", "tex": "tex", "latex": "tex", "text": "txt", "txt": "txt", "plaintext": "txt",
        "ini": "ini", "powershell": "ps1", "ps1": "ps1", "bat": "bat", "dart": "dart", "scala": "scala",
        "perl": "pl", "vue": "vue", "graphql": "graphql", "diff": "diff", "log": "log"
    ]

    /// Works out the extension when the reply did not label the block.
    private static func sniff(_ content: String) -> String {
        let start = content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if start.hasPrefix("<svg") { return "svg" }
        if start.hasPrefix("<!doctype html") || start.hasPrefix("<html") { return "html" }
        if start.hasPrefix("<?xml") { return "xml" }
        if start.hasPrefix("{") || start.hasPrefix("["),
           let data = content.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data)) != nil {
            return "json"
        }
        if start.hasPrefix("#!/bin/bash") || start.hasPrefix("#!/bin/sh") || start.hasPrefix("#!/usr/bin/env bash") { return "sh" }
        if start.hasPrefix("#!/usr/bin/env python") { return "py" }
        return "txt"
    }

    static func safeName(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r")).joined()
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "file.txt" : cleaned
    }

    /// Every fenced code block in the reply, as a file. A block cut off by the end of the reply still counts.
    static func extract(from text: String) -> [ReplyFile] {
        var files: [ReplyFile] = []
        var info: String?
        var lines: [String] = []
        var used: [String: Int] = [:]

        func close() {
            let content = lines.joined(separator: "\n")
            lines = []
            guard let header = info else { return }
            info = nil
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

            let tokens = header.split(whereSeparator: { $0 == " " || $0 == ":" || $0 == "=" || $0 == "\t" }).map(String.init)
            let language = (tokens.first ?? "").lowercased()
            // A label such as "html index.html" or "python:main.py" names the file outright.
            var name = tokens.dropFirst().first(where: { $0.contains(".") && !$0.hasPrefix(".") && !$0.contains("/") })
            if name == nil, language.contains("."), extensions[language] == nil { name = tokens.first }
            if language == "dockerfile" { name = name ?? "Dockerfile" }
            if language == "makefile" { name = name ?? "Makefile" }

            if name == nil {
                let ext = extensions[language] ?? sniff(content)
                let base = ext == "html" ? "index" : (ext == "svg" ? "image" : (ext == "csv" ? "data" : "file"))
                let count = (used[base + ext] ?? 0) + 1
                used[base + ext] = count
                name = count == 1 ? "\(base).\(ext)" : "\(base)-\(count).\(ext)"
            }
            files.append(ReplyFile(name: safeName(name ?? "file.txt"), language: language, content: content + "\n"))
        }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if info == nil {
                    info = String(trimmed.dropFirst(3)).trimmingCharacters(in: CharacterSet(charactersIn: "` "))
                } else {
                    close()
                }
            } else if info != nil {
                lines.append(line)
            }
        }
        close()
        return files
    }

    /// Writes the file under its exact name so the share sheet and the Files app keep the extension.
    static func write(name: String, content: String) -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(safeName(name))
            try content.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}

/// Lists the files in a reply and sends any of them to the Files app or another app.
struct SaveFilesView: View {
    @Environment(\.dismiss) private var dismiss
    let replyText: String
    @State private var files: [ReplyFile] = []
    @State private var wholeName = "reply.md"
    @State private var share: ShareItem?
    @State private var failed = false

    var body: some View {
        NavigationStack {
            Form {
                ForEach($files) { $file in
                    Section {
                        TextField("File name", text: $file.name)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Text(preview(file.content))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(6)
                        Button {
                            send(name: file.name, content: file.content)
                        } label: {
                            Label("Save or share", systemImage: "square.and.arrow.down")
                        }
                    } header: {
                        Text(size(file.content))
                    }
                }

                Section {
                    TextField("File name", text: $wholeName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        send(name: wholeName, content: replyText)
                    } label: {
                        Label("Save or share the whole reply", systemImage: "doc.text")
                    }
                } header: {
                    Text("Whole reply")
                } footer: {
                    Text(files.isEmpty
                         ? "This reply has no separate code or data blocks, so it is saved as one file. Change the ending of the name (for example .csv or .html) if the reply is that kind of file."
                         : "Change a name or its ending before saving if you like. In the share sheet, choose Save to Files to keep it on the phone.")
                }
            }
            .navigationTitle("Save as file")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(item: $share) { item in
                ActivityView(items: [item.url])
            }
            .alert("The file could not be written.", isPresented: $failed) {
                Button("OK", role: .cancel) {}
            }
            .onAppear {
                if files.isEmpty { files = ReplyFiles.extract(from: replyText) }
            }
        }
    }

    private func send(name: String, content: String) {
        if let url = ReplyFiles.write(name: name, content: content) {
            share = ShareItem(url: url)
        } else {
            failed = true
        }
    }

    private func preview(_ content: String) -> String {
        content.components(separatedBy: "\n").prefix(6).joined(separator: "\n")
    }

    private func size(_ content: String) -> String {
        let bytes = content.utf8.count
        let lines = content.components(separatedBy: "\n").count - 1
        return bytes < 1024 ? "\(lines) lines · \(bytes) bytes" : String(format: "%d lines · %.1f KB", lines, Double(bytes) / 1024)
    }
}
