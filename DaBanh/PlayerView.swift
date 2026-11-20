import AVFoundation
import AVKit
import MediaPlayer
import SwiftUI
import UIKit

/// Player page (v1.16): a CUSTOM player surface — an AVPlayerLayer
/// with the app's own control layer — embedded full-bleed, exactly
/// like the JTV app's player. One chrome only: close, title,
/// play/pause, AirPlay, PiP and the fit/fill toggle all live in one
/// control layer that fades together after 3.5 s — but the fade
/// only ever starts once playback is actually ready (DB-05):
/// while a source is still loading, or the ladder is advancing
/// to the next one, the chrome — the close button included —
/// stays visible and tappable, so the viewer is never trapped
/// on a black screen with no exit.
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
                .onAppear {
                    DiagLog.log("player",
                                "no signal: ladder exhausted at #\(index) — "
                                + "'\(headerEntry.map { MatchTitle.clean($0.channel.title) } ?? session.key)'")
                }
                closeButton
            } else if let channel = current, channel.streamURL != nil {
                LivePlayerSurface(
                    channel: channel, onFail: advance,
                    onReady: {
                        switching = false
                        // DB-07: the first frame is up — deep-warm
                        // the rest of the ladder behind it (see
                        // SourcePrewarmStore). Idempotent: a ready
                        // after a switch just re-prioritises what
                        // is still cold. Pure background work.
                        session.beginPrewarming(after: index)
                    },
                    onDefinitiveFail: { reason in
                        // FIX-129 (Item C): a DEFINITIVE player
                        // failure (see LivePlayerViewController's
                        // classifier) teaches the session: the
                        // URL is marked dead for the session and
                        // the hub, so no later merge, publish or
                        // tap hands it to a player again.
                        session.markPlayerDead(channel, reason: reason)
                    }, onClose: { dismiss() },
                    sourceIndex: index,
                    showsSourceSwitch: headerEntry != nil,
                    onSourceSwitch: {
                        DiagLog.log("player",
                                    "source switch: board opened at source #\(index)")
                        sourceBoardPresented = true
                    },
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
                .onAppear {
                    // FIX-128: the waiting anchor — the player
                    // has walked past the published ladder but
                    // resolution is still running, so it holds
                    // for the next published batch instead of
                    // declaring signal loss (that slate requires
                    // settledExhausted: settled AND walked past).
                    DiagLog.log("player",
                                "player waiting: past the published ladder at "
                                + "#\(index), resolution still running — "
                                + "holding for the next batch")
                }
                closeButton
            }
        }
        .onAppear {
            DiagLog.log("player",
                        "open: '\(headerEntry.map { MatchTitle.clean($0.channel.title) } ?? current.map { MatchTitle.clean($0.title) } ?? session.key)' "
                        + "starting at source #\(index) (resolving=\(session.isResolving))")
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
            DiagLog.log("player", "close: player view gone at source #\(index)")
            session.endPrewarming()
            // FIX-127B: no orientation widen here. A Đổi
            // nguồn route flip replaces this view in place
            // inside the still-up cover, and SwiftUI gives
            // no ordering guarantee against the incoming
            // view's onAppear — an unconditional widen could
            // land last and leave the swapped-to player
            // portrait-capable. The lock now follows the
            // presentation: ContentView asserts landscape
            // from the route state and widens to .all only
            // in the cover's onDismiss (a genuine close).
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
                DiagLog.log("player",
                            "source switch VN in place: #\(index) -> #\(position) \(diagSourceTag(channel))")
                index = position
                switching = true
            } else {
                DiagLog.log("player",
                            "source switch VN: already playing \(diagSourceTag(channel))")
            }
        } else {
            DiagLog.log("player",
                        "source switch VN via host cover-swap: \(diagSourceTag(channel))")
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
        guard meta.id != currentENMetaID else {
            DiagLog.log("player",
                        "source switch EN: already playing '\(meta.name)'")
            return
        }
        DiagLog.log("player",
                    "source switch EN via host cover-swap: '\(meta.name)'")
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
        if let channel = current {
            DiagLog.log("player",
                        "advance: leaving source #\(index) \(diagSourceTag(channel))")
        } else {
            DiagLog.log("player",
                        "advance: past the published ladder at #\(index)")
        }
        index += 1
        // DB-07: a source pre-warming proved dead while an
        // earlier rung played is skipped in place — the ladder
        // steps over it instantly instead of spending a player
        // load on it. Only the automatic advance skips: an
        // explicit board pick (switchToVN) always tries the
        // row the viewer chose.
        while let ch = current, session.isWarmedDead(ch.url) {
            DiagLog.log("player",
                        "advance: skipping pre-warm-dead source #\(index) \(diagSourceTag(ch))")
            index += 1
        }
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

/// One-line source descriptor for DiagLog (DB-06): the cleaned
/// title plus the stream's host — never the full URL, because
/// stream URLs can carry tokens; the existing resolve lines in
/// this file set the same title-only style.
private func diagSourceTag(_ channel: Channel) -> String {
    let host = channel.streamURL?.host ?? URL(string: channel.url)?.host ?? "?"
    return "'\(MatchTitle.clean(channel.title))' host=\(host)"
}

/// SwiftUI wrapper around the custom live-player surface. Plays
/// immediately on appear; pauses and releases on dismantle. The
/// asset carries exactly the headers the entry itself declared
/// (#EXTVLCOPT).
struct LivePlayerSurface: UIViewControllerRepresentable {
    let channel: Channel
    let onFail: () -> Void
    let onReady: () -> Void
    /// FIX-129 (Item C): a DEFINITIVE failure of this surface's
    /// source, classified by the view controller (TLS/certificate
    /// invalid, or HTTP 403/404 in the item's access log), with a
    /// short reason tag. Optional: surfaces that pass nil keep
    /// the pre-FIX-129 behaviour exactly.
    var onDefinitiveFail: ((String) -> Void)? = nil
    let onClose: () -> Void
    /// This surface's rung on the ladder, for DiagLog lines.
    var sourceIndex: Int = 0
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
        controller.sourceIndex = sourceIndex
        controller.onFail = onFail
        controller.onReady = onReady
        controller.onDefinitiveFail = onDefinitiveFail
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
    /// This surface's rung on the ladder, for DiagLog lines.
    var sourceIndex = 0
    var onFail: (() -> Void)?
    var onReady: (() -> Void)?
    /// FIX-129 (Item C): fired (with a reason tag) when this
    /// surface's failure is DEFINITIVE — see
    /// definitiveFailureReason(for:) — just before onFail.
    var onDefinitiveFail: ((String) -> Void)?
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
    /// FIX-129 (Item C): the playing item, kept so its access
    /// log can be read at failure time (the HTTP status of the
    /// request that failed lives there, not in item.error).
    private var playerItem: AVPlayerItem?
    private var pipController: AVPictureInPictureController?
    private var statusToken: NSKeyValueObservation?
    private var timeControlToken: NSKeyValueObservation?
    private var failToken: NSObjectProtocol?
    private var firedFail = false
    private var firedReady = false
    private var firedPlaying = false
    private var hideTimer: Timer?
    private var controlsVisible = true
    private var torn = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let channel else { return }
        DiagLog.log("player",
                    "try source #\(sourceIndex): \(diagSourceTag(channel))")

        // Audio session for background / PiP playback.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)

        let item = AVPlayerItem(asset: LivePlayerSurface.asset(for: channel))
        playerItem = item
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
        // DB-05: NO hide timer here. The chrome starts visible and
        // stays visible until the item is ready to play — the
        // fade clock starts in the ready handler below, and
        // scheduleControlsHide() itself refuses to run before
        // that, so no path can fade the close button out from
        // under a viewer who is still waiting for signal.
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
            let itemError = item.error
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch status {
                case .readyToPlay:
                    if !firedReady {
                        firedReady = true
                        if let channel {
                            DiagLog.log("player",
                                        "source #\(sourceIndex) ready: \(diagSourceTag(channel))")
                        }
                        self.onReady?()
                        // DB-05: the 3.5 s fade clock starts HERE —
                        // only once playback is real.
                        self.scheduleControlsHide()
                    }
                case .failed:
                    noteFailure(itemError)
                default:
                    break
                }
            }
        }
        failToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self] note in
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey]
                as? Error
            self?.noteFailure(error)
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

    /// DB-06: write the failure (with AVFoundation's reason when
    /// it offers one) exactly once per surface, then run the
    /// page's fail path. Both failure signals (item status and
    /// the failed-to-end notification) funnel through here; the
    /// firedFail guard keeps it to a single line.
    private func noteFailure(_ error: Error?) {
        guard !firedFail else { return }
        if let channel {
            DiagLog.log("player",
                        "source #\(sourceIndex) failed: \(diagSourceTag(channel))"
                        + (error.map { " — \($0.localizedDescription)" } ?? ""))
        }
        // FIX-129 (Item C): a definitive failure teaches the
        // session BEFORE the page advances, so the resolve
        // still running behind this player cannot merge the
        // same URL back onto the ladder (see markPlayerDead).
        if let reason = definitiveFailureReason(for: error) {
            onDefinitiveFail?(reason)
        }
        fireFailOnce()
    }

    /// FIX-129 (Item C): classify a PLAYER-observed failure as
    /// definitive, or not. Definitive means the URL itself is
    /// condemned for this app run — the failure cannot heal
    /// within the session:
    /// - HTTP 403 / 404, read from the item's ACCESS LOG
    ///   (AVPlayerItemAccessLogEvent.errorStatusCode — the most
    ///   recent error event at failure time): AVPlayerItem.error
    ///   does not carry the HTTP status, the access log does.
    /// - A TLS/certificate failure: NSURLErrorDomain secure-
    ///   connection codes (-1200…-1206: failed, bad date,
    ///   untrusted, unknown root, not yet valid, client cert
    ///   rejected/required), searched through the underlying-
    ///   error chain, with the stable localized text
    ///   ("…certificate…") as a fallback when the error arrives
    ///   wrapped in an AVFoundation domain.
    /// Everything else — timeouts, stalls, 5xx, generic network
    /// errors — returns nil and marks NOTHING (house doctrine:
    /// only definitive verdicts condemn).
    ///
    /// How this differs from pre-flight's KEPT-403: pre-flight's
    /// 403 is a bare probe's answer, which on this household's
    /// network can mean "the tunnel is off right now", so the
    /// source is kept (demoted, still playable). A 403 the
    /// PLAYER receives is a different observation: the source
    /// had already been published to the viewer — verified, or
    /// the instant head he picked — and the full playback
    /// request, with the channel's own headers and repaired
    /// Referer, was still refused (or the playlist is simply
    /// gone: 404). That verdict is about THIS URL as served to
    /// the player, and it condemns only that URL, for this
    /// session/run — pre-flight's kept-403 handling is
    /// untouched and still governs sources the player has not
    /// tried.
    private func definitiveFailureReason(for error: Error?) -> String? {
        if let events = playerItem?.errorLog()?.events {
            for event in events.reversed() where event.errorStatusCode != 0 {
                if event.errorStatusCode == 403 || event.errorStatusCode == 404 {
                    return "HTTP \(event.errorStatusCode)"
                }
                break // the newest error event is not a 403/404
            }
        }
        var current = error as NSError?
        var depth = 0
        while let ns = current, depth < 3 {
            if ns.domain == NSURLErrorDomain, (-1206 ... -1200).contains(ns.code) {
                return "TLS/certificate invalid"
            }
            current = ns.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        if let text = error?.localizedDescription.lowercased(),
           text.contains("certificate") {
            return "TLS/certificate invalid"
        }
        return nil
    }

    private func refreshPlaybackUI(_ player: AVPlayer) {
        switch player.timeControlStatus {
        case .playing:
            spinner.stopAnimating()
            playPauseButton.setImage(UIImage(systemName: "pause.fill"), for: .normal)
            if !firedPlaying {
                firedPlaying = true
                // DB-07: the tap→play timeline's last anchor —
                // frames are actually flowing (distinct from
                // .readyToPlay, which only promises them).
                if let channel {
                    DiagLog.log("player",
                                "playback started: source #\(sourceIndex) \(diagSourceTag(channel))")
                }
            }
            // Playback is (again) real: resume the normal fade.
            scheduleControlsHide()
        case .waitingToPlayAtSpecifiedRate:
            spinner.startAnimating()
            // DB-05: while the spinner runs — first load or a
            // mid-stream stall — the chrome stays up, close
            // button included; any pending fade is cancelled.
            keepControlsVisible()
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
        // N-1 (REVIEW-125-LOOP1): before the first ready a tap
        // must never hide the chrome — the close button has to
        // stay reachable for the whole wait, even when the item
        // sits in one waiting state without a status change to
        // re-pin it. Pre-ready taps only show / keep visible.
        guard firedReady else {
            keepControlsVisible()
            return
        }
        controlsVisible.toggle()
        UIView.animate(withDuration: 0.25) { self.controlsView.alpha = self.controlsVisible ? 1 : 0 }
        if controlsVisible { scheduleControlsHide() } else { hideTimer?.invalidate() }
    }

    private func showControls() {
        controlsVisible = true
        UIView.animate(withDuration: 0.25) { self.controlsView.alpha = 1 }
        scheduleControlsHide()
    }

    /// DB-05: pin the chrome on screen — used whenever the
    /// player is waiting for signal (the spinner is running).
    private func keepControlsVisible() {
        hideTimer?.invalidate()
        if !controlsVisible {
            controlsVisible = true
            UIView.animate(withDuration: 0.25) { self.controlsView.alpha = 1 }
        }
    }

    private func scheduleControlsHide() {
        hideTimer?.invalidate()
        // DB-05: the fade NEVER starts before the first ready —
        // before that the viewer is still waiting for signal and
        // the close button must stay. Every caller (show, toggle,
        // stall recovery) funnels through this one guard.
        guard firedReady else { return }
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
        playerItem = nil
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
    /// The ladder begin() received, kept for publishHeadNow():
    /// the hub hands a tap its session before the cover reads
    /// sources, and the head must be publishable from the
    /// ladder itself, not from anything verification produced.
    private var ladderSnapshot: [Channel] = []
    /// DB-07: a tap published the head unverified (see
    /// publishHeadNow) — run()'s publications append behind
    /// it from then on, exactly as after a verified publish.
    private var headPublished = false
    /// FIX-128: the "ladder first batch" DiagLog line fires
    /// once per session, at run()'s first publication.
    private var didLogFirstBatch = false
    /// FIX-128B: run() has made its FINAL publication (the
    /// one that appends the kept tail — including a final
    /// publication that lands ZERO rungs: every candidate
    /// dead, or the hard deadline empty-handed). Set inside
    /// publish(final:) at the moment of that publish, so it
    /// is already true while run() is still draining its
    /// task group afterwards. adoptSeed and publishHeadNow
    /// both refuse once this is set: after the final publish
    /// the ladder is settled, and nothing may be injected
    /// into it for noteResolved to mistake for this run's
    /// own result (REVIEW-128-LOOP1 F-1).
    private var didPublishFinal = false
    /// FIX-129 (Item C): URLs the PLAYER itself failed with a
    /// definitive error during this session (see
    /// markPlayerDead). run()'s publications never merge one
    /// back onto the ladder, and the settle writes them into
    /// the cache entry's dead set, so the condemnation outlives
    /// the session through ResolveHub.provenDead.
    private var playerDeadURLs: Set<String> = []

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

    /// FIX-128: a session born with a STALE resolve-cache
    /// ladder already published (the tvOS read path: a cached
    /// resolution is adopted, never discarded for age — see
    /// ResolveHub). The replayed ladder excludes every source
    /// the resolve that produced it proved dead (the cache
    /// write filters them), so the player starts on a
    /// previously-verified rung in the same state change as
    /// the tap; `beginRevalidation(ladder:)` then re-resolves
    /// behind it and run()'s publications merge into the
    /// replayed ladder exactly as behind an instant head (the
    /// published prefix never moves). The hub registers the
    /// session in its in-flight table before calling
    /// beginRevalidation, so the settle-time hub writes meet
    /// their identity guards satisfied.
    static func seeded(key: String, sources: [Channel]) -> MatchPlaySession {
        let session = MatchPlaySession(key: key)
        session.sources = sources
        session.headPublished = true
        session.started = true
        return session
    }

    /// FIX-128: replay a stale cached ladder into this
    /// session while it is still empty (a tap adopting an
    /// in-flight session whose verification has not published
    /// yet — the board-open pre-resolve in the 285 s case).
    /// The replay becomes the published prefix: this session's
    /// own publications merge behind it exactly as behind an
    /// instant head, so verification continues behind a ladder
    /// the player can already walk. No-op once anything has
    /// published — a live ladder is never re-based.
    /// FIX-128B: "anything has published" includes a final
    /// publish that landed ZERO rungs (sources stays empty,
    /// so the sources.isEmpty check alone cannot see it):
    /// the didPublishFinal gate is what refuses the seed
    /// while run() drains its task group after that publish.
    func adoptSeed(_ seed: [Channel]) {
        guard isResolving, !didPublishFinal, sources.isEmpty, !seed.isEmpty else { return }
        headPublished = true
        sources = seed
    }

    /// Starts the background re-resolution behind a seeded
    /// (stale-adopted) ladder. The current ladder is verified
    /// in full; nothing about the replayed prefix changes
    /// while it runs.
    func beginRevalidation(ladder: [Channel]) {
        ladderSnapshot = ladder
        guard !ladder.isEmpty else {
            // Unreachable through the hub (a stale entry's key
            // is its ladder's URLs, so a matching empty ladder
            // means an empty entry, which never takes the
            // stale path) — kept to begin()'s shape: an empty
            // ladder settles as a negative entry.
            isResolving = false
            ResolveHub.shared.noteResolved(key: key, sources: [], from: self)
            return
        }
        resolveTask = Task { [weak self] in
            await self?.run(ladder: ladder)
        }
    }

    func begin(ladder: [Channel]) {
        guard !started else { return }
        started = true
        ladderSnapshot = ladder
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

    /// DB-07 (plan D): publish the ladder's head the moment a
    /// tap adopts this session — before any verification. The
    /// head of a tap's ladder is the row the viewer picked
    /// (callers rotate it to the front) and its URL is already
    /// final in the playlist data, so the player starts on it
    /// at once; verification keeps running behind it and its
    /// publications APPEND from here on (run()'s publish
    /// honours headPublished), so the playing rung never
    /// moves. If the head proves dead, the player's own fail
    /// path advances past it — and run() keeps a proven-dead
    /// head out of the cache entry, so the next open does not
    /// inherit it as a proven source.
    ///
    /// FIX-128: the head publish is FILTERED by the verdicts
    /// this app run already holds (the hub's proven-dead set,
    /// fed by every settled resolve, and the pre-warm store's
    /// dead set — both definitive-death only, see isKnownDead).
    /// A picked head already verdicted dead is never handed
    /// to the player to die on again: the first ladder rung
    /// not known dead publishes in its place (the pick's row
    /// stays on the board, marked by the verdicts there; the
    /// session's own verification still re-checks every rung
    /// behind, so a revived source returns through run()'s
    /// publications). When EVERY rung is known dead nothing
    /// publishes here — the session settles on its own
    /// evidence and the player shows its slate, instead of
    /// replaying a death the app already knows.
    ///
    /// FIX-128B: the head publish also refuses once run()
    /// has made its final publication (didPublishFinal): a
    /// session draining its task group after an empty final
    /// publish is settled, and an instant head injected in
    /// that window would be written into the cache by
    /// noteResolved as if it were the run's own result —
    /// the same F-1 window adoptSeed is gated against.
    func publishHeadNow() {
        guard isResolving, !didPublishFinal, sources.isEmpty,
              let head = ladderSnapshot.first else { return }
        if isKnownDead(head) {
            guard let substitute = ladderSnapshot.first(where: { !isKnownDead($0) })
            else { return }
            headPublished = true
            sources = [substitute]
            DiagLog.log("player",
                        "instant head: picked source \(diagSourceTag(head)) "
                        + "already proven dead this run — starting at "
                        + "\(diagSourceTag(substitute)) instead, "
                        + "verification continues behind it")
            return
        }
        headPublished = true
        sources = [head]
        DiagLog.log("player",
                    "instant head: '\(MatchTitle.clean(head.title))' "
                    + "published unverified for the tap — verification continues behind it")
    }

    /// FIX-128: definitive death as this app run has already
    /// judged it — a settled resolve's verdict (the hub's
    /// proven-dead set) or a deep-warm verdict (the pre-warm
    /// store). Both sources convict on pre-flight's standard
    /// only (404/410, a fake-200 body, or a network failure
    /// while the source should be serving); a 403 that
    /// survived Referer repair is KEPT there, never dead, so
    /// the tunnel-off case is never filtered here.
    private func isKnownDead(_ ch: Channel) -> Bool {
        ResolveHub.shared.isProvenDead(ch.url)
            || SourcePrewarmStore.shared.isDead(ch.url)
    }

    /// DB-07: the first frame is up (the view calls this on
    /// every ready) — deep-warm the rest of the ladder behind
    /// the playing rung in the shared pre-warm store. Pure
    /// background work; it never blocks or slows playback.
    func beginPrewarming(after index: Int) {
        let ladder = sources
        guard ladder.count > 1, ladder.indices.contains(index) else { return }
        let current = ladder[index]
        SourcePrewarmStore.shared.warm(
            ladder: ladder, startingAfter: current.url,
            excluding: [current.url])
    }

    /// The player closed: stop spending bandwidth on warm-ups
    /// that have not started yet.
    func endPrewarming() {
        SourcePrewarmStore.shared.cancelPending()
    }

    /// A source the pre-warmer proved dead (see
    /// SourcePrewarmStore): the player's automatic advance
    /// skips it without spending a player load on it.
    func isWarmedDead(_ url: String) -> Bool {
        SourcePrewarmStore.shared.isDead(url)
    }

    /// FIX-129 (Item C): the player failed this source with a
    /// DEFINITIVE error (TLS/certificate invalid, HTTP 403/404
    /// — classified in LivePlayerViewController). Until now a
    /// player failure taught the ladder nothing: in the 1.28
    /// device log the Castilla head died on an invalid
    /// certificate at 21:35:20Z and the resolve's first batch
    /// one second later merged the SAME URL back in place, and
    /// a second pick re-tried the same host for seconds. The
    /// mark lands in three places: this session's exclusion set
    /// (run()'s merge honours it — see publish(final:)), the
    /// hub's provenDead (so publishHeadNow filters the URL for
    /// every later tap this run, and this session's settle
    /// writes it into the cache entry's dead set), and one
    /// DiagLog line per URL.
    func markPlayerDead(_ ch: Channel, reason: String) {
        guard playerDeadURLs.insert(ch.url).inserted else { return }
        let host = ch.streamURL?.host ?? URL(string: ch.url)?.host ?? "?"
        DiagLog.log("player", "player-dead: \(host) — \(reason)")
        ResolveHub.shared.notePlayerDead(url: ch.url)
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
        var deadURLs = Set<String>()
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
            // Merge into the published ladder: a channel whose
            // URL is already on the ladder replaces that rung IN
            // PLACE — pre-flight's verified copy can carry a
            // repaired Referer the instant head went out without,
            // and dropping it on URL alone (the old dedup) left
            // the live ladder holding the unrepaired original.
            // The rung's position never changes; only genuinely
            // new URLs append behind.
            func merge(_ incoming: [Channel]) {
                for ch in incoming {
                    // FIX-129 (Item C): a URL the player has
                    // definitively condemned this session never
                    // merges back — neither as a replacement of
                    // its own rung (the Castilla shape: the
                    // instant head died on a certificate error
                    // and the first batch re-published the same
                    // URL in place) nor as an append. A rung
                    // already published stays published (the
                    // prefix never moves); the player has
                    // already advanced past it.
                    if self.playerDeadURLs.contains(ch.url) { continue }
                    if let rung = self.sources.firstIndex(where: { $0.url == ch.url }) {
                        self.sources[rung] = ch
                    } else {
                        self.sources.append(ch)
                    }
                }
            }
            if published || self.headPublished {
                // DB-07: with an instant head already published,
                // the verified batch appends behind it like any
                // later publication — the head rung never moves.
                merge(ordered)
            } else {
                self.sources = ordered
                published = true
            }
            if final {
                // FIX-128B: mark the settle as the kept tail
                // merges — publish() never suspends, so the
                // flag and the merge land atomically with
                // respect to any tap vending this session
                // while run() drains its task group below.
                self.didPublishFinal = true
                merge(kept.sorted { $0.0 < $1.0 }.map { $0.1 })
            }
            // FIX-128: the first-batch anchor of the resolve
            // timeline — the moment the first verified (or
            // kept-tail) publication lands on the ladder.
            if !self.didLogFirstBatch, !self.sources.isEmpty {
                self.didLogFirstBatch = true
                DiagLog.log("player",
                            "ladder first batch: \(self.sources.count) source(s) "
                            + "published for "
                            + "'\(ladder.first.map { MatchTitle.clean($0.title) } ?? "?")'")
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
                    deadURLs.insert(ladder[i].url)
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
        // DB-07: the live ladder keeps the instant head even
        // when pre-flight later proved it dead (the published
        // prefix never moves under a live player), but the
        // cache entry must not inherit a proven-dead source as
        // playable — the next open resolves it fresh instead.
        ResolveHub.shared.noteResolved(
            key: key,
            sources: sources.filter {
                !deadURLs.contains($0.url) && !playerDeadURLs.contains($0.url)
            },
            deadURLs: deadURLs.union(playerDeadURLs),
            verifiedURLs: Set(verified.map { $0.1.url }),
            from: self)
    }
}

/// One source's deep warm (DB-07, plan D): fetch the playlist,
/// descend a master playlist to its best variant's media
/// playlist, then pull the first segment's head — so the CDN
/// edge nearest this phone and the provider's session are warm
/// before the viewer ever switches to the source, and a source
/// that is provably dead at warm time is known before the
/// ladder spends a player load on it.
///
/// Death is judged at the top playlist only, on exactly
/// pre-flight's standard (HTTP 404/410, or a 200 whose body
/// is not a playlist / is a takedown slate); anything
/// transient — 5xx, 401/403 (the Referer-repair question is
/// pre-flight's, already settled for published sources),
/// network errors — leaves the source merely unwarmed, never
/// marked. The variant and segment fetches below the top
/// playlist run for their warming value only and never
/// judge: a source can lose its top variant, or its oldest
/// segment to the sliding live window, while it still plays.
/// Nonisolated, like SourcePreflight: it touches no actor
/// state.
private enum SourcePrewarmer {

    /// True only on definitive death.
    static func warm(_ ch: Channel, session: URLSession) async -> Bool {
        guard let url = ch.streamURL else { return true }
        guard let head = await fetch(ch, url: url, limit: 16_384, session: session)
        else { return false }
        switch head.status {
        case 404, 410: return true
        case 200: break
        default: return false
        }
        let path = ch.url.split(separator: "?").first.map(String.init) ?? ch.url
        guard path.lowercased().hasSuffix(".m3u8") else {
            // Direct-media URL: nothing structured to prime.
            return false
        }
        let text = String(decoding: head.body, as: UTF8.self)
        guard isPlaylist(text) else { return true }
        var mediaText = text
        var mediaBase = url
        if text.contains("#EXT-X-STREAM-INF"),
           let variant = bestVariantURL(in: text, base: url) {
            // The descent still runs — fetching the variant
            // playlist is most of the warming value — but its
            // answer never judges (see the death rule above):
            // a failed descent just ends the warm here.
            guard let media = await fetch(ch, url: variant, limit: 16_384, session: session),
                  media.status == 200
            else { return false }
            let variantText = String(decoding: media.body, as: UTF8.self)
            guard isPlaylist(variantText) else { return false }
            mediaText = variantText
            mediaBase = variant
        }
        if let segment = firstSegmentURL(in: mediaText, base: mediaBase) {
            // Pulled for its warming value only: a 404/410
            // here judges nothing — the oldest segment of a
            // sliding live window can expire between the
            // playlist fetch and this one while the source
            // plays on.
            _ = await fetch(ch, url: segment, limit: 256 * 1024, session: session)
        }
        return false
    }

    private static func isPlaylist(_ text: String) -> Bool {
        text.contains("#EXTM3U")
            && (text.contains("#EXT-X-STREAM-INF") || text.contains("#EXTINF"))
            && !text.lowercased().contains("takedown")
    }

    /// One bounded fetch in pre-flight's shape: the channel's
    /// declared header set, a 4 s request timeout, at most
    /// `limit` bytes of body read. Nil on a network-level error.
    private static func fetch(_ ch: Channel, url: URL, limit: Int,
                              session: URLSession) async -> (status: Int, body: Data)? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        for (field, value) in NuvioStreamHeaders.requestHeaders(for: ch, referrer: ch.referrer) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            var buffer = Data()
            if status == 200 {
                for try await byte in bytes {
                    buffer.append(byte)
                    if buffer.count > limit { break }
                }
            }
            return (status, buffer)
        } catch {
            return nil
        }
    }

    /// The variant the player meets first when it opens a
    /// master playlist: the highest-BANDWIDTH #EXT-X-STREAM-INF
    /// entry (token-boundary attribute parsing, as in
    /// ParsedQuality.parse).
    private static func bestVariantURL(in text: String, base: URL) -> URL? {
        var best: (bandwidth: Int, uri: String)?
        var pendingBandwidth: Int?
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-STREAM-INF") {
                let attributeList = line.split(separator: ":", maxSplits: 1).last.map(String.init) ?? line
                var bandwidth = 0
                for rawToken in attributeList.components(separatedBy: ",") {
                    let token = rawToken.trimmingCharacters(in: .whitespaces)
                    if token.hasPrefix("BANDWIDTH=") {
                        bandwidth = Int(token.dropFirst("BANDWIDTH=".count)) ?? 0
                    }
                }
                pendingBandwidth = bandwidth
            } else if !line.isEmpty, !line.hasPrefix("#"), let bw = pendingBandwidth {
                if best == nil || bw > best!.bandwidth { best = (bw, line) }
                pendingBandwidth = nil
            }
        }
        guard let uri = best?.uri else { return nil }
        return URL(string: uri, relativeTo: base)?.absoluteURL
    }

    /// The first segment a media playlist declares.
    private static func firstSegmentURL(in text: String, base: URL) -> URL? {
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            return URL(string: line, relativeTo: base)?.absoluteURL
        }
        return nil
    }
}

