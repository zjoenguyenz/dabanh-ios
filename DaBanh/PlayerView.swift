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
///
/// Since 2026-11-19 the sources arrive through a MatchPlaySession
/// (Nuvio optimisation set, bottom of this file): candidates are
/// pre-flight-verified in parallel and publish progressively, so
/// the first source this page plays is already proven alive from
/// this phone, and sources verified later append to the ladder
/// while playback is under way.
///
/// Đổi nguồn (1.22): a fixture playback also carries a source
/// switch in the surface's control layer — the fixture's link
/// board as an overlay, the playing row marked; a Vietnamese
/// pick switches in place inside this session, an English pick
/// (a different session, vended by the addon store) cover-swaps
/// through the host. Design: screen 4 of the owner-approved
/// portrait preview; placement per the 1.21 portrait audit §5.
struct PlayerView: View {
    @ObservedObject var session: MatchPlaySession
    /// The fixture this playback was chosen from (1.21): its
    /// cluster renders in the board-header slot above the waiting
    /// slate (spec §2.4/§2.6) — the same MatchState the lists and
    /// the link board show, never a second truth. Optional: the
    /// pre-1.21 entry points (24/7 channels) pass nil.
    var headerEntry: FixtureEntry? = nil
    /// The fixture's folded English links (1.22), handed in by
    /// the host exactly as the link board receives them — the
    /// Đổi nguồn overlay's EN section. Empty when the fixture
    /// matched no English event (the section is then omitted,
    /// like the board's). Values, not the addon store itself:
    /// the host stays the store's single owner.
    var enMetas: [NuvioMeta] = []
    /// When this player IS an English (addon) session, the meta
    /// it is playing — the overlay marks that EN row "ĐANG
    /// PHÁT". Nil for a playlist session, whose playing row is
    /// marked by channel URL instead.
    var currentENMetaID: String? = nil
    /// Cover-swap requests for the switches this session cannot
    /// serve in place: an English pick (a different session),
    /// or a Vietnamese pick whose link this session never
    /// published. The host dismisses this cover and presents
    /// the other — the board's own dismissal-deferred pattern.
    var onSwitchEN: ((NuvioMeta) -> Void)? = nil
    var onSwitchVN: ((Channel) -> Void)? = nil
    @EnvironmentObject private var store: PlaylistStore
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var switching = true
    /// The Đổi nguồn overlay (the fixture's link board in its
    /// in-player mode) is up over the playing surface.
    @State private var sourceBoardPresented = false

    /// The header entry re-read with the freshest matched state.
    private var liveHeaderEntry: FixtureEntry? {
        guard var entry = headerEntry else { return nil }
        entry.state = store.state(for: entry.channel)
        entry.competition = LeagueClassifier.competition(
            for: entry.channel, state: entry.state)
        return entry
    }

    /// The board-header slot: the fixture's cluster, shown above
    /// the waiting slate and on the no-signal slate.
    @ViewBuilder
    private var boardHeaderSlot: some View {
        if let liveHeaderEntry {
            BoardHeaderView(entry: liveHeaderEntry)
                .padding(.horizontal, 16)
                .padding(.top, 54)
        }
    }

    private var sources: [Channel] { session.sources }

    private var current: Channel? {
        sources.indices.contains(index) ? sources[index] : nil
    }

