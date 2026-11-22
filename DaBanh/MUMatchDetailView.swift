import SwiftUI

/// The Manchester United match detail (theme-mu): the
/// approved design's page — title bar, the score block over
/// stadium artwork, and the fixed bottom CTA. Source
/// selection follows the owner's 2026-11-22 01:50 ruling
/// (FIX-MU-5, item B): ONE small button under the hero
/// opens the source list as a sheet — the drawing's list
/// itself (Vietnamese group above English, rows as drawn)
/// lives in that sheet, not on the page.
///
/// Behaviour follows leader decision D-6 (the 1.30 one-tap
/// law outranks the mock's two-step): tapping a source row
/// SELECTS it and PLAYS it immediately, through the exact
/// callbacks the classic board uses. The CTA plays the
/// current selection — by default the first available
/// Vietnamese source, else the first English one. A source
/// the app has itself proven dead (ResolveHub's proven-dead
/// set, or the pre-warm store's dead verdict) renders in the
/// design's unavailable treatment — dimmed, ✕, note — and is
/// NEVER filtered out of its group.
struct MUMatchDetailView: View {
    @EnvironmentObject private var store: PlaylistStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.dismiss) private var dismiss
    let entry: FixtureEntry
    let enMetas: [NuvioMeta]
    let onPlayVN: (Channel) -> Void
    let onPlayEN: (NuvioMeta) -> Void
    let onOpenThemePicker: () -> Void

    /// The artwork for the hero, refreshed at appear.
    @State private var artURL: URL? = MUWallpapers.heroImage()

    /// One selectable source row's identity.
    private enum SourceID: Equatable {
        case vn(String)   // channel URL
        case en(String)   // meta id
    }
    @State private var selected: SourceID?
    /// FIX-MU-5 (item B): the source list lives behind the
    /// one small button now (owner ruling 2026-11-22 01:50
    /// CST) — this presents it as a sheet.
    @State private var showSourceSheet = false

    private var ladder: [Channel] { store.sources(for: entry.channel) }

    /// The entry re-read with the freshest state.
    private var liveEntry: FixtureEntry {
        var entry = entry
        entry.state = store.state(for: entry.channel)
        entry.competition = LeagueClassifier.competition(
            for: entry.channel, state: entry.state)
        return entry
    }

    private func isUnavailable(_ channel: Channel) -> Bool {
        ResolveHub.shared.isProvenDead(channel.url)
            || SourcePrewarmStore.shared.isDead(channel.url)
    }

    /// The default selection (D-6, exact order): the first
    /// available VN source, else the first EN source, else —
    /// only when no EN source exists at all — the first VN
    /// source. (FIX-MU-1, F-3: a proven-dead VN source must
    /// not outrank a playable EN one — VN failover cannot
    /// cross into the Nuvio EN ladder.)
    private var defaultSelection: SourceID? {
        // FIX-MU-5 (item A, Phát lại): the preferred
        // commentary language's group is tried FIRST for the
        // default selection only — the groups' DISPLAY order
        // (VN above EN) never changes, and the D-6 order
        // within each language is untouched.
        if MUPlaybackPrefs.lang == "en" {
            if let first = enMetas.first { return .en(first.id) }
            if let first = ladder.first(where: { !isUnavailable($0) }) {
                return .vn(first.url)
            }
            if let first = ladder.first { return .vn(first.url) }
            return nil
        }
        if let first = ladder.first(where: { !isUnavailable($0) }) {
            return .vn(first.url)
        }
        if let first = enMetas.first { return .en(first.id) }
        if let first = ladder.first { return .vn(first.url) }
        return nil
    }

    /// The live selection: the viewer's pick while it still
    /// names a listed source, else the D-6 default (the
    /// ladder can change under an open detail on a refresh).
    private var effectiveSelection: SourceID? {
        if let selected {
            switch selected {
            case .vn(let url):
                if ladder.contains(where: { $0.url == url }) { return selected }
            case .en(let id):
                if enMetas.contains(where: { $0.id == id }) { return selected }
            }
        }
        return defaultSelection
    }

    private var totalSources: Int { ladder.count + enMetas.count }

    var body: some View {
        ZStack {
            MUTokens.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                titleBar
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        hero
                        eventsSection
                        sourceButton
                    }
                }
                footer
            }
        }
        .sheet(isPresented: $showSourceSheet) {
            sourceSheet
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(24)
        }
        .preferredColorScheme(.dark)
        // FIX-MU-5 (item A): a Hình nền pick in Settings
        // re-reads the hero the moment it lands.
        .onChange(of: themeStore.wallpaperChoice) { _, _ in
            artURL = MUWallpapers.heroImage()
        }
        .task {
            if await MUWallpapers.refreshRemote() {
                artURL = MUWallpapers.heroImage()
            }
            // The same background duties the classic board
            // performs (MatchBoardView.task): deep-warm this
            // fixture's ladder, and put the fixture first in
            // line for its FotMob incidents.
            await MainActor.run {
                SourcePrewarmStore.shared.warm(ladder: ladder)
            }
            await store.liveStates.ensureDetails(for: entry.channel)
        }
        .onAppear {
            // The board-open anchor of the tap→play timeline —
            // the same DiagLog line the classic board writes.
            DiagLog.log("player",
                        "board opened: '\(MatchTitle.clean(entry.channel.title))' "
                        + "(\(ladder.count) sources)")
        }
    }

    // MARK: Title bar (56)

    private var titleBar: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(MUTokens.cream)
                    .frame(width: 44, height: 44)
                    .background(
                        MUPressedBackground(RoundedRectangle(cornerRadius: 14), MUTokens.card)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(MUTokens.border, lineWidth: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(MUPressButtonStyle())
            .accessibilityLabel("Quay lại")

            Text("Chi tiết trận đấu")
                .font(MUFont.body(16, .semibold))
                .foregroundStyle(MUTokens.cream)
                .lineLimit(1)

            Spacer(minLength: 8)

            Button {
                onOpenThemePicker()
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 15))
                    .foregroundStyle(MUTokens.cream)
                    .frame(width: 44, height: 44)
                    .background(
                        MUPressedBackground(RoundedRectangle(cornerRadius: 14), MUTokens.card)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(MUTokens.border, lineWidth: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(MUPressButtonStyle())
            .accessibilityLabel("Giao diện")
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
    }

    // MARK: Hero (208)

    private var hero: some View {
        let entry = liveEntry
        // FIX-MU-3 (finding 5): the hero content is
        // TOP-anchored in the 208 block (spec: padding top
        // 16) and the team/score row carries its fixed 124
        // height — the ZStack no longer centre-anchors the
        // score block below the drawing's position.
        return ZStack(alignment: .top) {
            heroBackground
            VStack(spacing: 10) {
                Text(entry.competitionLabel)
                    .font(MUFont.body(10, .semibold))
                    .tracking(0.15 * 10)
                    .foregroundStyle(MUTokens.gold)
                    .lineLimit(1)
                if let teams = entry.teams {
                    HStack(alignment: .top, spacing: 6) {
                        heroTeam(name: teams.0, crest: entry.crests?.0 ?? nil)
                        heroCentre(entry)
                            .frame(width: 112)
                        heroTeam(name: teams.1, crest: entry.crests?.1 ?? nil)
                    }
                    .frame(height: 124)
                } else {
                    Text(entry.cleanTitle)
                        .font(MUFont.body(15, .semibold))
                        .foregroundStyle(MUTokens.cream)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    heroCentre(entry)
                }
                // The design's venue line renders ONLY when
                // real venue data exists; no source in this
                // app carries a venue, so the line is omitted
                // rather than fabricated.
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
        }
        .frame(height: 208)
    }

    /// Stadium artwork under a dark fade; the fallback is the
    /// featured base + gradient (the A-1 rule).
    private var heroBackground: some View {
        ZStack {
            MUTokens.featuredBase
            if let artURL {
                // FIX-131 (DB-14/FL-396): same inert pattern as
                // the board backdrop — the image sits in the
                // background of a clear layer sized by this
                // ZStack, so its intrinsic size cannot inflate
                // the hero.
                Color.clear
                    .background {
                        AsyncImage(url: artURL) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().scaledToFill()
                            default:
                                Color.clear
                            }
                        }
                    }
            }
            LinearGradient(
                colors: [MUTokens.bg.opacity(0.25), MUTokens.bg.opacity(0.88)],
                startPoint: .top, endPoint: .bottom)
        }
        .clipped()
    }

    private func heroTeam(name: String, crest: URL?) -> some View {
        VStack(spacing: 7) {
            CrestImg(url: crest, size: 64)
            Text(name)
                .font(MUFont.body(13, .medium))
                .foregroundStyle(MUTokens.cream)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private func heroCentre(_ entry: FixtureEntry) -> some View {
        VStack(spacing: 6) {
            if let state = entry.state, let home = state.scoreHome, let away = state.scoreAway {
                // The design's colon composition at 76
                // (FIX-MU-3, finding 2).
                MUScoreText(home: home, away: away, size: 76)
            } else {
                Text(heroScoreText(entry))
                    .font(MUFont.display(76))
                    .muDisplayTracking(76)
                    .foregroundStyle(MUTokens.scoreBright)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
            if let pill = heroPillText(entry) {
                HStack(spacing: 5) {
                    Circle().fill(MUTokens.cream).frame(width: 4, height: 4)
                    Text(pill)
                        .font(MUFont.body(10, .bold))
                        .tracking(0.05 * 10)
                        .lineLimit(1)
                }
                .foregroundStyle(MUTokens.cream)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(MUTokens.red))
            } else if let kickoff = entry.channel.kickoff, kickoff > Date() {
                Text(KickoffFormat.day.string(from: kickoff))
                    .font(MUFont.body(11))
                    .foregroundStyle(MUTokens.secondary)
            } else if let state = entry.state, state.status == .fullTime {
                Text("FT")
                    .font(MUFont.body(11, .semibold))
                    .foregroundStyle(MUTokens.secondary)
            }
        }
    }

    private func heroScoreText(_ entry: FixtureEntry) -> String {
        if let state = entry.state, let home = state.scoreHome, let away = state.scoreAway {
            return "\(home):\(away)"
        }
        if entry.isLive { return "VS" }
        if let kickoff = entry.channel.kickoff, kickoff > Date() {
            return KickoffFormat.time.string(from: kickoff)
        }
        return "VS"
    }

    private func heroPillText(_ entry: FixtureEntry) -> String? {
        if let state = entry.state {
            switch state.status {
            case .live:
                if let minute = state.minuteText { return "LIVE · \(minute)" }
                return "LIVE"
            case .halfTime:
                return "NGHỈ GIỮA HIỆP"
            default:
                return nil
            }
        }
        if entry.isLive, let badge = entry.liveBadgeText {
            return "LIVE · \(badge)"
        }
        return nil
    }

    // MARK: Events (FIX-133, item G — theme-mu/DETAIL-EVENTS-SPEC.md)

    /// The match-events section (spec §2): the half-time
    /// score line and the two-column goals/cards block,
    /// inserted between the hero and the source button
    /// inside the existing ScrollView. Display only — the
    /// data already arrives on this page (`liveEntry.state`
    /// carries htHome/htAway + goals + cards, and the view's
    /// .task already fires ensureDetails). The section is
    /// ABSENT ENTIRELY when there is nothing to show (no
    /// state, or a state with neither a half-time score nor
    /// any event) — no divider, no placeholder line.
    @ViewBuilder
    private var eventsSection: some View {
        if let state = liveEntry.state {
            let hasHT = state.htHome != nil && state.htAway != nil
            let hasEvents = !state.goals.isEmpty || !state.cards.isEmpty
            if hasHT || hasEvents {
                VStack(alignment: .leading, spacing: 0) {
                    Rectangle()
                        .fill(MUTokens.border)
                        .frame(height: 1)
                    if hasHT, let htHome = state.htHome, let htAway = state.htAway {
                        HStack(spacing: 6) {
                            Text("HIỆP 1")
                                .font(MUFont.body(10, .semibold))
                                .tracking(0.15 * 10)
                                .foregroundStyle(MUTokens.secondary)
                            Text("\(htHome) – \(htAway)")
                                .font(MUFont.body(11, .semibold))
                                .foregroundStyle(MUTokens.cream)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 8)
                    }
                    if hasEvents {
                        eventsColumns(state)
                            // Spec §2.3: 10 pt under the HT
                            // line when both parts show. With
                            // events alone the block takes the
                            // same 8 pt under-divider rhythm
                            // the HT line uses (the only
                            // under-divider spacing the spec
                            // defines).
                            .padding(.top, hasHT ? 10 : 8)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
        }
    }

    /// The two event columns (spec §2.4): the hero's own
    /// geometry — 1fr · 112 · 1fr at spacing 6 — so each
    /// team's events sit directly under its crest and name.
    /// Home left-aligned, away right-aligned; within a
    /// column, goals first, then cards, each in the source
    /// array's own (chronological) order. No row cap.
    private func eventsColumns(_ state: MatchState) -> some View {
        HStack(alignment: .top, spacing: 6) {
            eventsColumn(state, isHome: true)
            Color.clear.frame(width: 112)
            eventsColumn(state, isHome: false)
        }
    }

    private func eventsColumn(_ state: MatchState, isHome: Bool) -> some View {
        VStack(alignment: isHome ? .leading : .trailing, spacing: 6) {
            ForEach(Array(state.goals.filter { $0.isHome == isHome }.enumerated()),
                    id: \.offset) { _, goal in
                goalRow(goal)
            }
            ForEach(Array(state.cards.filter { $0.isHome == isHome }.enumerated()),
                    id: \.offset) { _, card in
                cardRow(card)
            }
        }
        .frame(maxWidth: .infinity, alignment: isHome ? .leading : .trailing)
    }

    /// One goal line (spec §2.4): minute first, then the
    /// scorer, with the app's global " (pen)" / " (OG)"
    /// suffixes in the same size and colour. The away
    /// column keeps this same internal order and hugs the
    /// right edge via the column's trailing alignment (the
    /// LiveBoardView precedent — the row itself never
    /// reverses).
    private func goalRow(_ goal: GoalEvent) -> some View {
        let suffix = (goal.isPenalty ? " (pen)" : "") + (goal.isOwnGoal ? " (OG)" : "")
        return HStack(spacing: 5) {
            Text(goal.minuteText)
                .font(MUFont.body(11, .semibold))
                .foregroundStyle(MUTokens.cream)
            Text(goal.scorer + suffix)
                .font(MUFont.body(11))
                .foregroundStyle(MUTokens.cream)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(spokenMinute(goal.minuteText)), \(goal.scorer), bàn thắng")
    }

    /// One card line (spec §2.4): the 8×11 card chip
    /// (radius 2 — yellow is the app-wide card constant,
    /// red is the theme's red), then the player, then the
    /// minute.
    private func cardRow(_ card: CardEvent) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2)
                .fill(card.isRed ? MUTokens.red : BoardPalette.cardYellow)
                .frame(width: 8, height: 11)
            Text(card.player)
                .font(MUFont.body(11))
                .foregroundStyle(MUTokens.cream)
                .lineLimit(1)
            Text(card.minuteText)
                .font(MUFont.body(11, .semibold))
                .foregroundStyle(MUTokens.cream)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(card.isRed ? "thẻ đỏ" : "thẻ vàng"), \(card.player), \(spokenMinute(card.minuteText))")
    }

    /// "72'" → "72 phút" for the VoiceOver line forms the
    /// spec fixes (§2.7).
    private func spokenMinute(_ minuteText: String) -> String {
        minuteText.replacingOccurrences(of: "'", with: " phút")
    }

    // MARK: Source button + sheet (FIX-MU-5, item B)

    /// The count pill the button and the sheet header share
    /// ("n NGUỒN", quality-style 9/400, gold, theme border).
    private var countChip: some View {
        Text("\(totalSources) NGUỒN")
            .font(MUFont.body(9))
            .foregroundStyle(MUTokens.gold)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(MUTokens.themeBorder, lineWidth: 1)
            )
    }

    /// The ONE small source button (owner ruling 2026-11-22
    /// 01:50 CST — it supersedes the drawing's on-page list
    /// for this screen): height 52, radius 12, card fill,
    /// border 1; gold list icon; "Nguồn: <selected channel>"
    /// (or "Chọn nguồn phát" when nothing is selected / there
    /// are no sources); the count chip + chevron at the
    /// right. Disabled when there are no sources. It sits in
    /// the slot the source section occupied (top 12, h16).
    private var sourceButton: some View {
        Button {
            showSourceSheet = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "list.bullet")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(MUTokens.gold)
                Text(effectiveSelection == nil
                     ? "Chọn nguồn phát"
                     : "Nguồn: \(selectionName)")
                    .font(MUFont.body(13, .semibold))
                    .foregroundStyle(MUTokens.cream)
                    .lineLimit(1)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                countChip
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(MUTokens.secondary)
            }
            .padding(.horizontal, 12)
            .frame(height: 52)
            .background(
                MUPressedBackground(RoundedRectangle(cornerRadius: 12), MUTokens.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(MUTokens.border, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(MUPressButtonStyle())
        .disabled(totalSources == 0)
        .opacity(totalSources == 0 ? 0.45 : 1)
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    /// The source list as a sheet, in the MU sheet language
    /// (ground card, padding 20, sheetBorder stroke, radius
    /// 24 at the presentation site): the drawing's section —
    /// heading + count pill, the one-line description, the
    /// VN group above the EN group, the rows exactly as
    /// drawn (the row/group code below is the page's own,
    /// moved here unchanged). A row tap selects + plays at
    /// once (D-6) and dismisses the sheet.
    private var sourceSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Text("CHỌN NGUỒN PHÁT")
                    .font(MUFont.display(24))
                    .muDisplayTracking(24)
                    .foregroundStyle(MUTokens.cream)
                Spacer(minLength: 8)
                countChip
                // FIX-133 (audit D23): the sheet language's
                // 44×44 header close — the sheet dismissed by
                // drag/swipe alone before; the button is the
                // settings sheet's own close, carried over.
                Button {
                    showSourceSheet = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(MUTokens.cream)
                        .frame(width: 44, height: 44)
                        .background(MUPressedBackground(Circle(), MUTokens.card))
                        .overlay(Circle().stroke(MUTokens.border, lineWidth: 1))
                }
                .buttonStyle(MUPressButtonStyle())
                .accessibilityLabel("Đóng")
            }
            Text("Chạm vào một nguồn để phát ngay.")
                .font(MUFont.body(11))
                .foregroundStyle(MUTokens.secondary)
                .padding(.top, 7)
                // FIX-133 (audit D28): the spec's description
                // margins are 7 top / 17 bottom — the bottom
                // 17 was lost when the list moved into the
                // sheet, leaving only the group header's own
                // 16 above the first group.
                .padding(.bottom, 17)
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    if !ladder.isEmpty {
                        groupHeader("Tiếng Việt", right: "Ưu tiên · \(ladder.count) nguồn")
                        VStack(spacing: 8) {
                            ForEach(Array(ladder.enumerated()), id: \.element.id) { index, channel in
                                vnRow(channel, isFirst: index == 0)
                            }
                        }
                    }
                    if !enMetas.isEmpty {
                        groupHeader("Tiếng Anh", right: "English · \(enMetas.count) nguồn")
                        VStack(spacing: 8) {
                            ForEach(enMetas) { meta in
                                enRow(meta)
                            }
                        }
                    }
                }
                .padding(.bottom, 4)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MUTokens.card.ignoresSafeArea())
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(MUTokens.sheetBorder, lineWidth: 1)
        )
        .preferredColorScheme(.dark)
    }

    private func groupHeader(_ title: String, right: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(MUFont.body(13, .medium))
                .foregroundStyle(MUTokens.cream)
            Spacer(minLength: 8)
            Text(right)
                .font(MUFont.body(10))
                .foregroundStyle(MUTokens.secondary)
        }
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    // MARK: Source rows (h60, r12)

    private func vnRow(_ channel: Channel, isFirst: Bool) -> some View {
        let unavailable = isUnavailable(channel)
        let isSelected = effectiveSelection == .vn(channel.url)
        let name = muCommentatorName(MatchTitle.clean(channel.title), group: channel.group)
        // Row notes (audit #102 — the drawing's strings):
        // the selected VN row leads with "Đang chọn ·", the
        // recommended head keeps its "Đề xuất ·", the rest
        // are the backup line; unavailable keeps its note.
        let note: String
        if unavailable {
            note = "Tạm không khả dụng"
        } else if isSelected {
            note = isFirst
                ? "Đang chọn · Đề xuất · bình luận tiếng Việt"
                : "Đang chọn · bình luận tiếng Việt"
        } else if isFirst {
            note = "Đề xuất · bình luận tiếng Việt"
        } else {
            note = "Nguồn dự phòng · tiếng Việt"
        }
        return Button {
            // D-6: a tap selects AND plays, in one motion —
            // and dismisses the source sheet it lives in now.
            selected = .vn(channel.url)
            onPlayVN(channel)
            showSourceSheet = false
        } label: {
            sourceRow(name: name, note: note,
                      quality: qualityToken(for: channel),
                      isSelected: isSelected, unavailable: unavailable)
        }
        .buttonStyle(MUPressButtonStyle())
        .opacity(unavailable ? 0.45 : 1)
        // FIX-133 (audit D42): the unavailable treatment's
        // "no click" half — a proven-dead row is really
        // disabled now, not merely dimmed over a live button.
        .disabled(unavailable)
    }

    private func enRow(_ meta: NuvioMeta) -> some View {
        let isSelected = effectiveSelection == .en(meta.id)
        // The classic board's EN row anatomy: the competition
        // string leads when the addon provides one. The note
        // is the drawing's (#102): "Bình luận tiếng Anh".
        let name = meta.competitionString ?? meta.channelHint ?? meta.displayName
        let note = "Bình luận tiếng Anh"
        return Button {
            selected = .en(meta.id)
            onPlayEN(meta)
            showSourceSheet = false
        } label: {
            sourceRow(name: name, note: note, quality: nil,
                      isSelected: isSelected, unavailable: false)
        }
        .buttonStyle(MUPressButtonStyle())
    }

    private func sourceRow(name: String, note: String, quality: String?,
                           isSelected: Bool, unavailable: Bool) -> some View {
        HStack(spacing: 10) {
            Text(muBadgeText(name))
                .font(MUFont.body(11, .bold))
                .foregroundStyle(MUTokens.bg)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 35, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 6).fill(MUTokens.cream)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(MUFont.body(13, .semibold))
                    .foregroundStyle(MUTokens.cream)
                    .lineLimit(1)
                    .multilineTextAlignment(.leading)
                Text(note)
                    .font(MUFont.body(10))
                    .foregroundStyle(MUTokens.secondary)
                    .lineLimit(1)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let quality {
                Text(quality)
                    .font(MUFont.body(9))
                    .foregroundStyle(MUTokens.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(MUTokens.border, lineWidth: 1)
                    )
            }
            if unavailable {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(MUTokens.secondary)
            } else if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(MUTokens.gold)
            } else {
                Image(systemName: "play.circle")
                    .font(.system(size: 17))
                    .foregroundStyle(MUTokens.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 60)
        .background(
            MUPressedBackground(
                RoundedRectangle(cornerRadius: 12),
                isSelected ? MUTokens.selectedFill : MUTokens.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isSelected ? MUTokens.gold : MUTokens.border, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }

    /// A quality chip only when the channel's own title
    /// carries a quality token — shown verbatim, never
    /// converted into a resolution the app did not measure.
    /// FIX-133 (audit F13): the rule itself now lives in the
    /// shared `muQualityToken(for:)` (MUHomeView.swift), so
    /// the in-player board rows read the identical function.
    private func qualityToken(for channel: Channel) -> String? {
        muQualityToken(for: channel)
    }

    // MARK: Sticky footer CTA

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(MUTokens.border).frame(height: 1)
            Button {
                playSelection()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 14, weight: .bold))
                    Text("Xem trận · \(selectionName)")
                        .font(MUFont.body(14, .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(
                    MUPressedBackground(RoundedRectangle(cornerRadius: 14), MUTokens.ctaGradient)
                )
                .contentShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(MUPressButtonStyle())
            .disabled(effectiveSelection == nil)
            .opacity(effectiveSelection == nil ? 0.45 : 1)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 6)
        }
        .background(MUTokens.bg)
    }

    private var selectionName: String {
        switch effectiveSelection {
        case .vn(let url):
            if let channel = ladder.first(where: { $0.url == url }) {
                return muCommentatorName(MatchTitle.clean(channel.title), group: channel.group)
            }
            return "—"
        case .en(let id):
            if let meta = enMetas.first(where: { $0.id == id }) {
                return meta.competitionString ?? meta.channelHint ?? meta.displayName
            }
            return "—"
        case nil:
            return "—"
        }
    }

    private func playSelection() {
        switch effectiveSelection {
        case .vn(let url):
            if let channel = ladder.first(where: { $0.url == url }) {
                onPlayVN(channel)
            }
        case .en(let id):
            if let meta = enMetas.first(where: { $0.id == id }) {
                onPlayEN(meta)
            }
        case nil:
            break
        }
    }
}
