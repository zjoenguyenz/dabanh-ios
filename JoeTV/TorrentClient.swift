import Foundation
import OSLog

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
///       Real-Debrid account (RdClient below). TorBox and
///       Premiumize (added 2026-11-16) have no direct client
///       here by design — like TorBox since it shipped, they
///       work purely through the Torrentio config segments in
///       TorrentSettings.effectiveBase.
enum TorrentSettings {
    static let keyAddonURL = "addon_url"
    static let keyRDToken = "rd_token"
    static let keyTorBoxToken = "torbox_token"
    static let keyPremiumizeToken = "premiumize_token"
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
    static var premiumizeToken: String {
        get { UserDefaults.standard.string(forKey: keyPremiumizeToken) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: keyPremiumizeToken) }
    }

    /// v2.0.5 (N7 — baked-in tokens, owner order 2026-11-16):
    /// the EFFECTIVE tokens resolve exactly like the TMDB
    /// key (TMDBClient.swift): a stored value wins; when
    /// storage is empty, the build-time bundled value from
    /// BundledTokens (injected by the workflow from the
    /// RD_TOKEN / TORBOX_TOKEN Actions secrets) applies, so
    /// a reinstall never asks the owner to re-type a token
    /// with the TV remote. The raw accessors above stay the
    /// Settings editor's view of storage — unchanged keys,
    /// unchanged save() behaviour. Premiumize (owner order
    /// 2026-11-16: a third resolver next to RD + TorBox)
    /// follows the identical rule, its bundled value coming
    /// from the PREMIUMIZE_TOKEN Actions secret.
    static var effectiveRDToken: String {
        let stored = rdToken.trimmingCharacters(in: .whitespaces)
        return stored.isEmpty ? BundledTokens.rdToken : stored
    }
    static var effectiveTorBoxToken: String {
        let stored = torboxToken.trimmingCharacters(in: .whitespaces)
        return stored.isEmpty ? BundledTokens.torboxToken : stored
    }
    static var effectivePremiumizeToken: String {
        let stored = premiumizeToken.trimmingCharacters(in: .whitespaces)
        return stored.isEmpty ? BundledTokens.premiumizeToken : stored
    }
    static var subAddonURL: String {
        get { UserDefaults.standard.string(forKey: keySubAddonURL) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: keySubAddonURL) }
    }

    /// v2.0.16: MediaFusion, the second torrent gateway (the
    /// Android 2.3.14 port). The owner pastes ONE manifest URL
    /// minted on the MediaFusion configure page; the secret in
    /// it is a bearer credential — it lives only in these
    /// prefs, is never logged and never sent anywhere but the
    /// MediaFusion host itself.
    static let keyMfURL = "mf_url"
    static let keyMfEnabled = "mf_enabled"

    static var mfURL: String {
        get { UserDefaults.standard.string(forKey: keyMfURL) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: keyMfURL) }
    }

    /// The kill-switch (Android parity, default ON): off ⇒
    /// MediaFusion is fully absent and the torrent surfaces
    /// behave exactly as before it existed.
    static var mfEnabled: Bool {
        get {
            let d = UserDefaults.standard
            return d.object(forKey: keyMfEnabled) == nil
                ? true : d.bool(forKey: keyMfEnabled)
        }
        set { UserDefaults.standard.set(newValue, forKey: keyMfEnabled) }
    }

    /// The MediaFusion base to talk to, or nil when it is not
    /// in play: kill-switch off, nothing pasted, or the pasted
    /// value does not validate as an http/https URL (the
    /// effectiveBase rule — a stray word in the field must
    /// never become a base). Accepts the configure page's
    /// manifest URL, the bare base, or a stremio:// link
    /// (stripSlash removes the /manifest.json tail).
    static var mfBase: String? {
        guard mfEnabled else { return nil }
        let raw = mfURL.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return nil }
        var s = raw
        if s.hasPrefix("stremio://") {
            s = "https://" + String(s.dropFirst("stremio://".count))
        }
        let base = stripSlash(s)
        return isValidAddonBase(base) ? base : nil
    }

    /// True when a MediaFusion URL is saved (regardless of the
    /// toggle) — the Settings presence tick.
    static var mfConfigured: Bool {
        !mfURL.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// v2.0.24: the Thể Thao Torrent tab's OWN sources (the
    /// Sony 2.3.37 port). Two stored slots beside — never
    /// instead of — the MediaFusion base above: the MF base
    /// also feeds the pooled MOVIE path, so it is never
    /// repointed; the sports chain reads these slots first
    /// and falls back to MF. The primary slot defaults to
    /// the Nuvio Live Sports public instance (the
    /// sports-provider hunt's winner, probed live
    /// 2026-11-17); the second defaults to StremVerse, whose
    /// live-events catalog is the standing third source. A
    /// stored value wins over the default (e.g. a
    /// self-hosted Nuvio on the owner's PC); a stored value
    /// that does not validate as an http/https URL makes the
    /// slot nil — the mfBase honesty rule, so a stray word
    /// in the field can never become a base.
    static let keySportsURL = "sports_url"
    static let keySports2URL = "sports2_url"
    static let sportsDefault = "https://nuviosports.xyz"
    static let sports2Default = "https://stremverse1.alwaysdata.net"

    static var sportsURL: String {
        get { UserDefaults.standard.string(forKey: keySportsURL) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: keySportsURL) }
    }
    static var sports2URL: String {
        get { UserDefaults.standard.string(forKey: keySports2URL) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: keySports2URL) }
    }

    /// A sports slot's effective base: the stored value when
    /// set (stremio:// links and a /manifest.json tail are
    /// normalised exactly as for mfBase), else the slot's
    /// public default; nil only when a stored value is set
    /// but does not validate.
    private static func sportsSlotBase(stored: String, fallback: String) -> String? {
        var raw = stored.trimmingCharacters(in: .whitespaces)
        if raw.isEmpty { return fallback }
        if raw.hasPrefix("stremio://") {
            raw = "https://" + String(raw.dropFirst("stremio://".count))
        }
        let base = stripSlash(raw)
        return isValidAddonBase(base) ? base : nil
    }

    static var sportsBase: String? {
        sportsSlotBase(stored: sportsURL, fallback: sportsDefault)
    }
    static var sports2Base: String? {
        sportsSlotBase(stored: sports2URL, fallback: sports2Default)
    }

    /// The sports tab is offered when any sports source is
    /// in play (the Sony sportsAvailable rule): a sports
    /// slot resolves, or MediaFusion is configured.
    static var sportsAvailable: Bool {
        sportsBase != nil || mfBase != nil
    }

    static let torrentio = "https://torrentio.strem.fun"
    static let cinemeta = "https://v3-cinemeta.strem.io"

    /// The addon base to talk to, or nil when nothing is
    /// configured. A pasted full Torrentio URL wins; otherwise a
    /// bare token builds the standard Torrentio config URL.
    /// v2.0.5 (error 4): a pasted value must VALIDATE as an
    /// http/https URL with a host before it may win. Pre-fix,
    /// any non-empty string — the owner's test typing "bbbb"
    /// in the field — took absolute priority over the RD token
    /// and every stream fetch became "bbbb/stream/…", while
    /// isConfigured (effectiveBase != nil) still showed ✓.
    /// An invalid pasted value now falls through to the token
    /// bases; if none is valid either, the result is nil and
    /// the configuration check is honest.
    /// Premiumize (owner order 2026-11-16): the token-built
    /// base now carries EVERY configured debrid in ONE
    /// Torrentio config — Torrentio's own config grammar is
    /// `|`-joined key=value pairs and its server collects
    /// all debrid credentials present, querying them in
    /// config order (verified 2026-11-16 against the live
    /// configure page's apiKeys map and the torrentio-scraper
    /// server source: providers/premiumize.rs fixes the key
    /// as "premiumize", and config.rs unit-tests a combined
    /// torbox|realdebrid config). The segment order keeps
    /// the established priority — Real-Debrid first, then
    /// TorBox, then Premiumize — and a single configured
    /// token still builds byte-for-byte the base it built
    /// before (RD-only and TorBox-only are unchanged); the
    /// pasted-URL precedence and validity rule above are
    /// untouched.
    static var effectiveBase: String? {
        let url = addonURL.trimmingCharacters(in: .whitespaces)
        if !url.isEmpty {
            let base = stripSlash(url)
            if isValidAddonBase(base) { return base }
        }
        var segments: [String] = []
        let rd = effectiveRDToken
        if !rd.isEmpty { segments.append("realdebrid=" + rd) }
        let tb = effectiveTorBoxToken
        if !tb.isEmpty { segments.append("torbox=" + tb) }
        let pm = effectivePremiumizeToken
        if !pm.isEmpty { segments.append("premiumize=" + pm) }
        return segments.isEmpty
            ? nil
            : torrentio + "/" + segments.joined(separator: "|")
    }

    /// A usable addon base is an absolute http/https URL with
    /// a non-empty host. (A bare word like "bbbb" parses as a
    /// RELATIVE URL — scheme and host both nil — and fails.)
    private static func isValidAddonBase(_ s: String) -> Bool {
        guard let u = URL(string: s),
              let scheme = u.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = u.host, !host.isEmpty
        else { return false }
        return true
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
    /// v2.0.24: the addon base that SERVED this meta, stamped
    /// by the sports fetch (the Sony servingBase rule) so the
    /// Thể Thao Torrent play path resolves the meta's streams
    /// from the same addon that listed it. Empty for movie /
    /// series metas, whose streams come from the configured
    /// gateways as before.
    var servingBase = ""
    var posterURL: URL? { poster.isEmpty ? nil : URL(string: poster) }
}

