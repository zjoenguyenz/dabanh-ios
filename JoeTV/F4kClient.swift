import Foundation

/// Film4K.net public API client (https://film4k.net) — a genuinely
/// independent provider: its own catalogue database and streams on
/// TikTok's CDN, nothing shared with the KKPhim family, and it
/// answers non-Vietnam IPs directly (no tunnel needed). Found and
/// verified end-to-end by the 2026-11-14 link hunt (playlist 200
/// #EXTM3U + segment 206 from a US vantage). NOT the Phim4K
/// Android app — that is a KKPhim front-end; this is a different
/// service that happens to share the name.
///
/// Shapes measured live from this machine (2026-11-14):
///   GET /api/home[?page=N] → {list:[…] (24/page, paginated),
///        newMovies:[…12], newSeries:[…12], genres, total}
///   GET /api/search/suggest?q=… → {list:[…]} (light items)
///   GET /api/title/{slug} → {movie:{…}, playable, languages,
///        episodes:[{season, episode, title,
///                   sources:[{kind:"other",
///                             url:"/api/hls/<token>/master.m3u8",
///                             label:"Server 1"}]}]}
///   Item fields: slug, title{en,vi}, poster{en,vi} (TMDB URLs),
///        mediaType "movie"|"tv", year (number, 0 = unknown),
///        maxRes ("1080p"/"4K"), viSubs/viDub booleans,
///        genres{en:[],vi:[]}, overview{en,vi}; series add
///        epCount/epTotal.
///
/// Stream URLs are TOKENISED and the token rotates on every API
/// call (two fetches of the same title return different tokens).
/// The client therefore follows the KKPhim rule: a token URL is
/// parsed out of the detail response and used only by the play
/// ladder built from that same response — and the ladder is
/// always built from a detail fetched at tap time (the detail
/// view's PlayDirector re-fetches detail before ladderFor runs,
/// and the failover refresh re-fetches again). No stream URL is
/// ever written to WatchStore, prefs or any file.
///
/// Segments are PNG-disguised fMP4 (a ~67-byte PNG, then the
/// fMP4 styp box) served by the TikTok CDN. Playback here is the
/// plain AVPlayer path like every other provider — whether
/// AVPlayer tolerates the disguise on device is
/// UNVERIFIED-ON-DEVICE (flagged in the delivery report).
enum F4kClient {
    static let base = "https://film4k.net"

    // MARK: - Endpoints

    /// The home feed's paginated "list" — newest-updated titles,
    /// movies and series mixed.
    static func newest(page: Int) async throws -> [Movie] {
        let root = try await JoeHTTP.getJSON(base + "/api/home?page=\(page)")
        return parseItems(JSON.arr(root, "list") ?? [])
    }

    /// Typed rails from the home payload: page 1 uses the curated
    /// newMovies / newSeries sections; deeper pages filter the
    /// paginated mixed list by media type. Other KK-style types
    /// have no Film4K equivalent and return empty (the rail then
    /// simply does not render).
    static func listByType(_ type: String, page: Int) async throws -> [Movie] {
        switch type {
        case "phim-le", "phim-bo":
            let wantMovie = type == "phim-le"
            if page <= 1 {
                let root = try await JoeHTTP.getJSON(base + "/api/home")
                return parseItems(JSON.arr(root, wantMovie ? "newMovies" : "newSeries") ?? [])
            }
            let root = try await JoeHTTP.getJSON(base + "/api/home?page=\(page)")
            return parseItems(JSON.arr(root, "list") ?? [])
                .filter { ($0.type == "single") == wantMovie }
        default:
            return []
        }
    }

    /// Suggest is the site's only search surface (measured:
    /// /api/search answers 404). Items are light — slug, titles,
    /// poster, mediaType, year — which parseMovie tolerates.
    static func search(_ keyword: String) async throws -> [Movie] {
        let root = try await JoeHTTP.getJSON(
            base + "/api/search/suggest?q=\(JoeHTTP.qenc(keyword))")
        return parseItems(JSON.arr(root, "list") ?? [])
    }

    static func detail(_ slug: String) async throws -> Detail {
        let root = try await JoeHTTP.getJSON(base + "/api/title/\(slug)")
        var d = Detail()
        guard let item = JSON.obj(root, "movie") else { return d }
        d.movie = parseMovie(item)
        d.content = stripHTML(localized(item, "overview"))
        var meta: [String] = []
        if !d.movie.year.isEmpty { meta.append(d.movie.year) }
        let q = cleanField(JSON.str(item, "maxRes")); if !q.isEmpty { meta.append(q) }
        if !d.movie.lang.isEmpty { meta.append(d.movie.lang) }
        let epCount = JSON.int(item, "epCount"), epTotal = JSON.int(item, "epTotal")
        if epCount > 0 && epTotal > epCount {
            meta.append("Đang chiếu: Tập \(epCount)")
        }
        d.metaLine = joinParts(meta, "  ·  ")
        let genres = localizedArray(item, "genres")
        if !genres.isEmpty { d.categories = joinParts(genres, ", ") }

        let episodes = JSON.arr(root, "episodes") ?? []
        if episodes.isEmpty {
            // Movie: one "Full" episode from the title's own
            // tokenised hlsUrl (fresh from THIS fetch — see the
            // class comment for why that satisfies the fresh rule).
            let hls = JSON.str(item, "hlsUrl")
            if !hls.isEmpty {
                var s = Server()
                s.name = "Server 1"
                var e = Episode()
                e.name = "Full"
                e.m3u8 = absURL(hls)
                s.episodes.append(e)
                d.servers.append(s)
            }
        } else {
            // Series: group each episode's sources by label into
            // servers, preserving first-seen label order and the
            // API's episode order. Only real HLS sources count —
            // anything without an .m3u8 URL (e.g. an ok.ru embed
            // kind) never enters the ladder.
            var order: [String] = []
            var byLabel: [String: [Episode]] = [:]
            for ej in episodes {
                let name = epName(season: JSON.int(ej, "season", 1),
                                  episode: JSON.int(ej, "episode"))
                for sj in JSON.arr(ej, "sources") ?? [] {
                    let url = JSON.str(sj, "url")
                    guard url.contains(".m3u8") else { continue }
                    let label = JSON.str(sj, "label", "Server 1")
                    var e = Episode()
                    e.name = name
                    e.m3u8 = absURL(url)
                    if byLabel[label] == nil { order.append(label) }
                    byLabel[label, default: []].append(e)
                }
            }
            for label in order {
                var s = Server()
                s.name = label
                s.episodes = byLabel[label] ?? []
                if !s.episodes.isEmpty { d.servers.append(s) }
            }
        }
        return d
    }