    /// Out of sources for good: the session has settled AND the
    /// player has walked past the last published source. While the
    /// session is still verifying, an empty tail is NOT exhaustion
    /// — more sources may still land (the waiting branch below).
    private var settledExhausted: Bool {
        !session.isResolving && index >= sources.count
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()

            if settledExhausted {
                VStack {
                    boardHeaderSlot
                    noSignal
                }
                closeButton
            } else if let channel = current, channel.streamURL != nil {
                LivePlayerSurface(
                    channel: channel, onFail: advance,
                    onReady: { switching = false }, onClose: { dismiss() },
                    showsSourceSwitch: headerEntry != nil,
                    onSourceSwitch: { sourceBoardPresented = true },
                    pipSuppressed: sourceBoardPresented)
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
            } else if current != nil {
                // An unparseable URL counts as a failed source.
                Color.clear.onAppear { advance() }
            } else {
                // Past the last published source, but the session
                // is still verifying: wait on black with the
                // switching note instead of declaring the slate.
                // When the next verified source lands, this body
                // re-renders onto it at the same index; when the
                // session settles empty, settledExhausted takes over.
                VStack {
                    boardHeaderSlot
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
                closeButton
            }
        }
        .onAppear {
            OrientationHelper.lock(.landscape, rotateTo: .landscapeRight)
        }
        .task {
            // The opened fixture is first in line for its FotMob
            // incidents (spec §1.2, board-open upgrade).
            if let headerEntry {
                await store.liveStates.ensureDetails(for: headerEntry.channel)
            }
        }
        .sheet(isPresented: $sourceBoardPresented) {
            // The Đổi nguồn overlay: the fixture's own link
            // board in its in-player mode — same rows, same
            // arrangement, the playing row marked. Its row
            // callbacks are the switches below, never a fresh
            // entry into the player.
            if let liveHeaderEntry {
                MatchBoardView(
                    entry: liveHeaderEntry,
                    enMetas: enMetas,
                    onPlayVN: switchToVN,
                    onPlayEN: switchToEN,
                    inPlayerMode: true,
                    playingChannelURL: current?.url,
                    playingENMetaID: currentENMetaID)
            }
        }
        .onDisappear {
            OrientationHelper.lock(.all, rotateTo: .portrait)
        }
    }

    /// Đổi nguồn to a Vietnamese row: an in-place index set
    /// when this session carries the link — matched by URL,
    /// never by position (the session's ladder is the board's
    /// ladder rotated, and a published entry may be a
    /// Referer-repaired copy of the row's channel; the URL is
    /// the identity that survives both). Playback continues in
    /// the same session. A row this session never published
    /// (verified dead, or not published yet) has no position to
    /// set — the host re-presents a fresh session rotated to
    /// it, the board's own entry path.
    private func switchToVN(_ channel: Channel) {
        sourceBoardPresented = false
        if let position = session.sources.firstIndex(where: { $0.url == channel.url }) {
            if position != index {
                index = position
                switching = true
            }
        } else {
            onSwitchVN?(channel)
        }
    }

