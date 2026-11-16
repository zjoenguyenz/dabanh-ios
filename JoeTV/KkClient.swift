import Foundation

/// KKPhim public API client — port of the Android KkApi, host
/// failover included. Two hosts serve the identical KKPhim-format
/// catalogue; every call RACES them in parallel and the first
/// SHAPE-VALID answer wins (the losers are cancelled):
///   (a) https://phimapi.com               — "/v1/api/..." flavour
///   (b) https://free.cryboiz.workers.dev  — bare-path flavour
/// "Valid" is strict: the body must parse AND carry the expected
/// container (items array for lists/search, a movie object for
/// detail) — a {"status":false} stub does not count.
///
/// The pre-v1.9 SEQUENTIAL failover (try in order, 25 s each) is
/// gone: on a hanging route one call could burn 75 s, and with
/// 17 KK jobs at launch that was the endless-spinner machine.
///
/// Host (c) https://free2.phim4k.dev was REMOVED in v1.9 —
/// measured 2026-11-15 from the VM with the app's User-Agent:
/// every list AND detail path variant tried (/api/danh-sach/…,
/// bare /danh-sach/…, /api/v1/api/…, /v1/api/…, /api/phim/{slug},
/// /phim/{slug}) returns the {"status":false} 404 stub. It could
/// only ever add a wasted attempt. (An earlier version of this
/// comment claimed all three hosts were verified; that claim was
/// stale and is corrected here.)
///
/// Envelopes absorbed (measured live on Android, 2026-11-13):
///   (a) lists: {data:{items:[…], APP_DOMAIN_CDN_IMAGE}}
///       (newest: {items:[…]} at root, absolute posters)
///   (b) lists: {status, items:[…]} at root
///   (a) detail: {data:{item:{…, episodes:[…]}}}
///   (b) detail: {movie:{…}, episodes:[…]} — episodes may carry
///       the stream in a "link" field instead of "link_m3u8".
enum KkClient {
    private static let hosts = [
        "https://phimapi.com",
        "https://free.cryboiz.workers.dev",
    ]
    private static let cdnDefault = "https://phimimg.com"
    /// Per-request budget for catalogue (list/search) calls.
    /// Since 1.9.2 (Team 9 item 2) this is the CAP handed to
    /// SourceHealth's list stage: every list/search call below
    /// races its hosts through fetchJSON's health path, so a
    /// host that black-holes list calls tightens its fuse and
    /// latches instead of re-burning 12 s per rail job on
    /// every load.
    private static let listTimeout: TimeInterval = 12
    /// Tuned detail cap (LATENCY-AUDIT §6): 25 s → 10 s
    /// (healthy detail max 0.91 on host A). Applied PER HOST
    /// inside the race via SourceHealth — each host carries
    /// its own stats key and its own dynamic fuse.
    private static let detailCap: TimeInterval = 10

    /// Session winner of the most recent race; -1 = none yet.
    /// Diagnostics only — every call races all hosts, so no call
    /// depends on this value. Lock-guarded (C-15): races finish
    /// concurrently and the pre-v1.9 plain static var was
    /// unsynchronised shared mutable state.
    private static let hostLock = NSLock()
    private static var _activeHost = -1
    static var activeHost: Int {
        hostLock.lock()
        defer { hostLock.unlock() }
        return _activeHost
    }
    private static func setActiveHost(_ h: Int) {
        hostLock.lock()
        _activeHost = h
        hostLock.unlock()
    }

    // MARK: - Host-race fetch

