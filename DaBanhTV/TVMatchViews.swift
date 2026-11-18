import SwiftUI

/// TV-native building blocks for the Đá Banh TV redesign (v1.3.0,
/// 2026-11-14). What is carried over from the iPhone v1.11 redesign
/// is only the design LANGUAGE and the data behaviour: one card per
/// fixture with its sources grouped inside, cleaned titles (never a
/// raw playlist title), crest-vs-crest face-offs, true live minute /
/// device-local kickoff, and the store's source ladder at play time.
/// Nothing about the phone's layout comes with it — no vertical list
/// of rows, no 300pt swipe cards. Everything here is composed for a
/// 1080p/4K screen driven by a remote from the sofa: wide landscape
/// tiles in horizontal rails, 20pt+ type throughout, and a focus
/// ring you can see from across the room.
///
/// This file is tvOS-only. The iOS target has its own equivalents in
/// MatchViews.swift; the shared engine files (Channel, Crests,
/// LeagueClassifier, M3UParser, PlaylistStore) are untouched.

// MARK: - Kickoff formatting (device-local, like the phone)

/// Kickoff stamps in the playlist are absolute instants parsed from
/// ICT text, so they must render in the DEVICE's timezone — the
/// owner's rule from the iPhone redesign (21:00 in Vietnam reads
/// 08:00 in Oklahoma). The old TV view pinned its formatter to
/// Asia/Ho_Chi_Minh; v1.3.0 follows the device like the phone does.
/// Live minutes come from the absolute instant and never shift.
enum TVKickoffFormat {
    static let time: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = .autoupdatingCurrent
        f.dateFormat = "HH:mm"
        return f
    }()

    static let timeDay: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = .autoupdatingCurrent
        f.dateFormat = "HH:mm · dd/MM"
        return f
    }()

    /// Minutes played for a live match, from the absolute kickoff.
    static func liveMinute(of kickoff: Date, now: Date = Date()) -> Int {
        max(1, Int(now.timeIntervalSince(kickoff) / 60))
    }
}

// MARK: - Fixture grouping (same rules as the phone, TV presentation)

/// One fixture as the TV UI presents it: every source carrying the
/// same match collapses into a single tile, so a match never fills
/// a rail with two or three near-identical cards again. Grouping
/// rules are the shared FixtureGrouping pair-key identity
/// (Crests.swift — order-independent, filler-tolerant, stamp-jitter
/// and live-merge aware), the same identity the phone's cards and
/// the store's source ladder use; the representative channel is
/// the first in the store's sorted order, and playing hands it to
/// PlaylistStore.sources(for:), which returns the fixture's full
/// member list as the fallback ladder. Display-only: stored
/// channels are never mutated.
struct TVFixtureEntry: Identifiable {
    let channel: Channel
    let sourceCount: Int
    let id: String

    /// Cleaned title — the only title form the UI ever shows.
    var cleanTitle: String { MatchTitle.clean(channel.title) }

    /// "Team A" / "Team B" when the cleaned title is a fixture.
    var teams: (String, String)? { Crests.teams(ofCleanTitle: cleanTitle) }

    /// Both crest URLs for the fixture (either side may be nil);
    /// nil when the title is not a fixture at all.
    var crests: (URL?, URL?)? { Crests.crests(forTitle: channel.title) }

    /// Headline for hero and tiles: "Team A vs Team B" when both
    /// teams are known (no broadcaster clutter survives), else the
    /// cleaned title.
    var headline: String {
        if let teams { return "\(teams.0) vs \(teams.1)" }
        return cleanTitle
    }

    var isLive: Bool { LeagueClassifier.isLive(channel) }

    var leagueName: String {
        League(rawValue: channel.leagueRank)?.name ?? "Khác"
    }

    /// Group a sorted channel list into fixture entries, preserving
    /// the incoming order (first occurrence wins the slot). The
    /// identity itself lives in FixtureGrouping (Crests.swift),
    /// shared with the phone — this is a delegation, not a copy.
    static func group(_ channels: [Channel]) -> [TVFixtureEntry] {
        FixtureGrouping.group(channels).map { g in
            TVFixtureEntry(channel: g.members[0], sourceCount: g.members.count, id: g.id)
        }
    }
}

// MARK: - English-commentary channels

/// The English backup block the mirror added to the shared playlist
/// (2026-11-14): group-title "EN · BLV Anh", titles prefixed
/// "EN · ". These are 24/7 channels — no kickoff, no fixture — so
/// they get their own section and their own card, and are filtered
/// out of every fixture list and the featured rail.
enum TVEnglish {
    static let groupName = "EN · BLV Anh"