/// The Thể Thao Torrent fetch outcome (v2.0.21).
struct MfSportEventsResult {
    var metas: [TorMeta] = []
    /// Whether the profile's manifest was READ and exposes
    /// at least one live catalog (type "events" or "tv"):
    /// true = live catalogs exist (their metas are merged
    /// above); false = the manifest was read and carries NO
    /// live catalogs, so the profile itself is the cause of
    /// an empty tab; nil = the manifest could not be read
    /// and the fetch fell back to the plain events catalog,
    /// leaving the profile question open.
    var manifestLiveCatalogs: Bool? = nil
}

struct TorStream: Identifiable {
    var id = UUID()
    var name = ""
    var title = ""
    var url = ""
    var infoHash = ""
    var fileIdx = -1
    var proxyHeaders: [String: String] = [:]

    /// v2.0.16: which gateway served this row — "TOR"
    /// (Torrentio, the default) or "MF" (MediaFusion).
    var gateway: String = "TOR"

    /// v2.0.26 (idea 10): the stream's parsed display
    /// features, stamped at fetch time from the SAME parse
    /// the ranking uses (RankFeat.of — see fetchStreams).
    /// playCandidates copies them onto each PlayCandidate,
    /// and the KSPlayer host turns them into its
    /// preferredDisplayCriteria; the AVPlayer path is
    /// matched by the system and never reads them.
    /// Defaults = SDR / unknown rate.
    var dv = false
    var hdr = false
    /// Frame rate parsed from the release name when present
    /// (e.g. 59.94 / 50); nil = no explicit rate in the name.
    var fps: Double? = nil

    /// Debrid cache state, read from the serving gateway's
    /// own name grammar (Android 2.3.4 / 2.3.14): a Torrentio
    /// row whose name carries " download]" is a release the
    /// debrid is still fetching; a MediaFusion row WITHOUT
    /// ⚡️ in its name is the same state in MF's grammar.
    var awaitingDisplay: Bool {
        if gateway == "MF" { return !name.contains("⚡️") }
        return name.lowercased().contains(" download]")
    }

    /// Ranking class (Android rankPool): 0 = plays now,
    /// 1 = playable but awaiting the debrid, 2 = hash-only.
    var playClass: Int {
        if !playable { return 2 }
        return awaitingDisplay ? 1 : 0
    }

    /// "Plays at once": the stream carries a direct URL. Since
    /// v2.0.3 the torrent candidates play in the FFmpeg engine
    /// (KSPlayer — see JoeKSPlayerView), which opens every
    /// container Torrentio serves, so a direct URL is all
    /// "playable" means now. The B-5 container gate below is
    /// retired from selection: it was an AVPlayer workaround,
    /// and in practice it could not even see the container —
    /// Torrentio's RD resolve URLs carry no file extension and
    /// its release titles carry no extension either, so MKV
    /// files sailed through the gate and died inside AVPlayer
    /// after the tap (the owner's endless black spinner).
    var playable: Bool { !url.isEmpty }

