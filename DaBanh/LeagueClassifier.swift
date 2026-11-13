import Foundation

/// League classification + ordering, ported faithfully from the Android app
/// (MainActivity.leagueOf / bucketOf / sportOf / sortChannels).
///
/// Rules, exactly as on Android:
/// - A channel's league is decided ONLY by keyword-matching its lowercased
///   title, checked in the order Anh → Tây Ban Nha → Ý → Pháp. The
///   group-title (source brand) plays no part. No match → 9 (Khác).
///   (The Android source also defines LG_GER and LG_VIE keyword lists but
///   leagueOf never consults them — German and Vietnamese matches fall into
///   Khác there, and they do here too. See README.)
/// - Sort buckets: 0 = live window (kickoff −10 min … +140 min),
///   1 = upcoming match in a priority league, 2 = upcoming match in Khác,
///   3 = everything else (no kickoff, or long finished).
/// - Inside a bucket: football (⚽ / no sport emoji) before other sports,
///   then — bucket 1 only — by league order, then — buckets 0–2 — by
///   kickoff ascending. The sort is stable, like Java's Collections.sort.
enum LeagueClassifier {

    // Keyword lists copied verbatim from the Android source (LG_ENG,
    // LG_SPAIN, LG_ITA, LG_FRA). Matching is `title.contains(keyword)` on
    // the lowercased title.
    private static let spain = ["tây ban nha", "la liga", "real madrid", "barcelona", "atlético", "atletico", "sevilla", "valencia cf", "real sociedad", "athletic", "real betis", "betis", "villarreal", "celta", "getafe", "espanyol", "mallorca", "osasuna", "rayo", "girona", "alavés", "alaves", "las palmas", "leganés", "leganes", "valladolid"]
    private static let england = ["ngoại hạng", "premier league", "arsenal", "chelsea", "liverpool", "manchester", "man utd", "man city", "tottenham", "newcastle", "aston villa", "west ham", "brighton", "everton", "wolves", "fulham", "brentford", "crystal palace", "nottingham", "leicester", "ipswich", "southampton", "bournemouth"]
    private static let italy = ["serie a", "napoli", "internazionale", "inter milan", "ac milan", "juventus", "as roma", "lazio", "atalanta", "fiorentina", "bologna", "torino", "como", "udinese", "genoa", "cagliari", "parma", "sassuolo", "verona", "lecce"]
    private static let france = ["ligue 1", "paris saint", "psg", "marseille", "monaco", "lille ", "losc", "olympique lyon", "lyon", "ogc nice", "nice", "lens", "rennes", "strasbourg", "toulouse", "brestois", "brest", "nantes", "angers", "auxerre", "le havre", "metz", "lorient", "le mans"]

    static func leagueRank(of title: String) -> Int {
        let t = title.lowercased()
        for k in england where t.contains(k) { return 1 }
        for k in spain where t.contains(k) { return 2 }
        for k in italy where t.contains(k) { return 3 }
        for k in france where t.contains(k) { return 4 }
        return 9
    }

    /// Sort bucket for "now" — see the type doc comment. Mirrors Android
    /// bucketOf(channel, now) with kickoffMs == 0 → bucket 3.
    static func bucket(of channel: Channel, now: Date) -> Int {
        guard let kickoff = channel.kickoff else { return 3 }
        let sinceKick = now.timeIntervalSince(kickoff) // seconds since kickoff
        if sinceKick >= -10 * 60 && sinceKick <= 140 * 60 { return 0 }
        if sinceKick < -10 * 60 { return channel.leagueRank < 9 ? 1 : 2 }
        return 3
    }

    /// 0 = football first, 1 = other sports. Mirrors Android sportOf: a ⚽ in
    /// the title (or no sport emoji at all) means football; 🏐🏀🎾🏸🏒🥊
    /// mean "other sport".
    static func sportRank(of channel: Channel) -> Int {
        let t = channel.title
        if t.contains("⚽") { return 0 }
        if t.contains("🏐") || t.contains("🏀") || t.contains("🎾")
            || t.contains("🏸") || t.contains("🏒") || t.contains("🥊") {
            return 1
        }
        return 0
    }

    /// The Android sortChannels comparator. Swift's sorted(by:) is stable,
    /// matching Java's Collections.sort for equal elements.
    static func sorted(_ list: [Channel], now: Date = Date()) -> [Channel] {
        list.sorted { a, b in
            let ba = bucket(of: a, now: now)
            let bb = bucket(of: b, now: now)
            if ba != bb { return ba < bb }
            let sa = sportRank(of: a)
            let sb = sportRank(of: b)
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
}