    static func isEnglish(_ ch: Channel) -> Bool { ch.group == groupName }

    /// Card name without the "EN · " prefix (the section header and
    /// the BLV ANH chip already carry that information).
    static func displayName(_ ch: Channel) -> String {
        let t = MatchTitle.clean(ch.title)
        if t.hasPrefix("EN · ") { return String(t.dropFirst("EN · ".count)) }
        if t.hasPrefix("EN ·") { return String(t.dropFirst("EN ·".count)) }
        return t
    }
}

// MARK: - Shared TV palette (the TV app's own teal/cyan identity)

/// Đá Banh TV's established palette — deep teal + cyan on near-black,
/// deliberately unlike both the phone app (near-black + green) and
/// the general TV app, so the three are never confused.
enum TVPalette {
    static let cyan = Color(red: 0.0, green: 0.898, blue: 1.0)
    static let tealFill = Color(red: 0.05, green: 0.36, blue: 0.30)
    static let liveRed = Color(red: 1.0, green: 0.27, blue: 0.23)
    static let amber = Color(red: 1.0, green: 0.78, blue: 0.35)
    static let heroMeta = Color(red: 0.75, green: 0.94, blue: 0.90)
}

/// The four-state status chip every fixture tile carries (owner,
/// 2026-11-13: live vs replay must never be a guess) — red
/// LIVE · minute / amber ⏰ kickoff (device-local) / grey ↺ PHÁT LẠI
/// / slate 📺 KÊNH. Same language as the phone, sized for TV.
struct TVStatusChip: View {
    let channel: Channel

    var body: some View {
        let now = Date()
        let bucket = LeagueClassifier.bucket(of: channel, now: now)
        if bucket == 0 {
            HStack(spacing: 7) {
                Circle()
                    .fill(TVPalette.liveRed)
                    .frame(width: 13, height: 13)
                Text("LIVE · \(TVKickoffFormat.liveMinute(of: channel.kickoff ?? now, now: now))'")
                    .font(.system(size: 19, weight: .heavy))
                    .foregroundStyle(TVPalette.liveRed)
            }
        } else if let kickoff = channel.kickoff, kickoff > now {
            Text("⏰ " + TVKickoffFormat.time.string(from: kickoff))
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(TVPalette.amber)
        } else if channel.kickoff != nil {
            Text("↺ PHÁT LẠI")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
        } else {
            Text("📺 KÊNH")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
        }
    }
}

/// Tile background shared by every rail card: the same glassy panel
/// as the hero, with the thick cyan focus ring the owner approved —
/// the focus state must read from the sofa, not just glow faintly.
func tvCardBackground(focused: Bool) -> some View {
    RoundedRectangle(cornerRadius: 22)
        .fill(LinearGradient(
            colors: [Color.white.opacity(0.13), Color.white.opacity(0.05)],
            startPoint: .topLeading, endPoint: .bottomTrailing))
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .strokeBorder(focused ? TVPalette.cyan : Color.white.opacity(0.16),
                              lineWidth: focused ? 4 : 1.5))
}

// MARK: - Card button (the .card cure, 2026-11-17)
//
// Every button in this app used to wear .buttonStyle(.card).
// That style paints the SYSTEM's own platter under the label
// — a pale plate at the system's size and offset — so every
// pill and card showed a ghost copy of itself peeking out
// from underneath (the owner's close-ups of 2026-11-17; the
// same disease JoeTV cured in its v2.0.8). The labels here
// already own their focus rendering (tvCardBackground's cyan
// ring, TVPillFace below), so the style layer must add
// NOTHING: this style returns the label untouched, and
// .focusEffectDisabled() kills the separate focus-effect
// layer with it. The app's drawn faces are the only layer.
struct TVCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

struct TVCardButton: ViewModifier {
    func body(content: Content) -> some View {
        content
            .buttonStyle(TVCardButtonStyle())
            .focusEffectDisabled()
    }
}

extension View {
    /// The app's only button construction — see TVCardButton.
    func tvCardButton() -> some View {
        modifier(TVCardButton())
    }
}

/// The pill face the league pills and the header buttons
/// share: capsule fill (selected teal / idle white 10%) plus
/// the app's own focus ring — an outset cyan stroke in the
/// same weight as the cards' ring — replacing the platter
/// the .card style used to lend them.
struct TVPillFace: View {
    let focused: Bool
    let selected: Bool

