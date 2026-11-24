import Foundation

/// League classification + ordering, ported faithfully from the Android app
/// (MainActivity.leagueOf / bucketOf / sportOf / sortChannels).
///
/// Rules, exactly as on Android:
/// - A channel's league is decided ONLY by keyword-matching its lowercased
///   title, checked in the order Anh → Tây Ban Nha → Ý → Pháp → Đức. The
///   group-title (source brand) plays no part. No match → 9 (Khác).
///   (The Android source also defines an LG_VIE keyword list but leagueOf
///   never consults it — Vietnamese matches fall into Khác there, and
///   they do here too. Germany sat in the same boat until 1.20: Android's
///   LG_GER list existed unused; this port now consults an extended
///   German list at rank 5 — see `germany` below. See README.)
/// - Sort buckets: 0 = live window (kickoff −10 min … +125 min),
///   1 = upcoming match in a priority league, 2 = upcoming match in Khác,
///   3 = everything else (no kickoff, or long finished).
/// - Inside a bucket: football (⚽ / no sport emoji) before other sports,
///   then — bucket 1 only — by league order, then — buckets 0–2 — by
///   kickoff ascending. The sort is stable, like Java's Collections.sort.
enum LeagueClassifier {

    // Keyword lists copied verbatim from the Android source (LG_ENG,
    // LG_SPAIN, LG_ITA, LG_FRA). Matching is `title.contains(keyword)` on
    // the lowercased title. The `germany` list starts from Android's
    // LG_GER and extends it in the same house style (league name, then
    // top-flight clubs plus the big yo-yo clubs, with and without
    // diacritics) — owner's Bundesliga tab, 2026-11-19.
    private static let spain = ["tây ban nha", "la liga", "real madrid", "barcelona", "atlético", "atletico", "sevilla", "valencia cf", "real sociedad", "athletic", "real betis", "betis", "villarreal", "celta", "getafe", "espanyol", "mallorca", "osasuna", "rayo", "girona", "alavés", "alaves", "las palmas", "leganés", "leganes", "valladolid"]
    private static let england = ["ngoại hạng", "premier league", "arsenal", "chelsea", "liverpool", "manchester", "man utd", "man city", "tottenham", "newcastle", "aston villa", "west ham", "brighton", "everton", "wolves", "fulham", "brentford", "crystal palace", "nottingham", "leicester", "ipswich", "southampton", "bournemouth"]
    private static let italy = ["serie a", "napoli", "internazionale", "inter milan", "ac milan", "juventus", "as roma", "lazio", "atalanta", "fiorentina", "bologna", "torino", "como", "udinese", "genoa", "cagliari", "parma", "sassuolo", "verona", "lecce"]
    private static let france = ["ligue 1", "paris saint", "psg", "marseille", "monaco", "lille ", "losc", "olympique lyon", "lyon", "ogc nice", "nice", "lens", "rennes", "strasbourg", "toulouse", "brestois", "brest", "nantes", "angers sco", "auxerre", "le havre", "metz", "lorient", "le mans"]
    private static let germany = ["bundesliga", "bayern", "dortmund", "leverkusen", "leipzig", "stuttgart", "frankfurt", "wolfsburg", "gladbach", "hoffenheim", "union berlin", "köln", "koln", "cologne", "hamburg", "hsv", "werder", "bremen", "freiburg", "augsburg", "mainz", "heidenheim", "st. pauli", "st pauli", "holstein", "kiel", "hertha", "schalke", "bielefeld", "magdeburg", "darmstadt", "paderborn", "elversberg"]

    static func leagueRank(of title: String) -> Int {
        let t = title.lowercased()
        for k in england where t.contains(k) { return 1 }
        for k in spain where t.contains(k) { return 2 }
        for k in italy where t.contains(k) { return 3 }
        for k in france where t.contains(k) { return 4 }
        for k in germany where t.contains(k) { return 5 }
        return 9
    }