/// The shared pre-warm queue (DB-07, plan D): deep-warms match
/// sources in the background — from the moment a fixture's link
/// board opens (the viewer's intent is on screen) and continuing
/// inside the player behind the playing source. Priority is the
/// ladder's own order, re-based behind the playing rung when
/// the player asks; at most two warm fetches run at once, every
/// fetch is byte-capped, and the queue only ever touches
/// network state — playback is never blocked by it. A source it
/// proves dead is remembered for the rest of the app run, so
/// the player's automatic advance can skip that rung instantly
/// (PlayerView.advance); an explicit board pick still tries
/// the row the viewer chose. Warmth is per app run: a source
/// warmed or proven dead once is not re-fetched for later
/// boards or sessions of the same fixture.
@MainActor
final class SourcePrewarmStore {
    static let shared = SourcePrewarmStore()

    private enum WarmState { case warming, warm, dead }
    private var states: [String: WarmState] = [:]
    private var pending: [Channel] = []
    private var driver: Task<Void, Never>?
    private var driverToken: UUID?

    private init() {}

    func isDead(_ url: String) -> Bool { states[url] == .dead }

    /// Enqueue a ladder for warming. `startingAfter` re-bases
    /// the priority: the rungs behind that URL go first (the
    /// order the ladder would advance through them), the
    /// earlier rungs after. Sources already warm, warming,
    /// proven dead or explicitly excluded are skipped; the
    /// pending queue is rebuilt in the newest priority order
    /// on every call, so a switch mid-warm re-prioritises
    /// what has not started yet.
    func warm(ladder: [Channel], startingAfter: String? = nil,
              excluding: Set<String> = []) {
        var ordered = ladder
        if let anchor = startingAfter,
           let i = ladder.firstIndex(where: { $0.url == anchor }) {
            ordered = Array(ladder[(i + 1)...]) + Array(ladder[..<i])
        }
        var seen = Set<String>()
        pending = ordered.filter { ch in
            !excluding.contains(ch.url)
                && states[ch.url] == nil
                && seen.insert(ch.url).inserted
        }
        startDriverIfNeeded()
    }

