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

    /// Per-request budget for catalogue (list/search) calls
    /// (was 20 s pre-v1.9).
    private static let listTimeout: TimeInterval = 12
    /// Tuned detail budgets (LATENCY-AUDIT §6): the old single
    /// 20 s detail budget is SPLIT — the API call gets its own
    /// 10 s cap (healthy max 1.54) and the CacheVideo probe
    /// gets its own separate 10 s cap (in
    /// CacheVideo.resolveCap; healthy max 5.40). Neither draws
    /// from the other. SourceHealth fuses tighten within both.
    /// v2.0.8 (P2d): the probe no longer runs inside detail()
    /// at all — see probeCacheVideoServer.
    private static let detailCap: TimeInterval = 10
    /// Tuned Gold embed cap (LATENCY-AUDIT §6): 20 s → 8 s
    /// (healthy max 1.68).
    private static let embedCap: TimeInterval = 8

    static func newestRaw(page: Int) async throws -> [String: Any] {
        try await listJSON(base + "/movies?page=\(page)&limit=24")
    }

    static func newest(page: Int) async throws -> [Movie] {
        parseItems(try await newestRaw(page: page))
    }

    static func listByTypeRaw(_ type: String, page: Int) async throws -> [String: Any] {
        let t = type == "phim-bo" ? "series" : "single,movie"
        return try await listJSON(base + "/movies?page=\(page)&limit=24&type=\(t)")
    }

    /// type: "phim-le" → single,movie; "phim-bo" → series.
    static func listByType(_ type: String, page: Int) async throws -> [Movie] {
        parseItems(try await listByTypeRaw(type, page: page))
    }

    static func search(_ keyword: String) async throws -> [Movie] {
        let root = try await listJSON(
            base + "/movies?search=\(JoeHTTP.qenc(keyword))&page=1&limit=30")
        return parseItems(root)
    }

    /// 1.9.2 (Team 9 item 2): every catalogue (list/search)
    /// fetch rides SourceHealth's list stage — the dynamic
    /// fuse tightens within the 12 s cap and the latch stops
    /// a dead host's list calls from re-burning full caps on
    /// every load. Pre-fix, list calls consulted no health
    /// memory at all.
    private static func listJSON(_ url: String) async throws -> [String: Any] {
        try await SourceHealth.run(
            provider: Providers.TP, stage: .list, url: url, cap: listTimeout
        ) { budget in
            try await JoeHTTP.getJSON(url, timeout: budget)
        }
    }

    /// Internal (not private) so Providers.parseList can re-parse
    /// a cached raw response without a network call.
    static func parseItems(_ root: [String: Any]) -> [Movie] {
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
        // ★ Field names are SWAPPED vs content on this API
        // (live-measured 2026-11-16, 6 newest titles):
        // posterPath* serves the LANDSCAPE 16:9 still
        // (poster_300 = 533×300; poster_original up to
        // 3840×2160) while thumbPath* serves the PORTRAIT
        // 2:3 poster (thumb_300 = 200×300; thumb_original
        // 336×504 … 2000×3000). Map by CONTENT, never by
        // name: poster ← the portrait file, thumb ← the
        // real landscape. The old name-based read put a 16:9
        // bitmap in every 2:3 card — the whole Tủ Phim shelf
        // letterboxed into a band in every theme — and left
        // m.thumb "" for every TP record, so the detail band
        // had no thumb stage either.
        m.poster = JSON.str(o, "thumbPathOriginal")
        if m.poster.isEmpty { m.poster = JSON.str(o, "thumbPath300") }
        m.thumb = JSON.str(o, "posterPathOriginal")
        if m.thumb.isEmpty { m.thumb = JSON.str(o, "posterPath300") }
        m.year = JSON.str(o, "year")
        m.type = JSON.str(o, "type") == "series" ? "phim-bo" : "phim-le"
        m.episodeCurrent = cleanField(JSON.str(o, "episodeCurrent"))
        m.quality = cleanField(JSON.str(o, "quality"))
        m.lang = cleanField(JSON.str(o, "lang"))
        // UI-5-FIXUP (filter facets): the list payload carries
        // categories[] and countries[] name lists the parser used
        // to drop — read them into the shared Movie fields so the
        // browse filter's country facet and the anime flag (the
        // type mapping above folds "hoathinh" into "phim-le") work
        // for Tủ Phim too. Additive only; absent keys leave the
        // fields empty.
        m.categories = (JSON.arr(o, "categories") ?? [])
            .map { cleanField(JSON.str($0, "name")) }.filter { !$0.isEmpty }
        m.country = (JSON.arr(o, "countries") ?? [])
            .map { cleanField(JSON.str($0, "name")) }.filter { !$0.isEmpty }
            .joined(separator: " · ")
        m.imdbId = JSON.str(o, "imdbId")
        m.tmdbSeason = JSON.int(o, "tmdbSeason")
        // FIX4 (fix 8): the TMDB id itself was never read
        // here — parseMovie read tmdbSeason and imdbId but
        // left tmdbId "", so a Tủ Phim detail (the TVB tab's
        // home provider) could not feed the Film4K leg's
        // TMDB-id acceptance in Providers.searchSlug, and
        // the leg starved on exactly the titles it was wired
        // for. Read tolerantly in both shapes this payload
        // family uses — the flat field (Film4K's shape) and
        // the KK-style tmdb object; a numeric 0 is the
        // family's missing-value marker. Absent in both, the
        // field stays "" and behaviour is unchanged.
        let flatTmdbId = cleanField(JSON.str(o, "tmdbId"))
        if !flatTmdbId.isEmpty && flatTmdbId != "0" {
            m.tmdbId = flatTmdbId
        } else if let tm = JSON.obj(o, "tmdb") {
            let objTmdbId = cleanField(JSON.str(tm, "id"))
            if !objTmdbId.isEmpty && objTmdbId != "0" {
                m.tmdbId = objTmdbId
            }
            if m.tmdbType.isEmpty {
                m.tmdbType = cleanField(JSON.str(tm, "type"))
            }
        }
        m.provider = Providers.TP
        return m
    }

    // MARK: - Detail

    /// Episode template stash (v2.0.8, P2d): detail()
    /// computes the episode template (Gold episodes, or the
    /// templateEpisodes fallback) and the CacheVideo probe —
    /// now a SEPARATE call (probeCacheVideoServer) — needs
    /// that same template later to rebuild the server.
    /// Lock-guarded, keyed by slug, in-memory only; it holds
    /// episode NAMES/templates, never stream URLs.
    private static let templateLock = NSLock()
    private static var templateStash: [String: [Episode]] = [:]

    private static func stashTemplate(slug: String, template: [Episode]?) {
        guard let template, !template.isEmpty else { return }
        templateLock.lock()
        templateStash[slug] = template
        templateLock.unlock()
    }

    private static func stashedTemplate(slug: String) -> [Episode]? {
        templateLock.lock()
        defer { templateLock.unlock() }
        return templateStash[slug]
    }

    static func detail(_ slug: String) async throws -> Detail {
        let url = base + "/movies/\(slug)"
        let root = try await SourceHealth.run(
            provider: Providers.TP, stage: .detail, url: url, cap: detailCap
        ) { budget in
            try await JoeHTTP.getJSON(url, timeout: budget)
        }
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

        // v2.0.8 (P2d): the CacheVideo probe NO LONGER rides
        // the detail call — detail returns after the Gold
        // episode pages, and the detail screen merges the
        // probe result (probeCacheVideoServer) when it lands.
        // The template computed here is stashed by slug so
        // the probe can rebuild the server later.
        stashTemplate(slug: slug, template: template)
        return d
    }

    /// The separated CacheVideo probe (v2.0.8, P2d): build
    /// the "CacheVideo" backup server for a detail that has
    /// already loaded, or nil when CacheVideo does not carry
    /// the title. Guards exactly like the old in-detail call
    /// site: nil when the movie's imdbId is empty, and
    /// cacheVideoServer itself returns nil when the resolver
    /// does not carry the title. The episode template comes
    /// from the stash detail() left for this slug when
    /// present, else from the Gold server's episodes in the
    /// passed detail; a series with neither gets nil (the
    /// movie case needs no template).
    static func probeCacheVideoServer(detail: Detail, slug: String) async -> Server? {
        guard !detail.movie.imdbId.isEmpty else { return nil }
        let template: [Episode]?
        if let stashed = stashedTemplate(slug: slug) {
            template = stashed
        } else if let gold = detail.servers.first(where: { $0.name == "Gold" }) {
            template = gold.episodes
        } else {
            template = nil
        }
        return await cacheVideoServer(movie: detail.movie, template: template)
    }

    private static func findSource(_ sources: [[String: Any]], prefix: String) -> [String: Any]? {
        sources.first { JSON.str($0, "nickname").hasPrefix(prefix) }
    }

    /// Gold episodes: detail page 1 + /episodes pages until the
    /// pagination total is collected (cap 20 pages).
    ///
    /// v2.0.8 (P2d): pages 2…N are fetched CONCURRENTLY in a
    /// throwing task group and appended IN PAGE ORDER. The
    /// stop conditions are preserved: no page beyond
    /// totalPages, none beyond the 20-page cap, no fetch at
    /// all when idx < 0 or page 1 already collected the
    /// total, and appending stops in page order once the
    /// total is collected (the serial loop's before-fetch
    /// `out.count < total` check, applied at append time).
    /// Every page keeps its SourceHealth wrapping and 10 s
    /// stage cap, and failure semantics are unchanged: any
    /// page error throws out of the group, goldEpisodes
    /// throws, and detail() treats Gold as absent via its
    /// `(try? …) ?? []`.
    private static func goldEpisodes(slug: String, gold: [String: Any]) async throws -> [Episode] {
        var out: [Episode] = []
        appendEpisodes(&out, JSON.arr(gold, "episodes"))
        let pg = JSON.obj(gold, "episodePagination")
        let total = JSON.int(pg, "total", out.count)
        let totalPages = JSON.int(pg, "totalPages", 1)
        let idx = JSON.int(gold, "sourceIndex", -1)
        guard idx >= 0, out.count < total else { return out }
        let lastPage = min(totalPages, 20)
        guard lastPage >= 2 else { return out }
        let pages = Array(2...lastPage)
        var byPage: [Int: [String: Any]] = [:]
        try await withThrowingTaskGroup(of: (Int, [String: Any]).self) { group in
            for p in pages {
                group.addTask {
                    // Gold episode paging is part of the detail's API
                    // work — same 10 s stage cap as the detail call.
                    let pageURL = TpClient.base
                        + "/movies/\(slug)/episodes?sourceIndex=\(idx)&page=\(p)&limit=100"
                    let r = try await SourceHealth.run(
                        provider: Providers.TP, stage: .detail, url: pageURL, cap: TpClient.detailCap
                    ) { budget in
                        try await JoeHTTP.getJSON(pageURL, timeout: budget)
                    }
                    return (p, r)
                }
            }
            for try await (p, r) in group {
                byPage[p] = r
            }
        }
        for p in pages {
            if out.count >= total { break }
            appendEpisodes(&out, JSON.arr(JSON.obj(byPage[p], "data"), "episodes"))
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
    /// the title. Internal (not private) so the separated
    /// probeCacheVideoServer — and any other caller — reuses
    /// this exact construction.
    static func cacheVideoServer(movie: Movie, template: [Episode]?) async -> Server? {
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
        let embedURL = base + "/embed/\(hash)"
        // The status check lives INSIDE the measured closure:
        // a dead hash's 404 (audit §3.1: declares in ≈1.2 s)
        // records as an instant-fail sample, not a success.
        let raw = try await SourceHealth.run(
            provider: Providers.TP, stage: .resolve, url: embedURL, cap: embedCap
        ) { budget in
            let r = try await getNoRedirect(embedURL, timeout: budget)
            guard r.status == 200 || (300..<400).contains(r.status) else {
                throw URLError(.badServerResponse)
            }
            return r
        }
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

    private static func getNoRedirect(_ urlString: String,
                                      timeout: TimeInterval) async throws -> RawResponse {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
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