    /// Sort bucket for "now" — see the type doc comment. Mirrors Android
    /// bucketOf(channel, now) with kickoffMs == 0 → bucket 3.
    static func bucket(of channel: Channel, now: Date) -> Int {
        guard let kickoff = channel.kickoff else { return 3 }
        let sinceKick = now.timeIntervalSince(kickoff) // seconds since kickoff
        if sinceKick >= -10 * 60 && sinceKick <= 125 * 60 { return 0 }
        if sinceKick < -10 * 60 { return channel.leagueRank < 9 ? 1 : 2 }
        return 3
    }

    /// Sport identity of a channel title: 0 = positively football
    /// (⚽ in the title), 1 = other sport (🏐🏀🎾🏸🏒🥊 in the
    /// title), 2 = unknown (no sport emoji at all — NOT assumed
    /// football). FIX-139: Android's sportOf returned 0 for the
    /// untagged fall-through too, which made "untagged" and
    /// "football" indistinguishable; the fall-through is now 2.
    /// `sorted(_:now:)` maps 2 back into the football group, so
    /// ordering is unchanged — only identity tests see the new
    /// value (see `isIdentifiedFootball`).
    static func sportRank(of channel: Channel) -> Int {
        let t = channel.title
        if t.contains("⚽") { return 0 }
        if t.contains("🏐") || t.contains("🏀") || t.contains("🎾")
            || t.contains("🏸") || t.contains("🏒") || t.contains("🥊") {
            return 1
        }
        return 2
    }

    /// Positive football identity — the ONLY test the football-clock
    /// gates (`FixtureEntry.liveBadgeText` / `isHalfTimeDisplay`)
    /// may use. FIX-139 (WP5 root cause): the FIX-137 gates tested
    /// `sportRank == 0`, but 0 was also the fall-through for
    /// untagged channels, and the playlist carries no 🏒 tags at
    /// all — an NHL fixture (Minnesota Wild vs San Jose Sharks)
    /// passed as "football" and wore a fabricated "75'".
    ///
    /// Identity, positively: false when the title positively names
    /// another sport (sportRank 1); true when the title carries ⚽
    /// (sportRank 0); otherwise true only when the title matched
    /// the classifier's known football-league vocabulary
    /// (`channel.leagueRank < 9` — the channel's stored property,
    /// set at parse from `leagueRank(of:)`). An untagged fixture
    /// from an unrecognised league is UNKNOWN and fails this test:
    /// it keeps its LIVE badge, just no fabricated minute. A
    /// fixture with a matched state never reaches the gates (the
    /// state path bypasses them), so identified-by-state football
    /// is unaffected.
    static func isIdentifiedFootball(_ channel: Channel) -> Bool {
        let rank = sportRank(of: channel)
        if rank == 1 { return false }
        if rank == 0 { return true }
        return channel.leagueRank < 9
    }

    /// The Android sortChannels comparator. Swift's sorted(by:) is stable,
    /// matching Java's Collections.sort for equal elements.
    static func sorted(_ list: [Channel], now: Date = Date()) -> [Channel] {
        list.sorted { a, b in
            let ba = bucket(of: a, now: now)
            let bb = bucket(of: b, now: now)
            if ba != bb { return ba < bb }
            // FIX-139: sportRank is now 0 = football / 1 = other
            // sport / 2 = unknown. The sort deliberately keeps
            // unknown with football (ordering is presentation, not
            // identity), so compare on the derived key — rank 1 → 1,
            // ranks 0 and 2 → 0 — which reproduces the pre-FIX-139
            // comparator outcome for every input pair.
            let sa = sportRank(of: a) == 1 ? 1 : 0
            let sb = sportRank(of: b) == 1 ? 1 : 0
            if sa != sb { return sa < sb }
            if ba == 1 && a.leagueRank != b.leagueRank { return a.leagueRank < b.leagueRank }
            if ba <= 2 {
                let ka = a.kickoff?.timeIntervalSince1970 ?? .greatestFiniteMagnitude
                let kb = b.kickoff?.timeIntervalSince1970 ?? .greatestFiniteMagnitude
                if ka != kb { return ka < kb }
            }
            return false
        }
    }

