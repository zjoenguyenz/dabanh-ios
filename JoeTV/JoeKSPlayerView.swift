import AVFoundation
import AVKit
import CoreMedia
import KSPlayer
import SwiftUI
import UIKit

/// The FFmpeg-engine player for torrent candidates (v2.0.3).
///
/// Why this exists: Torrentio/Real-Debrid direct files are
/// predominantly Matroska (every BluRay/REMUX/x265 release, and
/// most WEB-DL too). AVFoundation has no Matroska demuxer, so on
/// the AVPlayer path those items could never produce a frame —
/// the item sat unready or failed, the director advanced, and
/// with a dozen-plus near-identically labelled candidates the
/// walk read as one endless black spinner. KSPlayer's ME engine
/// (FFmpeg) opens these files natively. Provider candidates are
/// NOT routed here — they keep the AVPlayer controller and its
/// system transport UI exactly as before (PlayCandidate.engine
/// is the only switch, and only TorrentClient sets .ffmpeg).
///
/// The director contract is the same one the AVPlayer
/// coordinator honours: ready → resume rule, ticks → progress
/// saves, end → finished rule, failure → the ladder advances.
/// Two budgets mirror the Android player's torrent behaviour
/// (PlayerActivity STALL / POSITION_STALL):
///   • first frame: if the engine has not reached its playing
///     state 30 s after the attempt starts, the attempt fails
///     with a visible notice and the ladder moves on;
///   • mid-play freeze: once playing, a playhead that does not
///     advance for 30 s (and is not user-paused) fails the same
///     way. No torrent attempt can spin forever any more.
/// Both budgets were 12 s until v2.0.15, when they were raised
/// to the Android direct route's 30 s as part of the Sony
/// 2.3.17 player-fix port: on the owner's TV a 12 s budget
/// killed healthy REMUX sources whose post-seek refill simply
/// takes longer than that, and the failure then restarted the
/// film — his "kéo luôn 1 phát đứt luôn" verdict. The Sony
/// device trials (16 sources, 5 films) showed 30 s separates
/// a slow refill from a dead link; the streaming (AVPlayer)
/// path keeps its own budgets untouched.
/// Transport: KSPlayerLayer registers the remote's media
/// commands itself (play/pause, ±15 s skip, position change);
/// the host controller adds click handling — Select toggles
/// play/pause, Left/Right clicks seek ∓30 s. Menu is never
/// swallowed: it propagates to the shell's exit command, like
/// the AVPlayer path — which since v2.0.31 (L5) first asks
/// the director whether this host's picker is open and
/// closes just the picker in that case.
///
/// Transport bar (v2.0.12, owner defect on 2.0.10): the bare
/// layer above had NO on-screen controls at all — the owner
/// found torrent playback missing the whole bottom bar the
/// streaming path gets free from AVPlayerViewController
/// ("Riêng phần torrent thì không có thanh bar... Không
/// chỉnh được sub... Mất toàn bộ thanh đó"). The library's
/// own control view (KSVideoPlayerView) cannot be adopted
/// here: it builds and owns its own KSPlayerLayer from a URL,
/// so the director contract this host exists for — deferred
/// layer creation, the failover ladder behind attemptID, the
/// resume rule, both watchdogs — would all be bypassed.
/// The bar below is therefore built against KSPlayerLayer
/// directly, in this file, mirroring the AVPlayer transport:
/// play/pause, a focusable seek bar with current/total time,
/// subtitle selection (a host-owned SubtitleModel fed from
/// the player's subtitle data source — the pattern of the
/// library's own player views — Off included) and
/// audio-track selection (the documented
/// tracks(mediaType:) / select(track:) API). It auto-hides
/// while playing, exactly like the system bar, and any remote
/// press brings it back; Down moves focus into it, Up leaves
/// it, and Menu still exits (it only backs out of an open
/// track picker first, as the system menus do).
struct JoeKSPlayerController: UIViewControllerRepresentable {
    let candidate: PlayCandidate
    let director: PlayDirector

    final class Coordinator {
        weak var host: KSPlayerHostViewController?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> KSPlayerHostViewController {
        let host = KSPlayerHostViewController()
        context.coordinator.host = host
        host.start(candidate: candidate, director: director)
        return host
    }

    func updateUIViewController(_ controller: KSPlayerHostViewController,
                                context: Context) {}

    static func dismantleUIViewController(_ controller: KSPlayerHostViewController,
                                          coordinator: Coordinator) {
        controller.teardown()
    }
}

final class KSPlayerHostViewController: UIViewController, KSPlayerLayerDelegate {
    private var layer: KSPlayerLayer?
    private var director: PlayDirector?
    /// v2.0.16: the session's side-loaded subtitle URL (the
    /// candidate's subtitleURL — the subtitle addon's best
    /// Vietnamese), fed into the subtitle model beside the
    /// embedded tracks by prepareSubtitleModel.
    private var externalSubtitleURL: URL?
    /// The candidate start() was handed. Layer creation is
    /// DEFERRED until the first layout pass with real bounds
    /// (v2.0.5, error 3b — see beginPlaybackIfPossible), so the
    /// candidate waits here until the view has a true size.
    private var pendingCandidate: PlayCandidate?
    /// v2.0.27 (idea 10, tvOS-corrected): the display
    /// criteria built in start() from the candidate's
    /// display features. start() runs before the host has a
    /// window, so the criteria wait here and are handed to
    /// the window's AVDisplayManager by applyDisplayCriteria
    /// (retried from viewDidAppear, when a window exists).
    private var pendingDisplayCriteria: AVDisplayCriteria?
    private var failed = false
    private var ready = false
    private var playing = false
    private var ended = false
    /// First-frame budget (30 s, Android STALL parity): armed
    /// when the layer is created, cancelled the moment the
    /// engine reports readyToPlay or its playing state
    /// (v2.0.5: readyToPlay added — a slow-but-viable start
    /// that had announced itself ready was previously still
    /// killed at 12 s because only bufferFinished disarmed
    /// the budget).
    private var firstFrameWatchdog: DispatchWorkItem?
    /// Mid-play freeze watchdog (30 s without playhead advance,
    /// Android POSITION_STALL parity): a 1 s ticker, judging
    /// only after the first frame — the same shape as the
    /// AVPlayer coordinator's freeze watch.
    private var freezeTimer: Timer?
    private var lastPositionSec = -1.0
    private var lastAdvanceAt = Date()
    /// Director ticks ride the AV path's ~5 s cadence even
    /// though the engine reports time every 0.1 s.
    private var lastTickAt = Date.distantPast

    // MARK: - Transport bar (v2.0.12)