    var body: some View {
        Capsule()
            .fill(selected ? TVPalette.tealFill : Color.white.opacity(0.10))
            .overlay(
                Capsule()
                    .stroke(TVPalette.cyan, lineWidth: focused ? 4 : 0)
                    .padding(focused ? -4 : 0))
    }
}

// MARK: - Crest / logo pieces

/// Session image cache for crests and channel logos (v1.3.5,
/// tvOS 27 optimisation pass). The two image views below used to
/// be bare AsyncImage: it keeps no decoded-image memory cache, so
/// every hero swap — and the hero follows EVERY focus move — plus
/// every rail re-render re-fetched and re-decoded the same
/// TheSportsDB crests all session long, visible as placeholder
/// flicker on the hero art. tvOS 26/27 changed nothing in
/// AsyncImage to fix that, so the app now holds decoded images in
/// an NSCache and fetches through a session with a real URLCache
/// (32 MB memory / 128 MB disk): a crest is downloaded at most
/// once per launch, and usually once ever. Rendering is
/// unchanged — same placeholder while loading, same scaledToFit
/// image when loaded.
private enum TVImageCache {
    static let cache = NSCache<NSURL, UIImage>()
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 32 * 1024 * 1024,
                                   diskCapacity: 128 * 1024 * 1024)
        return URLSession(configuration: config)
    }()

    static func load(_ url: URL) async -> UIImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        guard let (data, _) = try? await session.data(from: url),
              let image = UIImage(data: data) else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}

/// One cached image with the house placeholder while it loads.
private struct TVCachedImage: View {
    let url: URL
    let placeholderSize: CGFloat
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                TVSoccerPlaceholder(size: placeholderSize)
            }
        }
        .task(id: url) {
            image = await TVImageCache.load(url)
        }
    }
}

struct TVCrestImage: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        Group {
            if let url {
                TVCachedImage(url: url, placeholderSize: size * 0.5)
            } else {
                TVSoccerPlaceholder(size: size * 0.5)
            }
        }
        .frame(width: size, height: size)
    }
}

struct TVSoccerPlaceholder: View {
    let size: CGFloat

    var body: some View {
        Image(systemName: "soccerball")
            .font(.system(size: size))
            .foregroundStyle(.white.opacity(0.35))
    }
}

/// Crest-vs-crest row for a fixture tile; falls back to the channel
/// logo when the title is not a known fixture.
struct TVCrestRow: View {
    let channel: Channel
    var crestSize: CGFloat = 62
    var logoHeight: CGFloat = 54

    var body: some View {
        let pair = Crests.crests(forTitle: channel.title)
        if let pair, pair.0 != nil || pair.1 != nil {
            HStack(spacing: 10) {
                TVCrestImage(url: pair.0, size: crestSize)
                if pair.0 != nil && pair.1 != nil {
                    Text("vs")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
                TVCrestImage(url: pair.1, size: crestSize)
                if (pair.0 == nil) != (pair.1 == nil) {
                    TVChannelLogo(channel: channel, height: 46)
                }
            }
        } else {
            TVChannelLogo(channel: channel, height: logoHeight)
        }
    }
}

struct TVChannelLogo: View {
    let channel: Channel
    let height: CGFloat

    var body: some View {
        Group {
            if let url = channel.logoURL {
                TVCachedImage(url: url, placeholderSize: height * 0.6)
            } else {
                TVSoccerPlaceholder(size: height * 0.6)
            }
        }
        .frame(height: height)
    }
}

// MARK: - Featured tile (the TV's featured rail)

/// Big face-off tile for the featured rail — the television
/// expression of the phone's featured card, NOT a scaled copy of
/// it: roughly twice the phone card in each dimension, crests at
/// 110pt with the team names under them, a LIVE · minute (or
/// device-local kickoff) badge, the league line, and the source
/// count. One tile per fixture, however many sources carry it.
struct TVFeaturedCard: View {
    @EnvironmentObject private var store: PlaylistStore
    let entry: TVFixtureEntry
    let focused: Bool

