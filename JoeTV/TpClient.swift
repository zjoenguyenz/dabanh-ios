import Foundation

/// Tủ Phim client — public API at api.phimsrv.com/v1 (official
/// site tuphim.org). Swift port of the Android TpApi (Joe TV
/// v1.7 → v1.9.2, device-verified on the Sony + dad's box
/// 2026-11-14). Catalogue shapes re-measured live 2026-11-14:
///   GET /v1/movies?page&limit&type=single,movie|series|search=…
///     → {ok, data:{items[]}} — the largest catalogue measured
///     (~48.9k titles). vipOnly titles are filtered out of
///     rails/search (their playback is unproven).
///   GET /v1/movies/{slug} → {ok, data:{movie, categories,
///     watchSources[]}}. Each watchSource wears a nickname:
///     "Gold"    — the genuinely independent layer: episodes
///                 resolve via /v1/embed/{hash} to direct HLS.
///                 THE server this provider ships.
///     "Diamond" — the KKPhim-family CDN in disguise: NOT
///                 surfaced (zero independence over KK).
///     "Master"  — StreamC embed pages only: NOT surfaced.
///   Gold episodes beyond page 1 are paged in via
///   /v1/movies/{slug}/episodes?sourceIndex&page.
///
/// Gold resolution (marker "tp:" + hash): GET /v1/embed/{hash}
/// WITHOUT following redirects →
///   • 200 HTML carrying a base64 publicKey + a hex
///     encrypted_url: the playlist URL is the byte-wise XOR of
///     the hex-decoded ciphertext with the repeating key — the
///     publicKey STRING's own bytes, NOT its base64 decoding
///     (the Android harness caught exactly that bug in v1.7).
///   • 3xx: some titles' Gold episode is a VSMOV video page in
///     disguise — the Location goes to the VSMOV resolver (or is
///     returned directly when it is already an .m3u8).
/// A Gold episode whose payload carries an embedUrl outright
/// gets marker "tpv:" + that URL and resolves via VSMOV too.
///
/// ★ JSON-null law (Android v1.9.2 root cause): this API sends
/// "embedUrl": null on hash-only Gold episodes. The house JSON
/// reader (JoeModels.JSON) returns the fallback for NSNull, so
/// the marker can never become the literal string "null" here —
/// keep it that way: never read these fields raw.
///
/// CacheVideo: the detail's imdbId keys a probe of the
/// CacheVideo resolver; when it carries the title, an extra
/// "CacheVideo" server is attached (markers "cv:{imdb}|{season}
/// |{ep}", resolved per-episode at ladder time).
enum TpClient {
    static let base = "https://api.phimsrv.com/v1"

    // MARK: - Catalogue

    static func newest(page: Int) async throws -> [Movie] {
        let root = try await JoeHTTP.getJSON(
            base + "/movies?page=\(page)&limit=24", timeout: 20)
        return parseItems(root)
    }

    /// type: "phim-le" → single,movie; "phim-bo" → series.
    static func listByType(_ type: String, page: Int) async throws -> [Movie] {
        let t = type == "phim-bo" ? "series" : "single,movie"
        let root = try await JoeHTTP.getJSON(
            base + "/movies?page=\(page)&limit=24&type=\(t)", timeout: 20)
        return parseItems(root)
    }

    static func search(_ keyword: String) async throws -> [Movie] {
        let root = try await JoeHTTP.getJSON(
            base + "/movies?search=\(JoeHTTP.qenc(keyword))&page=1&limit=30",
            timeout: 20)
        return parseItems(root)
    }

    private static func parseItems(_ root: [String: Any]) -> [Movie] {
        let items = JSON.arr(JSON.obj(root, "data"), "items") ?? []
        return items.compactMap { o in
            if JSON.bool(o, "vipOnly") { return nil }
            let m = parseMovie(o)
            return m.slug.isEmpty ? nil : m
        }
    }

    private static func parseMovie(_ o: [String: Any]) -> Movie {
        var m = Movie()
        m.name = JSON.str(o, "name").trimmingCharacters(in: .whitespaces)
        m.originName = JSON.str(o, "originName").trimmingCharacters(in: .whitespaces)
        m.slug = JSON.str(o, "primarySlug")
        m.poster = JSON.str(o, "posterPath300")
        if m.poster.isEmpty { m.poster = JSON.str(o, "posterPathOriginal") }
        m.year = JSON.str(o, "year")
        m.type = JSON.str(o, "type") == "series" ? "phim-bo" : "phim-le"
        m.episodeCurrent = cleanField(JSON.str(o, "episodeCurrent"))
        m.quality = cleanField(JSON.str(o, "quality"))
        m.lang = cleanField(JSON.str(o, "lang"))
        m.imdbId = JSON.str(o, "imdbId")
        m.tmdbSeason = JSON.int(o, "tmdbSeason")
        m.provider = Providers.TP
        return m
    }