    /// Đổi nguồn to an English row: the meta lives in a
    /// different session vended by the addon store, so the
    /// switch is the host's cover swap — except the meta
    /// already playing, which is a no-op beyond closing the
    /// overlay.
    private func switchToEN(_ meta: NuvioMeta) {
        sourceBoardPresented = false
        guard meta.id != currentENMetaID else { return }
        onSwitchEN?(meta)
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
        // Unconditional: index may move one past the last published
        // source. Each surface fires onFail once per .id(index), so
        // this cannot run away — with current == nil the body
        // re-renders into the waiting branch while the session is
        // still resolving, or the settledExhausted slate once it
        // settles.
        index += 1
        switching = true
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
    /// Đổi nguồn (1.22): whether the surface shows the switch
    /// button in its control layer (fixture playbacks only —
    /// the page passes headerEntry != nil) and what a tap fires.
    var showsSourceSwitch: Bool = false
    var onSourceSwitch: () -> Void = {}
    /// While the switch overlay is up, auto-PiP is suppressed
    /// so the picture cannot leave inline under the board.
    var pipSuppressed: Bool = false

    func makeUIViewController(context: Context) -> LivePlayerViewController {
        let controller = LivePlayerViewController()
        controller.channel = channel
        controller.onFail = onFail
        controller.onReady = onReady
        controller.onClose = onClose
        controller.showsSourceSwitch = showsSourceSwitch
        controller.onSourceSwitch = onSourceSwitch
        controller.pipSuppressed = pipSuppressed
        return controller
    }

    func updateUIViewController(_ uiViewController: LivePlayerViewController, context: Context) {
        uiViewController.setPIPSuppressed(pipSuppressed)
    }

    static func dismantleUIViewController(_ uiViewController: LivePlayerViewController, coordinator: ()) {
        uiViewController.teardown()
    }

    static func asset(for channel: Channel) -> AVURLAsset {
        let url = channel.streamURL ?? URL(fileURLWithPath: "/dev/null")
        // The channel's declared headers; for addon (Nuvio)
        // streams the registry adds the rest of the declared
        // proxyHeaders set (Origin, …), with the channel's own
        // pair over it — so a Referer repaired by pre-flight is
        // the one the player sends. For a playlist channel this
        // is exactly the old behaviour: only the declared pair,
        // only when non-empty.
        let headers = NuvioStreamHeaders.playerHeaders(for: channel)
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
    /// Đổi nguồn (1.22), vended by the surface like the other
    /// callbacks: whether the switch button joins the control
    /// layer, and what a tap fires. pipSuppressed is re-applied
    /// by the representable on every update (setPIPSuppressed).
    var showsSourceSwitch = false
    var onSourceSwitch: (() -> Void)?
    var pipSuppressed = false

    private let videoView = PlayerLayerView()
    private let controlsView = UIView()
    private let closeButton = UIButton(type: .system)
    private let sourceSwitchButton = UIButton(type: .system)
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

        // The Đổi nguồn button (1.22): top-right — the one zone
        // the control map leaves free — in the close button's
        // exact chrome, inside controlsView so it inherits the
        // 3.5 s fade and the tap-to-show behaviour. Only a
        // fixture playback has a board to switch among; the
        // surface is told via showsSourceSwitch.
        if showsSourceSwitch {
            roundButton(sourceSwitchButton, "arrow.triangle.2.circlepath", #selector(sourceSwitchTapped))
            sourceSwitchButton.accessibilityLabel = "Đổi nguồn"
            controlsView.addSubview(sourceSwitchButton)
        }

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
            titleLabel.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            playPauseButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            playPauseButton.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            bottomRow.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            bottomRow.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            bottomRow.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -14),
        ])
        if showsSourceSwitch {
            // The title truncates before the switch button,
            // never under it.
            NSLayoutConstraint.activate([
                sourceSwitchButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
                sourceSwitchButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
                titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: sourceSwitchButton.leadingAnchor, constant: -12),
            ])
        } else {
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16).isActive = true
        }

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
            pipController?.canStartPictureInPictureAutomaticallyFromInline = !pipSuppressed
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

    @objc private func sourceSwitchTapped() {
        onSourceSwitch?()
        showControls()
    }

    /// Auto-PiP suppression (1.22): while the Đổi nguồn overlay
    /// is up, the picture must not leave inline under the board.
    /// The representable re-applies this on every update, so it
    /// tracks the overlay's presentation exactly.
    func setPIPSuppressed(_ suppressed: Bool) {
        pipSuppressed = suppressed
        pipController?.canStartPictureInPictureAutomaticallyFromInline = !suppressed
    }

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

// MARK: - Match source resolution (Nuvio optimisation set, 2026-11-19)

/// The best variant a master playlist declares (RESOLUTION /
/// BANDWIDTH of its top #EXT-X-STREAM-INF entry). The Nuvio addon
/// corrects provider-claimed quality labels from the parsed master
/// playlist (research §3.6); this app displays no quality label
/// anywhere, so the parsed quality is spent where it can act: it
/// orders the verified batch of a match's ladder, best first. A
/// media playlist carries a single variant — nothing to parse —
/// and ranks below any parsed master, keeping its ladder order
/// among its peers.
struct ParsedQuality: Sendable, Comparable {
    let height: Int
    let bandwidth: Int

    static func < (lhs: ParsedQuality, rhs: ParsedQuality) -> Bool {
        (lhs.height, lhs.bandwidth) < (rhs.height, rhs.bandwidth)
    }