    var body: some View {
        let _ = store.crestsRevision
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Text(entry.leagueName.uppercased())
                    .font(.system(size: 21, weight: .bold))
                    .tracking(2)
                    .foregroundStyle(TVPalette.heroMeta)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if entry.sourceCount > 1 {
                    Text("\(entry.sourceCount) nguồn phát")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.white.opacity(0.14)))
                }
            }

            if let teams = entry.teams {
                HStack(alignment: .top, spacing: 10) {
                    teamBlock(name: teams.0, crest: entry.crests?.0 ?? nil)
                    Text("VS")
                        .font(.system(size: 24, weight: .heavy))
                        .foregroundStyle(.white.opacity(0.45))
                        .padding(.top, 40)
                    teamBlock(name: teams.1, crest: entry.crests?.1 ?? nil)
                }
            } else {
                HStack(spacing: 18) {
                    TVChannelLogo(channel: entry.channel, height: 84)
                    Text(entry.cleanTitle)
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 14) {
                if entry.isLive {
                    HStack(spacing: 8) {
                        Circle().fill(.white).frame(width: 11, height: 11)
                        if let kickoff = entry.channel.kickoff {
                            Text("ĐANG ĐÁ · \(TVKickoffFormat.liveMinute(of: kickoff))'")
                                .font(.system(size: 22, weight: .heavy))
                        } else {
                            Text("ĐANG ĐÁ")
                                .font(.system(size: 22, weight: .heavy))
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(TVPalette.liveRed))
                }
                if let kickoff = entry.channel.kickoff {
                    Text(TVKickoffFormat.timeDay.string(from: kickoff))
                        .font(.system(size: 22))
                        .foregroundStyle(.white.opacity(0.75))
                }
                Spacer(minLength: 0)
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 46))
                    .foregroundStyle(TVPalette.cyan)
            }
        }
        .padding(28)
        .frame(width: 640, height: 330, alignment: .leading)
        .background(tvCardBackground(focused: focused))
    }

    private func teamBlock(name: String, crest: URL?) -> some View {
        VStack(spacing: 10) {
            TVCrestImage(url: crest, size: 110)
            Text(name)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Match tile (standard rail card)

/// One fixture in a bucket rail: crest-vs-crest (or the channel
/// logo), the headline, the four-state status chip, and a meta line
/// with the device-local kickoff and the grouped source count.
/// Same 470×252 footprint the owner already approved on his TV —
/// the redesign changes what the tile MEANS (one fixture, not one
/// source), not the rail geometry his remote flow is tuned to.
struct TVMatchCard: View {
    @EnvironmentObject private var store: PlaylistStore
    let entry: TVFixtureEntry
    let focused: Bool

    private var channel: Channel { entry.channel }

    var body: some View {
        let _ = store.crestsRevision
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                TVCrestRow(channel: channel)
                Spacer()
                TVStatusChip(channel: channel)
            }
            Text(entry.headline)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(focused ? TVPalette.cyan : .white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            Text(meta)
                .font(.system(size: 20))
                .foregroundStyle(.white.opacity(0.62))
                .lineLimit(1)
        }
        .padding(22)
        .frame(width: 470, height: 252, alignment: .topLeading)
        .background(tvCardBackground(focused: focused))
    }

    private var meta: String {
        var parts: [String] = []
        if let kickoff = channel.kickoff {
            parts.append(TVKickoffFormat.timeDay.string(from: kickoff))
        }
        if !channel.group.isEmpty { parts.append(channel.group) }
        if entry.sourceCount > 1 { parts.append("\(entry.sourceCount) nguồn") }
        return parts.joined(separator: "  ·  ")
    }
}

// MARK: - English channel card

/// One English-commentary channel in the EN section. The mirror's
/// EN entries carry no tvg-logo, so the card is built around
/// typography, not artwork: the channel name large, a 24/7 · BLV ANH
/// chip (these channels are always on — there is no kickoff to
/// show), and the channel logo only when one exists. Playing one
/// hands the player just this channel; there is no fixture ladder
/// behind a 24/7 channel.
struct TVENChannelCard: View {
    let channel: Channel
    let focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                if channel.logoURL != nil {
                    TVChannelLogo(channel: channel, height: 58)
                } else {
                    Image(systemName: "tv")
                        .font(.system(size: 44))
                        .foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
                Text("24/7 · BLV ANH")
                    .font(.system(size: 19, weight: .heavy))
                    .foregroundStyle(TVPalette.cyan)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(TVPalette.tealFill))
            }
            Text(TVEnglish.displayName(channel))
                .font(.system(size: 31, weight: .bold))
                .foregroundStyle(focused ? TVPalette.cyan : .white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(TVPalette.cyan)
                Text("Kênh tiếng Anh · phát liên tục")
                    .font(.system(size: 20))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
            }
        }
        .padding(22)
        .frame(width: 470, height: 252, alignment: .topLeading)
        .background(tvCardBackground(focused: focused))
    }
}