    /// The player closed: stop spending bandwidth. In-flight
    /// fetches are cancelled with the driver; sources left
    /// mid-warm fall back to unwarmed (a later board or
    /// session may warm them again), while warm and dead
    /// verdicts are kept.
    func cancelPending() {
        pending = []
        driver?.cancel()
    }

    private func startDriverIfNeeded() {
        guard driver == nil, !pending.isEmpty else { return }
        let token = UUID()
        driverToken = token
        driver = Task { [weak self] in
            await self?.runDriver(token: token)
        }
    }

    private func runDriver(token: UUID) async {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6
        let session = URLSession(configuration: config)
        var channelsByURL: [String: Channel] = [:]
        /// FIX-129 (Item B): when each in-flight warm started,
        /// for the ready line's elapsed time below.
        var startedAt: [String: Date] = [:]

        /// Pop the next source to warm, in queue order, and
        /// mark it in flight (the same nested-helper shape as
        /// MatchPlaySession.run's publish()).
        func takeNext() -> Channel? {
            guard !pending.isEmpty else { return nil }
            let ch = pending.removeFirst()
            channelsByURL[ch.url] = ch
            states[ch.url] = .warming
            // FIX-129 (Item B): a warm START line per source.
            // Until now the store logged only a proven death,
            // so a device log could not show that warming had
            // happened at all (the 1.28 log carries zero
            // prewarm lines); the start/ready pair below is
            // the evidence the next log is read against.
            startedAt[ch.url] = Date()
            DiagLog.log("player",
                        "prewarm: warming \(diagSourceTag(ch))")
            return ch
        }

        defer {
            session.invalidateAndCancel()
            // Sources left mid-warm by a cancellation are
            // unwarmed again, never half-marked.
            if Task.isCancelled {
                for url in states.filter({ $0.value == .warming }).map(\.key) {
                    states[url] = nil
                }
            }
            if driverToken == token {
                driver = nil
                driverToken = nil
                // A warm() that landed while this driver was
                // unwinding starts a fresh one.
                startDriverIfNeeded()
            }
        }

        await withTaskGroup(of: (String, Bool).self) { group in
            var active = 0
            while active < 2, let ch = takeNext() {
                group.addTask { (ch.url, await SourcePrewarmer.warm(ch, session: session)) }
                active += 1
            }
            for await (url, dead) in group {
                active -= 1
                if !Task.isCancelled {
                    states[url] = dead ? .dead : .warm
                    if dead, let ch = channelsByURL[url] {
                        DiagLog.log("player",
                                    "prewarm: source proven dead — the ladder will skip it: \(diagSourceTag(ch))")
                    } else if let ch = channelsByURL[url] {
                        // FIX-129 (Item B): the warm READY line
                        // (host + elapsed, via diagSourceTag) —
                        // the counterpart of the start line in
                        // takeNext(). A warm that ends neither
                        // dead nor cancelled lands here: the top
                        // playlist (and, for a master, the best
                        // variant + first segment head) was
                        // fetched, so the host is warm.
                        let ms = startedAt[url].map {
                            Int(Date().timeIntervalSince($0) * 1000)
                        } ?? -1
                        DiagLog.log("player",
                                    "prewarm: ready \(diagSourceTag(ch)) in \(ms)ms")
                    }
                }
                while active < 2, let ch = takeNext() {
                    group.addTask { (ch.url, await SourcePrewarmer.warm(ch, session: session)) }
                    active += 1
                }
            }
        }
    }
}

