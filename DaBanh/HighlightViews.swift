import AVKit
import AVFoundation
import SwiftUI
import UIKit
import WebKit

/// The Highlight tab's surfaces (FIX-134, Đá Banh iOS 1.34):
/// the MU feed (inside MUHomeView), the Classic feed (inside
/// ContentView's leagueList) and ONE shared highlight player
/// page, themed per the current theme. Visual spec: the
/// approved demo (theme-mu/demo/demo-highlight.html +
/// DEMO-HIGHLIGHT-REPORT.md derivation mapping) over study
/// §2/§3 — MU surfaces derive from the MU board language,
/// Classic surfaces from Classic's OWN board language
/// (BoardPalette, capsule chips, MatchCard tiles), never a
/// recoloured MU card.
///
/// Interaction (owner ruling): ONE tap on a card presents the
/// player immediately on the top-ranked source; switching and
/// auto-advance on failure live INSIDE the player.

// MARK: - Shared feed helpers

/// Day grouping for the feeds: matches bucketed by their
/// local calendar day, newest day first, newest match first
/// inside the day (the store already sorts newest-first).
private func highlightDayGroups(_ matches: [HighlightMatch]) -> [(day: Date, matches: [HighlightMatch])] {
    var order: [Date] = []
    var byDay: [Date: [HighlightMatch]] = [:]
    let cal = Calendar.current
    for match in matches {
        let day = cal.startOfDay(for: match.matchDate)
        if byDay[day] == nil { order.append(day) }
        byDay[day, default: []].append(match)
    }
    return order.sorted(by: >).map { (day: $0, matches: byDay[$0] ?? []) }
}

/// "3:14" from a duration in seconds (the card badge + the
/// player source row). Nil duration → nil (never faked).
private func highlightDurationText(_ seconds: Int?) -> String? {
    guard let seconds, seconds > 0 else { return nil }
    return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
}

/// The card's source line (study §3.2): the progressive-fill
/// state in words — the count grows as later sources land.
private func highlightSourceLine(_ match: HighlightMatch) -> String {
    match.hasOfficialSource
        ? "\(match.sources.count) nguồn · có bản chính thức"
        : "\(match.sources.count) nguồn · bản sớm"
}

/// The competition eyebrow for one match (the UEFA group holds
/// three competitions; the card names the real one).
private func highlightCompetitionName(_ match: HighlightMatch) -> String {
    switch match.competition {
    case .premierLeague: return "PREMIER LEAGUE"
    case .laLiga: return "LA LIGA"
    case .championsLeague: return "CHAMPIONS LEAGUE"
    case .europaLeague: return "EUROPA LEAGUE"
    case .conferenceLeague: return "CONFERENCE LEAGUE"
    case .unknown: return ""
    }
}

// MARK: - MU feed

