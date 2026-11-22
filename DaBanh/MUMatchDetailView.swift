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
                AsyncImage(url: artURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        Color.clear
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
            }
            Text("Chạm vào một nguồn để phát ngay.")
                .font(MUFont.body(11))
                .foregroundStyle(MUTokens.secondary)
                .padding(.top, 7)
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
    private func qualityToken(for channel: Channel) -> String? {
        let title = MatchTitle.clean(channel.title).uppercased()
        if title.contains("FHD") { return "FHD" }
        if title.contains("UHD") || title.contains("4K") { return "4K" }
        if title.contains("1080") { return "1080p" }
        if title.contains("720") { return "720p" }
        if title.contains("HD") { return "HD" }
        if title.contains("SD") { return "SD" }
        return nil
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