    /// Containers AVPlayer opens natively.
    static let avPlayerContainers: Set<String> = ["mp4", "m4v", "mov"]
    /// Containers AVPlayer cannot open at all (B-5, Team 4
    /// conformance).
    static let nonAVPlayerContainers: Set<String> =
        ["mkv", "avi", "wmv", "flv", "webm", "ts", "mpg", "mpeg", "rm", "rmvb"]

    /// B-5 (historical): whether this stream's container is one
    /// AVPlayer can play, read from the stream URL's extension
    /// when it has one, else from the release name carried in
    /// the title/name text. No longer consulted at selection
    /// time (the torrent engine is FFmpeg now); retained as the
    /// documented AVPlayer capability boundary — RdClient's
    /// file pick keys on the same container sets above.
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

    /// Owner source-priority policy (2026-11-15, IN v2.0.0 per
    /// the owner's 16:08 ruling): a HIGH-QUALITY release for
    /// the Auto torrent-first rule. Token-based over the same
    /// name+title text the container rule reads: the release
    /// must carry a 2160p or 1080p token AND a BluRay /
    /// WEB-DL / WEBRip-class tag (Blu-ray, BDRip and BRRip
    /// count as the BluRay class). A CAM-class token (CAM,
    /// CAMRIP, HDCAM, HDTS, TS, TELESYNC, TELECINE…) vetoes
    /// the stream outright — CAM-class NEVER qualifies, even
    /// when a resolution token rides along.
    var isHighQualityRelease: Bool {
        let tokens = Set((name + " " + title).uppercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty })
        let camClass: Set<String> = ["CAM", "CAMRIP", "HDCAM", "HDTS",
                                     "TS", "TELESYNC", "TELECINE", "TC",
                                     "HDTC", "SCREENER", "SCR"]
        if !tokens.isDisjoint(with: camClass) { return false }
        let hasResolution = tokens.contains("2160P") || tokens.contains("1080P")
        let hasClass = tokens.contains("BLURAY")
            || (tokens.contains("BLU") && tokens.contains("RAY"))
            || tokens.contains("BDRIP") || tokens.contains("BRRIP")
            || tokens.contains("WEBDL")
            || (tokens.contains("WEB") && tokens.contains("DL"))
            || tokens.contains("WEBRIP")
        return hasResolution && hasClass
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

    static func fetchStreams(addonBase: String, type: String, id: String,
                             gateway: String = "TOR",
                             provider: String = SourceHealth.torrentProvider)
        async throws -> [TorStream] {
        let url = addonBase + "/stream/\(type)/\(id).json"
        let root = try await SourceHealth.run(
            provider: provider, stage: .resolve,
            url: url, cap: streamsCap
        ) { budget in
            try await JoeHTTP.getJSON(url, timeout: budget)
        }
        return (JSON.arr(root, "streams") ?? []).map { o in
            var s = TorStream()
            s.name = JSON.str(o, "name")
            s.title = JSON.str(o, "title")
            // v2.0.16: MediaFusion puts the release detail in
            // "description", not "title" — the shared parse
            // falls back so an MF row is never title-less
            // (a no-op for Torrentio, which fills "title").
            if s.title.isEmpty { s.title = JSON.str(o, "description") }
            s.gateway = gateway
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
            // v2.0.26 (idea 10): stamp the display features
            // from the ranking's OWN parse (RankFeat.of) —
            // the one parse, reused, never a second divergent
            // one. RankFeat.of is pure over name/title, so
            // this costs nothing and cannot change ranking:
            // rankPool re-derives the same features itself.
            let feat = RankFeat.of(s)
            s.dv = feat.dv
            s.hdr = feat.hdr
            s.fps = feat.fps
            return s
        }
    }

    // MARK: - Pooled fetch + ranking (v2.0.16, Android 2.3.14/2.3.16 port)

    /// The two gateways are asked in parallel, each fail-soft;
    /// the pool is deduped to one row per release and ranked
    /// best-first, cut to 30 rows — the Sony form the owner
    /// approved ("chỉ cần nguồn chất lượng cao nhất và nhanh
    /// nhất"). `primaryFailed` reports the Torrentio leg's
    /// failure so the detail can keep its error surface
    /// honest when the pool comes back empty; a gateway that
    /// is not configured at all is absence, not failure.
    static func fetchPooledStreams(torrentioBase: String?, mfBase: String?,
                                   type: String, id: String)
        async -> (streams: [TorStream], primaryFailed: Bool) {
        func leg(_ base: String?, _ gateway: String) async -> [TorStream]? {
            guard let base else { return nil }
            return try? await fetchStreams(addonBase: base, type: type,
                                           id: id, gateway: gateway)
        }
        async let tor = leg(torrentioBase, "TOR")
        async let mfRows = leg(mfBase, "MF")
        let torResult = await tor
        let mfResult = await mfRows
        var pool: [TorStream] = []
        if let torResult { pool += torResult }
        if let mfResult { pool += mfResult }
        return (Array(rankPool(pool).prefix(30)),
                torrentioBase != nil && torResult == nil)
    }

    /// Ranking features parsed from an entry's own text — the
    /// gateways publish no structured fields; name + title
    /// carry resolution, source class, size and seeders in
    /// both gateways' grammars.
    private struct RankFeat {
        var playClass: Int
        var res: Int      // 2160 / 1080 / 720 / 480 / 0
        var cls: Int      // REMUX 50, BluRay 40, BDRip 35, WEB 30, HDTV 20, other 10
        var cam: Bool
        var dv: Bool
        var hdr: Bool
        /// v2.0.26 (idea 10): frame rate parsed from the
        /// release name, carried for display matching only —
        /// rankBefore / routeBefore / releaseKey never read
        /// it, so ranking behaviour is unchanged by its
        /// presence.
        var fps: Double? = nil
        var tor: Bool     // served by Torrentio (not MediaFusion)
        var seeders: Int
        var sizeGb: Double
        var provider: Int // TorBox 3, Real-Debrid 2, Premiumize 1, unknown 0