    /// Parse a master playlist body; nil when it declares no
    /// variants (a media playlist).
    static func parse(masterPlaylist body: String) -> ParsedQuality? {
        var best: ParsedQuality?
        for rawLine in body.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("#EXT-X-STREAM-INF") else { continue }
            var height = 0
            if let r = line.range(of: "RESOLUTION=") {
                let token = line[r.upperBound...].prefix { $0 != "," }
                let parts = token.split(separator: "x")
                if parts.count == 2 { height = Int(parts[1]) ?? 0 }
            }
            var bandwidth = 0
            // Match BANDWIDTH / AVERAGE-BANDWIDTH at token
            // boundaries: "BANDWIDTH=" is a substring of
            // "AVERAGE-BANDWIDTH=", so a range(of:) search matches
            // the average value when it appears first and makes the
            // fallback unreachable. Split the attribute list (the
            // part after the "#EXT-X-STREAM-INF:" prefix) on ","
            // and match whole KEY= prefixes per token instead.
            // BANDWIDTH is primary; AVERAGE-BANDWIDTH is only the
            // fallback when no BANDWIDTH token is present.
            let attributeList = line.split(separator: ":", maxSplits: 1).last.map(String.init) ?? line
            var bandwidthValue: Int?
            var averageBandwidthValue: Int?
            for rawToken in attributeList.components(separatedBy: ",") {
                let token = rawToken.trimmingCharacters(in: .whitespaces)
                if token.hasPrefix("BANDWIDTH=") {
                    bandwidthValue = Int(token.dropFirst("BANDWIDTH=".count)) ?? 0
                } else if token.hasPrefix("AVERAGE-BANDWIDTH=") {
                    averageBandwidthValue = Int(token.dropFirst("AVERAGE-BANDWIDTH=".count)) ?? 0
                }
            }
            bandwidth = bandwidthValue ?? averageBandwidthValue ?? 0
            let q = ParsedQuality(height: height, bandwidth: bandwidth)
            if best == nil || q > best! { best = q }
        }
        return best
    }
}

/// What pre-flight learned about one candidate link. `verified`
/// carries the channel the player should use — the ladder entry
/// itself, unless the Referer-repair retry rewrote its referrer —
/// plus the parsed master-playlist quality when there was one.
/// `kept` means "not provably dead from this device": the source
/// is demoted behind every verified one, never dropped (see
/// SourcePreflight for the rules and the one deliberate deviation
/// from the plugin).
private enum PreflightOutcome: Sendable {
    case verified(Channel, ParsedQuality?)
    case kept(Channel)
    case dead
}

/// One-link pre-flight: the client port of the Nuvio addon's
/// verify-before-serve (research §3.1/§3.2), tuned to this app's
/// own measured doctrines (PlaylistStore.LinkProbe):
/// - Definitive death: HTTP 404/410, or HTTP 200 whose body is not
///   a playlist (fake-200 pages, empty bodies, variant-less and
///   segment-less stubs, takedown slates).
/// - 401/403 earns ONE retry with a repaired Referer derived from
///   the stream's own host; on success the repaired Referer is
///   written back into the channel, so the player sends it too
///   (LivePlayerSurface.asset already forwards channel.referrer).
///   A 403 that survives repair is KEPT but demoted, never
///   dropped: on this household's network a 403 can mean "the
///   tunnel is off right now" — the same reason the whole-list
///   validator never hides a link on 403. The plugin drops it;
///   the demotion is the deliberate local deviation.
/// - Transient failures (5xx, network errors, timeouts) retry —
///   3 attempts total, 0.5 s / 1.0 s backoff, 4 s per attempt —
///   all bounded by the session's hard deadline. A network-level
///   failure still failing after the retries counts as death only
///   for a channel that should be serving right now (live window
///   or 24/7); a 5xx never convicts on its own.
/// Nonisolated, like LinkProbe: it touches no actor state.
private enum SourcePreflight {

