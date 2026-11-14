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
    /// Resume position read at session start (>20 s rule applied
    /// by the caller against the stored entry).
    private let resumeMs: Int64

    private var candidates: [PlayCandidate] = []
    private var candidateIndex = 0
    private var refreshed = false
    private var hopped = false
    private var seekApplied = false
    private var lastPosMs: Int64 = 0
    private var lastDurMs: Int64 = 0
    private var started = false

    init(store: WatchStore,
         identity: PlayIdentity,
         resumeMs: Int64,
         resolveLadder: @escaping (PlayIdentity) async -> [PlayCandidate],
         hopIdentity: ((PlayIdentity) async -> PlayIdentity?)?) {
        self.store = store
        self.identity = identity
        self.resumeMs = resumeMs
        self.resolveLadder = resolveLadder
        self.hopIdentity = hopIdentity
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

    /// Refresh once → hop once → exhausted. Mirrors the Android
    /// player exactly (PlayerActivity.beginFailoverStep).
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
        phase = .exhausted
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

    init(director: PlayDirector) {
        _director = StateObject(wrappedValue: director)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch director.phase {
            case .resolving:
                ProgressView("Đang tải…")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .tint(.white)
            case .playing:
                if let candidate = director.candidate {
                    PlayerController(candidate: candidate,
                                     director: director)
                        .id(director.attemptID)
                        .ignoresSafeArea()
                }
                statusCapsule
            case .exhausted:
                VStack(spacing: 18) {
                    Text("NGUỒN ĐANG LỖI")
                        .font(.system(size: 50, weight: .bold))
                        .tracking(3)
                        .foregroundStyle(.white)
                    Text("Đã thử lấy link mới và đổi nguồn nhưng vẫn không phát được. Bấm Menu để quay lại.")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.65))
                }
            }
        }
        .onAppear { director.start() }
        .onDisappear { director.flush() }
        .onExitCommand { dismiss() }
    }

    private var statusCapsule: some View {
        VStack {
            Spacer()
            HStack {
                if let notice = director.notice {
                    Text(notice)
                        .font(.callout)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.black.opacity(0.6)))
                } else if !director.currentLabel.isEmpty {
                    Text(director.currentLabel)
                        .font(.callout)
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

        init(director: PlayDirector) {
            self.director = director
        }

        func observe(_ item: AVPlayerItem, player: AVPlayer) {
            self.player = player
            statusToken = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
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

        private func fireFail() {
            guard !failed else { return }
            failed = true
            DispatchQueue.main.async { [weak self] in self?.director.itemFailed() }
        }

        func invalidate() {
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
