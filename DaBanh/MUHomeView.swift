import SwiftUI

/// Shared MU display helpers (home + detail): the channel /
/// commentator name a fixture's representative channel
/// carries. The board's own convention (MatchBoardView) is
/// that the cleaned title's trailing "(Name)" is the
/// commentator the viewer chooses by — the MU surfaces show
/// THAT name where the design shows a channel name, and fall
/// back to the playlist group when a title carries none.
func muCommentatorName(_ cleanTitle: String, group: String) -> String {
    if let open = cleanTitle.lastIndex(of: "("),
       cleanTitle.hasSuffix(")") {
        let inner = cleanTitle[cleanTitle.index(after: open)..<cleanTitle.index(before: cleanTitle.endIndex)]
            .trimmingCharacters(in: .whitespaces)
        if !inner.isEmpty { return inner }
    }
    return group
}

/// Two-letter badge initials for a channel name (the detail
/// rows' badge square): the first letters of the first two
/// words, uppercased; a single word gives its first two
/// letters.
func muInitials(_ name: String) -> String {
    let words = name.split(separator: " ").filter { !$0.isEmpty }
    if words.count >= 2 {
        return (String(words[0].prefix(1)) + String(words[1].prefix(1))).uppercased()
    }
    if let word = words.first {
        return String(word.prefix(2)).uppercased()
    }
    return "TV"
}

/// The detail badge's lettering (FIX-MU-3, finding 4): a
/// known channel carries its BRAND mark as the design draws
/// it — "K+", "ON", "VTV", "sky" — not word initials.
/// Unknown channels fall back to `muInitials`.
func muBadgeText(_ name: String) -> String {
    let upper = name.uppercased()
    if upper.hasPrefix("K+") { return "K+" }
    if upper.hasPrefix("VTV") { return "VTV" }
    if upper.hasPrefix("SKY") { return "sky" }
    if upper.hasPrefix("BEIN") { return "beIN" }
    if upper.hasPrefix("TNT") { return "TNT" }
    if upper.hasPrefix("ESPN") { return "ESPN" }
    if upper.hasPrefix("FPT") { return "FPT" }
    if upper.hasPrefix("HTV") { return "HTV" }
    if upper.hasPrefix("SCTV") { return "SCTV" }
    if upper == "ON" || upper.hasPrefix("ON ") || upper.hasPrefix("ON-") { return "ON" }
    return muInitials(name)
}

/// The design's big-score composition (spec TYPE, FIX-MU-3
/// finding 2): the colon renders at .7em, raised 3 pt
/// (the spec's "vertical-align 3"), with 4 pt of space on
/// each side; the digits stay at full size. Used by the
/// home centre scores (64/44) and the detail hero (76).
struct MUScoreText: View {
    let home: Int
    let away: Int
    let size: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("\(home)")
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(":")
                .font(MUFont.display(size * 0.7))
                .baselineOffset(3)
                .lineLimit(1)
            Text("\(away)")
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .font(MUFont.display(size))
        .tracking(-0.015 * size)
        .foregroundStyle(MUTokens.scoreBright)
    }
}

/// The Vietnamese date line for the home heading
/// ("Thứ Bảy, 22 tháng 11") — composed from Calendar so it
/// never depends on a locale pack being present.
func muVietnameseDateLine(_ date: Date = Date()) -> String {
    let cal = Calendar.current
    let weekdayNames = ["Chủ Nhật", "Thứ Hai", "Thứ Ba", "Thứ Tư",
                        "Thứ Năm", "Thứ Sáu", "Thứ Bảy"]
    let weekday = weekdayNames[max(0, min(6, cal.component(.weekday, from: date) - 1))]
    return "\(weekday), \(cal.component(.day, from: date)) tháng \(cal.component(.month, from: date))"
}

