import Foundation

/// Torrent/debrid module over OPEN Stremio-protocol APIs + the
/// owner's OWN debrid accounts — port of the Android TorrentApi +
/// RdApi. The only endpoints are the addon base the owner
/// configures himself (normally his own Torrentio URL with his
/// Real-Debrid attached) and the public Cinemeta metadata service.
///
/// Protocol (shapes verified on Android 2026-11-13):
///   GET {base}/manifest.json → {catalogs:[…]} — stock Torrentio
///       ships none, so the section falls back to Cinemeta's public
///       top movie/series catalogs for posters/metadata; streams
///       ALWAYS come from the owner's configured addon.
///   GET {host}/catalog/{type}/{id}.json
///   GET {host}/catalog/{type}/{id}/search={kw}.json → {metas:[…]}
///   GET {host}/meta/{type}/{id}.json → {meta:{…, videos:[…]}}
///   GET {base}/stream/{type}/{id}.json → {streams:[{name, title,
///       url?, infoHash?, fileIdx?, behaviorHints:{proxyHeaders}}]}
///       Entries WITHOUT url are raw torrents; a debrid-configured
///       addon returns direct HTTPS urls for cached releases, and
///       url-less entries can be resolved through the owner's
///       Real-Debrid account (RdClient below).
enum TorrentSettings {
    static let keyAddonURL = "addon_url"
    static let keyRDToken = "rd_token"
    static let keyTorBoxToken = "torbox_token"
    static let keySubAddonURL = "sub_addon_url"
    static let opensubtitlesDefault = "https://opensubtitles-v3.strem.io/manifest.json"

    static var addonURL: String {
        get { UserDefaults.standard.string(forKey: keyAddonURL) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: keyAddonURL) }
    }
    static var rdToken: String {
        get { UserDefaults.standard.string(forKey: keyRDToken) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: keyRDToken) }
    }
    static var torboxToken: String {
        get { UserDefaults.standard.string(forKey: keyTorBoxToken) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: keyTorBoxToken) }
    }
    static var subAddonURL: String {
        get { UserDefaults.standard.string(forKey: keySubAddonURL) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: keySubAddonURL) }
    }

    static let torrentio = "https://torrentio.strem.fun"
    static let cinemeta = "https://v3-cinemeta.strem.io"

    /// The addon base to talk to, or nil when nothing is
    /// configured. A pasted full Torrentio URL wins; otherwise a
    /// bare token builds the standard Torrentio config URL.
    static var effectiveBase: String? {
        let url = addonURL.trimmingCharacters(in: .whitespaces)
        if !url.isEmpty { return stripSlash(url) }
        let rd = rdToken.trimmingCharacters(in: .whitespaces)
        if !rd.isEmpty { return torrentio + "/realdebrid=" + rd }
        let tb = torboxToken.trimmingCharacters(in: .whitespaces)
        if !tb.isEmpty { return torrentio + "/torbox=" + tb }
        return nil
    }

    static var isConfigured: Bool { effectiveBase != nil }

    static func stripSlash(_ s: String) -> String {
        var out = s
        while out.hasSuffix("/") { out = String(out.dropLast()) }
        if out.hasSuffix("/manifest.json") {
            out = String(out.dropLast("/manifest.json".count))
        }
        return out
    }

    /// The subtitle source: the dedicated subtitle addon when set,
    /// else the configured stream addon itself.
    static func subtitleBase(addonBase: String) -> String {
        let s = subAddonURL.trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? addonBase : stripSlash(s)
    }
}

struct TorCatalog {
    var type = ""
    var id = ""
    var name = ""
    var base = ""
    var searchable = false
}

struct TorMeta: Identifiable, Hashable {
    var id = ""
    var type = "movie"
    var name = ""
    var poster = ""
    var background = ""
    var year = ""
    var desc = ""
    var posterURL: URL? { poster.isEmpty ? nil : URL(string: poster) }
}

struct TorStream: Identifiable {
    var id = UUID()
    var name = ""
    var title = ""
    var url = ""
    var infoHash = ""
    var fileIdx = -1
    var proxyHeaders: [String: String] = [:]
    var playable: Bool { !url.isEmpty }
    /// The row's two lines, Stremio-style: addon/quality name on
    /// top, release title below.
    var label: String { name.isEmpty ? title : name }
}

struct TorSubtitle {
    var url = ""
    var lang = ""
}

struct TorVideo: Identifiable, Hashable {
    var id = ""
    var label = ""
}

enum TorrentClient {

    // MARK: - Discovery

