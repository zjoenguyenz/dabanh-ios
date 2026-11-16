import Foundation

/// VSMOV public API client (https://vsmov.com) — port of the
/// Android VsApi. An independent provider: its own catalogue API
/// and its own stream CDN (streamvsmov.com), nothing shared with
/// the KKPhim family. No auth. Shapes verified live on Android
/// (2026-11-13):
///   GET /api/danh-sach/phim-moi-cap-nhat?page=N → {items:[…]} at root
///   GET /api/danh-sach/{type}?page=N   type ∈ phim-bo|phim-le|hoat-hinh|tv-shows
///   GET /api/tim-kiem?keyword=…
///   GET /api/phim/{slug} → {movie:{…}, episodes:[{server_name,
///        server_data:[{name, link_embed}]}]}
/// Episode names are BARE NUMBERS ("1") — canonicalized to "Tập 1"
/// at parse time. link_m3u8 is empty on this provider: streams
/// exist only behind the embed page (see resolveStream).
enum VsClient {
    static let base = "https://vsmov.com"
    /// Per-request budget for catalogue (list/search) calls.
    private static let listTimeout: TimeInterval = 12
    /// Tuned stage caps (LATENCY-AUDIT §6): detail 25 s →
    /// 10 s (healthy max 1.87), resolve 25 s → 8 s (healthy
    /// embed max 1.26; the v1/v6 black-hole class now declares
    /// in 8 s instead of 25). Both are CAPS — SourceHealth's
    /// dynamic fuse may only tighten within them.
    private static let detailCap: TimeInterval = 10
    private static let resolveCap: TimeInterval = 8

    static func newestRaw(page: Int) async throws -> [String: Any] {
        try await listJSON(base + "/api/danh-sach/phim-moi-cap-nhat?page=\(page)")
    }

    static func newest(page: Int) async throws -> [Movie] {
        parseList(try await newestRaw(page: page))
    }

    static func listByTypeRaw(_ type: String, page: Int) async throws -> [String: Any] {
        try await listJSON(base + "/api/danh-sach/\(type)?page=\(page)")
    }

    static func listByType(_ type: String, page: Int) async throws -> [Movie] {
        parseList(try await listByTypeRaw(type, page: page))
    }

    static func search(_ keyword: String) async throws -> [Movie] {
        try await listPath("/api/tim-kiem?keyword=\(JoeHTTP.qenc(keyword))")
    }

    private static func listPath(_ path: String) async throws -> [Movie] {
        let root = try await listJSON(base + path)
        return parseList(root)
    }

    /// 1.9.2 (Team 9 item 2): every catalogue (list/search)
    /// fetch rides SourceHealth's list stage — the dynamic
    /// fuse tightens within the 12 s cap and the latch stops
    /// a dead host's list calls from re-burning full caps on
    /// every load. Pre-fix, list calls consulted no health
    /// memory at all.
    private static func listJSON(_ url: String) async throws -> [String: Any] {
        try await SourceHealth.run(
            provider: Providers.VS, stage: .list, url: url, cap: listTimeout
        ) { budget in
            try await JoeHTTP.getJSON(url, timeout: budget)
        }
    }

    /// Parse a list response body — also used by
    /// Providers.parseList to re-parse a cached raw response.
    static func parseList(_ root: [String: Any]) -> [Movie] {
        let items = JSON.arr(root, "items")
            ?? JSON.arr(JSON.obj(root, "data"), "items") ?? []
        return items.compactMap { o in
            let m = parseMovie(o)
            return m.slug.isEmpty ? nil : m
        }
    }

    static func detail(_ slug: String) async throws -> Detail {
        let url = base + "/api/phim/\(slug)"
        let root = try await SourceHealth.run(
            provider: Providers.VS, stage: .detail, url: url, cap: detailCap
        ) { budget in
            try await JoeHTTP.getJSON(url, timeout: budget)
        }
        var d = Detail()
        var item = JSON.obj(root, "movie")
        if item == nil { item = JSON.obj(JSON.obj(root, "data"), "item") }
        guard let item else { return d }
        d.movie = parseMovie(item)
        d.content = stripHTML(JSON.str(item, "content"))
        var meta: [String] = []
        if !d.movie.year.isEmpty { meta.append(d.movie.year) }
        let q = cleanField(JSON.str(item, "quality")); if !q.isEmpty { meta.append(q) }
        let lang = cleanField(JSON.str(item, "lang")); if !lang.isEmpty { meta.append(lang) }
        let time = cleanField(JSON.str(item, "time")); if !time.isEmpty { meta.append(time) }
        let ep = cleanField(JSON.str(item, "episode_current"))
        if !ep.isEmpty { meta.append("Đang chiếu: \(ep)") }
        d.metaLine = joinParts(meta, "  ·  ")
        if let cats = JSON.arr(item, "category") {
            d.categories = joinParts(cats.map { JSON.str($0, "name") }, ", ")
        }
        for sj in JSON.arr(root, "episodes") ?? [] {
            var s = Server()
            s.name = JSON.str(sj, "server_name", "Server")
            let data = JSON.arr(sj, "server_data") ?? []
            for (j, ej) in data.enumerated() {
                var e = Episode()
                e.name = Providers.canonEpName(JSON.str(ej, "name"), position: j + 1)
                e.m3u8 = JSON.str(ej, "link_m3u8")
                e.embed = JSON.str(ej, "link_embed")
                s.episodes.append(e)
            }
            if !s.episodes.isEmpty { d.servers.append(s) }
        }
        return d
    }