    static func verify(_ ch: Channel, session: URLSession, deadline: Date) async -> PreflightOutcome {
        guard let url = ch.streamURL else { return .dead }
        var attempt = 0
        while true {
            attempt += 1
            switch await fetch(ch, url: url, referrer: ch.referrer, session: session) {
            case .ok(let quality):
                return .verified(ch, quality)
            case .unauthorized:
                // Referer repair: one retry with the Referer the
                // stream's own host implies. Skipped when that is
                // the Referer already sent (nothing to repair).
                if let repaired = repairedReferer(for: url), repaired != ch.referrer {
                    switch await fetch(ch, url: url, referrer: repaired, session: session) {
                    case .ok(let quality):
                        let fixed = Channel(title: ch.title, logo: ch.logo, group: ch.group,
                                            url: ch.url, kickoff: ch.kickoff,
                                            leagueRank: ch.leagueRank,
                                            referrer: repaired, userAgent: ch.userAgent)
                        return .verified(fixed, quality)
                    case .unauthorized, .transient, .other:
                        return .kept(ch)
                    case .dead:
                        return .dead
                    }
                }
                return .kept(ch)
            case .dead:
                return .dead
            case .other:
                return .kept(ch)
            case .transient(let networkLevel):
                if Task.isCancelled { return .kept(ch) }
                if attempt >= 3 || Date() >= deadline {
                    if networkLevel && mustBeServing(ch) { return .dead }
                    return .kept(ch)
                }
                try? await Task.sleep(for: .milliseconds(attempt == 1 ? 500 : 1000))
                if Task.isCancelled { return .kept(ch) }
                if Date() >= deadline {
                    if networkLevel && mustBeServing(ch) { return .dead }
                    return .kept(ch)
                }
            }
        }
    }

    private enum FetchResult {
        case ok(ParsedQuality?)
        case unauthorized
        case dead
        case transient(networkLevel: Bool)
        case other
    }

    /// One bounded fetch: status first, then at most the first
    /// 16 KB of body — a playlist's identity and its variant list
    /// live in its head, and a direct-media URL must never be
    /// downloaded whole just to prove it exists (the whole-list
    /// validator caps its read the same way, at 4 KB).
    private static func fetch(_ ch: Channel, url: URL, referrer: String, session: URLSession) async -> FetchResult {
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        // The candidate's full header set: its declared pair,
        // plus — for addon (Nuvio) streams — the rest of the
        // behaviorHints.proxyHeaders set (Origin included) from
        // the registry. The explicit `referrer` argument (the
        // declared one, or the repaired one on the repair retry)
        // always wins. For a playlist channel the registry is
        // empty and this is exactly the old behaviour: the TV
        // default User-Agent when none is declared, a Referer
        // only when one is.
        for (field, value) in NuvioStreamHeaders.requestHeaders(for: ch, referrer: referrer) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            switch status {
            case 401, 403:
                return .unauthorized
            case 404, 410:
                return .dead
            case 500...599:
                return .transient(networkLevel: false)
            case 200:
                break // classify the body below
            default:
                return .other
            }
            var buffer = Data()
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count > 16_384 { break }
            }
            return classify(body: buffer, url: ch.url)
        } catch {
            return .transient(networkLevel: true)
        }
    }

    private static func classify(body: Data, url: String) -> FetchResult {
        if body.isEmpty { return .dead }
        let text = String(decoding: body, as: UTF8.self)
        let path = url.split(separator: "?").first.map(String.init) ?? url
        guard path.lowercased().hasSuffix(".m3u8") else {
            // Direct-media URL: a non-empty 200 body is all the
            // proof available at this layer (same rule as the
            // whole-list validator).
            return .ok(nil)
        }
        guard text.contains("#EXTM3U") else { return .dead }
        // A playlist with neither variants nor segments is a stub
        // (placeholder / takedown slate), not a stream.
        guard text.contains("#EXT-X-STREAM-INF") || text.contains("#EXTINF") else { return .dead }
        if text.lowercased().contains("takedown") { return .dead }
        return .ok(ParsedQuality.parse(masterPlaylist: text))
    }

    /// The Referer a stream's own host implies: scheme://host[:port]/
    /// — the plugin's host-derived repair reduced to its portable
    /// core (its registry/regex chain encodes its own providers).
    private static func repairedReferer(for url: URL) -> String? {
        guard let scheme = url.scheme, let host = url.host else { return nil }
        var out = "\(scheme)://\(host)"
        if let port = url.port { out += ":\(port)" }
        return out + "/"
    }

    /// "Should be serving right now": inside the live window, or a
    /// channel with no kickoff at all (24/7 streams). Same test the
    /// whole-list validator applies.
    private static func mustBeServing(_ ch: Channel, now: Date = Date()) -> Bool {
        ch.kickoff == nil || LeagueClassifier.bucket(of: ch, now: now) == 0
    }
}