/// The Highlight tab under an MU-family theme (united AND MU
/// Wally — one layout; MUTokens already switches the palette
/// per theme, so Wally rides its own token derivation with no
/// third layout). Header language per the demo derivation:
/// the home heading block + the board's tab-chip component as
/// the competition switcher; cards are MUFixtureCard geometry.
struct MUHighlightView: View {
    @StateObject private var hlStore = HighlightStore()
    @State private var group: HighlightGroup = .premierLeague
    @State private var playing: HighlightMatch?

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                heading
                switcher
                feed
            }
        }
        .task { await hlStore.refresh() }
        .fullScreenCover(item: $playing) { match in
            HighlightPlayerView(match: match)
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("HIGHLIGHT")
                .font(MUFont.display(30))
                .muDisplayTracking(30)
                .foregroundStyle(MUTokens.cream)
            Text(muVietnameseDateLine())
                .font(MUFont.body(11))
                .foregroundStyle(MUTokens.secondary)
        }
        .padding(.horizontal, 16)
        .frame(height: 55)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The competition switcher: the board's tab-chip component
    /// reused verbatim (row 54, radius 12, min-height 44, body
    /// 12; selected = red fill + cream).
    private var switcher: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(HighlightGroup.allCases, id: \.title) { candidate in
                    let selected = group == candidate
                    Button {
                        group = candidate
                    } label: {
                        Text(candidate.title)
                            .font(MUFont.body(12, selected ? .semibold : .regular))
                            .foregroundStyle(selected ? MUTokens.cream : MUTokens.secondary)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 44)
                            .background(
                                MUPressedBackground(
                                    RoundedRectangle(cornerRadius: 12),
                                    selected ? MUTokens.red : MUTokens.card)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(selected ? MUTokens.red : MUTokens.border,
                                            lineWidth: 1)
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(MUPressButtonStyle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 5)
        }
        .frame(height: 54)
    }

    @ViewBuilder
    private var feed: some View {
        let matches = hlStore.matches(in: group)
        if !hlStore.hasLoaded {
            // Loading: the board's skeleton geometry (featured
            // + 2 standard), study §3.2.
            VStack(spacing: 12) {
                MUSkeletonCard(featured: true)
                MUSkeletonCard(featured: false)
                MUSkeletonCard(featured: false)
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
        } else if matches.isEmpty {
            VStack(spacing: 6) {
                Text("Chưa có highlight nào trong 7 ngày qua.")
                    .font(MUFont.body(12))
                    .foregroundStyle(MUTokens.secondary)
                Text(group.title)
                    .font(MUFont.body(10))
                    .foregroundStyle(MUTokens.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 196)
            .padding(.horizontal, 16)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(highlightDayGroups(matches).enumerated()), id: \.element.day) { groupIndex, dayGroup in
                    Text(muVietnameseDateLine(dayGroup.day).uppercased()
                         + " · \(KickoffFormat.day.string(from: dayGroup.day))")
                        .font(MUFont.body(10, .semibold))
                        .tracking(0.15 * 10)
                        .foregroundStyle(MUTokens.secondary)
                        .padding(.top, 4)
                    ForEach(Array(dayGroup.matches.enumerated()), id: \.element.id) { index, match in
                        Button {
                            playing = match
                        } label: {
                            // The featured card is the feed's
                            // first card ONLY (study §3: "the
                            // first (newest) card of the selected
                            // competition", exactly like the
                            // board's first box) — not one per
                            // day group. REVIEW-134 F2.
                            MUHighlightCard(match: match,
                                            featured: groupIndex == 0 && index == 0)
                        }
                        .buttonStyle(MUPressButtonStyle())
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }
}

/// One MU highlight card: MUFixtureCard geometry verbatim
/// (featured 358×196 / standard 358×142, radius 18, padding
/// 12/14, crests 54/36, score 64/44 via MUScoreText), the FT
/// score inside, "FULL TIME" as a quiet caption in the centre
/// pill slot, the play disc (40 / 48 featured, card fill, 1 pt
/// gold border, cream ▶) centred on the score's vertical axis
/// at the card's trailing third, the duration badge of the
/// top-ranked source bottom-trailing, and the source line in
/// the bottom row's left slot.
struct MUHighlightCard: View {
    @Environment(\.muIsPressed) private var isPressed
    let match: HighlightMatch
    let featured: Bool

    private var height: CGFloat { featured ? 196 : 142 }
    private var crestSize: CGFloat { featured ? 54 : 36 }
    private var scoreSize: CGFloat { featured ? 64 : 44 }
    private var nameSize: CGFloat { featured ? 12 : 11 }
    private var discSize: CGFloat { featured ? 48 : 40 }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18)
                .fill(isPressed ? MUTokens.pressedFill
                      : (featured ? MUTokens.featuredBase : MUTokens.card))
            VStack(spacing: 0) {
                topRow
                Spacer(minLength: 4)
                middleRow
                Spacer(minLength: 4)
                Rectangle()
                    .fill(featured ? MUTokens.featuredSeparator : MUTokens.border)
                    .frame(height: 1)
                    .padding(.bottom, featured ? 10 : 7)
                bottomRow
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            // The play disc, over the score axis at the trailing
            // third — clear of the centre score column (112).
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                playDisc
                Spacer(minLength: 0).frame(width: 34)
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(featured ? MUTokens.featuredBorder : MUTokens.border,
                        lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 18))
    }

    private var playDisc: some View {
        ZStack {
            Circle().fill(MUTokens.card)
            Circle().stroke(MUTokens.gold, lineWidth: 1)
            Image(systemName: "play.fill")
                .font(.system(size: discSize * 0.36, weight: .semibold))
                .foregroundStyle(MUTokens.cream)
                .offset(x: 1)
        }
        .frame(width: discSize, height: discSize)
    }

    private var topRow: some View {
        HStack(spacing: 8) {
            Text(highlightCompetitionName(match))
                .font(MUFont.body(10))
                .foregroundStyle(MUTokens.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text(KickoffFormat.day.string(from: match.matchDate))
                .font(MUFont.body(9))
                .tracking(0.08 * 9)
                .foregroundStyle(featured ? MUTokens.gold : MUTokens.secondary)
                .lineLimit(1)
        }
    }

    private var middleRow: some View {
        HStack(alignment: .center, spacing: 6) {
            teamBlock(name: match.home, crest: Crests.url(forTeam: match.home))
            centre.frame(width: 112)
            teamBlock(name: match.away, crest: Crests.url(forTeam: match.away))
        }
    }

    private func teamBlock(name: String, crest: URL?) -> some View {
        VStack(spacing: featured ? 7 : 4) {
            CrestImg(url: crest, size: crestSize)
            Text(name)
                .font(MUFont.body(nameSize, .medium))
                .foregroundStyle(MUTokens.scoreBright)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    /// The centre column: the FT score with the quiet
    /// "FULL TIME" caption in the LIVE pill's slot beneath it.
    private var centre: some View {
        VStack(spacing: 5) {
            MUScoreText(home: match.scoreHome, away: match.scoreAway, size: scoreSize)
            Text("FULL TIME")
                .font(MUFont.body(10))
                .tracking(0.05 * 10)
                .foregroundStyle(MUTokens.secondary)
                .lineLimit(1)
        }
    }

    private var bottomRow: some View {
        HStack(spacing: 8) {
            Text(highlightSourceLine(match))
                .font(MUFont.body(10))
                .foregroundStyle(MUTokens.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let duration = highlightDurationText(match.rankedSources.first?.durationSec) {
                Text(duration)
                    .font(MUFont.body(10, .semibold))
                    .foregroundStyle(MUTokens.cream)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.black.opacity(0.55))
                    )
            }
        }
    }
}

// MARK: - Classic feed

/// The Highlight tab under the Classic theme: Classic's OWN
/// board language — BoardPalette, capsule chips (selected
/// competition = tabActiveBG), classic MatchCard-style tiles
/// (tileBG / tileBorder, centred score in system 24 bold with
/// the palette dash), the play affordance in sky and the
/// source line in dimText (demo derivation mapping).
struct ClassicHighlightView: View {
    @StateObject private var hlStore = HighlightStore()
    @State private var group: HighlightGroup = .premierLeague
    @State private var playing: HighlightMatch?

    var body: some View {
        List {
            switcherRow
            feedRows
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .task { await hlStore.refresh() }
        .fullScreenCover(item: $playing) { match in
            HighlightPlayerView(match: match)
        }
    }

    private var switcherRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(HighlightGroup.allCases, id: \.title) { candidate in
                    let selected = group == candidate
                    Button {
                        group = candidate
                    } label: {
                        Text(candidate.title)
                            .font(.subheadline.weight(selected ? .bold : .regular))
                            .foregroundStyle(selected ? .white : .white.opacity(0.7))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                Capsule().fill(selected
                                               ? BoardPalette.tabActiveBG
                                               : Color.white.opacity(0.08))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
    }

    @ViewBuilder
    private var feedRows: some View {
        let matches = hlStore.matches(in: group)
        if !hlStore.hasLoaded {
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 14)
                    .fill(BoardPalette.tileBG)
                    .frame(height: 84)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            }
        } else if matches.isEmpty {
            VStack(spacing: 6) {
                Text("Chưa có highlight nào trong 7 ngày qua.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.6))
                Text(group.title)
                    .font(.caption)
                    .foregroundStyle(BoardPalette.dimText)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        } else {
            ForEach(highlightDayGroups(matches), id: \.day) { dayGroup in
                Section {
                    ForEach(dayGroup.matches) { match in
                        Button {
                            playing = match
                        } label: {
                            ClassicHighlightTile(match: match)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    }
                } header: {
                    Text(muVietnameseDateLine(dayGroup.day)
                         + " · \(KickoffFormat.day.string(from: dayGroup.day))")
                        .font(.caption.bold())
                        .tracking(1)
                        .foregroundStyle(BoardPalette.headText)
                }
            }
        }
    }
}

/// One Classic highlight tile: the classic MatchCard's tile
/// chrome (radius 14, white 6 % fill family → BoardPalette
/// tileBG/tileBorder per the demo mapping) with crest + name |
/// centred FT score (system 24 bold, dash between) | name +
/// crest, a sky play line and the dim source line under it.
struct ClassicHighlightTile: View {
    let match: HighlightMatch

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(highlightCompetitionName(match))
                    .font(.caption2.bold())
                    .tracking(1)
                    .foregroundStyle(BoardPalette.leagueText)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(KickoffFormat.day.string(from: match.matchDate))
                    .font(.caption2)
                    .foregroundStyle(BoardPalette.dimText)
            }
            HStack(alignment: .center, spacing: 6) {
                teamBlock(name: match.home, crest: Crests.url(forTeam: match.home))
                centre
                teamBlock(name: match.away, crest: Crests.url(forTeam: match.away))
            }
            Rectangle().fill(BoardPalette.divider).frame(height: 1)
            HStack(spacing: 8) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(BoardPalette.sky)
                Text("Xem highlight")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(BoardPalette.sky)
                Spacer(minLength: 0)
                Text(highlightSourceLine(match))
                    .font(.caption)
                    .foregroundStyle(BoardPalette.dimText)
                    .lineLimit(1)
                if let duration = highlightDurationText(match.rankedSources.first?.durationSec) {
                    Text(duration)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(BoardPalette.eventMinute)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.black.opacity(0.35))
                        )
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14).fill(BoardPalette.tileBG)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(BoardPalette.tileBorder, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }

    private func teamBlock(name: String, crest: URL?) -> some View {
        VStack(spacing: 5) {
            CrestImg(url: crest, size: 32)
            Text(name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(BoardPalette.teamText)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    /// The centred FT score: system 24 bold, the palette dash
    /// between the digits, "FULL TIME" quiet beneath.
    private var centre: some View {
        VStack(spacing: 3) {
            HStack(spacing: 4) {
                Text("\(match.scoreHome)")
                Text("–").foregroundStyle(BoardPalette.dash)
                Text("\(match.scoreAway)")
            }
            .font(.system(size: 24, weight: .bold))
            .foregroundStyle(.white)
            .lineLimit(1)
            Text("FULL TIME")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.05 * 9)
                .foregroundStyle(BoardPalette.dimText)
        }
        .frame(minWidth: 64)
    }
}

// MARK: - Highlight player page

/// The shared highlight player page (study §2): ONE surface,
/// the video layer swapped by source kind — AVPlayer for
/// ESPN MP4, the official YouTube IFrame embed in a WKWebView
/// for YouTube, a WKWebView page load for UEFA — with the
/// app's own source row beneath it (chips ≥ 44 pt, the playing
/// source marked, "Chính thức" on official sources). A failed
/// source auto-advances to the next (the live law, DB-11);
/// when every source fails, a plain note plus a "Mở YouTube"
/// external open (when a YouTube source exists) is the last
/// resort — never a dead end.
///
/// Orientation: under MU the page follows the DB-20 behaviour
/// — portrait page layout with the video block on top, and a
/// fullscreen toggle that locks landscape entering /
/// restores .all + portrait exiting; the landscape state is
/// the existing designed full-bleed layout, unchanged. Under
/// Classic the page keeps the classic player's convention
/// (landscape lock while the player is up).
struct HighlightPlayerView: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.dismiss) private var dismiss
    let match: HighlightMatch

    @State private var sourceIndex = 0
    /// Sources this page has already advanced past after a
    /// failure — a kind that reports twice never double-advances.
    @State private var failedIndices: Set<Int> = []
    @State private var allFailed = false
    /// MU fullscreen (DB-20 behaviour): the designed full-bleed
    /// landscape state, entered/exited by the toggle only.
    @State private var isFullscreen = false

    private var sources: [HighlightSource] { match.rankedSources }
    private var current: HighlightSource? {
        sources.indices.contains(sourceIndex) ? sources[sourceIndex] : nil
    }
    private var isMU: Bool { themeStore.isMU }

    var body: some View {
        ZStack {
            (isMU ? MUTokens.bg : BoardPalette.bg).ignoresSafeArea()
            if isMU && isFullscreen {
                landscapeBody
            } else {
                portraitBody
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            if let first = sources.first {
                DiagLog.log("highlight",
                            "play start: '\(match.home) vs \(match.away)' "
                            + "on \(first.kind.rawValue) '\(first.label)' "
                            + "(source 1/\(sources.count))")
            }
            if !isMU {
                // Classic keeps the classic player's convention.
                OrientationHelper.lock(.landscape, rotateTo: .landscapeRight)
            }
        }
        .onDisappear {
            if isMU {
                if isFullscreen {
                    isFullscreen = false
                    OrientationHelper.lock(.all, rotateTo: .portrait)
                }
            } else {
                OrientationHelper.lock(.all, rotateTo: .portrait)
            }
        }
    }

    // MARK: Layouts

    /// Portrait page: header row, the video block on top, then
    /// the title block and the source row (study §2 / demo).
    private var portraitBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(current?.label ?? "")
                        .font(isMU ? MUFont.body(17, .semibold) : .headline)
                        .foregroundStyle(isMU ? MUTokens.cream : BoardPalette.teamText)
                        .lineLimit(1)
                    Text(highlightCompetitionName(match))
                        .font(isMU ? MUFont.body(10) : .caption2)
                        .foregroundStyle(isMU ? MUTokens.gold : BoardPalette.leagueText)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                closeButton
            }
            .padding(.horizontal, 16)
            .frame(height: 56)

            videoBlock
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .background(Color.black)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    titleBlock
                    if allFailed {
                        allFailedNote
                    } else {
                        sourceRow
                    }
                }
                .padding(16)
            }
        }
    }

    /// The designed full-bleed landscape state: the video layer
    /// fills the screen; the close, the mini-score and the
    /// source chips ride over it exactly as the PlayerLandscape
    /// drawing lays them out. No layout is redesigned here.
    private var landscapeBody: some View {
        ZStack(alignment: .top) {
            videoBlock
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    miniScore
                    Spacer(minLength: 8)
                    // The fullscreen toggle rides here too, so
                    // the DB-20 rotation works both ways inside
                    // the landscape state (exit in place, not
                    // only via closing the player). REVIEW-134 F3.
                    fullscreenButton
                    closeButton
                }
                .padding(.horizontal, 59)
                .padding(.top, 12)
                .frame(height: 48)
                Spacer(minLength: 0)
                if allFailed {
                    allFailedNote
                        .padding(.horizontal, 59)
                        .padding(.bottom, 16)
                } else {
                    sourceRow
                        .padding(.horizontal, 59)
                        .padding(.bottom, 28)
                }
            }
        }
    }

    private var miniScore: some View {
        HStack(spacing: 7) {
            CrestImg(url: Crests.url(forTeam: match.home), size: 23)
            Text("\(match.scoreHome) – \(match.scoreAway)")
                .font(MUFont.body(11, .semibold))
                .foregroundStyle(MUTokens.cream)
            CrestImg(url: Crests.url(forTeam: match.away), size: 23)
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.55))
        )
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("FULL TIME")
                    .font(isMU ? MUFont.body(10, .bold) : .caption2.bold())
                    .tracking(0.05 * 10)
                    .foregroundStyle(isMU ? MUTokens.gold : BoardPalette.leagueText)
                Text(highlightCompetitionName(match))
                    .font(isMU ? MUFont.body(10, .semibold) : .caption2.bold())
                    .tracking(0.15 * 10)
                    .foregroundStyle(isMU ? MUTokens.gold : BoardPalette.leagueText)
            }
            Text("\(match.home) \(match.scoreHome) – \(match.scoreAway) \(match.away)")
                .font(isMU ? MUFont.display(32) : .title2.bold())
                .foregroundStyle(isMU ? MUTokens.cream : BoardPalette.teamText)
                .lineLimit(2)
            HStack(spacing: 10) {
                Text(muVietnameseDateLine(match.matchDate)
                     + " · \(KickoffFormat.day.string(from: match.matchDate))")
                    .font(isMU ? MUFont.body(11) : .caption)
                    .foregroundStyle(isMU ? MUTokens.secondary : BoardPalette.dimText)
                Spacer(minLength: 0)
                if isMU {
                    fullscreenButton
                }
            }
        }
    }

    /// The MU fullscreen toggle (DB-20 behaviour, verbatim):
    /// entering locks landscape (rotate to landscapeRight);
    /// exiting restores .all and rotates back to portrait.
    private var fullscreenButton: some View {
        Button {
            if isFullscreen {
                isFullscreen = false
                OrientationHelper.lock(.all, rotateTo: .portrait)
            } else {
                isFullscreen = true
                OrientationHelper.lock(.landscape, rotateTo: .landscapeRight)
            }
        } label: {
            Image(systemName: isFullscreen
                  ? "arrow.down.right.and.arrow.up.left"
                  : "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(MUTokens.cream)
                .frame(width: 44, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 14).fill(MUTokens.card)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(MUTokens.border, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(MUPressButtonStyle())
        .accessibilityLabel(isFullscreen ? "Thoát toàn màn hình" : "Toàn màn hình")
    }

    /// The design's close: 48×48, circular, gold 1 pt border,
    /// always top-right.
    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(isMU ? MUTokens.cream : BoardPalette.buttonText)
                .frame(width: 48, height: 48)
                .background(Circle().fill(Color.black.opacity(0.45)))
                .overlay(
                    Circle().stroke(isMU ? MUTokens.gold : BoardPalette.buttonBorder,
                                    lineWidth: 1)
                )
                .contentShape(Circle())
        }
        .modifier(HighlightCardButtonStyle(isMU: isMU))
        .accessibilityLabel("Đóng")
    }

    // MARK: Video layer + source row

    /// The video layer for the current source, rebuilt per
    /// source (the .id) so a switch or an advance always lands
    /// on a fresh layer.
    @ViewBuilder
    private var videoBlock: some View {
        if let source = current {
            switch source.kind {
            case .espnMP4:
                if let url = URL(string: source.ref) {
                    HighlightMP4View(url: url, onFail: { advance(from: sourceIndex, reason: "mp4") })
                        .id(sourceIndex)
                } else {
                    Color.clear.onAppear { advance(from: sourceIndex, reason: "mp4-bad-url") }
                }
            case .youtube:
                HighlightYouTubeView(videoID: source.ref,
                                     onFail: { advance(from: sourceIndex, reason: "youtube") })
                    .id(sourceIndex)
            case .uefaPage:
                if let url = URL(string: source.ref) {
                    HighlightWebPageView(url: url,
                                         onFail: { advance(from: sourceIndex, reason: "uefa-page") })
                        .id(sourceIndex)
                } else {
                    Color.clear.onAppear { advance(from: sourceIndex, reason: "uefa-bad-url") }
                }
            case .unknown:
                Color.clear.onAppear { advance(from: sourceIndex, reason: "unknown-kind") }
            }
        } else {
            Color.black
        }
    }

    /// The in-player source row: chips ≥ 44 pt high, the
    /// playing source marked (MU: selected fill + gold border;
    /// Classic: tabActiveBG), official sources tagged
    /// "Chính thức". A tap switches the layer at once.
    private var sourceRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(sources.enumerated()), id: \.offset) { index, source in
                    sourceChip(source, index: index)
                }
            }
        }
    }

    private func sourceChip(_ source: HighlightSource, index: Int) -> some View {
        let selected = index == sourceIndex
        return Button {
            guard index != sourceIndex else { return }
            failedIndices.remove(index)
            allFailed = false
            sourceIndex = index
            DiagLog.log("highlight",
                        "source switch: '\(match.home) vs \(match.away)' "
                        + "→ \(source.kind.rawValue) '\(source.label)' "
                        + "(source \(index + 1)/\(sources.count))")
        } label: {
            HStack(spacing: 6) {
                if selected {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9, weight: .bold))
                }
                Text(source.label.isEmpty ? source.kind.rawValue : source.label)
                    .font(isMU ? MUFont.body(11) : .caption)
                    .lineLimit(1)
                if let duration = highlightDurationText(source.durationSec) {
                    Text(duration)
                        .font(isMU ? MUFont.body(10) : .caption2)
                        .opacity(0.75)
                }
                if source.official {
                    Text("Chính thức")
                        .font(isMU ? MUFont.body(9, .bold) : .caption2.bold())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(isMU ? MUTokens.gold : BoardPalette.gold)
                        )
                        .foregroundStyle(Color.black)
                }
            }
            .foregroundStyle(chipForeground(selected: selected))
            .padding(.horizontal, 11)
            .frame(minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(chipFill(selected: selected))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(chipBorder(selected: selected), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .modifier(HighlightCardButtonStyle(isMU: isMU))
    }

    private func chipFill(selected: Bool) -> Color {
        if isMU { return selected ? MUTokens.selectedFill : MUTokens.card }
        return selected ? BoardPalette.tabActiveBG : BoardPalette.tabBG
    }

    private func chipBorder(selected: Bool) -> Color {
        if isMU { return selected ? MUTokens.gold : MUTokens.border }
        return selected ? BoardPalette.sky : BoardPalette.tabBorder
    }

    private func chipForeground(selected: Bool) -> Color {
        if isMU { return selected ? MUTokens.cream : MUTokens.secondary }
        return selected ? .white : BoardPalette.tabText
    }

    /// Every source failed: a plain note, plus the external
    /// YouTube open when a YouTube source exists (last resort).
    private var allFailedNote: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Không phát được highlight này từ các nguồn hiện có.")
                .font(isMU ? MUFont.body(12) : .subheadline)
                .foregroundStyle(isMU ? MUTokens.secondary : .white.opacity(0.65))
            if let youtube = sources.first(where: { $0.kind == .youtube }),
               let url = URL(string: "https://www.youtube.com/watch?v=\(youtube.ref)") {
                Button {
                    UIApplication.shared.open(url)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.up.forward.app")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Mở YouTube")
                            .font(isMU ? MUFont.body(13, .semibold) : .subheadline.weight(.semibold))
                    }
                    .foregroundStyle(isMU ? MUTokens.cream : .white)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(isMU ? MUTokens.red : BoardPalette.tabActiveBG)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 10))
                }
                .modifier(HighlightCardButtonStyle(isMU: isMU))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Auto-advance

    /// A source failed: log it and move to the next untried
    /// source; when none is left, the all-failed note takes
    /// over. Guarded by failedIndices so a kind that reports
    /// its failure twice (KVO + notification, delegate +
    /// message) advances exactly once.
    private func advance(from index: Int, reason: String) {
        guard index == sourceIndex, !failedIndices.contains(index) else { return }
        failedIndices.insert(index)
        guard let failed = sources.indices.contains(index) ? sources[index] : nil
        else { return }
        DiagLog.log("highlight",
                    "source fail (\(reason)): '\(match.home) vs \(match.away)' "
                    + "\(failed.kind.rawValue) '\(failed.label)' "
                    + "(source \(index + 1)/\(sources.count))")
        if let next = sources.indices.first(where: { $0 > index && !failedIndices.contains($0) })
            ?? sources.indices.first(where: { !failedIndices.contains($0) && $0 != index }) {
            sourceIndex = next
            let nextSource = sources[next]
            DiagLog.log("highlight",
                        "advance: → \(nextSource.kind.rawValue) '\(nextSource.label)' "
                        + "(source \(next + 1)/\(sources.count))")
        } else {
            allFailed = true
            DiagLog.log("highlight",
                        "all sources failed: '\(match.home) vs \(match.away)' "
                        + "(\(sources.count) source(s))")
        }
    }
}

