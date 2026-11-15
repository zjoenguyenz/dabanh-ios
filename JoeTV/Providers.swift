import Foundation

/// Provider registry for the aggregated Phim library — port of
/// the Android Providers (Joe TV v1.5.1, verified on device;
/// v1.1 brings the tvOS app to parity with Android v1.9.2).
/// The providers the owner kept on 2026-11-14:
///   kk      KKPhim     — phimapi.com + mirror hosts in KkClient
///   f4k     Film4K.net — film4k.net, own API + TikTok CDN
///   vsmov   VSMOV      — vsmov.com, own API + own CDN
///   tp      Tủ Phim    — api.phimsrv.com, Gold layer only, plus
///                        the CacheVideo backup server on its
///                        details (TpClient / CacheVideo)
/// Priority for dedupe + cross-provider failover: KK > F4K > VS > TP.
///
/// RapPhim was REMOVED entirely by owner order 2026-11-14 00:09
/// CST (its CDN fails from his house; short-lived /f/ tokens) —
/// no rails, no search, no chips, no failover hop, and the HLS
/// proxy that existed only for it is gone with it.
/// ADDENDUM RULE (owner, 2026-11-13): stream URLs are plumbing —
/// resolved FRESH at every play tap / resume / refresh / failover
/// hop, and never written to WatchStore, prefs or any list file.
/// Everything here deals in provider + slug + episode identity
/// only. NguonC is deliberately absent: device tests showed its
/// episodes are embed-only with no playable m3u8.
enum Providers {
    static let KK = "kk"
    static let F4K = "f4k"
    static let VS = "vsmov"
    static let TP = "tp"
    static let priority = [KK, F4K, VS, TP]

    static func displayName(_ code: String) -> String {
        switch code {
        case F4K: return "Film4K"
        case VS: return "VSMOV"
        case TP: return "Tủ Phim"
        default: return "KKPhim"
        }
    }

    static func badge(_ code: String) -> String {
        switch code {
        case F4K: return "F4K"
        case VS: return "VS"
        case TP: return "TP"
        default: return "KK"
        }
    }

    /// WatchStore kind string for a provider.
    static func kindOf(_ code: String) -> String {
        switch code {
        case F4K: return WatchStore.kindF4K
        case VS: return WatchStore.kindVS
        case TP: return WatchStore.kindTP
        default: return WatchStore.kindKK
        }
    }

    static func progressKey(_ code: String, slug: String, epName: String) -> String {
        switch code {
        case F4K: return WatchStore.f4kProgressKey(slug: slug, epName: epName)
        case VS: return WatchStore.vsProgressKey(slug: slug, epName: epName)
        case TP: return WatchStore.tpProgressKey(slug: slug, epName: epName)
        default: return WatchStore.kkProgressKey(slug: slug, epName: epName)
        }
    }

    // MARK: - Catalogue dispatch

    /// One catalogue (list) request, provider-agnostic. Splitting
    /// fetch from parse lets PhimStore cache the RAW response of
    /// each rail job and re-parse it on the next launch with no
    /// network (the TVStore cache-first pattern). Genre/country
    /// requests exist only on KKPhim; the other providers are
    /// never asked for them.
    enum ListRequest {
        case newest(page: Int)
        case byType(type: String, page: Int)
        case genre(slug: String, page: Int)
        case country(slug: String, page: Int, limit: Int?)
    }

    static func fetchListRaw(_ code: String, _ req: ListRequest) async throws -> [String: Any] {
        switch req {
        case .genre(let slug, let page):
            return try await KkClient.listByGenreRaw(slug, page: page)
        case .country(let slug, let page, let limit):
            return try await KkClient.listByCountryRaw(slug, page: page, limit: limit)
        case .newest(let page):
            switch code {
            case F4K: return try await F4kClient.newestRaw(page: page)
            case VS: return try await VsClient.newestRaw(page: page)
            case TP: return try await TpClient.newestRaw(page: page)
            default: return try await KkClient.newestRaw(page: page)
            }
        case .byType(let type, let page):
            switch code {
            case F4K: return try await F4kClient.listByTypeRaw(type, page: page)
            case VS: return try await VsClient.listByTypeRaw(type, page: page)
            case TP: return try await TpClient.listByTypeRaw(type, page: page)
            default: return try await KkClient.listByTypeRaw(type, page: page)
            }
        }
    }

