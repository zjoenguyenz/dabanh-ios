import AVFoundation
import AVKit
import Combine
import OSLog
import SwiftUI
import UIKit

/// Playback failure log (v2.0.5, error 8a): the torrent path
/// used to discard every engine error unread — the KS delegate
/// received the finish Error and threw it away, RD resolution
/// failures vanished into a bare `try?`, and the exhausted
/// slate carried no evidence at all. Failures are now logged
/// with engine + HOST ONLY: Torrentio URLs embed the owner's
/// RD token in the path, so a full URL (or any token) must
/// never reach the log.
enum PlaybackLog {
    static let logger = Logger(subsystem: "com.luun.nguyen.joetv",
                               category: "playback")
}

/// One playable stream candidate: a freshly resolved URL plus
/// the headers its CDN demands (never a blanket header — see the
/// house rule in Channel.swift).
struct PlayCandidate {
    /// Which engine plays this candidate. Provider ladders stay
    /// on AVPlayer (the house player, untouched). Torrent
    /// candidates (TorrentClient.playCandidates — the torrent
    /// section AND the Phim substitution rung) carry .ffmpeg:
    /// the files Torrentio/Real-Debrid serve are predominantly
    /// Matroska, which AVFoundation cannot demux at all — those
    /// items never became ready and the session walked a long
    /// list of them as one endless black spinner (v2.0.3).
    enum Engine {
        case avPlayer
        case ffmpeg
    }

    var url: URL
    var headers: [String: String] = [:]
    var label: String = ""
    var engine: Engine = .avPlayer

    /// v2.0.16: the side-loaded subtitle the session resolved
    /// for this title — the subtitle addon's best Vietnamese
    /// (JoeTorrentDetail attaches it to every ladder
    /// candidate). The KSPlayer host adds it to its subtitle
    /// model beside the file's embedded tracks and selects
    /// it, the Android player's auto-attach mirrored. Nil
    /// for provider candidates and titles without one.
    var subtitleURL: URL? = nil

    /// v2.0.26 (idea 10): the torrent stream's parsed display
    /// features, stamped by TorrentClient.playCandidates from
    /// the TorStream's own ranking parse. The KSPlayer host
    /// reads them to build its preferredDisplayCriteria (the
    /// AVPlayer path is matched by the system and ignores
    /// them). Defaults = SDR / unknown rate: provider
    /// candidates never set them.
    var dv = false
    var hdr = false
    /// Frame rate parsed from the release name when present
    /// (e.g. 59.94 / 50); nil = no explicit rate in the name.
    var fps: Double? = nil

    /// The AVURLAsset the AVPlayer path opens for this
    /// candidate: exactly the candidate's headers, plus the
    /// house user agent when none was set. Shared by the
    /// cold path (PlayerController) and the dwell warmer
    /// (StreamWarmer) so both open the stream identically —
    /// the warmer's whole value is that the tap re-opens
    /// nothing it already loaded.
    func makeAsset() -> AVURLAsset {
        var headers = self.headers
        if headers["User-Agent"] == nil {
            headers["User-Agent"] = JoeHTTP.userAgent
        }
        return AVURLAsset(url: url,
                          options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
    }
}

/// Everything the player needs to keep WatchStore honest: the
/// entry template saved on ticks, and the key the resume position
/// was read from. After a cross-provider hop the detail view
/// re-issues the session with the NEW provider's identity — the
/// resume position itself is carried over by the director.
struct PlayIdentity {
    var entry: WatchStore.Entry
    var progressKey: String { entry.key }
}

/// The play session's brain: resolves ladders, drives the
/// Android-verified failover ladder (same-provider refresh once,
/// then one cross-provider hop), applies the resume rule and saves
/// progress at the Android cadence. The SwiftUI view below is a
/// thin shell over it.
@MainActor
final class PlayDirector: ObservableObject {
    enum Phase {
        case resolving
        case playing
        case exhausted
    }

    @Published private(set) var phase: Phase = .resolving
    @Published private(set) var attemptID = 0
    @Published var notice: String?
    @Published private(set) var currentLabel = ""
    /// v2.0.29 (item 2): the live host's transport-bar
    /// visibility, reported by the host itself — the KS
    /// host from its show/hide path, the AVPlayer host from
    /// the fix-9 delegate callback. The shell binds the
    /// status capsule's visibility to this, so the capsule
    /// (the candidate's source label / the resume and
    /// failover notices) hides and returns WITH the bar on
    /// both engines and can never linger on its own: the
    /// capsule itself has no timer and no other state.
    /// Starts true — both hosts open with their bar up.
    @Published private(set) var transportBarVisible = true

    /// Hosts report their bar's visibility here. Only a
    /// change publishes, so a host re-asserting its state
    /// (every press wakes the KS bar) costs no re-render.
    func setTransportBarVisible(_ visible: Bool) {
        if transportBarVisible != visible {
            transportBarVisible = visible
        }
    }

    /// v2.0.31 (L5): the KS host's picker state, reported
    /// by the host on the same pattern as the bar
    /// visibility above. The shell's exit command consults
    /// it: a Menu press while a picker is open closes the
    /// PICKER — through the host's own closePicker, via the
    /// registered handler — instead of dismissing the
    /// player. The host deliberately no longer intercepts
    /// Menu in its pressesEnded: on the owner's set the
    /// press reached BOTH consumers (the host closed the
    /// panel and the shell still dismissed), so Back out
    /// of the subtitle panel exited the film. With the
    /// host's interception gone, the shell is the one
    /// Menu arbiter for both engines, exactly as it
    /// already was whenever no picker was open.
    @Published private(set) var pickerOpen = false
    /// The live KS host's close-the-picker action,
    /// registered while its picker is open (nil on the
    /// AVPlayer path, between attempts, and once closed).
    private var pickerCloseHandler: (() -> Void)?

    func setPickerOpen(_ open: Bool, closeHandler: (() -> Void)? = nil) {
        pickerCloseHandler = open ? closeHandler : nil
        if pickerOpen != open {
            pickerOpen = open
        }
    }

    /// Menu with a picker open: close just the picker.
    /// The handler is the host's closePicker, so focus
    /// landing and bar state are restored by the same code
    /// that closes the panel after a selection.
    func requestPickerClose() {
        pickerCloseHandler?()
    }
    /// The most recent candidate failure's short cause (an
    /// engine error's description, or a watchdog label) — the
    /// exhausted slate shows it ("Lỗi cuối: …") so a dead
    /// slate finally says WHY, and itemFailed logs it. Set by
    /// whichever engine/watchdog reports the failure; cleared
    /// on a manual retry.
    @Published private(set) var lastFailure: String?

    // MARK: Up Next contract (v2.0.25, Idea 6 core)
    //
    // The factories that build the NEXT episode's session
    // (detail views / episode lists) wire these three
    // members on the CURRENT director before playback; the
    // player view itself only renders the countdown and
    // performs the handover (see JoePlayerView below).
    // Sessions that never set a factory keep the exact
    // pre-Up-Next end behaviour: itemEnded() just drops
    // the progress entry and nothing else happens.

    /// Builds the next episode's director, or nil when no
    /// next episode could be resolved. Called at most once
    /// per countdown (at zero, or from advanceNow()).
    var nextEpisodeFactory: (@MainActor () async -> PlayDirector?)?
    /// The next episode's display title, shown on the
    /// countdown card.
    var nextEpisodeTitle: String = ""
    /// Fired exactly once per session, from the shared
    /// itemReady core, on the FIRST ready item — the hook
    /// the shared warming system uses to warm the upcoming
    /// episode while this one plays.
    var onPlayingStarted: (@MainActor () -> Void)?

    /// Seconds left on the Up Next countdown (10 → 1);
    /// nil = no countdown is active.
    @Published private(set) var upNextSecondsLeft: Int?
    /// The next episode's director, published when the
    /// countdown's factory resolves one. The view observes
    /// this and swaps its session director in place.
    @Published private(set) var advanceTarget: PlayDirector?

    /// The countdown / advance task (one at a time) and a
    /// generation counter that invalidates a superseded
    /// run: cancelAdvance() and advanceNow() both bump the
    /// generation, so a factory result that lands after a
    /// cancel can never publish an advanceTarget.
    private var upNextTask: Task<Void, Never>?
    private var upNextGeneration = 0
    /// FIX4 (fix 6): latched the first time the Up Next card
    /// is armed for this item — by the last-10-seconds tick
    /// trigger, or by itemEnded's fallback. A user cancel
    /// must not let a later tick (or the end itself) re-arm
    /// the card for the same item.
    private var upNextArmed = false
    /// Once-per-session guard for onPlayingStarted (the
    /// firstFrameMarked guard below is its model).
    private var playingStartedNotified = false