/// One match's source-resolution session: verifies the store's
/// ladder in parallel and publishes the playable order
/// progressively — the client port of the Nuvio addon's progressive
/// publication (research §3.3), with its own numbers: quorum 3
/// verified, soft deadline 6 s, hard deadline 15 s.
///
/// Publication contract (the player depends on it):
/// - Nothing publishes until the quorum, or every candidate has
///   settled, or the soft deadline passes with at least one
///   verified source.
/// - The first publish is the verified batch ordered by parsed
///   quality (best first). After that, publication is APPEND-ONLY:
///   the published prefix never moves, so a player already walking
///   the ladder is never disturbed by a late arrival.
/// - Kept (unverifiable but not provably dead) sources append
///   last, in ladder order, when resolution settles or the hard
///   deadline passes. Dead sources never publish.
/// - When nothing at all is playable, sources stays empty and
///   isResolving settles false — the player shows its slate.
@MainActor
final class MatchPlaySession: ObservableObject {
    @Published private(set) var sources: [Channel] = []
    @Published private(set) var isResolving = true

    let key: String
    private var resolveTask: Task<Void, Never>?
    private var started = false

    nonisolated private static let quorum = 3
    nonisolated private static let softDeadline: TimeInterval = 6
    nonisolated private static let hardDeadline: TimeInterval = 15

    init(key: String) {
        self.key = key
    }

    /// A session born complete (fresh resolve-cache hit): the
    /// cached ladder publishes instantly, with no network at all.
    static func cached(key: String, sources: [Channel]) -> MatchPlaySession {
        let session = MatchPlaySession(key: key)
        session.sources = sources
        session.isResolving = false
        session.started = true
        return session
    }

    func begin(ladder: [Channel]) {
        guard !started else { return }
        started = true
        guard !ladder.isEmpty else {
            isResolving = false
            ResolveHub.shared.noteResolved(key: key, sources: [], from: self)
            return
        }
        resolveTask = Task { [weak self] in
            await self?.run(ladder: ladder)
        }
    }

    /// Stops the verification where it stands (a superseded
    /// pre-resolve pass). Whatever already published stays
    /// published; a cancelled session never writes the cache.
    func cancel() {
        resolveTask?.cancel()
    }

    /// Whether this session's resolve task has been cancelled.
    /// Task cancellation is recorded synchronously by cancel()
    /// (on the main actor), so the hub can treat a cancelled
    /// in-flight session as absent before run() notices and
    /// forgets it itself.
    var isCancelled: Bool {
        resolveTask?.isCancelled ?? false
    }

    private func run(ladder: [Channel]) async {
        let total = ladder.count
        let hardDeadline = Date().addingTimeInterval(Self.hardDeadline)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        var verified: [(Int, Channel, ParsedQuality?)] = []
        var kept: [(Int, Channel)] = []
        var settled = 0
        var published = false
        var softPassed = false
        var finalPublished = false

        /// Publish per the contract above. `final` also appends
        /// the kept tail.
        func publish(final: Bool) {
            let ordered = verified.sorted { a, b in
                switch (a.2, b.2) {
                case let (qa?, qb?):
                    if qa != qb { return qa > qb }
                    return a.0 < b.0
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return a.0 < b.0
                }
            }.map { $0.1 }
            if published {
                let have = Set(self.sources.map(\.url))
                self.sources += ordered.filter { !have.contains($0.url) }
            } else {
                self.sources = ordered
                published = true
            }
            if final {
                let have = Set(self.sources.map(\.url))
                self.sources += kept.sorted { $0.0 < $1.0 }.map { $0.1 }.filter { !have.contains($0.url) }
            }
        }

        await withTaskGroup(of: (Int, PreflightOutcome?).self) { group in
            for (i, ch) in ladder.enumerated() {
                group.addTask {
                    (i, await SourcePreflight.verify(ch, session: session, deadline: hardDeadline))
                }
            }
            // The deadlines ride the same group as nil outcomes:
            // the soft tick at 6 s, the hard tick at 15 s.
            group.addTask {
                try? await Task.sleep(for: .seconds(Self.softDeadline))
                return (-1, nil)
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(Self.hardDeadline))
                return (-2, nil)
            }
            for await (i, outcome) in group {
                if Task.isCancelled { break }
                if finalPublished { continue }
                switch (i, outcome) {
                case (-1, _):
                    softPassed = true
                    if !verified.isEmpty { publish(final: false) }
                case (-2, _):
                    publish(final: true)
                    finalPublished = true
                    group.cancelAll()
                case (_, .verified(let ch, let quality)?):
                    verified.append((i, ch, quality))
                    settled += 1
                    if settled == total {
                        publish(final: true)
                        group.cancelAll()
                    } else if verified.count >= Self.quorum || softPassed {
                        publish(final: false)
                    }
                case (_, .kept(let ch)?):
                    kept.append((i, ch))
                    settled += 1
                    if settled == total {
                        publish(final: true)
                        group.cancelAll()
                    }
                case (_, .dead?):
                    settled += 1
                    if settled == total {
                        publish(final: true)
                        group.cancelAll()
                    }
                default:
                    break
                }
            }
        }

