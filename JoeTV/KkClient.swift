import Foundation

/// KKPhim public API client — port of the Android KkApi, host
/// failover included. Three hosts serve the identical KKPhim-format
/// catalogue and are tried in order until one answers with VALID
/// catalogue JSON:
///   (a) https://phimapi.com               — "/v1/api/..." flavour
///   (b) https://free.cryboiz.workers.dev  — bare-path flavour
///   (c) https://free2.phim4k.dev/api      — bare-path flavour
/// The first host returning valid JSON wins for the session and is
/// tried first on later calls; every call still falls through the
/// remaining hosts. "Valid" is strict: the body must parse AND carry
/// the expected container (items array for lists/search, a movie
/// object for detail) — a {"status":false} stub does not count.
///
/// Envelopes absorbed (measured live on Android, 2026-11-13):
///   (a) lists: {data:{items:[…], APP_DOMAIN_CDN_IMAGE}}
///       (newest: {items:[…]} at root, absolute posters)
///   (b/c) lists: {status, items:[…]} at root
///   (a) detail: {data:{item:{…, episodes:[…]}}}
///   (b/c) detail: {movie:{…}, episodes:[…]} — episodes may carry
///       the stream in a "link" field instead of "link_m3u8".
enum KkClient {
    private static let hosts = [
        "https://phimapi.com",
        "https://free.cryboiz.workers.dev",
        "https://free2.phim4k.dev/api",
    ]
    private static let cdnDefault = "https://phimimg.com"
    /// Session winner; -1 = unprobed. A fresh app start re-probes.
    private static var activeHost = -1

    // MARK: - Host-failover fetch

    private static func fetchJSON(path: (Bool) -> String,
                                  shape: ([String: Any]) -> Bool) async throws -> [String: Any] {
        var order: [Int] = []
        if activeHost >= 0 { order.append(activeHost) }
        for h in hosts.indices where h != activeHost { order.append(h) }
        var lastError: Error = URLError(.cannotConnectToHost)
        for h in order {
            do {
                let root = try await JoeHTTP.getJSON(hosts[h] + path(h != 0))
                if shape(root) {
                    activeHost = h
                    return root
                }
                lastError = URLError(.badServerResponse)
            } catch {
                lastError = error
            }
        }
        throw lastError
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

    static func newest(page: Int) async throws -> [Movie] {
        let root = try await fetchJSON(
            path: { _ in "/danh-sach/phim-moi-cap-nhat?page=\(page)" },
            shape: { itemsArray($0) != nil })
        return parseItems(root)
    }

    /// Typed list rails: phim-bo, phim-le, hoat-hinh, tv-shows…
    static func listByType(_ type: String, page: Int) async throws -> [Movie] {
        let root = try await fetchJSON(
            path: { bare in
                bare ? "/danh-sach/\(type)?page=\(page)"
                     : "/v1/api/danh-sach/\(type)?page=\(page)"
            },
            shape: { itemsArray($0) != nil })
        return parseItems(root)
    }

    static func search(_ keyword: String) async throws -> [Movie] {
        let q = JoeHTTP.qenc(keyword)
        let root = try await fetchJSON(
            path: { bare in
                bare ? "/tim-kiem?keyword=\(q)" : "/v1/api/tim-kiem?keyword=\(q)"
            },
            shape: { itemsArray($0) != nil })
        return parseItems(root)
    }

    static func detail(_ slug: String) async throws -> Detail {
        let root = try await fetchJSON(
            path: { bare in bare ? "/phim/\(slug)" : "/v1/api/phim/\(slug)" },
            shape: { detailItem($0) != nil })
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

    private static func parseItems(_ root: [String: Any]) -> [Movie] {
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
        if m.poster.isEmpty { m.poster = absImage(JSON.str(o, "thumb_url"), cdn: cdn) }
        m.year = cleanField(JSON.str(o, "year"))
        m.type = JSON.str(o, "type")
        m.episodeCurrent = cleanField(JSON.str(o, "episode_current"))
        if m.episodeCurrent.isEmpty {
            m.episodeCurrent = cleanField(JSON.str(o, "current_episode"))
        }
        m.quality = cleanField(JSON.str(o, "quality"))
        m.lang = cleanField(JSON.str(o, "lang"))
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
