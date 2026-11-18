import AVFoundation
import AVKit
import MediaPlayer
import SwiftUI
import UIKit

/// Player page (v1.16): a CUSTOM player surface — an AVPlayerLayer
/// with the app's own control layer — embedded full-bleed, exactly
/// like the JTV app's player. One chrome only: close, title,
/// play/pause, AirPlay, PiP and the fit/fill toggle all live in one
/// control layer that fades together after 3.5 s.
///
/// Why not the system player (the design up to v1.15): the embedded
/// AVPlayerViewController draws its OWN top bar (close + title)
/// next to the app's floating chrome, so every tap showed two
/// close buttons side by side — the owner called it an eyesore and
/// ordered the surface unified with JTV's. AVKit also could not be
/// told to hide just its top bar.
///
/// Why embedded, not modal (the v1.2 lesson, still in force): when
/// PiP starts, iOS dismisses a modally presented player; the host's
/// viewDidAppear then looks exactly like "user closed the player"
/// and the whole page was torn down, killing the PiP stream
/// (owner's clip, 2026-11-12). Embedded, PiP opens in place.
///
/// Pinch-to-fill: a two-finger pinch toggles the layer's
/// videoGravity between resizeAspect (fit) and resizeAspectFill
/// (fill / "tràn viền"), as the owner asked for explicitly.
///
/// Sources + fallback (2026-11-13, synced with the tvOS player):
/// the page receives every source carrying the same match; when a
/// stream fails it advances to the next source automatically, and
/// only when all of them fail does it settle on a "no signal"
/// slate (which keeps its own always-visible close button — there
/// is no video to keep clean there).
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
                closeButton
            } else if let channel = current, channel.streamURL != nil {
                LivePlayerSurface(channel: channel, onFail: advance, onReady: { switching = false }, onClose: { dismiss() })
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
        }
        .onAppear {
            OrientationHelper.lock(.landscape, rotateTo: .landscapeRight)
        }
        .onDisappear {
            OrientationHelper.lock(.all, rotateTo: .portrait)
        }
    }

    /// The slate's own exit (no player surface exists there).
    private var closeButton: some View {
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
        .padding(.leading, 14)
        .padding(.top, 10)
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

/// SwiftUI wrapper around the custom live-player surface. Plays
/// immediately on appear; pauses and releases on dismantle. The
/// asset carries exactly the headers the entry itself declared
/// (#EXTVLCOPT).
struct LivePlayerSurface: UIViewControllerRepresentable {
    let channel: Channel
    let onFail: () -> Void
    let onReady: () -> Void
    let onClose: () -> Void

    func makeUIViewController(context: Context) -> LivePlayerViewController {
        let controller = LivePlayerViewController()
        controller.channel = channel
        controller.onFail = onFail
        controller.onReady = onReady
        controller.onClose = onClose
        return controller
    }

    func updateUIViewController(_ uiViewController: LivePlayerViewController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: LivePlayerViewController, coordinator: ()) {
        uiViewController.teardown()
    }

    static func asset(for channel: Channel) -> AVURLAsset {
        let url = channel.streamURL ?? URL(fileURLWithPath: "/dev/null")
        var headers: [String: String] = [:]
        if !channel.userAgent.isEmpty { headers["User-Agent"] = channel.userAgent }
        if !channel.referrer.isEmpty { headers["Referer"] = channel.referrer }
        if headers.isEmpty { return AVURLAsset(url: url) }
        return AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
    }
}

/// The custom live surface: AVPlayerLayer + one fading control
/// layer (close + title on top; play/pause centred; LIVE badge,
/// AirPlay, PiP and fit/fill along the bottom). Mirrors the JTV
/// player's surface so both of the owner's apps feel identical.
final class LivePlayerViewController: UIViewController {
    var channel: Channel?
    var onFail: (() -> Void)?
    var onReady: (() -> Void)?
    var onClose: (() -> Void)?

    private let videoView = PlayerLayerView()
    private let controlsView = UIView()
    private let closeButton = UIButton(type: .system)
    private let titleLabel = UILabel()
    private let playPauseButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .large)
    private var pipButton = UIButton(type: .system)
    private let fillButton = UIButton(type: .system)
    private let liveBadge = UILabel()

    private var player: AVPlayer?
    private var pipController: AVPictureInPictureController?
    private var statusToken: NSKeyValueObservation?
    private var timeControlToken: NSKeyValueObservation?
    private var failToken: NSObjectProtocol?
    private var firedFail = false
    private var firedReady = false
    private var hideTimer: Timer?
    private var controlsVisible = true
    private var torn = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let channel else { return }

        // Audio session for background / PiP playback.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)

        let item = AVPlayerItem(asset: LivePlayerSurface.asset(for: channel))
        let titleItem = AVMutableMetadataItem()
        titleItem.identifier = AVMetadataIdentifier.commonIdentifierTitle
        titleItem.value = channel.title as NSString
        titleItem.extendedLanguageTag = "und"
        item.externalMetadata = [titleItem]

        let player = AVPlayer(playerItem: item)
        player.allowsExternalPlayback = true
        self.player = player
        videoView.playerLayer.player = player
        videoView.playerLayer.videoGravity = .resizeAspect
        videoView.frame = view.bounds
        videoView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(videoView)

        buildControls(channel: channel)
        observe(item: item, player: player)
        setupRemoteCommands(channel: channel)
        player.play()
        scheduleControlsHide()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        videoView.frame = view.bounds
        controlsView.frame = view.bounds
    }

    // MARK: - Controls

    private func buildControls(channel: Channel) {
        controlsView.frame = view.bounds
        controlsView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(controlsView)

        func roundButton(_ button: UIButton, _ systemName: String, _ action: Selector) {
            button.setImage(UIImage(systemName: systemName), for: .normal)
            button.tintColor = .white
            button.backgroundColor = UIColor.black.withAlphaComponent(0.45)
            button.layer.cornerRadius = 20
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 40).isActive = true
            button.heightAnchor.constraint(equalToConstant: 40).isActive = true
            button.addTarget(self, action: action, for: .touchUpInside)
        }

        roundButton(closeButton, "xmark", #selector(closeTapped))
        controlsView.addSubview(closeButton)

        titleLabel.text = MatchTitle.clean(channel.title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        controlsView.addSubview(titleLabel)

        playPauseButton.setImage(UIImage(systemName: "pause.fill"), for: .normal)
        playPauseButton.tintColor = .white
        playPauseButton.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        playPauseButton.layer.cornerRadius = 36
        playPauseButton.translatesAutoresizingMaskIntoConstraints = false
        playPauseButton.widthAnchor.constraint(equalToConstant: 72).isActive = true
        playPauseButton.heightAnchor.constraint(equalToConstant: 72).isActive = true
        playPauseButton.addTarget(self, action: #selector(togglePlayPause), for: .touchUpInside)
        controlsView.addSubview(playPauseButton)

        liveBadge.text = "● TRỰC TIẾP"
        liveBadge.font = .systemFont(ofSize: 11, weight: .bold)
        liveBadge.textColor = .systemRed
        liveBadge.translatesAutoresizingMaskIntoConstraints = false

        let routePicker = AVRoutePickerView()
        routePicker.prioritizesVideoDevices = true
        routePicker.tintColor = .white
        routePicker.activeTintColor = .systemOrange
        routePicker.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        routePicker.layer.cornerRadius = 20
        routePicker.translatesAutoresizingMaskIntoConstraints = false
        routePicker.widthAnchor.constraint(equalToConstant: 40).isActive = true
        routePicker.heightAnchor.constraint(equalToConstant: 40).isActive = true

        roundButton(pipButton, "pip.enter", #selector(togglePiP))
        pipButton.isHidden = !AVPictureInPictureController.isPictureInPictureSupported()

        roundButton(fillButton, "arrow.up.left.and.arrow.down.right", #selector(toggleFill))

        let spacer = UIView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let bottomRow = UIStackView(arrangedSubviews: [liveBadge, spacer, routePicker, pipButton, fillButton])
        bottomRow.axis = .horizontal
        bottomRow.spacing = 10
        bottomRow.alignment = .center
        bottomRow.translatesAutoresizingMaskIntoConstraints = false
        controlsView.addSubview(bottomRow)

        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            titleLabel.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            playPauseButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            playPauseButton.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            bottomRow.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            bottomRow.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            bottomRow.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -14),
        ])

        spinner.color = .white
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        spinner.startAnimating()

        let tap = UITapGestureRecognizer(target: self, action: #selector(toggleControls))
        view.addGestureRecognizer(tap)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        view.addGestureRecognizer(pinch)

        if AVPictureInPictureController.isPictureInPictureSupported() {
            pipController = AVPictureInPictureController(playerLayer: videoView.playerLayer)
            pipController?.delegate = self
            pipController?.canStartPictureInPictureAutomaticallyFromInline = true
        }
    }

    // MARK: - Observation (the old Coordinator's semantics, in place)

    private func observe(item: AVPlayerItem, player: AVPlayer) {
        statusToken = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            // Read the status VALUE here and hop: the KVO handler is a
            // non-isolated context, the VC's state is main-actor
            // state (Swift 6).
            let status = item.status
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch status {
                case .readyToPlay:
                    if !firedReady {
                        firedReady = true
                        self.onReady?()
                    }
                case .failed:
                    fireFailOnce()
                default:
                    break
                }
            }
        }
        failToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            self?.fireFailOnce()
        }
        timeControlToken = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            DispatchQueue.main.async { self?.refreshPlaybackUI(player) }
        }
    }

    private func fireFailOnce() {
        guard !firedFail else { return }
        firedFail = true
        DispatchQueue.main.async { self.onFail?() }
    }

    private func refreshPlaybackUI(_ player: AVPlayer) {
        switch player.timeControlStatus {
        case .playing:
            spinner.stopAnimating()
            playPauseButton.setImage(UIImage(systemName: "pause.fill"), for: .normal)
        case .waitingToPlayAtSpecifiedRate:
            spinner.startAnimating()
        case .paused:
            spinner.stopAnimating()
            playPauseButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
        @unknown default:
            break
        }
    }

    // MARK: - Actions

    @objc private func closeTapped() { onClose?() }

    @objc private func togglePlayPause() {
        guard let player else { return }
        if player.timeControlStatus == .paused { player.play() } else { player.pause() }
        refreshPlaybackUI(player)
        showControls()
    }

    @objc private func togglePiP() {
        guard let pipController else { return }
        if pipController.isPictureInPictureActive {
            pipController.stopPictureInPicture()
        } else {
            pipController.startPictureInPicture()
        }
        showControls()
    }

    @objc private func toggleFill() {
        let layer = videoView.playerLayer
        layer.videoGravity = layer.videoGravity == .resizeAspect ? .resizeAspectFill : .resizeAspect
        showControls()
    }

    /// Spread (scale > 1) fills the screen, pinch (scale < 1)
    /// returns to fit — the owner's thresholds from the AVKit era.
    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard gesture.state == .changed || gesture.state == .ended else { return }
        let layer = videoView.playerLayer
        if gesture.scale > 1.12, layer.videoGravity != .resizeAspectFill {
            layer.videoGravity = .resizeAspectFill
        } else if gesture.scale < 0.88, layer.videoGravity != .resizeAspect {
            layer.videoGravity = .resizeAspect
        }
    }

    @objc private func toggleControls() {
        controlsVisible.toggle()
        UIView.animate(withDuration: 0.25) { self.controlsView.alpha = self.controlsVisible ? 1 : 0 }
        if controlsVisible { scheduleControlsHide() } else { hideTimer?.invalidate() }
    }

    private func showControls() {
        controlsVisible = true
        UIView.animate(withDuration: 0.25) { self.controlsView.alpha = 1 }
        scheduleControlsHide()
    }

    private func scheduleControlsHide() {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 3.5, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.controlsVisible = false
            UIView.animate(withDuration: 0.25) { self.controlsView.alpha = 0 }
        }
    }

    // MARK: - Now Playing / remote commands (AVKit provided these)

    private func setupRemoteCommands(channel: Channel) {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: MatchTitle.clean(channel.title),
            MPNowPlayingInfoPropertyIsLiveStream: true,
        ]
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            self?.player?.play()
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.player?.pause()
            return .success
        }
    }

    func teardown() {
        guard !torn else { return }
        torn = true
        hideTimer?.invalidate()
        if pipController?.isPictureInPictureActive == true {
            pipController?.stopPictureInPicture()
        }
        pipController = nil
        player?.pause()
        statusToken?.invalidate()
        statusToken = nil
        timeControlToken?.invalidate()
        timeControlToken = nil
        if let failToken {
            NotificationCenter.default.removeObserver(failToken)
            self.failToken = nil
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        videoView.playerLayer.player = nil
        player = nil
    }
}

extension LivePlayerViewController: AVPictureInPictureControllerDelegate {}

/// A plain view whose layer is the player layer.
final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
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