/// Resolve cache + single-flight hub (research §3.4): concurrent
/// opens of the same fixture share one in-flight session; a fresh
/// cached ladder replays instantly with no network; a fixture that
/// resolved to nothing playable is negative-cached for ~30 s, so a
/// dead fixture is not re-scraped on every tap; a healthy
/// re-resolve doubles the entry's TTL (60 s floor, 10 min cap),
/// while an empty resolve collapses the entry to the 30 s negative
/// TTL. In-memory only, capped at 200 entries (least-recently-used
/// evicted): a cold start re-verifies from the device — the only
/// vantage point that shares the owner's network and tunnel.
///
/// FIX-128 (the tvOS tap-to-play read path, ported): a tap reads
/// this registry in the order the SAME in-flight session → fresh
/// cache → STALE cache → new resolve, and never pays full
/// verification for a fixture the registry already knows:
/// - A stale (TTL-expired) entry with a playable ladder is
///   ADOPTED, not discarded: the tap vends a session seeded with
///   the cached ladder — which already excludes every source
///   that resolve proved dead — and re-resolution runs behind
///   it, merging into the replayed ladder. The TTL now governs
///   only when the background re-resolve runs, never whether
///   the tap may use what is known. (Before FIX-128 the entry
///   was treated as absent past its TTL: the 1.27 device log's
///   Bayern tap, 285 s after the launch pre-resolve settled,
///   created a new session and re-paid the dead head + serial
///   failover in full.)
/// - Every settled resolve also feeds its proven-dead URLs
///   into an app-run dead set (provenDead below) that outlives
///   any single entry's TTL, so a later tap's head publish can
///   filter a source this run already convicted — the same
///   per-run doctrine SourcePrewarmStore keeps for its own
///   verdicts.
@MainActor
final class ResolveHub {
    static let shared = ResolveHub()