    /// What the view should render right now.
    private(set) var candidate: PlayCandidate?

    private let store: WatchStore
    private var identity: PlayIdentity
    /// Builds a fresh ladder for the CURRENT identity (detail
    /// views own this: re-fetch detail → Providers.ladderFor).
    private let resolveLadder: (PlayIdentity) async -> [PlayCandidate]
    /// nil for sources with no cross-provider hop (torrent).
    private let hopIdentity: ((PlayIdentity) async -> PlayIdentity?)?
    /// The substitution rung (owner law, v1.9): when the ladder
    /// AND the hop are both exhausted, the director asks this
    /// closure for replacement candidates for the SAME title
    /// from another source family, still under the CURRENT
    /// identity (resume/Continue Watching stay on the original
    /// entry). The Phim detail wires it to the torrent side,
    /// matched by TMDB/IMDB id. nil for sources with nothing
    /// behind them (the torrent section's own sessions) — those
    /// exhaust exactly as before.
    private let fallbackCandidates: ((PlayIdentity) async -> [PlayCandidate])?
    /// Resume position read at session start (>20 s rule applied
    /// by the caller against the stored entry).
    private let resumeMs: Int64

    private var candidates: [PlayCandidate] = []
    private var candidateIndex = 0
    private var refreshed = false
    private var hopped = false
    private var fallbackTried = false
    private var seekApplied = false
    private var lastPosMs: Int64 = 0
    private var lastDurMs: Int64 = 0
    private var started = false

    // v2.0.8 (Phase 3): ONE stored resolution task + ONE
    // end-to-end deadline for the ladder+failover sequence.
    // Every resolution spawn (start, candidate exhaustion,
    // manual retry) stores its handle in `resolutionTask`, so
    // the deadline watchdog can cancel the whole chain; the
    // in-task chain itself (loadLadder ↔ failoverStep) runs
    // as direct awaits inside that one task. The watchdog is
    // a second stored task, armed when the session's first
    // resolution starts and re-armed by a manual retry; it
    // STANDS DOWN the moment the torrent substitution rung
    // starts (see failoverStep) — the debrid resolve is never
    // cancelled mid-flight, hedged, or retried.
    private var resolutionTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    /// The one Play budget: 60 s from the first resolution
    /// start to a playing candidate or the exhausted slate.
    private static let resolutionDeadline: TimeInterval = 60
    /// PerfLog once-per-session guards (Phase 3 marks).
    private var ladderReadyMarked = false
    private var firstFrameMarked = false

    /// Race box for the hedged failover pair (Phase 3): the
    /// refresh branch and the hop branch each publish their
    /// ladder (nil = still running) and a done flag; the
    /// failover poll reads them. Both branches run as tasks
    /// on the main actor, so the box is only ever touched
    /// between awaits — no lock needed.
    private final class HedgeBox {
        var refreshLadder: [PlayCandidate]?
        var refreshDone = false
        var hopIdentity: PlayIdentity?
        var hopLadder: [PlayCandidate]?
        var hopDone = false
    }

    init(store: WatchStore,
         identity: PlayIdentity,
         resumeMs: Int64,
         resolveLadder: @escaping (PlayIdentity) async -> [PlayCandidate],
         hopIdentity: ((PlayIdentity) async -> PlayIdentity?)?,
         fallbackCandidates: ((PlayIdentity) async -> [PlayCandidate])? = nil) {
        self.store = store
        self.identity = identity
        self.resumeMs = resumeMs
        self.resolveLadder = resolveLadder
        self.hopIdentity = hopIdentity
        self.fallbackCandidates = fallbackCandidates
    }

    deinit {
        // The Up Next countdown must never outlive its
        // session (its factory would swap a director into
        // a player that no longer exists).
        upNextTask?.cancel()
    }

    func start() {
        guard !started else { return }
        started = true
        armResolutionDeadline()
        resolutionTask = Task { await loadLadder() }
    }

    /// Arm (or re-arm) the 60 s Play deadline. When it fires
    /// with the phase still .resolving, the stored resolution
    /// task is cancelled and the session lands on the
    /// exhausted slate with a timeout note — a resolution
    /// chain that outlives its budget is a dead slate with a
    /// reason, never an endless spinner. Firing in any other
    /// phase is a no-op (playback started, or the slate is
    /// already up), and the torrent rung cancels the watchdog
    /// outright when it starts.
    private func armResolutionDeadline() {
        // Coordinator ruling (v2.0.8 close-out, protecting
        // the torrent-tab baseline): the deadline governs
        // the Phim play chain — the sessions that carry a
        // hop/fallback structure. A torrent-tab session has
        // neither closure and its resolveLadder IS the
        // debrid resolve, so no watchdog is armed for it
        // and its behaviour stays exactly the pre-v2.0.8
        // one (the debrid resolve is never cancelled).
        guard hopIdentity != nil || fallbackCandidates != nil else { return }
        deadlineTask?.cancel()
        deadlineTask = Task {
            try? await Task.sleep(
                nanoseconds: UInt64(Self.resolutionDeadline * 1_000_000_000))
            guard !Task.isCancelled, phase == .resolving else { return }
            resolutionTask?.cancel()
            lastFailure = "Quá 60 giây chưa tìm được nguồn phát"
            phase = .exhausted
        }
    }

    private func markLadderReadyIfFirst() {
        guard !ladderReadyMarked else { return }
        ladderReadyMarked = true
        PerfLog.mark("play.ladderReady")
    }

    private func loadLadder() async {
        phase = .resolving
        let ladder = await resolveLadder(identity)
        // A deadline-cancelled chain must not resurrect the
        // session over the exhausted slate the watchdog set.
        if Task.isCancelled { return }
        if ladder.isEmpty {
            await failoverStep()
            return
        }
        markLadderReadyIfFirst()
        candidates = ladder
        candidateIndex = 0
        beginCandidate()
    }

    private func beginCandidate() {
        guard candidates.indices.contains(candidateIndex) else {
            resolutionTask = Task { await failoverStep() }
            return
        }
        let c = candidates[candidateIndex]
        candidate = c
        currentLabel = c.label
        attemptID += 1
        // v2.0.15: every NEW candidate re-arms the resume seek
        // — itemReady applies it once per candidate, against
        // the session's furthest position (see itemReady).
        seekApplied = false
        phase = .playing
    }

    /// The current item failed (status .failed or failed-to-end).
    /// `cause` is the failing engine's own error description
    /// (or a watchdog label): it is remembered for the
    /// exhausted slate and logged with the candidate's engine
    /// and HOST ONLY — never the full URL (Torrentio URLs
    /// carry the owner's RD token in the path).
    func itemFailed(cause: String? = nil) {
        guard phase == .playing else { return }
        if let cause, !cause.isEmpty {
            lastFailure = String(cause.prefix(80))
        }
        let engineName = candidate?.engine == .ffmpeg ? "ffmpeg" : "avplayer"
        let host = candidate?.url.host ?? "?"
        PlaybackLog.logger.error(
            "candidate failed engine=\(engineName, privacy: .public) host=\(host, privacy: .public) cause=\(cause ?? "—", privacy: .public)")
        candidateIndex += 1
        if candidateIndex < candidates.count {
            beginCandidate()
        } else {
            resolutionTask = Task { await failoverStep() }
        }
    }