    static func parseList(_ code: String, _ req: ListRequest, _ root: [String: Any]) -> [Movie] {
        switch req {
        case .genre, .country:
            return KkClient.parseItems(root)
        case .newest:
            switch code {
            case F4K: return F4kClient.parseNewest(root)
            case VS: return VsClient.parseList(root)
            case TP: return TpClient.parseItems(root)
            default: return KkClient.parseItems(root)
            }
        case .byType(let type, let page):
            switch code {
            case F4K: return F4kClient.parseListByType(root, type: type, page: page)
            case VS: return VsClient.parseList(root)
            case TP: return TpClient.parseItems(root)
            default: return KkClient.parseItems(root)
            }
        }
    }

    static func newest(_ code: String, page: Int) async throws -> [Movie] {
        let req = ListRequest.newest(page: page)
        return parseList(code, req, try await fetchListRaw(code, req))
    }

    static func listByType(_ code: String, type: String, page: Int) async throws -> [Movie] {
        let req = ListRequest.byType(type: type, page: page)
        return parseList(code, req, try await fetchListRaw(code, req))
    }

    static func kkGenre(_ slug: String, page: Int) async throws -> [Movie] { try await KkClient.listByGenre(slug, page: page) }

    static func kkCountry(_ slug: String, page: Int) async throws -> [Movie] { try await KkClient.listByCountry(slug, page: page) }

    static func kkCountry(_ slug: String, page: Int, limit: Int) async throws -> [Movie] { try await KkClient.listByCountry(slug, page: page, limit: limit) }

    static func search(_ code: String, keyword: String) async throws -> [Movie] {
        switch code {
        case F4K: return try await F4kClient.search(keyword)
        case VS: return try await VsClient.search(keyword)
        case TP: return try await TpClient.search(keyword)
        default: return try await KkClient.search(keyword)
        }
    }

    static func detail(_ code: String, slug: String) async throws -> Detail {
        switch code {
        case F4K: return try await F4kClient.detail(slug)
        case VS: return try await VsClient.detail(slug)
        case TP: return try await TpClient.detail(slug)
        default: return try await KkClient.detail(slug)
        }
    }

    // MARK: - Title normalization / dedupe