/// The Manchester United home (theme-mu): the approved
/// design's composition wholesale — brand header with the MU
/// crest, the three utility pills, the league tab row, the
/// "SÂN CỎ HÔM NAY" heading, and the match board paged at
/// EXACTLY three boxes per page (the first box featured).
/// Data is the SAME PlaylistStore / MatchStateStore plumbing
/// the classic home reads; only the layout is new.
///
/// Composition heights follow the spec's 844 grid (header 60,
/// utilities 48, tabs 54, heading 55, cards 504, pagination
/// 42); on shorter viewports the lower block scrolls, as the
/// spec allows.
struct MUHomeView: View {
    @EnvironmentObject private var store: PlaylistStore
    @EnvironmentObject private var themeStore: ThemeStore
    @ObservedObject var nuvio: NuvioAddonStore
    /// A fixture tap opens its match detail (the host's board
    /// route — the same route the classic home presents).
    let onOpenFixture: (FixtureEntry) -> Void
    /// Direct plays from the BLV Anh tab's channel rows (the
    /// classic tab's own actions, re-homed here).
    let onPlayVNChannel: (Channel) -> Void
    let onPlayENMeta: (NuvioMeta) -> Void
    let onOpenThemePicker: () -> Void
    let onShowLog: () -> Void

    @State private var page = 0
    /// The featured/detail artwork, refreshed at appear (the
    /// wallpapers list itself loads from MUWallpapers).
    @State private var artURL: URL? = MUWallpapers.heroImage()

    // MARK: Tabs

    private struct MUTab {
        let label: String
        let value: Int
    }

    private var tabs: [MUTab] {
        var list: [MUTab] = [
            MUTab(label: "Trực tiếp", value: PlaylistStore.liveTabValue),
            MUTab(label: "Nổi bật", value: PlaylistStore.hotTabValue),
            MUTab(label: "Premier League", value: League.england.rawValue),
            MUTab(label: "La Liga", value: League.spain.rawValue),
            MUTab(label: "Serie A", value: League.italy.rawValue),
            MUTab(label: "Bundesliga", value: League.germany.rawValue),
            MUTab(label: "Ligue 1", value: League.france.rawValue),
            MUTab(label: "Cúp châu Âu", value: League.cups.rawValue),
            MUTab(label: "Khác", value: League.other.rawValue),
        ]
        // Every classic destination stays reachable: the BLV
        // Anh tab rides at the end whenever either of its
        // sources has content (the classic chip's own rule).
        if !enChannels.isEmpty || nuvio.hasContent {
            list.append(MUTab(label: "BLV Anh", value: LeagueClassifier.enTabValue))
        }
        return list
    }

    private var enChannels: [Channel] {
        store.channels.filter { LeagueClassifier.isEN($0) }
    }

    private var isENTab: Bool {
        store.selectedLeague == LeagueClassifier.enTabValue
    }

    /// The board's fixture entries for the selected tab, in
    /// the store's own order. The Trực tiếp tab is LIVE-ONLY,
    /// identical to classic (FIX-MU-1, F-5(a) — the theme-only
    /// rule allows no behaviour difference between themes);
    /// upcoming fixtures stay reachable via Nổi bật and the
    /// league tabs, exactly as in classic.
    private var tabEntries: [FixtureEntry] {
        switch store.selectedLeague {
        case PlaylistStore.liveTabValue:
            return store.entries(for: store.liveChannels)
        case PlaylistStore.hotTabValue:
            return store.entries(for: store.hotChannels)
        case League.cups.rawValue:
            return store.cupEntries
        case League.england.rawValue, League.spain.rawValue,
             League.italy.rawValue, League.germany.rawValue,
             League.france.rawValue, League.other.rawValue:
            let league = League(rawValue: store.selectedLeague) ?? .other
            return store.entries(for: store.channels(in: league).filter {
                !LeagueClassifier.isEN($0)
            })
        default:
            return store.entries(for: store.liveChannels)
        }
    }

    private var liveCount: Int {
        store.entries(for: store.liveChannels).count
    }

    private var pageCount: Int {
        max(1, Int(ceil(Double(tabEntries.count) / 3.0)))
    }

    private var pageEntries: [FixtureEntry] {
        let start = page * 3
        guard start < tabEntries.count else { return [] }
        return Array(tabEntries[start..<min(start + 3, tabEntries.count)])
    }

    // MARK: Body