    /// Failover: hedged refresh+hop → substitution rung once →
    /// exhausted, all inside the one Play deadline (see the
    /// stored-task/deadline note at the properties).
    ///
    /// v2.0.8 (Phase 3) design — read before touching:
    /// • The first two rungs used to run strictly one after
    ///   the other (refresh the whole chain, THEN one
    ///   cross-provider hop), so a dead incumbent taxed the
    ///   tap twice in series. They are now a HEDGED PAIR: on
    ///   the first exhaustion, the refresh (resolveLadder for
    ///   the current identity) and the hop (hopIdentity →
    ///   resolveLadder under the new identity) run
    ///   CONCURRENTLY, and the first NON-EMPTY candidate list
    ///   wins — a refresh win leaves the identity unchanged, a
    ///   hop win adopts the new identity and shows the
    ///   existing "Đổi nguồn: …" notice; the loser is
    ///   cancelled. Neither branch touches session state
    ///   while racing (both publish into the HedgeBox); the
    ///   winner is committed here, once.
    /// • After the hedge resolves either way, BOTH `refreshed`
    ///   and `hopped` count as consumed — a later exhaustion
    ///   goes to the torrent rung, never back into the hedge.
    /// • Sessions with no hop (the torrent section builds its
    ///   director with hopIdentity nil) degrade to the classic
    ///   refresh-only rung, byte-identical to the pre-hedge
    ///   behaviour.
    /// • The torrent substitution rung is NEVER hedged and
    ///   keeps its exact position and behaviour; the deadline
    ///   watchdog stands down the moment it starts, so the
    ///   debrid resolve is never cancelled mid-flight.
    private func failoverStep() async {
        if Task.isCancelled { return }
        guard let hopIdentity else {
            // No hop exists for this session: refresh once,
            // then the substitution rung / exhausted, exactly
            // as before the hedge.
            if !refreshed {
                refreshed = true
                notice = "Đang tải lại nguồn…"
                await loadLadder()
                return
            }
            await torrentRungOrExhausted()
            return
        }
        if !refreshed || !hopped {
            let doRefresh = !refreshed
            let doHop = !hopped
            refreshed = true
            hopped = true
            phase = .resolving
            notice = "Đang tải lại nguồn…"
            let origin = identity
            let box = HedgeBox()
            var refreshTask: Task<Void, Never>?
            var hopTask: Task<Void, Never>?
            if doRefresh {
                refreshTask = Task {
                    let ladder = await resolveLadder(origin)
                    box.refreshLadder = ladder
                    box.refreshDone = true
                }
            } else {
                box.refreshLadder = []
                box.refreshDone = true
            }
            if doHop {
                hopTask = Task {
                    if let next = await hopIdentity(origin) {
                        let ladder = await resolveLadder(next)
                        box.hopIdentity = next
                        box.hopLadder = ladder
                    }
                    box.hopDone = true
                }
            } else {
                box.hopDone = true
            }
            // Poll for the first non-empty ladder (the house
            // race pattern — cf. the KK host race and the
            // alternatives search box). Refresh is checked
            // first within a tick: on a simultaneous landing
            // the incumbent wins and the identity stays put.
            var winner: (identity: PlayIdentity,
                         ladder: [PlayCandidate], isHop: Bool)?
            while winner == nil {
                if let ladder = box.refreshLadder, !ladder.isEmpty {
                    winner = (origin, ladder, false)
                    break
                }
                if let ladder = box.hopLadder, !ladder.isEmpty,
                   let next = box.hopIdentity {
                    winner = (next, ladder, true)
                    break
                }
                if box.refreshDone && box.hopDone { break }
                if Task.isCancelled {
                    refreshTask?.cancel()
                    hopTask?.cancel()
                    return
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            refreshTask?.cancel()
            hopTask?.cancel()
            if Task.isCancelled { return }
            if let winner {
                if winner.isHop {
                    identity = winner.identity
                    notice = "Đổi nguồn: \(Providers.displayName(winner.identity.entry.source))"
                }
                markLadderReadyIfFirst()
                candidates = winner.ladder
                candidateIndex = 0
                beginCandidate()
                return
            }
            // Both branches produced nothing: fall through to
            // the torrent rung, as the serial ladder did after
            // its hop came back empty.
        }
        await torrentRungOrExhausted()
    }

    /// The substitution rung (owner law, v1.9) and the
    /// exhausted end state, shared by the hedged path and the
    /// no-hop path. Reached from every exhaustion path (an
    /// empty ladder, a failed item, the stall watchdog
    /// advancing past the last candidate). The rung's own
    /// behaviour is byte-identical to the pre-v2.0.8 inline
    /// version; the one addition is the deadline stand-down
    /// at its head.
    private func torrentRungOrExhausted() async {
        if !fallbackTried, let fallbackCandidates {
            fallbackTried = true
            // The deadline watchdog stands down NOW: the
            // debrid resolve inside the rung is never
            // cancelled mid-flight, hedged, or retried.
            deadlineTask?.cancel()
            notice = "Đang tìm nguồn thay thế…"
            let extra = await fallbackCandidates(identity)
            if !extra.isEmpty {
                notice = "Nguồn thay thế: Torrent"
                candidates = extra
                candidateIndex = 0
                beginCandidate()
                return
            }
        }
        phase = .exhausted
    }

    /// Manual retry from the exhausted slate (§8): reset the
    /// failover bookkeeping and run the whole ladder again —
    /// sources that were down may have recovered, and the owner
    /// must never be stranded on a dead slate with only Menu.
    /// v2.0.8: the retry also re-arms the Play deadline and
    /// re-stores the resolution task, like start().
    func retryFromExhausted() {
        guard phase == .exhausted else { return }
        refreshed = false
        hopped = false
        fallbackTried = false
        seekApplied = false
        lastFailure = nil
        notice = "Đang thử lại…"
        armResolutionDeadline()
        resolutionTask = Task { await loadLadder() }
    }

    /// Item is ready: apply the resume seek once per candidate
    /// (the view's
    /// coordinator performs it and reports back the position it
    /// landed on — here we just record that it happened and show
    /// the Android toast text).
    func itemReady(player: AVPlayer) {
        let durSec = player.currentItem?.duration.seconds ?? 0
        let durMs = durSec.isFinite ? Int64(durSec * 1000) : 0
        itemReady(durationMs: durMs) { ms in
            player.seek(to: CMTime(milliseconds: ms),
                        toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    /// The same resume rule for the FFmpeg engine (v2.0.3): the
    /// KSPlayer coordinator supplies the duration it measured
    /// and performs the seek itself. One rule, two engines —
    /// the >20 s / last-30 s window is identical.
    func itemReady(durationMs: Int64, seek: (Int64) -> Void) {
        // Phase 3 mark: the session's first ready item, once
        // per session, from this shared core so both engines
        // (AVPlayer above, KSPlayer via durationMs) report it.
        if !firstFrameMarked {
            firstFrameMarked = true
            PerfLog.mark("play.firstFrame")
        }
        // Up Next (v2.0.25): the playing-started hook fires
        // from this same shared core, exactly once per
        // session, on the first ready — both engines funnel
        // through here (itemReady(player:) delegates to this
        // method), so neither engine can fire it twice or
        // skip it.
        if !playingStartedNotified {
            playingStartedNotified = true
            onPlayingStarted?()
        }
        guard !seekApplied else { return }
        seekApplied = true
        // The Android rule, checked with the real duration in
        // hand: seek only when the stored position is past 20 s
        // AND outside the last 30 s (a finished title restarts).
        // v2.0.15 (Sony 2.3.17 port): the target is the
        // FURTHEST position this session has reached — the
        // stored resume point for the first candidate, the
        // live playhead (lastPosMs, kept current by tick())
        // once playback has moved past it. Pre-fix the target
        // was the fixed session-start resumeMs and the seek
        // was never re-armed for a new candidate, so a mid-play
        // failure advanced the ladder into a restart at 0:00 —
        // the exact fault behind the owner's Sony verdict
        // ("kéo luôn 1 phát đứt luôn", the film restarts).
        let targetMs = max(resumeMs, lastPosMs)
        if targetMs > 20_000 && (durationMs <= 0 || targetMs < durationMs - 30_000) {
            seek(targetMs)
            notice = "Tiếp tục từ \(WatchStore.fmtClock(targetMs))"
        }
    }

    /// Periodic tick from the player (~every 5 s): the Android
    /// save rule — under 10 s records nothing; inside the last
    /// 30 s the entry is dropped (finished); otherwise save.
    func tick(positionMs: Int64, durationMs: Int64) {
        lastPosMs = positionMs
        lastDurMs = durationMs
        // FIX4 (fix 6): the Up Next trigger moves from the
        // END of the item to its last 10 seconds (owner
        // finding on 2.0.27: the card appeared only once the
        // episode had already ended). tick() runs ≈ every
        // 5 s on both engines, so the first tick inside the
        // window opens the card with the countdown started
        // at the seconds ACTUALLY remaining (rounded up, so
        // the factory fires at — never before — the item's
        // end). Runs before the save rule below on purpose:
        // the last-30 s branch returns early.
        if nextEpisodeFactory != nil, !upNextArmed, durationMs > 0 {
            let remainingMs = durationMs - positionMs
            if remainingMs > 0, remainingMs <= 10_000 {
                upNextArmed = true
                startUpNextCountdown(
                    initialSeconds: Int((remainingMs + 999) / 1000))
            }
        }
        guard durationMs > 0, positionMs > 10_000 else { return }
        if positionMs >= durationMs - 30_000 {
            store.removeProgress(matching: identity.entry)
            return
        }
        var e = identity.entry
        e.pos = positionMs
        e.dur = durationMs
        e.ts = Int64(Date().timeIntervalSince1970 * 1000)
        store.saveProgress(e)
    }

    /// Playback reached the end cleanly: the title is finished —
    /// drop the progress entry (the Android STATE_ENDED rule).
    /// Up Next (v2.0.25): when the session carries a next-
    /// episode factory, the clean end ALSO starts the
    /// 10-second countdown; errors never reach here (they
    /// go through itemFailed), so the countdown only ever
    /// follows a genuine finish. With no factory set this
    /// is byte-for-byte the pre-Up-Next behaviour.
    func itemEnded() {
        store.removeProgress(matching: identity.entry)
        guard nextEpisodeFactory != nil else { return }
        // FIX4 (fix 6): fallback only — when the tick
        // trigger already armed the card, a countdown still
        // running (or one the user cancelled inside the
        // window) is left exactly as it stands.
        guard !upNextArmed else { return }
        upNextArmed = true
        startUpNextCountdown()
    }

    /// Start (or restart) the 10-second Up Next countdown:
    /// publishes 10 immediately, then one tick per second
    /// down to 1; at zero the factory runs (see
    /// runAdvanceFactory). Cancellable at every tick via
    /// cancelAdvance() / advanceNow() / deinit.
    private func startUpNextCountdown() {
        startUpNextCountdown(initialSeconds: 10)
    }

    /// FIX4 (fix 6): the countdown's starting value as a
    /// parameter — the tick trigger fires inside the
    /// last-10 s window, not at its edge, so the card opens
    /// showing the seconds actually left.
    private func startUpNextCountdown(initialSeconds: Int) {
        upNextGeneration += 1
        let generation = upNextGeneration
        upNextTask?.cancel()
        let start = max(1, min(10, initialSeconds))
        upNextSecondsLeft = start
        upNextTask = Task { [weak self] in
            guard let self else { return }
            var remaining = start
            while remaining > 0 {
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    return
                }
                if Task.isCancelled { return }
                guard generation == self.upNextGeneration else { return }
                remaining -= 1
                if remaining > 0 {
                    self.upNextSecondsLeft = remaining
                } else {
                    self.upNextSecondsLeft = nil
                    await self.runAdvanceFactory(generation: generation)
                    return
                }
            }
        }
    }

    /// Run the next-episode factory for `generation` and
    /// publish its director as advanceTarget. A nil result
    /// (or a generation superseded while the factory was
    /// in flight — a cancel, a manual advance) simply
    /// clears the countdown and publishes nothing, so a
    /// cancelled countdown can never fire late.
    private func runAdvanceFactory(generation: Int) async {
        guard generation == upNextGeneration,
              let factory = nextEpisodeFactory else { return }
        let next = await factory()
        guard generation == upNextGeneration, !Task.isCancelled else { return }
        upNextSecondsLeft = nil
        if let next {
            advanceTarget = next
        }
    }

    /// "Phát ngay": skip the rest of the countdown and run
    /// the factory immediately. A no-op when no countdown
    /// is active.
    func advanceNow() {
        guard upNextSecondsLeft != nil, nextEpisodeFactory != nil else { return }
        upNextGeneration += 1
        let generation = upNextGeneration
        upNextTask?.cancel()
        upNextSecondsLeft = nil
        upNextTask = Task { [weak self] in
            guard let self else { return }
            await self.runAdvanceFactory(generation: generation)
        }
    }

    /// Cancel the countdown: the finished item simply stays
    /// ended (the view's normal end behaviour resumes —
    /// Menu dismisses again once no countdown is active).
    /// Deliberately does NOT clear advanceTarget: a cancel
    /// that lands after the factory already published its
    /// director must not undo the handover.
    func cancelAdvance() {
        upNextGeneration += 1
        upNextTask?.cancel()
        upNextTask = nil
        upNextSecondsLeft = nil
    }

    // MARK: Player chrome actions (v2.0.27, Idea 13)
    //
    // The AVPlayer path's transport-bar menu (PlayerController
    // below) drives these three; the KSPlayer path has its own
    // settled chrome and never calls them. Each one reuses the
    // standing machinery — no forked ladder, no forked advance.

    /// "Đổi nguồn": a USER-initiated source switch while
    /// playing. Advances the ladder exactly like itemFailed
    /// (next candidate in the ladder, else the failover step
    /// with its refresh → hop → substitution rungs), but it
    /// is not a failure: lastFailure is left untouched and
    /// the log records a switch, not an error. When no rung
    /// remains the failover machinery lands on the exhausted
    /// slate, which is the correct end state. A no-op
    /// outside .playing.
    func userSwitchSource() {
        guard phase == .playing else { return }
        let host = candidate?.url.host ?? "?"
        PlaybackLog.logger.info(
            "user switch source host=\(host, privacy: .public)")
        candidateIndex += 1
        if candidateIndex < candidates.count {
            beginCandidate()
        } else {
            resolutionTask = Task { await failoverStep() }
        }
    }

    /// One row of the source chooser (v2.0.29, item 3): the
    /// session's CURRENT candidate ladder as the player
    /// chrome presents it — the index into the ladder, the
    /// candidate's own label (the text the status capsule
    /// shows for it), and whether it is the candidate on
    /// screen. An unlabelled candidate falls back to a
    /// numbered name, so a chooser row is never blank.
    struct SourceChoice {
        let index: Int
        let label: String
        let isCurrent: Bool
    }

    /// The chooser's rows, rebuilt from the live ladder on
    /// every read — a failover hop replaces the ladder, and
    /// the next menu/picker opening must show the NEW list
    /// with the NEW current candidate marked.
    var sourceChoices: [SourceChoice] {
        candidates.enumerated().map { pair in
            SourceChoice(
                index: pair.offset,
                label: pair.element.label.isEmpty
                    ? "Nguồn \(pair.offset + 1)" : pair.element.label,
                isCurrent: pair.offset == candidateIndex)
        }
    }

    /// "Đổi nguồn" to a CHOSEN candidate (v2.0.29, item 3):
    /// the owner picks from sourceChoices in the player
    /// chrome (the KS host's source picker; the AVPlayer
    /// transport-bar submenu) instead of the button blindly
    /// advancing to the next candidate — manual source
    /// selection is his standing rule. The switch itself is
    /// beginCandidate(), the same re-arm the failover ladder
    /// uses, so the standing itemReady resume rule carries
    /// the live position (lastPosMs, kept current by tick())
    /// onto the chosen candidate exactly as it does for
    /// userSwitchSource() and itemFailed. Picking the
    /// current candidate, an out-of-ladder index, or
    /// picking outside .playing is a no-op. Auto failover
    /// (itemFailed and its rungs) is untouched.
    func userSwitchSource(to index: Int) {
        guard phase == .playing,
              candidates.indices.contains(index),
              index != candidateIndex else { return }
        let host = candidates[index].url.host ?? "?"
        PlaybackLog.logger.info(
            "user switch source (chosen) host=\(host, privacy: .public)")
        candidateIndex = index
        beginCandidate()
    }

    /// "Yêu thích": toggle this title's favourite in
    /// WatchStore. NOTE the key: identity.entry.key is the
    /// PROGRESS key ("kk|<slug>|<episode name>"), while
    /// favourites live under their own key (the detail
    /// screens' favKey — WatchStore.movieFavKey /
    /// torFavKey), so the entry handed to the store is a
    /// copy of the session entry re-keyed to the favourite
    /// key, exactly as the detail screens build theirs;
    /// toggling the progress-keyed entry verbatim would
    /// strand the favourite where no other screen ever
    /// looks for it.
    func toggleFavourite() {
        var fav = identity.entry
        fav.key = favouriteKey
        fav.ts = Int64(Date().timeIntervalSince1970 * 1000)
        store.toggleFavorite(fav)
    }

    /// "Tập tiếp theo": skip straight to the next episode,
    /// from mid-play or from the countdown alike. The
    /// current item's bookkeeping ends exactly like
    /// itemEnded's (progress removed — the episode counts
    /// as finished for Continue Watching), any active
    /// countdown is cancelled through the standing cancel
    /// path, and the advance itself runs through the same
    /// runAdvanceFactory the countdown and "Phát ngay" use.
    /// Sessions without a next episode do nothing.
    func skipToNextEpisode() {
        guard nextEpisodeFactory != nil else { return }
        store.removeProgress(matching: identity.entry)
        cancelAdvance()
        upNextGeneration += 1
        let generation = upNextGeneration
        upNextTask = Task { [weak self] in
            guard let self else { return }
            await self.runAdvanceFactory(generation: generation)
        }
    }

    /// The favourite key for this session's title — the
    /// detail screens' derivation, shared by toggleFavourite
    /// and isFavourite so the two can never disagree.
    private var favouriteKey: String {
        let e = identity.entry
        if e.kind == WatchStore.kindTor {
            return WatchStore.torFavKey(metaId: e.metaId, type: e.metaType)
        }
        return WatchStore.movieFavKey(provider: e.source, slug: e.slug)
    }

    /// Read by the player chrome (the menu's favourite
    /// label) — the director owns the store, so the check
    /// lives here.
    var isFavourite: Bool { store.isFavorite(key: favouriteKey) }

    /// Whether the transport menu offers "Tập tiếp theo".
    var hasNextEpisode: Bool { nextEpisodeFactory != nil }

    /// The session's identity entry, read by the player
    /// chrome for the item metadata + info tab (title,
    /// episode label, poster). Read-only: identity itself
    /// stays private and changes only through the failover
    /// hop, exactly as before.
    var sessionEntry: WatchStore.Entry { identity.entry }

    /// Leaving the player: one last save under the same rule.
    func flush() {
        tick(positionMs: lastPosMs, durationMs: lastDurMs)
    }
}

/// Handover box for Up Next (v2.0.25): holds the session's
/// CURRENT director and swaps it when that director
/// publishes an advanceTarget. The swap is deferred to the
/// next main-runloop tick — @Published fires in willSet, so
/// publishing the box's own director inside the sink would
/// nest one publish inside another. After the swap the box
/// re-subscribes to the NEW director, so a chain of
/// episodes (each factory-built director carrying its own
/// factory) advances repeatedly through the same box.
@MainActor
private final class JoeDirectorBox: ObservableObject {
    @Published private(set) var director: PlayDirector
    private var advanceSubscription: AnyCancellable?

    init(director: PlayDirector) {
        self.director = director
        observe(director)
    }

    private func observe(_ director: PlayDirector) {
        advanceSubscription = director.$advanceTarget
            .sink { [weak self] target in
                guard let target else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.director !== target,
                          self.director.advanceTarget === target else { return }
                    self.director = target
                    self.observe(target)
                }
            }
    }
}

/// Full-screen player shell: AVPlayerViewController + a status
/// capsule (candidate label / failover notices), driven by
/// PlayDirector. Menu exits, like the house player.
///
/// v2.0.25 (Up Next handover): JoePlayerView itself is now a
/// thin identity shell over JoePlayerSessionView. The
/// session view is keyed by the current director's identity
/// (ObjectIdentifier), so when the box swaps in the next
/// episode's director the old session view is torn down and
/// a fresh one appears for the new director — whose start()
/// therefore fires through the exact same .onAppear path as
/// the first episode's did. The public init is unchanged.
struct JoePlayerView: View {
    @StateObject private var box: JoeDirectorBox

    /// v2.0.0 (UI-5): design F's exhausted slate lists the tried
    /// source families as rows (the render's shape). The Phim
    /// detail passes the four provider names; torrent sessions
    /// pass nil and F falls back to the plain slate.
    private let attemptRows: [String]?

    /// UI-6 defect D-18: the slate's kicker carries the film
    /// title + episode (the renders' slate heading), and the
    /// source line names the active source mode (owner
    /// source-priority policy: Tự động / ưu tiên Torrent / the
    /// pinned source). Both default empty — torrent sessions
    /// pass their own values.
    private let filmTitle: String
    private let filmEpisode: String
    private let sourceLine: String

    init(director: PlayDirector, attemptRows: [String]? = nil,
         filmTitle: String = "", filmEpisode: String = "",
         sourceLine: String = "") {
        _box = StateObject(wrappedValue: JoeDirectorBox(director: director))
        self.attemptRows = attemptRows
        self.filmTitle = filmTitle
        self.filmEpisode = filmEpisode
        self.sourceLine = sourceLine
    }

    var body: some View {
        JoePlayerSessionView(director: box.director,
                             attemptRows: attemptRows,
                             filmTitle: filmTitle,
                             filmEpisode: filmEpisode,
                             sourceLine: sourceLine)
            .id(ObjectIdentifier(box.director))
    }
}

/// One episode's player session (the pre-v2.0.25 JoePlayerView
/// body, verbatim in behaviour): the engine dispatch, the
/// status capsule, the exhausted slate, plus the Up Next
/// countdown card overlay. A fresh instance is created per
/// director by the identity shell above.
private struct JoePlayerSessionView: View {
    @ObservedObject var director: PlayDirector
    @Environment(\.dismiss) private var dismiss
    @Environment(\.joeTheme) private var theme
    @FocusState private var slateFocus: SlateButton?

    private enum SlateButton: Hashable { case retry, back, playNext }

    private let attemptRows: [String]?
    private let filmTitle: String
    private let filmEpisode: String
    private let sourceLine: String

    init(director: PlayDirector, attemptRows: [String]? = nil,
         filmTitle: String = "", filmEpisode: String = "",
         sourceLine: String = "") {
        self.director = director
        self.attemptRows = attemptRows
        self.filmTitle = filmTitle
        self.filmEpisode = filmEpisode
        self.sourceLine = sourceLine
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch director.phase {
            case .resolving:
                // §7.10 loading slate: black, white spinner, the
                // label bottom-left (TV360 language).
                VStack {
                    Spacer()
                    HStack(spacing: 14) {
                        ProgressView()
                            .tint(.white)
                        Text("Đang tải…")
                            .font(.system(size: 29))
                            .foregroundStyle(.white)
                        Spacer()
                    }
                    .padding(.leading, 48)
                    .padding(.bottom, 36)
                }
                .ignoresSafeArea()
            case .playing:
                if let candidate = director.candidate {
                    // Engine dispatch is a value on the candidate
                    // (torrent candidates carry .ffmpeg — see
                    // PlayCandidate); the shell, the capsule and
                    // the director contract are shared.
                    if candidate.engine == .ffmpeg {
                        JoeKSPlayerController(candidate: candidate,
                                              director: director)
                            .id(director.attemptID)
                            .ignoresSafeArea()
                    } else {
                        PlayerController(candidate: candidate,
                                         director: director)
                            .id(director.attemptID)
                            .ignoresSafeArea()
                    }
                }
                // v2.0.29 (item 2): the capsule — the source
                // label, the resume line, every failover
                // notice — is bound to the SAME visibility
                // state as the live host's transport bar,
                // reported into the director by the host
                // itself (KS: its show/hide path; AVPlayer:
                // the fix-9 delegate callback). Bar hidden →
                // capsule hidden; bar summoned → capsule back.
                // No separate timer exists for it any more:
                // pre-fix it was rendered unconditionally in
                // .playing, and since `notice` is never
                // cleared, the "Tiếp tục từ …" line in
                // particular stayed on screen for the whole
                // film after the bar had gone.
                statusCapsule
                    .opacity(director.transportBarVisible ? 1 : 0)
            case .exhausted:
                // §8 error slate: message + cause + reachable
                // buttons, focus on the first button. (v1.8's
                // slate was text-only — the only way out was
                // Menu, which read as part of the freeze.)
                // 1.9.2 (Team 9 item 1a): the text column is
                // CAPPED (≈1150) and the padding sits INSIDE the
                // flexible frame.
                // v2.0.0 (UI-5): the slate's placement follows
                // the active design — A a left column, D centred,
                // F bottom-left with the tried sources as rows.
                // v2.0.5 (error 8b): the slate's focus landing
                // is a standing .defaultFocus DECLARATION on the
                // slate container (one attachment covers all
                // three anatomies) — the focus engine consults
                // it at every focus update, including the one
                // the engine representable's teardown triggers.
                // The pre-fix construction was a one-shot
                // @FocusState write in .onChange racing that
                // teardown, with no declared landing to fall
                // back on: focus landed nowhere and the slate's
                // buttons were unreachable (Menu-only trap).
                exhaustedSlate
                    .defaultFocus($slateFocus, .retry)
            }
            // Up Next countdown card (v2.0.25): overlays the
            // finished item's last frame while the director
            // counts down. The card's focus landing is a
            // standing .defaultFocus declaration, the slate's
            // own construction (see the error-8b note above).
            if director.upNextSecondsLeft != nil {
                upNextCard
                    .defaultFocus($slateFocus, .playNext)
            }
        }
        .onAppear { director.start() }
        .onDisappear {
            director.flush()
            // Teardown: a countdown must not outlive its
            // session view. cancelAdvance() deliberately
            // leaves advanceTarget untouched, so the
            // handover teardown (this view disappearing
            // BECAUSE the box swapped directors) is safe.
            director.cancelAdvance()
        }
        .onExitCommand {
            // Menu during an active countdown cancels the
            // advance instead of leaving the player; with
            // no countdown active Menu exits as always.
            // v2.0.31 (L5): a picker open in the KS host owns
            // the FIRST Menu press — it closes, and focus /
            // playback state are restored by the host; the
            // countdown rule and the plain exit keep their
            // order behind it.
            if director.pickerOpen {
                director.requestPickerClose()
            } else if director.upNextSecondsLeft != nil {
                director.cancelAdvance()
            } else {
                dismiss()
            }
        }
    }

    /// The Up Next countdown card: next episode title, the
    /// remaining seconds, a focusable "Phát ngay" button and
    /// the Menu-cancels hint. Theme tokens and the file's
    /// existing button construction (slateButton →
    /// JoePrimaryLabel / .joeCardButton(), the custom style)
    /// only — no .card platter, no hand-drawn focus rings.
    private var upNextCard: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                VStack(alignment: .leading, spacing: 14) {
                    Text("TẬP TIẾP THEO")
                        .font(.system(size: 22, weight: .bold))
                        .tracking(4)
                        .foregroundStyle(theme.focusTitle)
                    if !director.nextEpisodeTitle.isEmpty {
                        Text(director.nextEpisodeTitle)
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(theme.text)
                            .lineLimit(2)
                    }
                    if let seconds = director.upNextSecondsLeft {
                        Text("Tập tiếp theo sau \(seconds)s")
                            .font(.system(size: 25))
                            .foregroundStyle(theme.meta)
                    }
                    HStack(spacing: 18) {
                        slateButton("Phát ngay", tag: .playNext, primary: true) {
                            director.advanceNow()
                        }
                    }
                    .padding(.top, 8)
                    Text("Nhấn Menu để hủy")
                        .font(.system(size: 22))
                        .foregroundStyle(theme.meta)
                }
                .padding(.horizontal, 30)
                .padding(.vertical, 24)
                .frame(maxWidth: 560, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: theme.rField)
                    .fill(theme.surfaceGradient))
                .overlay(RoundedRectangle(cornerRadius: theme.rField)
                    .strokeBorder(theme.stroke, lineWidth: 1.5))
            }
            .padding(.trailing, 48)
            .padding(.bottom, 36)
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var exhaustedSlate: some View {
        switch theme.id {
        case .posterWall:
            VStack(alignment: .center, spacing: 18) {
                slateTexts(centred: true)
                // Design-D player slate: button row gap 18,
                // margin-top 40 above the row (the column's 18
                // spacing + this 22 padding — the A branch's
                // construction, whose drawing agrees).
                HStack(spacing: 18) {
                    slateButton("Thử lại", tag: .retry, primary: true) {
                        director.retryFromExhausted()
                    }
                    slateButton("Quay lại", tag: .back, primary: false) {
                        dismiss()
                    }
                }
                .padding(.top, 22)
            }
            .frame(maxWidth: 1150)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        case .billboard, .ultra:
            VStack(alignment: .leading, spacing: 18) {
                slateTexts(centred: false)
                // Design-A player slate: button row gap 18,
                // margin-top 40 above the row (the column's 18
                // spacing + this 22 padding).
                HStack(spacing: 18) {
                    slateButton("Thử lại", tag: .retry, primary: true) {
                        director.retryFromExhausted()
                    }
                    slateButton("Quay lại", tag: .back, primary: false) {
                        dismiss()
                    }
                }
                .padding(.top, 22)
            }
            .frame(maxWidth: 1150, alignment: .leading)
            .padding(.leading, 48)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        case .sourceBoard:
            VStack(alignment: .leading, spacing: 18) {
                slateTexts(centred: false)
                if let attemptRows {
                    // Design-F player: the attempt rows are
                    // the drawing's .srcrow at full slate-column
                    // width — name 30 bold, the failed state 25
                    // semibold in the bad colour, padding 22/30,
                    // radius 18 (theme.rField under F), the
                    // surface gradient with the resting inset
                    // stroke 1.5, rows at margin-bottom 16; the
                    // block's margin-top is 28 (the column's 18
                    // + this 10 padding).
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(attemptRows, id: \.self) { name in
                            HStack(spacing: 22) {
                                Text(name)
                                    .font(.system(size: 30, weight: .bold))
                                    .foregroundStyle(theme.text)
                                Spacer()
                                Text("✗ Không phát được")
                                    .font(.system(size: 25, weight: .semibold))
                                    .foregroundStyle(JoeTheme.accentRed)
                            }
                            .padding(.horizontal, 30)
                            .padding(.vertical, 22)
                            .background(RoundedRectangle(cornerRadius: theme.rField)
                                .fill(theme.surfaceGradient))
                            .overlay(RoundedRectangle(cornerRadius: theme.rField)
                                .strokeBorder(theme.stroke, lineWidth: 1.5))
                        }
                    }
                    .padding(.top, 10)
                }
                // Design-F player: button row gap 18,
                // margin-top 30 (the column's 18 + this 12).
                HStack(spacing: 18) {
                    slateButton("Thử lại", tag: .retry, primary: true) {
                        director.retryFromExhausted()
                    }
                    slateButton("Quay lại", tag: .back, primary: false) {
                        dismiss()
                    }
                }
                .padding(.top, 12)
            }
            .frame(maxWidth: 1150, alignment: .leading)
            .padding(.leading, 48)
            .padding(.bottom, 36)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
    }

