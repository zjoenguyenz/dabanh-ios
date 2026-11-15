import AVFoundation
import AVKit
import SwiftUI

/// One playable stream candidate: a freshly resolved URL plus
/// the headers its CDN demands (never a blanket header — see the
/// house rule in Channel.swift).
struct PlayCandidate {
    var url: URL
    var headers: [String: String] = [:]
    var label: String = ""
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

    func start() {
        guard !started else { return }
        started = true
        Task { await loadLadder() }
    }

    private func loadLadder() async {
        phase = .resolving
        let ladder = await resolveLadder(identity)
        if ladder.isEmpty {
            await failoverStep()
            return
        }
        candidates = ladder
        candidateIndex = 0
        beginCandidate()
    }

    private func beginCandidate() {
        guard candidates.indices.contains(candidateIndex) else {
            Task { await failoverStep() }
            return
        }
        let c = candidates[candidateIndex]
        candidate = c
        currentLabel = c.label
        attemptID += 1
        phase = .playing
    }

    /// The current item failed (status .failed or failed-to-end).
    func itemFailed() {
        guard phase == .playing else { return }
        candidateIndex += 1
        if candidateIndex < candidates.count {
            beginCandidate()
        } else {
            Task { await failoverStep() }
        }
    }

    /// Refresh once → hop once → substitution rung once →
    /// exhausted. The first two steps mirror the Android player
    /// exactly (PlayerActivity.beginFailoverStep); the rung is
    /// the v1.9 owner-law extension behind them, reached from
    /// every exhaustion path (an empty ladder, a failed item,
    /// the stall watchdog advancing past the last candidate).
    private func failoverStep() async {
        if !refreshed {
            refreshed = true
            notice = "Đang tải lại nguồn…"
            await loadLadder()
            return
        }
        if !hopped, let hopIdentity {
            hopped = true
            notice = "Đang đổi nguồn…"
            if let next = await hopIdentity(identity) {
                identity = next
                notice = "Đổi nguồn: \(Providers.displayName(next.entry.source))"
                await loadLadder()
                return
            }
        }
        if !fallbackTried, let fallbackCandidates {
            fallbackTried = true
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
    func retryFromExhausted() {
        guard phase == .exhausted else { return }
        refreshed = false
        hopped = false
        fallbackTried = false
        seekApplied = false
        notice = "Đang thử lại…"
        Task { await loadLadder() }
    }

    /// Item is ready: apply the resume seek once (the view's
    /// coordinator performs it and reports back the position it
    /// landed on — here we just record that it happened and show
    /// the Android toast text).
    func itemReady(player: AVPlayer) {
        guard !seekApplied else { return }
        seekApplied = true
        // The Android rule, checked with the real duration in
        // hand: seek only when the stored position is past 20 s
        // AND outside the last 30 s (a finished title restarts).
        let durSec = player.currentItem?.duration.seconds ?? 0
        let durMs = durSec.isFinite ? Int64(durSec * 1000) : 0
        if resumeMs > 20_000 && (durMs <= 0 || resumeMs < durMs - 30_000) {
            let target = CMTime(milliseconds: resumeMs)
            player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            notice = "Tiếp tục từ \(WatchStore.fmtClock(resumeMs))"
        }
    }

    /// Periodic tick from the player (~every 5 s): the Android
    /// save rule — under 10 s records nothing; inside the last
    /// 30 s the entry is dropped (finished); otherwise save.
    func tick(positionMs: Int64, durationMs: Int64) {
        lastPosMs = positionMs
        lastDurMs = durationMs
        guard durationMs > 0, positionMs > 10_000 else { return }
        if positionMs >= durationMs - 30_000 {
            store.removeProgress(key: identity.progressKey)
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
    func itemEnded() {
        store.removeProgress(key: identity.progressKey)
    }

    /// Leaving the player: one last save under the same rule.
    func flush() {
        tick(positionMs: lastPosMs, durationMs: lastDurMs)
    }
}

/// Full-screen player shell: AVPlayerViewController + a status
/// capsule (candidate label / failover notices), driven by
/// PlayDirector. Menu exits, like the house player.
struct JoePlayerView: View {
    @StateObject private var director: PlayDirector
    @Environment(\.dismiss) private var dismiss
    @FocusState private var slateFocus: SlateButton?

    private enum SlateButton: Hashable { case retry, back }

    init(director: PlayDirector) {
        _director = StateObject(wrappedValue: director)
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
                    PlayerController(candidate: candidate,
                                     director: director)
                        .id(director.attemptID)
                        .ignoresSafeArea()
                }
                statusCapsule
            case .exhausted:
                // §8 error slate: message + cause + reachable
                // buttons, focus on the first button. (v1.8's
                // slate was text-only — the only way out was
                // Menu, which read as part of the freeze.)
                VStack(alignment: .leading, spacing: 18) {
                    Text("Không phát được nguồn này.")
                        .font(.system(size: 29, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Đã thử lấy link mới và đổi nguồn nhưng vẫn không phát được.")
                        .font(.system(size: 25))
                        .foregroundStyle(.white.opacity(0.7))
                    HStack(spacing: 16) {
                        slateButton("Thử lại", tag: .retry) {
                            director.retryFromExhausted()
                        }
                        slateButton("Quay lại", tag: .back) {
                            dismiss()
                        }
                    }
                    .padding(.top, 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.leading, 48)
                .padding(.bottom, 36)
            }
        }
        .onAppear { director.start() }
        .onChange(of: director.phase) { _, phase in
            // §8: when the error slate appears, focus lands on
            // its first button.
            if phase == .exhausted { slateFocus = .retry }
        }
        .onDisappear { director.flush() }
        .onExitCommand { dismiss() }
    }

    private func slateButton(_ title: String, tag: SlateButton,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 29, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 36)
                .padding(.vertical, 16)
                .background(Capsule().fill(JoeTheme.accentViolet))
                .overlay(JoeFocusRing(shape: Capsule()))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled(true)
        .focused($slateFocus, equals: tag)
        .scaleEffect(slateFocus == tag ? 1.05 : 1.0)
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

private struct PlayerController: UIViewControllerRepresentable {
    let candidate: PlayCandidate
    let director: PlayDirector

    func makeCoordinator() -> Coordinator {
        Coordinator(director: director)
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        let item = AVPlayerItem(asset: Self.asset(for: candidate))
        let player = AVPlayer(playerItem: item)
        controller.player = player
        context.coordinator.observe(item, player: player)
        player.play()
        return controller
    }

    /// Plain AVURLAsset with exactly the headers the candidate
    /// carries (plus the house user agent when none was set).
    static func asset(for candidate: PlayCandidate) -> AVURLAsset {
        var headers = candidate.headers
        if headers["User-Agent"] == nil {
            headers["User-Agent"] = JoeHTTP.userAgent
        }
        return AVURLAsset(url: candidate.url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
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
    final class Coordinator {
        private let director: PlayDirector
        private var statusToken: NSKeyValueObservation?
        private var failToken: NSObjectProtocol?
        private var endToken: NSObjectProtocol?
        private var timeToken: Any?
        private weak var player: AVPlayer?
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
        }

        func observe(_ item: AVPlayerItem, player: AVPlayer) {
            self.player = player
            // U-1: without this, an item whose status stays
            // .unknown (a stream that accepts the connection and
            // then never sends a byte) leaves the player on a
            // silent black screen forever — AVPlayer raises no
            // error for it. The watchdog feeds the stall into
            // the director's normal failover path.
            watchdog?.cancel()
            let wd = DispatchWorkItem { [weak self] in self?.fireFail() }
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
                    self.watchdog?.cancel()
                    self.freezeReady = true
                    self.lastAdvanceAt = Date()
                    if let p = self.player {
                        let now = p.currentTime().seconds
                        self.lastPositionSec = now.isFinite ? now : -1
                    }
                    DispatchQueue.main.async { [weak self] in
                        guard let self, let player = self.player else { return }
                        self.director.itemReady(player: player)
                    }
                case .failed:
                    fireFail()
                default:
                    break
                }
            }
            failToken = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
            ) { [weak self] _ in
                self?.fireFail()
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
                fireFail()
            }
        }

        private func fireFail() {
            guard !failed else { return }
            failed = true
            watchdog?.cancel()
            freezeTimer?.invalidate()
            freezeTimer = nil
            DispatchQueue.main.async { [weak self] in self?.director.itemFailed() }
        }

        func invalidate() {
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