/// Applies the themed button style for the player chrome
/// above: the MU press style under the MU family, the plain
/// style otherwise. A branch modifier, NOT a type-eraser:
/// each branch keeps its concrete style — the plain style
/// is a PrimitiveButtonStyle, which no ButtonStyle eraser
/// can wrap (CI run #89; FL-403: check the protocol FAMILY
/// before type-erasing a style).
private struct HighlightCardButtonStyle: ViewModifier {
    let isMU: Bool
    func body(content: Content) -> some View {
        if isMU {
            content.buttonStyle(MUPressButtonStyle())
        } else {
            content.buttonStyle(.plain)
        }
    }
}

// MARK: - Video layers

/// ESPN MP4 layer: AVPlayerViewController (its own transport
/// controls) over an AVPlayer that reports failure two ways —
/// the item's status flipping to .failed (KVO) and the
/// FailedToPlayToEndTime notification — both funnelled into
/// one guarded onFail in the coordinator (the LivePlayerSurface
/// precedent: plain representable, plain coordinator, closures
/// stored on it; WebKit/AVKit callbacks arrive on the main
/// thread).
struct HighlightMP4View: UIViewControllerRepresentable {
    let url: URL
    let onFail: () -> Void

    final class Coordinator {
        var onFail: () -> Void = {}
        private var reported = false
        private var statusObservation: NSKeyValueObservation?
        private var failObserver: NSObjectProtocol?