        if Task.isCancelled {
            isResolving = false
            ResolveHub.shared.forgetInFlight(key: key, from: self)
            return
        }
        if !published { publish(final: true) }
        isResolving = false
        ResolveHub.shared.noteResolved(key: key, sources: sources, from: self)
    }
}

/// Resolve cache + single-flight hub (research §3.4): concurrent
/// opens of the same fixture share one in-flight session; a fresh
/// cached ladder replays instantly with no network; a fixture that
/// resolved to nothing playable is negative-cached for ~30 s, so a
/// dead fixture is not re-scraped on every tap; a healthy
/// re-resolve doubles the entry's TTL (60 s floor, 10 min cap),
/// while an empty resolve collapses the entry to the 30 s negative
/// TTL. In-memory only, capped at 100 entries (oldest evicted):
/// a cold start re-verifies from the device — the only vantage
/// point that shares the owner's network and tunnel.
@MainActor
final class ResolveHub {
    static let shared = ResolveHub()

    private struct Entry {
        var sources: [Channel]
        var storedAt: Date
        var ttl: TimeInterval
    }

    private var cache: [String: Entry] = [:]
    private var inFlight: [String: MatchPlaySession] = [:]
    private var preresolveTask: Task<Void, Never>?
    private var preresolveSessions: [MatchPlaySession] = []
    /// Sessions a tap has been handed (created by the tap, or a
    /// preresolve-created session the tap adopted via the
    /// single-flight table). A preresolve sweep never cancels
    /// these. Entries are dropped when the session leaves the
    /// in-flight table (noteResolved / forgetInFlight).
    private var tapAdopted: Set<ObjectIdentifier> = []

    private init() {}

    /// Cache identity of a ladder: its URLs, in order. Two
    /// different fixtures never share an ordered URL list; a
    /// refreshed playlist with different URLs is a different key
    /// and resolves fresh.
    static func key(for ladder: [Channel]) -> String {
        ladder.map(\.url).joined(separator: "\n")
    }

    /// The session for a ladder: the in-flight one if this fixture
    /// is already resolving (single-flight — a tap and a
    /// pre-resolve pass share it), else a born-complete session
    /// from a fresh cache entry, else a new session that starts
    /// verifying immediately.
    func session(for ladder: [Channel]) -> MatchPlaySession {
        session(for: ladder, isTap: true).session
    }