    // MARK: - Detail

    static func detail(_ slug: String) async throws -> Detail {
        let root = try await JoeHTTP.getJSON(base + "/movies/\(slug)", timeout: 20)
        var d = Detail()
        guard let data = JSON.obj(root, "data"),
              let mo = JSON.obj(data, "movie") else { return d }
        d.movie = parseMovie(mo)
        d.content = stripHTML(JSON.str(mo, "content"))
        var meta: [String] = []
        if !d.movie.year.isEmpty { meta.append(d.movie.year) }
        if !d.movie.quality.isEmpty { meta.append(d.movie.quality) }
        if !d.movie.lang.isEmpty { meta.append(d.movie.lang) }
        let time = cleanField(JSON.str(mo, "time"))
        if !time.isEmpty { meta.append(time) }
        if !d.movie.episodeCurrent.isEmpty {
            meta.append("Đang chiếu: \(d.movie.episodeCurrent)")
        }
        d.metaLine = joinParts(meta, "  ·  ")
        if let cats = JSON.arr(data, "categories") {
            d.categories = joinParts(cats.map { JSON.str($0, "name") }, ", ")
        }
        let sources = JSON.arr(data, "watchSources") ?? []

        // Gold — the one independent layer this provider ships.
        var template: [Episode]?
        if let gold = findSource(sources, prefix: "Gold") {
            var s = Server()
            s.name = "Gold"
            s.episodes = (try? await goldEpisodes(slug: slug, gold: gold)) ?? []
            if !s.episodes.isEmpty {
                d.servers.append(s)
                template = s.episodes
            }
        }
        if template == nil { template = templateEpisodes(sources) }

        // CacheVideo — backup server on the titles it carries.
        if !d.movie.imdbId.isEmpty,
           let cv = await cacheVideoServer(movie: d.movie, template: template) {
            d.servers.append(cv)
        }
        return d
    }

    private static func findSource(_ sources: [[String: Any]], prefix: String) -> [String: Any]? {
        sources.first { JSON.str($0, "nickname").hasPrefix(prefix) }
    }

    /// Gold episodes: detail page 1 + /episodes pages until the
    /// pagination total is collected (cap 20 pages).
    private static func goldEpisodes(slug: String, gold: [String: Any]) async throws -> [Episode] {
        var out: [Episode] = []
        appendEpisodes(&out, JSON.arr(gold, "episodes"))
        let pg = JSON.obj(gold, "episodePagination")
        let total = JSON.int(pg, "total", out.count)
        let totalPages = JSON.int(pg, "totalPages", 1)
        let idx = JSON.int(gold, "sourceIndex", -1)
        var p = 2
        while p <= totalPages && out.count < total && p <= 20 && idx >= 0 {
            let r = try await JoeHTTP.getJSON(
                base + "/movies/\(slug)/episodes?sourceIndex=\(idx)&page=\(p)&limit=100",
                timeout: 20)
            appendEpisodes(&out, JSON.arr(JSON.obj(r, "data"), "episodes"))
            p += 1
        }
        return out
    }

    private static func appendEpisodes(_ out: inout [Episode], _ eps: [[String: Any]]?) {
        guard let eps else { return }
        for e in eps {
            var ep = Episode()
            ep.name = Providers.canonEpName(JSON.str(e, "name"), position: out.count + 1)
            // NSNull-safe via the house JSON reader: a JSON null
            // embedUrl reads as "" here, never the literal "null"
            // (the Android v1.9.2 bug — see the header note).
            let embedUrl = JSON.str(e, "embedUrl")
            let hash = JSON.str(e, "hash")
            if !embedUrl.isEmpty {
                ep.embed = "tpv:" + embedUrl
            } else if !hash.isEmpty {
                ep.embed = "tp:" + hash
            } else {
                continue // no resolvable identity — never ships
            }
            out.append(ep)
        }
    }

    /// Episode names from the first source that carries any —
    /// the template the CacheVideo server mirrors when Gold is
    /// absent (Diamond/Master lists are name-identical).
    private static func templateEpisodes(_ sources: [[String: Any]]) -> [Episode]? {
        for s in sources {
            guard let eps = JSON.arr(s, "episodes"), !eps.isEmpty else { continue }
            var out: [Episode] = []
            for e in eps {
                var ep = Episode()
                ep.name = Providers.canonEpName(JSON.str(e, "name"), position: out.count + 1)
                out.append(ep)
            }
            if !out.isEmpty { return out }
        }
        return nil
    }

