import Foundation

/// Provider registry for the aggregated Phim library — port of
/// the Android Providers (Joe TV v1.5.1, verified on device).
/// The providers the owner kept on 2026-11-14:
///   kk      KKPhim     — phimapi.com + mirror hosts in KkClient
///   f4k     Film4K.net — film4k.net, own API + TikTok CDN
///   vsmov   VSMOV      — vsmov.com, own API + own CDN
/// Priority for dedupe + cross-provider failover: KK > F4K > VS.
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
    static let priority = [KK, F4K, VS]

    static func displayName(_ code: String) -> String {
        switch code {
        case F4K: return "Film4K"
        case VS: return "VSMOV"
        default: return "KKPhim"
        }
    }

    static func badge(_ code: String) -> String {
        switch code {
        case F4K: return "F4K"
        case VS: return "VS"
        default: return "KK"
        }
    }

    /// WatchStore kind string for a provider.
    static func kindOf(_ code: String) -> String {
        switch code {
        case F4K: return WatchStore.kindF4K
        case VS: return WatchStore.kindVS
        default: return WatchStore.kindKK
        }
    }

    static func progressKey(_ code: String, slug: String, epName: String) -> String {
        switch code {
        case F4K: return WatchStore.f4kProgressKey(slug: slug, epName: epName)
        case VS: return WatchStore.vsProgressKey(slug: slug, epName: epName)
        default: return WatchStore.kkProgressKey(slug: slug, epName: epName)
        }
    }

    // MARK: - Catalogue dispatch

    static func newest(_ code: String, page: Int) async throws -> [Movie] {
        switch code {
        case F4K: return try await F4kClient.newest(page: page)
        case VS: return try await VsClient.newest(page: page)
        default: return try await KkClient.newest(page: page)
        }
    }

    static func listByType(_ code: String, type: String, page: Int) async throws -> [Movie] {
        switch code {
        case F4K: return try await F4kClient.listByType(type, page: page)
        case VS: return try await VsClient.listByType(type, page: page)
        default: return try await KkClient.listByType(type, page: page)
        }
    }

    static func search(_ code: String, keyword: String) async throws -> [Movie] {
        switch code {
        case F4K: return try await F4kClient.search(keyword)
        case VS: return try await VsClient.search(keyword)
        default: return try await KkClient.search(keyword)
        }
    }

    static func detail(_ code: String, slug: String) async throws -> Detail {
        switch code {
        case F4K: return try await F4kClient.detail(slug)
        case VS: return try await VsClient.detail(slug)
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

    // MARK: - Play ladder (fresh resolution)

    struct Ladder {
        var urls: [String] = []
        var titles: [String] = []
        var matchedEpName = ""
        var isEmpty: Bool { urls.isEmpty }
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
        for s in d.servers {
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
            guard let pick, let url = await playableURL(code: code, episode: pick),
                  !url.isEmpty else { continue }
            lad.urls.append(url)
            lad.titles.append(filmTitle + " · " + pick.name
                + (d.servers.count > 1 ? " · " + s.name : ""))
        }
        return lad
    }

    /// The playable URL of one episode RIGHT NOW, or nil. VSMOV
    /// resolves its embed page live; everyone else uses the m3u8
    /// the (freshly fetched) detail returned.
    static func playableURL(code: String, episode e: Episode) async -> String? {
        if code == VS {
            if !e.m3u8.isEmpty { return e.m3u8 }
            if e.embed.isEmpty { return nil }
            return try? await VsClient.resolveStream(embedURL: e.embed)
        }
        return e.m3u8.isEmpty ? nil : e.m3u8
    }

    /// True when the episode can be played at all (drives chip
    /// greying): m3u8 present, or VSMOV embed present. Embed-only
    /// on any other provider → false.
    static func isPlayable(code: String, episode e: Episode) -> Bool {
        if !e.m3u8.isEmpty { return true }
        return code == VS && !e.embed.isEmpty
    }

    // MARK: - Cross-provider lookup (session-cached)

    /// filmKey → (providerCode → slug). Only hits are stored;
    /// absence means "searched, not carried". Session-scoped —
    /// slugs are catalogue identity, not stream URLs, so caching
    /// them does not violate the fresh-resolution rule.
    private static var altCache: [String: [String: String]] = [:]

    /// Find which OTHER providers carry the same film. Returns a
    /// priority-ordered map providerCode → slug, possibly empty.
    static func findAlternatives(fromCode: String, name: String,
                                 origin: String, year: String) async -> [(code: String, slug: String)] {
        let key = filmKey(name: name, year: year) + "@" + fromCode
        if let hit = altCache[key] {
            return priority.filter { $0 != fromCode && hit[$0] != nil }
                .map { (code: $0, slug: hit[$0]!) }
        }
        var found: [String: String] = [:]
        for code in priority where code != fromCode {
            if let slug = await findSlug(code: code, name: name, origin: origin, year: year) {
                found[code] = slug
            }
        }
        altCache[key] = found
        return priority.filter { $0 != fromCode && found[$0] != nil }
            .map { (code: $0, slug: found[$0]!) }
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
