import Foundation

/// One playlist entry — mirrors `Channel` in the Android Đá Banh TV app
/// (com.gathin.dabanh.MainActivity.Channel).
struct Channel: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let logo: String
    let group: String
    let url: String
    /// Kickoff parsed from the title (Vietnam time, ICT). nil mirrors
    /// Android's kickoffMs == 0 ("no kickoff in the title").
    let kickoff: Date?
    /// 1 = Ngoại Hạng Anh, 2 = Tây Ban Nha, 3 = Ý, 4 = Pháp, 5 = Đức,
    /// 9 = Khác.
    let leagueRank: Int
    /// Playback headers the entry itself declares via #EXTVLCOPT
    /// (http-referrer / http-user-agent). Some CDNs refuse the stream
    /// without them; empty means "send nothing extra" — a blanket
    /// Referer is never invented, because probing on Android showed an
    /// uninvited Referer turns other hosts' segment fetches into 403.
    let referrer: String
    let userAgent: String

    init(title: String, logo: String, group: String, url: String, kickoff: Date?, leagueRank: Int,
         referrer: String = "", userAgent: String = "") {
        self.title = title
        self.logo = logo
        self.group = group
        self.url = url
        self.kickoff = kickoff
        self.leagueRank = leagueRank
        self.referrer = referrer
        self.userAgent = userAgent
    }

    var streamURL: URL? { URL(string: url) }
    var logoURL: URL? { logo.isEmpty ? nil : URL(string: logo) }
}

/// The six league tabs, in the user's fixed order (Android LEAGUE_TABS /
/// LEAGUE_NAMES in MainActivity).
enum League: Int, CaseIterable, Identifiable {
    case england = 1
    case spain = 2
    case italy = 3
    case france = 4
    case germany = 5
    /// The European cups tab (spec §4.1): value 6, placed after
    /// Đức (5) and before Khác (9). No channel ever carries rank
    /// 6 — cup fixtures keep their country leagueRank and are
    /// filed here by CompetitionID (S1/S2), in dual presence with
    /// their country tab.
    case cups = 6
    case other = 9

    var id: Int { rawValue }

    var name: String {
        switch self {
        case .england: return "Ngoại Hạng Anh"
        case .spain: return "Tây Ban Nha"
        case .italy: return "Ý"
        case .france: return "Pháp"
        case .germany: return "Đức"
        case .cups: return "Cúp châu Âu"
        case .other: return "Khác"
        }
    }

    /// Short tab-pill label (owner ruling 2026-11-19): the pills
    /// stay small and short like "Đức". `name` keeps the full
    /// wording for every other consumer (the tile league line in
    /// MatchViews, fallbacks) — only the pill renders `tabName`.
    /// The cups pill label is "Cúp EU" (owner ruling 2026-11-19
    /// 14:38, tab label only); `name` above keeps "Cúp châu Âu"
    /// and every in-tab cup header keeps its spec wording.
    var tabName: String {
        switch self {
        case .england: return "NHA"
        case .spain: return "TBN"
        case .italy: return "Ý"
        case .france: return "Pháp"
        case .germany: return "Đức"
        case .cups: return "Cúp EU"
        case .other: return "Khác"
        }
    }

    /// National-team name whose existing crest (the Crests map's
    /// national-team badge) rides small beside `tabName` in the
    /// pill (owner ruling 2026-11-19: small country badge + short
    /// text). nil = text-only pill: the cups tab carries no badge
    /// by the same ruling, and Khác has no country.
    var tabCrestTeam: String? {
        switch self {
        case .england: return "England"
        case .spain: return "Spain"
        case .italy: return "Italy"
        case .france: return "France"
        case .germany: return "Germany"
        case .cups, .other: return nil
        }
    }
}
