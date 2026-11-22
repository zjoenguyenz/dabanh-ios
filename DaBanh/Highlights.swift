import Combine
import Foundation

/// Match highlights index (FIX-134, Đá Banh iOS 1.34): the
/// Highlight tab's data pipe, mirroring the Crests / MUWallpapers
/// remote-JSON pattern — the app fetches `highlights.json` from
/// the owner's GitHub mirror at launch (disk cache in Caches,
/// NO bundled baseline: before the first successful fetch the
/// tab shows its empty state). The file is produced off-app by
/// the collector (Worker C); the app never searches YouTube and
/// never scrapes pages — it consumes direct video references
/// (YouTube IDs / ESPN MP4 URLs / UEFA page URLs) only.
///
/// Retention is the owner's 7-day rule (study §3.3), computed
/// IN-APP at render — see `HighlightStore.isInWindow(_:now:)`
/// for the exact predicate. No archive, no setting.

// MARK: - Model

/// One competition as the collector writes it. Decoding is
/// tolerant by construction: an unknown raw value lands in
/// `.unknown` and the match is simply never grouped, instead of
/// failing the whole file.
enum HighlightCompetition: String, Codable {
    case premierLeague = "premier-league"
    case laLiga = "la-liga"
    case championsLeague = "champions-league"
    case europaLeague = "europa-league"
    case conferenceLeague = "conference-league"
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = HighlightCompetition(rawValue: raw) ?? .unknown
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The tab's three switcher groups (study §3.2): the three UEFA
/// competitions fold into ONE "Cúp châu Âu" group.
enum HighlightGroup: CaseIterable {
    case premierLeague
    case laLiga
    case uefa

    var title: String {
        switch self {
        case .premierLeague: return "Ngoại hạng Anh"
        case .laLiga: return "La Liga"
        case .uefa: return "Cúp châu Âu"
        }
    }

    func contains(_ competition: HighlightCompetition) -> Bool {
        switch self {
        case .premierLeague: return competition == .premierLeague
        case .laLiga: return competition == .laLiga
        case .uefa:
            return competition == .championsLeague
                || competition == .europaLeague
                || competition == .conferenceLeague
        }
    }
}

/// One playable source of one match (progressive fill: sources
/// append over time; the row exists from the first one caught).
struct HighlightSource: Codable, Equatable {
    enum Kind: String {
        case youtube
        case espnMP4 = "espn-mp4"
        case uefaPage = "uefa-page"
        case unknown
    }

    /// The kind as written; an unknown kind decodes to
    /// `.unknown` and is dropped at the match level (see
    /// HighlightMatch.init) rather than failing the file.
    let kind: Kind
    /// YouTube video ID for `.youtube`; the full URL otherwise.
    let ref: String
    /// Channel / publisher name shown in the player source row.
    let label: String
    /// League / rights-holder / UEFA source — drives ranking
    /// and the card's "có bản chính thức" line.
    let official: Bool
    let durationSec: Int?
    let addedAt: Date

    /// Ranking class (study §3.2, fixed decision): official
    /// league/broadcaster YouTube → ESPN MP4 → sharing YouTube
    /// → UEFA page.
    var classRank: Int {
        switch kind {
        case .youtube: return official ? 0 : 2
        case .espnMP4: return 1
        case .uefaPage: return 3
        case .unknown: return 4
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind, ref, label, official, durationSec, addedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawKind = try c.decode(String.self, forKey: .kind)
        kind = Kind(rawValue: rawKind) ?? .unknown
        ref = try c.decode(String.self, forKey: .ref)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        official = try c.decodeIfPresent(Bool.self, forKey: .official) ?? false
        durationSec = try c.decodeIfPresent(Int.self, forKey: .durationSec)
        addedAt = try HighlightDates.decode(c, forKey: .addedAt) ?? Date.distantPast
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind.rawValue, forKey: .kind)
        try c.encode(ref, forKey: .ref)
        try c.encode(label, forKey: .label)
        try c.encode(official, forKey: .official)
        try c.encodeIfPresent(durationSec, forKey: .durationSec)
        try c.encode(HighlightDates.string(from: addedAt), forKey: .addedAt)
    }
}

/// One finished match with its highlight sources.
struct HighlightMatch: Codable, Identifiable {
    let competition: HighlightCompetition
    let home: String
    let away: String
    let scoreHome: Int
    let scoreAway: Int
    let matchDate: Date
    let espnEventId: String?
    /// Sources with a recognised kind only, in file order.
    let sources: [HighlightSource]

