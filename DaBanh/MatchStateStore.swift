import Foundation

/// The live cluster for one fixture (Đá Banh 1.21, scoreboard
/// redesign — DABANH-SCOREBOARD-SPEC §1): score + true
/// minute/status + goal scorers + cards, from the layered sources
/// ESPN (primary) > FotMob > Flashscore > LiveScore > bounded
/// computed clock.
/// A state is always ONE source's whole truth: layers never merge
/// fields across sources (a score from one and scorers from
/// another can disagree by a minute), so precedence replaces
/// wholesale. This file holds the model, the shared matcher, the
/// bounded clock, the source clients and the store; the views read
/// states through PlaylistStore, never from here directly.

enum MatchStatus: Sendable, Equatable {
    case pre
    case live
    case halfTime
    case fullTime
    case postponed
    case cancelled

    var isLiveish: Bool { self == .live || self == .halfTime }
}

enum MatchSource: Sendable, Equatable {
    case espn
    case fotmob
    case flashscore
    case livescore
}

/// The three European cups (spec §4).
enum CupKind: Sendable, Equatable, Hashable {
    case champions
    case europa
    case conference

    var shortLabel: String {
        switch self {
        case .champions: return "CÚP C1"
        case .europa: return "CÚP C2"
        case .conference: return "CÚP C3"
        }
    }
    var fullLabel: String {
        switch self {
        case .champions: return "CÚP C1 · CHAMPIONS LEAGUE"
        case .europa: return "CÚP C2 · EUROPA LEAGUE"
        case .conference: return "CÚP C3 · CONFERENCE LEAGUE"
        }
    }
}

/// Competition identity — what files a fixture into a division or
/// cup section (spec §3/§4). It comes only from a positive signal,
/// ranked S1 (matched ESPN/FotMob competition) > S2 (addon
/// competition string, exact match) > S3 (both-clubs roster rule);
/// anything else stays in the top section, never guessed. The
/// mirror alone carries no competition text at all (0 hits in 438
/// titles), so `.league(rank, lower: false)` is the honest default
/// for an unidentified fixture of a known country.
enum CompetitionID: Sendable, Equatable {
    /// A domestic league of country `rank` (LeagueClassifier ranks
    /// 1–5); `lower` = that country's second division.
    case league(rank: Int, lower: Bool)
    case cup(CupKind, women: Bool)
    /// An identified competition outside the tab system
    /// (internationals, other leagues) — a label only; the fixture
    /// keeps its classifier home.
    case other(label: String)

    var isCup: Bool {
        if case .cup = self { return true }
        return false
    }

    var cupKind: CupKind? {
        if case .cup(let kind, _) = self { return kind }
        return nil
    }

    /// C1 carries the prototype's gold variant (§0 tokens).
    var isGoldCup: Bool { cupKind == .champions }

    /// The tile's competition line.
    var label: String {
        switch self {
        case .league(let rank, let lower):
            switch (rank, lower) {
            case (1, false): return "NGOẠI HẠNG ANH"
            case (1, true): return "CHAMPIONSHIP"
            case (2, false): return "LA LIGA"
            case (2, true): return "SEGUNDA"
            case (3, false): return "SERIE A"
            case (3, true): return "SERIE B"
            case (4, false): return "LIGUE 1"
            case (4, true): return "LIGUE 2"
            case (5, false): return "BUNDESLIGA"
            case (5, true): return "2. BUNDESLIGA"
            default: return "KHÁC"
            }
        case .cup(let kind, let women):
            return women && kind == .champions ? "CÚP C1 NỮ" : kind.fullLabel
        case .other(let label):
            return label.uppercased()
        }
    }

    /// The country tab's division sub-section head (spec §3.1).
    var divisionHeadline: String {
        switch self {
        case .league(let rank, let lower):
            if !lower { return label }
            switch rank {
            case 1: return "GIẢI HẠNG NHẤT (CHAMPIONSHIP)"
            case 2: return "SEGUNDA"
            case 3: return "SERIE B"
            case 4: return "LIGUE 2"
            case 5: return "2. BUNDESLIGA"
            default: return label
            }
        default:
            return label
        }
    }

    /// The top-division sub-section head inside a country tab.
    static func topHeadline(rank: Int) -> String {
        CompetitionID.league(rank: rank, lower: false).label
    }
}

struct GoalEvent: Sendable, Equatable {
    let minuteText: String
    let scorer: String
    let isHome: Bool
    let isPenalty: Bool
    let isOwnGoal: Bool
}

struct CardEvent: Sendable, Equatable {
    let minuteText: String
    let player: String
    let isHome: Bool
    let isRed: Bool
}

/// One fixture's matched state. `pairKey` is the alias-normalised
/// pair key (MatchMatching); `dateKey` the event's ICT calendar
/// date in FixtureGrouping.stampDateKey format ("y-m-d").
struct MatchState: Sendable, Equatable {
    let pairKey: String
    let dateKey: String
    let eventKickoff: Date?
    var status: MatchStatus
    var minuteText: String?
    var scoreHome: Int?
    var scoreAway: Int?
    var htHome: Int?
    var htAway: Int?
    var goals: [GoalEvent]
    var cards: [CardEvent]
    var competition: CompetitionID?
    let source: MatchSource
    var fotmobID: Int?
    var fetchedAt: Date
    /// Whether the source's team names carry a women's marker —
    /// the state lookup's marker discipline (Addendum 2 §A2.1)
    /// reasons about it; the belonging key itself strips markers.
    var womenMarked: Bool = false

    var homeYellow: Int { cards.filter { $0.isHome && !$0.isRed }.count }
    var homeRed: Int { cards.filter { $0.isHome && $0.isRed }.count }
    var awayYellow: Int { cards.filter { !$0.isHome && !$0.isRed }.count }
    var awayRed: Int { cards.filter { !$0.isHome && $0.isRed }.count }

    /// The board's badge text: the source's minute verbatim for
    /// live play; the prototype's Vietnamese wording for the
    /// half-time state; FT for a finished match.
    var badgeText: String? {
        switch status {
        case .halfTime: return "NGHỈ GIỮA HIỆP"
        case .live: return minuteText
        case .fullTime: return "FT"
        case .postponed, .cancelled: return "HOÃN"
        case .pre: return nil
        }
    }

    var scoreText: String? {
        guard let h = scoreHome, let a = scoreAway else { return nil }
        return "\(h) – \(a)"
    }
}

/// Pair-key + date matching shared by every layer: the livescore
/// state lookup AND the per-match English-link merge (spec §2.5:
/// one pair-key + date function across mirror fixtures, ESPN,
/// FotMob, livescore and Nuvio — no separate EN matcher; owner
/// refinement 2026-11-19 13:53: fail closed).
///
/// The canonical team key is BOARD-REDESIGN-PLAN Addendum 2 §A2.1,
/// the measured design (30 folds / 0 wrong on 2026-11-19's real
/// data): Crests.norm → filler drop (the FixtureGrouping set PLUS
/// the measured additions) → token aliases → women's-marker strip
/// (leading/trailing) → whole-name aliases. The alias tables below
/// are Addendum 2 §A2.2 verbatim — every entry exists because the
/// day's data produced the variant — plus the survey's VN
/// national-team whole-name aliases (LIVESCORE-CLOCK-SURVEY §3.2),
/// which the same function needs for VN-titled mirror listings.
///
/// Scope limits (A2.1): marker stripping applies ONLY to this
/// belonging key — FixtureGrouping's card identity is untouched,
/// and classification (LeagueClassifier) still sees the markers.
enum MatchMatching {