    /// Probe the CacheVideo resolver once (S1E1 for series, the
    /// movie otherwise); build the server only when it carries
    /// the title.
    private static func cacheVideoServer(movie: Movie, template: [Episode]?) async -> Server? {
        let series = movie.type == "phim-bo"
        let season = movie.tmdbSeason > 0 ? movie.tmdbSeason : 1
        let probe = await CacheVideo.resolve(
            imdbId: movie.imdbId, season: series ? season : 0, episode: 1)
        guard probe != nil else { return nil }
        var cv = Server()
        cv.name = "CacheVideo"
        if !series {
            var e = Episode()
            e.name = "Full"
            e.embed = "cv:\(movie.imdbId)|0|0"
            cv.episodes.append(e)
        } else {
            guard let template, !template.isEmpty else { return nil }
            for (i, t) in template.enumerated() {
                let parsed = Providers.episodeNumber(t.name)
                let num = parsed > 0 ? parsed : i + 1
                var e = Episode()
                e.name = t.name
                e.embed = "cv:\(movie.imdbId)|\(season)|\(num)"
                cv.episodes.append(e)
            }
        }
        return cv.episodes.isEmpty ? nil : cv
    }

    // MARK: - Playback resolution

    /// Resolve one TP episode marker to a fresh playlist URL.
    /// Markers: "tp:{hash}" (Gold XOR / redirect), "tpv:{url}"
    /// (VSMOV video page), "cv:{imdb}|{season}|{ep}" (CacheVideo).
    static func resolveStream(marker: String) async throws -> String {
        if marker.isEmpty { throw URLError(.badURL) }
        if marker.hasPrefix("cv:") {
            let p = marker.dropFirst(3).split(separator: "|").map(String.init)
            guard p.count >= 3 else { throw URLError(.badURL) }
            guard let url = await CacheVideo.resolve(
                imdbId: p[0], season: Int(p[1]) ?? 0, episode: Int(p[2]) ?? 0)
            else { throw URLError(.resourceUnavailable) }
            return url
        }
        if marker.hasPrefix("tpv:") {
            return try await VsClient.resolveStream(embedURL: String(marker.dropFirst(4)))
        }
        if marker.hasPrefix("tp:") {
            return try await resolveGold(hash: String(marker.dropFirst(3)))
        }
        if marker.contains(".m3u8") { return marker }
        throw URLError(.badURL)
    }

    /// The Gold hop: /v1/embed/{hash} without following
    /// redirects. 200 → XOR-decode the page's key/ciphertext
    /// pair; 3xx → the Location is a VSMOV video page (resolve
    /// via VsClient) or already a playlist.
    private static func resolveGold(hash: String) async throws -> String {
        let raw = try await getNoRedirect(base + "/embed/\(hash)")
        if (300..<400).contains(raw.status) {
            guard let loc = raw.location, !loc.isEmpty else {
                throw URLError(.badServerResponse)
            }
            return try await resolveIndirect(loc)
        }
        guard raw.status == 200 else { throw URLError(.badServerResponse) }
        guard let key = capture(#"publicKey"?\s*[:=]\s*"([A-Za-z0-9+/=]+)""#, in: raw.body),
              let enc = capture(#"encrypted_url"?\s*[:=]\s*"([0-9a-fA-F]+)""#, in: raw.body),
              let url = xorDecode(publicKey: key, hex: enc) else {
            throw URLError(.cannotParseResponse)
        }
        return try await resolveIndirect(url)
    }

    private static func resolveIndirect(_ u: String) async throws -> String {
        if u.contains(".m3u8") { return u }
        if u.contains("vsmov") || u.contains("/video/") {
            return try await VsClient.resolveStream(embedURL: u)
        }
        return u
    }

    /// The Gold cipher: ciphertext = hex pairs;
    /// plain[i] = cipher[i] XOR key[i mod key.length], where the
    /// key is the publicKey STRING's own bytes — NOT its base64
    /// decoding (measured live 2026-11-14: decoding the key first
    /// yields garbage; the string-bytes key yields the playlist).
    static func xorDecode(publicKey: String, hex: String) -> String? {
        let key = Array(publicKey.utf8)
        guard !key.isEmpty else { return nil }
        let chars = Array(hex)
        var out: [UInt8] = []
        out.reserveCapacity(chars.count / 2)
        var i = 0
        while i + 1 < chars.count {
            guard let b = UInt8(String(chars[i...i + 1]), radix: 16) else { return nil }
            out.append(b ^ key[out.count % key.count])
            i += 2
        }
        return String(bytes: out, encoding: .utf8)
    }

    // MARK: - No-redirect fetch (the embed hop must see the 3xx)

    private struct RawResponse {
        var status: Int
        var location: String?
        var body: String
    }

    private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private static let noRedirectSession = URLSession(
        configuration: .default, delegate: NoRedirectDelegate(), delegateQueue: nil)

    private static func getNoRedirect(_ urlString: String) async throws -> RawResponse {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(JoeHTTP.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await noRedirectSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return RawResponse(
            status: http.statusCode,
            location: http.value(forHTTPHeaderField: "Location"),
            body: String(data: data, encoding: .utf8) ?? "")
    }

    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
}
