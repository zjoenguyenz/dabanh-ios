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
    var playable: Bool { !url.isEmpty && containerPlayable }

    /// Containers AVPlayer opens natively.
    static let avPlayerContainers: Set<String> = ["mp4", "m4v", "mov"]
    /// Containers AVPlayer cannot open at all (B-5, Team 4
    /// conformance).
    static let nonAVPlayerContainers: Set<String> =
        ["mkv", "avi", "wmv", "flv", "webm", "ts", "mpg", "mpeg", "rm", "rmvb"]

    /// B-5: whether this stream's container is one AVPlayer can
    /// play. Read from the stream URL's extension when it has
    /// one, else from the release name carried in the title/name
    /// text (Torrentio titles carry it). Unknown containers stay
    /// playable — the rule only excludes containers that are
    /// KNOWN-bad, so unlabelled streams are never punished.
    /// `playable` folds this in, and `playable` is what the
    /// view's auto-pick walk and "PHÁT NGAY" badge key on — a
    /// known-bad container is excluded at selection time
    /// instead of being discovered by AVPlayer after the tap.
    var containerPlayable: Bool {
        if let ext = URL(string: url)?.pathExtension.lowercased(),
           !ext.isEmpty {
            if Self.avPlayerContainers.contains(ext) { return true }
            if Self.nonAVPlayerContainers.contains(ext) { return false }
        }
        let text = (name + " " + title).lowercased()
        for ext in Self.nonAVPlayerContainers {
            // The extension must end at a non-alphanumeric
            // boundary, so "The.Tsars.2024" does not false-fire
            // on ".ts" while "Movie.2024.mkv" and
            // "Movie.MKV.1080p" both count.
            let needle = "." + ext
            var searchRange = text.startIndex..<text.endIndex
            while let range = text.range(of: needle, range: searchRange) {
                let after = range.upperBound
                if after == text.endIndex
                    || (!text[after].isLetter && !text[after].isNumber) {
                    return false
                }
                searchRange = after..<text.endIndex
            }
        }
        return true
    }
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
        // 1.9.2 (Team 9 item 6): discovery-class calls carry
        // an explicit 8 s budget — pre-fix they rode JoeHTTP's
        // 25 s default, and the torrent home's sequential
        // catalogue walk stacked those into a ~100 s grind on
        // a dead route. Streams (15 s, SourceHealth) and
        // subtitles (18 s) keep their own tuned budgets.
        if let root = try? await JoeHTTP.getJSON(addonBase + "/manifest.json",
                                                 timeout: 8) {
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
        let root = try await JoeHTTP.getJSON(
            cat.base + "/catalog/\(cat.type)/\(cat.id).json", timeout: 8)
        return parseMetas(JSON.arr(root, "metas"))
    }

    /// Genre rail from Cinemeta's top catalog. Endpoint pattern
    /// built from the existing catalog URL construction above
    /// (`/catalog/{type}/{id}.json`, here id "top" plus the
    /// Stremio `genre=` extra). The genre is URL-encoded (C-7):
    /// verbatim, "Science Fiction" put a literal space in the
    /// URL, which is not a valid URL at all — the rail could
    /// never load. Verified live 2026-11-15: the %20-encoded
    /// form answers (a 307 to Cinemeta's canonical
    /// "Science+Fiction" URL, which the session follows).
    static func fetchGenreCatalog(type: String, genre: String) async throws -> [TorMeta] {
        let root = try await JoeHTTP.getJSON(
            TorrentSettings.cinemeta + "/catalog/\(type)/top/genre=\(JoeHTTP.qenc(genre)).json",
            timeout: 8)
        return parseMetas(JSON.arr(root, "metas"))
    }

    static func search(_ cat: TorCatalog, keyword: String) async throws -> [TorMeta] {
        let q = JoeHTTP.qenc(keyword)
        let root = try await JoeHTTP.getJSON(
            cat.base + "/catalog/\(cat.type)/\(cat.id)/search=\(q).json",
            timeout: 8)
        return parseMetas(JSON.arr(root, "metas"))
    }

    /// Series episodes from the meta endpoint (Cinemeta-shaped).
    static func fetchVideos(metaBase: String, type: String, id: String) async throws -> [TorVideo] {
        let root = try await JoeHTTP.getJSON(
            metaBase + "/meta/\(type)/\(id).json", timeout: 8)
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

    /// Tuned Torrentio list cap (LATENCY-AUDIT §6): 35 s →
    /// 15 s (healthy max 1.17; a public service with load
    /// spikes keeps a generous ≈13× median headroom).
    /// SourceHealth's dynamic fuse tightens within it. This
    /// one call serves both the torrent section's own play
    /// path and the Phim substitution rung.
    private static let streamsCap: TimeInterval = 15

    static func fetchStreams(addonBase: String, type: String, id: String) async throws -> [TorStream] {
        let url = addonBase + "/stream/\(type)/\(id).json"
        let root = try await SourceHealth.run(
            provider: SourceHealth.torrentProvider, stage: .resolve,
            url: url, cap: streamsCap
        ) { budget in
            try await JoeHTTP.getJSON(url, timeout: budget)
        }
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

    // MARK: - Play candidates (shared conversion)

    /// Direct URL, or a hash resolved through the owner's own
    /// Real-Debrid account. Fail-soft to nil. (Moved here from
    /// JoeTorrentDetail: both play paths below share it, so the
    /// RD behaviour can never drift between them.)
    static func resolvePlayable(_ s: TorStream) async -> URL? {
        if s.playable { return URL(string: s.url) }
        guard !s.infoHash.isEmpty else { return nil }
        let token = TorrentSettings.rdToken
        guard !token.isEmpty else { return nil }
        if let r = try? await RdClient.resolve(
            token: token, infoHash: s.infoHash, fileIdx: s.fileIdx) {
            return URL(string: r.url)
        }
        return nil
    }

    /// Streams → player candidates: THE conversion both torrent
    /// play paths use — the torrent section's own player and
    /// the Phim section's substitution rung (JoeMovieDetail) —
    /// so filtering, RD behaviour and ordering are one
    /// implementation, not two copies. The `preferred` stream
    /// (the one the owner tapped; for the rung, the list's own
    /// first entry — Torrentio's top-ranked) leads the list and
    /// alone earns a Real-Debrid resolution when it carries no
    /// direct URL: resolving every hash in the list would spam
    /// the owner's account, so other hash entries are never
    /// auto-resolved. Every remaining candidate is a direct-URL
    /// stream passing TorStream.playable (the B-5 container
    /// rule included), in list order. `labelPrefix` marks the
    /// source for the player's status capsule ("" keeps the
    /// stream's own label, exactly what the torrent section
    /// has always shown).
    static func playCandidates(streams: [TorStream], preferred: TorStream?,
                               labelPrefix: String = "") async -> [PlayCandidate] {
        func label(_ s: TorStream) -> String {
            labelPrefix.isEmpty ? s.label : "\(labelPrefix) · \(s.label)"
        }
        var out: [PlayCandidate] = []
        let lead = preferred ?? streams.first
        if let lead,
           let match = streams.first(where: {
               $0.name == lead.name && $0.title == lead.title }),
           let url = await resolvePlayable(match) {
            out.append(PlayCandidate(url: url, label: label(match)))
        }
        for s in streams where s.playable {
            if let lead, s.name == lead.name && s.title == lead.title { continue }
            if let url = URL(string: s.url) {
                out.append(PlayCandidate(url: url, label: label(s)))
            }
        }
        return out
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
        var bestPlayableSize: Int64 = -1
        var bestPlayableId = -1
        var idxId = -1
        for (i, f) in files.enumerated() {
            let fid = JSON.int(f, "id", -1)
            let size = Int64(JSON.double(f, "bytes"))
            if i == fileIdx { idxId = fid }
            if size > bestSize { bestSize = size; bestId = fid }
            // B-5: the size fallback prefers the largest file
            // whose container AVPlayer can actually play (the
            // .mp4 in a release pack over an .mkv, say). The
            // addon's fileIdx, when present, is still honoured
            // exactly — it is the addon's own choice.
            let ext = (JSON.str(f, "path") as NSString).pathExtension.lowercased()
            if TorStream.avPlayerContainers.contains(ext),
               size > bestPlayableSize {
                bestPlayableSize = size
                bestPlayableId = fid
            }
        }
        let pick = idxId >= 0 ? idxId
            : (bestPlayableId >= 0 ? bestPlayableId : bestId)
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
        // Convergence (Team 6 D): the debrid API rides JoeHTTP's
        // bounded sessions (resource timeout = the call class's
        // 25 s) instead of URLSession.shared's unbounded default;
        // status/parse handling below is unchanged.
        let (data, response) = try await JoeHTTP.data(for: req, timeout: 25)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        if data.isEmpty { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}
