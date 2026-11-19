import Foundation
import SwiftUI

/// The Nuvio Live Sports addon (https://nuviosports.xyz) as a
/// source INSIDE the BLV Anh tab — owner order 2026-11-19: the
/// addon's channels and fixtures lead that tab, the mirror's
/// English block stays below them as the fallback pool.
/// A second owner order the same day (12:58) extends the addon
/// into the league tabs: a league tab also carries the addon's
/// channels for its own league, and its own live fixtures from
/// the addon lead there too — in 1.20 that is the Đức tab (the
/// Sky Bundesliga channel family + German live fixtures) and,
/// completing the same order, the Tây Ban Nha / Ý / Pháp tabs
/// (the La Liga / Calcio–Serie A / Ligue 1 channel families +
/// their live fixtures), each folded from its own probed
/// search family and name needles (see networkFamilies).
///
/// Contract (verified by live probes from this machine,
/// 2026-11-19, against the hunt report in
/// tv-build/sports-provider-hunt-20261117):
/// - Stremio shapes: {base}/manifest.json →
///   {base}/catalog/{type}/{id}/skip={n}.json →
///   {base}/stream/{type}/{id}.json. Paging is the PATH form —
///   the `?skip=` query form is ignored by this instance and
///   returns page 1 again (measured: identical bytes).
/// - Scope: the football catalog (`nuvio_sports_football`) for
///   fixtures and its own channels, PLUS a fold from the
///   Networks catalog. Review probes (2026-11-19) proved the
///   football catalog is NOT the addon's complete football
///   view: Sky Sports Main Event, TNT Sports 1–4, Premier
///   Sports 1/2, ESPN, Astro SuperSport 1–4 and Canal+ Sport /
///   Foot are carried by the addon (Networks + Live catalogs,
///   verified by meta id) but absent from the football catalog,
///   whose 148 channels are beIN-heavy. The Networks catalog
///   tags every entry "NETWORKS" — it has no football genre to
///   fold by — so the fold selects football-broadcaster
///   families through the addon's own search index: one search
///   request per family (searches do not page on this instance;
///   a combined search+skip path 404s, probed), deduped by meta
///   id against the football catalog. Queries whose tokens
///   degenerate into generic matches ("V Sport", "Sport TV",
///   "USA Network" — they return NBA TV and other non-football
///   channels) are deliberately NOT used; Setanta / Optus /
///   Peacock are not carried at all. The Live Now catalog's
///   football-live entries and the Upcoming catalog's
///   football-tagged fixtures are the SAME meta ids as the
///   football catalog's — both subsets verified fully contained
///   — so fixtures still come from the football catalog alone,
///   paged to exhaustion inside a 4-page cap.
/// - A meta classifies by its own fields, never by name parsing:
///   releaseInfo "24/7" → channel, "LIVE" → live event, anything
///   else with a `released` instant → upcoming event. (Live Now
///   interleaves 24/7 entries the same way; the rule routes them
///   to the channel section, never the fixture sections.)
/// - Meta `logo` is the addon's own logo on every entry; the
///   real artwork is `poster` (then `background`).
/// - Streams: entries without a playable `url` (the donation row,
///   externalUrl-only rows) are dropped when the ladder is built.
///   A stream's headers live at behaviorHints.proxyHeaders.request
///   and can carry Origin as well as Referer / User-Agent — the
///   full set is registered in NuvioStreamHeaders so BOTH the
///   pre-flight check and the player send all of it (the Channel
///   value itself only has slots for Referer / User-Agent).
///
/// Playback reuses the 1.18 machinery rather than duplicating it:
/// a tap vends a MatchPlaySession whose ladder is the meta's
/// streams mapped to Channels once the stream fetch lands — the
/// player opens on the session's waiting branch meanwhile, and
/// SourcePreflight verifies the ladder exactly as for a playlist
/// fixture. If the stream fetch returns nothing playable, the
/// session settles empty and the player shows its slate — never
/// a dead screen.

// MARK: - Addon meta (one catalog entry)

struct NuvioMeta: Sendable, Identifiable {
    let id: String
    let type: String
    let name: String
    let poster: String?
    let background: String?
    let releaseInfo: String?
    /// Kickoff instant (the catalog's `released` field); nil for
    /// 24/7 channels.
    let kickoff: Date?
    /// The addon's "🏆 League: …" line, when present.
    let leagueLine: String?
    let team1Name: String?
    let team2Name: String?