    // MARK: - Stream resolution (embed page → master playlist)

    /// The embed page carries two JS vars — baseUrl and videoHash —
    /// and the playable playlist is {baseUrl}/stream/{videoHash}/
    /// master.m3u8 (verified live on Android: the composed master
    /// answered 200). Resolved FRESH at every play tap — nothing is
    /// cached: stream URLs are plumbing, never stored.
    static func resolveStream(embedURL: String) async throws -> String {
        // The parse lives INSIDE the measured closure: an
        // answering-but-useless embed page (the 200 error-page
        // class, audit §3.1) records as an instant-fail sample,
        // not as a healthy fast call.
        try await SourceHealth.run(
            provider: Providers.VS, stage: .resolve, url: embedURL, cap: resolveCap
        ) { budget in
            let html = try await JoeHTTP.getText(embedURL, timeout: budget)
            guard let base = capture(#"baseUrl\s*=\s*"([^"]+)""#, in: html),
                  let hash = capture(#"videoHash\s*=\s*"([^"]+)""#, in: html) else {
                throw URLError(.cannotParseResponse)
            }
            let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
            return trimmed + "/stream/" + hash + "/master.m3u8"
        }
    }

    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    private static func parseMovie(_ o: [String: Any]) -> Movie {
        var m = Movie()
        m.name = JSON.str(o, "name")
        m.slug = JSON.str(o, "slug")
        m.originName = JSON.str(o, "origin_name")
        // ★ Field names are SWAPPED vs content on this API
        // (live-measured 2026-11-16, 5 titles incl. Love
        // Bound): poster_url serves the LANDSCAPE 16:9 still
        // (1280×720 … 3840×2160 — aspect 1.778 on every
        // sample) while thumb_url serves the PORTRAIT poster
        // (701×1000 … 2000×3000 — aspect 0.667–0.750). Map
        // by CONTENT, never by name — the same fix TpClient
        // took for the same disease. The old name-based read
        // put a 16:9 bitmap in the portrait field of every
        // VS record: the slot aspect gate rejected it and
        // the card/detail silently fell back to the TMDB
        // poster. parseMovie is the ONE mapping site — the
        // list/search parsers and detail() all flow through
        // it, so this swap covers every surface.
        m.poster = JSON.str(o, "thumb_url")
        m.thumb = JSON.str(o, "poster_url")
        // NO silent thumb→poster substitution (removed
        // 2026-11-16, same law as KkClient): a landscape thumb
        // copied into the portrait field letterboxes into a
        // band in the card and is indistinguishable downstream.
        // An empty poster stays empty so the slot's declared
        // fallback ladder (JoeRemoteImage slot-class gate) runs.
        m.year = cleanField(JSON.str(o, "year"))
        m.type = JSON.str(o, "type")
        m.episodeCurrent = cleanField(JSON.str(o, "episode_current"))
        m.quality = cleanField(JSON.str(o, "quality"))
        m.lang = cleanField(JSON.str(o, "lang"))
        // UI-6 D-2: VS is KK-shaped — same list extras as KK.
        if let cats = JSON.arr(o, "category") {
            m.categories = cats.map { cleanField(JSON.str($0, "name")) }
                .filter { !$0.isEmpty }
        }
        if let countries = JSON.arr(o, "country") {
            m.country = joinParts(countries.map { JSON.str($0, "name") }, " · ")
        }
        m.time = cleanField(JSON.str(o, "time"))
        m.episodeTotal = cleanField(JSON.str(o, "episode_total"))
        m.chieurap = JSON.bool(o, "chieurap")
        // v2.0.2 (P2 — mirror of Android FIX5): VS payloads are
        // KK-shaped and carry the same identity objects —
        // measured live on Android, the VS Die Hard detail
        // carries tmdb {type:"movie", id:"562"} and imdb
        // {id:"tt0095016"} — and this parser read NEITHER, so
        // a VS film's TMDB identity was dropped (with it the
        // detail screen's IMDb derivation when the imdb
        // object is absent) and its IMDb id never landed at
        // all: a VS-only title had no torrent identity. Same
        // tolerant blocks as KkClient (cleanField = the house
        // null discipline for every identity field).
        if let tm = JSON.obj(o, "tmdb") {
            m.tmdbId = cleanField(JSON.str(tm, "id"))
            m.tmdbType = cleanField(JSON.str(tm, "type"))
            let season = JSON.int(tm, "season")
            if season > 0 { m.tmdbSeason = season }
        }
        if m.imdbId.isEmpty, let im = JSON.obj(o, "imdb") {
            let idv = cleanField(JSON.str(im, "id"))
            if !idv.isEmpty { m.imdbId = idv }
        }
        m.provider = Providers.VS
        return m
    }
}