    /// Filler tokens: FixtureGrouping's set plus Addendum 2's
    /// measured additions — `de do da del` (particles), `dsc`,
    /// `sl`, `s` (possessive artifact), `futbol`/`football`
    /// (spelled-out FC). `clb` rides in FixtureGrouping's set
    /// (DB-04, 2026-11-19: the Vietnamese club prefix in "CLB
    /// Cincinnati", measured across the live playlist) and must
    /// drop here too or this layer's canonical key keeps the
    /// token FixtureGrouping already dropped.
    private static let fillerTokens: Set<String> = [
        "fc", "cf", "sc", "afc", "ca", "cd", "fk", "sk",
        "club", "clb", "ac", "as", "sd", "us", "ec",
        "de", "do", "da", "del", "dsc", "sl", "s", "futbol", "football",
    ]

    /// Women's markers stripped as leading/trailing tokens of the
    /// belonging key (A2.1 step 4).
    private static let womenMarkers: Set<String> = [
        "women", "w", "nu", "feminin", "femmes", "femenino", "femenina",
    ]

    /// Token aliases (A2.2, measured): applied per token after the
    /// filler drop.
    private static let tokenAliases: [String: String] = [
        "munchen": "munich",
        "wien": "vienna",
        "koln": "cologne",
        "mgladbach": "gladbach",
        "lyonnes": "lyon",
    ]

    /// Whole-name aliases (A2.2, measured; whole canonical name
    /// only, never substring) plus the survey's VN national-team
    /// aliases (§3.2 of the survey).
    private static let wholeNameAliases: [String: String] = [
        "atletico penarol": "penarol",
        "montevideo city torque": "montevideo city",
        "servette chenois": "servette",
        "servette geneve": "servette",
        "vitoria ba": "vitoria",
        "rb bragantino": "bragantino",
        "red bull bragantino": "bragantino",
        "bragantino sp": "bragantino",
        "vitoria salvador ba": "vitoria",
        "koge": "hb koge",
        "anh": "england",
        "phap": "france",
        "y": "italy",
        "duc": "germany",
        "tay ban nha": "spain",
        "ha lan": "netherlands",
        "bo dao nha": "portugal",
        "bi": "belgium",
        "dan mach": "denmark",
        "thuy si": "switzerland",
        "ao": "austria",
        "ba lan": "poland",
        "sec": "czechia",
        "tho nhi ky": "turkiye",
        "nga": "russia",
        "han quoc": "south korea",
        "nhat ban": "japan",
        "my": "usa",
        "uc": "australia",
    ]

    /// The canonical pipeline (A2.1 steps 2–5) over an already
    /// Crests.norm-normalised name.
    private static func canonicalise(normalized: String) -> String {
        var tokens = normalized
            .split(separator: " ")
            .map(String.init)
            .filter { !fillerTokens.contains($0) && !$0.allSatisfy({ $0.isNumber }) }
            .map { tokenAliases[$0] ?? $0 }
        while let first = tokens.first, womenMarkers.contains(first) {
            tokens.removeFirst()
        }
        while let last = tokens.last, womenMarkers.contains(last) {
            tokens.removeLast()
        }
        let joined = tokens.joined(separator: " ")
        if let alias = wholeNameAliases[joined] { return alias }
        // Brazilian state suffix (FixtureGrouping's measured
        // strip, 1.24): "sao paulo sp" must canonicalise to the
        // same key as ESPN's "sao paulo" or the decorated listing
        // can never bind this fixture's state — it then renders
        // the bounded computed clock beside the matched tile's
        // true minute, and one match shows two times.
        let stripped = FixtureGrouping.droppingStateSuffix(joined)
        return wholeNameAliases[stripped] ?? stripped
    }

    /// Canonical team key for a RAW team name (source feeds, Nuvio
    /// metas).
    static func canonicalTeam(rawName: String) -> String {
        canonicalise(normalized: Crests.norm(rawName))
    }

    /// Canonical team key for an already-normalised name
    /// (FixtureGrouping.normalizedTeam output — the mirror side).
    static func canonicalTeam(normalizedName: String) -> String {
        canonicalise(normalized: normalizedName)
    }

    /// The pair key for two raw team names (source feeds, Nuvio
    /// metas), or nil when either side canonicalises away.
    static func pairKey(team1: String, team2: String) -> String? {
        let a = canonicalTeam(rawName: team1)
        let b = canonicalTeam(rawName: team2)
        guard !a.isEmpty, !b.isEmpty else { return nil }
        return [a, b].sorted().joined(separator: " vs ")
    }

    /// The pair key for a playlist channel, or nil when its title
    /// has no recognisable pair.
    static func pairKey(of channel: Channel) -> String? {
        guard let raw = FixtureGrouping.pairKey(of: channel) else { return nil }
        return raw
            .components(separatedBy: " vs ")
            .map { canonicalTeam(normalizedName: $0) }
            .sorted()
            .joined(separator: " vs ")
    }

    /// The comparable minute of a source's minute text ("53'",
    /// "45'+2'", "90'+3'"): the sum of its number groups, so
    /// added time counts on top of the regulation minute — the
    /// convention ESPN's own displayClock follows. nil when the
    /// text carries no number at all (e.g. Flashscore states,
    /// whose minuteText is always nil). Used only by the
    /// staleness guard (1.24) to compare two SOURCE states'
    /// freshness; the bounded computed clock never participates.
    static func minuteValue(of text: String?) -> Int? {
        guard let text else { return nil }
        let numbers = text.split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
        guard !numbers.isEmpty else { return nil }
        return numbers.reduce(0, +)
    }

    /// True when a raw team name carries a women's marker token —
    /// the markedness the A2.1 marker-asymmetry rule and the state
    /// lookup's marker discipline reason about. (Classification
    /// has its own guard in LeagueClassifier; this one serves
    /// belonging only.)
    static func hasWomenMarker(rawName: String) -> Bool {
        Crests.norm(rawName)
            .split(separator: " ")
            .contains { womenMarkers.contains(String($0)) }
    }

    /// True when a fixture channel's pair is women-marked.
    static func fixtureIsWomenMarked(_ channel: Channel) -> Bool {
        guard let (a, b) = Crests.teams(ofCleanTitle: MatchTitle.clean(channel.title))
        else { return false }
        return hasWomenMarker(rawName: a) || hasWomenMarker(rawName: b)
    }

    /// Strict ICT calendar-date agreement (the Nuvio §2.5 rule:
    /// the meta's kickoff must name the same ICT date as the
    /// fixture's stamp).
    static func sameICTDate(_ a: Date, _ b: Date) -> Bool {
        FixtureGrouping.stampDateKey(of: a) == FixtureGrouping.stampDateKey(of: b)
    }