    enum Kind: Sendable {
        case live
        case upcoming
        case channel
    }

    var kind: Kind {
        if releaseInfo == "24/7" { return .channel }
        if releaseInfo == "LIVE" { return .live }
        if kickoff != nil { return .upcoming }
        return .channel
    }

    /// The name with the addon's status prefixes ("🔴 LIVE: ",
    /// "⏱️ ", "📺 ") removed — the tab's badges already say which
    /// state the entry is in.
    var displayName: String {
        var out = name
        for prefix in ["🔴 LIVE: ", "🔴 LIVE:", "⏱️ ", "⏱️", "📺 ", "📺"] where out.hasPrefix(prefix) {
            out = String(out.dropFirst(prefix.count))
            break
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Real artwork: poster first, background second. The meta's
    /// `logo` field is deliberately never used — it is the
    /// addon's own logo on every entry (contract note 6).
    var artworkURL: URL? {
        if let poster, !poster.isEmpty { return URL(string: poster) }
        if let background, !background.isEmpty { return URL(string: background) }
        return nil
    }

    /// One poster-URL query parameter (`lg=`, `ch=`): the addon
    /// stamps its competition and channel hints there, and the
    /// two always agree with the description's League line when
    /// both exist (spec §3.2 S2).
    private func posterParam(_ name: String) -> String? {
        guard let poster, let comps = URLComponents(string: poster),
              let value = comps.queryItems?.first(where: { $0.name == name })?.value,
              !value.isEmpty else { return nil }
        return value
    }

    /// The meta's competition string (S2 signal): the
    /// description's "🏆 League:" line first, the poster's `lg=`
    /// param as the twin source. Exact-match use only
    /// (LeagueClassifier.competition(forAddonString:)) — the
    /// generic "Football" value is no signal.
    var competitionString: String? {
        leagueLine ?? posterParam("lg")
    }

    /// The poster's `ch=` channel/quality hint (e.g. "HD |
    /// Bundesliga") — the link board's EN row label when the meta
    /// carries no competition string (spec §2.3b).
    var channelHint: String? { posterParam("ch") }
}

/// The three tab sections, classified and ordered.
struct NuvioCatalogSnapshot: Sendable {
    var live: [NuvioMeta]
    var upcoming: [NuvioMeta]
    var channels: [NuvioMeta]

    var isEmpty: Bool { live.isEmpty && upcoming.isEmpty && channels.isEmpty }
}

// MARK: - Wire DTOs (decoded defensively — one bad entry never kills a page)

private struct NuvioMetaDTO: Decodable {
    let id: String
    let type: String?
    let name: String?
    let poster: String?
    let background: String?
    let releaseInfo: String?
    let released: String?
    let description: String?
    let team1: NuvioTeamDTO?
    let team2: NuvioTeamDTO?
}

private struct NuvioTeamDTO: Decodable {
    let name: String?
    let logo: String?
}

private struct NuvioCatalogDTO: Decodable {
    let metas: [Failable<NuvioMetaDTO>]
}

private struct NuvioStreamsDTO: Decodable {
    let streams: [Failable<NuvioStreamDTO>]
}

private struct NuvioStreamDTO: Decodable {
    let name: String?
    let title: String?
    let url: String?
    let behaviorHints: NuvioHintsDTO?
}

private struct NuvioHintsDTO: Decodable {
    let proxyHeaders: NuvioProxyHeadersDTO?
}

/// proxyHeaders normally wraps its headers in a `request`
/// dictionary; tolerate a flat header dictionary too.
private struct NuvioProxyHeadersDTO: Decodable {
    let request: [String: String]?

    private enum CodingKeys: String, CodingKey { case request }

    init(from decoder: Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: CodingKeys.self),
           keyed.contains(.request) {
            request = try keyed.decodeIfPresent([String: String].self, forKey: .request)
        } else if let flat = try? decoder.singleValueContainer().decode([String: String].self) {
            request = flat
        } else {
            request = nil
        }
    }
}

/// A Decodable wrapper that turns one bad element into nil
/// instead of failing the whole array decode.
private struct Failable<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

/// One playable stream of a meta, headers included.
struct NuvioStream: Sendable {
    let name: String?
    let title: String?
    let url: String
    /// behaviorHints.proxyHeaders.request, keys as sent.
    let headers: [String: String]

    func header(_ field: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(field) == .orderedSame }?.value
    }

