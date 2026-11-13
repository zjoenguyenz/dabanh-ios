import AVFoundation
import AVKit
import SwiftUI

/// Full-screen native tvOS player. AVPlayerViewController brings the
/// standard remote transport controls (play/pause, scrub, Menu to exit).
struct TVPlayerView: View {
    let channel: Channel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let url = channel.streamURL {
                PlayerController(url: url)
                    .ignoresSafeArea()
            } else {
                Text("Link kênh không hợp lệ")
                    .foregroundStyle(.white)
            }
        }
        .onExitCommand { dismiss() }
    }
}

private struct PlayerController: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        let player = AVPlayer(url: url)
        controller.player = player
        player.play()
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: ()) {
        controller.player?.pause()
        controller.player = nil
    }
}
