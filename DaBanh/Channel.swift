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
    /// 1 = Ngoại Hạng Anh, 2 = Tây Ban Nha, 3 = Ý, 4 = Pháp, 9 = Khác.
    let leagueRank: Int

    init(title: String, logo: String, group: String, url: String, kickoff: Date?, leagueRank: Int) {
        self.title = title
        self.logo = logo
        self.group = group
        self.url = url
        self.kickoff = kickoff
        self.leagueRank = leagueRank
    }

    var streamURL: URL? { URL(string: url) }
    var logoURL: URL? { logo.isEmpty ? nil : URL(string: logo) }
}

/// The five league tabs, in the user's fixed order (Android LEAGUE_TABS /
/// LEAGUE_NAMES in MainActivity).
enum League: Int, CaseIterable, Identifiable {
    case england = 1
    case spain = 2
    case italy = 3
    case france = 4
    case other = 9

    var id: Int { rawValue }

    var name: String {
        switch self {
        case .england: return "Ngoại Hạng Anh"
        case .spain: return "Tây Ban Nha"
        case .italy: return "Ý"
        case .france: return "Pháp"
        case .other: return "Khác"
        }
    }
}