        static func of(_ s: TorStream) -> RankFeat {
            var f = RankFeat(playClass: s.playClass, res: 0, cls: 10,
                             cam: false, dv: false, hdr: false,
                             tor: s.gateway != "MF", seeders: 0,
                             sizeGb: 0, provider: 0)
            let all = s.name + "\n" + s.title
            let low = all.lowercased()
            if low.contains("2160p") || low.contains("4k") { f.res = 2160 }
            else if low.contains("1080p") { f.res = 1080 }
            else if low.contains("720p") { f.res = 720 }
            else if low.contains("480p") { f.res = 480 }
            if low.contains("remux") { f.cls = 50 }
            else if low.contains("bluray") || low.contains("blu-ray") { f.cls = 40 }
            else if low.contains("bdrip") { f.cls = 35 }
            else if low.contains("web-dl") || low.contains("webdl")
                        || low.contains("webrip") || low.contains("web ") { f.cls = 30 }
            else if low.contains("hdtv") { f.cls = 20 }
            f.cam = low.contains("hdcam") || low.contains("camrip")
                || low.contains("hdts") || low.contains("telesync")
                || low.contains("screener") || low.contains(" cam ")
            let tokens = " " + low.components(
                separatedBy: CharacterSet.alphanumerics.inverted)
                .joined(separator: " ") + " "
            f.dv = low.contains("dolby vision") || tokens.contains(" dv ")
            f.hdr = low.contains("hdr")
            f.fps = parseFPS(low)
            f.seeders = parseSeeders(all)
            f.sizeGb = parseSizeGb(all)
            f.provider = providerOf(s.name)
            return f
        }

        private static func parseSeeders(_ text: String) -> Int {
            guard let r = text.range(of: "👤") else { return 0 }
            var v = 0
            var started = false
            for ch in text[r.upperBound...] {
                if ch.isNumber {
                    started = true
                    v = v * 10 + (ch.wholeNumberValue ?? 0)
                } else if started { break }
            }
            return started ? v : 0
        }

        private static let fpsRegex = try? NSRegularExpression(
            pattern: "([0-9]+(?:\\.[0-9]+)?)\\s*fps")

        /// Frame rate from the release name (v2.0.26, idea
        /// 10): an explicit "<rate>fps" token first ("60fps",
        /// "50fps", "25fps", "59.94fps"), else a bare
        /// fractional rate token ("59.94", "29.97", "23.976")
        /// — the fractional rates release names carry are
        /// frame rates, and a bare integer without the fps
        /// suffix is too ambiguous to claim. Nil when the
        /// name carries no rate.
        private static func parseFPS(_ low: String) -> Double? {
            if let re = fpsRegex {
                let ns = low as NSString
                if let m = re.firstMatch(in: low, range: NSRange(
                        location: 0, length: ns.length)),
                   let v = Double(ns.substring(with: m.range(at: 1))) {
                    return v
                }
            }
            for rate in ["59.94", "29.97", "23.976", "23.98"] {
                if low.contains(rate) { return Double(rate) }
            }
            return nil
        }

        private static let sizeRegex = try? NSRegularExpression(
            pattern: "([0-9]+(?:\\.[0-9]+)?)\\s*(GB|MB)")

        private static func parseSizeGb(_ text: String) -> Double {
            guard let re = sizeRegex else { return 0 }
            let ns = text as NSString
            guard let m = re.firstMatch(in: text, range: NSRange(
                      location: 0, length: ns.length)),
                  let v = Double(ns.substring(with: m.range(at: 1)))
            else { return 0 }
            return ns.substring(with: m.range(at: 2)) == "MB" ? v / 1024.0 : v
        }

        private static func providerOf(_ name: String) -> Int {
            // Torrentio grammar: the name opens with the
            // provider badge — "[TB+]", "[RD+]", "[PM+]".
            // MediaFusion grammar: "… 🧲 TRB ⚡️ 2160p" / PM / RD.
            if name.hasPrefix("[TB") || name.contains(" TRB ") { return 3 }
            if name.hasPrefix("[RD") || name.contains(" RD ") { return 2 }
            if name.hasPrefix("[PM") || name.contains(" PM ") { return 1 }
            return 0
        }
    }

    /// Release identity: the parsed fingerprint first
    /// (resolution + source class + size — the same file
    /// prints the same size through every gateway and
    /// provider, so Torrentio's and MediaFusion's rows for
    /// one release collide here even though MF rows carry
    /// no infoHash); the infoHash is the fallback, and a row
    /// with neither keys unique and is never deduped away.
    private static func releaseKey(_ s: TorStream, _ f: RankFeat) -> String {
        if f.sizeGb > 0 && f.res > 0 {
            return "f:\(f.res)|\(f.cls)|\(Int((f.sizeGb * 100).rounded()))"
        }
        if !s.infoHash.isEmpty { return "h:" + s.infoHash.lowercased() }
        return "u:" + s.id.uuidString
    }

    /// Within one release, the route that stays: playable
    /// beats hash-only, cached beats awaiting, then the
    /// owner's measured provider speed (TorBox >
    /// Real-Debrid > Premiumize), then Torrentio's proven
    /// resolve path over MediaFusion's, then seeders.
    private static func routeBefore(_ a: RankFeat, _ b: RankFeat) -> Bool {
        if a.playClass != b.playClass { return a.playClass < b.playClass }
        if a.provider != b.provider { return a.provider > b.provider }
        if a.tor != b.tor { return a.tor }
        return a.seeders > b.seeders
    }

    /// The owner's ranking: fastest first — a link that plays
    /// now beats one the debrid still has to fetch; CAM
    /// vetoed to the bottom of its playability class; then
    /// highest quality (resolution, source class, DV/HDR
    /// bonus); then seeders; then provider speed.
    private static func rankBefore(_ a: RankFeat, _ b: RankFeat) -> Bool {
        if a.playClass != b.playClass { return a.playClass < b.playClass }
        if a.cam != b.cam { return !a.cam }
        let qa = a.res * 100 + a.cls + (a.dv ? 6 : 0) + (a.hdr ? 3 : 0)
        let qb = b.res * 100 + b.cls + (b.dv ? 6 : 0) + (b.hdr ? 3 : 0)
        if qa != qb { return qa > qb }
        if a.seeders != b.seeders { return a.seeders > b.seeders }
        return a.provider > b.provider
    }

