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
    enum ListRequest: Hashable {
        case newest(page: Int)
        case byType(type: String, page: Int)
        case genre(slug: String, page: Int)
        case country(slug: String, page: Int, limit: Int?)
    }

    // MARK: - Raw list memo (Idea 17, session in-memory)

    /// Session in-memory memo of RAW list responses, keyed by
    /// (provider code, ListRequest), TTL 120 s, lock-guarded
    /// like the resolve memo below. It exists so the launch
    /// gate does not pay for the same fetch twice: phase 1's
    /// probe (SourceProbe, via fetchListRawFresh) lands its
    /// real network responses here, and phase 2's PhimStore
    /// "newest" jobs — which flow through fetchListRaw — read
    /// them back instead of re-fetching the same four
    /// endpoints. In-memory only: nothing is persisted, and
    /// any fetch landing more than the TTL after the memoised
    /// one (e.g. PhimStore's later staged refresh) misses and
    /// goes to the network for real.
    private struct RawMemoKey: Hashable {
        var code: String
        var req: ListRequest
    }

    private struct RawMemoEntry {
        var root: [String: Any]
        var at: Date
    }

    private static let rawMemoLock = NSLock()
    private static var rawMemo: [RawMemoKey: RawMemoEntry] = [:]
    private static let rawMemoTTL: TimeInterval = 120

    private static func rawMemoGet(_ code: String, _ req: ListRequest) -> [String: Any]? {
        rawMemoLock.lock()
        defer { rawMemoLock.unlock() }
        guard let hit = rawMemo[RawMemoKey(code: code, req: req)],
              Date().timeIntervalSince(hit.at) <= rawMemoTTL
        else { return nil }
        return hit.root
    }

    private static func rawMemoSet(_ code: String, _ req: ListRequest,
                                   _ root: [String: Any]) {
        rawMemoLock.lock()
        if rawMemo.count > 64 { rawMemo.removeAll() }
        rawMemo[RawMemoKey(code: code, req: req)] =
            RawMemoEntry(root: root, at: Date())
        rawMemoLock.unlock()
    }

    /// Memoised raw fetch: a fresh memo hit returns the
    /// stored root with NO network; a miss fetches for real
    /// (fetchListRawNetwork) and writes the result into the
    /// memo.
    static func fetchListRaw(_ code: String, _ req: ListRequest) async throws -> [String: Any] {
        if let hit = rawMemoGet(code, req) { return hit }
        let root = try await fetchListRawNetwork(code, req)
        rawMemoSet(code, req, root)
        return root
    }

    /// Fresh raw fetch for callers that must measure the REAL
    /// network (SourceProbe's diagnostics — the gate's phase 1
    /// and Settings' "Kiểm tra ngay"): bypasses the memo READ,
    /// still writes every fresh result into the memo, so a
    /// following memoised caller (the gate's phase 2) reuses
    /// it instead of fetching again.
    static func fetchListRawFresh(_ code: String, _ req: ListRequest) async throws -> [String: Any] {
        let root = try await fetchListRawNetwork(code, req)
        rawMemoSet(code, req, root)
        return root
    }

    /// The unmemoised network fetch behind fetchListRaw /
    /// fetchListRawFresh — the original dispatch, unchanged.
    private static func fetchListRawNetwork(_ code: String, _ req: ListRequest) async throws -> [String: Any] {
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

    /// newest through the FRESH raw path: always a real
    /// network fetch (see fetchListRawFresh), whose result
    /// still lands in the raw memo for memoised callers.
    /// SourceProbe uses this so its diagnostics keep
    /// measuring the real network while exercising literally
    /// the same Providers call the home's phase 2 reuses.
    static func newestFresh(_ code: String, page: Int) async throws -> [Movie] {
        let req = ListRequest.newest(page: page)
        return parseList(code, req, try await fetchListRawFresh(code, req))
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
    ///
    /// 1.9.2 (Team 9 item 2, leader-ruled): a ±1 year difference
    /// ALSO counts as a match — cross-provider year variants
    /// (a part/year mismatch between catalogues) used to kill
    /// the failover hop before it started. The tolerance is
    /// gated on the title matching EXACTLY (normalized equality
    /// in one of the four pairings above): no title match, no
    /// tolerance.
    static func sameFilm(_ c: Movie, name: String, origin: String, year: String) -> Bool {
        let nn = normalizeTitle(name), no = normalizeTitle(origin)
        let cn = normalizeTitle(c.name), co = normalizeTitle(c.originName)
        let titleExact =
            (!nn.isEmpty && (nn == cn || (!co.isEmpty && nn == co)))
            || (!no.isEmpty && (no == cn || (!co.isEmpty && no == co)))
        guard titleExact else { return false }
        let cy = yearOf(c), ty = yearOf(year)
        if cy.isEmpty || ty.isEmpty || cy == ty { return true }
        if let a = Int(cy), let b = Int(ty), abs(a - b) == 1 { return true }
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

    /// The ladder's target episode, matched exactly as
    /// ladderFor has always matched it: by exact name first,
    /// then by episode number, then the single-playable
    /// fallback. Shared by ladderFor and preResolve so the
    /// speculative dwell resolve can never drift from the
    /// real ladder's matching.
    private static func ladderTarget(code: String, detail d: Detail,
                                     epName: String?, epNum: Int) -> Episode? {
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
        // 1.9.2 (Team 9 item 2): single-episode fallback.
        // Cross-provider, name AND number can both miss while
        // the film is identical — KK's "Full" carries episode
        // number -1, VS's canonical single is "Tập 1" — and the
        // hop ladder came back empty for a carried film. When
        // the target detail holds exactly ONE playable episode
        // in total there is nothing to confuse it with: it IS
        // the episode.
        var target = byName ?? byNum
        if target == nil {
            let playable = d.servers.flatMap { $0.episodes }
                .filter { isPlayable(code: code, episode: $0) }
            if playable.count == 1 { target = playable[0] }
        }
        return target
    }

    /// One server's copy of the target episode, matched
    /// exactly as ladderFor has always matched it inside a
    /// server: by the target's name first, then by number.
    private static func pickEpisode(in server: Server, target: Episode,
                                    epNum: Int) -> Episode? {
        var pick: Episode?
        for e in server.episodes
        where e.name.trimmingCharacters(in: .whitespaces).lowercased()
            == target.name.trimmingCharacters(in: .whitespaces).lowercased() {
            pick = e
            break
        }
        if pick == nil && epNum > 0 {
            pick = server.episodes.first { episodeNumber($0.name) == epNum }
        }
        return pick
    }

    /// Resolve `servers` (already in pass order) into the
    /// ladder, one entry per server, through the memoised
    /// wrapper. Entry order is the servers' order.
    ///
    /// 2.0.25 (3a): all servers of a pass now resolve
    /// CONCURRENTLY in a task group (previously sequential —
    /// each server waited for the previous server's resolve).
    /// Picks are made up front in server order; results are
    /// collected as (serverIndex, entry) pairs and sorted by
    /// index before appending, so the assembled order remains
    /// EXACTLY the servers' order regardless of which resolve
    /// finishes first.
    private static func appendResolved(code: String, servers: [Server],
                                       target: Episode, epNum: Int,
                                       filmTitle: String, multiServer: Bool,
                                       lad: inout Ladder) async {
        var picks: [(index: Int, server: Server, pick: Episode)] = []
        for (idx, s) in servers.enumerated() {
            guard let pick = pickEpisode(in: s, target: target, epNum: epNum)
            else { continue }
            picks.append((index: idx, server: s, pick: pick))
        }
        guard !picks.isEmpty else { return }
        var collected: [(index: Int, entry: LadderEntry)] = []
        await withTaskGroup(of: (Int, LadderEntry?).self) { group in
            for item in picks {
                group.addTask {
                    guard let resolved = await playableURLMemoised(
                        code: code, episode: item.pick),
                        !resolved.url.isEmpty else { return (item.index, nil) }
                    return (item.index, LadderEntry(
                        url: resolved.url,
                        title: filmTitle + " · " + item.pick.name
                            + (multiServer ? " · " + item.server.name : ""),
                        proxy: resolved.proxy, headers: resolved.headers))
                }
            }
            for await (idx, entry) in group {
                if let entry { collected.append((index: idx, entry: entry)) }
            }
        }
        collected.sort { $0.index < $1.index }
        for pair in collected {
            lad.entries.append(pair.entry)
        }
    }

    /// Build the play ladder for one episode of one provider's
    /// detail: match the episode by exact name first, then by
    /// episode number; one URL per server. Playable = non-empty
    /// m3u8, EXCEPT VSMOV whose episodes carry only an embed URL —
    /// those are resolved to master.m3u8 HERE, fresh, every call.
    ///
    /// v2.0.8 (P3-gate): SourceHealth latches are a GATE here,
    /// not just a reorder. Servers whose resolution path is
    /// latched (serverDemoted) are resolved on a SECOND pass
    /// only: when the unlatched pass produced at least one
    /// entry the latched servers are not resolved at all in
    /// this ladder; when it produced nothing the latched pass
    /// runs — a latched server is deferred, never deleted, so
    /// the same sources remain playable. Entry order within
    /// each pass is orderServers' order.
    static func ladderFor(code: String, detail d: Detail, filmTitle: String,
                          epName: String?, epNum: Int) async -> Ladder {
        PerfLog.mark("ladder.begin")
        var lad = Ladder()
        guard let target = ladderTarget(code: code, detail: d,
                                        epName: epName, epNum: epNum)
        else { return lad }
        lad.matchedEpName = target.name
        let ordered = orderServers(code: code, servers: d.servers)
        let unlatched = ordered.filter { !serverDemoted(code: code, server: $0) }
        let latched = ordered.filter { serverDemoted(code: code, server: $0) }
        await appendResolved(code: code, servers: unlatched, target: target,
                             epNum: epNum, filmTitle: filmTitle,
                             multiServer: d.servers.count > 1, lad: &lad)
        if lad.entries.isEmpty && !latched.isEmpty {
            await appendResolved(code: code, servers: latched, target: target,
                                 epNum: epNum, filmTitle: filmTitle,
                                 multiServer: d.servers.count > 1, lad: &lad)
        }
        PerfLog.mark("ladder.done")
        return lad
    }

    /// Speculative dwell-time resolve (v2.0.8, P3b): find the
    /// ladder target exactly as ladderFor does, take the FIRST
    /// server in orderServers order that carries the target,
    /// and resolve that server's copy through the memoised
    /// wrapper, discarding the result — it lands in the memo,
    /// so a following Play tap starts from a warm ladder.
    /// Providers whose playableURL needs no network (KK/F4K
    /// direct m3u8) are NOT skipped: the wrapper returns
    /// instantly for them and the memo entry is harmless.
    static func preResolve(code: String, detail: Detail, epName: String?, epNum: Int) async {
        guard let target = ladderTarget(code: code, detail: detail,
                                        epName: epName, epNum: epNum)
        else { return }
        for s in orderServers(code: code, servers: detail.servers) {
            if let pick = pickEpisode(in: s, target: target, epNum: epNum) {
                _ = await playableURLMemoised(code: code, episode: pick)
                return
            }
        }
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

    // MARK: - Resolve memo (dwell pre-resolve, v2.0.8 P3b)

    /// In-memory memo of playableURL results, keyed by
    /// provider code + the episode's embed/m3u8 identity.
    /// Discipline mirrors the CacheVideo memo
    /// (CacheVideo.swift): SUCCESS ONLY, 10-minute TTL,
    /// wholesale clear past 64 entries, lock-guarded.
    ///
    /// ★ Addendum rule (owner, 2026-11-13 — see the header):
    /// stream URLs are resolved fresh at tap and never
    /// PERSISTED. This memo honours that rule: it is
    /// in-memory only (nothing is written to WatchStore,
    /// prefs or disk), holds successful resolutions only,
    /// and dies with the process or the TTL — it exists so
    /// the dwell-time preResolve and the Play tap that
    /// follows it do not pay for the same resolve twice.
    private struct ResolveMemoEntry {
        var url: String
        var proxy: Bool
        var headers: [String: String]
        var at: TimeInterval
    }

    private static let resolveMemoLock = NSLock()
    private static var resolveMemo: [String: ResolveMemoEntry] = [:]
    private static let resolveMemoTTL: TimeInterval = 600

    private static func resolveMemoKey(code: String, episode e: Episode) -> String? {
        if !e.embed.isEmpty { return code + "|e|" + e.embed }
        if !e.m3u8.isEmpty { return code + "|m|" + e.m3u8 }
        return nil
    }

    private static func resolveMemoGet(_ key: String)
        -> (url: String, proxy: Bool, headers: [String: String])? {
        resolveMemoLock.lock()
        defer { resolveMemoLock.unlock() }
        guard let hit = resolveMemo[key],
              Date().timeIntervalSince1970 - hit.at <= resolveMemoTTL
        else { return nil }
        return (hit.url, hit.proxy, hit.headers)
    }

    private static func resolveMemoSet(
        _ key: String,
        _ resolved: (url: String, proxy: Bool, headers: [String: String])
    ) {
        resolveMemoLock.lock()
        if resolveMemo.count > 64 { resolveMemo.removeAll() }
        resolveMemo[key] = ResolveMemoEntry(
            url: resolved.url, proxy: resolved.proxy,
            headers: resolved.headers, at: Date().timeIntervalSince1970)
        resolveMemoLock.unlock()
    }

    /// playableURL through the memo above: a fresh hit is
    /// returned without touching the network; a miss resolves
    /// for real (playableURL's exact behaviour) and only a
    /// successful, non-empty result is memoised.
    static func playableURLMemoised(code: String, episode e: Episode)
        async -> (url: String, proxy: Bool, headers: [String: String])? {
        guard let key = resolveMemoKey(code: code, episode: e) else {
            return await playableURL(code: code, episode: e)
        }
        if let hit = resolveMemoGet(key) { return hit }
        let resolved = await playableURL(code: code, episode: e)
        if let resolved, !resolved.url.isEmpty {
            resolveMemoSet(key, resolved)
        }
        return resolved
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
    /// OVERALL DEADLINE 12 s (LATENCY-AUDIT §6): each search
    /// can take up to 2 calls per provider at a 12 s list
    /// budget each — an unbounded worst case near 72 s if
    /// they ran sequentially, while the measured typical is
    /// 2.7–5.7 s total. The search therefore runs in a task
    /// the caller stops waiting on at 12 s; whatever it found
    /// by then is returned (the hop tries it), the task is
    /// cancelled, and a deadline-cut result is NOT written
    /// to the session cache — providers it never reached are
    /// "unsearched", not "not carried".
    ///
    /// v2.0.8 (P2a): the per-provider findSlug calls now run
    /// CONCURRENTLY in a task group (each provider keeps its
    /// own name→origin fallback sequence inside findSlug),
    /// and each provider's hit is published into the box the
    /// moment it lands, so the caller polling the box sees
    /// results stream in per provider instead of arriving in
    /// priority-walk order. The 12 s caller deadline, the
    /// poll loop, the cache discipline and the return value's
    /// orderedAlternatives ordering are unchanged.
    static func findAlternatives(fromCode: String, name: String,
                                 origin: String, year: String,
                                 tmdbId: String = "") async -> [(code: String, slug: String)] {
        let key = filmKey(name: name, year: year) + "@" + fromCode
        if let hit = altCacheGet(key) {
            return orderedAlternatives(found: hit, fromCode: fromCode)
        }
        let box = AltSearchBox()
        let search = Task {
            var found: [String: String] = [:]
            await withTaskGroup(of: (String, String?).self) { group in
                for code in priority where code != fromCode {
                    group.addTask {
                        // FIX4 (fix 8): the caller's TMDB id
                        // rides along; only the Film4K leg
                        // consumes it (see searchSlug) — that
                        // leg is the TVB chain's new last rung
                        // (Tủ Phim → KKPhim → VSMOV → Film4K,
                        // owner-approved 2026-11-18).
                        let slug = await Providers.findSlug(
                            code: code, name: name, origin: origin, year: year,
                            tmdbId: tmdbId)
                        return (code, slug)
                    }
                }
                for await (code, slug) in group {
                    if !Task.isCancelled, let slug {
                        found[code] = slug
                        box.update(found)
                    }
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
    static func findSlug(code: String, name: String, origin: String, year: String,
                         tmdbId: String = "") async -> String? {
        var slug = await searchSlug(code: code, query: name, name: name, origin: origin, year: year,
                                    tmdbId: tmdbId)
        if slug == nil && !origin.trimmingCharacters(in: .whitespaces).isEmpty
            && origin.trimmingCharacters(in: .whitespaces).lowercased()
                != name.trimmingCharacters(in: .whitespaces).lowercased() {
            slug = await searchSlug(code: code, query: origin, name: name, origin: origin, year: year,
                                    tmdbId: tmdbId)
        }
        return slug
    }

    private static func searchSlug(code: String, query: String, name: String,
                                   origin: String, year: String,
                                   tmdbId: String = "") async -> String? {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return nil }
        guard let results = try? await search(code, keyword: q) else { return nil }
        // FIX4 (fix 8): the Film4K leg accepts on TMDB id
        // when the caller knows it. TVB titles are listed on
        // Film4K under names that fail sameFilm's exact
        // title+year test (the hunt measured 15 of 60 sampled
        // TVB titles held by Film4K, all playable — most
        // unreachable by name alone), while the opened
        // detail knows the title's TMDB id. Scoped to
        // Film4K only: the other providers' proven
        // name-based acceptance is untouched. An id match
        // outranks a same-title remake, so it is checked
        // before sameFilm — on the rare result that carries
        // an id at all (see the verification below).
        if code == F4K, !tmdbId.isEmpty {
            for m in results where m.tmdbId == tmdbId {
                return m.slug
            }
        }
        for m in results where sameFilm(m, name: name, origin: origin, year: year) {
            return m.slug
        }
        // FIX4 (fix 8), the operative half: Film4K's SEARCH
        // payload (/api/search/suggest — light items) carries
        // NO tmdbId; the id lives only on the detail payload
        // (/api/title — measured in F4kClient), so the loop
        // above can almost never fire. When the name test
        // failed and the caller knows the TMDB id, verify
        // the search's top candidates BY DETAIL: the first
        // whose detail carries the caller's id is the film.
        // Bounded to 3 detail fetches per search pass,
        // inside findAlternatives' existing 12 s envelope,
        // and only on this leg.
        if code == F4K, !tmdbId.isEmpty {
            for m in results.prefix(3) {
                if let d = try? await detail(code, slug: m.slug),
                   d.movie.tmdbId == tmdbId {
                    return m.slug
                }
            }
        }
        return nil
    }

    // MARK: - Identity resolution (detail-time, session-cached)

    /// The resolved cross-service identity of one film: the
    /// IMDb id Torrentio streams are indexed by, plus the
    /// TMDB coordinates it was derived from (kept so the
    /// substitution rung's series addressing — type, season —
    /// survives the trip). A resolved NEGATIVE is a value
    /// too: imdbId empty in a CACHED identity means the
    /// ladder ran to completion and the title carries no
    /// reachable IMDb identity this session — consumers must
    /// not re-derive a weaker answer behind its back.
    struct FilmIdentity {
        var imdbId = ""
        var tmdbId = ""
        var tmdbType = ""
        var tmdbSeason = 0
        var resolved: Bool { !imdbId.isEmpty }
    }

    /// filmKey + "@" + provider code → FilmIdentity (the
    /// Android ID_CACHE key shape). Session-scoped: ids are
    /// catalogue identity, not stream URLs, so caching them
    /// does not violate the fresh-resolution rule.
    /// Lock-guarded like the alt cache above (C-15).
    private static let idCacheLock = NSLock()
    private static var idCache: [String: FilmIdentity] = [:]

    static func identityKey(name: String, year: String, fromCode: String) -> String {
        filmKey(name: name, year: year) + "@" + fromCode
    }

    static func identityCacheGet(_ key: String) -> FilmIdentity? {
        idCacheLock.lock()
        defer { idCacheLock.unlock() }
        return idCache[key]
    }

    private static func identityCacheSet(_ key: String, _ value: FilmIdentity) {
        idCacheLock.lock()
        idCache[key] = value
        idCacheLock.unlock()
    }

    /// The detail-time identity ladder (v2.0.5 — Android
    /// FIX5 placement + depth; until now tvOS had only the
    /// play-time derivation inside torrentFallbackCandidates,
    /// a reduced subset). Runs when a detail page loads,
    /// alongside findAlternatives, and lands in the detail's
    /// view state so the source row can carry the Torrent
    /// entry's state. Rungs, in order:
    ///   1. the opened record's own IMDb id;
    ///   2. its TMDB id → TMDB external_ids → IMDb id;
    ///   3. the details of ALL located alternatives (every
    ///      provider findAlternatives returned — for a film
    ///      opened from KK these are the OTHER providers,
    ///      exactly the rescue the old KK-only rung could
    ///      never reach: findAlternatives excludes the origin
    ///      provider by construction);
    ///   4. a strict TMDB title search (exact normalised
    ///      title + exact year; skipped when the year is
    ///      unknown — never a guess), then external_ids on
    ///      the hit.
    /// Caching mirrors the alt cache's discipline: a positive
    /// is always cached; a NEGATIVE is cached only when the
    /// alternative search behind rung 3 actually COMPLETED
    /// (its completed map sits in the alt cache under the
    /// same key shape) — a deadline-cut search leaves the
    /// film "unsearched", not "id-less", and the next open
    /// retries the ladder.
    static func resolveIdentity(movie m: Movie, fromCode: String,
                                alternatives: [(code: String, slug: String)]) async -> FilmIdentity {
        let key = identityKey(name: m.name, year: m.year, fromCode: fromCode)
        if let hit = identityCacheGet(key) { return hit }
        var id = FilmIdentity(imdbId: m.imdbId, tmdbId: m.tmdbId,
                              tmdbType: m.tmdbType, tmdbSeason: m.tmdbSeason)
        // Rung 2: the record's own TMDB id → external_ids.
        if id.imdbId.isEmpty, !id.tmdbId.isEmpty {
            id.imdbId = await TMDBClient.imdbId(
                tmdbId: id.tmdbId, type: id.tmdbType) ?? ""
        }
        // Rung 3: every alternative's detail, in failover
        // order — first IMDb id wins; the first TMDB id found
        // is converted through rung 2's bridge before moving
        // on, so a shallower carrier is preferred over a
        // deeper one.
        //
        // v2.0.8 (P2b): the alternatives' details are fetched
        // CONCURRENTLY (one bounded task group — the
        // alternative list is at most the other providers),
        // then evaluated IN THE ORIGINAL ORDER with the exact
        // win rules below, the TMDB bridge included. The
        // fetch order changed; the decision order did not.
        if id.imdbId.isEmpty {
            var fetched: [Detail?] = Array(repeating: nil, count: alternatives.count)
            await withTaskGroup(of: (Int, Detail?).self) { group in
                for (idx, alt) in alternatives.enumerated() {
                    group.addTask {
                        let d = try? await Providers.detail(alt.code, slug: alt.slug)
                        return (idx, d)
                    }
                }
                for await (idx, d) in group {
                    fetched[idx] = d
                }
            }
            for idx in alternatives.indices {
                guard let d = fetched[idx] else { continue }
                let am = d.movie
                if !am.imdbId.isEmpty {
                    id.imdbId = am.imdbId
                    if id.tmdbId.isEmpty { id.tmdbId = am.tmdbId }
                    if id.tmdbType.isEmpty { id.tmdbType = am.tmdbType }
                    if id.tmdbSeason <= 0 { id.tmdbSeason = am.tmdbSeason }
                    break
                }
                if id.tmdbId.isEmpty, !am.tmdbId.isEmpty {
                    id.tmdbId = am.tmdbId
                    if id.tmdbType.isEmpty { id.tmdbType = am.tmdbType }
                    if id.tmdbSeason <= 0 { id.tmdbSeason = am.tmdbSeason }
                    id.imdbId = await TMDBClient.imdbId(
                        tmdbId: id.tmdbId, type: id.tmdbType) ?? ""
                    if !id.imdbId.isEmpty { break }
                }
            }
        }
        // Rung 4: the strict TMDB title search. A verified
        // hit whose external_ids carry an IMDb id is adopted
        // wholesale (the Android step-3 arbitration); a hit
        // without one still donates its TMDB coordinates when
        // the record had none.
        if id.imdbId.isEmpty {
            if let hit = await TMDBClient.searchIdentity(
                name: m.name, originName: m.originName, year: yearOf(m)) {
                if let found = await TMDBClient.imdbId(
                    tmdbId: hit.tmdbId, type: hit.type), !found.isEmpty {
                    id.imdbId = found
                    id.tmdbId = hit.tmdbId
                    id.tmdbType = hit.type
                } else if id.tmdbId.isEmpty {
                    id.tmdbId = hit.tmdbId
                    id.tmdbType = hit.type
                }
            }
        }
        if id.resolved || altCacheGet(key) != nil {
            identityCacheSet(key, id)
        }
        return id
    }
}
