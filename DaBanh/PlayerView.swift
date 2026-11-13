import AVFoundation
import AVKit
import SwiftUI
import UIKit

/// Player page: the system player is EMBEDDED full-bleed — edge-to-edge
/// under a small floating overlay (close button + title capsule),
/// reserving no layout space, so the picture is as full-screen as the
/// modal design was.
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
///
/// Sources + fallback (2026-11-13, synced with the tvOS player): the
/// page receives every source carrying the same match; when a stream
/// fails it advances to the next source automatically, and only when
/// all of them fail does it settle on a "no signal" slate.
struct PlayerView: View {
    let sources: [Channel]
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var exhausted = false
    @State private var switching = true

    private var current: Channel? {
        sources.indices.contains(index) ? sources[index] : nil
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()

            if exhausted {
                noSignal
            } else if let channel = current, channel.streamURL != nil {
                PlayerControllerView(channel: channel, onFail: advance, onReady: { switching = false })
                    .id(index)
                    .ignoresSafeArea()
                if switching {
                    VStack {
                        Spacer()
                        HStack {
                            Text(index == 0 ? "Đang tải…" : "Đang chuyển nguồn khác…")
                                .font(.footnote)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(Color.black.opacity(0.45), in: Capsule())
                            Spacer()
                        }
                        .padding(.leading, 14)
                        .padding(.bottom, 26)
                    }
                    .ignoresSafeArea()
                }
            } else {
                // An unparseable URL counts as a failed source.
                Color.clear.onAppear { advance() }
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

                Text(current?.title ?? "")
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

    private func advance() {
        if index + 1 < sources.count {
            index += 1
            switching = true
        } else {
            exhausted = true
        }
    }

    private var noSignal: some View {
        VStack(spacing: 14) {
            Spacer()
            Text("MẤT TÍN HIỆU")
                .font(.title.bold())
                .tracking(3)
                .foregroundStyle(.white)
            Text("Tất cả các nguồn của trận này đều không phát được.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.65))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

/// SwiftUI wrapper around an embedded AVPlayerViewController with PiP
/// enabled and a pinch recognizer for fit/fill switching. Plays
/// immediately on appear; pauses and releases on dismantle. The asset
/// carries exactly the headers the entry itself declared (#EXTVLCOPT).
struct PlayerControllerView: UIViewControllerRepresentable {
    let channel: Channel
    let onFail: () -> Void
    let onReady: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFail: onFail, onReady: onReady) }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        // Audio session for background / PiP playback.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)

        let item = AVPlayerItem(asset: Self.asset(for: channel))
        let titleItem = AVMutableMetadataItem()
        titleItem.identifier = AVMetadataIdentifier.commonIdentifierTitle
        titleItem.value = channel.title as NSString
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
        context.coordinator.observe(item)
        player.play()
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.invalidate()
        uiViewController.player?.pause()
        uiViewController.player = nil
        coordinator.controller = nil
    }

    static func asset(for channel: Channel) -> AVURLAsset {
        let url = channel.streamURL ?? URL(fileURLWithPath: "/dev/null")
        var headers: [String: String] = [:]
        if !channel.userAgent.isEmpty { headers["User-Agent"] = channel.userAgent }
        if !channel.referrer.isEmpty { headers["Referer"] = channel.referrer }
        if headers.isEmpty { return AVURLAsset(url: url) }
        return AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var controller: AVPlayerViewController?
        private let onFail: () -> Void
        private let onReady: () -> Void
        private var statusToken: NSKeyValueObservation?
        private var failToken: NSObjectProtocol?
        private var fired = false

        init(onFail: @escaping () -> Void, onReady: @escaping () -> Void) {
            self.onFail = onFail
            self.onReady = onReady
        }

        func observe(_ item: AVPlayerItem) {
            statusToken = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    DispatchQueue.main.async { self.onReady() }
                case .failed:
                    fireOnce()
                default:
                    break
                }
            }
            failToken = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
            ) { [weak self] _ in
                self?.fireOnce()
            }
        }

        private func fireOnce() {
            guard !fired else { return }
            fired = true
            DispatchQueue.main.async { self.onFail() }
        }

        func invalidate() {
            statusToken?.invalidate()
            statusToken = nil
            if let failToken {
                NotificationCenter.default.removeObserver(failToken)
                self.failToken = nil
            }
        }

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