    // MARK: - Parsing

    private static func parseItems(_ items: [[String: Any]]) -> [Movie] {
        items.compactMap { o in
            let m = parseMovie(o)
            return m.slug.isEmpty ? nil : m
        }
    }

    private static func parseMovie(_ o: [String: Any]) -> Movie {
        var m = Movie()
        m.name = localized(o, "title")
        let en = localized(o, "title", locale: "en")
        m.originName = (en.isEmpty || en == m.name) ? "" : en
        m.slug = JSON.str(o, "slug")
        m.poster = posterURL(o)
        let y = JSON.int(o, "year")
        m.year = y > 0 ? String(y) : ""
        switch JSON.str(o, "mediaType") {
        case "tv": m.type = "series"
        case "movie": m.type = "single"
        default: m.type = JSON.str(o, "mediaType")
        }
        m.episodeCurrent = episodeCurrent(o)
        m.quality = cleanField(JSON.str(o, "maxRes"))
        m.lang = langLine(o)
        m.provider = Providers.F4K
        return m
    }

    /// Card progress fragment: series carry "Tập N" (or
    /// "Tập N/M" while airing); movies read "Full" like KKPhim's
    /// phim-lẻ cards do.
    private static func episodeCurrent(_ o: [String: Any]) -> String {
        if JSON.str(o, "mediaType") == "movie" { return "Full" }
        let count = JSON.int(o, "epCount"), total = JSON.int(o, "epTotal")
        if count > 0 {
            return (total > count) ? "Tập \(count)/\(total)" : "Tập \(count)"
        }
        return total > 0 ? "Tập \(total)" : ""
    }

    /// "Vietsub" / "Thuyết minh" from the site's own flags — the
    /// same vocabulary the KKPhim lang field uses.
    private static func langLine(_ o: [String: Any]) -> String {
        var parts: [String] = []
        if boolField(o, "viSubs") { parts.append("Vietsub") }
        if boolField(o, "viDub") { parts.append("Thuyết minh") }
        return parts.joined(separator: " · ")
    }

    /// Deterministic episode display names from the (season,
    /// episode) pair — resume keys hold these names, so the same
    /// pair must always produce the same string. Season 1 reads
    /// "Tập N"; later seasons "S2 · Tập N" (episodeNumber() takes
    /// the LAST integer run, so cross-provider matching still
    /// lands on N).
    private static func epName(season: Int, episode: Int) -> String {
        let n = episode > 0 ? episode : 1
        return season > 1 ? "S\(season) · Tập \(n)" : "Tập \(n)"
    }

    // MARK: - Localised-field helpers

    /// Film4K localises display fields as {en, vi} dicts. Read the
    /// requested locale (Vietnamese first by default — the app's
    /// audience), falling back to the other locale, and tolerate a
    /// plain string in place of the dict.
    private static func localized(_ obj: [String: Any]?, _ key: String,
                                  locale: String = "vi") -> String {
        guard let obj else { return "" }
        if let dict = JSON.obj(obj, key) {
            let first = cleanField(JSON.str(dict, locale))
            if !first.isEmpty { return first }
            return cleanField(JSON.str(dict, locale == "vi" ? "en" : "vi"))
        }
        return cleanField(JSON.str(obj, key))
    }

    private static func localizedArray(_ obj: [String: Any]?, _ key: String) -> [String] {
        guard let dict = JSON.obj(obj, key) else { return [] }
        for locale in ["vi", "en"] {
            if let a = dict[locale] as? [Any] {
                let strs = a.compactMap { $0 as? String }
                    .map { cleanField($0) }.filter { !$0.isEmpty }
                if !strs.isEmpty { return strs }
            }
        }
        return []
    }

    private static func posterURL(_ o: [String: Any]) -> String {
        if let dict = JSON.obj(o, "poster") {
            let vi = JSON.str(dict, "vi")
            if !vi.isEmpty { return vi }
            return JSON.str(dict, "en")
        }
        return JSON.str(o, "poster")
    }

    private static func boolField(_ o: [String: Any], _ key: String) -> Bool {
        if let b = o[key] as? Bool { return b }
        if let n = o[key] as? NSNumber { return n.boolValue }
        return false
    }

    /// Stream paths arrive site-relative ("/api/hls/<token>/…").
    private static func absURL(_ path: String) -> String {
        if path.isEmpty || path.hasPrefix("http") { return path }
        return base + (path.hasPrefix("/") ? path : "/" + path)
    }
}
