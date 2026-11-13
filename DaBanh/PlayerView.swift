import AVFoundation
import AVKit
import SwiftUI
import UIKit

/// Player page (v1.3): the system player is EMBEDDED full-bleed —
/// edge-to-edge under a small floating overlay (close button + title
/// capsule), reserving no layout space, so the picture is as full-screen
/// as the modal design was.
///
/// Why not modal (the v1.2 design): when PiP starts, iOS dismisses a
/// modally presented AVPlayerViewController; the host's viewDidAppear
/// then looks exactly like "user closed the player", the whole page was
/// torn down and the PiP stream died with it (owner's clip, 2026-11-12:
/// PiP tap -> ejected to the portrait channel list). Embedded, PiP opens
/// in place and nothing else moves.
///
/// Pinch-to-fill: a two-finger pinch toggles the controller's
/// videoGravity between resizeAspect (fit) and resizeAspectFill (fill /
/// "tràn viền"), which the owner asked for explicitly.
struct PlayerView: View {
    let channel: Channel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()

            if let url = channel.streamURL {
                PlayerControllerView(url: url, title: channel.title)
                    .ignoresSafeArea()
            } else {
                VStack(spacing: 16) {
                    Spacer()
                    Text("Kênh không có địa chỉ phát hợp lệ.")
                        .foregroundStyle(.white)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }

            // Floating chrome: floats OVER the video, reserves nothing.
            HStack(spacing: 10) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.black.opacity(0.45), in: Circle())
                }
                .accessibilityLabel("Đóng")

                Text(channel.title)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.black.opacity(0.45), in: Capsule())
            }
            .padding(.leading, 14)
            .padding(.top, 10)
        }
        .onAppear {
            OrientationHelper.lock(.landscape, rotateTo: .landscapeRight)
        }
        .onDisappear {
            OrientationHelper.lock(.all, rotateTo: .portrait)
        }
    }
}

/// SwiftUI wrapper around an embedded AVPlayerViewController with PiP
/// enabled and a pinch recognizer for fit/fill switching. Plays
/// immediately on appear; pauses and releases on dismantle.
struct PlayerControllerView: UIViewControllerRepresentable {
    let url: URL
    let title: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        // Audio session for background / PiP playback.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)

        let item = AVPlayerItem(url: url)
        let titleItem = AVMutableMetadataItem()
        titleItem.identifier = AVMetadataIdentifier.commonIdentifierTitle
        titleItem.value = title as NSString
        titleItem.extendedLanguageTag = "und"
        item.externalMetadata = [titleItem]

        let player = AVPlayer(playerItem: item)
        player.allowsExternalPlayback = true

        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.videoGravity = .resizeAspect

        let pinch = UIPinchGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePinch(_:))
        )
        pinch.delegate = context.coordinator
        controller.view.addGestureRecognizer(pinch)

        context.coordinator.controller = controller
        player.play()
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: AVPlayerViewController, coordinator: Coordinator) {
        uiViewController.player?.pause()
        uiViewController.player = nil
        coordinator.controller = nil
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var controller: AVPlayerViewController?

        /// Spread (scale > 1) fills the screen, pinch (scale < 1) returns
        /// to fit. Thresholded so small movements don't flap the mode,
        /// and latched per gesture via the recognizer's state.
        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            guard let controller, gesture.state == .changed || gesture.state == .ended else { return }
            if gesture.scale > 1.12, controller.videoGravity != .resizeAspectFill {
                controller.videoGravity = .resizeAspectFill
            } else if gesture.scale < 0.88, controller.videoGravity != .resizeAspect {
                controller.videoGravity = .resizeAspect
            }
        }

        /// Let the pinch coexist with the player's own gestures
        /// (scrubbing, double-tap, its fullscreen pinch handling).
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

/// SwiftUI wrapper around AVRoutePickerView, preferring video routes so
/// the car's AirPlay video destination (when the car offers one) appears.
/// Used by the channel-list header.
struct RoutePickerView: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = true
        view.tintColor = .white
        view.activeTintColor = .systemOrange
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