    /// Lowercase, strip diacritics, collapse every non-alphanumeric
    /// run to one space, trim. "Siêu Nhân Tiga!" and "sieu nhan
    /// tiga" normalize equal.
    static func normalizeTitle(_ s: String) -> String {
        var n = s.folding(options: .diacriticInsensitive, locale: nil)
        n = n.replacingOccurrences(of: "đ", with: "d")
            .replacingOccurrences(of: "Đ", with: "d")
            .lowercased()
        var out = ""
        var lastWasSpace = true
        for ch in n {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
                lastWasSpace = false
            } else if !lastWasSpace {
                out.append(" ")
                lastWasSpace = true
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// First 4-digit run in a year string ("2026" → "2026").
    static func yearOf(_ year: String) -> String {
        let chars = Array(year)
        guard chars.count >= 4 else { return "" }
        for i in 0...(chars.count - 4) {
            if chars[i].isNumber && chars[i + 1].isNumber
                && chars[i + 2].isNumber && chars[i + 3].isNumber {
                return String(chars[i..<i + 4])
            }
        }
        return ""
    }

    static func yearOf(_ m: Movie) -> String { yearOf(m.year) }

    static func filmKey(name: String, year: String) -> String {
        normalizeTitle(name) + "|" + year.trimmingCharacters(in: .whitespaces)
    }

    /// True when candidate c is plausibly the same film as the
    /// target: a normalized title match on name or origin name
    /// (either direction), and years equal or either side empty.
    static func sameFilm(_ c: Movie, name: String, origin: String, year: String) -> Bool {
        let cy = yearOf(c), ty = yearOf(year)
        if !cy.isEmpty && !ty.isEmpty && cy != ty { return false }
        let nn = normalizeTitle(name), no = normalizeTitle(origin)
        let cn = normalizeTitle(c.name), co = normalizeTitle(c.originName)
        if !nn.isEmpty && (nn == cn || (!co.isEmpty && nn == co)) { return true }
        if !no.isEmpty && (no == cn || (!co.isEmpty && no == co)) { return true }
        return false
    }

    /// Merge lists in the order given (callers pass priority
    /// order), dropping later duplicates of an already-kept film.
    static func mergeDedupe(_ lists: [[Movie]]) -> [Movie] {
        var kept: [Movie] = []
        for list in lists {
            for m in list where !m.slug.isEmpty {
                if !kept.contains(where: { sameFilm(m, name: $0.name, origin: $0.originName, year: yearOf($0)) }) {
                    kept.append(m)
                }
            }
        }
        return kept
    }

    // MARK: - Episode identity

    /// Canonical episode names for providers that ship bare
    /// numbers (VSMOV: "1" → "Tập 1"). NOT applied to KKPhim —
    /// its parser passes names through raw and stored resume
    /// keys hold those raw names.
    static func canonEpName(_ raw: String, position: Int) -> String {
        let n = raw.trimmingCharacters(in: .whitespaces)
        if n.isEmpty { return "Tập \(position)" }
        if n.allSatisfy({ $0.isNumber }), let v = Int(n) { return "Tập \(v)" }
        if n.allSatisfy({ $0.isNumber }) { return "Tập \(n)" }
        return n
    }

    /// The episode NUMBER in a display name: the LAST integer run
    /// ("Tập 01" → 1, "S2 · Tập 3" → 3, "Full" → -1).
    static func episodeNumber(_ epName: String) -> Int {
        var last = -1
        var current = ""
        for ch in epName + " " {
            if ch.isNumber {
                current.append(ch)
            } else {
                if let v = Int(current) { last = v }
                current = ""
            }
        }
        return last
    }

    /// The SEASON number an episode name carries, when it
    /// carries one: "S2 · Tập 3" / "S02E03" → 2, "Season 2" /
    /// "Mùa 2" → 2. nil when the name is season-free — the KK
    /// norm (bare "Tập N" under a per-season detail page, whose
    /// Movie.tmdbSeason carries the season instead). Used by
    /// the substitution rung to address Torrentio series
    /// streams as imdbId:season:episode.
    static func seasonNumber(_ epName: String) -> Int? {
        let lower = epName.lowercased()
        for marker in ["season ", "mùa "] {
            if let r = lower.range(of: marker) {
                let digits = String(lower[r.upperBound...].prefix { $0.isNumber })
                if let v = Int(digits), v > 0 { return v }
            }
        }
        // Sxx marker: an "s" at a word boundary followed by
        // digits (S2, S02E03, "S2 · …"). The boundary check
        // keeps ordinary words ("Season" itself has no digits
        // after its s) from firing.
        var idx = lower.startIndex
        while idx < lower.endIndex {
            if lower[idx] == "s",
               idx == lower.startIndex
                || !lower[lower.index(before: idx)].isLetter {
                let after = lower.index(after: idx)
                let digits = String(lower[after...].prefix { $0.isNumber })
                if let v = Int(digits), v > 0 { return v }
            }
            idx = lower.index(after: idx)
        }
        return nil
    }

    // MARK: - Play ladder (fresh resolution)

    /// One playable candidate: a freshly resolved URL plus how
    /// AVPlayer must reach it. proxy = true routes the stream
    /// through JoeProxy (PNG-prefixed segments and/or a
    /// header-gated CDN — see JoeProxy); headers are the extra
    /// headers the CDN demands, applied by the proxy upstream or
    /// by the player for direct candidates.
    struct LadderEntry {
        var url: String
        var title: String
        var proxy: Bool = false
        var headers: [String: String] = [:]
    }

    struct Ladder {
        var entries: [LadderEntry] = []
        var matchedEpName = ""
        var isEmpty: Bool { entries.isEmpty }
    }

    /// Build the play ladder for one episode of one provider's
    /// detail: match the episode by exact name first, then by
    /// episode number; one URL per server. Playable = non-empty
    /// m3u8, EXCEPT VSMOV whose episodes carry only an embed URL —
    /// those are resolved to master.m3u8 HERE, fresh, every call.
    static func ladderFor(code: String, detail d: Detail, filmTitle: String,
                          epName: String?, epNum: Int) async -> Ladder {
        var lad = Ladder()
        var byName: Episode?
        var byNum: Episode?
        for s in d.servers {
            for e in s.episodes {
                if byName == nil, let epName,
                   e.name.trimmingCharacters(in: .whitespaces).lowercased()
                    == epName.trimmingCharacters(in: .whitespaces).lowercased() {
                    byName = e
                }
                if byNum == nil && epNum > 0 && episodeNumber(e.name) == epNum {
                    byNum = e
                }
            }
        }
        guard let target = byName ?? byNum else { return lad }
        lad.matchedEpName = target.name
        for s in orderServers(code: code, servers: d.servers) {
            var pick: Episode?
            for e in s.episodes
            where e.name.trimmingCharacters(in: .whitespaces).lowercased()
                == target.name.trimmingCharacters(in: .whitespaces).lowercased() {
                pick = e
                break
            }
            if pick == nil && epNum > 0 {
                pick = s.episodes.first { episodeNumber($0.name) == epNum }
            }
            guard let pick, let resolved = await playableURL(code: code, episode: pick),
                  !resolved.url.isEmpty else { continue }
            lad.entries.append(LadderEntry(
                url: resolved.url,
                title: filmTitle + " · " + pick.name
                    + (d.servers.count > 1 ? " · " + s.name : ""),
                proxy: resolved.proxy, headers: resolved.headers))
        }
        return lad
    }

    /// The playable URL of one episode RIGHT NOW, or nil — plus
    /// its delivery route. VSMOV resolves its embed page live;
    /// Tủ Phim resolves its marker (Gold XOR hop / VSMOV page /
    /// CacheVideo) live; everyone else uses the m3u8 the
    /// (freshly fetched) detail returned. Proxy flags mirror the
    /// Android player's data-source routing: VSMOV, Tủ Phim and
    /// Film4K segments are PNG-disguised (the proxy strips the
    /// prefix — AVPlayer cannot resync like Media3 does), and
    /// CacheVideo segments are header-gated.
    static func playableURL(code: String, episode e: Episode)
        async -> (url: String, proxy: Bool, headers: [String: String])? {
        switch code {
        case VS:
            if !e.m3u8.isEmpty { return (e.m3u8, true, [:]) }
            if e.embed.isEmpty { return nil }
            guard let u = try? await VsClient.resolveStream(embedURL: e.embed)
            else { return nil }
            return (u, true, [:])
        case TP:
            if !e.m3u8.isEmpty { return (e.m3u8, true, [:]) }
            if e.embed.isEmpty { return nil }
            guard let u = try? await TpClient.resolveStream(marker: e.embed)
            else { return nil }
            let headers = e.embed.hasPrefix("cv:") ? CacheVideo.headers : [:]
            return (u, true, headers)
        case F4K:
            return e.m3u8.isEmpty ? nil : (e.m3u8, true, [:])
        default:
            return e.m3u8.isEmpty ? nil : (e.m3u8, false, [:])
        }
    }

    // MARK: - Predictor-ordered servers (consumer b)

    /// Predictor consumer (b) at ladder granularity: servers
    /// whose resolution path is currently LATCHED (demoted by
    /// SourceHealth) are resolved AFTER unlatched ones, so a
    /// dead-mode host is tried last instead of first. Stable:
    /// the provider's own server order stands inside each
    /// group, and with nothing latched the order is untouched.
    private static func orderServers(code: String, servers: [Server]) -> [Server] {
        guard servers.count > 1 else { return servers }
        let flagged = servers.map {
            (server: $0, demoted: serverDemoted(code: code, server: $0))
        }
        guard flagged.contains(where: { $0.demoted }) else { return servers }
        return flagged.filter { !$0.demoted }.map(\.server)
            + flagged.filter { $0.demoted }.map(\.server)
    }

    /// Whether one server's resolution path is latched, read
    /// from its first episode carrying resolution data (a
    /// server's episodes share one host family, so the first
    /// is representative). The latch keys are the SAME keys
    /// the resolvers record under:
    ///   VS embed        → (vsmov, resolve, embed host)
    ///   TP "cv:" marker → (tp, resolve, CacheVideo resolver)
    ///   TP "tpv:" page  → (vsmov, resolve, embed host) — it
    ///                     resolves through VsClient
    ///   TP "tp:" hash   → (tp, resolve, phimsrv) — only the
    ///                     host of the probe URL is read
    ///   direct m3u8     → (provider, playlist, playlist host)
    private static func serverDemoted(code: String, server: Server) -> Bool {
        for e in server.episodes {
            if code == VS {
                if !e.embed.isEmpty {
                    return SourceHealth.isLatched(
                        provider: Providers.VS, stage: .resolve, url: e.embed)
                }
                if !e.m3u8.isEmpty {
                    return SourceHealth.isLatched(
                        provider: Providers.VS, stage: .playlist, url: e.m3u8)
                }
            } else if code == TP {
                if e.embed.hasPrefix("cv:") {
                    return SourceHealth.isLatched(
                        provider: Providers.TP, stage: .resolve,
                        url: CacheVideo.resolver)
                }
                if e.embed.hasPrefix("tpv:") {
                    return SourceHealth.isLatched(
                        provider: Providers.VS, stage: .resolve,
                        url: String(e.embed.dropFirst(4)))
                }
                if e.embed.hasPrefix("tp:") {
                    return SourceHealth.isLatched(
                        provider: Providers.TP, stage: .resolve,
                        url: TpClient.base + "/embed/probe")
                }
                if !e.m3u8.isEmpty {
                    return SourceHealth.isLatched(
                        provider: Providers.TP, stage: .playlist, url: e.m3u8)
                }
            } else if !e.m3u8.isEmpty {
                return SourceHealth.isLatched(
                    provider: code, stage: .playlist, url: e.m3u8)
            }
        }
        return false
    }

    /// True when the episode can be played at all (drives chip
    /// greying): m3u8 present, or a resolvable embed/marker on
    /// VSMOV / Tủ Phim. Embed-only on any other provider → false.
    static func isPlayable(code: String, episode e: Episode) -> Bool {
        if !e.m3u8.isEmpty { return true }
        return (code == VS || code == TP) && !e.embed.isEmpty
    }

    // MARK: - Cross-provider lookup (session-cached)

    /// filmKey → (providerCode → slug). Only hits are stored;
    /// absence means "searched, not carried". Session-scoped —
    /// slugs are catalogue identity, not stream URLs, so caching
    /// them does not violate the fresh-resolution rule.
    /// Lock-guarded (C-15): findAlternatives runs from async
    /// contexts that can overlap; the pre-v1.9 plain static var
    /// was unsynchronised shared mutable state.
    private static let altCacheLock = NSLock()
    private static var altCache: [String: [String: String]] = [:]

    private static func altCacheGet(_ key: String) -> [String: String]? {
        altCacheLock.lock()
        defer { altCacheLock.unlock() }
        return altCache[key]
    }

    private static func altCacheSet(_ key: String, _ value: [String: String]) {
        altCacheLock.lock()
        altCache[key] = value
        altCacheLock.unlock()
    }

    /// Lock-guarded result box for the deadline-bounded
    /// alternative search below: the search runs in an
    /// unstructured task (so the deadline can abandon it
    /// mid-flight) and publishes progress here.
    private final class AltSearchBox {
        private let lock = NSLock()
        private var found: [String: String] = [:]
        private var finished = false
        func update(_ f: [String: String]) {
            lock.lock(); found = f; lock.unlock()
        }
        func finish(_ f: [String: String]) {
            lock.lock(); found = f; finished = true; lock.unlock()
        }
        var isFinished: Bool {
            lock.lock(); defer { lock.unlock() }; return finished
        }
        func snapshot() -> [String: String] {
            lock.lock(); defer { lock.unlock() }; return found
        }
    }

    /// The alternative list in failover order: priority order,
    /// except providers SourceHealth currently demotes (any
    /// live latch) sort after the healthy ones — predictor
    /// consumer (b) at hop granularity. Stable inside groups.
    private static func orderedAlternatives(
        found: [String: String], fromCode: String
    ) -> [(code: String, slug: String)] {
        let all = priority.filter { $0 != fromCode && found[$0] != nil }
            .map { (code: $0, slug: found[$0]!) }
        let healthy = all.filter { !SourceHealth.providerDemoted($0.code) }
        let demoted = all.filter { SourceHealth.providerDemoted($0.code) }
        return demoted.isEmpty ? all : healthy + demoted
    }

    /// Find which OTHER providers carry the same film. Returns
    /// a failover-ordered list of providerCode → slug, possibly
    /// empty.
    ///
    /// OVERALL DEADLINE 12 s (LATENCY-AUDIT §6): the searches
    /// run sequentially (up to 2 per provider at a 12 s list
    /// budget each — an unbounded worst case near 72 s), while
    /// the measured typical is 2.7–5.7 s total. The search
    /// therefore runs in a task the caller stops waiting on at
    /// 12 s; whatever it found by then is returned (the hop
    /// tries it), the task is cancelled, and a deadline-cut
    /// result is NOT written to the session cache — providers
    /// it never reached are "unsearched", not "not carried".
    static func findAlternatives(fromCode: String, name: String,
                                 origin: String, year: String) async -> [(code: String, slug: String)] {
        let key = filmKey(name: name, year: year) + "@" + fromCode
        if let hit = altCacheGet(key) {
            return orderedAlternatives(found: hit, fromCode: fromCode)
        }
        let box = AltSearchBox()
        let search = Task {
            var found: [String: String] = [:]
            for code in priority where code != fromCode {
                if Task.isCancelled { return }
                if let slug = await findSlug(code: code, name: name,
                                             origin: origin, year: year) {
                    found[code] = slug
                    box.update(found)
                }
            }
            if !Task.isCancelled { box.finish(found) }
        }
        let start = Date()
        while !box.isFinished && !Task.isCancelled
                && Date().timeIntervalSince(start) < 12 {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let completed = box.isFinished
        if !completed { search.cancel() }
        let found = box.snapshot()
        if completed { altCacheSet(key, found) }
        return orderedAlternatives(found: found, fromCode: fromCode)
    }

    /// One provider's slug for a film, via its search API: search
    /// by Vietnamese name first, then by origin name; accept the
    /// first candidate that sameFilm() approves.
    static func findSlug(code: String, name: String, origin: String, year: String) async -> String? {
        var slug = await searchSlug(code: code, query: name, name: name, origin: origin, year: year)
        if slug == nil && !origin.trimmingCharacters(in: .whitespaces).isEmpty
            && origin.trimmingCharacters(in: .whitespaces).lowercased()
                != name.trimmingCharacters(in: .whitespaces).lowercased() {
            slug = await searchSlug(code: code, query: origin, name: name, origin: origin, year: year)
        }
        return slug
    }

    private static func searchSlug(code: String, query: String, name: String,
                                   origin: String, year: String) async -> String? {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return nil }
        guard let results = try? await search(code, keyword: q) else { return nil }
        for m in results where sameFilm(m, name: name, origin: origin, year: year) {
            return m.slug
        }
        return nil
    }
}