    /// Race every host in parallel; the first shape-valid body
    /// wins and the losers are cancelled. A fast-but-invalid
    /// answer (the {"status":false} stub class) never wins — it
    /// is recorded as an error and the race runs on. When every
    /// host fails, the last error received is thrown.
    private static func fetchJSON(path: @escaping (Bool) -> String,
                                  shape: @escaping ([String: Any]) -> Bool,
                                  timeout: TimeInterval = 25,
                                  health: (provider: String,
                                           stage: SourceHealth.Stage,
                                           cap: TimeInterval)? = nil)
        async throws -> [String: Any] {
        // CONVERGENCE (Team 6 census A4, 2026-11-15): the race
        // no longer consumes a task group. The old `for await`
        // join awaited EVERY child to actually finish — after
        // cancelAll() a loser whose request ignored cancellation
        // could hold the whole call hostage. Now each host runs
        // in an unstructured task publishing into a lock-guarded
        // box (the findAlternatives pattern): the moment a
        // winner lands, the caller returns it and cancels the
        // losers WITHOUT awaiting them.
        let box = KkRaceBox()
        let tasks = hosts.indices.map { h in
            Task {
                let url = hosts[h] + path(h != 0)
                do {
                    if let health {
                        // Predictor-wired leg (detail):
                        // each host races under its OWN
                        // SourceHealth fuse and records its
                        // own sample. The shape check sits
                        // inside the measured closure, so a
                        // fast-but-invalid stub answer
                        // records as an instant-fail, never
                        // as a healthy call. A cancelled
                        // race loser records nothing.
                        let root = try await SourceHealth.run(
                            provider: health.provider, stage: health.stage,
                            url: url, cap: health.cap
                        ) { budget in
                            let r = try await JoeHTTP.getJSON(url, timeout: budget)
                            guard shape(r) else {
                                throw URLError(.badServerResponse)
                            }
                            return r
                        }
                        box.report(host: h, root: root, error: nil)
                    } else {
                        let root = try await JoeHTTP.getJSON(url, timeout: timeout)
                        if shape(root) {
                            box.report(host: h, root: root, error: nil)
                        } else {
                            box.report(host: h, root: nil,
                                       error: URLError(.badServerResponse))
                        }
                    }
                } catch {
                    box.report(host: h, root: nil, error: error)
                }
            }
        }
        defer { tasks.forEach { $0.cancel() } }
        while true {
            if let winner = box.winner {
                setActiveHost(winner.host)
                return winner.root
            }
            if box.settledCount >= hosts.count {
                throw box.lastError ?? URLError(.cannotConnectToHost)
            }
            if Task.isCancelled { throw CancellationError() }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private static func itemsArray(_ root: [String: Any]) -> [[String: Any]]? {
        if let items = JSON.arr(root, "items") { return items }
        return JSON.arr(JSON.obj(root, "data"), "items")
    }

    private static func detailItem(_ root: [String: Any]) -> [String: Any]? {
        if let movie = JSON.obj(root, "movie") { return movie }
        return JSON.obj(JSON.obj(root, "data"), "item")
    }

    // MARK: - Endpoints

    // List endpoints come in raw + parse pairs: the raw half
    // returns the winning host's response body (PhimStore caches
    // it verbatim and re-parses it on the next launch), the
    // composed half is the pre-v1.9 API. Every list endpoint now
    // honours the bare flag for BOTH hosts — pre-v1.9 newest()
    // silently ignored it and sent the bare path to the
    // /v1/api host too (it happened to work; measured 2026-11-15
    // both flavours answer on phimapi.com, but consistency is
    // what keeps a host's retirement of one flavour from
    // silently breaking a rail).

    static func newestRaw(page: Int) async throws -> [String: Any] {
        try await fetchJSON(
            path: { bare in
                bare ? "/danh-sach/phim-moi-cap-nhat?page=\(page)"
                     : "/v1/api/danh-sach/phim-moi-cap-nhat?page=\(page)"
            },
            shape: { itemsArray($0) != nil },
            health: (Providers.KK, .list, listTimeout))
    }

    static func newest(page: Int) async throws -> [Movie] {
        parseItems(try await newestRaw(page: page))
    }

    /// Typed list rails: phim-bo, phim-le, hoat-hinh, tv-shows…
    static func listByTypeRaw(_ type: String, page: Int) async throws -> [String: Any] {
        try await fetchJSON(
            path: { bare in
                bare ? "/danh-sach/\(type)?page=\(page)"
                     : "/v1/api/danh-sach/\(type)?page=\(page)"
            },
            shape: { itemsArray($0) != nil },
            health: (Providers.KK, .list, listTimeout))
    }

    static func listByType(_ type: String, page: Int) async throws -> [Movie] {
        parseItems(try await listByTypeRaw(type, page: page))
    }

    static func listByGenreRaw(_ slug: String, page: Int) async throws -> [String: Any] {
        try await fetchJSON(
            path: { bare in
                bare ? "/the-loai/\(slug)?page=\(page)"
                     : "/v1/api/the-loai/\(slug)?page=\(page)"
            },
            shape: { itemsArray($0) != nil },
            health: (Providers.KK, .list, listTimeout))
    }

    static func listByGenre(_ slug: String, page: Int) async throws -> [Movie] {
        parseItems(try await listByGenreRaw(slug, page: page))
    }

    static func listByCountryRaw(_ slug: String, page: Int,
                                 limit: Int? = nil) async throws -> [String: Any] {
        let lim = limit.map { "&limit=\($0)" } ?? ""
        return try await fetchJSON(
            path: { bare in
                bare ? "/quoc-gia/\(slug)?page=\(page)\(lim)"
                     : "/v1/api/quoc-gia/\(slug)?page=\(page)\(lim)"
            },
            shape: { itemsArray($0) != nil },
            health: (Providers.KK, .list, listTimeout))
    }

    static func listByCountry(_ slug: String, page: Int) async throws -> [Movie] {
        parseItems(try await listByCountryRaw(slug, page: page))
    }

    /// Country listing with an explicit page size — the dedicated
    /// Vietnam block pulls 48 in one call so it can split series /
    /// single rails client-side from the items' `type` field.
    static func listByCountry(_ slug: String, page: Int, limit: Int) async throws -> [Movie] {
        parseItems(try await listByCountryRaw(slug, page: page, limit: limit))
    }

    static func search(_ keyword: String) async throws -> [Movie] {
        let q = JoeHTTP.qenc(keyword)
        let root = try await fetchJSON(
            path: { bare in
                bare ? "/tim-kiem?keyword=\(q)" : "/v1/api/tim-kiem?keyword=\(q)"
            },
            shape: { itemsArray($0) != nil },
            health: (Providers.KK, .list, listTimeout))
        return parseItems(root)
    }

    static func detail(_ slug: String) async throws -> Detail {
        let root = try await fetchJSON(
            path: { bare in bare ? "/phim/\(slug)" : "/v1/api/phim/\(slug)" },
            shape: { detailItem($0) != nil },
            health: (Providers.KK, .detail, detailCap))
        var d = Detail()
        guard let item = detailItem(root) else { return d }
        let cdn = JSON.obj(root, "data").flatMap { JSON.str($0, "APP_DOMAIN_CDN_IMAGE") }
        d.movie = parseMovie(item, cdn: (cdn?.isEmpty == false) ? cdn : nil)
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
        let eps = JSON.arr(root, "episodes") ?? JSON.arr(item, "episodes") ?? []
        for sj in eps {
            var s = Server()
            s.name = JSON.str(sj, "server_name", "Server")
            for ej in JSON.arr(sj, "server_data") ?? [] {
                var e = Episode()
                // Name handling is byte-exact with Android v1.4:
                // resume keys hold these names — never rewritten.
                e.name = JSON.str(ej, "name", "")
                if e.name.isEmpty { e.name = "Tập" }
                e.m3u8 = JSON.str(ej, "link_m3u8")
                if e.m3u8.isEmpty { e.m3u8 = JSON.str(ej, "link") }
                e.embed = JSON.str(ej, "link_embed")
                s.episodes.append(e)
            }
            if !s.episodes.isEmpty { d.servers.append(s) }
        }
        return d
    }

    // MARK: - Parsing

    /// Internal (not private) so Providers.parseList can re-parse
    /// a cached raw response without a network call.
    static func parseItems(_ root: [String: Any]) -> [Movie] {
        let cdnRaw = JSON.obj(root, "data").flatMap { JSON.str($0, "APP_DOMAIN_CDN_IMAGE") }
        let cdn = (cdnRaw?.isEmpty == false) ? cdnRaw : nil
        return (itemsArray(root) ?? []).compactMap { o in
            let m = parseMovie(o, cdn: cdn)
            return m.slug.isEmpty ? nil : m
        }
    }

    private static func parseMovie(_ o: [String: Any], cdn: String?) -> Movie {
        var m = Movie()
        m.name = JSON.str(o, "name")
        m.slug = JSON.str(o, "slug")
        m.originName = JSON.str(o, "origin_name")
        m.poster = absImage(JSON.str(o, "poster_url"), cdn: cdn)
        m.thumb = absImage(JSON.str(o, "thumb_url"), cdn: cdn)
        // NO silent thumb→poster substitution (removed
        // 2026-11-16): the old `if poster.isEmpty { poster =
        // thumb }` smuggled a LANDSCAPE url into the portrait
        // field, where nothing downstream could tell it apart
        // — the card then letterboxed it into a band. An empty
        // poster stays empty so the slot's declared fallback
        // ladder (TMDB poster → placeholder, JoeRemoteImage
        // slot-class gate) runs visibly instead.
        m.year = cleanField(JSON.str(o, "year"))
        m.type = JSON.str(o, "type")
        m.episodeCurrent = cleanField(JSON.str(o, "episode_current"))
        if m.episodeCurrent.isEmpty {
            m.episodeCurrent = cleanField(JSON.str(o, "current_episode"))
        }
        m.quality = cleanField(JSON.str(o, "quality"))
        m.lang = cleanField(JSON.str(o, "lang"))
        // UI-6 D-2: the list payloads already carry these — the
        // hero's full meta / genres line read them from here.
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
        if let tm = JSON.obj(o, "tmdb") {
            m.tmdbId = cleanField(JSON.str(tm, "id"))
            m.tmdbType = cleanField(JSON.str(tm, "type"))
            let season = JSON.int(tm, "season")
            if season > 0 { m.tmdbSeason = season }
        }
        // v2.0.2 (P2 — mirror of Android FIX5): the payload's
        // "imdb" object ({id: "tt…"} — e.g. tt47712459 for
        // "Yêu Là Tàn Nhẫn") was never read, so a KK film's own
        // IMDb id stayed "" — every consumer paid the TMDB
        // external_ids round trip instead, and the play-time
        // rescue ladder's alt-KK leg in JoeMovieDetail read an
        // always-empty kd.movie.imdbId (a dead leg). Same
        // tolerant shape as Android KkApi.fillFacets: fills
        // only an empty field, and cleanField applies the
        // house null discipline (a JSON null or the literal
        // text "null" is missing data, never an identity).
        if m.imdbId.isEmpty, let im = JSON.obj(o, "imdb") {
            let idv = cleanField(JSON.str(im, "id"))
            if !idv.isEmpty { m.imdbId = idv }
        }
        m.provider = Providers.KK
        return m
    }

    /// v1 endpoints return poster paths relative to the image CDN.
    private static func absImage(_ url: String, cdn: String?) -> String {
        if url.isEmpty || url.hasPrefix("http") { return url }
        let base = (cdn?.isEmpty == false) ? cdn! : cdnDefault
        if base.hasSuffix("/") && url.hasPrefix("/") { return base + String(url.dropFirst()) }
        if !base.hasSuffix("/") && !url.hasPrefix("/") { return base + "/" + url }
        return base + url
    }
}

/// Lock-guarded outcome box for the KK host race (the
/// findAlternatives pattern): each host task reports its
/// result here; the caller polls the box and returns the
/// FIRST shape-valid answer the moment it lands — cancelled
/// losers are never awaited. A failed host also settles, so
/// an all-fail race ends as soon as the last host reports.
private final class KkRaceBox {
    private let lock = NSLock()
    private var winnerValue: (host: Int, root: [String: Any])?
    private var errorValue: Error?
    private var settledValue = 0

    func report(host: Int, root: [String: Any]?, error: Error?) {
        lock.lock()
        settledValue += 1
        if let root {
            if winnerValue == nil { winnerValue = (host, root) }
        } else if let error {
            errorValue = error
        }
        lock.unlock()
    }

    var winner: (host: Int, root: [String: Any])? {
        lock.lock()
        defer { lock.unlock() }
        return winnerValue
    }

    var lastError: Error? {
        lock.lock()
        defer { lock.unlock() }
        return errorValue
    }

    var settledCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return settledValue
    }
}
