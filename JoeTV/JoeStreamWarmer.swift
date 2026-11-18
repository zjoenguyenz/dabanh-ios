import AVFoundation
import Foundation

/// Detail-dwell media warming for the KK play path
/// (v2.0.24 — Sony 2.3.37's D2 preload, in tvOS's own
/// shape; the design follows the platform study in
/// STUDY.md §5, not the Android code).
///
/// The Android build preloads through Media3's
/// DefaultPreloadManager: a manager that shares its
/// player components loads the first seconds of the
/// likely-next item during detail dwell, and the tap
/// hands the preloaded source to the player. AVFoundation
/// has no preload manager; its prepare-in-advance shape
/// (Apple's own playback guidance: create the asset/item
/// BEFORE the tap and load its keys asynchronously) is:
///
///   1. an AVURLAsset whose playable key is loaded async —
///      for HLS that pulls the master + variant playlists
///      and resolves the stream's shape;
///   2. an AVPlayerItem built from that asset, with a
///      ~5 s preferredForwardBufferDuration (the Sony
///      target preload duration), assigned to a paused
///      AVPlayer — a player loads its current item toward
///      that buffer target, so the initial segments land
///      while the owner is still reading the detail screen.
///
/// At the tap, PlayerController takes the warmed player
/// over whole (same item, same buffer) when its first
/// candidate is the warmed URL; any other candidate — or
/// a stale warm — falls back to the exact pre-2.0.24 cold
/// build. Nothing about the ladder, the failover, the
/// resume rule or the track rules changes: the warmer
/// only moves WHEN the first candidate's bytes start
/// moving.
///
/// Honest bounds, stated once here: AVFoundation exposes
/// no API that guarantees an exact warmed byte count —
/// the HLS stack decides how much of the forward buffer
/// to fill while paused — and the warm covers only the
/// ONE item the dwell target names (the focused/first
/// episode's first ladder entry, KK only; VS/F4K/TP keep
/// the dwell behaviour they already had, the URL-level
/// pre-resolve, because their URLs are minted by a live
/// resolve). The warm is in-memory only and holds no URL
/// past the freshness bound below: stream URLs are still
/// resolved fresh by the ladder at tap time, and the
/// warmer merely recognises the tap's own fresh URL when
/// it matches the one the dwell ladder — built from this
/// session's detail payload through the same memoised
/// resolver — produced moments earlier.
final class StreamWarmer {
    static let shared = StreamWarmer()

    /// Freshness bound: the resolve memo's TTL (Providers),
    /// for the same reason — past it, a held URL is no
    /// longer trusted as this session's fresh resolution.
    private static let maxAge: TimeInterval = 600

    private struct Entry {
        var url: URL
        var headers: [String: String]
        var player: AVPlayer
        var at: Date
    }

    private let lock = NSLock()
    private var entry: Entry?

    /// Warm one candidate (URL + the exact headers its
    /// ladder entry carries). Replaces any previous warm —
    /// the dwell names one likely-next item at a time, and
    /// the memory discipline is the platform study's: one
    /// item, ~5 s of media, released on replacement or
    /// take-over.
    func warm(url: URL, headers: [String: String]) {
        lock.lock()
        if let e = entry, e.url == url, e.headers == headers,
           Date().timeIntervalSince(e.at) <= Self.maxAge {
            lock.unlock()
            return
        }
        let old = entry
        entry = nil
        lock.unlock()
        old?.player.pause()
        old?.player.replaceCurrentItem(with: nil)

        let candidate = PlayCandidate(url: url, headers: headers)
        let asset = candidate.makeAsset()
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 5
        let player = AVPlayer(playerItem: item)
        lock.lock()
        entry = Entry(url: url, headers: headers, player: player, at: Date())
        lock.unlock()
        // Apple's async key loading, alongside the player's
        // own load: the playable key is what the item's
        // readiness turns on. Fail-soft — a failed load
        // leaves a cold item whose player the tap simply
        // never takes (its status never readies here, and
        // take() does not promise readiness, only identity;
        // the taken item still passes through the player
        // shell's normal ready/fail machinery).
        Task { _ = try? await asset.load(.isPlayable) }
    }

    /// The named entry point of the shared warming system
    /// (v2.0.25): callers that know an upcoming item (the
    /// Up Next path warms the next episode while the
    /// current one plays) warm through here rather than
    /// reaching for warm(url:headers:) directly. Later
    /// warming layers build onto this same warmer — the
    /// single-entry discipline is unchanged: one entry,
    /// replaced on a new warm, consumed on take.
    func warmUpcoming(url: URL, headers: [String: String]) {
        warm(url: url, headers: headers)
    }

    /// Hand the warmed player to the tap, or nil when the
    /// tap's candidate is not the warmed one (different
    /// URL/headers, or the warm aged out). A taken entry is
    /// consumed: the presented player owns it now, and a
    /// later dwell warm builds a fresh one.
    func take(url: URL, headers: [String: String]) -> AVPlayer? {
        lock.lock()
        defer { lock.unlock() }
        guard let e = entry, e.url == url, e.headers == headers,
              Date().timeIntervalSince(e.at) <= Self.maxAge
        else {
            PerfLog.mark("warm.miss")
            return nil
        }
        entry = nil
        PerfLog.mark("warm.hit")
        return e.player
    }

    /// Drop the warm without a take (detail exit paths
    /// that know the dwell context is gone).
    func clear() {
        lock.lock()
        let old = entry
        entry = nil
        lock.unlock()
        old?.player.pause()
        old?.player.replaceCurrentItem(with: nil)
    }
}