    var id: String {
        "\(competition.rawValue)|\(home)|\(away)|\(Int(matchDate.timeIntervalSince1970))"
    }

    /// The sources in PLAY order: (classRank, addedAt) — the
    /// study's ranking exactly. The first element is the source
    /// a card tap opens on, and the one whose duration the card
    /// badge shows.
    var rankedSources: [HighlightSource] {
        sources.sorted {
            if $0.classRank != $1.classRank { return $0.classRank < $1.classRank }
            return $0.addedAt < $1.addedAt
        }
    }

    var hasOfficialSource: Bool { sources.contains { $0.official } }

    private enum CodingKeys: String, CodingKey {
        case competition, home, away, scoreHome, scoreAway
        case matchDate, espnEventId, sources
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        competition = try c.decode(HighlightCompetition.self, forKey: .competition)
        home = try c.decode(String.self, forKey: .home)
        away = try c.decode(String.self, forKey: .away)
        scoreHome = try c.decode(Int.self, forKey: .scoreHome)
        scoreAway = try c.decode(Int.self, forKey: .scoreAway)
        // A match whose date cannot be read can never be placed
        // in the 7-day window — fail THIS match only (the file
        // decoder below is element-tolerant).
        guard let date = try HighlightDates.decode(c, forKey: .matchDate) else {
            throw DecodingError.dataCorruptedError(
                forKey: .matchDate, in: c,
                debugDescription: "unparseable matchDate")
        }
        matchDate = date
        espnEventId = try c.decodeIfPresent(String.self, forKey: .espnEventId)
        let decoded = try c.decodeIfPresent([HighlightSource].self, forKey: .sources) ?? []
        sources = decoded.filter { $0.kind != .unknown && !$0.ref.isEmpty }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(competition, forKey: .competition)
        try c.encode(home, forKey: .home)
        try c.encode(away, forKey: .away)
        try c.encode(scoreHome, forKey: .scoreHome)
        try c.encode(scoreAway, forKey: .scoreAway)
        try c.encode(HighlightDates.string(from: matchDate), forKey: .matchDate)
        try c.encodeIfPresent(espnEventId, forKey: .espnEventId)
        try c.encode(sources, forKey: .sources)
    }
}

/// ISO8601 date reading for the index: with or without
/// fractional seconds. A fresh formatter per call —
/// ISO8601DateFormatter is not concurrency-safe to share, and
/// index volume is low (the DiagLog precedent).
enum HighlightDates {
    static func parse(_ raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: raw) { return date }
        // FIX-135 (DB-22): DateFormatter fallbacks for shapes the
        // ISO8601 formatter refuses — above all a MISSING seconds
        // field (ESPN's raw kickoff format, "2026-11-22T20:00Z"),
        // which zeroed the whole tab in 1.34 when every match in
        // the file carried it. XXX accepts 'Z' and ±HH:mm alike.
        // Fresh formatters per call, same as above.
        for format in ["yyyy-MM-dd'T'HH:mm:ssXXX", "yyyy-MM-dd'T'HH:mmXXX"] {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = format
            if let date = f.date(from: raw) { return date }
        }
        return nil
    }

    static func string(from date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    static func decode<K: CodingKey>(_ container: KeyedDecodingContainer<K>,
                                     forKey key: K) throws -> Date? {
        guard let raw = try container.decodeIfPresent(String.self, forKey: key)
        else { return nil }
        return parse(raw)
    }
}

/// The index file's root. Element-tolerant: one malformed match
/// is dropped, never the whole file (a Failable wrapper, the
/// standard tolerant-array shape).
private struct HighlightIndexFile: Decodable {
    let version: Int?
    let generatedAt: String?
    let matches: [HighlightMatch]