    /// Dedupe a pooled list to one row per release, then
    /// sort best-first.
    static func rankPool(_ pool: [TorStream]) -> [TorStream] {
        var feats: [UUID: RankFeat] = [:]
        var best: [String: TorStream] = [:]
        var keys: [String] = []
        for s in pool {
            let f = RankFeat.of(s)
            feats[s.id] = f
            let k = releaseKey(s, f)
            if let cur = best[k], let cf = feats[cur.id] {
                if routeBefore(f, cf) { best[k] = s }
            } else {
                best[k] = s
                keys.append(k)
            }
        }
        return keys.compactMap { best[$0] }.sorted { a, b in
            guard let fa = feats[a.id], let fb = feats[b.id] else { return false }
            return rankBefore(fa, fb)
        }
    }

    // MARK: - MediaFusion live sport events (Thể Thao Torrent tab)

    /// The live content of the owner's MediaFusion profile
    /// for the Thể Thao Torrent tab. Fail-soft throughout.
    ///
    /// v2.0.16 shape (superseded): the tab queried ONLY the
    /// manifest-template catalog `live_sport_events` (type
    /// "events"). On the owner's TV the tab then stood empty
    /// all day (2026-11-17) even though his profile also
    /// carries NEWS / live-TV channels — standing channels,
    /// populated 24/7, which live in MediaFusion's type "tv"
    /// catalogs and could never appear through the events
    /// endpoint.
    ///
    /// v2.0.21 (manifest-driven): read the profile's own
    /// manifest, enumerate the catalogs it actually exposes,
    /// and fetch every LIVE one — type "events" and type
    /// "tv" (movie/series catalogs are skipped; the pooled
    /// film path is a separate, working route). Each catalog
    /// keeps the wave discipline measured in v2.0.16 (the
    /// endpoints answer in waves: two attempts, 2 s apart,
    /// 12 s timeout each). Metas merge across catalogs,
    /// deduped by id, capped at the tab's limit of 60.
    ///
    /// v2.0.22 (events first): the merge order is a STABLE
    /// PARTITION of the manifest order — every "events"
    /// catalog's metas land before every "tv" catalog's,
    /// each group keeping its manifest order. In pure
    /// manifest order the standing live-TV channels (populated
    /// 24/7, ~150 of them on the owner's profile) filled the
    /// merge — and the cap — ahead of the actual sport events
    /// the tab exists for, so events sat buried below the
    /// channel list (the Sony build proved the same fault and
    /// the same cure on 2026-11-17; the ordering design is
    /// ported here in this code's own shape, not its code).
    ///
    /// Fallback: if the manifest cannot be fetched or
    /// parsed, the fetch degrades to the v2.0.16 plain
    /// `live_sport_events` query, unchanged — never worse
    /// than the pre-fix behaviour.
    static func fetchMfSportEvents(base: String) async -> MfSportEventsResult {
        if let manifest = try? await JoeHTTP.getJSON(
                base + "/manifest.json", timeout: 12),
           let catalogs = JSON.arr(manifest, "catalogs") {
            let manifestLive: [(type: String, id: String)] = catalogs.compactMap { c in
                let t = JSON.str(c, "type")
                let i = JSON.str(c, "id")
                guard t == "events" || t == "tv", !i.isEmpty else { return nil }
                return (type: t, id: i)
            }
            // v2.0.22: stable partition — events catalogs
            // first (manifest order), then tv catalogs
            // (manifest order). See the doc comment above.
            let live = manifestLive.filter { $0.type == "events" }
                + manifestLive.filter { $0.type == "tv" }
            guard !live.isEmpty else {
                return MfSportEventsResult(metas: [],
                                           manifestLiveCatalogs: false)
            }
            var merged: [TorMeta] = []
            var seen = Set<String>()
            for cat in live {
                let url = base + "/catalog/\(cat.type)/\(cat.id).json"
                for attempt in 0..<2 {
                    if attempt > 0 {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                    }
                    if let root = try? await JoeHTTP.getJSON(url, timeout: 12) {
                        let metas = parseMetas(JSON.arr(root, "metas"))
                        if !metas.isEmpty {
                            for var m in metas where seen.insert(m.id).inserted {
                                // v2.0.24: stamp the serving
                                // base (see TorMeta.servingBase).
                                m.servingBase = base
                                merged.append(m)
                            }
                            break
                        }
                    }
                }
            }
            return MfSportEventsResult(metas: Array(merged.prefix(60)),
                                       manifestLiveCatalogs: true)
        }
        // Fallback — the v2.0.16 plain events fetch, verbatim.
        let plainURL = base + "/catalog/events/live_sport_events.json"
        for attempt in 0..<2 {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            if let root = try? await JoeHTTP.getJSON(plainURL, timeout: 12) {
                let metas = parseMetas(JSON.arr(root, "metas"))
                if !metas.isEmpty {
                    return MfSportEventsResult(
                        metas: metas.map { var m = $0; m.servingBase = base; return m },
                        manifestLiveCatalogs: nil)
                }
            }
        }
        return MfSportEventsResult(metas: [], manifestLiveCatalogs: nil)
    }

    // MARK: - Nuvio / StremVerse live sports (v2.0.24, Sony 2.3.37 port)

    /// The Nuvio live-catalog allowlist, in tab order (the
    /// Sony list, verified against the live manifest
    /// 2026-11-17/18): Live Now first, the per-sport live
    /// catalogs, the 24/7 Networks shelf, Upcoming last.
    /// Every other id the instance declares is a replay
    /// shelf (`nuvio_sports_replays*`) and stays out of the
    /// tab. Networks rides ahead of Upcoming so the
    /// always-on channels are never crowded out by
    /// not-yet-live fixtures at the merge cap.
    private static let nuvioLiveIDs = [
        "nuvio_sports_live",
        "nuvio_sports_football", "nuvio_sports_basketball",
        "nuvio_sports_hockey", "nuvio_sports_motorsport",
        "nuvio_sports_mma", "nuvio_sports_baseball",
        "nuvio_sports_tennis", "nuvio_sports_rugby",
        "nuvio_sports_american_football", "nuvio_sports_cricket",
        "nuvio_sports_golf", "nuvio_sports_darts",
        "nuvio_sports_college", "nuvio_sports_other",
        "nuvio_sports_networks",
        "nuvio_sports_upcoming",
    ]

