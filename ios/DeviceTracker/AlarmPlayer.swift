import AVFoundation
import Foundation

/// Loops the ping sound while the app is open. Uses the .playback category so it plays
/// even with the ring/silent switch on silent. It cannot raise the system volume: iOS has no API for that.
@MainActor
final class AlarmPlayer: ObservableObject {
    static let shared = AlarmPlayer()

    @Published private(set) var isPlaying = false

    private var player: AVAudioPlayer?
    private var autoStop: Task<Void, Never>?

    func start(duration: TimeInterval = 60) {
        guard !isPlaying, let url = Bundle.main.url(forResource: "ping", withExtension: "wav") else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = -1
            player.volume = 1
            player.play()
            self.player = player
            isPlaying = true
            autoStop = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.stop()
            }
        } catch {
            print("Alarm failed: \(error)")
        }
    }

    func stop() {
        autoStop?.cancel()
        autoStop = nil
        player?.stop()
        player = nil
        isPlaying = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