    /// Catalogs to show as rails: the configured addon's own when
    /// it declares any, else Cinemeta's public top movie/series.
    static func discoverCatalogs(addonBase: String) async -> [TorCatalog] {
        var out: [TorCatalog] = []
        if let root = try? await JoeHTTP.getJSON(addonBase + "/manifest.json") {
            for c in JSON.arr(root, "catalogs") ?? [] {
                let type = JSON.str(c, "type")
                guard type == "movie" || type == "series" else { continue }
                var cat = TorCatalog()
                cat.type = type
                cat.id = JSON.str(c, "id")
                cat.name = JSON.str(c, "name", cat.id)
                cat.base = addonBase
                cat.searchable = hasSearchExtra(c)
                if !cat.id.isEmpty { out.append(cat) }
            }
        }
        if out.isEmpty {
            out.append(cinemetaCatalog(type: "movie", id: "top", name: "🎬 Phim thịnh hành"))
            out.append(cinemetaCatalog(type: "series", id: "top", name: "📺 Series thịnh hành"))
        }
        return out
    }

    private static func cinemetaCatalog(type: String, id: String, name: String) -> TorCatalog {
        var cat = TorCatalog()
        cat.type = type
        cat.id = id
        cat.name = name
        cat.base = TorrentSettings.cinemeta
        cat.searchable = true
        return cat
    }

    private static func hasSearchExtra(_ catalog: [String: Any]) -> Bool {
        (JSON.arr(catalog, "extra") ?? []).contains { JSON.str($0, "name") == "search" }
    }

    // MARK: - Catalog / search / meta

    static func fetchCatalog(_ cat: TorCatalog) async throws -> [TorMeta] {
        let root = try await JoeHTTP.getJSON(cat.base + "/catalog/\(cat.type)/\(cat.id).json")
        return parseMetas(JSON.arr(root, "metas"))
    }

    static func search(_ cat: TorCatalog, keyword: String) async throws -> [TorMeta] {
        let q = JoeHTTP.qenc(keyword)
        let root = try await JoeHTTP.getJSON(
            cat.base + "/catalog/\(cat.type)/\(cat.id)/search=\(q).json")
        return parseMetas(JSON.arr(root, "metas"))
    }

    /// Series episodes from the meta endpoint (Cinemeta-shaped).
    static func fetchVideos(metaBase: String, type: String, id: String) async throws -> [TorVideo] {
        let root = try await JoeHTTP.getJSON(metaBase + "/meta/\(type)/\(id).json")
        guard let meta = JSON.obj(root, "meta") else { return [] }
        return (JSON.arr(meta, "videos") ?? []).compactMap { v in
            var video = TorVideo()
            video.id = JSON.str(v, "id")
            let season = JSON.int(v, "season")
            let ep = JSON.int(v, "episode")
            let nm = JSON.str(v, "name", JSON.str(v, "title"))
            video.label = (season > 0 || ep > 0)
                ? "S\(season) · Tập \(ep)" + (nm.isEmpty ? "" : " — \(nm)")
                : (nm.isEmpty ? video.id : nm)
            return video.id.isEmpty ? nil : video
        }
    }

    private static func parseMetas(_ arr: [[String: Any]]?) -> [TorMeta] {
        (arr ?? []).compactMap { o in
            var m = TorMeta()
            m.id = JSON.str(o, "id")
            m.type = JSON.str(o, "type", "movie")
            m.name = JSON.str(o, "name")
            m.poster = JSON.str(o, "poster")
            m.background = JSON.str(o, "background")
            m.year = JSON.str(o, "year")
            if m.year.isEmpty || m.year.lowercased() == "null" {
                let ri = JSON.str(o, "releaseInfo")
                m.year = ri.count >= 4 ? String(ri.prefix(4)) : ""
            }
            m.desc = JSON.str(o, "description")
            return (m.id.isEmpty || m.name.isEmpty) ? nil : m
        }
    }

    // MARK: - Streams

    static func fetchStreams(addonBase: String, type: String, id: String) async throws -> [TorStream] {
        let root = try await JoeHTTP.getJSON(addonBase + "/stream/\(type)/\(id).json", timeout: 35)
        return (JSON.arr(root, "streams") ?? []).map { o in
            var s = TorStream()
            s.name = JSON.str(o, "name")
            s.title = JSON.str(o, "title")
            s.url = JSON.str(o, "url")
            s.infoHash = JSON.str(o, "infoHash")
            s.fileIdx = JSON.int(o, "fileIdx", -1)
            if let bh = JSON.obj(o, "behaviorHints"),
               let ph = JSON.obj(bh, "proxyHeaders"),
               let req = JSON.obj(ph, "request") {
                for (k, v) in req where v is String {
                    s.proxyHeaders[k] = v as? String ?? ""
                }
            }
            return s
        }
    }