    /// StremVerse's one in-app-playable catalog — its Xtra /
    /// IPTV catalogs answer externalUrl-only, which this app
    /// never reads (hunt report 2026-11-17).
    private static let stremverseLiveIDs = ["stremverse_live_events"]

    /// The two catalogs whose page 2 carries content the tab
    /// exists for: the Premier League fixture tiles sit at
    /// idx 175+ of football and idx 141+ of upcoming
    /// (PL-CHECK, 2026-11-18), so these two are fetched
    /// through every page (Stremio `skip=` paging, 100 metas
    /// per page) while every other catalog stays at page 1,
    /// exactly as on Sony. Measured on the live instance
    /// 2026-11-18: football 265 metas (3 pages), upcoming
    /// 397 (4 pages), both fully paged here.
    private static let sportsPagedIDs: Set<String> = [
        "nuvio_sports_football", "nuvio_sports_upcoming",
    ]

    /// The sports merge cap. Sony's 260 was calibrated to
    /// its page-1-only fetches; with football and upcoming
    /// paged in full (above), the measured merge on the live
    /// instance (2026-11-18) puts the Live Now + football
    /// core at 351 unique metas and the PL fixtures at
    /// merged idx 279/291 — a 260 cap would cut exactly the
    /// fixtures the paging exists to surface. 400 is the
    /// smallest round cap that carries the measured core
    /// with headroom; the grid is lazy, and the cap still
    /// bounds the tab on a catalogue-growth day.
    private static let sportsMergeCap = 400

    /// The Thể Thao Torrent tab's fetch, v2.0.24: Nuvio
    /// FIRST (its own stored base — the MF base is never
    /// repointed, it also feeds the movie paths),
    /// MediaFusion as the fallback when Nuvio settles empty,
    /// StremVerse's live-events catalog third. Only ONE
    /// source's list is used — the first that settles
    /// non-empty — and every returned meta carries its
    /// serving base (TorMeta.servingBase) so the play path
    /// resolves streams from the same addon. Fail-soft: an
    /// empty list when every source is empty or down.
    /// `manifestLiveCatalogs` combines the legs for the
    /// tab's empty state: true when any leg's manifest read
    /// clean and declared live catalogs, false when a
    /// manifest read clean and NONE did, nil when no
    /// manifest could be read at all.
    static func fetchSportsEvents() async -> MfSportEventsResult {
        var combined: Bool? = nil
        func note(_ leg: Bool?) {
            if leg == true { combined = true }
            else if leg == false && combined == nil { combined = false }
        }
        if let base = TorrentSettings.sportsBase {
            let r = await fetchLiveScoped(base: base, allowlist: nuvioLiveIDs)
            if !r.metas.isEmpty { return r }
            note(r.manifestLiveCatalogs)
        }
        if let mf = TorrentSettings.mfBase {
            let r = await fetchMfSportEvents(base: mf)
            if !r.metas.isEmpty { return r }
            note(r.manifestLiveCatalogs)
        }
        if let base = TorrentSettings.sports2Base {
            let r = await fetchLiveScoped(base: base, allowlist: stremverseLiveIDs)
            if !r.metas.isEmpty { return r }
            note(r.manifestLiveCatalogs)
        }
        return MfSportEventsResult(metas: [], manifestLiveCatalogs: combined)
    }

    /// One manifest-driven live fetch scoped to an allowlist
    /// of catalog ids, merged in allowlist order: read the
    /// manifest, keep the declared live catalogs (type
    /// "events" / "tv") whose id is allowlisted, fetch each
    /// (the paged set through all its pages, the rest page 1
    /// only), and merge deduped by id — the earliest
    /// allowlist catalog to carry an id wins it. Catalogs
    /// fetch concurrently; each page carries the house 12 s
    /// discovery budget and a failed page simply ends that
    /// catalog with what landed. Every meta is stamped with
    /// the serving base, and a meta not already carrying a
    /// live type inherits its catalog's type (the Sony
    /// stampLiveType rule — a live meta must resolve its
    /// streams under its own live type). A manifest that
    /// reads clean but declares none of the allowlisted
    /// catalogs reports manifestLiveCatalogs = false.
    private static func fetchLiveScoped(base: String, allowlist: [String])
        async -> MfSportEventsResult {
        guard let manifest = try? await JoeHTTP.getJSON(
                base + "/manifest.json", timeout: 12),
              let catalogs = JSON.arr(manifest, "catalogs") else {
            return MfSportEventsResult(metas: [], manifestLiveCatalogs: nil)
        }
        var declared: [String: String] = [:]   // id → type
        for c in catalogs {
            let t = JSON.str(c, "type")
            let i = JSON.str(c, "id")
            guard t == "events" || t == "tv", !i.isEmpty,
                  allowlist.contains(i) else { continue }
            declared[i] = t
        }
        let ordered: [(type: String, id: String)] = allowlist.compactMap { id in
            declared[id].map { (type: $0, id: id) }
        }
        guard !ordered.isEmpty else {
            return MfSportEventsResult(metas: [], manifestLiveCatalogs: false)
        }
        // Fetch concurrently, collect per catalog, merge in
        // allowlist order below (never in completion order).
        let perCatalog: [[TorMeta]] = await withTaskGroup(
            of: (Int, [TorMeta]).self
        ) { group in
            for (idx, cat) in ordered.enumerated() {
                group.addTask {
                    (idx, await fetchSportsCatalog(
                        base: base, type: cat.type, id: cat.id,
                        paged: sportsPagedIDs.contains(cat.id)))
                }
            }
            var slots = [[TorMeta]](repeating: [], count: ordered.count)
            for await (idx, metas) in group { slots[idx] = metas }
            return slots
        }
        var merged: [TorMeta] = []
        var seen = Set<String>()
        for (idx, cat) in ordered.enumerated() {
            for var m in perCatalog[idx] {
                if m.type != "events" && m.type != "tv" { m.type = cat.type }
                m.servingBase = base
                if seen.insert(m.id).inserted { merged.append(m) }
            }
        }
        return MfSportEventsResult(metas: Array(merged.prefix(sportsMergeCap)),
                                   manifestLiveCatalogs: true)
    }

