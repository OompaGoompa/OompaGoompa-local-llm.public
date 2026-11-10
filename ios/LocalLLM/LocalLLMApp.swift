import SwiftUI
import UIKit

@main
struct LocalLLMApp: App {
    @StateObject private var app = AppState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            TabView {
                ChatView()
                    .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
                ModelsView()
                    .tabItem { Label("Models", systemImage: "cpu") }
                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gearshape") }
            }
            .environmentObject(app)
            .alert("Something went wrong", isPresented: Binding(get: { app.errorText != nil }, set: { if !$0 { app.errorText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(app.errorText ?? "")
            }
            .sheet(item: $app.shareItem) { item in
                ActivityView(items: [item.url])
            }
            // A .gguf file sent to the app (AirDrop, "Open in", Files) lands in the model list.
            .onOpenURL { url in
                if url.isFileURL { app.importModel(from: url) }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                app.didReceiveMemoryWarning()
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background { app.didEnterBackground() }
            if phase == .active { app.refreshModels() }
        }
    }
}

/// The system share sheet.
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