    /// The slate's text block (UI-6 defect D-18 — the renders'
    /// slate composition): the kicker (film title — episode,
    /// focusTitle colour, tracked uppercase), the 52 pt heavy
    /// headline, the explanation, the tried-sources line
    /// (designs A/D; F renders the same data as rows below),
    /// and the active source-mode line.
    private func slateTexts(centred: Bool) -> some View {
        // Design .slate text rhythm (shared stylesheet, all
        // three drawings): headline margin-top 12 below the
        // kicker, message 16 below the headline in FULL white,
        // tried line 18 below the message in the theme's meta
        // colour. One spacing-0 column with per-line top
        // paddings, so an absent line collapses with its
        // margin, like CSS. The "Lỗi cuối" and source-mode
        // lines are app-only (v2.0.5 error 8a) and keep their
        // dimmed white at the same 18 rhythm.
        VStack(alignment: centred ? .center : .leading, spacing: 0) {
            if !filmTitle.isEmpty {
                Text(filmEpisode.isEmpty ? filmTitle : "\(filmTitle) — \(filmEpisode)")
                    .font(.system(size: 22, weight: .bold))
                    .tracking(4)
                    .textCase(.uppercase)
                    .foregroundStyle(theme.focusTitle)
                    .multilineTextAlignment(centred ? .center : .leading)
            }
            // Headline/message sizes follow each drawing's own
            // slate classes: A and F inline the slate sizes
            // (52 headline, 29 message, full white); design-D's
            // player drawing reuses its hero classes instead —
            // .hero-title at D's 56px override and .hero-syn
            // at 27px, white at the base rule's .92 opacity.
            Text("Không phát được nguồn này")
                .font(.system(size: theme.id == .posterWall ? 56 : 52, weight: .heavy))
                .foregroundStyle(.white)
                .multilineTextAlignment(centred ? .center : .leading)
                .padding(.top, filmTitle.isEmpty ? 0 : 12)
            Text("Đã thử lấy link mới và đổi nguồn nhưng vẫn không phát được.")
                .font(.system(size: theme.id == .posterWall ? 27 : 29))
                .foregroundStyle(theme.id == .posterWall ? .white.opacity(0.92) : .white)
                .multilineTextAlignment(centred ? .center : .leading)
                .padding(.top, 16)
            if let lastFailure = director.lastFailure {
                // v2.0.5 (error 8a): the last failure's own cause,
                // remembered by the director — a dead slate used
                // to say nothing about why every attempt died.
                Text("Lỗi cuối: \(lastFailure)")
                    .font(.system(size: 25))
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(centred ? .center : .leading)
                    .padding(.top, 18)
            }
            if theme.id != .sourceBoard, let attemptRows, !attemptRows.isEmpty {
                Text("Đã thử: " + attemptRows.joined(separator: " · "))
                    .font(.system(size: 25))
                    .foregroundStyle(theme.meta)
                    .multilineTextAlignment(centred ? .center : .leading)
                    .padding(.top, 18)
            }
            if !sourceLine.isEmpty {
                Text(sourceLine)
                    .font(.system(size: 25))
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(centred ? .center : .leading)
                    .padding(.top, 18)
            }
        }
    }

