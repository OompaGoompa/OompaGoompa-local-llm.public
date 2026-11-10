import SwiftUI
import UIKit

/// A file found inside a reply: the contents of one code block, with a name and the right extension.
struct ReplyFile: Identifiable {
    let id = UUID()
    var name: String
    let language: String
    /// The text of the file, or a short description when the file is binary.
    let content: String
    /// Set for files that are not plain text (a packaged .3mf).
    var data: Data? = nil
    /// The 3D shape, when the file is one, for the built-in viewer.
    var mesh: ThreeMF.Mesh? = nil
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
        "perl": "pl", "vue": "vue", "graphql": "graphql", "diff": "diff", "log": "log",
        "stl": "stl", "obj": "obj", "scad": "scad", "openscad": "scad", "gcode": "gcode", "3mf": "model"
    ]

    /// Works out the extension when the reply did not label the block.
    private static func sniff(_ content: String) -> String {
        let start = content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if start.hasPrefix("<svg") { return "svg" }
        if start.hasPrefix("solid"), start.contains("facet") { return "stl" }
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

            // A 3D model written as text (3MF XML, STL or OBJ) is also offered as a ready-to-print .3mf.
            if let packed = ThreeMF.package(content) {
                let count = (used["3mf"] ?? 0) + 1
                used["3mf"] = count
                files.append(ReplyFile(name: count == 1 ? "model.3mf" : "model-\(count).3mf", language: "3mf",
                                       content: packed.summary, data: packed.data, mesh: ThreeMF.mesh(from: content)))
            }
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
    static func write(name: String, data: Data) -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(safeName(name))
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}

/// Turns a 3D model the AI wrote as text into a real .3mf file (a zip package around the model XML).
enum ThreeMF {
    struct Mesh {
        var vertices: [(Double, Double, Double)] = []
        var triangles: [(Int, Int, Int)] = []
    }

    static func package(_ text: String) -> (data: Data, summary: String)? {
        let lower = text.lowercased()
        if lower.contains("<model"), lower.contains("3dmanufacturing"), lower.contains("<triangle") {
            // Already 3MF model XML: wrap it as it is.
            var xml = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !xml.hasPrefix("<?xml") { xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" + xml }
            let triangles = lower.components(separatedBy: "<triangle ").count - 1
            return (zip(modelXML: xml), "3D model packaged from the 3MF text above: \(triangles) triangles.")
        }
        var mesh: Mesh?
        if lower.contains("facet"), lower.contains("vertex") {
            mesh = parseSTL(text)
        } else if text.contains("\nf ") || text.hasPrefix("f "), text.contains("v ") {
            mesh = parseOBJ(text)
        }
        guard let mesh, !mesh.triangles.isEmpty else { return nil }
        return (zip(modelXML: modelXML(mesh)),
                "3D model converted to 3MF: \(mesh.triangles.count) triangles, \(mesh.vertices.count) points, in millimetres.")
    }

    private static func numbers(_ line: Substring) -> [Double] {
        line.split(whereSeparator: { $0 == " " || $0 == "\t" }).compactMap { Double($0) }
    }

    static func parseSTL(_ text: String) -> Mesh {
        var mesh = Mesh()
        var index: [String: Int] = [:]
        var corner: [Int] = []
        for raw in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = raw.drop(while: { $0 == " " || $0 == "\t" })
            guard line.lowercased().hasPrefix("vertex") else { continue }
            let n = numbers(line.dropFirst(6))
            guard n.count >= 3 else { continue }
            let key = "\(n[0]) \(n[1]) \(n[2])"
            let id: Int
            if let found = index[key] {
                id = found
            } else {
                id = mesh.vertices.count
                index[key] = id
                mesh.vertices.append((n[0], n[1], n[2]))
            }
            corner.append(id)
            if corner.count == 3 {
                if corner[0] != corner[1], corner[1] != corner[2], corner[0] != corner[2] {
                    mesh.triangles.append((corner[0], corner[1], corner[2]))
                }
                corner = []
            }
        }
        return mesh
    }