    /// One sports catalog, page by page when `paged`: page 1
    /// plainly, then `skip=` pages of 100 until a short page
    /// answers or the 5-page bound is hit. Fail-soft per
    /// page — an error ends the catalog with what landed.
    private static func fetchSportsCatalog(base: String, type: String,
                                           id: String, paged: Bool)
        async -> [TorMeta] {
        var out: [TorMeta] = []
        var skip = 0
        while true {
            let url = skip == 0
                ? base + "/catalog/\(type)/\(id).json"
                : base + "/catalog/\(type)/\(id)/skip=\(skip).json"
            guard let root = try? await JoeHTTP.getJSON(url, timeout: 12)
            else { break }
            let page = parseMetas(JSON.arr(root, "metas"))
            out += page
            if !paged || page.count < 100 { break }
            skip += 100
            if skip > 400 { break }
        }
        return out
    }

    /// Stream fetch for the sports tab's live sources
    /// (Nuvio / StremVerse / MF-served sports metas). Same
    /// Stremio envelope and budget as fetchStreams, but its
    /// own SourceHealth provider tag ("live") and gateway
    /// tag ("LIVE"), so the MF rows' ⚡️ cache grammar
    /// (TorStream.awaitingDisplay) never mislabels a direct
    /// live row as awaiting debrid (the Sony rule). Live
    /// streams play direct, no tunnel — unchanged.
    static func fetchStreamsLive(base: String, type: String, id: String)
        async throws -> [TorStream] {
        try await fetchStreams(addonBase: base, type: type, id: id,
                               gateway: "LIVE", provider: "live")
    }

    // MARK: - Play candidates (shared conversion)