    private struct Entry {
        var sources: [Channel]
        var storedAt: Date
        var ttl: TimeInterval
        /// Last vend (fresh or stale) — the LRU eviction key.
        var lastUsed: Date
        /// FIX-128: the URLs of the entry's VERIFIED tier
        /// (the rest of `sources` is the kept/blind tail, plus
        /// possibly an instant head at rung 0). Recorded so a
        /// later tap's seed order can tell a verified pick
        /// from a merely-kept one without re-deriving tiers
        /// from positions the merge may have shifted.
        var verifiedURLs: Set<String>
    }

    private var cache: [String: Entry] = [:]
    private var inFlight: [String: MatchPlaySession] = [:]
    /// URLs a settled resolve proved definitively dead this
    /// app run (pre-flight's standard only — see
    /// MatchPlaySession.isKnownDead). Outlives cache entries:
    /// a verdict must survive the TTL of the entry that
    /// produced it, or an expired entry resurrects its dead.
    private var provenDead: Set<String> = []

    /// Whether a settled resolve has already proven this URL
    /// dead during this app run.
    func isProvenDead(_ url: String) -> Bool {
        provenDead.contains(url)
    }

    /// FIX-129 (Item C): a PLAYER-observed definitive failure
    /// (TLS/certificate invalid, HTTP 403/404) joins the same
    /// app-run dead set a settled resolve feeds, so
    /// publishHeadNow filters the URL for every later tap —
    /// including taps of other fixtures whose ladders carry
    /// the same URL. Session-scoped in effect (the set is
    /// in-memory, per app run, like every verdict here).
    func notePlayerDead(url: String) {
        provenDead.insert(url)
    }
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