    // MARK: - Subtitles (addon protocol)

    /// GET {base}/subtitles/{type}/{id}.json → {subtitles:[…]}.
    /// Fail-soft: any error returns an empty list.
    static func fetchSubtitles(base: String, type: String, id: String) async -> [TorSubtitle] {
        guard let root = try? await JoeHTTP.getJSON(base + "/subtitles/\(type)/\(id).json", timeout: 18)
        else { return [] }
        return (JSON.arr(root, "subtitles") ?? []).compactMap { o in
            var s = TorSubtitle()
            s.url = JSON.str(o, "url")
            s.lang = JSON.str(o, "lang")
            return s.url.isEmpty ? nil : s
        }
    }

    /// Best Vietnamese subtitle: exact "vi"/"vie"/"vi-*" first,
    /// then anything whose lang mentions viet.
    static func bestVietnamese(_ subs: [TorSubtitle]) -> TorSubtitle? {
        var loose: TorSubtitle?
        for s in subs {
            let l = s.lang.lowercased()
            if l == "vi" || l == "vie" || l.hasPrefix("vi-") || l.hasPrefix("vi_") { return s }
            if l.contains("viet") && loose == nil { loose = s }
        }
        return loose
    }
}

/// Minimal Real-Debrid client for ONE job: turn a torrent infoHash
/// (a stream the addon returned without a direct URL) into a
/// playable HTTPS link through the OWNER'S OWN premium account.
/// Flow (official REST API, Bearer token from Settings):
/// addMagnet → info (file list) → selectFiles (the Stremio
/// fileIdx when known, else the largest file) → poll info until
/// links[] present → unrestrict/link → {download}.
/// Fail-soft by design: every failure throws; the caller falls
/// back to the stream list with a message.
enum RdClient {
    private static let base = "https://api.real-debrid.com/rest/1.0"

    static func resolve(token: String, infoHash: String, fileIdx: Int) async throws -> (url: String, filename: String) {
        let trimmed = token.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw URLError(.userAuthenticationRequired) }
        let hash = infoHash.trimmingCharacters(in: .whitespaces).lowercased()

        let magnet = "magnet:?xt=urn:btih:" + hash
        let added = try await request(token: trimmed, method: "POST", path: "/torrents/addMagnet",
                                      form: ["magnet": magnet])
        let id = JSON.str(added, "id")
        guard !id.isEmpty else { throw URLError(.badServerResponse) }

        let info = try await request(token: trimmed, method: "GET", path: "/torrents/info/\(id)", form: nil)
        let files = JSON.arr(info, "files") ?? []
        guard !files.isEmpty else { throw URLError(.badServerResponse) }
        var bestSize: Int64 = -1
        var bestId = -1
        var idxId = -1
        for (i, f) in files.enumerated() {
            let fid = JSON.int(f, "id", -1)
            let size = Int64(JSON.double(f, "bytes"))
            if i == fileIdx { idxId = fid }
            if size > bestSize { bestSize = size; bestId = fid }
        }
        let pick = idxId >= 0 ? idxId : bestId
        guard pick >= 0 else { throw URLError(.badServerResponse) }

        _ = try await request(token: trimmed, method: "POST",
                              path: "/torrents/selectFiles/\(id)", form: ["files": String(pick)])

        var link: String?
        for _ in 0..<10 where link == nil {
            let inf = try await request(token: trimmed, method: "GET", path: "/torrents/info/\(id)", form: nil)
            if let links = inf["links"] as? [Any], let first = links.first as? String, !first.isEmpty {
                link = first
            } else {
                try await Task.sleep(for: .seconds(1.5))
            }
        }
        guard let link else { throw URLError(.timedOut) }

        let un = try await request(token: trimmed, method: "POST", path: "/unrestrict/link",
                                   form: ["link": link])
        let url = JSON.str(un, "download")
        guard !url.isEmpty else { throw URLError(.badServerResponse) }
        return (url, JSON.str(un, "filename"))
    }

    private static func request(token: String, method: String, path: String,
                                form: [String: String]?) async throws -> [String: Any] {
        guard let url = URL(string: base + path) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 25
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let form {
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = form.map { "\(JoeHTTP.qenc($0.key))=\(JoeHTTP.qenc($0.value))" }
                .joined(separator: "&").data(using: .utf8)
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        if data.isEmpty { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}