    private func slateButton(_ title: String, tag: SlateButton, primary: Bool,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if primary {
                JoePrimaryLabel(title: title)
            } else {
                JoeSecondaryLabel(title: title)
            }
        }
        .joeCardButton()
        .focused($slateFocus, equals: tag)
    }

    private var statusCapsule: some View {
        VStack {
            Spacer()
            HStack {
                if let notice = director.notice {
                    Text(notice)
                        .font(.system(size: 25))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.black.opacity(0.6)))
                } else if !director.currentLabel.isEmpty {
                    Text(director.currentLabel)
                        .font(.system(size: 25))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.black.opacity(0.45)))
                }
                Spacer()
            }
            .padding(.leading, 48)
            .padding(.bottom, 36)
        }
        .ignoresSafeArea()
    }
}

/// Info-tab page for the AVPlayer chrome (v2.0.27, Idea 13):
/// the system player's info panel hosts this controller
/// (AVPlayerViewController.customInfoViewControllers) — the
/// film title, the episode label and the current source line
/// as plain labels on a dark ground matching the player. The
/// PlayerController Coordinator owns the one instance and
/// re-points its labels at every new item.
private final class JoePlayerInfoViewController: UIViewController {
    private let titleLabel = UILabel()
    private let episodeLabel = UILabel()
    private let sourceLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0.08, alpha: 1)
        titleLabel.font = .systemFont(ofSize: 38, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 2
        episodeLabel.font = .systemFont(ofSize: 29)
        episodeLabel.textColor = UIColor.white.withAlphaComponent(0.85)
        episodeLabel.numberOfLines = 1
        sourceLabel.font = .systemFont(ofSize: 29)
        sourceLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        sourceLabel.numberOfLines = 2
        let stack = UIStackView(arrangedSubviews: [titleLabel, episodeLabel, sourceLabel])
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 48),
            stack.trailingAnchor.constraint(
                lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -48),
            stack.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 48),
        ])
    }

    /// Point the labels at a (new) item: the film title, its
    /// episode label (hidden for single-episode titles) and
    /// the live source line. Safe to call before the view has
    /// loaded — the first item is observed before the info
    /// panel is ever opened.
    func update(title: String, episode: String, source: String) {
        loadViewIfNeeded()
        titleLabel.text = title
        episodeLabel.text = episode
        episodeLabel.isHidden = episode.isEmpty
        sourceLabel.text = source
        sourceLabel.isHidden = source.isEmpty
    }
}

