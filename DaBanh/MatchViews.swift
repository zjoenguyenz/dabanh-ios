import SwiftUI

/// Accent green used across the UI (shared with ContentView).
let accentGreen = Color(red: 0.13, green: 0.77, blue: 0.37)

/// Kickoff formatting shared by the cards. Times render in the
/// DEVICE's local timezone (owner's rule, 2026-11-14): playlist
/// kickoffs are absolute instants parsed from ICT stamps, so the same
/// match reads 21:00 in Vietnam and 08:00 in Oklahoma. Live minutes
/// are computed from the absolute instant and never shift.
/// MainActor-isolated (Swift 6): DateFormatter is not Sendable, and
/// every caller is a SwiftUI view on the main actor anyway.
@MainActor
enum KickoffFormat {
    static let time: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = .autoupdatingCurrent
        f.dateFormat = "HH:mm"
        return f
    }()

    static let day: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = .autoupdatingCurrent
        f.dateFormat = "dd/MM"
        return f
    }()

    static let full: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = .autoupdatingCurrent
        f.dateFormat = "HH:mm dd/MM"
        return f
    }()

    /// Minutes played for a live match, from the absolute kickoff.
    static func liveMinute(of kickoff: Date, now: Date = Date()) -> Int {
        max(1, Int(now.timeIntervalSince(kickoff) / 60))
    }
}

/// One fixture as the UI presents it (redesign, 2026-11-14): every
/// source carrying the same match collapses into a single entry, so
/// a match never appears as two or three near-identical rows again.
/// What "the same match" means is FixtureGrouping's pair-key
/// identity (order-independent, filler-tolerant, stamp-jitter and
/// live-merge aware — see Crests.swift), shared with the TV app and
/// with PlaylistStore.sources(for:), so a card and the player's
/// fallback ladder always cover exactly the same sources. The
/// representative channel is the first one in the store's sorted
/// order. Display-only: stored channels are never mutated.
struct FixtureEntry: Identifiable {
    let channel: Channel
    let sourceCount: Int
    let id: String

    /// Title with the kickoff stamp and ⚽🟢🔴 markers stripped —
    /// the only title form the redesigned UI ever shows.
    var cleanTitle: String { MatchTitle.clean(channel.title) }

    /// "Team A" / "Team B" when the cleaned title is a fixture.
    var teams: (String, String)? { Crests.teams(ofCleanTitle: cleanTitle) }

    /// Both crest URLs for the fixture (either side may be nil when
    /// that team is not in the crest map); nil when not a fixture.
    var crests: (URL?, URL?)? { Crests.crests(forTitle: channel.title) }

    var isLive: Bool { LeagueClassifier.isLive(channel) }

    var leagueName: String {
        League(rawValue: channel.leagueRank)?.name ?? "Khác"
    }

    /// Group a sorted channel list into fixture entries, preserving
    /// the incoming order (first occurrence wins the slot). The
    /// identity itself lives in FixtureGrouping (Crests.swift).
    static func group(_ channels: [Channel]) -> [FixtureEntry] {
        FixtureGrouping.group(channels).map { g in
            FixtureEntry(channel: g.members[0], sourceCount: g.members.count, id: g.id)
        }
    }
}

/// Big face-off card for the featured rail: the two crests large,
/// team names under them, league line on top, LIVE badge + minute
/// (or kickoff) and a big play button along the bottom.
struct FeaturedCard: View {
    @EnvironmentObject private var store: PlaylistStore
    let entry: FixtureEntry