    /// FIX-128: the order a stale entry's ladder is replayed
    /// in for a tap whose pick is `pick` (the head of the
    /// tap's rotated ladder). Pick semantics, in order:
    /// - The pick is in the entry's VERIFIED tier → it leads
    ///   (it is both the viewer's choice and proven).
    /// - The pick is only in the kept/blind tail while the
    ///   entry holds verified rungs → the resolved order
    ///   stands (verified first): the player starts at the
    ///   first verified rung instead of paying the blind
    ///   pick's possible death — the same rule publishHeadNow
    ///   applies to a proven-dead pick, extended one tier:
    ///   unverified loses to verified when a verified
    ///   alternative is already known.
    /// - Nothing in the entry is verified → the pick leads
    ///   (among blind equals the choice rules, as the
    ///   instant head has always done).
    /// A pick absent from the entry (its URL rotated out of
    /// the playlist since) leaves the resolved order alone.
    private func tapSeedOrder(entry: Entry, pick: Channel?) -> [Channel] {
        let seed = entry.sources
        guard let pick,
              let i = seed.firstIndex(where: { $0.url == pick.url }) else { return seed }
        if entry.verifiedURLs.contains(pick.url) || entry.verifiedURLs.isEmpty {
            return [seed[i]] + seed.enumerated()
                .filter { $0.offset != i }
                .map { $0.element }
        }
        return seed
    }

