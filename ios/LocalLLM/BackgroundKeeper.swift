import AVFoundation
import UIKit
import UserNotifications

/// Keeps the app alive in the background while server work is in progress (a reply streaming in, a download),
/// and posts a notification when it finishes.
///
/// iOS pauses an app shortly after it leaves the screen unless it is doing one of a few allowed things. Playing
/// audio is one of them, so this plays silence, mixed with whatever else is playing, for as long as work is
/// running. It does not interrupt music or podcasts.
@MainActor
final class BackgroundKeeper {
    static let shared = BackgroundKeeper()

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var holds = 0
    private var askedForNotifications = false
    private var observer: NSObjectProtocol?

    private var enabled: Bool { UserDefaults.standard.bool(forKey: Keys.keepAlive) }

    /// Call when background-worthy work starts. Balanced by `end()`.
    func begin() {
        holds += 1
        guard holds == 1, enabled else { return }
        askForNotifications()
        startSilence()
    }

    func end() {
        holds = max(0, holds - 1)
        if holds == 0 { stopSilence() }
    }

    /// Tells the user something finished, but only when they are not looking at the app.
    func notify(title: String, body: String) {
        guard enabled, UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(body.prefix(140))
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    private func askForNotifications() {
        guard !askedForNotifications else { return }
        askedForNotifications = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func startSilence() {
        guard engine == nil else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            engine.attach(player)
            guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100) else { return }
            buffer.frameLength = 44_100
            engine.connect(player, to: engine.mainMixerNode, format: format)
            engine.mainMixerNode.outputVolume = 0
            try engine.start()
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            player.play()
            self.engine = engine
            self.player = player

            // A phone call or alarm pauses audio; pick it back up afterwards so the work is not cut off.
            observer = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                guard raw == AVAudioSession.InterruptionType.ended.rawValue else { return }
                Task { @MainActor in self?.resume() }
            }
        } catch {
            engine = nil
            player = nil
        }
    }

    private func resume() {
        guard holds > 0, let engine, let player else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        if !engine.isRunning { try? engine.start() }
        if !player.isPlaying { player.play() }
    }

    private func stopSilence() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