    /// The bar's container, added in viewDidLoad — BEFORE the
    /// player view exists, so beginPlayback inserts the player
    /// view UNDER it (insertSubview at 0). Hidden with
    /// isHidden (never just alpha) so the focus engine can
    /// never land on invisible controls.
    private let controlsView = UIView()
    private let transportBar = UIView()
    private let playPauseButton = UIButton(type: .system)
    private let subtitleButton = UIButton(type: .system)
    private let audioButton = UIButton(type: .system)
    /// FIX4 (fix 4): the source switch, in the bar since
    /// this round — idea 13's "Đổi nguồn" existed only in
    /// the AVPlayer transport menu, so a torrent session
    /// (this host) offered no way to change source at all
    /// (owner finding on 2.0.27).
    private let switchSourceButton = UIButton(type: .system)
    private let currentTimeLabel = UILabel()
    private let durationLabel = UILabel()
    private let seekBar = KSSeekBarView()
    private let bufferingSpinner = UIActivityIndicatorView(style: .medium)
    private var controlsBuilt = false
    private var controlsVisible = false
    /// True while focus sits inside the bar or the picker.
    /// FIX4 (fix 5): this no longer vetoes auto-hide — it
    /// never could be false while the bar was up (showControls
    /// deliberately moves focus INTO the bar), so the bar
    /// could never hide at all. Focus moves inside the bar
    /// now simply re-arm the idle timer (see didUpdateFocus);
    /// when it fires, the bar hides and focus returns to the
    /// root through the same preferredFocusEnvironments path
    /// that brought it in — the remote is never stranded.
    private var focusInControls = false
    /// 0.5 s refresh for the bar (time labels, seek fill,
    /// play/pause icon, buffering spinner) — the JTV surface's
    /// proven cadence shape, half its rate.
    private var uiTimer: Timer?
    private var hideTimer: Timer?
    /// Track picker state: the centred panel that replaces
    /// the bar while a subtitle/audio choice is open. Its
    /// buttons are rebuilt per opening from the LIVE track
    /// lists, so a failover to a new candidate never shows a
    /// stale slate (the host itself is recreated per attempt
    /// via .id(attemptID) regardless).
    private let pickerView = UIView()
    private let pickerTitleLabel = UILabel()
    private var pickerButtons: [UIButton] = []
    private var pickerIsOpen = false
    private enum PickerKind { case subtitles, audio, sources }
    private var pickerKind: PickerKind = .subtitles
    /// The subtitle rows' infos, cached at picker opening so
    /// a button's tag indexes the same array the selection
    /// writes back into the host's subtitle model.
    private var pickerSubtitleInfos: [any SubtitleInfo] = []
    private var pickerAudioTracks: [MediaPlayerTrack] = []
    /// v2.0.29 (item 3): the source chooser's rows, cached at
    /// opening like the track rows beside them — a button's
    /// tag is the candidate's ladder index, the value
    /// userSwitchSource(to:) consumes. pickerSourceIndex is
    /// the CURRENT candidate's index at opening: the focus
    /// landing (preferredFocusEnvironments) and the row's
    /// check mark both read it.
    private var pickerSourceLabels: [PlayDirector.SourceChoice] = []
    private var pickerSourceIndex = -1
    /// The subtitle selection model, owned by this host.
    /// KSPlayerLayer has NO subtitle model of its own (the
    /// first 2.0.12 draft wrote against `layer.subtitleModel`
    /// and CI run #38 rejected it): in KSPlayer 2.3.4 the
    /// model belongs to the player VIEWS — VideoPlayerView's
    /// srtControl, KSVideoPlayer.Coordinator's subtitleModel —
    /// and the host here mirrors them: the model is fed from
    /// the player's own subtitle data source (KSMEPlayer is
    /// its own source; its infos are the file's embedded
    /// subtitle tracks) and its parts are painted by the
    /// render pair below.
    private let subtitleModel = SubtitleModel()
    /// The player instance the model was fed for. The layer
    /// can swap its player in place (an error finish rebuilds
    /// it from the second player type), and addSubtitle
    /// APPENDS — feeding one source twice would duplicate
    /// every picker row, so the feed is once per instance.
    private var subtitleFedPlayerID: ObjectIdentifier?
    /// 0.25 s subtitle paint timer: the model's parts are
    /// pulled against the live playhead — VideoPlayerView
    /// does the same pull inside the layer's currentTime
    /// delegate, but that delegate here is the director's
    /// 5 s tick and stays untouched, so the pull rides its
    /// own timer, born with the model feed.
    private var subtitleTimer: Timer?
    /// Subtitle render pair, mirroring the library's
    /// subtitleBackView + subtitleLabel: an image view for
    /// image-based parts (PGS / DVB) carrying a centred
    /// label for text parts. Built lazily at the model feed
    /// and inserted BELOW the controls view, so the bar
    /// never fights it for the screen — the strip simply
    /// lifts while the bar is up.
    private let subtitleImageView = UIImageView()
    private let subtitleLabel = UILabel()
    private var subtitleViewsBuilt = false

    override func loadView() {
        view = KSPlayerHostRootView()
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        // While the track picker is open it owns the landing.
        // While the transport bar is up, the play button owns
        // it (v2.0.17): before this, focus stayed on the root
        // view and Left/Right could only seek — the track
        // buttons were reachable only by an undiscoverable
        // Down-then-Up path, and the owner reported exactly
        // that ("chỉ cho kéo tới kéo lui"). With focus IN the
        // bar, Left/Right walk the button row and Down drops
        // to the seek bar, where Left/Right step ∓30 s.
        if pickerIsOpen {
            // v2.0.29 (item 3): the source chooser lands on
            // the CURRENT source's row — the owner starts
            // from where he is and walks from there. The
            // track pickers keep their first-row landing.
            if pickerKind == .sources,
               let current = pickerButtons.first(where: { $0.tag == pickerSourceIndex }) {
                return [current]
            }
            if let first = pickerButtons.first {
                return [first]
            }
        }
        if controlsVisible {
            return [playPauseButton]
        }
        return [view]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        buildControls()
        uiTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refreshTransport()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setNeedsFocusUpdate()
        showControls()
        // v2.0.31 (L4): force this fresh host's focus
        // landing (the play button, per
        // preferredFocusEnvironments) instead of leaving it
        // pending — after a source switch this host replaces
        // one the focus engine was still resolving, and a
        // landing left to the engine's leisure is the one
        // the owner's dead play press followed.
        updateFocusIfNeeded()
        // The host has a window by now: hand the window's
        // display manager the criteria start() prepared
        // (applyDisplayCriteria no-ops without a window).
        applyDisplayCriteria()
        beginPlaybackIfPossible()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // The library contract is frame-based: re-assert the
        // player surface's frame against the host's real
        // bounds on EVERY layout pass, so no later resize
        // (rotation-class changes, cover re-presentation) can
        // strand it at a stale size again.
        if let playerView = layer?.player.view {
            playerView.frame = view.bounds
        }
        if controlsBuilt {
            layoutControls()
        }
        beginPlaybackIfPossible()
    }

    func start(candidate: PlayCandidate, director: PlayDirector) {
        self.director = director
        externalSubtitleURL = candidate.subtitleURL
        pendingCandidate = candidate
        // v2.0.26 (idea 10), tvOS-corrected in v2.0.27:
        // display-mode matching for the torrent path. The
        // AVPlayer path is matched by the system
        // automatically; KSPlayer/FFmpeg is not, so the host
        // states the candidate's display features (stamped
        // by TorrentClient.playCandidates from the stream's
        // own parse) as an AVDisplayCriteria on the window's
        // AVDisplayManager — Apple's prescribed mechanism
        // for non-AVPlayer playback (Tech Talk 503). The
        // v2.0.26 code set a `preferredDisplayCriteria`
        // property on the view controller and built the
        // criteria from an AVVideoDynamicRange: neither
        // exists in the tvOS SDK (verified against Apple's
        // documentation — AVDisplayCriteria's sole
        // initializer is init(refreshRate:formatDescription:)
        // and the manager is vended by the window as
        // UIWindow.avDisplayManager). This is a PREFERENCE
        // the system honours subject to the user's Match
        // Content settings (Settings > Video and Audio >
        // Match Content) — that is Apple's intended
        // behaviour; do not try to force or override system
        // settings. With no rate in the release name the
        // torrent path is film/series content, so the rate
        // defaults to 23.976.
        pendingDisplayCriteria = Self.makeDisplayCriteria(for: candidate)
        applyDisplayCriteria()
        view.backgroundColor = .black
        // makeUIViewController calls this BEFORE the view has
        // been laid out — creating the layer there froze the
        // surface at the pre-layout (safe-area) size forever
        // (error 3b). Actual creation waits for bounds.
        beginPlaybackIfPossible()
    }

    /// Builds the candidate's AVDisplayCriteria in the only
    /// form the tvOS SDK offers: a refresh rate plus a
    /// CMFormatDescription whose colour extensions carry the
    /// dynamic range (BT.2020 primaries/matrix + SMPTE
    /// ST 2084 PQ transfer for DV/HDR, BT.709 for SDR). The
    /// release-name parse carries no codec or resolution, so
    /// the description states HEVC at a nominal 3840×2160 —
    /// the torrent ladder is x265-dominated and the DV/HDR
    /// flags come from 2160p names; the display manager's
    /// mode decision rides on the rate and the colour
    /// extensions, not the stated size. Dolby Vision is
    /// expressed as its PQ base layer: a bare format
    /// description cannot carry the DV configuration
    /// record, so the system may match a DV candidate as
    /// HDR10 — the supported subset, stated plainly.
    /// Fail-soft: any failure returns nil (no preference).
    private static func makeDisplayCriteria(for candidate: PlayCandidate) -> AVDisplayCriteria? {
        let primaries: CFString
        let transfer: CFString
        let matrix: CFString
        if candidate.dv || candidate.hdr {
            primaries = kCMFormatDescriptionColorPrimaries_ITU_R_2020
            transfer = kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
            matrix = kCMFormatDescriptionYCbCrMatrix_ITU_R_2020
        } else {
            primaries = kCMFormatDescriptionColorPrimaries_ITU_R_709_2
            transfer = kCMFormatDescriptionTransferFunction_ITU_R_709_2
            matrix = kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2
        }
        let extensions: [CFString: CFString] = [
            kCMFormatDescriptionExtension_ColorPrimaries: primaries,
            kCMFormatDescriptionExtension_TransferFunction: transfer,
            kCMFormatDescriptionExtension_YCbCrMatrix: matrix,
        ]
        var formatDescription: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_HEVC,
            width: 3840, height: 2160,
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &formatDescription)
        guard status == noErr, let formatDescription else { return nil }
        return AVDisplayCriteria(
            refreshRate: Float(candidate.fps ?? 23.976),
            formatDescription: formatDescription)
    }

    /// Hands the pending criteria to the window's
    /// AVDisplayManager (UIWindow.avDisplayManager — the
    /// manager "vended by the key UIWindow" in Apple's
    /// guidance). start() runs before the host has a window,
    /// so this no-ops then and is retried from
    /// viewDidAppear; assigning the (possibly nil) pending
    /// value also clears a previous session's preference.
    private func applyDisplayCriteria() {
        guard let window = view.window else { return }
        window.avDisplayManager.preferredDisplayCriteria = pendingDisplayCriteria
    }