    /// True when the channel is inside the live window (bucket 0) at `now`.
    static func isLive(_ channel: Channel, now: Date = Date()) -> Bool {
        bucket(of: channel, now: now) == 0
    }

    /// State-aware bucket (spec §1.4): a matched state wins
    /// completely over the wall-clock window — FT/AP and
    /// postponed/cancelled leave bucket 0 at the next poll, NS
    /// suppresses bucket 0 even inside the −10-minute window, and
    /// a source-live fixture stays bucket 0 past +125 minutes
    /// (extra time and penalties are real). Unmatched fixtures
    /// keep the wall-clock bucket unchanged.
    static func bucket(of channel: Channel, now: Date, state: MatchState?) -> Int {
        guard let state else { return bucket(of: channel, now: now) }
        switch state.status {
        case .fullTime, .cancelled, .postponed:
            return 3
        case .pre:
            guard let kickoff = channel.kickoff else { return 3 }
            if kickoff > now { return channel.leagueRank < 9 ? 1 : 2 }
            return 3
        case .live, .halfTime:
            return 0
        }
    }

    // MARK: - Division + cup classification (spec §3/§4, 1.21)

    /// Division-2 club rosters, seeded VERBATIM from the spec's
    /// Appendix B (ESPN /teams pull, 2026-11-19) — membership is
    /// season data (plan §6-Q7: refresh each August). Names are
    /// stored as ESPN writes them and normalised through
    /// FixtureGrouping.normalizedTeam, exactly like a title's team
    /// names, so both sides land in the same key space. S1 (a
    /// matched event's competition) always overrides these lists.
    private static let div2Seeds: [Int: [String]] = [
        1: ["Birmingham City", "Blackburn Rovers", "Bolton Wanderers", "Bristol City",
            "Burnley", "Cardiff City", "Charlton Athletic", "Derby County",
            "Lincoln City", "Middlesbrough", "Millwall", "Norwich City",
            "Portsmouth", "Preston North End", "Queens Park Rangers",
            "Sheffield United", "Southampton", "Stoke City", "Swansea City",
            "Watford", "West Bromwich Albion", "West Ham United",
            "Wolverhampton Wanderers", "Wrexham"],
        2: ["Albacete", "Almería", "Burgos", "CD Sabadell", "Castellón", "Ceuta",
            "Cádiz", "Córdoba", "Eibar", "Eldense", "FC Andorra", "Girona",
            "Granada", "Las Palmas", "Leganés", "Mallorca", "RC Celta Fortuna",
            "Real Oviedo", "Real Sociedad II", "Real Valladolid",
            "Sporting Gijón", "Tenerife"],
        3: ["Arezzo", "Ascoli", "Benevento", "Carrarese", "Catanzaro", "Cesena",
            "Cremonese", "Empoli", "Hellas Verona", "Juve Stabia", "Mantova",
            "Modena", "Padova", "Palermo", "Pisa", "Sampdoria", "Sudtirol",
            "US Avellino", "Vicenza", "Virtus Entella"],
        4: ["AS Nancy Lorraine", "Annecy", "Boulogne", "Clermont Foot",
            "Dijon FCO", "Dunkerque", "Grenoble", "Guingamp", "Metz",
            "Montpellier", "Nantes", "Pau", "Red Star FC 93", "Rodez Aveyron",
            "Saint-Étienne", "Sochaux", "Stade Laval", "Stade de Reims"],
        5: ["1. FC Heidenheim 1846", "1. FC Magdeburg", "1. FC Nürnberg",
            "Arminia Bielefeld", "Dynamo Dresden", "Energie Cottbus",
            "Hannover 96", "Hertha Berlin", "Holstein Kiel", "Kaiserslautern",
            "Karlsruher SC", "SV Darmstadt 98", "SpVgg Greuther Fürth",
            "St. Pauli", "TSV Eintracht Braunschweig", "VfL Bochum",
            "VfL Osnabruck", "VfL Wolfsburg"],
    ]