    /// The hub's core lookup. `createdFresh` is true only when
    /// this call created and started a brand-new session — a
    /// single-flight hit and a born-complete cached session are
    /// both not fresh. Only the preresolve pass uses the flag, to
    /// track exactly the sessions it owns. A tap call (isTap)
    /// also marks the returned live session tap-adopted and
    /// drops it from the preresolve-owned list, so a later sweep
    /// can never cancel a session a player is using.
    private func session(for ladder: [Channel], isTap: Bool) -> (session: MatchPlaySession, createdFresh: Bool) {
        let key = Self.key(for: ladder)
        if let live = inFlight[key] {
            if live.isCancelled {
                // A cancelled session remains in the table until
                // its run() notices and forgets it, but it will
                // settle empty, publish nothing further and write
                // no cache — treat it as absent: forget it with
                // the same bookkeeping as a self-noticed
                // cancellation and fall through to a fresh session.
                forgetInFlight(key: key, from: live)
            } else {
                if isTap { noteTapAdoption(of: live) }
                return (live, false)
            }
        }
        if let entry = cache[key],
           Date().timeIntervalSince(entry.storedAt) < entry.ttl {
            return (MatchPlaySession.cached(key: key, sources: entry.sources), false)
        }
        DiagLog.log("player",
                    "resolve: new session for '\(ladder.first?.title ?? "?")' "
                    + "(\(ladder.count) sources)")
        let session = MatchPlaySession(key: key)
        inFlight[key] = session
        if isTap { noteTapAdoption(of: session) }
        session.begin(ladder: ladder)
        return (session, true)
    }

    private func noteTapAdoption(of session: MatchPlaySession) {
        tapAdopted.insert(ObjectIdentifier(session))
        preresolveSessions.removeAll { $0 === session }
    }

    /// Pre-resolve the fixtures the first screen leads with (the
    /// client analogue of the addon's pre-warming, research §3.5):
    /// bounded to the first three ladders, started one at a time.
    /// A new call supersedes the previous pass — sessions it
    /// started are cancelled where they stand and no further
    /// fixtures start. Sessions begun by a tap are never touched.
    func preresolve(ladders: [[Channel]]) {
        preresolveTask?.cancel()
        // Cancel only sessions this pass owns: still resolving and
        // never handed to a tap. (Adopted sessions are also removed
        // from preresolveSessions at adoption time — the tapAdopted
        // check here is the second line of defence.)
        for session in preresolveSessions
        where session.isResolving && !tapAdopted.contains(ObjectIdentifier(session)) {
            session.cancel()
        }
        preresolveSessions = []
        let batch = Array(ladders.prefix(3))
        guard !batch.isEmpty else { return }
        preresolveTask = Task { [weak self] in
            for ladder in batch {
                if Task.isCancelled { return }
                guard let self else { return }
                // Track only sessions this pass created fresh: a
                // single-flight hit may be a tap's session (or a
                // cached replay), which this pass must never cancel.
                let result = self.session(for: ladder, isTap: false)
                if result.createdFresh {
                    self.preresolveSessions.append(result.session)
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    /// Called by a session when its resolution settles: leaves the
    /// in-flight table and writes the cache entry. Identity-guarded:
    /// a session that has been replaced in the in-flight table by a
    /// different session must not evict that replacement or
    /// overwrite its cache entry, so the write is dropped when
    /// `inFlight[key]` holds a different session object.
    func noteResolved(key: String, sources: [Channel], from session: MatchPlaySession) {
        if let live = inFlight[key] {
            guard live === session else { return }
            tapAdopted.remove(ObjectIdentifier(live))
        }
        inFlight[key] = nil
        let ttl: TimeInterval
        if sources.isEmpty {
            ttl = 30 // negative entry — see the type doc
        } else if let previous = cache[key] {
            ttl = min(previous.ttl * 2, 600)
        } else {
            ttl = 60
        }
        cache[key] = Entry(sources: sources, storedAt: Date(), ttl: ttl)
        if cache.count > 100,
           let oldest = cache.min(by: { $0.value.storedAt < $1.value.storedAt })?.key {
            cache[oldest] = nil
        }
    }

    /// A cancelled session leaves the in-flight table without
    /// writing the cache, so the next open resolves it fresh.
    /// Identity-guarded: the entry — and its tap-adoption
    /// bookkeeping — is dropped only when the table still holds
    /// the session being forgotten; a stale session unwinding
    /// after a replacement took over its key must not evict the
    /// live replacement.
    func forgetInFlight(key: String, from session: MatchPlaySession) {
        guard let live = inFlight[key], live === session else { return }
        tapAdopted.remove(ObjectIdentifier(live))
        inFlight[key] = nil
    }
}