    /// Creates the KSPlayerLayer and starts playback — but
    /// only once the host view has REAL, non-zero bounds (the
    /// first layout pass, or viewDidAppear as a backstop).
    /// KSPlayer's documented sizing contract is frame +
    /// autoresizingMask; the pre-v2.0.5 host violated it on
    /// both axes: it created the layer against the not-yet-
    /// laid-out view and pinned the player view with Auto
    /// Layout constraints, so the surface kept the 1760×960
    /// safe-area size at origin (0,0) inside the full-screen
    /// host — the right + bottom bands on the owner's TV.
    private func beginPlaybackIfPossible() {
        guard layer == nil,
              let candidate = pendingCandidate,
              view.bounds.width > 0, view.bounds.height > 0
        else { return }
        pendingCandidate = nil
        let options = KSOptions()
        // Same header discipline as the AVPlayer path: the
        // candidate's own headers, the house user agent when
        // none was set.
        options.userAgent = candidate.headers["User-Agent"] ?? JoeHTTP.userAgent
        if !candidate.headers.isEmpty {
            options.appendHeader(candidate.headers)
        }
        // v2.0.15 (Sony 2.3.17 port): hand FFmpeg's HTTP layer
        // the patience the Android direct route got — a 20 s
        // read/write timeout plus automatic reconnect (plain,
        // streamed and at-EOF, up to 5 s backoff) — so a
        // dropped debrid connection is resumed by the engine
        // itself before any watchdog has to judge. The keys
        // ride formatContextOptions, the dictionary MEPlayerItem
        // passes to avformat_open_input (verified in the
        // KSPlayer 2.3.4 sources; the library's own userAgent
        // and referer setters write into the same dictionary).
        options.formatContextOptions["rw_timeout"] = "20000000"
        options.formatContextOptions["reconnect"] = "1"
        options.formatContextOptions["reconnect_streamed"] = "1"
        options.formatContextOptions["reconnect_at_eof"] = "1"
        options.formatContextOptions["reconnect_delay_max"] = "5"
        // The FFmpeg engine, deterministically: KSPlayerLayer
        // reads this type-level default at creation, and torrent
        // candidates are the only KSPlayerLayers this app ever
        // creates, so setting it here scopes it to this path.
        KSOptions.firstPlayerType = KSMEPlayer.self
        let layer = KSPlayerLayer(url: candidate.url, options: options, delegate: self)
        self.layer = layer
        if let playerView = layer.player.view {
            playerView.frame = view.bounds
            playerView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            // UNDER the transport bar: the controls were added
            // in viewDidLoad, before this layer existed, so a
            // plain addSubview here would bury them beneath
            // the picture surface forever.
            view.insertSubview(playerView, at: 0)
        }
        // v2.0.5 (P2): play EXPLICITLY. The pre-fix host never
        // called play() at start — playback depended on the
        // library's autoplay behaviour, which this side has
        // never verified; a host that wants playback must ask
        // for it.
        layer.play()
        let wd = DispatchWorkItem { [weak self] in
            guard let self, !self.playing else { return }
            self.stallFail(reason: "Chưa có hình sau 30 giây")
        }
        firstFrameWatchdog = wd
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: wd)
        lastAdvanceAt = Date()
        let ticker = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkFreeze()
        }
        RunLoop.main.add(ticker, forMode: .common)
        freezeTimer = ticker
    }

    func teardown() {
        // v2.0.26 (idea 10), tvOS-corrected in v2.0.27:
        // clear the display criteria handed to the window's
        // display manager in start()/viewDidAppear, so no
        // preference lingers after the session — the system
        // returns to its default mode.
        //
        // FIX4 (fix 1): the clear is IDENTITY-GUARDED now.
        // Hosts are recreated per attempt (.id(attemptID)),
        // and SwiftUI's dismantle of an old attempt's host
        // can land AFTER the replacement host's viewDidAppear
        // already applied its own criteria to the SAME
        // window's manager — the old unconditional clear then
        // silently nilled the LIVE attempt's preference, and
        // nothing ever re-applied it: display matching was
        // dead for every session that churned an attempt
        // before settling (the owner's 2.0.27 test: two
        // torrent films, no badge, no mode change). Only
        // clear while the manager still holds THIS host's
        // object.
        if let window = view.window,
           let mine = pendingDisplayCriteria,
           window.avDisplayManager.preferredDisplayCriteria === mine {
            window.avDisplayManager.preferredDisplayCriteria = nil
        }
        pendingDisplayCriteria = nil
        // A dismantled host must never begin playback late:
        // drop the deferred candidate first.
        pendingCandidate = nil
        firstFrameWatchdog?.cancel()
        firstFrameWatchdog = nil
        freezeTimer?.invalidate()
        freezeTimer = nil
        // Close the picker BEFORE killing the timers:
        // closePicker re-arms the hide timer via showControls,
        // and teardown must be the last word on timers.
        closePicker()
        uiTimer?.invalidate()
        uiTimer = nil
        hideTimer?.invalidate()
        hideTimer = nil
        layer?.delegate = nil
        layer?.stop()
        layer = nil
    }

    // MARK: - Remote clicks (Menu deliberately untouched)

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            switch press.type {
            case .select:
                showControls()
                togglePlayPause()
                handled = true
            case .playPause:
                showControls()
                togglePlayPause()
                handled = true
            case .leftArrow:
                showControls()
                // v2.0.18: with focus inside the bar (or the
                // picker open), arrows belong to focus
                // movement; a press that still bubbles up to
                // the host is an edge-of-row press and must
                // never become a seek under the user's fingers.
                if pickerIsOpen || focusInControls { break }
                seekBy(-30)
                handled = true
            case .rightArrow:
                showControls()
                if pickerIsOpen || focusInControls { break }
                seekBy(30)
                handled = true
            case .menu:
                // v2.0.31 (L5): Menu is NOT handled here any
                // more, picker open or not — it propagates
                // to the shell's exit command, which asks the
                // director whether a picker is open: open →
                // the shell closes just the picker (through
                // this host's closePicker, registered with
                // the director); closed → the film exits, as
                // always. Pre-fix the host closed the picker
                // here AND the press still reached the shell
                // on the owner's set — one press, two
                // consumers — and the film exited behind the
                // closing panel (his subtitle-panel finding).
                break
            default:
                // Up/Down (and anything else) only wake the
                // bar; they are never swallowed, so the focus
                // engine still receives them and can move
                // focus into or out of the transport bar.
                showControls()
                break
            }
        }
        if !handled {
            super.pressesEnded(presses, with: event)
        }
    }

    private func togglePlayPause() {
        guard let layer else { return }
        if layer.state.isPlaying {
            layer.pause()
        } else {
            layer.play()
        }
        refreshTransport()
    }

    private func seekBy(_ delta: TimeInterval) {
        guard let layer else { return }
        let target = max(0, layer.player.currentPlaybackTime + delta)
        layer.seek(time: target, autoPlay: true) { _ in }
        refreshTransport()
    }

    // MARK: - Transport bar: build & layout

    private func buildControls() {
        guard !controlsBuilt else { return }
        controlsBuilt = true
        controlsView.frame = view.bounds
        controlsView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controlsView.isHidden = true
        view.addSubview(controlsView)

        transportBar.backgroundColor = UIColor.black.withAlphaComponent(0.62)
        transportBar.layer.cornerRadius = 24
        controlsView.addSubview(transportBar)

        // v2.0.30 (FIX6, the owner's close-ups): the plate
        // lives in the button's CONFIGURATION, not in a
        // hand-set backgroundColor + layer radius. A .system
        // button draws its OWN focus platter over a hand
        // plate, at the system's size, radius and offset —
        // the two rounded rects rendered doubled and
        // ghosted on every bar control in the owner's
        // photos. With the plate inside the configuration,
        // the system renders ONE plate in both states. See
        // transportButtonConfiguration.
        playPauseButton.configuration = Self.transportButtonConfiguration(
            font: nil, backgroundAlpha: 0.14, cornerRadius: 14,
            contentInsets: .zero)
        playPauseButton.configurationUpdateHandler = Self.transportFocusHandler
        playPauseButton.setImage(Self.transportSymbol("play.fill"), for: .normal)
        playPauseButton.addTarget(self, action: #selector(playPauseButtonTapped),
                                  for: .primaryActionTriggered)
        transportBar.addSubview(playPauseButton)

        bufferingSpinner.color = .white
        bufferingSpinner.hidesWhenStopped = true
        transportBar.addSubview(bufferingSpinner)

        styleTransportButton(subtitleButton, title: "Phụ đề: Tắt")
        subtitleButton.addTarget(self, action: #selector(subtitleButtonTapped),
                                 for: .primaryActionTriggered)
        transportBar.addSubview(subtitleButton)
        styleTransportButton(audioButton, title: "Âm thanh")
        audioButton.addTarget(self, action: #selector(audioButtonTapped),
                              for: .primaryActionTriggered)
        transportBar.addSubview(audioButton)

        // FIX4 (fix 4): same dress as the track buttons,
        // same right-hand cluster (laid out in
        // layoutControls, left of Phụ đề).
        styleTransportButton(switchSourceButton, title: "Đổi nguồn")
        switchSourceButton.addTarget(self, action: #selector(switchSourceButtonTapped),
                                     for: .primaryActionTriggered)
        transportBar.addSubview(switchSourceButton)

        for label in [currentTimeLabel, durationLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 25, weight: .medium)
            label.textColor = .white
            label.text = "0:00"
            transportBar.addSubview(label)
        }
        durationLabel.textAlignment = .right

        seekBar.backgroundColor = .clear
        seekBar.onStep = { [weak self] delta in
            self?.showControls()
            self?.seekBy(delta)
        }
        seekBar.onTogglePlayPause = { [weak self] in
            self?.showControls()
            self?.togglePlayPause()
        }
        transportBar.addSubview(seekBar)

        pickerView.backgroundColor = UIColor.black.withAlphaComponent(0.88)
        pickerView.layer.cornerRadius = 20
        pickerView.isHidden = true
        controlsView.addSubview(pickerView)
        pickerTitleLabel.font = .systemFont(ofSize: 29, weight: .bold)
        pickerTitleLabel.textColor = .white
        pickerView.addSubview(pickerTitleLabel)

        layoutControls()
    }

    /// Standard tvOS button dress (v2.0.30, FIX6 — the
    /// house doctrine applied literally): white text on a
    /// quiet plate, and the plate lives INSIDE the button's
    /// configuration so the system renders exactly one
    /// plate in both states. Pre-fix this painted a hand
    /// plate (backgroundColor + layer.cornerRadius) on a
    /// .system button, and tvOS drew its own focus platter
    /// over it at the system's geometry — the doubled,
    /// offset ghost outlines in the owner's close-ups of
    /// the Phụ đề / Âm thanh pills. Resting values are
    /// unchanged (white 0.14 plate, radius 14, white 25
    /// semibold, insets 10×22); the focused title still
    /// goes dark, via the configuration update handler —
    /// a state title colour would be overridden by the
    /// configuration the system actually renders.
    private func styleTransportButton(_ button: UIButton, title: String) {
        button.configuration = Self.transportButtonConfiguration(
            title: title,
            font: .systemFont(ofSize: 25, weight: .semibold),
            backgroundAlpha: 0.14, cornerRadius: 14,
            contentInsets: NSDirectionalEdgeInsets(top: 10, leading: 22,
                                                   bottom: 10, trailing: 22))
        button.configurationUpdateHandler = Self.transportFocusHandler
    }

    /// v2.0.30 (FIX6): the one-plate configuration shared
    /// by every bar and picker button — the resting dress
    /// (translucent plate at the standing radius, white
    /// foreground, the title's font carried by the text
    /// attributes transformer so later setTitle-shaped
    /// updates keep it). The system renders its focused
    /// face from THIS background, so no second plate can
    /// appear.
    private static func transportButtonConfiguration(
        title: String? = nil,
        font: UIFont?,
        backgroundAlpha: CGFloat,
        cornerRadius: CGFloat,
        contentInsets: NSDirectionalEdgeInsets
    ) -> UIButton.Configuration {
        var config = UIButton.Configuration.filled()
        config.title = title
        config.baseForegroundColor = .white
        config.background.backgroundColor =
            UIColor.white.withAlphaComponent(backgroundAlpha)
        config.background.cornerRadius = cornerRadius
        config.contentInsets = contentInsets
        if let font {
            config.titleTextAttributesTransformer =
                UIConfigurationTextAttributesTransformer { incoming in
                    var outgoing = incoming
                    outgoing.font = font
                    return outgoing
                }
        }
        return config
    }

    /// The focused-foreground flip shared by every bar and
    /// picker button (v2.0.30): the system's focused face
    /// is light, so the title/glyph goes dark on it — the
    /// intent the pre-fix setTitleColor(.black, for:
    /// .focused) expressed, moved into the configuration.
    private static let transportFocusHandler:
        UIButton.ConfigurationUpdateHandler = { button in
            guard var config = button.configuration else { return }
            config.baseForegroundColor =
                button.state.contains(.focused) ? .black : .white
            button.configuration = config
        }

    /// Title writes for the configured buttons (v2.0.30):
    /// the title lives in the configuration now, so the
    /// live re-titles (the selected track's name after
    /// readyToPlay, after every picker selection) write
    /// through it directly instead of relying on the
    /// legacy setter's bridging.
    private func setConfiguredTitle(_ button: UIButton, _ title: String) {
        if var config = button.configuration {
            config.title = title
            button.configuration = config
        } else {
            button.setTitle(title, for: .normal)
        }
    }

    /// v2.0.30 (FIX6): a subtitle whose name is a bare ISO
    /// language code ("spa" in the owner's close-up) reads
    /// as the language's own Vietnamese name instead — the
    /// code alone told him nothing. Only a whole-string
    /// 2–3 letter code that Locale recognises is mapped
    /// ("sdh" excluded: it is a real code — Southern
    /// Kurdish — but on subtitle tracks it overwhelmingly
    /// means SDH captions); any real name ("Vietsub", a
    /// file's own label) passes through untouched.
    private static func friendlyTrackName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard (2...3).contains(trimmed.count),
              trimmed.allSatisfy({ $0.isLetter }),
              trimmed.lowercased() != "sdh",
              let name = Locale(identifier: "vi_VN")
                .localizedString(forLanguageCode: trimmed.lowercased())
        else { return raw }
        return name
    }

    /// Frame layout, in the file's frame-based contract (the
    /// player surface is frame-sized too; no Auto Layout
    /// anywhere in this host). Recomputed on every layout
    /// pass, so the bar tracks the real bounds like the
    /// player view does.
    private func layoutControls() {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        controlsView.frame = bounds
        let inset = max(view.safeAreaInsets.left, 48)
        let barWidth = bounds.width - inset * 2
        let barHeight: CGFloat = 168
        let barY = bounds.height - max(view.safeAreaInsets.bottom, 36) - barHeight
        transportBar.frame = CGRect(x: inset, y: barY, width: barWidth, height: barHeight)

        playPauseButton.frame = CGRect(x: 24, y: 12, width: 104, height: 64)
        bufferingSpinner.frame = CGRect(x: 144, y: 34, width: 20, height: 20)

        // Track buttons hug the right edge, sized to their
        // current titles (set by refreshTrackButtons).
        subtitleButton.sizeToFit()
        audioButton.sizeToFit()
        let audioW = audioButton.isHidden ? 0 : max(audioButton.frame.width, 170)
        let subW = subtitleButton.isHidden ? 0 : max(subtitleButton.frame.width, 190)
        if !audioButton.isHidden {
            audioButton.frame = CGRect(x: barWidth - 24 - audioW, y: 12,
                                       width: audioW, height: 64)
        }
        if !subtitleButton.isHidden {
            subtitleButton.frame = CGRect(x: barWidth - 24 - audioW - (audioW > 0 ? 16 : 0) - subW,
                                          y: 12, width: subW, height: 64)
        }
        // FIX4 (fix 4): Đổi nguồn closes the right cluster
        // on the left — its offset walks past whichever
        // track buttons are visible (their widths are 0
        // while hidden, and the gaps follow the same rule
        // as the subtitle button's own math above).
        let switchW: CGFloat = 190
        switchSourceButton.frame = CGRect(
            x: barWidth - 24 - audioW - (audioW > 0 ? 16 : 0)
               - subW - (subW > 0 ? 16 : 0) - switchW,
            y: 12, width: switchW, height: 64)

        currentTimeLabel.frame = CGRect(x: 24, y: 94, width: 150, height: 48)
        durationLabel.frame = CGRect(x: barWidth - 24 - 150, y: 94, width: 150, height: 48)
        let seekX: CGFloat = 24 + 150 + 20
        seekBar.frame = CGRect(x: seekX, y: 94,
                               width: barWidth - seekX - 150 - 24 - 20, height: 48)
        if pickerIsOpen {
            layoutPicker()
        }
    }

    private func layoutPicker() {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        let panelW = min(780, bounds.width - 120)
        // Rows compress on tall slates (a REMUX can carry a
        // dozen subtitle tracks): the panel must never grow
        // past the screen, or its lower rows — and their
        // focus — would live off-screen.
        let count = max(pickerButtons.count, 1)
        let maxPanelH = bounds.height - 80
        let rowH = min(66, (maxPanelH - 108) / CGFloat(count))
        let panelH = 108 + CGFloat(pickerButtons.count) * rowH
        pickerView.frame = CGRect(x: (bounds.width - panelW) / 2,
                                  y: (bounds.height - panelH) / 2,
                                  width: panelW, height: panelH)
        pickerTitleLabel.frame = CGRect(x: 32, y: 24, width: panelW - 64, height: 44)
        for (index, button) in pickerButtons.enumerated() {
            button.frame = CGRect(x: 32, y: 92 + CGFloat(index) * rowH,
                                  width: panelW - 64, height: rowH - 8)
        }
    }

    // MARK: - Transport bar: show / hide

    /// v2.0.18: flip the root view's focus eligibility and
    /// ask for the update that relocates focus accordingly —
    /// into the bar when it wakes (the host's preferred
    /// environment is the play button), back to the root when
    /// the bar hides (the preferred environment is the root).
    private func setRootAcceptsFocus(_ on: Bool) {
        guard let root = view as? KSPlayerHostRootView,
              root.acceptsFocus != on else { return }
        root.acceptsFocus = on
        setNeedsFocusUpdate()
    }

    private func showControls() {
        guard controlsBuilt else { return }
        // v2.0.18: the bar being up means the root must not
        // hold focus (see KSPlayerHostRootView.acceptsFocus).
        setRootAcceptsFocus(false)
        // v2.0.29 (item 2): the shell's status capsule is
        // bound to the bar through the director — the bar
        // waking wakes the capsule (source label / resume
        // line) with it, and only with it.
        director?.setTransportBarVisible(true)
        if !controlsVisible {
            controlsVisible = true
            controlsView.isHidden = false
            refreshTransport()
            // v2.0.17: the bar waking is the moment focus moves
            // into it (onto the play button, per
            // preferredFocusEnvironments) — but only when focus
            // is not already inside the bar or the picker, so a
            // press that merely re-arms the hide timer never
            // yanks the user's place.
            if !focusInControls, !pickerIsOpen {
                setNeedsFocusUpdate()
            }
        }
        scheduleControlsHide()
    }

    private func scheduleControlsHide() {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { [weak self] _ in
            self?.hideControlsIfIdle()
        }
    }

    /// The system bar's contract: it fades only while the
    /// picture is actually playing, never while paused, and
    /// never under an open picker. FIX4 (fix 5): "never while
    /// the user is standing inside it" is GONE — standing in
    /// the bar is the bar's normal state (focus moves in when
    /// it wakes), so that clause vetoed every hide and the
    /// bar stayed on screen forever (owner finding on
    /// 2.0.27). Idleness is now measured by the timer alone:
    /// every show and every focus move inside the bar re-arms
    /// it, and when it fires the bar hides and focus returns
    /// to the root (setRootAcceptsFocus below).
    private func hideControlsIfIdle() {
        guard controlsVisible, !pickerIsOpen, let layer else { return }
        guard layer.player.isPlaying else {
            // v2.0.29 (item 2, the Billboard single-source
            // case): the pre-fix guard simply returned, and
            // NOTHING ever re-armed the timer — one veto at
            // the fire instant (the engine momentarily not
            // reporting its playing state: a slow first
            // buffer, a rebuffer dip) retired the hide
            // mechanism for the rest of the session, and the
            // bar stayed on screen forever. The veto now
            // re-arms the idle timer and the decision is
            // retried on the next cycle. The paused contract
            // is unchanged — the bar still never hides while
            // the engine is not playing; it merely keeps
            // checking instead of giving up after one check.
            scheduleControlsHide()
            return
        }
        controlsVisible = false
        controlsView.isHidden = true
        // v2.0.29 (item 2): the capsule hides WITH the bar —
        // the same director flag the AVPlayer path's
        // delegate callback drives.
        director?.setTransportBarVisible(false)
        // v2.0.18: the bar is gone — the root takes focus back.
        setRootAcceptsFocus(true)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext,
                                 with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        guard let next = context.nextFocusedView else { return }
        focusInControls = next.isDescendant(of: controlsView)
        if focusInControls {
            controlsVisible = true
            controlsView.isHidden = false
            // v2.0.29 (item 2): focus resurrecting the bar
            // resurrects the capsule with it.
            director?.setTransportBarVisible(true)
            // FIX4 (fix 5): a focus move inside the bar is
            // activity — restart the idle clock instead of
            // cancelling it. The pre-fix invalidate here,
            // combined with showControls moving focus into
            // the bar, meant the hide timer was cancelled the
            // moment the bar appeared and could never fire.
            scheduleControlsHide()
        }
    }

    // MARK: - Transport bar: state

    private func refreshTransport() {
        guard controlsBuilt, let layer else { return }
        let cur = layer.player.currentPlaybackTime
        let dur = layer.player.duration
        currentTimeLabel.text = Self.clockText(cur)
        durationLabel.text = (dur.isFinite && dur > 0) ? Self.clockText(dur) : "--:--"
        if dur.isFinite, dur > 0, cur.isFinite {
            seekBar.fraction = max(0, min(1, cur / dur))
        } else {
            seekBar.fraction = 0
        }
        seekBar.setNeedsDisplay()
        playPauseButton.setImage(
            Self.transportSymbol(layer.state.isPlaying ? "pause.fill" : "play.fill"),
            for: .normal)
        if !ready || layer.state == .buffering {
            bufferingSpinner.startAnimating()
        } else {
            bufferingSpinner.stopAnimating()
        }
    }

    /// The play/pause glyph at a size the focused platter
    /// cannot swallow (v2.0.17): the bare system symbol
    /// renders at its small default point size inside the
    /// button, and the owner's close-up showed the focused
    /// plate huge with the glyph invisible inside it.
    private static func transportSymbol(_ name: String) -> UIImage? {
        UIImage(systemName: name,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 34, weight: .bold))
    }

    private static func clockText(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        return WatchStore.fmtClock(Int64(seconds * 1000))
    }

    /// Sizes and labels the two track buttons from the LIVE
    /// lists. Called at readyToPlay and after every selection:
    /// the audio button exists only when the file carries a
    /// choice (≥2 tracks, the system player's rule), the
    /// subtitle button only when the host's subtitle model
    /// holds at least one embedded info.
    private func refreshTrackButtons() {
        guard controlsBuilt, let layer else { return }
        let audioTracks = layer.player.tracks(mediaType: .audio)
        audioButton.isHidden = audioTracks.count < 2
        if let current = audioTracks.first(where: { $0.isEnabled }) {
            setConfiguredTitle(audioButton, "Âm thanh: \(Self.trackLabel(current))")
        } else {
            setConfiguredTitle(audioButton, "Âm thanh")
        }
        prepareSubtitleModel(layer: layer)
        subtitleButton.isHidden = subtitleModel.subtitleInfos.isEmpty
        if let selected = subtitleModel.selectedSubtitleInfo {
            // v2.0.30 (FIX6): a bare language code reads as
            // the language's name (see friendlyTrackName).
            setConfiguredTitle(subtitleButton,
                               "Phụ đề: \(Self.friendlyTrackName(selected.name))")
        } else {
            setConfiguredTitle(subtitleButton, "Phụ đề: Tắt")
        }
        layoutControls()
    }

    /// Feeds the host's SubtitleModel from the player's own
    /// subtitle data source — the library's readyToPlay
    /// pattern, verbatim in shape (VideoPlayerView and
    /// KSVideoPlayer.Coordinator both do exactly this): the
    /// feed is delayed 1 s because embedded subtitles carried
    /// inside the video stream can land after readyToPlay,
    /// and the default-enabled embed is auto-selected when
    /// the options ask for it (KSOptions' default is yes).
    /// A player with no source (the AVPlayer engine returns
    /// nil) simply never feeds, and the button stays hidden.
    ///
    /// v2.0.16: the session's side-loaded subtitle (the
    /// candidate's subtitleURL) is fed in the same pass and
    /// SELECTED — the Android player's auto-attach mirrored.
    /// Pre-fix the model only ever saw embedded tracks, so a
    /// file whose only subtitle was "default eng" offered no
    /// Vietnamese choice even though the app had already
    /// fetched one (the owner's Dune: Part Two clip). The
    /// feed no longer requires an embedded source at all: a
    /// file with no embedded subtitles still receives the
    /// side-loaded one. The picker lists it beside the
    /// embeds, and the owner can still switch or turn
    /// subtitles off.
    private func prepareSubtitleModel(layer: KSPlayerLayer) {
        let playerID = ObjectIdentifier(layer.player as AnyObject)
        guard subtitleFedPlayerID != playerID else { return }
        let dataSouce = layer.player.subtitleDataSouce
        let externalURL = externalSubtitleURL
        guard dataSouce != nil || externalURL != nil else { return }
        subtitleFedPlayerID = playerID
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, let layer = self.layer,
                  ObjectIdentifier(layer.player as AnyObject) == playerID
            else { return }
            if let dataSouce {
                self.subtitleModel.addSubtitle(dataSouce: dataSouce)
                // The owner's standing defaults (2026-11-17):
                // subtitle starts Vietnamese when the file
                // carries one, else English, else the file's
                // own default-flagged track; the side-loaded
                // Vietnamese below still outranks every embed,
                // and the picker stays free for any manual
                // choice. Skipped while the picker is open, so
                // a late feed can never override a choice the
                // owner is making.
                if self.subtitleModel.selectedSubtitleInfo == nil,
                   !self.pickerIsOpen {
                    let infos = self.subtitleModel.subtitleInfos
                    let pick = infos.first { Self.isVietnameseSubtitle($0) }
                        ?? infos.first { Self.isEnglishSubtitle($0) }
                        ?? (layer.options.autoSelectEmbedSubtitle
                            ? infos.first { $0.isEnabled } : nil)
                    if let pick {
                        self.subtitleModel.selectedSubtitleInfo = pick
                    }
                }
            }
            if let externalURL {
                let info = URLSubtitleInfo(
                    subtitleID: "joetv-external-vi",
                    name: "Tiếng Việt",
                    url: externalURL,
                    userAgent: JoeHTTP.userAgent)
                self.subtitleModel.addSubtitle(
                    dataSouce: JoeExternalSubtitleDataSouce(info: info))
                self.subtitleModel.selectedSubtitleInfo = info
            }
            self.buildSubtitleViewsIfNeeded()
            self.startSubtitleTimerIfNeeded()
            self.refreshTrackButtons()
        }
    }

    /// Language sniffing for the default-track rules: the
    /// engine's names are inconsistent across sources (ISO
    /// codes like "vie"/"eng", full words, the side-load's
    /// "Tiếng Việt"), so matching is by word token over the
    /// name + id, never by substring.
    private static func subtitleTokens(_ info: any SubtitleInfo) -> Set<String> {
        let raw = (info.name + " " + info.subtitleID).lowercased()
        return Set(raw.split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }

    private static func isVietnameseSubtitle(_ info: any SubtitleInfo) -> Bool {
        let t = subtitleTokens(info)
        return t.contains("vie") || t.contains("vi") || t.contains("viet")
            || t.contains("việt") || t.contains("vietnamese")
    }

    private static func isEnglishSubtitle(_ info: any SubtitleInfo) -> Bool {
        let t = subtitleTokens(info)
        return t.contains("eng") || t.contains("en") || t.contains("english")
    }

    private static func isEnglishAudio(_ track: MediaPlayerTrack) -> Bool {
        let raw = ((track.language ?? "") + " " + track.name).lowercased()
        let tokens = Set(raw.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        return tokens.contains("eng") || tokens.contains("en")
            || tokens.contains("english")
    }

    /// The audio half of the owner's defaults (2026-11-17):
    /// when a file offers a choice and its default track is
    /// not English while an English track exists, start in
    /// English (his Dune stream opened on the file's Spanish
    /// default). Once per player instance, at readyToPlay —
    /// a manual pick in the picker is never overridden,
    /// because this runs before any pick can exist and never
    /// again for the same player.
    private var audioDefaultPlayerID: ObjectIdentifier?
    private func applyDefaultAudio(layer: KSPlayerLayer) {
        let playerID = ObjectIdentifier(layer.player as AnyObject)
        guard audioDefaultPlayerID != playerID else { return }
        audioDefaultPlayerID = playerID
        let tracks = layer.player.tracks(mediaType: .audio)
        guard tracks.count >= 2,
              let current = tracks.first(where: { $0.isEnabled }),
              !Self.isEnglishAudio(current),
              let english = tracks.first(where: { Self.isEnglishAudio($0) })
        else { return }
        if let mePlayer = layer.player as? KSMEPlayer,
           let concrete = english as? FFmpegAssetTrack {
            mePlayer.select(track: concrete)
        } else {
            for track in tracks {
                track.isEnabled = track === english
            }
        }
    }

    private func buildSubtitleViewsIfNeeded() {
        guard !subtitleViewsBuilt else { return }
        subtitleViewsBuilt = true
        subtitleImageView.contentMode = .scaleAspectFit
        subtitleImageView.isHidden = true
        subtitleLabel.numberOfLines = 0
        subtitleLabel.textAlignment = .center
        subtitleLabel.font = SubtitleModel.textFont
        subtitleLabel.textColor = UIColor(SubtitleModel.textColor)
        subtitleLabel.layer.shadowColor = UIColor.black.cgColor
        subtitleLabel.layer.shadowOffset = CGSize(width: 1, height: 1)
        subtitleLabel.layer.shadowOpacity = 0.9
        subtitleLabel.layer.shadowRadius = 1
        subtitleImageView.addSubview(subtitleLabel)
        // Above the picture, below the transport controls.
        view.insertSubview(subtitleImageView, belowSubview: controlsView)
        layoutSubtitleViews()
    }

    private func layoutSubtitleViews() {
        guard subtitleViewsBuilt else { return }
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        // The strip lifts clear of the bar while the bar is
        // up (the system player's courtesy); otherwise it
        // rests near the bottom edge, the library's anchor
        // scaled to this host's 36 pt bottom margin.
        let lift: CGFloat = controlsVisible ? 168 + 36 + 16 : 44
        let height: CGFloat = 150
        subtitleImageView.frame = CGRect(x: 120,
                                         y: bounds.height - lift - height,
                                         width: bounds.width - 240,
                                         height: height)
        subtitleLabel.frame = subtitleImageView.bounds
    }

    private func startSubtitleTimerIfNeeded() {
        guard subtitleTimer == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.updateSubtitles()
        }
        RunLoop.main.add(timer, forMode: .common)
        subtitleTimer = timer
    }

    /// Paints the model's current parts — text into the
    /// label, an image part (PGS / DVB) into the image view —
    /// VideoPlayerView's update, shape for shape: it
    /// repaints only when the model reports the parts
    /// changed, and clears both halves when no part is due.
    private func updateSubtitles() {
        guard subtitleViewsBuilt, let layer else { return }
        if subtitleModel.subtitle(currentTime: layer.player.currentPlaybackTime) {
            if let part = subtitleModel.parts.first {
                subtitleImageView.image = part.image
                subtitleLabel.attributedText = part.text
                subtitleImageView.isHidden = false
            } else {
                subtitleImageView.image = nil
                subtitleLabel.attributedText = nil
                subtitleImageView.isHidden = true
            }
        }
        layoutSubtitleViews()
    }

    /// v2.0.29 (item 3): a candidate label flattened for a
    /// one-line picker row — Torrentio/MF stream names are
    /// multi-line (a source line, a quality line), and the
    /// picker rows are single-line, so the lines join with
    /// " · " instead of truncating at the first break.
    /// Display only; the candidate's own label is unchanged
    /// everywhere else (the status capsule shows it whole).
    private static func flattenedSourceLabel(_ label: String) -> String {
        label.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private static func trackLabel(_ track: MediaPlayerTrack) -> String {
        var parts: [String] = []
        if let language = track.language, !language.isEmpty {
            parts.append(language)
        }
        if !track.name.isEmpty {
            parts.append(track.name)
        }
        return parts.isEmpty ? "Track \(track.trackID)" : parts.joined(separator: " - ")
    }

    // MARK: - Transport bar: actions & track picker

    @objc private func playPauseButtonTapped() {
        showControls()
        togglePlayPause()
    }

    @objc private func subtitleButtonTapped() {
        openPicker(kind: .subtitles)
    }

    @objc private func audioButtonTapped() {
        openPicker(kind: .audio)
    }

    @objc private func switchSourceButtonTapped() {
        // v2.0.29 (item 3): the button now OPENS THE SOURCE
        // CHOOSER — the same picker panel the subtitle/audio
        // buttons open, listing the session's candidates —
        // instead of the FIX4 behaviour of blindly advancing
        // to the next candidate (owner finding on 2.0.28:
        // "bấm là nó tự lấy một nguồn khác, không hiện danh
        // sách cho chọn"; manual selection is his standing
        // rule). The pick itself goes through
        // PlayDirector.userSwitchSource(to:) — see
        // pickerButtonTapped's .sources case. The bar is
        // woken first so the press registers as activity.
        showControls()
        openPicker(kind: .sources)
    }

    private func openPicker(kind: PickerKind) {
        // v2.0.29 (item 3): the source chooser's rows come
        // from the director's ladder, not the engine, so it
        // is not held to the track pickers' ready + layer
        // guard below — their rows ARE the engine's live
        // lists, its rows exist from the session's start.
        if kind == .sources {
            openSourceChooser()
            return
        }
        guard ready, let layer else { return }
        pickerKind = kind
        for button in pickerButtons { button.removeFromSuperview() }
        pickerButtons.removeAll()
        switch kind {
        case .subtitles:
            pickerTitleLabel.text = "Phụ đề"
            pickerSubtitleInfos = subtitleModel.subtitleInfos
            pickerAudioTracks = []
            pickerSourceLabels = []
            pickerSourceIndex = -1
            addPickerButton(title: "Tắt", checked: subtitleModel.selectedSubtitleInfo == nil, tag: -1)
            for (index, info) in pickerSubtitleInfos.enumerated() {
                let checked = subtitleModel.selectedSubtitleInfo?.subtitleID == info.subtitleID
                addPickerButton(title: info.name.isEmpty ? "Phụ đề \(index + 1)" : Self.friendlyTrackName(info.name),
                                checked: checked, tag: index)
            }
        case .audio:
            pickerTitleLabel.text = "Âm thanh"
            pickerAudioTracks = layer.player.tracks(mediaType: .audio)
            pickerSubtitleInfos = []
            pickerSourceLabels = []
            pickerSourceIndex = -1
            for (index, track) in pickerAudioTracks.enumerated() {
                addPickerButton(title: Self.trackLabel(track),
                                checked: track.isEnabled, tag: index)
            }
        case .sources:
            // Unreachable — routed to openSourceChooser()
            // above; the case exists so the switch stays
            // exhaustive over PickerKind.
            break
        }
        showPickerPanel()
    }

    /// v2.0.29 (item 3): the "Đổi nguồn" chooser — the
    /// session's candidate list in the host's standing
    /// picker panel: one row per candidate in the current
    /// ladder, the candidate's own label (flattened to one
    /// line), the current candidate checked, focus landing
    /// on the current row (preferredFocusEnvironments).
    /// Picking a row switches through
    /// PlayDirector.userSwitchSource(to:) — the position
    /// is kept by the standing itemReady resume rule, the
    /// same machinery the old blind advance used.
    private func openSourceChooser() {
        guard let director else { return }
        pickerKind = .sources
        for button in pickerButtons { button.removeFromSuperview() }
        pickerButtons.removeAll()
        pickerTitleLabel.text = "Chọn nguồn"
        let choices = director.sourceChoices
        pickerSourceLabels = choices
        pickerSubtitleInfos = []
        pickerAudioTracks = []
        pickerSourceIndex = choices.first(where: { $0.isCurrent })?.index ?? -1
        for choice in choices {
            addPickerButton(title: Self.flattenedSourceLabel(choice.label),
                            checked: choice.isCurrent, tag: choice.index)
        }
        showPickerPanel()
    }

    /// The picker tail shared by every kind (extracted in
    /// v2.0.29 from openPicker, byte-identical in effect):
    /// the panel replaces the bar, the hide timer stands
    /// down while a choice is open, focus moves to the
    /// picker's preferred landing.
    private func showPickerPanel() {
        guard !pickerButtons.isEmpty else { return }
        pickerIsOpen = true
        pickerView.isHidden = false
        transportBar.isHidden = true
        controlsVisible = true
        controlsView.isHidden = false
        // v2.0.29 (item 2): the picker is summoned chrome —
        // the status capsule stays with the chrome while a
        // choice is open, like it does with the bar.
        director?.setTransportBarVisible(true)
        // v2.0.31 (L5): the shell's exit command owns Menu
        // now — register this host's close so its first
        // press closes just this panel (see PlayDirector
        // .pickerOpen). Registered on every opening; the
        // matching clear rides closePicker.
        director?.setPickerOpen(true) { [weak self] in
            self?.closePicker()
        }
        hideTimer?.invalidate()
        layoutPicker()
        setNeedsFocusUpdate()
        // v2.0.31 (L4/L5): force the landing NOW — the
        // picker's first row must actually hold focus when
        // the panel is up, not whenever the engine gets to
        // the pending update: a panel whose rows never took
        // focus is the panel whose presses go nowhere.
        updateFocusIfNeeded()
    }

    private func addPickerButton(title: String, checked: Bool, tag: Int) {
        let button = UIButton(type: .system)
        button.tag = tag
        // v2.0.30 (FIX6): same one-plate configuration as
        // the bar buttons — the pre-fix hand plate (white
        // 0.10 + layer radius 12) doubled with the system's
        // focus platter here too. Resting values unchanged
        // (27 medium, insets 8×20, left-aligned).
        button.configuration = Self.transportButtonConfiguration(
            title: (checked ? "✓   " : "      ") + title,
            font: .systemFont(ofSize: 27, weight: .medium),
            backgroundAlpha: 0.10, cornerRadius: 12,
            contentInsets: NSDirectionalEdgeInsets(top: 8, leading: 20,
                                                   bottom: 8, trailing: 20))
        button.configurationUpdateHandler = Self.transportFocusHandler
        button.contentHorizontalAlignment = .left
        button.addTarget(self, action: #selector(pickerButtonTapped(_:)),
                         for: .primaryActionTriggered)
        pickerView.addSubview(button)
        pickerButtons.append(button)
    }

    @objc private func pickerButtonTapped(_ sender: UIButton) {
        guard let layer else {
            closePicker()
            return
        }
        switch pickerKind {
        case .subtitles:
            if sender.tag < 0 {
                subtitleModel.selectedSubtitleInfo = nil
            } else if pickerSubtitleInfos.indices.contains(sender.tag) {
                subtitleModel.selectedSubtitleInfo = pickerSubtitleInfos[sender.tag]
            }
        case .audio:
            if pickerAudioTracks.indices.contains(sender.tag) {
                // KSPlayer 2.3.4's select(track:) takes an opaque
                // `some MediaPlayerTrack` — an existential straight
                // out of the picker array cannot satisfy it (that
                // was CI run #39's only error). Hand it the concrete
                // track the FFmpeg engine vends, via the concrete
                // player, so the generic binds to a concrete type.
                let chosen = pickerAudioTracks[sender.tag]
                if let mePlayer = layer.player as? KSMEPlayer,
                   let concrete = chosen as? FFmpegAssetTrack {
                    mePlayer.select(track: concrete)
                } else {
                    // Any other engine: select() ultimately flips
                    // isEnabled across the same media type (see
                    // MEPlayerItem.select) — mirror that directly.
                    for track in pickerAudioTracks {
                        track.isEnabled = track === chosen
                    }
                }
            }
        case .sources:
            // v2.0.29 (item 3): the tag IS the candidate's
            // ladder index (openSourceChooser). The panel
            // closes first — the switch recreates this host
            // for the chosen attempt (.id(attemptID)), so no
            // track refresh applies here — then the director
            // switches, keeping the position through the
            // standing itemReady resume rule. Picking the
            // current row is the director's no-op.
            let index = sender.tag
            closePicker()
            director?.userSwitchSource(to: index)
            return
        }
        refreshTrackButtons()
        // v2.0.31 (L4): the track pickers close DEFERRED —
        // never inside the tapped row's own press dispatch
        // (see closePickerDeferred). The source chooser
        // above keeps its immediate close: its switch tears
        // this host down and rebuilds it, so no focus state
        // of this host's survives to be stranded.
        closePickerDeferred()
    }

    /// v2.0.31 (L4): close the picker on the next runloop
    /// turn instead of inside the tapped button's action.
    /// The tapped row IS the focused view; the pre-fix
    /// closePicker removed it from the hierarchy in the
    /// middle of its own .primaryActionTriggered dispatch,
    /// and on the owner's set the focus engine never
    /// landed anywhere afterwards — later presses were
    /// delivered to no focused view at all, so with the
    /// film paused his play press (the button showing the
    /// triangle, its state read correctly by
    /// refreshTransport) did nothing, every time, until
    /// the session changed. Deferred, the press cycle
    /// completes with the hierarchy intact; the close then
    /// runs as an ordinary state change, and closePicker's
    /// forced focus update lands focus on the play button
    /// deterministically — the same landing the bar-wake
    /// path has always made. Idempotent: a second queued
    /// close reads pickerIsOpen false and no-ops.
    private func closePickerDeferred() {
        DispatchQueue.main.async { [weak self] in
            self?.closePicker()
        }
    }

    private func closePicker() {
        guard pickerIsOpen else { return }
        pickerIsOpen = false
        // v2.0.31 (L5): the shell's Menu routing stands
        // down with the panel.
        director?.setPickerOpen(false)
        pickerView.isHidden = true
        transportBar.isHidden = false
        for button in pickerButtons { button.removeFromSuperview() }
        pickerButtons.removeAll()
        pickerSubtitleInfos = []
        pickerAudioTracks = []
        pickerSourceLabels = []
        pickerSourceIndex = -1
        setNeedsFocusUpdate()
        // v2.0.31 (L4): force the relocation to the play
        // button NOW (the host's preferredFocusEnvironments
        // names it while the bar is up) instead of leaving
        // it to the engine's next cycle — the relocation is
        // the step whose absence stranded the owner's
        // presses after a pick. Skipped during teardown
        // (no window): a dying host must not reach for
        // focus on its way out.
        if view.window != nil {
            updateFocusIfNeeded()
        }
        showControls()
    }

    deinit {
        // The subtitle paint timer is the one timer teardown
        // does not own — it is born with the subtitle model
        // feed, not with the view — so it dies here, with
        // the host itself.
        subtitleTimer?.invalidate()
    }

    // MARK: - KSPlayerLayerDelegate

    func player(layer: KSPlayerLayer, state: KSPlayerState) {
        switch state {
        case .readyToPlay:
            // FIX4 (fix 1): re-assert the display criteria at
            // the moment playback actually starts. Apple's
            // choreography (Tech Talk 503) is: state the
            // criteria on the key window's AVDisplayManager,
            // then start playback — the switch keys off the
            // preference standing when frames begin. The
            // viewDidAppear application can be lost before
            // this point (a stale host's teardown landing
            // late, the cover transition), so the preference
            // is stated again here, per attempt, where it
            // cannot be overtaken.
            applyDisplayCriteria()
            // v2.0.5 (P3): readyToPlay disarms the first-frame
            // budget too — the engine has announced itself; a
            // start that is merely slow to fill its buffer is
            // viable and must not be killed at the budget. (The
            // mid-play freeze watchdog still guards a playhead
            // that never advances after this point.)
            firstFrameWatchdog?.cancel()
            if !ready {
                ready = true
                let dur = layer.player.duration
                let durMs = dur.isFinite ? Int64(dur * 1000) : 0
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    // The track lists exist only from this
                    // point on: size the bar's subtitle/audio
                    // buttons from the live lists now (a file
                    // with no second audio track gets no audio
                    // button, like the system player).
                    self.applyDefaultAudio(layer: layer)
                    self.refreshTrackButtons()
                    self.refreshTransport()
                    self.director?.itemReady(durationMs: durMs) { ms in
                        layer.seek(time: TimeInterval(ms) / 1000,
                                   autoPlay: true) { _ in }
                    }
                }
            }
        case .bufferFinished:
            if !playing {
                playing = true
                firstFrameWatchdog?.cancel()
                lastAdvanceAt = Date()
                let now = layer.player.currentPlaybackTime
                lastPositionSec = now.isFinite ? now : -1
            }
            refreshTransport()
        case .error:
            fireFail(cause: "Engine báo lỗi (KSPlayer state .error)")
        default:
            break
        }
    }

    func player(layer: KSPlayerLayer, currentTime: TimeInterval, totalTime: TimeInterval) {
        let now = Date()
        guard now.timeIntervalSince(lastTickAt) >= 5 else { return }
        lastTickAt = now
        director?.tick(positionMs: Int64(currentTime * 1000),
                       durationMs: totalTime.isFinite ? Int64(totalTime * 1000) : 0)
    }

    func player(layer: KSPlayerLayer, finish error: Error?) {
        if let error {
            // v2.0.5 (error 8a): the Error is READ before the
            // failure is reported — pre-fix this delegate
            // checked only `error != nil` and discarded the
            // value, so the one artefact that could convict
            // the failure cause never reached any log or UI.
            fireFail(cause: error.localizedDescription)
        } else if !ended {
            ended = true
            DispatchQueue.main.async { [weak self] in
                self?.director?.itemEnded()
            }
        }
    }

    func player(layer: KSPlayerLayer, bufferedCount: Int, consumeTime: TimeInterval) {}

    // MARK: - Stall handling

    /// One freeze-watchdog tick (1 s, main run loop). Mirrors
    /// the AVPlayer coordinator's judgement exactly: user
    /// pause holds the clock open, the end of the file belongs
    /// to the finish delegate, any playhead movement counts as
    /// alive.
    private func checkFreeze() {
        guard playing, !ended, !failed, let layer else { return }
        if layer.state == .paused || !layer.player.isPlaying {
            lastAdvanceAt = Date()
            let now = layer.player.currentPlaybackTime
            if now.isFinite { lastPositionSec = now }
            return
        }
        let pos = layer.player.currentPlaybackTime
        guard pos.isFinite else { return }
        let dur = layer.player.duration
        if dur.isFinite, dur > 0, pos >= dur - 1.5 {
            lastAdvanceAt = Date()
            lastPositionSec = pos
            return
        }
        if lastPositionSec >= 0 {
            if abs(pos - lastPositionSec) > 0.05 {
                lastAdvanceAt = Date()
            }
        } else {
            lastAdvanceAt = Date()
        }
        lastPositionSec = pos
        if Date().timeIntervalSince(lastAdvanceAt) >= 30 {
            stallFail(reason: "Hình đứng yên 30 giây (đóng băng)")
        }
    }

    /// A stall (first-frame budget or frozen playhead): the
    /// owner SEES why the picture changed — the notice rides
    /// the shell's status capsule — then the ladder advances.
    /// `reason` also rides to the director as the failure
    /// cause, so a watchdog kill is labelled as a watchdog
    /// kill in the log and on the exhausted slate, never
    /// mistaken for an engine error.
    private func stallFail(reason: String) {
        guard !failed else { return }
        director?.notice = "Nguồn này không phát được — đang chuyển nguồn khác…"
        fireFail(cause: reason)
    }

    private func fireFail(cause: String? = nil) {
        guard !failed else { return }
        failed = true
        firstFrameWatchdog?.cancel()
        freezeTimer?.invalidate()
        freezeTimer = nil
        DispatchQueue.main.async { [weak self] in
            self?.director?.itemFailed(cause: cause)
        }
    }
}

