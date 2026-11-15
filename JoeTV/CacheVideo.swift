import Foundation

/// CacheVideo — an independent HLS CDN (cachevideo.com) surfaced
/// through a third-party Stremio-protocol resolver addon (author
/// quan1208; measured live 2026-11-14 in LINK-HUNT-WAVE3). Swift
/// port of the Android CacheVideo (Joe TV v1.7, device-verified).
/// It carries a SUBSET of titles, keyed by IMDb id:
///   GET {resolver}/stream/movie/{imdbId}.json
///   GET {resolver}/stream/series/{imdbId}:{season}:{episode}.json
/// Playback needs the Referer/UA below on the playlist AND the
/// segment requests (a segment fetch without the Referer answers
/// 403), so callers route CacheVideo URLs through JoeProxy with
/// these headers attached. The segments themselves are plain
/// MPEG-TS (0x47 sync at offset 0 — no disguise prefix).
/// resolve() returns nil whenever the resolver does not carry the
/// title/episode; callers treat that as "server contributes
/// nothing", the house behaviour for a dead server.
enum CacheVideo {
    static let resolver = "https://motchillv.q-1208.fun"
    static let referer = "https://motchillv.tel/"
    static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) "
        + "Chrome/120.0.0.0 Safari/537.36"
    static var headers: [String: String] {
        ["Referer": referer, "User-Agent": userAgent]
    }

    /// Tuned resolve cap (LATENCY-AUDIT §6): 15 s → 10 s. The
    /// resolver has the widest legitimate spread in the system
    /// (2.0–5.4 s measured), so its cap stays the loosest of
    /// the resolve class; SourceHealth's fuse tightens within.
    private static let resolveCap: TimeInterval = 10

    // MARK: - Detail-probe memo (double-resolve elimination)

    /// TpClient.detail() probes this resolver once per title
    /// (S{season}E1 / the movie) to learn whether the title is
    /// carried; the play ladder then resolves the SAME key
    /// again when that episode is played — measured as the
    /// slowest healthy path in the system (audit §1.4: the
    /// double resolution stacks ≈3.6 s twice). Successful
    /// resolutions are memoised in memory so the ladder reuses
    /// the detail-time result for the identical key.
    ///
    /// Bounds, chosen against the house fresh-resolution rule:
    /// in-memory ONLY (never persisted, dies with the
    /// process), successful results only, 10-minute TTL — the
    /// window covers a detail-open → play flow, and the
    /// resolver's URLs are stable CDN addresses (unlike
    /// Film4K's per-call tokens, which are never memoised).
    private static let memoLock = NSLock()
    private static var memo: [String: (url: String, at: TimeInterval)] = [:]
    private static let memoTTL: TimeInterval = 600

    private static func memoGet(_ key: String) -> String? {
        memoLock.lock()
        defer { memoLock.unlock() }
        guard let hit = memo[key],
              Date().timeIntervalSince1970 - hit.at <= memoTTL else { return nil }
        return hit.url
    }

    private static func memoSet(_ key: String, _ url: String) {
        memoLock.lock()
        if memo.count > 64 { memo.removeAll() }
        memo[key] = (url, Date().timeIntervalSince1970)
        memoLock.unlock()
    }

    /// The cachevideo.com playlist URL for one title (season <= 0
    /// → movie) or episode, or nil when not carried. Prefers the
    /// "Direct" stream (the raw CDN URL); the addon's own proxy
    /// wrap of the same URL is the fallback.
    static func resolve(imdbId: String, season: Int, episode: Int) async -> String? {
        if imdbId.isEmpty { return nil }
        let memoKey = "\(imdbId)|\(season)|\(episode)"
        if let cached = memoGet(memoKey) { return cached }
        let path = season > 0
            ? "/stream/series/\(imdbId):\(season):\(max(1, episode)).json"
            : "/stream/movie/\(imdbId).json"
        let url = resolver + path
        // Recorded under TP (the provider whose details carry
        // CacheVideo), resolve stage, resolver host.
        guard let root = try? await SourceHealth.run(
            provider: Providers.TP, stage: .resolve, url: url, cap: resolveCap,
            { budget in
                try await JoeHTTP.getJSON(url, timeout: budget)
            }) else {
            return nil
        }
        let streams = JSON.arr(root, "streams") ?? []
        var fallback: String?
        for s in streams {
            let streamURL = JSON.str(s, "url")
            if !streamURL.contains("cachevideo.com") { continue }
            if JSON.str(s, "name").contains("Direct") {
                memoSet(memoKey, streamURL)
                return streamURL
            }
            if fallback == nil { fallback = streamURL }
        }
        if let fallback { memoSet(memoKey, fallback) }
        return fallback
    }
}