    var body: some View {
        ZStack(alignment: .top) {
            MUTokens.bg.ignoresSafeArea()
            // FIX-MU-3 (finding 3): the spec's board backdrop —
            // the selected stadium/fanart at opacity .15,
            // height 380 from the top of the content area
            // (the design's y47, below the status safe area),
            // its mask fading to transparent at the bottom.
            // No art loaded → the flat bg alone, as before.
            if let artURL {
                // FIX-131 (DB-14/FL-396): the image lives in the
                // BACKGROUND of a sized clear base. Background
                // content is sized BY the base and can never
                // report a size back, so the remote image's
                // intrinsic size stays out of layout negotiation
                // (the bare AsyncImage's aspect-fill size —
                // 3840×(380/2160) ≈ 676 pt — was widening this
                // root ZStack past the portrait screen).
                Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 380)
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
                .clipped()
                .opacity(0.15)
                .mask(
                    LinearGradient(
                        gradient: Gradient(stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: 0.55),
                            .init(color: .clear, location: 1),
                        ]),
                        startPoint: .top, endPoint: .bottom)
                )
            }
            VStack(spacing: 0) {
                header
                utilities
                tabRow
                if isENTab {
                    enList
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 0) {
                            heading
                            cardsBlock
                            pagination
                        }
                    }
                }
            }
        }
        .task {
            if await MUWallpapers.refreshRemote() {
                artURL = MUWallpapers.heroImage()
            }
        }
        // FIX-MU-5 (item A): a Hình nền pick in Settings
        // re-reads the hero the moment it lands.
        .onChange(of: themeStore.wallpaperChoice) { _, _ in
            artURL = MUWallpapers.heroImage()
        }
        .onChange(of: store.selectedLeague) { _, _ in
            page = 0
        }
        // FIX-MU-1 (F-2): the store polls, so the filtered
        // list can shrink under an open page (live fixtures
        // finish) — clamp the page whenever the page count
        // moves, or pageEntries slices past the end and the
        // board shows a false empty state with an inverted
        // footer range.
        .onChange(of: pageCount) { _, n in
            if page >= n { page = max(0, n - 1) }
        }
    }

    // MARK: Header (60)

    private var header: some View {
        HStack(spacing: 9) {
            muCrest
            VStack(alignment: .leading, spacing: 1) {
                Text("ĐÁ BANH")
                    .font(MUFont.display(28))
                    .muDisplayTracking(28)
                    .foregroundStyle(MUTokens.cream)
                Text("MANCHESTER UNITED EDITION")
                    .font(MUFont.body(8))
                    .tracking(0.16 * 8)
                    // FIX-MU-5 (#35): gold at FULL opacity.
                    .foregroundStyle(MUTokens.gold)
            }
            Spacer(minLength: 8)
            themePill
        }
        .padding(.horizontal, 16)
        .frame(height: 60)
    }

    /// The brand crest: the real Manchester United crest from
    /// the shared crests map (deviation A-2), 35×40 per spec.
    private var muCrest: some View {
        Group {
            if let url = Crests.url(forTeam: "Manchester United") {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit()
                    default:
                        Image(systemName: "shield")
                            .foregroundStyle(MUTokens.gold.opacity(0.5))
                    }
                }
            } else {
                Image(systemName: "shield")
                    .foregroundStyle(MUTokens.gold.opacity(0.5))
            }
        }
        .frame(width: 35, height: 40)
    }

    /// The design's top-right theme pill: palette icon + the
    /// current theme's name + the settings affordance; opens
    /// the theme picker sheet.
    private var themePill: some View {
        Button {
            onOpenThemePicker()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "paintpalette")
                    .font(.system(size: 14))
                Text(themeStore.themeID.pillName)
                    .font(MUFont.body(12, .semibold))
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 12))
            }
            .foregroundStyle(MUTokens.cream)
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(
                MUPressedBackground(RoundedRectangle(cornerRadius: 14), MUTokens.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(MUTokens.themeBorder, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(MUPressButtonStyle())
        .accessibilityLabel("Đổi giao diện")
    }

    // MARK: Utilities (48)

    private var utilities: some View {
        HStack(spacing: 8) {
            utilityButton(
                icon: "arrow.clockwise", label: "Làm mới",
                busy: store.isLoading
            ) {
                Task { await store.refresh() }
            }
            utilityButton(
                icon: "checkmark.shield", label: "Kiểm tra link",
                busy: store.isValidating
            ) {
                Task { await store.refreshAndValidate() }
            }
            utilityButton(icon: "doc.text", label: "Log", busy: false) {
                onShowLog()
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
    }

    private func utilityButton(icon: String, label: String, busy: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if busy {
                    ProgressView().tint(MUTokens.cream).scaleEffect(0.7)
                } else {
                    Image(systemName: icon).font(.system(size: 14))
                }
                Text(label).font(MUFont.body(12, .medium))
            }
            .foregroundStyle(MUTokens.cream)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(
                MUPressedBackground(RoundedRectangle(cornerRadius: 10), MUTokens.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(MUTokens.border, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(MUPressButtonStyle())
        .disabled(busy)
    }

    // MARK: Tabs (54)

    private var tabRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(tabs, id: \.value) { tab in
                    let selected = store.selectedLeague == tab.value
                    Button {
                        store.selectedLeague = tab.value
                    } label: {
                        Text(tab.label)
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

    // MARK: Heading (55)

    private var heading: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("SÂN CỎ HÔM NAY")
                    .font(MUFont.display(30))
                    .muDisplayTracking(30)
                    .foregroundStyle(MUTokens.cream)
                Text(muVietnameseDateLine())
                    .font(MUFont.body(11))
                    .foregroundStyle(MUTokens.secondary)
            }
            Spacer(minLength: 8)
            if liveCount > 0 {
                HStack(spacing: 5) {
                    Circle().fill(MUTokens.cream).frame(width: 4, height: 4)
                    Text("LIVE · \(liveCount)")
                        .font(MUFont.body(10, .bold))
                        .tracking(0.05 * 10)
                }
                .foregroundStyle(MUTokens.cream)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6).fill(MUTokens.red)
                )
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 55)
    }

    // MARK: Cards block (504)

    @ViewBuilder
    private var cardsBlock: some View {
        VStack(spacing: 12) {
            if pageEntries.isEmpty {
                if store.isLoading {
                    // FIX-MU-5 (#72): the first load paints
                    // the design's three skeleton cards (the
                    // page's own geometry) instead of the
                    // empty-state line; the true empty state
                    // (loaded, nothing here) keeps its text.
                    skeletonCards
                } else {
                    Text("Chưa có trận nào trong mục này.")
                        .font(MUFont.body(12))
                        .foregroundStyle(MUTokens.secondary)
                        .frame(maxWidth: .infinity, minHeight: 196)
                }
            } else {
                ForEach(Array(pageEntries.enumerated()), id: \.element.id) { index, entry in
                    Button {
                        DiagLog.log("player",
                                    "tap: fixture '\(MatchTitle.clean(entry.channel.title))' from the list")
                        onOpenFixture(entry)
                    } label: {
                        MUFixtureCard(entry: entry,
                                      featured: index == 0,
                                      artURL: artURL)
                    }
                    .buttonStyle(MUPressButtonStyle())
                }
            }
            // FIX-MU-5 (#73): the store's orange status line
            // is NOT drawn on the MU board (audit — it is not
            // part of the design).
        }
        .padding(.horizontal, 16)
    }

    /// The loading skeleton (#72): three cards at the page's
    /// own heights (featured 196, standard 142 ×2) in card
    /// fill + border, with muted placeholder blocks holding
    /// the card geometry. The pulse is motion — with Reduce
    /// Motion on the blocks rest at full strength.
    private var skeletonCards: some View {
        VStack(spacing: 12) {
            MUSkeletonCard(featured: true)
            MUSkeletonCard(featured: false)
            MUSkeletonCard(featured: false)
        }
    }

    // MARK: Pagination (42)

    private var pagination: some View {
        HStack(spacing: 10) {
            Button {
                if page > 0 { page -= 1 }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(page > 0 ? MUTokens.cream : MUTokens.secondary.opacity(0.4))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(MUPressButtonStyle())
            .disabled(page == 0)

            Text(tabEntries.isEmpty
                 ? "0 / 0 trận"
                 : "\(page * 3 + 1)–\(min(page * 3 + 3, tabEntries.count)) / \(tabEntries.count) trận")
                .font(MUFont.body(10))
                .foregroundStyle(MUTokens.secondary)

            Spacer(minLength: 8)

            if pageCount > 1 && pageCount <= 10 {
                HStack(spacing: 5) {
                    ForEach(0..<pageCount, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 2.5)
                            .fill(index == page ? MUTokens.gold : MUTokens.border)
                            .frame(width: index == page ? 17 : 5, height: 5)
                    }
                }
            }

            Spacer(minLength: 8)

            Button {
                if page < pageCount - 1 { page += 1 }
            } label: {
                HStack(spacing: 4) {
                    Text("Tiếp")
                        .font(MUFont.body(10))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(page < pageCount - 1
                                 ? MUTokens.cream
                                 : MUTokens.secondary.opacity(0.4))
                .frame(height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(MUPressButtonStyle())
            .disabled(page >= pageCount - 1)
        }
        .padding(.horizontal, 16)
        .frame(height: 42)
    }

    // MARK: BLV Anh tab (channel list, MU chrome)

    private var enList: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                if !nuvio.liveEvents.isEmpty {
                    enSection("Đang đá · Nuvio", entries: nuvio.liveEvents)
                }
                if !nuvio.upcomingEvents.isEmpty {
                    enSection("Sắp đá · Nuvio", entries: nuvio.upcomingEvents)
                }
                if !nuvio.channels.isEmpty {
                    enSection("Kênh 24/7 · Nuvio", entries: nuvio.channels)
                }
                if !enChannels.isEmpty {
                    Text("KÊNH TIẾNG ANH")
                        .font(MUFont.body(11, .semibold))
                        .tracking(1)
                        .foregroundStyle(MUTokens.gold)
                    VStack(spacing: 8) {
                        ForEach(enChannels) { channel in
                            Button {
                                onPlayVNChannel(channel)
                            } label: {
                                enChannelRow(channel)
                            }
                            .buttonStyle(MUPressButtonStyle())
                        }
                    }
                }
                if nuvio.liveEvents.isEmpty && nuvio.upcomingEvents.isEmpty
                    && nuvio.channels.isEmpty && enChannels.isEmpty {
                    Text(nuvio.isLoading
                         ? "Đang tải kênh Nuvio…"
                         : "Chưa có kênh tiếng Anh nào trong danh sách.")
                        .font(MUFont.body(12))
                        .foregroundStyle(MUTokens.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private func enSection(_ title: String, entries: [NuvioMeta]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(MUFont.body(11, .semibold))
                .tracking(1)
                .foregroundStyle(MUTokens.gold)
            VStack(spacing: 8) {
                ForEach(entries) { meta in
                    Button {
                        onPlayENMeta(meta)
                    } label: {
                        enMetaRow(meta)
                    }
                    .buttonStyle(MUPressButtonStyle())
                }
            }
        }
    }

    private func enMetaRow(_ meta: NuvioMeta) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(meta.displayName)
                    .font(MUFont.body(13, .semibold))
                    .foregroundStyle(MUTokens.cream)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let competition = meta.competitionString {
                    Text(competition)
                        .font(MUFont.body(10))
                        .foregroundStyle(MUTokens.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if meta.kind == .live {
                HStack(spacing: 4) {
                    Circle().fill(MUTokens.cream).frame(width: 4, height: 4)
                    Text("LIVE").font(MUFont.body(9, .bold))
                }
                .foregroundStyle(MUTokens.cream)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(MUTokens.red))
            }
            Image(systemName: "play.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(MUTokens.gold)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MUPressedBackground(RoundedRectangle(cornerRadius: 12), MUTokens.card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(MUTokens.border, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }

    private func enChannelRow(_ channel: Channel) -> some View {
        HStack(spacing: 10) {
            LogoTile(channel: channel, size: 40, corner: 9)
            Text(channel.title.hasPrefix("EN · ")
                 ? String(channel.title.dropFirst(5))
                 : MatchTitle.clean(channel.title))
                .font(MUFont.body(13, .medium))
                .foregroundStyle(MUTokens.cream)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                Circle().fill(MUTokens.cream).frame(width: 4, height: 4)
                Text("LIVE").font(MUFont.body(9, .bold))
            }
            .foregroundStyle(MUTokens.cream)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(MUTokens.red))
            Image(systemName: "play.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(MUTokens.gold)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MUPressedBackground(RoundedRectangle(cornerRadius: 12), MUTokens.card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(MUTokens.border, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// One MU board card (home): the design's match box —
/// competition line + state caption on top, crest/name |
/// big central score | name/crest in the middle, channel +
/// "Chọn nguồn →" under a divider. The featured variant
/// (358×196) carries the stadium artwork inside with the
/// design's gradient; standard boxes are 358×142 on card
/// fill. Score is the matched state's, in the design's
/// colon form; a fixture with no score shows its kickoff
/// (upcoming) or "VS" — never a fabricated digit.
struct MUFixtureCard: View {
    @EnvironmentObject private var store: PlaylistStore
    /// The enclosing card button's pressed flag (injected by
    /// MUPressButtonStyle): the standard card swaps its fill
    /// to the pressed fill; the featured card — whose ground
    /// is artwork — takes a pressed-fill wash under its
    /// content (FIX-MU-3, finding 1).
    @Environment(\.muIsPressed) private var isPressed
    let entry: FixtureEntry
    let featured: Bool
    let artURL: URL?

    private var height: CGFloat { featured ? 196 : 142 }
    private var crestSize: CGFloat { featured ? 54 : 36 }
    private var scoreSize: CGFloat { featured ? 64 : 44 }
    private var nameSize: CGFloat { featured ? 12 : 11 }

    /// The entry re-read with the freshest state (the board
    /// may sit open across a poll).
    private var liveEntry: FixtureEntry {
        var entry = entry
        entry.state = store.state(for: entry.channel)
        entry.competition = LeagueClassifier.competition(
            for: entry.channel, state: entry.state)
        return entry
    }

    var body: some View {
        let entry = liveEntry
        ZStack {
            if featured {
                featuredBackground
                if isPressed {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(MUTokens.pressedFill.opacity(0.55))
                }
            } else {
                RoundedRectangle(cornerRadius: 18)
                    .fill(isPressed ? MUTokens.pressedFill : MUTokens.card)
            }
            VStack(spacing: 0) {
                topRow(entry)
                Spacer(minLength: 4)
                middleRow(entry)
                Spacer(minLength: 4)
                Rectangle()
                    .fill(featured ? MUTokens.featuredSeparator : MUTokens.border)
                    .frame(height: 1)
                    .padding(.bottom, featured ? 10 : 7)
                bottomRow(entry)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
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

    /// Featured art: the shared wallpaper (scaled to fill)
    /// under the design's featured gradient, over the
    /// featured base — the fallback when no art has loaded.
    private var featuredBackground: some View {
        ZStack {
            MUTokens.featuredBase
            if let artURL {
                // FIX-131 (DB-14/FL-396): same inert pattern as
                // the board backdrop — the image sits in the
                // background of a clear layer sized by this
                // ZStack, so its intrinsic size cannot inflate
                // the card.
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
                colors: [MUTokens.featuredGradientTop, MUTokens.featuredGradientBottom],
                startPoint: .top, endPoint: .bottom)
        }
    }

    private func topRow(_ entry: FixtureEntry) -> some View {
        HStack(spacing: 8) {
            Text(entry.competitionLabel)
                .font(MUFont.body(10))
                .foregroundStyle(MUTokens.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text(captionText(entry))
                .font(MUFont.body(9))
                .tracking(0.08 * 9)
                .foregroundStyle(featured ? MUTokens.gold : MUTokens.secondary)
                .lineLimit(1)
        }
    }

    private func captionText(_ entry: FixtureEntry) -> String {
        if entry.isLive { return featured ? "TÂM ĐIỂM ĐÊM NAY" : "Đang diễn ra" }
        if let state = entry.state {
            switch state.status {
            case .fullTime: return "Đã kết thúc"
            case .postponed, .cancelled: return "Hoãn"
            case .pre: break
            case .live, .halfTime: return "Đang diễn ra"
            }
        }
        let bucket = entry.bucket()
        if bucket == 1 || bucket == 2 { return "Sắp diễn ra" }
        if entry.channel.kickoff != nil { return "Phát lại" }
        return "Kênh"
    }

    private func middleRow(_ entry: FixtureEntry) -> some View {
        Group {
            if let teams = entry.teams {
                HStack(alignment: .center, spacing: 6) {
                    teamBlock(name: teams.0, crest: entry.crests?.0 ?? nil)
                    centre(entry)
                        .frame(width: 112)
                    teamBlock(name: teams.1, crest: entry.crests?.1 ?? nil)
                }
            } else {
                HStack(spacing: 12) {
                    LogoTile(channel: entry.channel, size: crestSize, corner: 10)
                    Text(entry.cleanTitle)
                        .font(MUFont.body(12, .semibold))
                        .foregroundStyle(MUTokens.cream)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
            }
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

    /// The centre column: the big score (or kickoff / "VS")
    /// with the LIVE pill beneath it when the match is live.
    private func centre(_ entry: FixtureEntry) -> some View {
        VStack(spacing: 5) {
            if let state = entry.state, let home = state.scoreHome, let away = state.scoreAway {
                // A real score wears the design's colon
                // composition (FIX-MU-3, finding 2); the
                // kickoff / "VS" centre text keeps the plain
                // rendering.
                MUScoreText(home: home, away: away, size: scoreSize)
            } else {
                Text(centreText(entry))
                    .font(MUFont.display(scoreSize))
                    .muDisplayTracking(scoreSize)
                    .foregroundStyle(MUTokens.scoreBright)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            if let pill = livePillText(entry) {
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
            } else if let sub = centreSubText(entry) {
                Text(sub)
                    .font(MUFont.body(10))
                    .foregroundStyle(MUTokens.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func centreText(_ entry: FixtureEntry) -> String {
        if let state = entry.state, let home = state.scoreHome, let away = state.scoreAway {
            return "\(home):\(away)"
        }
        if entry.isLive { return "VS" }
        if let kickoff = entry.channel.kickoff, kickoff > Date() {
            return KickoffFormat.time.string(from: kickoff)
        }
        return "VS"
    }

    private func livePillText(_ entry: FixtureEntry) -> String? {
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

    private func centreSubText(_ entry: FixtureEntry) -> String? {
        if let state = entry.state, state.status == .fullTime { return "FT" }
        if let kickoff = entry.channel.kickoff, kickoff > Date() {
            return KickoffFormat.day.string(from: kickoff)
        }
        return nil
    }

    private func bottomRow(_ entry: FixtureEntry) -> some View {
        HStack(spacing: 8) {
            Text(muCommentatorName(entry.cleanTitle, group: entry.channel.group))
                .font(MUFont.body(11, .medium))
                .foregroundStyle(MUTokens.cream)
                .lineLimit(1)
            Spacer(minLength: 0)
            HStack(spacing: 5) {
                Text("Chọn nguồn")
                    .font(MUFont.body(10))
                Image(systemName: "arrow.right")
                    .font(.system(size: 10))
            }
            .foregroundStyle(MUTokens.secondary)
        }
    }
}

/// One loading skeleton card (FIX-MU-5, #72): the fixture
/// card's own frame (featured 196 / standard 142, radius
/// 18, card fill, border) with muted blocks where the
/// crests, score and lines will land. The gentle pulse is
/// motion, so it runs only when Reduce Motion is off.
struct MUSkeletonCard: View {
    let featured: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                block(width: featured ? 54 : 36, height: featured ? 54 : 36, circle: true)
                VStack(spacing: 6) {
                    block(width: 92, height: 12)
                    block(width: 64, height: 10)
                }
                Spacer(minLength: 0)
                block(width: featured ? 76 : 56, height: featured ? 44 : 32)
                Spacer(minLength: 0)
                VStack(spacing: 6) {
                    block(width: 92, height: 12)
                    block(width: 64, height: 10)
                }
                block(width: featured ? 54 : 36, height: featured ? 54 : 36, circle: true)
            }
            Spacer(minLength: 0)
            block(width: 150, height: 10)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .frame(height: featured ? 196 : 142)
        .background(
            RoundedRectangle(cornerRadius: 18).fill(MUTokens.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(MUTokens.border, lineWidth: 1)
        )
        .opacity(dimmed ? 0.55 : 1)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                dimmed = true
            }
        }
    }

    private func block(width: CGFloat, height: CGFloat, circle: Bool = false) -> some View {
        Group {
            if circle {
                Circle().fill(MUTokens.border)
            } else {
                RoundedRectangle(cornerRadius: 4).fill(MUTokens.border)
            }
        }
        .frame(width: width, height: height)
    }
}