private struct PlayerController: UIViewControllerRepresentable {
    let candidate: PlayCandidate
    let director: PlayDirector

    func makeCoordinator() -> Coordinator {
        Coordinator(director: director)
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        // v2.0.24: adopt the dwell-warmed player when this
        // candidate is the one the detail screen warmed
        // (StreamWarmer) — its item has been loading since
        // the dwell, so playback starts from warm playlists
        // and buffered initial segments instead of a cold
        // build. Any other candidate takes the cold build
        // below, byte-identical to before.
        let player: AVPlayer
        let item: AVPlayerItem
        if let warm = StreamWarmer.shared.take(url: candidate.url,
                                               headers: candidate.headers),
           let warmItem = warm.currentItem {
            player = warm
            item = warmItem
        } else {
            item = AVPlayerItem(asset: candidate.makeAsset())
            player = AVPlayer(playerItem: item)
        }
        controller.player = player
        context.coordinator.attach(controller)
        context.coordinator.observe(item, player: player)
        player.play()
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.invalidate()
        controller.player?.pause()
        controller.player = nil
    }

    /// Watches the item: ready → resume seek via the director;
    /// failed → director's failover; periodic ticks → progress
    /// saves; end → finished rule. Each event fires at most the
    /// transitions the director allows, so stale items from a
    /// previous attempt can never double-drive the machine (the
    /// view recreates the controller per attempt via .id()).
    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        private let director: PlayDirector
        private var statusToken: NSKeyValueObservation?
        private var failToken: NSObjectProtocol?
        private var endToken: NSObjectProtocol?
        private var timeToken: Any?
        private weak var player: AVPlayer?
        /// Idea 13 chrome (v2.0.27): the hosting controller
        /// (the transport menu + info tab are set on it), the
        /// one info-tab controller whose labels follow the
        /// item, and the in-flight poster fetch behind the
        /// artwork metadata.
        private weak var viewController: AVPlayerViewController?
        private let infoController = JoePlayerInfoViewController()
        private var artworkTask: Task<Void, Never>?
        private var failed = false
        /// U-1 stall watchdog: fires itemFailed() if the item
        /// has neither readied nor failed 20 s after observe().
        private var watchdog: DispatchWorkItem?
        /// Mid-play freeze watchdog (latency round, audit
        /// §3.2/§6): the U-1 watchdog is cancelled the moment
        /// the item readies, and before this round NOTHING
        /// bounded a silent mid-play stall on tvOS — a stream
        /// could freeze forever without AVPlayer ever raising
        /// an error. This 1 s ticker watches the playhead
        /// after readyToPlay: 12 s without advance while the
        /// player is meant to be playing routes through
        /// fireFail(), the same failure path as an error, so
        /// the director's ladder advances (refresh → hop →
        /// torrent rung → exhausted). 12 s = two missed
        /// segments at the 6 s cadence of VS/TP/CV (audit §6);
        /// the value is CONSTANT this round — SourceHealth
        /// does not move it.
        private var freezeTimer: Timer?
        private var freezeReady = false
        private var freezeEnded = false
        private var lastPositionSec = -1.0
        private var lastAdvanceAt = Date()