/// The host's root view — the one focusable surface of the KS
/// player screen. tvOS focus can only land on a UIView: a view
/// controller has no `canBecomeFocused` to override (that line
/// is what CI run #24 rejected). With focus on this view,
/// remote presses bubble up the responder chain to the host
/// controller's `pressesEnded`, which is where Select and
/// Left/Right are handled; Menu is never swallowed there.
/// v2.0.16: a one-info SubtitleDataSouce carrying the
/// session's side-loaded subtitle. KSPlayer's
/// URLSubtitleInfo downloads and parses the file lazily
/// when it becomes the selected info.
private final class JoeExternalSubtitleDataSouce: SubtitleDataSouce {
    var infos: [any SubtitleInfo]
    init(info: URLSubtitleInfo) { infos = [info] }
}

private final class KSPlayerHostRootView: UIView {
    /// v2.0.18: DYNAMIC, not a constant. While the transport
    /// bar (or the picker) is up, the root REFUSES focus: a
    /// focus update then has no eligible incumbent and MUST
    /// relocate, and only relocation consults the host's
    /// preferredFocusEnvironments. That was the 2.0.17 fix's
    /// missing half — preferred environments guide focus
    /// ENTERING an environment (or being evicted from an
    /// ineligible view); they cannot pull focus off an
    /// eligible full-screen view that already holds it, so
    /// focus stayed glued to this root, its full-screen frame
    /// offered the focus engine no directional exit, and
    /// every arrow fell through to the host's seek handler —
    /// the owner's "không cho mình bấm qua để chỉnh".
    var acceptsFocus = true
    override var canBecomeFocused: Bool { acceptsFocus }
}