    /// Division-1 rosters (2025-26 membership) for the S3 guard:
    /// a pair files division-2 only when NEITHER club is in its
    /// country's division-1 roster — this is what neutralises the
    /// Appendix-B seed entries that are top-flight clubs this
    /// season (West Ham, Wolves, Wolfsburg, Nantes…) and every
    /// cross-division cup tie. Short forms the mirror actually
    /// writes ("Wolves", "Man City", "PSG", "Inter") are included
    /// alongside the canonical names.
    private static let div1Seeds: [Int: [String]] = [
        1: ["Arsenal", "Aston Villa", "Bournemouth", "Brentford",
            "Brighton & Hove Albion", "Brighton", "Burnley", "Chelsea",
            "Crystal Palace", "Everton", "Fulham", "Leeds United", "Leeds",
            "Liverpool", "Manchester City", "Man City", "Manchester United",
            "Man Utd", "Newcastle United", "Newcastle", "Nottingham Forest",
            "Sunderland", "Tottenham Hotspur", "Spurs", "West Ham United",
            "West Ham", "Wolverhampton Wanderers", "Wolves"],
        2: ["Alavés", "Athletic Club", "Athletic Bilbao", "Atlético Madrid",
            "Atletico Madrid", "Barcelona", "Celta Vigo", "Elche", "Espanyol",
            "Getafe", "Girona", "Levante", "Mallorca", "Osasuna",
            "Rayo Vallecano", "Real Betis", "Real Madrid", "Real Oviedo",
            "Real Sociedad", "Sevilla", "Valencia", "Villarreal"],
        3: ["Atalanta", "Bologna", "Cagliari", "Como", "Cremonese",
            "Fiorentina", "Genoa", "Inter Milan", "Inter", "Juventus",
            "Lazio", "Lecce", "AC Milan", "Milan", "Napoli", "Parma", "Pisa",
            "AS Roma", "Roma", "Sassuolo", "Torino", "Udinese",
            "Hellas Verona", "Verona"],
        4: ["Angers SCO", "Angers", "Auxerre", "Brest", "Le Havre", "Lens",
            "Lille", "Lorient", "Lyon", "Marseille", "Metz", "Monaco",
            "Nantes", "Nice", "Paris FC", "Paris Saint-Germain", "PSG",
            "Rennes", "Strasbourg", "Toulouse"],
        5: ["FC Augsburg", "Augsburg", "Bayern Munich", "Bayern",
            "Borussia Dortmund", "Dortmund", "Borussia Mönchengladbach",
            "Gladbach", "Eintracht Frankfurt", "Frankfurt", "SC Freiburg",
            "Freiburg", "Hamburger SV", "Hamburg", "Heidenheim",
            "TSG Hoffenheim", "Hoffenheim", "1. FC Köln", "Köln", "Koln",
            "RB Leipzig", "Leipzig", "Bayer Leverkusen", "Leverkusen",
            "Mainz 05", "Mainz", "FC St. Pauli", "St. Pauli",
            "VfB Stuttgart", "Stuttgart", "Union Berlin", "Werder Bremen",
            "Bremen", "VfL Wolfsburg", "Wolfsburg"],
    ]

    private static func normalizedSet(_ seeds: [String]) -> Set<String> {
        Set(seeds.map { FixtureGrouping.normalizedTeam($0) }.filter { !$0.isEmpty })
    }

    private static let div2Sets: [Int: Set<String>] = div2Seeds.mapValues(normalizedSet)
    private static let div1Sets: [Int: Set<String>] = div1Seeds.mapValues(normalizedSet)