    /// The ladder label: the stream title's first line, else its
    /// name, else the meta's name.
    func ladderTitle(metaName: String) -> String {
        if let title {
            let first = title.components(separatedBy: "\n").first?
                .trimmingCharacters(in: .whitespaces) ?? ""
            if !first.isEmpty { return first }
        }
        if let name, !name.isEmpty { return name }
        return metaName
    }
}

// MARK: - Addon client (nonisolated; the store owns all state)

enum NuvioAddonClient {
    static let base = "https://nuviosports.xyz"
    static let footballCatalogID = "nuvio_sports_football"
    static let networksCatalogID = "nuvio_sports_networks"

    /// Football-broadcaster families folded in from the Networks
    /// catalog through its search index — the marquee football
    /// networks the football catalog omits (see the file header).
    /// Every query was probed live (2026-11-19) and returns a
    /// clean family set in a single unpaged response.
    /// "Sky Sport Bundesliga" is the Đức league tab's family
    /// (owner order 2026-11-19 12:58): probed live, it returns
    /// exactly the 11 Sky Sports Bundesliga channels — the
    /// generic "Sky Sports" query is not relied on to surface
    /// them; the snapshot's id dedupe absorbs any overlap.
    /// The same order's other three league families, probed
    /// live the same day: "La Liga" returns exactly the 15
    /// La Liga channels (DAZN / Movistar / beIN / SuperSport
    /// LaLiga, LaLiga TV + its bar and second-tier variants);
    /// "Sky Calcio" returns exactly the 5 Sky Italia football
    /// channels (Sky Sports Calcio + Sky Calcio 1–4 — the
    /// needle set in ContentView also picks up "Sky Sports
    /// Serie A", which the generic "Sky Sports" family already
    /// surfaces); "Ligue 1" returns exactly 19 (Canal+ Ligue 1,
    /// the Ligue 1+ set, Psg Ligue 1 — DAZN's Ligue 1 channels
    /// ride the generic "DAZN" family). The "Serie A" query is
    /// deliberately NOT a family: it degenerates into TV-series
    /// channels (probed), and no league channel needs it.
    private static let networkFamilies = [
        "Sky Sports", "TNT Sports", "beIN Sports", "SuperSport",
        "Premier Sports", "ESPN", "Astro SuperSport",
        "Canal+ Sport", "Canal+ Foot", "DAZN", "Nova Sport",
        "Arena Sport", "Digi Sport", "Orange Sport",
        "Prima Sport", "Eleven Sports", "Ziggo Sport",
        "RMC Sport", "Viaplay Sport", "CBS Sports", "FOX Sports",
        "Stan Sport", "Sky Sport Bundesliga",
        "La Liga", "Sky Calcio", "Ligue 1",
    ]

    /// Hard paging bound per catalog (contract note 4): 4 pages
    /// of 100. The football catalog exhausts inside it (275
    /// tonight); the cap exists so a runaway catalog can never
    /// page forever.
    private static let maxPages = 4
    private static let pageSize = 100