    /// Direct URL, or a hash resolved through the owner's own
    /// Real-Debrid account. Fail-soft to nil. (Moved here from
    /// JoeTorrentDetail: both play paths below share it, so the
    /// RD behaviour can never drift between them.)
    /// v2.0.5 (error 8a): a direct URL on the ADDON's host is
    /// Torrentio's /resolve/ redirector — a bare 302 hop to the
    /// debrid CDN. The listing path (URLSession) follows it
    /// natively, but the FFmpeg media stack fails to open the
    /// redirector itself, so EVERY candidate died identically
    /// while the list loaded fine. Following the Android
    /// discipline (DirectNet.resolveFinalUrl pre-resolves for
    /// players that cannot ride the hop), the redirect chain
    /// is followed HERE and the engine receives the FINAL CDN
    /// URL. Fail-soft: any probe failure returns the original
    /// URL, exactly the pre-fix behaviour.
    static func resolvePlayable(_ s: TorStream) async -> URL? {
        if s.playable {
            guard let raw = URL(string: s.url) else { return nil }
            if isAddonHost(raw) { return await preResolved(raw) }
            return raw
        }
        guard !s.infoHash.isEmpty else { return nil }
        // v2.0.5 (N7): the EFFECTIVE token (stored wins,
        // bundled fallback) — same resolution as
        // effectiveBase above.
        let token = TorrentSettings.effectiveRDToken
        guard !token.isEmpty else { return nil }
        do {
            let r = try await RdClient.resolve(
                token: token, infoHash: s.infoHash, fileIdx: s.fileIdx)
            return URL(string: r.url)
        } catch {
            // v2.0.5 (error 8a): the failure is LOGGED, not
            // swallowed by a bare `try?` — an RD failure and a
            // dead URL used to be indistinguishable after the
            // fact. Behaviour stays fail-soft (nil).
            PlaybackLog.logger.error(
                "RD resolve failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// True when the URL lives on the configured addon host —
    /// the only URLs that are /resolve/ redirectors. Debrid
    /// CDN URLs (from RdClient) and any other direct URL pass
    /// through pre-resolution untouched.
    private static func isAddonHost(_ url: URL) -> Bool {
        guard let base = TorrentSettings.effectiveBase,
              let baseHost = URL(string: base)?.host,
              let host = url.host
        else { return false }
        return host.caseInsensitiveCompare(baseHost) == .orderedSame
    }

    /// Session cache of /resolve/ → final-URL results, keyed
    /// by the source URL string. Debrid download links live
    /// for hours; a session is far shorter, and re-probing the
    /// same title on every ladder rebuild would only add
    /// latency. Guarded by a lock: playCandidates probes
    /// concurrently.
    private static var finalURLCache: [String: URL] = [:]
    private static let finalURLCacheLock = NSLock()

    /// The final URL at the end of the redirect chain, or the
    /// original URL when the chain cannot be followed (error,
    /// timeout ≤ 8 s, or no redirect at all).
    private static func preResolved(_ url: URL) async -> URL {
        let key = url.absoluteString
        finalURLCacheLock.lock()
        let cached = finalURLCache[key]
        finalURLCacheLock.unlock()
        if let cached { return cached }
        let probe = RedirectProbe()
        guard let final = await probe.run(url: url, timeout: 8) else {
            PlaybackLog.logger.error(
                "pre-resolve failed host=\(url.host ?? "?", privacy: .public) — falling back to the original URL")
            return url
        }
        finalURLCacheLock.lock()
        finalURLCache[key] = final
        finalURLCacheLock.unlock()
        return final
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
    /// stream (TorStream.playable), in list order.
    /// v2.0.3: every candidate is tagged .ffmpeg (the KSPlayer
    /// engine — Torrentio's files are predominantly Matroska,
    /// which AVPlayer cannot open at all), and the walk is
    /// capped at 6, the Android ladder's MAX_TRIES: Torrentio
    /// ranks by quality/seeds, so the head of the list is where
    /// a working file lives; the old uncapped walk could burn
    /// a dozen-plus attempts behind one unchanging label before
    /// the exhausted slate appeared. `labelPrefix` marks the
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
            // v2.0.5 (error 8a, H6): the stream's own
            // proxyHeaders ride into the candidate — pre-fix
            // they were parsed at fetch time and read NOWHERE,
            // so a stream whose media leg required its Referer
            // or User-Agent failed on tvOS while Android (which
            // forwards them) played it.
            // v2.0.26 (idea 10): the stream's parsed display
            // features ride onto the candidate (see
            // TorStream.dv) for the KSPlayer host's
            // preferredDisplayCriteria.
            var leadCandidate = PlayCandidate(url: url,
                                              headers: match.proxyHeaders,
                                              label: label(match),
                                              engine: .ffmpeg)
            leadCandidate.dv = match.dv
            leadCandidate.hdr = match.hdr
            leadCandidate.fps = match.fps
            out.append(leadCandidate)
        }
        // Remaining direct-URL streams, in list order. Each
        // goes through resolvePlayable too (v2.0.5): the
        // /resolve/ pre-resolution must cover EVERY candidate
        // the ladder can reach, not only the lead — pre-fix
        // this loop copied s.url verbatim. The probes run
        // concurrently (one round-trip class of latency for
        // the whole list, not one per candidate); results are
        // slotted back into list order.
        let rest = streams.filter { s in
            guard s.playable else { return false }
            if let lead, s.name == lead.name && s.title == lead.title {
                return false
            }
            return true
        }
        let resolved: [URL?] = await withTaskGroup(
            of: (Int, URL?).self
        ) { group in
            for (i, s) in rest.enumerated() {
                group.addTask { (i, await resolvePlayable(s)) }
            }
            var slots = [URL?](repeating: nil, count: rest.count)
            for await (i, u) in group { slots[i] = u }
            return slots
        }
        for (s, url) in zip(rest, resolved) {
            if let url {
                // v2.0.26 (idea 10): same display-feature
                // stamp as the lead candidate above.
                var candidate = PlayCandidate(url: url,
                                              headers: s.proxyHeaders,
                                              label: label(s),
                                              engine: .ffmpeg)
                candidate.dv = s.dv
                candidate.hdr = s.hdr
                candidate.fps = s.fps
                out.append(candidate)
            }
        }
        return Array(out.prefix(6))
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

/// Follows a redirect chain WITHOUT downloading the body:
/// the data task is cancelled the moment the final response's
/// headers arrive, and the response's URL — the chain's end —
/// is the result. This is what turns Torrentio's /resolve/
/// 302 into the debrid CDN URL the media stack opens
/// directly, at the cost of one headers-only round trip
/// (a Range header is sent as well, as a second guard
/// against a server that would otherwise stream the file).
/// Redirects are followed by the session's default policy;
/// the delegate only observes the final response.
///
/// v2.0.8 (P3f): ONE shared session is reused across all
/// probes (pre-fix, every probe built a new ephemeral
/// session, defeating connection reuse). The probe's
/// semantics are unchanged — 8 s request/resource budgets,
/// the same headers, the same cancel-on-headers behaviour.
/// Because the session (and therefore its delegate) is now
/// shared, no per-probe state lives on the delegate: each
/// task's continuation and captured final URL are held in
/// the delegate's registry keyed by taskIdentifier, and the
/// shared session is NEVER invalidated (the per-probe
/// invalidateAndCancel is gone — it would kill the pool).
private final class RedirectProbe: NSObject {
    /// The shared session's delegate: a registry of in-flight
    /// probes keyed by taskIdentifier. It holds no state of
    /// its own beyond that per-task registry.
    private final class SessionDelegate: NSObject, URLSessionDataDelegate {
        private struct ProbeState {
            var continuation: CheckedContinuation<URL?, Never>
            var finalURL: URL?
        }

        private let lock = NSLock()
        private var states: [Int: ProbeState] = [:]

        func register(taskIdentifier: Int,
                      continuation: CheckedContinuation<URL?, Never>) {
            lock.lock()
            states[taskIdentifier] = ProbeState(
                continuation: continuation, finalURL: nil)
            lock.unlock()
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                        didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            lock.lock()
            states[dataTask.taskIdentifier]?.finalURL = response.url
            lock.unlock()
            completionHandler(.cancel)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        didCompleteWithError error: Error?) {
            // Fires for every ending — the cancel above, a
            // timeout, a network error. Whatever response URL
            // was captured for THIS task (nil when none
            // arrived) is the answer. The shared session is
            // deliberately NOT invalidated here.
            lock.lock()
            let state = states.removeValue(forKey: task.taskIdentifier)
            lock.unlock()
            state?.continuation.resume(returning: state?.finalURL)
        }
    }

    private static let sharedDelegate = SessionDelegate()
    private static let sharedSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        // The probe's budgets, exactly as the per-probe
        // sessions carried them: the sole call site
        // (preResolved) probes with timeout 8, and the
        // per-request timeoutInterval in run() still carries
        // the caller's `timeout` on every request.
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 8
        return URLSession(configuration: config,
                          delegate: RedirectProbe.sharedDelegate, delegateQueue: nil)
    }()

    /// The chain's final URL, or nil on any failure (DNS,
    /// TLS, timeout — the session's request/resource budgets
    /// bound the probe end to end, the house JoeHTTP
    /// discipline).
    func run(url: URL, timeout: TimeInterval) async -> URL? {
        await withCheckedContinuation { cont in
            var req = URLRequest(url: url)
            req.timeoutInterval = timeout
            req.setValue(JoeHTTP.userAgent, forHTTPHeaderField: "User-Agent")
            req.setValue("bytes=0-0", forHTTPHeaderField: "Range")
            let task = RedirectProbe.sharedSession.dataTask(with: req)
            RedirectProbe.sharedDelegate.register(
                taskIdentifier: task.taskIdentifier, continuation: cont)
            task.resume()
        }
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
        // The addon's fileIdx, when present, is honoured
        // exactly — it is the addon's own choice; otherwise the
        // largest file (the feature, not a sample or extra).
        // The B-5-era preference for the largest AVPlayer-native
        // container is retired with the gate itself (v2.0.3):
        // the torrent engine is FFmpeg now, and the preference
        // could pick a small .mp4 sample over the .mkv feature.
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