    /// The hub's core lookup. `createdFresh` is true only when
    /// this call created and started a brand-new session — a
    /// single-flight hit and a born-complete cached session are
    /// both not fresh. Only the preresolve pass uses the flag, to
    /// track exactly the sessions it owns. A tap call (isTap)
    /// also marks the returned live session tap-adopted and
    /// drops it from the preresolve-owned list, so a later sweep
    /// can never cancel a session a player is using.
    ///
    /// FIX-128 read order for a tap: in-flight session → fresh
    /// cache entry → stale cache entry (seeded adoption with
    /// re-resolution behind) → new session. A pre-resolve call
    /// meeting a stale entry falls through to a fresh session —
    /// refreshing the entry is exactly the pass's job.
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
                if isTap {
                    noteTapAdoption(of: live)
                    DiagLog.log("player",
                                "resolve: tap adopted in-flight resolution for "
                                + "'\(ladder.first?.title ?? "?")' — "
                                + "\(live.sources.count) source(s) already published, "
                                + "still resolving behind the player")
                    // FIX-128: a still-empty in-flight session
                    // (the board-open pre-resolve a second old)
                    // is seeded with the stale cached ladder
                    // when one exists, so the player starts on
                    // previously-verified rungs while THIS
                    // session's verification continues behind
                    // the replay — the tap never waits for the
                    // young session's first batch when an older
                    // resolve already knows the fixture.
                    if live.sources.isEmpty, let entry = cache[key],
                       !entry.sources.isEmpty {
                        let seed = tapSeedOrder(entry: entry, pick: ladder.first)
                        live.adoptSeed(seed)
                        cache[key]?.lastUsed = Date()
                        DiagLog.log("player",
                                    "resolve: tap seeded in-flight resolution for "
                                    + "'\(ladder.first?.title ?? "?")' with the stale "
                                    + "ladder — \(seed.count) source(s) replayed "
                                    + "instantly, verification continues behind")
                    }
                    // DB-07: the tap plays the head NOW, even
                    // while this shared session still verifies.
                    // (A no-op when the seed just landed: the
                    // replay already published a ladder.)
                    live.publishHeadNow()
                }
                return (live, false)
            }
        }
        if let entry = cache[key] {
            let age = Date().timeIntervalSince(entry.storedAt)
            cache[key]?.lastUsed = Date()
            if age < entry.ttl {
                if isTap {
                    DiagLog.log("player",
                                "resolve: tap adopted cached resolution for "
                                + "'\(ladder.first?.title ?? "?")' — "
                                + "\(entry.sources.count) source(s), entry age "
                                + "\(Int(age))s of \(Int(entry.ttl))s TTL")
                }
                return (MatchPlaySession.cached(key: key, sources: entry.sources), false)
            }
            if isTap, !entry.sources.isEmpty {
                // FIX-128: stale adoption — the tvOS read path.
                // The entry's ladder replays instantly (it
                // already excludes the sources its resolve
                // proved dead); a fresh resolve runs behind it
                // and merges in, and its settle rewrites the
                // entry with a doubled TTL. A stale NEGATIVE
                // entry (empty ladder) never takes this path:
                // there is nothing to replay, and re-resolving
                // from scratch is the correct answer for a
                // fixture that may have revived.
                let session = MatchPlaySession.seeded(
                    key: key, sources: tapSeedOrder(entry: entry, pick: ladder.first))
                inFlight[key] = session
                noteTapAdoption(of: session)
                DiagLog.log("player",
                            "resolve: tap adopted stale resolution for "
                            + "'\(ladder.first?.title ?? "?")' — "
                            + "\(entry.sources.count) source(s) replayed instantly, "
                            + "re-resolving behind (entry age \(Int(age))s, "
                            + "TTL was \(Int(entry.ttl))s)")
                session.beginRevalidation(ladder: ladder)
                return (session, true)
            }
        }
        DiagLog.log("player",
                    "resolve: new session for '\(ladder.first?.title ?? "?")' "
                    + "(\(ladder.count) sources)")
        let session = MatchPlaySession(key: key)
        inFlight[key] = session
        if isTap { noteTapAdoption(of: session) }
        session.begin(ladder: ladder)
        // DB-07: a fresh session for a tap publishes its head
        // unverified at once (see publishHeadNow); a pre-resolve
        // pass (isTap == false) keeps the verified-batch
        // contract untouched.
        if isTap { session.publishHeadNow() }
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
    func noteResolved(key: String, sources: [Channel], deadURLs: Set<String> = [],
                      verifiedURLs: Set<String> = [],
                      from session: MatchPlaySession) {
        if let live = inFlight[key] {
            guard live === session else { return }
            tapAdopted.remove(ObjectIdentifier(live))
        }
        inFlight[key] = nil
        // FIX-128: the resolve's death verdicts join the
        // app-run dead set BEFORE the entry is written, so
        // they outlive this entry's TTL (see provenDead).
        provenDead.formUnion(deadURLs)
        let ttl: TimeInterval
        if sources.isEmpty {
            ttl = 30 // negative entry — see the type doc
        } else if let previous = cache[key] {
            ttl = min(previous.ttl * 2, 600)
        } else {
            ttl = 60
        }
        let now = Date()
        cache[key] = Entry(sources: sources, storedAt: now, ttl: ttl,
                           lastUsed: now, verifiedURLs: verifiedURLs)
        // FIX-128: LRU cap — evict least-recently-VENDED
        // entries (a fixture the viewer keeps returning to
        // keeps its verdicts; a one-off fixture's entry is
        // the first to go).
        while cache.count > 200,
              let lru = cache.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key {
            cache[lru] = nil
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