    private struct FailableMatch: Decodable {
        let value: HighlightMatch?
        init(from decoder: Decoder) throws {
            value = try? HighlightMatch(from: decoder)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version, generatedAt, matches
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version)
        generatedAt = try c.decodeIfPresent(String.self, forKey: .generatedAt)
        let wrapped = try c.decodeIfPresent([FailableMatch].self, forKey: .matches) ?? []
        matches = wrapped.compactMap(\.value)
    }
}

// MARK: - Store

/// The Highlight tab's store: the board stores' shape
/// (@MainActor ObservableObject, @Published state) over the
/// Crests/Wallpapers pipe — launch fetch of the remote index,
/// disk cache in Caches for offline renders, no bundled copy.
@MainActor
final class HighlightStore: ObservableObject {

    /// selectedLeague value meaning "the Highlight tab" (league
    /// rawValues are positive, PlaylistStore uses 0 / −1, and
    /// LeagueClassifier.enTabValue is −2, so −3 is free). Defined
    /// HERE per the build brief — LeagueClassifier is untouched.
    static let tabValue = -3

    /// The live-updating copy, produced by the off-app collector.
    static let remoteURL = URL(string: "https://raw.githubusercontent.com/zjoenguyenz/dabanh-ios/main/highlights.json")!

    private static var cachedRemoteURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("highlights-remote.json")
    }

    @Published private(set) var matches: [HighlightMatch] = []
    @Published private(set) var isLoading = false
    /// True once any index (cache or remote) has loaded — the
    /// feed's skeleton shows only before this.
    @Published private(set) var hasLoaded = false

    init() {
        if let data = try? Data(contentsOf: Self.cachedRemoteURL),
           let decoded = Self.decode(data) {
            matches = decoded
            hasLoaded = true
        }
    }

    private static func decode(_ data: Data) -> [HighlightMatch]? {
        guard let file = try? JSONDecoder().decode(HighlightIndexFile.self, from: data)
        else { return nil }
        // A match with no playable source is not a highlight row.
        return file.matches.filter { !$0.sources.isEmpty }
    }

    /// Fetch the mirror's highlights.json; on success cache it
    /// for the next launch and swap it in for this one. A failed
    /// fetch or an unparseable file keeps whatever is on screen
    /// (the cached index still renders — study §3.2 offline).
    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let (data, _) = try await URLSession.shared.data(from: Self.remoteURL)
            guard let fresh = Self.decode(data) else {
                DiagLog.log("highlight", "parse fail: remote highlights.json undecodable (\(data.count) bytes) — keeping current index")
                return
            }
            try? data.write(to: Self.cachedRemoteURL, options: .atomic)
            matches = fresh
            hasLoaded = true
            let inWindow = fresh.filter { Self.isInWindow($0.matchDate) }.count
            DiagLog.log("highlight", "fetch ok: \(fresh.count) match(es) in index, \(inWindow) inside the 7-day window")
        } catch {
            DiagLog.log("highlight", "fetch fail: \(error.localizedDescription) — keeping current index (\(matches.count) match(es))")
        }
    }

    // MARK: 7-day window + grouping (render-time, in-app)

    /// THE 7-day predicate (study §3.3, rolling window from the
    /// MATCH date): a match is shown while
    /// `now − matchDate < 7 × 24 h`. A one-hour future tolerance
    /// absorbs clock/format skew on a just-finished match; a
    /// match dies by its match date, never by source age.
    static func isInWindow(_ matchDate: Date, now: Date = Date()) -> Bool {
        matchDate.timeIntervalSince(now) < 3600
            && now.timeIntervalSince(matchDate) < 7 * 24 * 3600
    }

    /// The matches of one switcher group inside the window,
    /// newest match first (the feed order).
    func matches(in group: HighlightGroup, now: Date = Date()) -> [HighlightMatch] {
        matches
            .filter { group.contains($0.competition) && Self.isInWindow($0.matchDate, now: now) }
            .sorted { $0.matchDate > $1.matchDate }
    }
}