    /// Date agreement for feed states (spec §1.3): same ICT date,
    /// or ±1 day for the feeds' uncalibrated stamps, or — when both
    /// kickoff instants are known — instants within 3 hours across
    /// the day seam. Fail closed otherwise.
    static func datesAgree(fixtureKickoff: Date?, fixtureDateKey: String,
                           state: MatchState) -> Bool {
        if fixtureDateKey == state.dateKey { return true }
        if let fk = fixtureKickoff, let ek = state.eventKickoff,
           abs(fk.timeIntervalSince(ek)) <= 3 * 3600 { return true }
        if state.source == .livescore,
           let a = dayOrdinal(fixtureDateKey), let b = dayOrdinal(state.dateKey),
           abs(a - b) <= 1 { return true }
        return false
    }

    /// "y-m-d" → a day ordinal for ±1 comparisons.
    private static func dayOrdinal(_ key: String) -> Int? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return parts[0] * 372 + parts[1] * 31 + parts[2]
    }
}

/// The bounded computed clock (spec §1.4 / survey §3.4) — the
/// fallback for fixtures no source matched, and the whole display
/// when every layer is down. HT-aware, frozen at 90+', and it
/// never invents a score.
enum BoundedClock {
    static func text(kickoff: Date, now: Date = Date()) -> String {
        let elapsed = Int(now.timeIntervalSince(kickoff) / 60)
        if elapsed <= 45 { return "\(max(1, elapsed))'" }
        // 46–60 is first-half added time, NOT half-time: a source
        // must report HT for the badge to say HT (RC5, 2026-11-19).
        // Rendered in ESPN's convention ("45'+1'").
        if elapsed <= 60 { return "45'+\(elapsed - 45)'" }
        if elapsed > 100 { return "90+'" }
        return "\(elapsed - 15)'"
    }

    static func isHalfTimeEstimate(kickoff: Date, now: Date = Date()) -> Bool {
        let elapsed = Int(now.timeIntervalSince(kickoff) / 60)
        return elapsed > 45 && elapsed <= 60
    }
}

// MARK: - Wire DTOs (only the fields §1 names are decoded)

private struct ESPNDTO: Decodable { let events: [ESPNEventDTO]? }
private struct ESPNEventDTO: Decodable {
    let date: String?
    let competitions: [ESPNCompDTO]?
    let status: ESPNStatusDTO?
}
private struct ESPNCompDTO: Decodable {
    let competitors: [ESPNCompetitorDTO]?
    let details: [ESPNDetailDTO]?
}
private struct ESPNCompetitorDTO: Decodable {
    let homeAway: String?
    let score: String?
    let team: ESPNTeamDTO?
}
private struct ESPNTeamDTO: Decodable {
    let id: String?
    let displayName: String?
    /// The team's badge on ESPN's own CDN (DB-02: this field was
    /// on the wire all along and decoded nowhere, so a matched
    /// MLS fixture rendered empty shields — the static crest map
    /// carries no MLS).
    let logo: String?
}
private struct ESPNDetailDTO: Decodable {
    let type: ESPNTypeDTO?
    let clock: ESPNClockDTO?
    let team: ESPNTeamRefDTO?
    let scoringPlay: Bool?
    let yellowCard: Bool?
    let redCard: Bool?
    let athletesInvolved: [ESPNAthleteDTO]?
}
private struct ESPNTypeDTO: Decodable { let text: String? }
private struct ESPNClockDTO: Decodable { let displayValue: String? }
private struct ESPNTeamRefDTO: Decodable { let id: String? }
private struct ESPNAthleteDTO: Decodable { let displayName: String? }
private struct ESPNStatusDTO: Decodable {
    let displayClock: String?
    let type: ESPNStatusTypeDTO?
}
private struct ESPNStatusTypeDTO: Decodable {
    let name: String?
    let detail: String?
    let state: String?
    let completed: Bool?
}

private struct FotMobDayDTO: Decodable { let leagues: [FotMobLeagueDTO]? }
private struct FotMobLeagueDTO: Decodable {
    let name: String?
    let ccode: String?
    let matches: [FotMobMatchDTO]?
}
private struct FotMobMatchDTO: Decodable {
    let id: Int?
    let home: FotMobTeamDTO?
    let away: FotMobTeamDTO?
    let status: FotMobStatusDTO?
    let utcTime: String?
}
private struct FotMobTeamDTO: Decodable {
    let id: Int?
    let name: String?
}
private struct FotMobStatusDTO: Decodable {
    let started: Bool?
    let finished: Bool?
    let ongoing: Bool?
    let scoreStr: String?
    let liveTime: FotMobLiveTimeDTO?
    let halfs: FotMobHalfsDTO?
}
private struct FotMobLiveTimeDTO: Decodable { let short: String? }
private struct FotMobHalfsDTO: Decodable {
    let firstHalfStarted: String?
    let secondHalfStarted: String?
}
private struct FotMobDetailsDTO: Decodable { let content: FotMobContentDTO? }
private struct FotMobContentDTO: Decodable { let matchFacts: FotMobFactsDTO? }
private struct FotMobFactsDTO: Decodable { let events: FotMobEventsDTO? }
private struct FotMobEventsDTO: Decodable { let events: [FotMobEventDTO]? }
private struct FotMobEventDTO: Decodable {
    let type: String?
    let time: Int?
    let isHome: Bool?
    let card: String?
    let player: FotMobPlayerDTO?
    let goalDescription: String?
}
private struct FotMobPlayerDTO: Decodable { let name: String? }

private struct LSDTO: Decodable { let Stages: [LSStageDTO]? }
private struct LSStageDTO: Decodable { let Events: [LSEventDTO]? }
private struct LSEventDTO: Decodable {
    let Eps: String?
    let T1: [LSTeamDTO]?
    let T2: [LSTeamDTO]?
    let Tr1: String?
    let Tr2: String?
    let Trh1: String?
    let Trh2: String?
    let Esd: Int?
}
private struct LSTeamDTO: Decodable { let Nm: String? }

// MARK: - Source clients (nonisolated; the store owns all state)

enum MatchStateClient {