    static func parseOBJ(_ text: String) -> Mesh {
        var mesh = Mesh()
        for raw in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = raw.drop(while: { $0 == " " || $0 == "\t" })
            if line.hasPrefix("v ") {
                let n = numbers(line.dropFirst(2))
                if n.count >= 3 { mesh.vertices.append((n[0], n[1], n[2])) }
            } else if line.hasPrefix("f ") {
                // "f 1 2 3", "f 1/1/1 2/2/2 3/3/3", negative numbers count back from the end; polygons are fanned.
                let ids: [Int] = line.dropFirst(2).split(separator: " ").compactMap { part in
                    guard let first = part.split(separator: "/", omittingEmptySubsequences: false).first, let v = Int(first) else { return nil }
                    return v > 0 ? v - 1 : mesh.vertices.count + v
                }
                guard ids.count >= 3, ids.allSatisfy({ $0 >= 0 && $0 < mesh.vertices.count }) else { continue }
                for i in 1..<(ids.count - 1) { mesh.triangles.append((ids[0], ids[i], ids[i + 1])) }
            }
        }
        return mesh
    }

    static func modelXML(_ mesh: Mesh) -> String {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        xml += "<model unit=\"millimeter\" xml:lang=\"en-US\" xmlns=\"http://schemas.microsoft.com/3dmanufacturing/core/2015/02\">\n"
        xml += " <resources>\n  <object id=\"1\" type=\"model\">\n   <mesh>\n    <vertices>\n"
        for v in mesh.vertices { xml += "     <vertex x=\"\(v.0)\" y=\"\(v.1)\" z=\"\(v.2)\"/>\n" }
        xml += "    </vertices>\n    <triangles>\n"
        for t in mesh.triangles { xml += "     <triangle v1=\"\(t.0)\" v2=\"\(t.1)\" v3=\"\(t.2)\"/>\n" }
        xml += "    </triangles>\n   </mesh>\n  </object>\n </resources>\n <build>\n  <item objectid=\"1\"/>\n </build>\n</model>\n"
        return xml
    }

    // MARK: - Zip (stored, no compression)

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in data { c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    static func zip(modelXML: String) -> Data {
        let types = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"model\" ContentType=\"application/vnd.ms-package.3dmanufacturing-3dmodel+xml\"/></Types>\n"
        let rels = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Target=\"/3D/3dmodel.model\" Id=\"rel0\" Type=\"http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel\"/></Relationships>\n"
        let entries: [(String, Data)] = [
            ("[Content_Types].xml", Data(types.utf8)),
            ("_rels/.rels", Data(rels.utf8)),
            ("3D/3dmodel.model", Data(modelXML.utf8))
        ]

        var out = Data()
        var central = Data()
        func u16(_ v: Int) -> Data { Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]) }
        func u32(_ v: UInt32) -> Data { Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]) }

        for (name, data) in entries {
            let nameBytes = Data(name.utf8)
            let crc = crc32(data)
            let offset = UInt32(out.count)
            let size = UInt32(data.count)
            // Shared by the local header and the directory entry: version, flags, method, time, date, crc, sizes, name length, extra length.
            let commonParts: [Data] = [u16(20), u16(0), u16(0), u16(0), u16(0x21), u32(crc), u32(size), u32(size), u16(nameBytes.count), u16(0)]
            var common = Data()
            for part in commonParts { common.append(part) }

            let localParts: [Data] = [u32(0x0403_4B50), common, nameBytes, data]
            for part in localParts { out.append(part) }

            let directoryParts: [Data] = [u32(0x0201_4B50), u16(20), common, u16(0), u16(0), u16(0), u32(0), u32(offset), nameBytes]
            for part in directoryParts { central.append(part) }
        }
        let start = UInt32(out.count)
        let count = entries.count
        out.append(central)
        let endParts: [Data] = [u32(0x0605_4B50), u16(0), u16(0), u16(count), u16(count), u32(UInt32(central.count)), u32(start), u16(0)]
        for part in endParts { out.append(part) }
        return out
    }
}

