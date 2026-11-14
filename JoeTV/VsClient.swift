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

    static func newest(page: Int) async throws -> [Movie] {
        try await listPath("/api/danh-sach/phim-moi-cap-nhat?page=\(page)")
    }

    static func listByType(_ type: String, page: Int) async throws -> [Movie] {
        try await listPath("/api/danh-sach/\(type)?page=\(page)")
    }

    static func search(_ keyword: String) async throws -> [Movie] {
        try await listPath("/api/tim-kiem?keyword=\(JoeHTTP.qenc(keyword))")
    }

    private static func listPath(_ path: String) async throws -> [Movie] {
        let root = try await JoeHTTP.getJSON(base + path)
        let items = JSON.arr(root, "items")
            ?? JSON.arr(JSON.obj(root, "data"), "items") ?? []
        return items.compactMap { o in
            let m = parseMovie(o)
            return m.slug.isEmpty ? nil : m
        }
    }

    static func detail(_ slug: String) async throws -> Detail {
        let root = try await JoeHTTP.getJSON(base + "/api/phim/\(slug)")
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
        let html = try await JoeHTTP.getText(embedURL)
        guard let base = capture(#"baseUrl\s*=\s*"([^"]+)""#, in: html),
              let hash = capture(#"videoHash\s*=\s*"([^"]+)""#, in: html) else {
            throw URLError(.cannotParseResponse)
        }
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        return trimmed + "/stream/" + hash + "/master.m3u8"
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
        m.poster = JSON.str(o, "poster_url")
        if m.poster.isEmpty { m.poster = JSON.str(o, "thumb_url") }
        m.year = cleanField(JSON.str(o, "year"))
        m.type = JSON.str(o, "type")
        m.episodeCurrent = cleanField(JSON.str(o, "episode_current"))
        m.quality = cleanField(JSON.str(o, "quality"))
        m.lang = cleanField(JSON.str(o, "lang"))
        m.provider = Providers.VS
        return m
    }
}