    /// Women's / youth guard (spec §3.2): the men's division
    /// rosters must never be applied to a pair carrying a women's
    /// marker (Women / W / Nữ) or a youth-age marker (U17…U23).
    private static func isWomenOrYouth(normalizedTeam name: String) -> Bool {
        for token in name.split(separator: " ") {
            let t = String(token)
            if t == "women" || t == "w" || t == "nu" { return true }
            if t.count >= 2, t.hasPrefix("u"),
               t.dropFirst().allSatisfy({ $0.isNumber }) { return true }
        }
        return false
    }

    /// S3 — the both-clubs rule (spec §3.2): a mirror fixture files
    /// in its country's division 2 ONLY when both normalised clubs
    /// are in the division-2 roster AND neither is in the
    /// division-1 roster. Every other case is not division 2.
    static func isLowerDivisionPair(_ channel: Channel) -> Bool {
        let rank = channel.leagueRank
        guard let div2 = div2Sets[rank], let div1 = div1Sets[rank],
              let (a, b) = Crests.teams(ofCleanTitle: MatchTitle.clean(channel.title))
        else { return false }
        let na = FixtureGrouping.normalizedTeam(a)
        let nb = FixtureGrouping.normalizedTeam(b)
        guard !na.isEmpty, !nb.isEmpty,
              !isWomenOrYouth(normalizedTeam: na),
              !isWomenOrYouth(normalizedTeam: nb)
        else { return false }
        return div2.contains(na) && div2.contains(nb)
            && !div1.contains(na) && !div1.contains(nb)
    }

    /// The fixture's competition (spec §3/§4 signal order):
    /// S1 — the matched state's competition, authoritative;
    /// S3 — the both-clubs rule for mirror fixtures of a known
    /// country; otherwise the top section of the classifier's
    /// country (never guessed). Cup membership comes ONLY from
    /// S1/S2 — cup club pools are forbidden as classifiers (§4.2).
    static func competition(for channel: Channel, state: MatchState?) -> CompetitionID {
        if let competition = state?.competition { return competition }
        let rank = channel.leagueRank
        if (1...5).contains(rank) {
            return .league(rank: rank, lower: isLowerDivisionPair(channel))
        }
        return .other(label: "Khác")
    }

    /// S2 — the addon competition string, exact match only (spec
    /// §3.2/§4.2). Any other value — in particular the generic
    /// "Football" — is no signal and falls through.
    static func competition(forAddonString raw: String?) -> CompetitionID? {
        switch raw {
        case "Ligue 2": return .league(rank: 4, lower: true)
        case "2. Bundesliga": return .league(rank: 5, lower: true)
        case "LaLiga 2": return .league(rank: 2, lower: true)
        case "UEFA Champions League": return .cup(.champions, women: false)
        case "UEFA Europa League": return .cup(.europa, women: false)
        case "UEFA Conference League": return .cup(.conference, women: false)
        case "UEFA Women's Champions League", "UEFA Women Champions League":
            return .cup(.champions, women: true)
        default: return nil
        }
    }

    // MARK: - English-commentary block

    /// group-title of the English-commentary block the mirror appends
    /// after the Vietnamese list (scrape_en.py, 2026-11-14): 24/7
    /// channels with English commentary, kept as a fallback pool
    /// beside the fixture tabs. Identified by GROUP, not by title —
    /// the league rules above stay title-only, exactly as on Android.
    static let enGroupName = "EN · BLV Anh"

    /// selectedLeague value meaning "the BLV Anh tab" (league
    /// rawValues are 1, 2, 3, 4 and 9; PlaylistStore uses 0 for the
    /// Hot tab and -1 for Trực tiếp, so -2 is free).
    static let enTabValue = -2

    /// True for a channel from the English-commentary block. These
    /// channels carry no kickoff, so the bucket sort parks them in
    /// bucket 3 and their titles match no league keyword (rank 9) —
    /// without this carve-out they surface inside the Khác league
    /// list as pseudo-fixtures. The UI keeps them under their own
    /// chip instead and filters them out of every league list.
    static func isEN(_ channel: Channel) -> Bool {
        channel.group == enGroupName
    }
}