        init(director: PlayDirector) {
            self.director = director
            super.init()
        }

        /// Idea 13 (v2.0.27): adopt the hosting controller —
        /// the info tab is installed here, once per session
        /// view; the transport menu and the item metadata are
        /// (re)built per item in refreshChrome, from
        /// observe().
        func attach(_ controller: AVPlayerViewController) {
            viewController = controller
            infoController.title = "Thông tin"
            controller.customInfoViewControllers = [infoController]
            // FIX4 (fix 9): this coordinator is the player
            // controller's delegate so the Title View can be
            // bound to the transport bar's visibility (the
            // delegate callback below). The Title View starts
            // INCLUDED — it belongs with the bar.
            controller.delegate = self
            controller.transportBarIncludesTitleView = true
            // v2.0.29 (item 2): a freshly attached
            // controller's bar starts visible — report that
            // to the director so the status capsule starts
            // with the bar even when a previous attempt in
            // this session (e.g. a KS attempt before the
            // torrent substitution rung, or the reverse) had
            // reported its own bar hidden.
            DispatchQueue.main.async { [weak self] in
                self?.director.setTransportBarVisible(true)
            }
        }

        /// FIX4 (fix 9): the Title View binding. AVKit renders
        /// the film's title + poster — idea 13's
        /// externalMetadata, set in refreshChrome — in a Title
        /// View above the transport bar. On tvOS 27.2.1 the
        /// owner observed the title still sitting on screen
        /// after the bar auto-hid; his ruling: the title hides
        /// WITH the bar and returns WITH the bar, never on its
        /// own schedule. AVKit announces every transport-bar
        /// visibility transition to its delegate (this is the
        /// documented "responding to transport bar changes"
        /// surface), and the Title View's inclusion follows
        /// the announced state, so the two cannot drift
        /// apart: bar coming up → title included; bar going
        /// away → title excluded. No separate title timer
        /// exists anywhere in this binding.
        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            willTransitionToVisibilityOfTransportBar visible: Bool,
            with _: AVPlayerViewControllerAnimationCoordinator
        ) {
            playerViewController.transportBarIncludesTitleView = visible
            // v2.0.29 (item 2): the SAME announced state is
            // reported into the director, where the shell's
            // status capsule is bound to it — the capsule
            // (source label / resume line) now follows this
            // path's bar exactly as the Title View does,
            // from the one announcement, so the three can
            // never drift apart. (Pre-fix the capsule was
            // rendered unconditionally and the resume line
            // lingered after bar + title had hidden — the
            // owner's normal-film finding on 2.0.28.)
            DispatchQueue.main.async { [weak self] in
                self?.director.setTransportBarVisible(visible)
            }
        }

        /// v2.0.29 (item 3): a candidate label flattened for
        /// a one-line menu row — the same treatment as the
        /// KS host's chooser rows (multi-line stream names
        /// join with " · " instead of truncating at the
        /// first line break). Display only; the candidate's
        /// own label is unchanged everywhere else.
        private static func flattenedSourceLabel(_ label: String) -> String {
            label.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
        }

        /// The metadata title for an item: the film title,
        /// plus the episode label when the entry carries one.
        private static func displayTitle(for entry: WatchStore.Entry) -> String {
            if entry.title.isEmpty { return entry.epLabel }
            if entry.epLabel.isEmpty { return entry.title }
            return "\(entry.title) — \(entry.epLabel)"
        }

        /// Per-item chrome refresh, called from observe():
        /// the item's external metadata (title now, artwork
        /// when the poster lands), a rebuilt transport menu
        /// (favourite state / next-episode presence are read
        /// at build time) and the info tab's labels.
        @MainActor
        private func refreshChrome(for item: AVPlayerItem) {
            let entry = director.sessionEntry
            let titleItem = AVMutableMetadataItem()
            titleItem.identifier = .commonIdentifierTitle
            titleItem.value = Self.displayTitle(for: entry) as NSString
            titleItem.extendedLanguageTag = nil
            DispatchQueue.main.async {
                item.externalMetadata = [titleItem]
            }
            // Artwork: fetch the poster fail-soft and add it
            // only if this item is still the player's current
            // one when the data lands — a slow poster must
            // never stamp itself onto the NEXT candidate.
            artworkTask?.cancel()
            artworkTask = nil
            if let posterURL = entry.posterURL {
                artworkTask = Task { [weak self] in
                    // FIX4 (HTTP consolidation): the poster
                    // fetch rides the shared JoeHTTP pool like
                    // every other data fetch — pre-fix it used
                    // URLSession.shared, outside the pool,
                    // outside the metrics and outside every
                    // house timeout. Fail-soft exactly as
                    // before (any error → no artwork).
                    let data = try? await JoeHTTP.getData(
                        posterURL.absoluteString, timeout: 15)
                    guard let data, !data.isEmpty else { return }
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.player?.currentItem === item else { return }
                        let artItem = AVMutableMetadataItem()
                        artItem.identifier = .commonIdentifierArtwork
                        artItem.value = data as NSData
                        artItem.extendedLanguageTag = nil
                        item.externalMetadata = [titleItem, artItem]
                    }
                }
            }
            refreshTransportMenu()
            infoController.update(title: entry.title,
                                  episode: entry.epLabel,
                                  source: director.currentLabel)
        }

        /// (Re)build the "Joe TV" transport-bar menu from the
        /// director's CURRENT state. Called per item (from
        /// refreshChrome) and again right after a favourite
        /// toggle, so the label the owner sees on the next
        /// long-press is never stale.
        @MainActor
        private func refreshTransportMenu() {
            guard let viewController else { return }
            let isFav = director.isFavourite
            // v2.0.29 (item 3): "Đổi nguồn" is a SUBMENU —
            // the session's candidate list, each row the
            // candidate's own label with the current one
            // checked (.on) — instead of the pre-fix single
            // action that blindly advanced to the next
            // candidate. Picking a row switches to THAT
            // candidate through userSwitchSource(to:),
            // which keeps the playback position via the
            // standing itemReady resume rule. The menu is
            // rebuilt per item (refreshChrome) and after a
            // favourite toggle, so the check mark is never
            // stale. Same transport-menu pattern as the
            // rest of this menu — no new presentation form.
            let switchMenu = UIMenu(
                title: "Đổi nguồn",
                image: UIImage(systemName: "arrow.triangle.2.circlepath"),
                children: director.sourceChoices.map { choice in
                    UIAction(
                        title: Self.flattenedSourceLabel(choice.label),
                        state: choice.isCurrent ? .on : .off
                    ) { [weak self] _ in
                        self?.director.userSwitchSource(to: choice.index)
                    }
                })
            let favouriteAction = UIAction(
                title: isFav ? "Bỏ yêu thích" : "Yêu thích",
                image: UIImage(systemName: isFav ? "heart.fill" : "heart")
            ) { [weak self] _ in
                guard let self else { return }
                self.director.toggleFavourite()
                self.refreshTransportMenu()
            }
            var children: [UIMenuElement] = [switchMenu, favouriteAction]
            if director.hasNextEpisode {
                children.append(UIAction(
                    title: "Tập tiếp theo",
                    image: UIImage(systemName: "forward.end.fill")
                ) { [weak self] _ in
                    self?.director.skipToNextEpisode()
                })
            }
            viewController.transportBarCustomMenuItems = [
                UIMenu(title: "Joe TV", children: children)
            ]
        }

        @MainActor
        func observe(_ item: AVPlayerItem, player: AVPlayer) {
            self.player = player
            // U-1: without this, an item whose status stays
            // .unknown (a stream that accepts the connection and
            // then never sends a byte) leaves the player on a
            // silent black screen forever — AVPlayer raises no
            // error for it. The watchdog feeds the stall into
            // the director's normal failover path.
            watchdog?.cancel()
            let wd = DispatchWorkItem { [weak self] in
                self?.fireFail(cause: "Quá 20 giây vẫn chưa sẵn sàng phát")
            }
            watchdog = wd
            DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: wd)
            // Mid-play freeze watchdog: armed now, but it only
            // starts judging once the item readies — until
            // then the pre-ready watchdog above owns the start
            // phase and the two never overlap.
            freezeTimer?.invalidate()
            freezeReady = false
            freezeEnded = false
            lastPositionSec = -1
            lastAdvanceAt = Date()
            let ticker = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.checkFreeze()
            }
            RunLoop.main.add(ticker, forMode: .common)
            freezeTimer = ticker
            statusToken = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    self.handleReady()
                case .failed:
                    fireFail()
                default:
                    break
                }
            }
            // v2.0.24: a dwell-warmed item (StreamWarmer) may
            // ALREADY be .readyToPlay when the observation is
            // installed — KVO with .new reports only changes
            // after registration, so without this check the
            // ready transition would never fire for it: no
            // resume seek, and the U-1 watchdog would kill a
            // healthy item at 20 s. For a cold item the status
            // is .unknown here and the check is a no-op.
            if item.status == .readyToPlay {
                handleReady()
            }
            failToken = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
            ) { [weak self] note in
                // The notification carries the error that
                // ended playback — hand it to the director
                // (pre-v2.0.5 it was discarded unread).
                let err = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                self?.fireFail(cause: err?.localizedDescription)
            }
            endToken = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
            ) { [weak self] _ in
                // The freeze watchdog stands down at the end:
                // a finished item is the end-observer's
                // transition, never a stall.
                self?.freezeEnded = true
                DispatchQueue.main.async { self?.director.itemEnded() }
            }
            timeToken = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 5, preferredTimescale: 600),
                queue: .main
            ) { [weak self] time in
                guard let self, let item = self.player?.currentItem else { return }
                let pos = Int64(time.seconds * 1000)
                let dur = item.duration.seconds.isFinite ? Int64(item.duration.seconds * 1000) : 0
                self.director.tick(positionMs: pos, durationMs: dur)
            }
            // Idea 13: the new item gets its metadata, menu
            // and info-tab labels (see refreshChrome).
            refreshChrome(for: item)
        }

        /// The .readyToPlay transition, shared by the KVO
        /// above and observe()'s already-ready check: stand
        /// the pre-ready watchdog down, arm the freeze
        /// watchdog's judgement from a fresh clock, and hand
        /// the resume seek to the director.
        private func handleReady() {
            watchdog?.cancel()
            freezeReady = true
            lastAdvanceAt = Date()
            if let p = player {
                let now = p.currentTime().seconds
                lastPositionSec = now.isFinite ? now : -1
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, let player = self.player else { return }
                self.director.itemReady(player: player)
            }
        }

        /// One freeze-watchdog tick (1 s, main run loop).
        /// Judgement is deliberately narrow — it fires ONLY
        /// on a playhead that has not advanced for 12 s while
        /// playback is supposed to be running:
        ///   • not ready yet → the pre-ready watchdog owns
        ///     the phase; stay out of its way;
        ///   • user-paused (timeControlStatus == .paused,
        ///     which is also where the controller sits during
        ///     a scrub) → hold the clock open, so a resume
        ///     always gets a fresh 12 s and a pause can never
        ///     be misread as a stall;
        ///   • ended / within a breath of the end → the
        ///     end-observer owns the transition;
        ///   • any playhead movement — including a seek jump
        ///     in either direction — counts as alive.
        private func checkFreeze() {
            guard freezeReady, !freezeEnded, !failed,
                  let player, let item = player.currentItem else { return }
            if player.timeControlStatus == .paused {
                lastAdvanceAt = Date()
                let now = player.currentTime().seconds
                if now.isFinite { lastPositionSec = now }
                return
            }
            let pos = player.currentTime().seconds
            guard pos.isFinite else { return }
            let dur = item.duration.seconds
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
                fireFail(cause: "Hình đứng yên 12 giây (đóng băng)")
            }
        }

        /// Failure funnel: the cause (the caller's explicit
        /// label, else the item's own error — read here before
        /// it is thrown away) rides to the director, which logs
        /// it and remembers it for the exhausted slate.
        private func fireFail(cause: String? = nil) {
            guard !failed else { return }
            failed = true
            watchdog?.cancel()
            freezeTimer?.invalidate()
            freezeTimer = nil
            let resolved = cause ?? player?.currentItem?.error?.localizedDescription
            DispatchQueue.main.async { [weak self] in
                self?.director.itemFailed(cause: resolved)
            }
        }

        func invalidate() {
            artworkTask?.cancel()
            artworkTask = nil
            watchdog?.cancel()
            watchdog = nil
            freezeTimer?.invalidate()
            freezeTimer = nil
            statusToken?.invalidate()
            statusToken = nil
            if let failToken { NotificationCenter.default.removeObserver(failToken) }
            if let endToken { NotificationCenter.default.removeObserver(endToken) }
            failToken = nil
            endToken = nil
            if let timeToken, let player {
                player.removeTimeObserver(timeToken)
            }
            timeToken = nil
        }
    }
}

extension CMTime {
    init(milliseconds: Int64) {
        self.init(value: milliseconds, timescale: 1000)
    }
}
