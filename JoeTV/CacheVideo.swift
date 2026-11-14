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

    /// The cachevideo.com playlist URL for one title (season <= 0
    /// → movie) or episode, or nil when not carried. Prefers the
    /// "Direct" stream (the raw CDN URL); the addon's own proxy
    /// wrap of the same URL is the fallback.
    static func resolve(imdbId: String, season: Int, episode: Int) async -> String? {
        if imdbId.isEmpty { return nil }
        let path = season > 0
            ? "/stream/series/\(imdbId):\(season):\(max(1, episode)).json"
            : "/stream/movie/\(imdbId).json"
        guard let root = try? await JoeHTTP.getJSON(resolver + path, timeout: 15) else {
            return nil
        }
        let streams = JSON.arr(root, "streams") ?? []
        var fallback: String?
        for s in streams {
            let url = JSON.str(s, "url")
            if !url.contains("cachevideo.com") { continue }
            if JSON.str(s, "name").contains("Direct") { return url }
            if fallback == nil { fallback = url }
        }
        return fallback
    }
}
