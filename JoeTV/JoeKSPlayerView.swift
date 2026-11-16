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
/// (PlayerActivity STALL / POSITION_STALL, both 12 s):
///   • first frame: if the engine has not reached its playing
///     state 12 s after the attempt starts, the attempt fails
///     with a visible notice and the ladder moves on;
///   • mid-play freeze: once playing, a playhead that does not
///     advance for 12 s (and is not user-paused) fails the same
///     way. No torrent attempt can spin forever any more.
/// Transport: KSPlayerLayer registers the remote's media
/// commands itself (play/pause, ±15 s skip, position change);
/// the host controller adds click handling — Select toggles
/// play/pause, Left/Right clicks seek ∓30 s. Menu is never
/// swallowed: it propagates to the shell's exit command, like
/// the AVPlayer path.
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
    /// The candidate start() was handed. Layer creation is
    /// DEFERRED until the first layout pass with real bounds
    /// (v2.0.5, error 3b — see beginPlaybackIfPossible), so the
    /// candidate waits here until the view has a true size.
    private var pendingCandidate: PlayCandidate?
    private var failed = false
    private var ready = false
    private var playing = false
    private var ended = false
    /// First-frame budget (12 s, Android STALL parity): armed
    /// when the layer is created, cancelled the moment the
    /// engine reports readyToPlay or its playing state
    /// (v2.0.5: readyToPlay added — a slow-but-viable start
    /// that had announced itself ready was previously still
    /// killed at 12 s because only bufferFinished disarmed
    /// the budget).
    private var firstFrameWatchdog: DispatchWorkItem?
    /// Mid-play freeze watchdog (12 s without playhead advance,
    /// Android POSITION_STALL parity): a 1 s ticker, judging
    /// only after the first frame — the same shape as the
    /// AVPlayer coordinator's freeze watch.
    private var freezeTimer: Timer?
    private var lastPositionSec = -1.0
    private var lastAdvanceAt = Date()
    /// Director ticks ride the AV path's ~5 s cadence even
    /// though the engine reports time every 0.1 s.
    private var lastTickAt = Date.distantPast

    override func loadView() {
        view = KSPlayerHostRootView()
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [view] }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setNeedsFocusUpdate()
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
        beginPlaybackIfPossible()
    }

    func start(candidate: PlayCandidate, director: PlayDirector) {
        self.director = director
        pendingCandidate = candidate
        view.backgroundColor = .black
        // makeUIViewController calls this BEFORE the view has
        // been laid out — creating the layer there froze the
        // surface at the pre-layout (safe-area) size forever
        // (error 3b). Actual creation waits for bounds.
        beginPlaybackIfPossible()
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
            view.addSubview(playerView)
        }
        // v2.0.5 (P2): play EXPLICITLY. The pre-fix host never
        // called play() at start — playback depended on the
        // library's autoplay behaviour, which this side has
        // never verified; a host that wants playback must ask
        // for it.
        layer.play()
        let wd = DispatchWorkItem { [weak self] in
            guard let self, !self.playing else { return }
            self.stallFail(reason: "Chưa có hình sau 12 giây")
        }
        firstFrameWatchdog = wd
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: wd)
        lastAdvanceAt = Date()
        let ticker = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkFreeze()
        }
        RunLoop.main.add(ticker, forMode: .common)
        freezeTimer = ticker
    }

    func teardown() {
        // A dismantled host must never begin playback late:
        // drop the deferred candidate first.
        pendingCandidate = nil
        firstFrameWatchdog?.cancel()
        firstFrameWatchdog = nil
        freezeTimer?.invalidate()
        freezeTimer = nil
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
                togglePlayPause()
                handled = true
            case .leftArrow:
                seekBy(-30)
                handled = true
            case .rightArrow:
                seekBy(30)
                handled = true
            default:
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
    }

    private func seekBy(_ delta: TimeInterval) {
        guard let layer else { return }
        let target = max(0, layer.player.currentPlaybackTime + delta)
        layer.seek(time: target, autoPlay: true) { _ in }
    }

    // MARK: - KSPlayerLayerDelegate

    func player(layer: KSPlayerLayer, state: KSPlayerState) {
        switch state {
        case .readyToPlay:
            // v2.0.5 (P3): readyToPlay disarms the first-frame
            // budget too — the engine has announced itself; a
            // start that is merely slow to fill its buffer is
            // viable and must not be killed at 12 s. (The
            // mid-play freeze watchdog still guards a playhead
            // that never advances after this point.)
            firstFrameWatchdog?.cancel()
            if !ready {
                ready = true
                let dur = layer.player.duration
                let durMs = dur.isFinite ? Int64(dur * 1000) : 0
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
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
        if Date().timeIntervalSince(lastAdvanceAt) >= 12 {
            stallFail(reason: "Hình đứng yên 12 giây (đóng băng)")
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
private final class KSPlayerHostRootView: UIView {
    override var canBecomeFocused: Bool { true }
}