        func watch(_ item: AVPlayerItem) {
            statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                if item.status == .failed { self?.report() }
            }
            failObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime,
                object: item, queue: .main) { [weak self] _ in
                self?.report()
            }
        }

        func report() {
            guard !reported else { return }
            reported = true
            onFail()
        }

        func teardown() {
            statusObservation?.invalidate()
            statusObservation = nil
            if let failObserver {
                NotificationCenter.default.removeObserver(failObserver)
                self.failObserver = nil
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        controller.player = player
        context.coordinator.onFail = onFail
        context.coordinator.watch(item)
        player.play()
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: AVPlayerViewController,
                                          coordinator: Coordinator) {
        uiViewController.player?.pause()
        uiViewController.player = nil
        coordinator.teardown()
    }
}

/// YouTube layer: the official IFrame embed
/// (youtube-nocookie, playsinline, IFrame API enabled) in a
/// WKWebView. Failure surfaces three ways, all funnelled into
/// the coordinator's guarded onFail: the IFrame API's onError
/// (posted through the "hlYT" script message handler — error
/// codes incl. 101/150 embed-restriction and 100 removed),
/// the player's onStateChange reporting an unrecoverable
/// state is NOT treated as failure (a paused/ended video is
/// not a dead source), and WKNavigationDelegate failures.
struct HighlightYouTubeView: UIViewRepresentable {
    let videoID: String
    let onFail: () -> Void

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var onFail: () -> Void = {}
        private var reported = false