    private static func makeSession(resourceTimeout: TimeInterval = 30) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = resourceTimeout
        return URLSession(configuration: config)
    }

    /// One JSON fetch. When a deadline is given it is a hard
    /// bound, not a hint: an expired budget fails the fetch at
    /// once, and the request's own timeout is capped at the time
    /// remaining, so no single fetch can overrun the budget by
    /// more than its in-flight instant.
    private static func getJSON(_ url: URL, session: URLSession, deadline: Date? = nil) async -> Data? {
        var request = URLRequest(url: url)
        if let deadline {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return nil }
            request.timeoutInterval = min(20, remaining)
        }
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else { return nil }
            return data
        } catch {
            return nil
        }
    }

    /// One paged walk over the URLs `pageURL` builds for skip
    /// offsets 0, 100, 200, …: page 1 first, deeper pages in
    /// parallel, kept in skip order. `complete` reports whether
    /// the walk reached the source's true end (a short page) or
    /// the page cap without a failure; a page that fails — a
    /// network error, a bad decode, an expired deadline — stops
    /// the walk with `complete == false`, because a hole in the
    /// middle is not the end of anything. Callers decide what
    /// partial data is worth: the catalog accepts only complete
    /// walks, so a truncated fetch can never replace the last
    /// good snapshot with a shorter one.
    private static func fetchPaged(session: URLSession, deadline: Date,
                                   pageURL: @escaping @Sendable (Int) -> URL?)
        async -> (metas: [NuvioMeta], complete: Bool) {
        func page(_ skip: Int) async -> [NuvioMeta]? {
            guard let url = pageURL(skip),
                  let data = await getJSON(url, session: session, deadline: deadline),
                  let dto = try? JSONDecoder().decode(NuvioCatalogDTO.self, from: data)
            else { return nil }
            return dto.metas.compactMap { $0.value }.map(mapMeta)
        }

        guard let first = await page(0) else { return ([], false) }
        var all = first
        var complete = first.count < pageSize
        if !complete {
            // Deeper pages are independent: fetch them in
            // parallel, then keep them in skip order up to the
            // first short page (the source's true end) — or stop
            // incomplete at the first failed page.
            let rest = await withTaskGroup(of: (Int, [NuvioMeta]?).self) { group in
                for pageIndex in 1..<maxPages {
                    group.addTask { (pageIndex, await page(pageIndex * pageSize)) }
                }
                var byIndex: [Int: [NuvioMeta]] = [:]
                for await (pageIndex, metas) in group {
                    if let metas { byIndex[pageIndex] = metas }
                }
                return byIndex
            }
            for pageIndex in 1..<maxPages {
                guard let metas = rest[pageIndex] else { return (all, false) }
                all += metas
                if metas.count < pageSize { complete = true; break }
                if pageIndex == maxPages - 1 { complete = true } // cap reached, no failure
            }
        }
        // Pages can overlap when the source shifts mid-fetch:
        // dedupe by id, first occurrence wins.
        var seen = Set<String>()
        return (all.filter { seen.insert($0.id).inserted }, complete)
    }

    /// One catalog, paged with the PATH skip form (the query
    /// form does not page — contract note 1). nil = the walk was
    /// incomplete or failed outright (the store then keeps its
    /// last good snapshot); an empty array is a successful fetch
    /// of an empty catalog.
    private static func fetchCatalog(id: String, type: String = "tv",
                                     session: URLSession, deadline: Date) async -> [NuvioMeta]? {
        let walk = await fetchPaged(session: session, deadline: deadline) { skip in
            URL(string: skip == 0
                ? "\(base)/catalog/\(type)/\(id).json"
                : "\(base)/catalog/\(type)/\(id)/skip=\(skip).json")
        }
        return walk.complete ? walk.metas : nil
    }

    /// The Networks fold: one search request per football-
    /// broadcaster family, run in parallel under the snapshot's
    /// shared deadline. Best-effort by design — a family whose
    /// request fails or misses the budget contributes nothing
    /// this cycle, and the fold never gates the snapshot (the
    /// football catalog does).
    private static func fetchNetworkChannels(session: URLSession, deadline: Date) async -> [NuvioMeta] {
        await withTaskGroup(of: [NuvioMeta].self) { group in
            for family in networkFamilies {
                group.addTask {
                    // The probed form: query percent-encoded so
                    // "Canal+ Sport" reaches the index as %2B.
                    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
                    guard let query = family.addingPercentEncoding(withAllowedCharacters: allowed),
                          let url = URL(string: "\(base)/catalog/tv/\(networksCatalogID)/search=\(query).json"),
                          let data = await getJSON(url, session: session, deadline: deadline),
                          let dto = try? JSONDecoder().decode(NuvioCatalogDTO.self, from: data)
                    else { return [] }
                    return dto.metas.compactMap { $0.value }.map(mapMeta)
                }
            }
            var all: [NuvioMeta] = []
            for await metas in group { all += metas }
            return all
        }
    }

    /// The tab's snapshot: the football catalog classified into
    /// live / upcoming / channels, with the Networks fold merged
    /// in (deduped by meta id, the catalog's own entry winning a
    /// collision). One session and one 25 s deadline bound the
    /// WHOLE snapshot — catalog pages and family searches alike.
    /// nil when the football catalog's walk was incomplete: the
    /// store then keeps its last good snapshot.
    static func fetchSnapshot() async -> NuvioCatalogSnapshot? {
        let session = makeSession(resourceTimeout: 25)
        defer { session.invalidateAndCancel() }
        let deadline = Date().addingTimeInterval(25)
        async let catalog = fetchCatalog(id: footballCatalogID, session: session, deadline: deadline)
        async let folded = fetchNetworkChannels(session: session, deadline: deadline)
        guard let metas = await catalog else { return nil }
        var snapshot = NuvioCatalogSnapshot(live: [], upcoming: [], channels: [])
        var seen = Set<String>()
        for meta in metas + (await folded) where seen.insert(meta.id).inserted {
            switch meta.kind {
            case .live: snapshot.live.append(meta)
            case .upcoming: snapshot.upcoming.append(meta)
            case .channel: snapshot.channels.append(meta)
            }
        }
        snapshot.upcoming.sort {
            ($0.kickoff ?? .distantFuture) < ($1.kickoff ?? .distantFuture)
        }
        snapshot.channels.sort {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        return snapshot
    }

    /// A meta's streams, playable ones only, in the addon's own
    /// (scored) order, capped so pre-flight fan-out stays sane.
    /// An empty result is a successful fetch with nothing
    /// playable; nil is a failed fetch — the store treats both
    /// as an empty ladder (the player settles on its slate).
    static func fetchStreams(for meta: NuvioMeta) async -> [NuvioStream] {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        guard let url = URL(string: "\(base)/stream/\(meta.type)/\(meta.id).json"),
              let data = await getJSON(url, session: session),
              let dto = try? JSONDecoder().decode(NuvioStreamsDTO.self, from: data)
        else { return [] }
        var streams: [NuvioStream] = []
        var seenURLs = Set<String>()
        for failable in dto.streams {
            guard let stream = failable.value,
                  let raw = stream.url, !raw.isEmpty,
                  URL(string: raw) != nil,
                  seenURLs.insert(raw).inserted
            else { continue } // no playable url: donation / externalUrl-only row (contract note 2)
            streams.append(NuvioStream(
                name: stream.name,
                title: stream.title,
                url: raw,
                headers: stream.behaviorHints?.proxyHeaders?.request ?? [:]))
            if streams.count >= 12 { break }
        }
        return streams
    }

    private static func mapMeta(_ dto: NuvioMetaDTO) -> NuvioMeta {
        NuvioMeta(
            id: dto.id,
            type: dto.type ?? "tv",
            name: dto.name ?? dto.id,
            poster: dto.poster,
            background: dto.background,
            releaseInfo: dto.releaseInfo,
            kickoff: dto.released.flatMap(parseISO8601),
            leagueLine: leagueLine(from: dto.description),
            team1Name: dto.team1?.name,
            team2Name: dto.team2?.name)
    }

    /// "🏆 League: FIFA U17 World Cup" → "FIFA U17 World Cup".
    private static func leagueLine(from description: String?) -> String? {
        guard let description else { return nil }
        for line in description.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("🏆 League:") {
                let value = trimmed.dropFirst("🏆 League:".count)
                    .trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    private static func parseISO8601(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}

// MARK: - Declared-header registry (pre-flight + player)

/// The full header set each addon stream declared, keyed by
/// stream URL. The Channel value carries only Referer and
/// User-Agent, but the addon can also declare Origin (and
/// anything else) in behaviorHints.proxyHeaders — contract
/// note 3: ALL of it must reach both the pre-flight fetch and
/// the player's request. The store registers a stream's headers
/// when it maps the stream into the ladder; PlayerView's asset
/// builder and SourcePreflight merge them in from here. Only
/// addon stream URLs are ever registered, so playlist channels
/// see no change at all.
enum NuvioStreamHeaders {
    private final class Table: @unchecked Sendable {
        private let lock = NSLock()
        private var headersByURL: [String: [String: String]] = [:]
        private var order: [String] = []

        func register(url: String, headers: [String: String]) {
            lock.lock()
            defer { lock.unlock() }
            guard !headers.isEmpty else {
                // A rebuilt ladder whose stream no longer
                // declares headers must not keep sending the
                // set an earlier ladder registered for this
                // URL — registering an empty set clears it.
                if headersByURL[url] != nil {
                    headersByURL[url] = nil
                    order.removeAll { $0 == url }
                }
                return
            }
            if headersByURL[url] == nil { order.append(url) }
            headersByURL[url] = headers
            while order.count > 300 {
                headersByURL[order.removeFirst()] = nil
            }
        }

        func headers(for url: String) -> [String: String]? {
            lock.lock()
            defer { lock.unlock() }
            return headersByURL[url]
        }
    }

    private static let table = Table()

    static func register(url: String, headers: [String: String]) {
        table.register(url: url, headers: headers)
    }

    /// Case-insensitive set: removes any existing key that
    /// differs only by case, then writes the canonical one.
    private static func set(_ headers: inout [String: String], field: String, value: String) {
        for key in headers.keys where key.caseInsensitiveCompare(field) == .orderedSame {
            headers[key] = nil
        }
        headers[field] = value
    }

    private static func value(_ headers: [String: String], field: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(field) == .orderedSame }?.value
    }

    /// Headers for a pre-flight fetch: the registry set as the
    /// base, the channel's User-Agent over it (the app's TV
    /// default when the channel declares none — pre-flight has
    /// always sent one), and the caller's `referrer` (the
    /// declared one, or the repaired one on the repair retry)
    /// over everything. For a playlist channel the registry is
    /// empty and this reduces to exactly the old behaviour.
    static func requestHeaders(for channel: Channel, referrer: String) -> [String: String] {
        var headers = table.headers(for: channel.url) ?? [:]
        let userAgent = !channel.userAgent.isEmpty
            ? channel.userAgent
            : (value(headers, field: "User-Agent") ?? "Mozilla/5.0 (Linux; Android 14; TV)")
        set(&headers, field: "User-Agent", value: userAgent)
        if !referrer.isEmpty {
            set(&headers, field: "Referer", value: referrer)
        }
        return headers
    }

    /// Headers for the player's asset: the registry set as the
    /// base, the channel's own User-Agent / Referer over it (so
    /// a Referer repaired by pre-flight is the one the player
    /// sends). For a playlist channel this reduces to exactly
    /// the old behaviour — only the declared pair, only when
    /// non-empty.
    static func playerHeaders(for channel: Channel) -> [String: String] {
        var headers = table.headers(for: channel.url) ?? [:]
        if !channel.userAgent.isEmpty {
            set(&headers, field: "User-Agent", value: channel.userAgent)
        }
        if !channel.referrer.isEmpty {
            set(&headers, field: "Referer", value: channel.referrer)
        }
        return headers
    }
}

// MARK: - Store (tab state + playback sessions)

@MainActor
final class NuvioAddonStore: ObservableObject {
    @Published private(set) var liveEvents: [NuvioMeta] = []
    @Published private(set) var upcomingEvents: [NuvioMeta] = []
    @Published private(set) var channels: [NuvioMeta] = []
    @Published private(set) var isLoading = false

    var hasContent: Bool {
        !liveEvents.isEmpty || !upcomingEvents.isEmpty || !channels.isEmpty
    }

    /// Addon live fixtures the shared classifier files under
    /// `league` — the league-tab fold (owner order 2026-11-19):
    /// a league tab leads with its own league's live fixtures
    /// from every source, the addon included. Classification
    /// is the classifier's own rule run on the display name, so
    /// a cross-border cup fixture files under the first-checked
    /// league exactly as a mirror fixture does.
    func liveEvents(in league: League) -> [NuvioMeta] {
        liveEvents.filter {
            LeagueClassifier.leagueRank(of: $0.displayName) == league.rawValue
        }
    }

    /// Standing addon channels whose name carries `needle` —
    /// how a league tab picks its own league's channel family
    /// out of the snapshot (the Đức tab's needle is
    /// "Bundesliga": the Sky Sports Bundesliga channels).
    func standingChannels(matching needle: String) -> [NuvioMeta] {
        channels.filter {
            $0.displayName.localizedCaseInsensitiveContains(needle)
        }
    }

    /// The multi-needle form of `standingChannels(matching:)` —
    /// a league whose channel family is spelled more than one
    /// way picks its channels by ANY of its needles: Tây Ban
    /// Nha ("LaLiga" / "La Liga"), Ý ("Calcio" / "Serie A"),
    /// Pháp ("Ligue 1" / the source's own "Leauge 1"
    /// misspelling on DAZN's overflow channels). Order is the
    /// snapshot's own (name-sorted) order, as with the
    /// singular form.
    func standingChannels(matchingAny needles: [String]) -> [NuvioMeta] {
        channels.filter { channel in
            needles.contains {
                channel.displayName.localizedCaseInsensitiveContains($0)
            }
        }
    }

    /// The addon events that BELONG to a mirror fixture — the
    /// per-match English merge (spec §2.5 as measured by
    /// BOARD-REDESIGN-PLAN Addendum 2, which is authoritative for
    /// belonging; owner refinement 2026-11-19 13:53: per-match
    /// only, fail closed, BLV Anh keeps everything else).
    ///
    /// A meta folds only when ALL of these hold:
    /// - it is an event (releaseInfo LIVE or a kickoff time —
    ///   24/7 channels never match, §2.5);
    /// - it carries team1/team2 and a `released` instant
    ///   (NuvioMeta.kickoff) — no instant, no fold (A2.6 #2/#3);
    /// - its canonical pair key (MatchMatching — the A2.1 key)
    ///   equals the fixture's;
    /// - the instant's ICT calendar date equals the fixture's
    ///   stamp date AND the instant is within the 3 h guard of
    ///   the fixture's kickoff (A2.1: measured folds sit at
    ///   Δ0/+5 min; the guard stops a same-pair same-date
    ///   different match folding on date alone);
    /// - cluster rule: `competing` carries the OTHER fixture
    ///   entries sharing this pair + stamp date (spelling-split
    ///   clusters are already one entry via FixtureGrouping's
    ///   45-min chaining, so competing entries are distinct
    ///   matches) — the event folds here only when no competing
    ///   fixture is also inside the guard (exactly one candidate
    ///   inside the guard, A2.1);
    /// - marker asymmetry (A2.1): a women-marked event takes a
    ///   women-marked fixture; an unmarked event folds into a
    ///   marked fixture (or the reverse) only when it is the
    ///   unique candidate for the pair + date — when marked and
    ///   unmarked fixtures both claim the pair, an unmarked
    ///   event is ambiguous and stays in BLV Anh.
    ///
    /// Anything short of the full rule set = not a link for this
    /// match; the event remains in the BLV Anh tab untouched.
    func matchedEvents(for channel: Channel, competing: [Channel]) -> [NuvioMeta] {
        guard let fixtureKey = MatchMatching.pairKey(of: channel),
              let fixtureKickoff = channel.kickoff else { return [] }
        let fixtureDateKey = FixtureGrouping.stampDateKey(of: fixtureKickoff)
        let fixtureMarked = MatchMatching.fixtureIsWomenMarked(channel)
        let competingMarked = competing.contains {
            MatchMatching.fixtureIsWomenMarked($0)
        }
        let competingUnmarked = competing.contains {
            !MatchMatching.fixtureIsWomenMarked($0)
        }
        return (liveEvents + upcomingEvents).filter { meta in
            guard meta.kind != .channel,
                  let team1 = meta.team1Name, let team2 = meta.team2Name,
                  let metaKey = MatchMatching.pairKey(team1: team1, team2: team2),
                  metaKey == fixtureKey,
                  let metaKickoff = meta.kickoff,
                  FixtureGrouping.stampDateKey(of: metaKickoff) == fixtureDateKey
            else { return false }
            // Cluster rule: another fixture inside the guard too
            // means the event cannot be assigned — fail closed.
            let competingInsideGuard = competing.contains { other in
                other.kickoff.map {
                    abs(metaKickoff.timeIntervalSince($0)) <= 3 * 3600
                } ?? false
            }
            if competingInsideGuard { return false }
            guard abs(metaKickoff.timeIntervalSince(fixtureKickoff)) <= 3 * 3600
            else { return false }
            // Marker asymmetry.
            let eventMarked = MatchMatching.hasWomenMarker(rawName: team1)
                || MatchMatching.hasWomenMarker(rawName: team2)
            if eventMarked { return fixtureMarked }
            if fixtureMarked { return !competingUnmarked }
            return !competingMarked
        }
    }

    /// Last good snapshot + when it landed. A failed refresh
    /// keeps the last good on screen; with no last good the tab
    /// simply shows the mirror's English block alone — the tab
    /// never goes empty because the addon is down.
    private var fetchedAt: Date?
    private let ttl: TimeInterval = 300
    private var loadTask: Task<Void, Never>?

    /// Playback sessions by meta id (single-flight: a second tap
    /// on an entry whose streams are still resolving gets the
    /// same session), and the stream ladders behind them, cached
    /// on the ResolveHub doctrine: 60 s for a playable ladder,
    /// 30 s for an empty one, so a dead fixture is not
    /// re-scraped on every tap but a healthy one re-verifies
    /// from the device on the next open.
    private var sessions: [String: MatchPlaySession] = [:]
    private var ladders: [String: (ladder: [Channel], at: Date)] = [:]

    // MARK: Loading

    func loadIfNeeded() async {
        if let loadTask {
            await loadTask.value
            return
        }
        if let fetchedAt, Date().timeIntervalSince(fetchedAt) < ttl { return }
        await refresh()
    }

    func refresh() async {
        if let loadTask {
            await loadTask.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performLoad()
        }
        loadTask = task
        await task.value
    }

    private func performLoad() async {
        isLoading = true
        defer {
            isLoading = false
            loadTask = nil
        }
        guard let snapshot = await NuvioAddonClient.fetchSnapshot() else {
            return // keep the last good sections (or stay empty)
        }
        liveEvents = snapshot.live
        upcomingEvents = snapshot.upcoming
        channels = snapshot.channels
        fetchedAt = Date()
    }

    // MARK: Playback

    /// The session for a tap on an addon entry, captured by the
    /// view at tap time exactly like a playlist tap. The session
    /// starts resolving immediately; while the stream fetch is
    /// in flight the player sits on its waiting branch, and when
    /// the ladder lands the session verifies it through the
    /// usual pre-flight machinery. An entry whose streams come
    /// back empty settles the session empty — the player's
    /// slate, never a dead screen.
    func session(for meta: NuvioMeta) -> MatchPlaySession {
        if let existing = sessions[meta.id], existing.isResolving {
            return existing
        }
        let session = MatchPlaySession(key: "nuvio:" + meta.id)
        sessions[meta.id] = session
        if sessions.count > 50 {
            let stale = sessions.filter { !$0.value.isResolving && $0.key != meta.id }
                .map(\.key)
            for key in stale { sessions[key] = nil }
        }
        if let cached = ladders[meta.id],
           Date().timeIntervalSince(cached.at) < (cached.ladder.isEmpty ? 30 : 60) {
            session.begin(ladder: cached.ladder)
            return session
        }
        Task { [weak self, weak session] in
            let streams = await NuvioAddonClient.fetchStreams(for: meta)
            guard let self, let session else { return }
            let ladder = streams.map { stream -> Channel in
                // Register the stream's full declared header set
                // BEFORE the session begins: pre-flight and the
                // player both merge from the registry.
                NuvioStreamHeaders.register(url: stream.url, headers: stream.headers)
                return Channel(
                    title: stream.ladderTitle(metaName: meta.displayName),
                    logo: meta.poster ?? "",
                    group: "Nuvio",
                    url: stream.url,
                    kickoff: meta.kickoff,
                    leagueRank: 9,
                    referrer: stream.header("Referer") ?? "",
                    userAgent: stream.header("User-Agent") ?? "")
            }
            self.ladders[meta.id] = (ladder, Date())
            session.begin(ladder: ladder)
        }
        return session
    }
}

// MARK: - Tab rows (the BLV Anh tab's existing row idiom)

/// One addon row: artwork tile, name, state badge and the play
/// affordance, in the same card chrome as ENChannelRow. Live
/// events and 24/7 channels carry the red LIVE badge; upcoming
/// events carry their kickoff time instead — the row never
/// pretends an upcoming fixture is live.
struct NuvioEntryRow: View {
    let entry: NuvioMeta

    var body: some View {
        HStack(spacing: 12) {
            NuvioArtworkTile(entry: entry)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let league = entry.leagueLine {
                    Text(league)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            switch entry.kind {
            case .live, .channel:
                liveBadge
            case .upcoming:
                if let kickoff = entry.kickoff {
                    Text(Self.kickoffText(kickoff))
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.12), in: Capsule())
                }
            }
            Image(systemName: "play.circle.fill")
                .font(.system(size: 24))
                .foregroundStyle(accentGreen)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }

    private var liveBadge: some View {
        HStack(spacing: 5) {
            Circle().fill(Color.white).frame(width: 6, height: 6)
            Text("LIVE")
                .font(.caption2.bold())
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.red, in: Capsule())
    }

    /// "19:45 · 19/11" in the device's locale/timezone.
    private static func kickoffText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm · dd/MM"
        return formatter.string(from: date)
    }
}

/// The row's artwork tile: same chrome as LogoTile, fed from
/// the meta's poster (never its `logo` — contract note 6).
private struct NuvioArtworkTile: View {
    let entry: NuvioMeta

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.08))
            AsyncImage(url: entry.artworkURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFit()
                default:
                    Image(systemName: "soccerball")
                        .font(.system(size: 20))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .padding(4)
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