/// The transport bar's seek bar (v2.0.12). UISlider cannot
/// take tvOS focus or answer the remote at all, so the bar is
/// a plain focusable view that draws track / played fill /
/// knob itself (growing the knob under focus, the system's
/// own emphasis language) and answers the presses the system
/// player answers on its timeline: Left/Right clicks step
/// ∓30 s (the host's standing seek step), Select toggles
/// play/pause. Presses it does not handle — Up back to the
/// button row, Menu out of the player — are passed up the
/// responder chain untouched. No buffered fill is drawn: the
/// KS layer's verified delegate surface exposes no buffered
/// time range (bufferedCount is an event count, not a time),
/// and an invented fill would be a lie on screen.
private final class KSSeekBarView: UIView {
    /// Played fraction, 0...1.
    var fraction: Double = 0
    var onStep: ((TimeInterval) -> Void)?
    var onTogglePlayPause: (() -> Void)?

    override var canBecomeFocused: Bool { true }

    override func draw(_ rect: CGRect) {
        let barHeight: CGFloat = isFocused ? 10 : 6
        let y = (rect.height - barHeight) / 2
        let trackRect = CGRect(x: 0, y: y, width: rect.width, height: barHeight)
        UIColor.white.withAlphaComponent(0.35).setFill()
        UIBezierPath(roundedRect: trackRect, cornerRadius: barHeight / 2).fill()
        let fillWidth = rect.width * CGFloat(max(0, min(1, fraction)))
        if fillWidth > 0 {
            let fillRect = CGRect(x: 0, y: y, width: fillWidth, height: barHeight)
            UIColor.white.setFill()
            UIBezierPath(roundedRect: fillRect, cornerRadius: barHeight / 2).fill()
        }
        let knob: CGFloat = isFocused ? 30 : 18
        let knobX = max(0, min(rect.width - knob, fillWidth - knob / 2))
        let knobRect = CGRect(x: knobX, y: (rect.height - knob) / 2,
                              width: knob, height: knob)
        UIColor.white.setFill()
        UIBezierPath(ovalIn: knobRect).fill()
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext,
                                 with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        setNeedsDisplay()
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            switch press.type {
            case .leftArrow:
                onStep?(-30)
                handled = true
            case .rightArrow:
                onStep?(30)
                handled = true
            case .select:
                onTogglePlayPause?()
                handled = true
            default:
                break
            }
        }
        if !handled {
            super.pressesEnded(presses, with: event)
        }
    }
}