    var body: some View {
        let _ = store.crestsRevision
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(entry.leagueName.uppercased())
                    .font(.caption2.bold())
                    .tracking(1)
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if entry.sourceCount > 1 {
                    Text("\(entry.sourceCount) nguồn")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.white.opacity(0.14), in: Capsule())
                }
            }

            if let teams = entry.teams {
                faceOff(teams)
            } else {
                HStack(spacing: 12) {
                    LogoTile(channel: entry.channel, size: 54, corner: 12)
                    Text(entry.cleanTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                if entry.isLive {
                    HStack(spacing: 5) {
                        Circle().fill(Color.white).frame(width: 6, height: 6)
                        if let kickoff = entry.channel.kickoff {
                            Text("ĐANG ĐÁ · \(KickoffFormat.liveMinute(of: kickoff))'")
                                .font(.caption2.bold())
                        } else {
                            Text("ĐANG ĐÁ")
                                .font(.caption2.bold())
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.red, in: Capsule())
                }
                if let kickoff = entry.channel.kickoff {
                    Text(KickoffFormat.full.string(from: kickoff))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.75))
                }
                Spacer(minLength: 0)
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.white)
            }
        }
        .padding(14)
        .frame(width: 300, height: 176, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Color(red: 0.05, green: 0.23, blue: 0.13),
                         Color(red: 0.02, green: 0.09, blue: 0.06)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 18)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 18))
    }

    /// Crest over name, twice, with a quiet "VS" between them.
    private func faceOff(_ teams: (String, String)) -> some View {
        HStack(alignment: .top, spacing: 6) {
            teamBlock(name: teams.0, crest: entry.crests?.0 ?? nil)
            Text("VS")
                .font(.caption2.bold())
                .foregroundStyle(.white.opacity(0.45))
                .padding(.top, 22)
            teamBlock(name: teams.1, crest: entry.crests?.1 ?? nil)
        }
    }

    private func teamBlock(name: String, crest: URL?) -> some View {
        VStack(spacing: 6) {
            CrestImg(url: crest, size: 52)
            Text(name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}

/// One fixture as a list card: time block on the left (LIVE + minute /
/// local kickoff / replay / channel), crest + Team A vs Team B +
/// crest in the middle, source line under it, play on the right.
struct MatchCard: View {
    @EnvironmentObject private var store: PlaylistStore
    let entry: FixtureEntry

    private var channel: Channel { entry.channel }
    private var isLive: Bool { entry.isLive }

    var body: some View {
        let _ = store.crestsRevision
        HStack(spacing: 12) {
            statusBlock
            middle
            Spacer(minLength: 0)
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

    /// Four-state status block, same language as the TV versions:
    /// LIVE + minute / kickoff time / ↺ PHÁT LẠI / 📺 KÊNH — so a
    /// replay source is never mistaken for a live one (owner,
    /// 2026-11-13). Kickoff times are device-local.
    private var statusBlock: some View {
        VStack(spacing: 2) {
            if isLive {
                HStack(spacing: 3) {
                    Circle().fill(Color.red).frame(width: 7, height: 7)
                    Text("LIVE")
                        .font(.caption.bold())
                        .foregroundStyle(.red)
                }
                if let kickoff = channel.kickoff {
                    Text("\(KickoffFormat.liveMinute(of: kickoff))'")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.red.opacity(0.8))
                }
            } else if let kickoff = channel.kickoff, kickoff > Date() {
                Text(KickoffFormat.time.string(from: kickoff))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text(KickoffFormat.day.string(from: kickoff))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
            } else if channel.kickoff != nil {
                Text("↺")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.55))
                Text("PHÁT LẠI")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
            } else {
                Text("📺")
                    .font(.caption)
                Text("KÊNH")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .frame(width: 48)
    }

    @ViewBuilder
    private var middle: some View {
        if let teams = entry.teams {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    CrestImg(url: entry.crests?.0 ?? nil, size: 28)
                    Text("\(teams.0) vs \(teams.1)")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    CrestImg(url: entry.crests?.1 ?? nil, size: 28)
                }
                caption
            }
        } else {
            HStack(spacing: 10) {
                LogoTile(channel: channel, size: 44, corner: 10)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.cleanTitle)
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    caption
                }
            }
        }
    }

    /// Source line: the playlist group, plus how many sources carry
    /// this fixture when it is more than the one shown.
    private var caption: some View {
        Text(entry.sourceCount > 1
             ? "\(channel.group) • \(entry.sourceCount) nguồn"
             : channel.group)
            .font(.caption)
            .foregroundStyle(.white.opacity(0.5))
            .lineLimit(1)
    }
}

/// Fixed-size channel logo with a placeholder that never breaks layout.
struct LogoTile: View {
    let channel: Channel
    let size: CGFloat
    let corner: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner)
                .fill(Color.white.opacity(0.08))
            AsyncImage(url: channel.logoURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFit()
                default:
                    Image(systemName: "soccerball")
                        .font(.system(size: size * 0.45))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .padding(4)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner))
    }
}

/// One row of the BLV Anh tab: a 24/7 English-commentary channel —
/// logo tile, channel name, an always-on LIVE badge and the play
/// affordance, in the same card chrome as MatchCard. No time block
/// and no fixture face-off: these channels have no kickoff to show
/// and are not fixtures, so the row never pretends otherwise.
struct ENChannelRow: View {
    let channel: Channel

    /// Channel name without the block's "EN · " title prefix — the
    /// tab itself already says whose channels these are.
    var displayName: String {
        channel.title.hasPrefix("EN · ")
            ? String(channel.title.dropFirst(5))
            : channel.title
    }

    var body: some View {
        HStack(spacing: 12) {
            LogoTile(channel: channel, size: 44, corner: 10)
            Text(displayName)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            HStack(spacing: 5) {
                Circle().fill(Color.white).frame(width: 6, height: 6)
                Text("LIVE")
                    .font(.caption2.bold())
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.red, in: Capsule())
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
}

/// One team crest with a shield placeholder while loading / missing.
struct CrestImg: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit()
                    default:
                        Image(systemName: "shield")
                            .font(.system(size: size * 0.6))
                            .foregroundStyle(.white.opacity(0.35))
                    }
                }
            } else {
                Image(systemName: "shield")
                    .font(.system(size: size * 0.6))
                    .foregroundStyle(.white.opacity(0.2))
            }
        }
        .frame(width: size, height: size)
    }
}