        func report() {
            guard !reported else { return }
            reported = true
            onFail()
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == "hlYT" else { return }
            if let body = message.body as? [String: Any],
               let event = body["event"] as? String, event == "error" {
                report()
            }
        }

        func webView(_ webView: WKWebView,
                     didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            report()
        }

        func webView(_ webView: WKWebView,
                     didFail navigation: WKNavigation!,
                     withError error: Error) {
            report()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let content = WKUserContentController()
        content.add(context.coordinator, name: "hlYT")
        config.userContentController = content
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.scrollView.isScrollEnabled = false
        webView.backgroundColor = .black
        webView.isOpaque = false
        context.coordinator.onFail = onFail
        webView.loadHTMLString(Self.embedHTML(videoID: videoID),
                               baseURL: URL(string: "https://www.youtube-nocookie.com"))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.stopLoading()
        uiView.navigationDelegate = nil
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "hlYT")
    }

    /// The embed page: the IFrame API creates the player with
    /// playsinline + autoplay; onError posts back to the app.
    private static func embedHTML(videoID: String) -> String {
        """
        <!DOCTYPE html>
        <html><head><meta name="viewport" content="width=device-width, initial-scale=1">
        <style>html,body{margin:0;padding:0;background:#000;height:100%}
        #player{position:absolute;top:0;left:0;width:100%;height:100%}</style></head>
        <body><div id="player"></div>
        <script src="https://www.youtube.com/iframe_api"></script>
        <script>
        var player;
        function onYouTubeIframeAPIReady(){
          player = new YT.Player('player', {
            videoId: '\(videoID)',
            playerVars: {playsinline: 1, autoplay: 1, rel: 0},
            events: {
              onError: function(e){
                if (window.webkit && window.webkit.messageHandlers.hlYT) {
                  window.webkit.messageHandlers.hlYT.postMessage({event: 'error', code: e.data});
                }
              }
            }
          });
        }
        </script></body></html>
        """
    }
}

/// UEFA page layer: the uefa.com video page in a WKWebView
/// (its own player inside). Only navigation failure is
/// observable from outside the page — that is the failure
/// signal (study §2).
struct HighlightWebPageView: UIViewRepresentable {
    let url: URL
    let onFail: () -> Void

    final class Coordinator: NSObject, WKNavigationDelegate {
        var onFail: () -> Void = {}
        private var reported = false

        func report() {
            guard !reported else { return }
            reported = true
            onFail()
        }

        func webView(_ webView: WKWebView,
                     didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            report()
        }

        func webView(_ webView: WKWebView,
                     didFail navigation: WKNavigation!,
                     withError error: Error) {
            report()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero)
        webView.navigationDelegate = context.coordinator
        webView.backgroundColor = .black
        context.coordinator.onFail = onFail
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.stopLoading()
        uiView.navigationDelegate = nil
    }
}