struct ViewedModel: Identifiable {
    let id = UUID()
    let mesh: ThreeMF.Mesh
    let title: String
}

/// Lists the files in a reply and sends any of them to the Files app or another app.
struct SaveFilesView: View {
    @Environment(\.dismiss) private var dismiss
    let replyText: String
    @State private var files: [ReplyFile] = []
    @State private var wholeName = "reply.md"
    @State private var share: ShareItem?
    @State private var failed = false
    @State private var notAModel = false
    @State private var viewing: ViewedModel?

    private static let types = ["txt", "md", "html", "css", "js", "json", "csv", "xml", "svg", "py", "sh", "swift",
                                "java", "c", "cpp", "sql", "yaml", "stl", "obj", "scad", "gcode", "3mf"]

    private func ending(of name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[name.index(after: dot)...]).lowercased()
    }

    /// A menu of file types; choosing one swaps the ending of the name.
    private func typePicker(_ name: Binding<String>) -> some View {
        let current = ending(of: name.wrappedValue)
        let options = Self.types.contains(current) || current.isEmpty ? Self.types : [current] + Self.types
        let selection = Binding<String>(
            get: { ending(of: name.wrappedValue) },
            set: { chosen in
                let old = name.wrappedValue
                let base: String
                if let dot = old.lastIndex(of: "."), dot != old.startIndex {
                    base = String(old[..<dot])
                } else {
                    base = old.isEmpty ? "file" : old
                }
                name.wrappedValue = base + "." + chosen
            }
        )
        return Picker("File type", selection: selection) {
            if current.isEmpty { Text("None").tag("") }
            ForEach(options, id: \.self) { Text("." + $0).tag($0) }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                ForEach($files) { $file in
                    Section {
                        TextField("File name", text: $file.name)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if file.data == nil { typePicker($file.name) }
                        Text(preview(file.content))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(6)
                        if let mesh = file.mesh {
                            Button {
                                viewing = ViewedModel(mesh: mesh, title: file.name)
                            } label: {
                                Label("View in 3D", systemImage: "rotate.3d")
                            }
                        }
                        Button {
                            if let data = file.data {
                                send(name: file.name, data: data)
                            } else {
                                send(name: file.name, text: file.content)
                            }
                        } label: {
                            Label("Save or share", systemImage: "square.and.arrow.down")
                        }
                    } header: {
                        Text(file.data.map { String(format: "3D model · %.1f KB", Double($0.count) / 1024) } ?? size(file.content))
                    }
                }

                Section {
                    TextField("File name", text: $wholeName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    typePicker($wholeName)
                    Button {
                        send(name: wholeName, text: replyText)
                    } label: {
                        Label("Save or share the whole reply", systemImage: "doc.text")
                    }
                } header: {
                    Text("Whole reply")
                } footer: {
                    Text(files.isEmpty
                         ? "This reply has no separate code or data blocks, so it is saved as one file. Pick the file type that matches what the reply is."
                         : "Pick a file type or change a name before saving if you like. In the share sheet, choose Save to Files to keep it on the phone.")
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
            .sheet(item: $viewing) { model in
                ModelPreviewView(mesh: model.mesh, title: model.title)
            }
            .alert("The file could not be written.", isPresented: $failed) {
                Button("OK", role: .cancel) {}
            }
            .alert("Not a 3D model", isPresented: $notAModel) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("A .3mf needs 3D shape data, and this text has none (it may be a program or an explanation). Ask the AI for an ASCII STL in a code block, then save that as .3mf.")
            }
            .onAppear {
                if files.isEmpty { files = ReplyFiles.extract(from: replyText) }
            }
        }
    }

    /// Text is written as it is, except for .3mf, which has to be built from 3D shape data in the text.
    private func send(name: String, text: String) {
        if ending(of: name) == "3mf" {
            guard let packed = ThreeMF.package(text) else {
                notAModel = true
                return
            }
            send(name: name, data: packed.data)
        } else {
            send(name: name, data: Data(text.utf8))
        }
    }

    private func send(name: String, data: Data) {
        if let url = ReplyFiles.write(name: name, data: data) {
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