    /// The ESPN slug table (spec §1.2/§3/§4): the spec slugs,
    /// plus the women's Champions League and UEFA World Cup
    /// qualifying, whose fixtures ride the Hot/Trực tiếp lists.
    /// Adding a competition = one row here.
    static let espnSlugs: [(slug: String, competition: CompetitionID)] = [
        ("eng.1", .league(rank: 1, lower: false)),
        ("eng.2", .league(rank: 1, lower: true)),
        ("esp.1", .league(rank: 2, lower: false)),
        ("esp.2", .league(rank: 2, lower: true)),
        ("ita.1", .league(rank: 3, lower: false)),
        ("ita.2", .league(rank: 3, lower: true)),
        ("fra.1", .league(rank: 4, lower: false)),
        ("fra.2", .league(rank: 4, lower: true)),
        ("ger.1", .league(rank: 5, lower: false)),
        ("ger.2", .league(rank: 5, lower: true)),
        ("uefa.champions", .cup(.champions, women: false)),
        ("uefa.europa", .cup(.europa, women: false)),
        ("uefa.europa.conf", .cup(.conference, women: false)),
        ("uefa.womens.champions", .cup(.champions, women: true)),
        ("fifa.worldq.uefa", .other(label: "Vòng loại World Cup")),
        // Brazil Série A (2026-11-19): CompetitionID has no Brazil
        // case — its league ranks are the five European countries
        // only — and Brazilian fixtures are NOT playlist-bound to a
        // country tab (they keep their classifier home, rank 9 /
        // "Khác"). The settled design had Brazil riding FotMob
        // only; ESPN's bra.1 scoreboard carries full incidents, so
        // it joins as a state layer under the same `.other` label
        // the FotMob map stamps for ("Série A", "BRA") — a label
        // only, never a tab filing.
        ("bra.1", .other(label: "Serie A Brazil")),
    ]

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }

    private static func get(_ url: URL, session: URLSession,
                            extraHeaders: [String: String] = [:]) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        for (field, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else { return nil }
            return data
        } catch {
            return nil
        }
    }

    // MARK: ICT date helpers

    private static var ictCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh") ?? .current
        return cal
    }

    /// "yyyyMMdd" in ICT for the ESPN/FotMob date parameters.
    static func ictDateParam(_ date: Date) -> String {
        let c = ictCalendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// "yyyyMMdd" in UTC — the calendar FotMob files its day feed
    /// under (RC1, 2026-11-19).
    static func utcDateParam(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// "yyyyMMdd" in the DEVICE's own timezone (owner ruling
    /// 2026-11-19 17:26 CST: every app runs on Oklahoma time; only
    /// iOS varies, following the device's timezone/GPS location).
    /// `TimeZone.current` is the device zone — never a hardcoded
    /// ICT clock for "today" on this platform.
    static func localDateParam(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Inverse of the date parameters above: 00:00 UTC on the
    /// calendar day a "yyyyMMdd" parameter names. `stampDateKey`
    /// reads that instant back in ICT (07:00 the same day), so it
    /// stamps to the parameter's own calendar day. Used ONLY as
    /// the FotMob fallback date basis — never the fetch instant.
    static func dateParamDayStartUTC(_ param: String) -> Date? {
        guard param.count == 8,
              let year = Int(param.prefix(4)),
              let month = Int(param.dropFirst(4).prefix(2)),
              let day = Int(param.suffix(2)) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return cal.date(from: DateComponents(year: year, month: month, day: day))
    }

    // MARK: ESPN

    /// One scoreboard sweep. `full` fetches every slug; a live
    /// cycle fetches only `activeSlugs` (the slugs the last
    /// snapshot carried). Dates span the ICT seam ±1 day (spec
    /// §1.2/§1.3): yesterday's board still carries a late kickoff
    /// live past midnight, tomorrow's carries the early fixtures
    /// the mirror already lists — date agreement decides which
    /// states bind.
    static func fetchESPN(full: Bool, activeSlugs: Set<String>) async -> [MatchState] {
        let table = full ? espnSlugs : espnSlugs.filter { activeSlugs.contains($0.slug) }
        if table.isEmpty { return [] }
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let now = Date()
        let dates = [ictDateParam(now.addingTimeInterval(-24 * 3600)),
                     ictDateParam(now),
                     ictDateParam(now.addingTimeInterval(24 * 3600))]
        return await withTaskGroup(of: [MatchState].self) { group in
            for entry in table {
                for dateParam in dates {
                    group.addTask {
                        await fetchESPNBoard(slug: entry.slug, competition: entry.competition,
                                             dateParam: dateParam, session: session)
                    }
                }
            }
            var all: [MatchState] = []
            for await states in group { all += states }
            return all
        }
    }

    private static func fetchESPNBoard(slug: String, competition: CompetitionID,
                                       dateParam: String, session: URLSession) async -> [MatchState] {
        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/soccer/\(slug)/scoreboard?dates=\(dateParam)"),
              let data = await get(url, session: session),
              let dto = try? JSONDecoder().decode(ESPNDTO.self, from: data),
              let events = dto.events else { return [] }
        var out: [MatchState] = []
        for event in events {
            guard let comp = event.competitions?.first,
                  let competitors = comp.competitors, competitors.count == 2,
                  let home = competitors.first(where: { $0.homeAway == "home" }),
                  let away = competitors.first(where: { $0.homeAway == "away" }),
                  let homeName = home.team?.displayName,
                  let awayName = away.team?.displayName,
                  let key = MatchMatching.pairKey(team1: homeName, team2: awayName)
            else { continue }
            let kickoff = event.date.flatMap { parseISO8601($0) }
            let dateKey = kickoff.map { FixtureGrouping.stampDateKey(of: $0) } ?? ""
            let type = event.status?.type
            let name = (type?.name ?? "").uppercased()
            let status: MatchStatus
            var minute: String? = nil
            if type?.state == "pre" {
                status = .pre
            } else if name.contains("POSTPONED") {
                status = .postponed
            } else if name.contains("CANCEL") {
                status = .cancelled
            } else if type?.state == "post" || type?.completed == true {
                status = .fullTime
            } else if type?.detail == "HT" || name.contains("HALFTIME") {
                status = .halfTime
            } else {
                status = .live
                if let clock = event.status?.displayClock, clock != "HT", clock != "FT" {
                    minute = clock
                }
            }
            var goals: [GoalEvent] = []
            var cards: [CardEvent] = []
            for detail in comp.details ?? [] {
                guard let athlete = detail.athletesInvolved?.first?.displayName,
                      let minuteText = detail.clock?.displayValue else { continue }
                let isHome = detail.team?.id != nil && detail.team?.id == home.team?.id
                if detail.scoringPlay == true {
                    let text = detail.type?.text ?? ""
                    goals.append(GoalEvent(minuteText: minuteText, scorer: athlete,
                                           isHome: isHome,
                                           isPenalty: text.contains("Penalty"),
                                           isOwnGoal: text.contains("Own Goal")))
                } else if detail.yellowCard == true || detail.redCard == true {
                    cards.append(CardEvent(minuteText: minuteText, player: athlete,
                                           isHome: isHome, isRed: detail.redCard == true))
                }
            }
            // The feed's own badges go into Crests' learned
            // registry (DB-02), so the card — which looks crests
            // up by the playlist's spelling of the same team —
            // finds them even when the static map never carried
            // the team. (They no longer ride the state itself:
            // the state-carried logo fields were write-only
            // payload — N-2, REVIEW-125-LOOP1.)
            let homeLogo = home.team?.logo.flatMap { URL(string: $0) }
            let awayLogo = away.team?.logo.flatMap { URL(string: $0) }
            if let homeLogo { Crests.registerLearnedLogo(forTeam: homeName, logoURL: homeLogo) }
            if let awayLogo { Crests.registerLearnedLogo(forTeam: awayName, logoURL: awayLogo) }
            out.append(MatchState(
                pairKey: key, dateKey: dateKey, eventKickoff: kickoff,
                status: status, minuteText: minute,
                scoreHome: home.score.flatMap { Int($0) },
                scoreAway: away.score.flatMap { Int($0) },
                htHome: nil, htAway: nil,
                goals: goals, cards: cards,
                competition: competition, source: .espn,
                fotmobID: nil, fetchedAt: Date(),
                womenMarked: MatchMatching.hasWomenMarker(rawName: homeName)
                    || MatchMatching.hasWomenMarker(rawName: awayName)))
        }
        return out
    }

    private static func parseISO8601(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    // MARK: FotMob

    /// The FotMob competition map (spec §3.3, measured names —
    /// ccode is mandatory in the key; a pair outside the map stamps
    /// nothing). The women's Champions League is the one name whose
    /// ccode varies, so it is matched on name alone.
    static func fotmobCompetition(name: String, ccode: String) -> CompetitionID? {
        if name == "Women's Champions League" { return .cup(.champions, women: true) }
        switch (name, ccode) {
        case ("Premier League", "ENG"): return .league(rank: 1, lower: false)
        case ("LaLiga", "ESP"): return .league(rank: 2, lower: false)
        case ("LaLiga2", "ESP"): return .league(rank: 2, lower: true)
        case ("Serie A", "ITA"): return .league(rank: 3, lower: false)
        case ("Bundesliga", "GER"): return .league(rank: 5, lower: false)
        case ("2. Bundesliga", "GER"): return .league(rank: 5, lower: true)
        case ("Ligue 1", "FRA"): return .league(rank: 4, lower: false)
        case ("Ligue 2", "FRA"): return .league(rank: 4, lower: true)
        case ("Série A", "BRA"): return .other(label: "Serie A Brazil")
        case ("Champions League", "INT"): return .cup(.champions, women: false)
        case ("Europa League", "INT"): return .cup(.europa, women: false)
        case ("Conference League", "INT"): return .cup(.conference, women: false)
        default: return nil
        }
    }

    /// The day feeds covering today: score + true minute for
    /// everything ESPN does not carry; no incidents (those come
    /// from matchDetails, on demand only).
    ///
    /// RC1 (2026-11-19, master fault): FotMob files matches under
    /// the UTC date, but the old code fetched only the ICT date —
    /// ICT is a day ahead during US-evening hours, so the whole
    /// layer was silently empty exactly when the owner watches.
    /// The fetch now covers BOTH the UTC filing date AND the
    /// device-local date (owner timezone ruling 2026-11-19 17:26:
    /// iOS follows the device's own timezone), deduped when they
    /// coincide, and merges the feeds deduped by match id (pair
    /// key as fallback). Each state's `dateKey` is derived from
    /// the match's own `utcTime` through `stampDateKey` — the
    /// playlist's ICT stamp convention, which binding keys
    /// legitimately keep — never from "today" in any timezone.
    static func fetchFotMob() async -> [MatchState] {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let now = Date()
        var dateParams: [String] = []
        for param in [utcDateParam(now), localDateParam(now)]
        where !dateParams.contains(param) {
            dateParams.append(param)
        }
        var out: [MatchState] = []
        var seenIDs: Set<Int> = []
        var seenPairs: Set<String> = []
        for dateParam in dateParams {
            let states = await fetchFotMobDay(dateParam: dateParam, session: session)
            for state in states {
                // Dedupe on BOTH keys for every candidate: the same
                // match may carry an id in one feed and none in the
                // other, so checking only the key matching the
                // record's shape let it through twice.
                let pairStamp = state.pairKey + "|" + state.dateKey
                if seenPairs.contains(pairStamp) { continue }
                if let id = state.fotmobID, seenIDs.contains(id) { continue }
                if let id = state.fotmobID { seenIDs.insert(id) }
                seenPairs.insert(pairStamp)
                out.append(state)
            }
        }
        return out
    }

    /// One FotMob day feed (one date parameter).
    private static func fetchFotMobDay(dateParam: String, session: URLSession) async -> [MatchState] {
        guard let url = URL(string: "https://www.fotmob.com/api/data/matches?date=\(dateParam)"),
              let data = await get(url, session: session),
              let dto = try? JSONDecoder().decode(FotMobDayDTO.self, from: data),
              let leagues = dto.leagues else { return [] }
        // Fallback date basis for a match whose own kickoff is
        // missing: the calendar day of THIS feed, from its
        // dateParam — never the fetch instant. Nil only when the
        // parameter itself is unparseable, in which case such a
        // match is skipped below (fail closed).
        let feedDateKey = dateParamDayStartUTC(dateParam)
            .map { FixtureGrouping.stampDateKey(of: $0) }
        var out: [MatchState] = []
        for league in leagues {
            let competition = fotmobCompetition(name: league.name ?? "", ccode: league.ccode ?? "")
            for match in league.matches ?? [] {
                guard let homeName = match.home?.name, let awayName = match.away?.name,
                      let key = MatchMatching.pairKey(team1: homeName, team2: awayName),
                      let statusDTO = match.status else { continue }
                let status: MatchStatus
                var minute: String? = nil
                if statusDTO.finished == true {
                    status = .fullTime
                } else if statusDTO.ongoing == true {
                    if let short = statusDTO.liveTime?.short, !short.isEmpty {
                        if short.uppercased() == "HT"
                            || short.lowercased().contains("half") {
                            status = .halfTime
                        } else {
                            status = .live
                            minute = short
                        }
                    } else if statusDTO.halfs?.secondHalfStarted == nil,
                              let firstHalf = statusDTO.halfs?.firstHalfStarted,
                              let firstStart = parseISO8601(firstHalf),
                              Date().timeIntervalSince(firstStart) > 50 * 60 {
                        // No liveTime and the second half has not
                        // begun 50+ minutes after the first began:
                        // the interval. (The same shape inside the
                        // first 50 minutes is just the first half —
                        // it must not wear the HT badge.)
                        status = .halfTime
                    } else {
                        status = .live
                    }
                } else {
                    status = .pre
                }
                var scoreHome: Int? = nil
                var scoreAway: Int? = nil
                if let scoreStr = statusDTO.scoreStr {
                    let parts = scoreStr.split(separator: "-")
                    if parts.count == 2 {
                        scoreHome = Int(parts[0].trimmingCharacters(in: .whitespaces))
                        scoreAway = Int(parts[1].trimmingCharacters(in: .whitespaces))
                    }
                }
                // Binding keys stay on the playlist's ICT stamp
                // convention, derived from the match's OWN kickoff
                // instant (utcTime) — so a state binds by its real
                // date whichever feed file carried it. A match
                // without a kickoff falls back to the carrying
                // feed's own day (`feedDateKey`); with neither it
                // is skipped — the fetch instant is never a basis.
                let kickoff = match.utcTime.flatMap { parseISO8601($0) }
                guard let dateKey = kickoff.map({ FixtureGrouping.stampDateKey(of: $0) })
                        ?? feedDateKey else { continue }
                // FotMob's day feed carries no logo field — only
                // the team id — but FotMob serves every badge from
                // its own teamlogo resource under that id (DB-02;
                // the resource was verified live against this
                // feed's ids, Orlando City and FC Cincinnati among
                // them, before this derivation was trusted). The
                // logos register into Crests exactly like ESPN's.
                let homeLogo = match.home?.id.map {
                    URL(string: "https://images.fotmob.com/image_resources/logo/teamlogo/\($0).png")
                } ?? nil
                let awayLogo = match.away?.id.map {
                    URL(string: "https://images.fotmob.com/image_resources/logo/teamlogo/\($0).png")
                } ?? nil
                if let homeLogo { Crests.registerLearnedLogo(forTeam: homeName, logoURL: homeLogo) }
                if let awayLogo { Crests.registerLearnedLogo(forTeam: awayName, logoURL: awayLogo) }
                out.append(MatchState(
                    pairKey: key, dateKey: dateKey, eventKickoff: kickoff,
                    status: status, minuteText: minute,
                    scoreHome: scoreHome, scoreAway: scoreAway,
                    htHome: nil, htAway: nil,
                    goals: [], cards: [],
                    competition: competition, source: .fotmob,
                    fotmobID: match.id, fetchedAt: Date(),
                    womenMarked: MatchMatching.hasWomenMarker(rawName: homeName)
                        || MatchMatching.hasWomenMarker(rawName: awayName)))
            }
        }
        return out
    }

    /// matchDetails for ONE fixture (≈335 KB — never bulk): the
    /// goals/cards of a FotMob-covered fixture ESPN missed.
    static func fetchFotMobDetails(matchID: Int) async -> (goals: [GoalEvent], cards: [CardEvent])? {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        guard let url = URL(string: "https://www.fotmob.com/api/data/matchDetails?matchId=\(matchID)"),
              let data = await get(url, session: session),
              let dto = try? JSONDecoder().decode(FotMobDetailsDTO.self, from: data),
              let events = dto.content?.matchFacts?.events?.events else { return nil }
        var goals: [GoalEvent] = []
        var cards: [CardEvent] = []
        for event in events {
            guard let time = event.time else { continue }
            let minuteText = "\(time)'"
            let isHome = event.isHome ?? true
            if event.type == "Goal" {
                let description = event.goalDescription ?? ""
                goals.append(GoalEvent(
                    minuteText: minuteText,
                    scorer: event.player?.name ?? "",
                    isHome: isHome,
                    isPenalty: description.localizedCaseInsensitiveContains("penalty"),
                    isOwnGoal: description.localizedCaseInsensitiveContains("own goal")))
            } else if event.type == "Card" {
                cards.append(CardEvent(
                    minuteText: minuteText,
                    player: event.player?.name ?? "",
                    isHome: isHome,
                    isRed: event.card == "Red"))
            }
        }
        return (goals, cards)
    }

    // MARK: Flashscore (third layer — score + status ONLY)

    /// The Flashscore competition map for the league headers
    /// VERIFIED in the 2026-11-19 probe feed (fs_feed1.txt) —
    /// exact header strings only; any other header stamps nil and
    /// the fixture keeps its classifier home, never a guess.
    static func flashscoreCompetition(leagueHeader: String) -> CompetitionID? {
        if leagueHeader.hasPrefix("EUROPE: UEFA Champions League Women") {
            return .cup(.champions, women: true)
        }
        switch leagueHeader {
        case "BRAZIL: Serie A": return .other(label: "Serie A Brazil")
        case "SPAIN: LaLiga": return .league(rank: 2, lower: false)
        case "SPAIN: LaLiga2": return .league(rank: 2, lower: true)
        case "ITALY: Serie B": return .league(rank: 3, lower: true)
        case "FRANCE: Ligue 1": return .league(rank: 4, lower: false)
        case "FRANCE: Ligue 2": return .league(rank: 4, lower: true)
        case "GERMANY: Bundesliga": return .league(rank: 5, lower: false)
        case "GERMANY: 2. Bundesliga": return .league(rank: 5, lower: true)
        default: return nil
        }
    }

    /// The whole-world soccer day feed their own clients consume
    /// (probe-verified 2026-11-19: HTTP 200 on every pull, static
    /// `x-fsign` header, no account/cookies). Score + status ONLY:
    /// the feed carries NO minute field and NO incidents, so
    /// `minuteText` stays nil and goals/cards stay empty — the
    /// bounded clock and the ESPN/FotMob layers own those.
    ///
    /// The basketball feed (f_3) is deliberately NOT fetched: this
    /// app binds football fixtures only — no basketball fixture,
    /// pair-keyed state or tab exists anywhere in DaBanh (the one
    /// "NBA" hit is a Nuvio channel-family comment) — so NBB
    /// states could never bind and would only pollute the store.
    static func fetchFlashscore() async -> [MatchState] {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        guard let url = URL(string: "https://www.flashscore.com/x/feed/f_1_0_3_en_1"),
              let data = await get(url, session: session,
                                   extraHeaders: ["x-fsign": "SW9D1eZo"]),
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty, text != "0" else { return [] }
        return parseFlashscoreFeed(text)
    }

    /// Defensive parser for the `~` / `¬` / `KEY÷value` wire
    /// format: records split on "~", fields on "¬", each field is
    /// "KEY÷value". One malformed record is skipped, never fatal.
    ///
    /// Field semantics VERIFIED against the probe feeds
    /// (fs_feed1.txt / fsnap2/fs.txt, cross-checked with ESPN +
    /// FotMob at the same instant): AA = match id, AD = kickoff
    /// epoch seconds (UTC), AE/AF = home/away team, AG/AH =
    /// home/away score, AB = stage class (1 = scheduled — no
    /// AG/AH, 2 = in play — AI "y" present, AG/AH live, 3 =
    /// terminal). Terminal records split on AC: AC "3" is the
    /// only verified finished shape (scores present in every
    /// sample); AC "4"/"5" terminal records carry NO scores and
    /// unverified semantics, so they fail closed (skipped). NO
    /// half-time shape exists in any probe feed — every live
    /// football record was first-half (AC "12") — so this layer
    /// never reports HT; AB "2" maps to plain `.live`.
    static func parseFlashscoreFeed(_ text: String) -> [MatchState] {
        var out: [MatchState] = []
        var leagueHeader = ""
        for record in text.components(separatedBy: "~") {
            var fields: [String: String] = [:]
            for field in record.components(separatedBy: "¬") {
                let parts = field.split(separator: "÷", maxSplits: 1,
                                         omittingEmptySubsequences: false)
                guard parts.count == 2 else { continue }
                fields[String(parts[0])] = String(parts[1])
            }
            if let header = fields["ZA"] {
                leagueHeader = header
                continue
            }
            guard fields["AA"] != nil,
                  let homeName = fields["AE"], !homeName.isEmpty,
                  let awayName = fields["AF"], !awayName.isEmpty,
                  let key = MatchMatching.pairKey(team1: homeName, team2: awayName),
                  let adRaw = fields["AD"], let ad = TimeInterval(adRaw)
            else { continue }
            let status: MatchStatus
            switch (fields["AB"] ?? "", fields["AC"] ?? "") {
            case ("1", _): status = .pre
            case ("2", _): status = .live
            case ("3", "3"): status = .fullTime
            default: continue // unverified shape — fail closed
            }
            let kickoff = Date(timeIntervalSince1970: ad)
            out.append(MatchState(
                pairKey: key,
                dateKey: FixtureGrouping.stampDateKey(of: kickoff),
                eventKickoff: kickoff,
                status: status, minuteText: nil,
                scoreHome: fields["AG"].flatMap { Int($0) },
                scoreAway: fields["AH"].flatMap { Int($0) },
                htHome: nil, htAway: nil,
                goals: [], cards: [],
                competition: flashscoreCompetition(leagueHeader: leagueHeader),
                source: .flashscore,
                fotmobID: nil, fetchedAt: Date(),
                womenMarked: MatchMatching.hasWomenMarker(rawName: homeName)
                    || MatchMatching.hasWomenMarker(rawName: awayName)))
        }
        return out
    }

    // MARK: LiveScore (fourth layer — score + minute only)

    static func fetchLiveScoreLive() async -> [MatchState] {
        await fetchLiveScore(urlString: "https://prod-public-api.livescore.com/v1/api/app/live/soccer/3?MD=1")
    }

    static func fetchLiveScoreDate() async -> [MatchState] {
        let dateParam = ictDateParam(Date())
        return await fetchLiveScore(urlString: "https://prod-public-api.livescore.com/v1/api/app/date/soccer/\(dateParam)/0?MD=1")
    }

    /// The date feed gated by its hourly cadence (its own cache
    /// header says max-age=3600): an async-let-friendly wrapper
    /// that returns empty without a request when not due.
    static func fetchLiveScoreDate(ifNeeded: Bool) async -> [MatchState] {
        guard ifNeeded else { return [] }
        return await fetchLiveScoreDate()
    }

    private static func fetchLiveScore(urlString: String) async -> [MatchState] {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        guard let url = URL(string: urlString),
              let data = await get(url, session: session),
              let dto = try? JSONDecoder().decode(LSDTO.self, from: data),
              let stages = dto.Stages else { return [] }
        var out: [MatchState] = []
        for stage in stages {
            for event in stage.Events ?? [] {
                guard let homeName = event.T1?.first?.Nm, let awayName = event.T2?.first?.Nm,
                      let key = MatchMatching.pairKey(team1: homeName, team2: awayName)
                else { continue }
                let eps = event.Eps ?? ""
                let status: MatchStatus
                var minute: String? = nil
                switch eps {
                case "NS": status = .pre
                case "HT": status = .halfTime
                case "FT", "AP": status = .fullTime
                case "Canc.": status = .cancelled
                default:
                    if eps.contains("'") {
                        status = .live
                        minute = eps
                    } else {
                        status = .pre
                    }
                }
                var dateKey = ""
                if let esd = event.Esd {
                    let s = String(esd)
                    if s.count >= 8 {
                        let y = Int(s.prefix(4)) ?? 0
                        let m = Int(s.dropFirst(4).prefix(2)) ?? 0
                        let d = Int(s.dropFirst(6).prefix(2)) ?? 0
                        dateKey = "\(y)-\(m)-\(d)"
                    }
                }
                out.append(MatchState(
                    pairKey: key, dateKey: dateKey, eventKickoff: nil,
                    status: status, minuteText: minute,
                    scoreHome: event.Tr1.flatMap { Int($0) },
                    scoreAway: event.Tr2.flatMap { Int($0) },
                    htHome: event.Trh1.flatMap { Int($0) },
                    htAway: event.Trh2.flatMap { Int($0) },
                    goals: [], cards: [],
                    competition: nil, source: .livescore,
                    fotmobID: nil, fetchedAt: Date(),
                    womenMarked: MatchMatching.hasWomenMarker(rawName: homeName)
                        || MatchMatching.hasWomenMarker(rawName: awayName)))
            }
        }
        return out
    }
}

// MARK: - Store

/// Owns the matched states and the poll loop (spec §1.6): a 60 s
/// live cycle while anything is live, a 5-minute idle cycle, and a
/// full 13+-slug sweep every 15 minutes piggybacked on the same
/// loop. Failure behaviour (§1.7 of the plan): a failed cycle keeps
/// the last-good states for 30 minutes, then the overrides drop —
/// never worse than the bounded computed clock.
@MainActor
final class MatchStateStore: ObservableObject {

    /// Bumped on every published snapshot; PlaylistStore forwards
    /// the change so the views re-render.
    @Published private(set) var revision = 0

    private(set) var states: [MatchState] = []
    /// Set by PlaylistStore after each publish: true while any
    /// fixture sits in its live window or is matched-live.
    var liveHint = false

    private var lastSuccessAt: Date?
    private var lastFullAt: Date?
    private var lastLiveScoreDateAt: Date?
    private var knownSlugs: Set<String> = []
    /// The last staleness-guard firing logged per fixture pair
    /// key, so a firing is written to the diagnostic log once,
    /// not on every render that re-runs the selection.
    private var lastGuardLog: [String: String] = [:]
    private var loopTask: Task<Void, Never>?
    private var refreshing = false
    private var detailCache: [Int: (goals: [GoalEvent], cards: [CardEvent])] = [:]

    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            guard let self else { return }
            await self.refresh(full: true)
            while !Task.isCancelled {
                let interval: TimeInterval = self.liveHint ? 60 : 300
                try? await Task.sleep(for: .seconds(interval))
                if Task.isCancelled { break }
                let needFull = self.lastFullAt.map {
                    Date().timeIntervalSince($0) > 15 * 60
                } ?? true
                await self.refresh(full: needFull)
            }
        }
    }

    /// A playlist refresh also refreshes the states (plan §1.7).
    func refreshNow() async {
        await refresh(full: true)
    }

    private func refresh(full: Bool) async {
        if refreshing { return }
        refreshing = true
        defer { refreshing = false }
        let now = Date()
        let wantDateFeed = lastLiveScoreDateAt.map {
            now.timeIntervalSince($0) > 3600
        } ?? true
        async let espnFetch = MatchStateClient.fetchESPN(full: full, activeSlugs: knownSlugs)
        async let fotmobFetch = MatchStateClient.fetchFotMob()
        async let flashFetch = MatchStateClient.fetchFlashscore()
        async let liveFetch = MatchStateClient.fetchLiveScoreLive()
        async let dateFetch = MatchStateClient.fetchLiveScoreDate(ifNeeded: wantDateFeed)
        let espnStates = await espnFetch
        let fotmobStates = await fotmobFetch
        let flashStates = await flashFetch
        let liveStates = await liveFetch
        let dateStates = await dateFetch

        // Precedence by wholesale replacement per fixture key:
        // ESPN > FotMob > Flashscore > LiveScore — livescore
        // first, then Flashscore, then FotMob, then ESPN on top.
        var merged: [String: MatchState] = [:]
        for state in dateStates + liveStates + flashStates + fotmobStates + espnStates {
            merged[state.pairKey + "|" + state.dateKey] = state
        }
        // FotMob states inherit any cached matchDetails incidents
        // (same source family — the one allowed upgrade).
        var upgraded = Array(merged.values)
        for i in upgraded.indices {
            if upgraded[i].source == .fotmob, let id = upgraded[i].fotmobID,
               let cached = detailCache[id] {
                upgraded[i].goals = cached.goals
                upgraded[i].cards = cached.cards
            }
        }
        if upgraded.isEmpty {
            if let last = lastSuccessAt, now.timeIntervalSince(last) < 30 * 60 {
                DiagLog.log("cluster",
                            "cycle full=\(full): no states returned — keeping last-good snapshot")
                return // keep the last-good snapshot
            }
            if !states.isEmpty {
                states = []
                revision += 1
            }
            return
        }
        states = upgraded
        lastSuccessAt = now
        if full { lastFullAt = now }
        if wantDateFeed { lastLiveScoreDateAt = now }
        knownSlugs = Set(espnStates.map { state in
            MatchStateClient.espnSlugs.first { $0.competition == state.competition }?.slug ?? ""
        }.filter { !$0.isEmpty })
        revision += 1
        DiagLog.log("cluster",
                    "cycle full=\(full): espn=\(espnStates.count) "
                    + "fotmob=\(fotmobStates.count) flash=\(flashStates.count) "
                    + "livescore=\(liveStates.count + dateStates.count) "
                    + "merged=\(upgraded.count) "
                    + "live=\(upgraded.filter { $0.status.isLiveish }.count)")
        // RC2 (2026-11-19): the FotMob incidents upgrade also runs
        // on this refresh cycle — the 60 s live cycle included —
        // not only at playlist publish, so scorers/cards land
        // within a cycle of the state that needs them.
        await upgradeLiveFotMobDetails()
    }

    /// The refresh-cycle form of the FotMob incidents upgrade
    /// (RC2): same discipline as `upgradeDetails(for:)` — FotMob
    /// states only (the details endpoint is FotMob-only), capped
    /// at 4 per pass, live first, cached ids never refetched —
    /// driven from the store's own states because the cycle has
    /// no channel list. Only states lacking incidents qualify.
    private func upgradeLiveFotMobDetails() async {
        let ordered = states.sorted {
            ($0.status.isLiveish ? 0 : 1) < ($1.status.isLiveish ? 0 : 1)
        }
        var targets: [Int] = []
        for state in ordered {
            guard targets.count < 4,
                  state.source == .fotmob,
                  let id = state.fotmobID,
                  state.goals.isEmpty, state.cards.isEmpty,
                  detailCache[id] == nil else { continue }
            targets.append(id)
        }
        if targets.isEmpty { return }
        for id in targets {
            if let details = await MatchStateClient.fetchFotMobDetails(matchID: id) {
                detailCache[id] = details
                var changed = false
                for i in states.indices
                where states[i].source == .fotmob && states[i].fotmobID == id {
                    states[i].goals = details.goals
                    states[i].cards = details.cards
                    changed = true
                }
                if changed { revision += 1 }
            }
        }
    }

    /// The state bound to a fixture channel, if any: pair-key +
    /// date agreement, fail closed. When several layers bound the
    /// same fixture under different date keys, the highest layer
    /// wins (ESPN > FotMob > Flashscore > LiveScore).
    func state(for channel: Channel) -> MatchState? {
        guard let key = MatchMatching.pairKey(of: channel),
              let kickoff = channel.kickoff else { return nil }
        let fixtureDateKey = FixtureGrouping.stampDateKey(of: kickoff)
        let candidates = states.filter {
            $0.pairKey == key
                && MatchMatching.datesAgree(fixtureKickoff: kickoff,
                                            fixtureDateKey: fixtureDateKey,
                                            state: $0)
        }
        // Marker discipline (Addendum 2 §A2.1, applied to states):
        // a state whose women's markedness matches the fixture's
        // wins; a cross-marker bind is allowed only when it is the
        // unique candidate — otherwise the fixture stays unmatched
        // rather than borrowing the other side's match.
        let marked = MatchMatching.fixtureIsWomenMarked(channel)
        let exact = candidates.filter { $0.womenMarked == marked }
        let pool = !exact.isEmpty ? exact
            : (candidates.count == 1 ? candidates : [])
        guard let winner = pool.max(by: {
            precedence($0.source) < precedence($1.source)
        }) else { return nil }
        return stalenessOverride(of: winner, in: pool) ?? winner
    }

    /// Staleness guard (1.24): precedence is absolute, so a top
    /// layer whose clock stops advancing while the match plays on
    /// would outrank fresher layers forever. When the precedence
    /// winner is LIVE and another candidate state for the same
    /// fixture is also LIVE with a materially later minute (≥4′ —
    /// several poll cycles of advancement the winner missed) and
    /// no fewer goals (goals never un-happen), the fresher state
    /// wins wholesale — still one source's whole truth, never a
    /// field merge.
    ///
    /// Fail-closed by construction: the winner must be `.live`
    /// (a reported HT/FT/pre/postponed state is a real status,
    /// never "corrected" — RC5 discipline), the challenger must
    /// be `.live` too, both must carry a parseable minute AND a
    /// score, and the bounded computed clock is not a state and
    /// can never challenge. For São Paulo vs Fluminense
    /// (2026-11-19) this guard would NOT have fired — ESPN and
    /// FotMob agreed to the minute; the wrong number that night
    /// was the computed clock on the duplicate unbound tile.
    private func stalenessOverride(of winner: MatchState,
                                   in pool: [MatchState]) -> MatchState? {
        guard winner.status == .live,
              let winnerMinute = MatchMatching.minuteValue(of: winner.minuteText),
              let winnerHome = winner.scoreHome,
              let winnerAway = winner.scoreAway
        else { return nil }
        let challengers = pool.filter { other in
            guard other != winner, other.status == .live,
                  let minute = MatchMatching.minuteValue(of: other.minuteText),
                  minute >= winnerMinute + 4,
                  let home = other.scoreHome, let away = other.scoreAway
            else { return false }
            return home + away >= winnerHome + winnerAway
        }
        guard let freshest = challengers.max(by: { a, b in
            let am = MatchMatching.minuteValue(of: a.minuteText) ?? 0
            let bm = MatchMatching.minuteValue(of: b.minuteText) ?? 0
            if am != bm { return am < bm }
            return precedence(a.source) < precedence(b.source)
        }) else { return nil }
        let signature = "\(winner.source):\(winnerMinute)->"
            + "\(freshest.source):\(MatchMatching.minuteValue(of: freshest.minuteText) ?? -1)"
        if lastGuardLog[winner.pairKey] != signature {
            lastGuardLog[winner.pairKey] = signature
            DiagLog.log("cluster",
                        "staleness guard: \(winner.pairKey) — \(winner.source) "
                        + "\(winner.minuteText ?? "?") superseded by fresher "
                        + "\(freshest.source) \(freshest.minuteText ?? "?")")
        }
        return freshest
    }

    private func precedence(_ source: MatchSource) -> Int {
        switch source {
        case .espn: return 4
        case .fotmob: return 3
        case .flashscore: return 2
        case .livescore: return 1
        }
    }

    var hasLiveState: Bool { states.contains { $0.status.isLiveish } }

    /// FotMob matchDetails on demand (spec §1.2): for live fixtures
    /// ESPN did not cover — capped at 4 per call, live first, and
    /// never for a fixture already carrying an ESPN state.
    func upgradeDetails(for channels: [Channel]) async {
        var targets: [Int] = []
        for channel in channels {
            guard targets.count < 4,
                  let state = state(for: channel),
                  state.source == .fotmob,
                  let id = state.fotmobID,
                  state.goals.isEmpty,
                  detailCache[id] == nil else { continue }
            targets.append(id)
        }
        if targets.isEmpty { return }
        for id in targets {
            if let details = await MatchStateClient.fetchFotMobDetails(matchID: id) {
                detailCache[id] = details
                var changed = false
                for i in states.indices
                where states[i].source == .fotmob && states[i].fotmobID == id {
                    states[i].goals = details.goals
                    states[i].cards = details.cards
                    changed = true
                }
                if changed { revision += 1 }
            }
        }
    }

    /// The board-open upgrade: the fixture whose link board is open
    /// gets its FotMob incidents fetched first (spec §1.2).
    func ensureDetails(for channel: Channel) async {
        await upgradeDetails(for: [channel])
    }
}
