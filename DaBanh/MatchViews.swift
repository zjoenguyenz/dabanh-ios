import SwiftUI

/// Accent green used across the UI (shared with ContentView).
let accentGreen = Color(red: 0.13, green: 0.77, blue: 0.37)

/// sRGB colour from a 0xRRGGBB prototype token.
func boardColor(_ hex: UInt32) -> Color {
    Color(red: Double((hex >> 16) & 0xFF) / 255,
          green: Double((hex >> 8) & 0xFF) / 255,
          blue: Double(hex & 0xFF) / 255)
}

/// The scoreboard prototype's palette (DABANH-SCOREBOARD-SPEC
/// §0 — the mock's exact hex, shared by the web render and the
/// Sony prototype port).
enum BoardPalette {
    static let bg = boardColor(0x0A1120)
    static let tileBG = boardColor(0x111D33)
    static let tileBorder = boardColor(0x22355A)
    static let sky = boardColor(0x38BDF8)
    static let minuteBG = boardColor(0xC22626)
    static let htBG = boardColor(0x8A6D1F)
    static let badgeIdleBG = boardColor(0x26395E)
    static let liveDot = boardColor(0xEF4444)
    static let teamText = boardColor(0xEEF4FC)
    static let dash = boardColor(0x54749F)
    static let leagueText = boardColor(0x7E93B5)
    static let eventText = boardColor(0xA9BCD9)
    static let eventMinute = boardColor(0xE8EEF7)
    static let cardYellow = boardColor(0xF5C518)
    static let cardRed = boardColor(0xE0342B)
    static let divider = boardColor(0x1D2C49)
    static let dimText = boardColor(0x63769A)
    static let headText = boardColor(0xCFE0F5)
    static let buttonBG = boardColor(0x131F38)
    static let buttonBorder = boardColor(0x26395E)
    static let buttonText = boardColor(0xB9C9E2)
    static let tabBG = boardColor(0x101B31)
    static let tabBorder = boardColor(0x1F3050)
    static let tabText = boardColor(0x9DB1CF)
    static let tabActiveBG = boardColor(0x0E4D78)
    static let amber = boardColor(0xFFB454)
    static let gold = boardColor(0xFFD76A)
    static let goldHead = boardColor(0xFFE9A8)
    static let goldLabel = boardColor(0xC9B269)
    static let goldTileBG = boardColor(0x161A2E)
    static let goldTileBorder = boardColor(0x4A441F)
    static let goldTabBG = boardColor(0x1D1A0E)
    static let goldTabActiveBG = boardColor(0x6B5518)
}

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

    /// The matched live state (1.21), attached by
    /// PlaylistStore.entries(for:) — nil until the state layer
    /// binds one, and nil forever for fixtures no source carries
    /// (those render the bounded computed clock, never a score).
    var state: MatchState? = nil
    /// The competition identity (S1 > S2 > S3, spec §3/§4),
    /// attached with the state.
    var competition: CompetitionID? = nil

    /// Title with the kickoff stamp and ⚽🟢🔴 markers stripped —
    /// the only title form the redesigned UI ever shows.
    var cleanTitle: String { MatchTitle.clean(channel.title) }

    /// "Team A" / "Team B" when the cleaned title is a fixture.
    var teams: (String, String)? { Crests.teams(ofCleanTitle: cleanTitle) }

    /// Both crest URLs for the fixture (either side may be nil when
    /// that team is not in the crest map); nil when not a fixture.
    var crests: (URL?, URL?)? { Crests.crests(forTitle: channel.title) }

    /// The effective bucket: the matched state wins over the
    /// wall-clock window (an FT fixture is not live).
    func bucket(now: Date = Date()) -> Int {
        LeagueClassifier.bucket(of: channel, now: now, state: state)
    }

    var isLive: Bool { bucket() == 0 }

    /// The board's badge text for a live fixture: the matched
    /// state's own minute/status, or the bounded computed clock
    /// when no source matched (never a fabricated score).
    var liveBadgeText: String? {
        if let state { return state.badgeText }
        guard isLive, let kickoff = channel.kickoff else { return nil }
        return BoundedClock.text(kickoff: kickoff)
    }

    /// True when the live badge should wear the half-time amber:
    /// a matched HT state, or the computed clock's HT estimate.
    var isHalfTimeDisplay: Bool {
        if let state { return state.status == .halfTime }
        guard let kickoff = channel.kickoff else { return false }
        return isLive && BoundedClock.isHalfTimeEstimate(kickoff: kickoff)
    }

    /// The tile's competition line: the identified competition
    /// when there is one, else the league tab's name.
    var competitionLabel: String {
        competition?.label ?? leagueName.uppercased()
    }

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
        if entry.isLive {
            // A live featured fixture IS the big-score board
            // (spec §2.1/§1.5), at rail width.
            LiveBoardView(entry: entry)
                .frame(width: 300)
        } else {
            featuredBody
        }
    }

    private var featuredBody: some View {
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
        if entry.isLive {
            // Live fixtures render as the big-score board
            // (spec §1.5); non-live fixtures keep the compact
            // card below, byte-identical to before.
            LiveBoardView(entry: entry)
        } else {
            compactBody
        }
    }

    private var compactBody: some View {
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

// MARK: - Big-score board (1.21, spec §0/§1.5)

/// The live board: the prototype's tile at full card width —
/// competition label + minute/status badge on top, crest + name |
/// BIG centred score | name + crest, then the events block
/// (scorers with minutes, card chips with minutes) under a
/// divider. Sizes scale from the tile's own width off the
/// prototype's 606-pt tile (score 69, team 24, league 19, badge
/// 25, events 19, crest Ø44) — the board is never shrunk below
/// the mock's proportions; on portrait iPhone the boards are
/// full-width rows. A fixture with no matched state renders the
/// same shape with the bounded computed clock in the badge and
/// NO score and NO event lines — nothing is ever fabricated.
/// The C1 gold variant recolours the tile per §0.
struct LiveBoardView: View {
    let entry: FixtureEntry

    private var isGold: Bool { entry.competition?.isGoldCup == true }
    private var hasEvents: Bool {
        guard let state = entry.state else { return false }
        return !state.goals.isEmpty || !state.cards.isEmpty
    }

    var body: some View {
        GeometryReader { geo in
            board(scale: geo.size.width / 606)
        }
        .aspectRatio(hasEvents ? 1.72 : 2.45, contentMode: .fit)
        .contentShape(RoundedRectangle(cornerRadius: 16))
    }

    private func board(scale s: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10 * s) {
            HStack(alignment: .center, spacing: 8) {
                Text(entry.competitionLabel)
                    .font(.system(size: max(10, 19 * s), weight: .bold))
                    .tracking(1)
                    .foregroundStyle(isGold ? BoardPalette.goldLabel : BoardPalette.leagueText)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if entry.sourceCount > 1 {
                    Text("\(entry.sourceCount) nguồn")
                        .font(.system(size: max(9, 15 * s), weight: .medium))
                        .foregroundStyle(BoardPalette.dimText)
                }
                badge(scale: s)
            }

            if let teams = entry.teams {
                scoreRow(teams, scale: s)
            } else {
                Text(entry.cleanTitle)
                    .font(.system(size: max(12, 24 * s), weight: .semibold))
                    .foregroundStyle(BoardPalette.teamText)
                    .lineLimit(2)
            }

            if hasEvents, let state = entry.state {
                Rectangle()
                    .fill(BoardPalette.divider)
                    .frame(height: 1)
                eventsBlock(state, scale: s)
            }
        }
        .padding(.horizontal, 20 * s)
        .padding(.vertical, 14 * s)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(isGold ? BoardPalette.goldTileBG : BoardPalette.tileBG)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(isGold ? BoardPalette.goldTileBorder : BoardPalette.tileBorder,
                        lineWidth: 1.5)
        )
    }

    /// Minute/status badge: red for live play, amber for the
    /// half-time state, idle slate for FT/HOÃN.
    private func badge(scale s: CGFloat) -> some View {
        Group {
            if let text = entry.liveBadgeText {
                HStack(spacing: 5 * s) {
                    if entry.state?.status.isLiveish == true || (entry.state == nil && entry.isLive) {
                        Circle()
                            .fill(BoardPalette.liveDot)
                            .frame(width: 8 * s, height: 8 * s)
                    }
                    Text(text)
                        .font(.system(size: max(10, 25 * s), weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                .padding(.horizontal, 11 * s)
                .padding(.vertical, 3 * s)
                .background(
                    RoundedRectangle(cornerRadius: 8 * s)
                        .fill(badgeColor)
                )
            }
        }
    }

    private var badgeColor: Color {
        if let state = entry.state {
            switch state.status {
            case .halfTime: return BoardPalette.htBG
            case .live: return BoardPalette.minuteBG
            default: return BoardPalette.badgeIdleBG
            }
        }
        return entry.isHalfTimeDisplay ? BoardPalette.htBG : BoardPalette.minuteBG
    }

    private func scoreRow(_ teams: (String, String), scale s: CGFloat) -> some View {
        HStack(alignment: .center, spacing: 6 * s) {
            teamSide(name: teams.0, crest: entry.crests?.0 ?? nil, scale: s)
            centre(scale: s)
            teamSide(name: teams.1, crest: entry.crests?.1 ?? nil, scale: s)
        }
    }

    private func teamSide(name: String, crest: URL?, scale s: CGFloat) -> some View {
        VStack(spacing: 5 * s) {
            CrestImg(url: crest, size: max(24, 44 * s))
            Text(name)
                .font(.system(size: max(11, 24 * s), weight: .semibold))
                .foregroundStyle(BoardPalette.teamText)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    /// The big centred score — or "VS" when no source has given
    /// this fixture a score (never a fabricated digit).
    private func centre(scale s: CGFloat) -> some View {
        Group {
            if let state = entry.state, let home = state.scoreHome, let away = state.scoreAway {
                HStack(spacing: 4 * s) {
                    Text("\(home)")
                        .foregroundStyle(.white)
                    Text("–")
                        .foregroundStyle(BoardPalette.dash)
                    Text("\(away)")
                        .foregroundStyle(.white)
                }
                .font(.system(size: max(24, 69 * s), weight: .bold))
                .lineLimit(1)
            } else {
                Text("VS")
                    .font(.system(size: max(16, 34 * s), weight: .bold))
                    .foregroundStyle(BoardPalette.dash)
            }
        }
        .frame(minWidth: 70 * s)
    }

    /// Scorers + cards under the divider: home events left, away
    /// events right-aligned, minutes bright (prototype anatomy).
    private func eventsBlock(_ state: MatchState, scale s: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 10 * s) {
            VStack(alignment: .leading, spacing: 3 * s) {
                ForEach(Array(eventLines(state, home: true).enumerated()), id: \.offset) { _, line in
                    line
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 3 * s) {
                ForEach(Array(eventLines(state, home: false).enumerated()), id: \.offset) { _, line in
                    line
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func eventLines(_ state: MatchState, home: Bool) -> [AnyView] {
        var lines: [AnyView] = []
        for goal in state.goals where goal.isHome == home {
            lines.append(AnyView(
                HStack(spacing: 5) {
                    Text(goal.minuteText)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(BoardPalette.eventMinute)
                    Text(goal.scorer + (goal.isPenalty ? " (pen)" : goal.isOwnGoal ? " (OG)" : ""))
                        .font(.system(size: 12))
                        .foregroundStyle(BoardPalette.eventText)
                        .lineLimit(1)
                }
            ))
        }
        for card in state.cards where card.isHome == home {
            lines.append(AnyView(
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(card.isRed ? BoardPalette.cardRed : BoardPalette.cardYellow)
                        .frame(width: 8, height: 11)
                    Text(card.player)
                        .font(.system(size: 12))
                        .foregroundStyle(BoardPalette.eventText)
                        .lineLimit(1)
                    Text(card.minuteText)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(BoardPalette.eventMinute)
                }
            ))
        }
        if lines.count > 3 {
            let extra = lines.count - 3
            lines = Array(lines.prefix(3))
            lines.append(AnyView(
                Text("+\(extra)")
                    .font(.system(size: 11))
                    .foregroundStyle(BoardPalette.dimText)
            ))
        }
        return lines
    }
}

/// The link board's header (spec §2.4): the fixture's cluster in
/// the tile idiom — competition line, big score with the badge,
/// and up to two event lines (goals, then card counts). With no
/// matched state it shows the kickoff instead; the board never
/// waits for state.
struct BoardHeaderView: View {
    let entry: FixtureEntry

    var body: some View {
        VStack(spacing: 8) {
            Text(entry.competitionLabel)
                .font(.caption.bold())
                .tracking(1)
                .foregroundStyle(entry.competition?.isGoldCup == true
                                 ? BoardPalette.goldLabel : BoardPalette.leagueText)
                .lineLimit(1)
            if let teams = entry.teams {
                Text("\(teams.0)  vs  \(teams.1)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(BoardPalette.teamText)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            } else {
                Text(entry.cleanTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(BoardPalette.teamText)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            centreLine
            if let state = entry.state {
                if !state.goals.isEmpty {
                    Text(state.goals.map { "\($0.minuteText) \($0.scorer)" }
                        .joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(BoardPalette.eventText)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
                if !state.cards.isEmpty {
                    HStack(spacing: 6) {
                        cardCountChip(red: false, text: "\(state.homeYellow) – \(state.awayYellow)")
                        cardCountChip(red: true, text: "\(state.homeRed) – \(state.awayRed)")
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(entry.competition?.isGoldCup == true
                      ? BoardPalette.goldTileBG : BoardPalette.tileBG)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(entry.competition?.isGoldCup == true
                        ? BoardPalette.goldTileBorder : BoardPalette.tileBorder,
                        lineWidth: 1)
        )
    }

    private func cardCountChip(red: Bool, text: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(red ? BoardPalette.cardRed : BoardPalette.cardYellow)
                .frame(width: 9, height: 12)
            Text(text)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(BoardPalette.eventMinute)
        }
    }

    private var centreLine: some View {
        Group {
            if let state = entry.state, let score = state.scoreText {
                HStack(spacing: 10) {
                    Text(score)
                        .font(.system(size: 40, weight: .bold))
                        .foregroundStyle(.white)
                    if let badge = state.badgeText {
                        Text(badge)
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(state.status == .halfTime
                                          ? BoardPalette.htBG
                                          : state.status == .live
                                            ? BoardPalette.minuteBG
                                            : BoardPalette.badgeIdleBG)
                            )
                    }
                }
            } else if let kickoff = entry.channel.kickoff {
                VStack(spacing: 2) {
                    if entry.isLive, let badge = entry.liveBadgeText {
                        Text(badge)
                            .font(.title3.bold())
                            .foregroundStyle(BoardPalette.liveDot)
                    }
                    Text(KickoffFormat.full.string(from: kickoff))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(BoardPalette.sky)
                }
            }
        }
    }
}

/// The fixture's link board (spec §2): the cluster header, the
/// Vietnamese links on top (rows = the fixture's grouped mirror
/// channels, ladder order, representative first and highlighted;
/// the label is the cleaned title VERBATIM — its trailing
/// "(Name)" is the commentator the owner chooses by), then the
/// English section with ONLY this fixture's matched Nuvio events
/// (Addendum-2 belonging; omitted entirely when none matched —
/// never faked, and 24/7 channels are never fixture links).
/// A row tap plays that row; the caller rotates the ladder /
/// resolves the meta.
struct MatchBoardView: View {
    @EnvironmentObject private var store: PlaylistStore
    @Environment(\.dismiss) private var dismiss
    let entry: FixtureEntry
    let enMetas: [NuvioMeta]
    let onPlayVN: (Channel) -> Void
    let onPlayEN: (NuvioMeta) -> Void

    /// The entry re-read with the freshest state: the sheet may
    /// sit open across a poll.
    private var liveEntry: FixtureEntry {
        var entry = entry
        entry.state = store.state(for: entry.channel)
        entry.competition = LeagueClassifier.competition(
            for: entry.channel, state: entry.state)
        return entry
    }

    var body: some View {
        ZStack {
            BoardPalette.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Spacer()
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(BoardPalette.buttonText)
                                .frame(width: 32, height: 32)
                                .background(Circle().fill(BoardPalette.buttonBG))
                        }
                        .accessibilityLabel("Đóng")
                    }
                    BoardHeaderView(entry: liveEntry)

                    sectionTitle("LINK TIẾNG VIỆT")
                    let ladder = store.sources(for: entry.channel)
                    VStack(spacing: 8) {
                        ForEach(Array(ladder.enumerated()), id: \.element.id) { index, channel in
                            Button {
                                onPlayVN(channel)
                            } label: {
                                boardRow(
                                    title: MatchTitle.clean(channel.title),
                                    highlighted: index == 0)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if !enMetas.isEmpty {
                        sectionTitle("LINK TIẾNG ANH · BLV ANH")
                        VStack(spacing: 8) {
                            ForEach(enMetas) { meta in
                                Button {
                                    onPlayEN(meta)
                                } label: {
                                    boardRow(
                                        title: meta.competitionString ?? meta.channelHint ?? meta.displayName,
                                        subtitle: meta.competitionString != nil ? meta.displayName : nil,
                                        highlighted: false)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
        .preferredColorScheme(.dark)
        .task {
            // The opened board is first in line for the FotMob
            // incidents of its fixture (spec §1.2).
            await store.liveStates.ensureDetails(for: entry.channel)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.caption.bold())
            .tracking(1)
            .foregroundStyle(BoardPalette.headText)
    }

    private func boardRow(title: String, subtitle: String? = nil,
                          highlighted: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "play.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(highlighted ? BoardPalette.sky : BoardPalette.dimText)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(highlighted ? .semibold : .regular))
                    .foregroundStyle(BoardPalette.teamText)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(BoardPalette.dimText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if highlighted {
                Text("MẶC ĐỊNH")
                    .font(.caption2.bold())
                    .foregroundStyle(BoardPalette.sky)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(BoardPalette.tabBG)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(highlighted ? BoardPalette.sky : BoardPalette.tabBorder,
                        lineWidth: highlighted ? 1.5 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}
