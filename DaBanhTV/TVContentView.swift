import SwiftUI

/// Đá Banh TV home v1.1 — the finished design, ported from the Sony
/// Android v2.0 the owner approved (which follows the Phim4K language):
/// deep-teal gradient, a hero panel whose content follows the focused
/// card (status badge, big cleaned title, source count, team crests
/// flanking a VS), pill league tabs, and horizontal rails of match
/// cards with a cyan focus ring. Cards show crest-vs-crest when both
/// teams are known (Crests), else the channel logo. Football identity
/// only — deliberately unlike the TV app (different layout, palette
/// accents and typography) so the two are never confused.
struct TVContentView: View {
    @EnvironmentObject private var store: PlaylistStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var playRequest: PlayRequest?
    @State private var hero: Channel?
    @FocusState private var focusedID: Channel.ID?

    private static let cyan = Color(red: 0.0, green: 0.898, blue: 1.0)
    private static let tealFill = Color(red: 0.05, green: 0.36, blue: 0.30)
    private static let liveRed = Color(red: 1.0, green: 0.27, blue: 0.23)
    private static let heroMetaColor = Color(red: 0.75, green: 0.94, blue: 0.90)

    private struct PlayRequest: Identifiable {
        let id = UUID()
        let sources: [Channel]
    }

    private var currentList: [Channel] {
        store.selectedLeague == PlaylistStore.hotTabValue
            ? store.hotChannels
            : store.channels(in: League(rawValue: store.selectedLeague) ?? .england)
    }

    var body: some View {
        ZStack {
            background
            VStack(spacing: 20) {
                header
                tabBar
                if let message = store.statusMessage {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                scrollBody
            }
            .padding(.horizontal, 60)
            .padding(.top, 40)
            .padding(.bottom, 28)
        }
        .task { await store.start() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await store.refreshIfStale() }
            }
        }
        .fullScreenCover(item: $playRequest) { request in
            TVPlayerView(sources: request.sources)
        }
        .onChange(of: focusedID) { _, id in
            guard let id, let ch = currentList.first(where: { $0.id == id }) else { return }
            hero = ch
        }
        .onChange(of: store.selectedLeague) { _, _ in
            hero = currentList.first
        }
        .onChange(of: store.channels) { _, _ in syncHero() }
        .onChange(of: store.hotChannels) { _, _ in syncHero() }
    }

    private func syncHero() {
        if let h = hero, currentList.contains(h) { return }
        hero = currentList.first
    }

    // MARK: - Chrome

    private var background: some View {
        LinearGradient(
            colors: [Color(red: 0.02, green: 0.22, blue: 0.19),
                     Color(red: 0.01, green: 0.11, blue: 0.11),
                     Color(red: 0.00, green: 0.05, blue: 0.06)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 7) {
                Text("TRỰC TIẾP BÓNG ĐÁ")
                    .font(.system(size: 23, weight: .semibold))
                    .tracking(6)
                    .foregroundStyle(Color(red: 0.45, green: 0.90, blue: 0.83))
                Text("Đá Banh TV")
                    .font(.system(size: 56, weight: .bold))
                    .foregroundStyle(.white)
                RoundedRectangle(cornerRadius: 3)
                    .fill(Self.cyan)
                    .frame(width: 120, height: 6)
            }
            Spacer()
            HStack(spacing: 22) {
                Button {
                    Task { await store.refresh() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.clockwise")
                        Text("Làm mới")
                    }
                    .font(.system(size: 24, weight: .medium))
                    .padding(.horizontal, 26)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.card)
                .disabled(store.isLoading)
                Text(countText)
                    .font(.system(size: 24))
                    .foregroundStyle(.white.opacity(0.75))
            }
            .padding(.top, 10)
        }
    }

    private var countText: String {
        store.selectedLeague == PlaylistStore.hotTabValue
            ? "\(store.hotChannels.count) trận hot"
            : "\(currentList.count) kênh"
    }

    private var tabBar: some View {
        HStack(spacing: 16) {
            tabPill(title: "🔥 Hot", value: PlaylistStore.hotTabValue)
            ForEach(League.allCases) { league in
                tabPill(title: league.name, value: league.rawValue)
            }
            Spacer()
        }
    }

    private func tabPill(title: String, value: Int) -> some View {
        let selected = store.selectedLeague == value
        return Button {
            store.selectedLeague = value
        } label: {
            Text(title)
                .font(.system(size: 26, weight: selected ? .bold : .medium))
                .padding(.horizontal, 30)
                .padding(.vertical, 14)
                .background(Capsule().fill(selected ? Self.tealFill : Color.white.opacity(0.10)))
                .foregroundStyle(.white)
        }
        .buttonStyle(.card)
    }

    // MARK: - Content

    @ViewBuilder
    private var scrollBody: some View {
        let list = currentList
        if list.isEmpty {
            Spacer()
            if store.isLoading {
                ProgressView("Đang tải danh sách…")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .tint(.white)
            } else {
                Text(store.selectedLeague == PlaylistStore.hotTabValue
                     ? "Chưa có trận hot nào. Trang nguồn gắn cờ hot cho trận nào thì trận đó hiện ở đây."
                     : "Chưa có trận nào trong mục này.")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
        } else {
            let now = Date()
            let live = list.filter { LeagueClassifier.bucket(of: $0, now: now) == 0 }
            let upcoming = list.filter {
                let b = LeagueClassifier.bucket(of: $0, now: now)
                return b == 1 || b == 2
            }
            let rest = list.filter { LeagueClassifier.bucket(of: $0, now: now) == 3 }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 30) {
                    heroPanel(hero ?? list.first!)
                    if !live.isEmpty {
                        railSection("🔴  ĐANG ĐÁ", live, live: true)
                    }
                    if !upcoming.isEmpty {
                        railSection("⏰  SẮP ĐÁ", upcoming, live: false)
                    }
                    if !rest.isEmpty {
                        railSection("📺  KHÁC", rest, live: false)
                    }
                    HStack {
                        Spacer()
                        Text("Đá Banh TV v1.1")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
                .padding(.top, 6)
                .padding(.bottom, 10)
            }
        }
    }

    // MARK: - Hero

    private func heroPanel(_ ch: Channel) -> some View {
        Button {
            play(ch)
        } label: {
            HStack(alignment: .center, spacing: 36) {
                VStack(alignment: .leading, spacing: 14) {
                    badge(ch)
                    Text(MatchTitle.clean(ch.title))
                        .font(.system(size: 46, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(metaLine(ch))
                        .font(.system(size: 24))
                        .foregroundStyle(Self.heroMetaColor)
                        .lineLimit(1)
                    HStack(spacing: 10) {
                        Text("Xem ngay")
                            .font(.system(size: 24, weight: .semibold))
                        Image(systemName: "play.fill")
                            .font(.system(size: 19))
                    }
                    .foregroundStyle(Self.cyan)
                    .padding(.horizontal, 26)
                    .padding(.vertical, 10)
                    .overlay(Capsule().strokeBorder(Self.cyan, lineWidth: 2.5))
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                heroArt(ch)
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 26)
                    .fill(LinearGradient(
                        colors: [Color.white.opacity(0.13), Color.white.opacity(0.05)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(
                        RoundedRectangle(cornerRadius: 26)
                            .strokeBorder(Color.white.opacity(0.20), lineWidth: 1.5)))
        }
        .buttonStyle(.card)
    }

    private func badge(_ ch: Channel) -> some View {
        let now = Date()
        let bucket = LeagueClassifier.bucket(of: ch, now: now)
        let text: String
        let color: Color
        if bucket == 0 {
            let mins = max(1, Int(now.timeIntervalSince(ch.kickoff ?? now) / 60))
            text = "🔴 ĐANG ĐÁ · \(mins)'"
            color = Self.liveRed
        } else if let kickoff = ch.kickoff {
            text = "⏰ " + Self.timeFormatter.string(from: kickoff)
            color = Self.tealFill
        } else {
            text = "📺 " + ch.group
            color = Self.tealFill
        }
        return Text(text)
            .font(.system(size: 21, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 7)
            .background(Capsule().fill(color))
    }

    private func metaLine(_ ch: Channel) -> String {
        var parts = [leagueDisplayName(ch.leagueRank)]
        if !ch.group.isEmpty { parts.append(ch.group) }
        let sources = fixtureSources(for: ch).count
        if sources > 1 { parts.append("\(sources) nguồn phát") }
        return parts.joined(separator: "  ·  ")
    }

    private func leagueDisplayName(_ rank: Int) -> String {
        switch rank {
        case 1: return "Ngoại Hạng Anh"
        case 2: return "Tây Ban Nha"
        case 3: return "Ý"
        case 4: return "Pháp"
        default: return "Trận đấu"
        }
    }

    @ViewBuilder
    private func heroArt(_ ch: Channel) -> some View {
        if let pair = Crests.crests(forTitle: ch.title), pair.0 != nil || pair.1 != nil {
            HStack(spacing: 22) {
                crestImage(pair.0, size: 168)
                Text("VS")
                    .font(.system(size: 30, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.85))
                crestImage(pair.1, size: 168)
            }
        } else if let url = ch.logoURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFit()
                default:
                    soccerPlaceholder(size: 110)
                }
            }
            .frame(width: 300, height: 168)
        } else {
            soccerPlaceholder(size: 110)
        }
    }

    // MARK: - Rails and cards

    private func railSection(_ title: String, _ items: [Channel], live: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(.white)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 28) {
                    ForEach(items) { ch in
                        matchCard(ch, live: live)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 16)
            }
        }
    }

    private func matchCard(_ ch: Channel, live: Bool) -> some View {
        let focused = focusedID == ch.id
        return Button {
            play(ch)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 10) {
                    crestRow(ch)
                    Spacer()
                    if live {
                        HStack(spacing: 7) {
                            Circle()
                                .fill(Self.liveRed)
                                .frame(width: 13, height: 13)
                            Text("LIVE")
                                .font(.system(size: 19, weight: .heavy))
                                .foregroundStyle(Self.liveRed)
                        }
                    }
                }
                Text(MatchTitle.clean(ch.title))
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(focused ? Self.cyan : .white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
                Text(cardMeta(ch))
                    .font(.system(size: 20))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
            }
            .padding(22)
            .frame(width: 470, height: 252, alignment: .topLeading)
            .background(cardBackground(focused: focused))
        }
        .buttonStyle(.card)
        .focused($focusedID, equals: ch.id)
    }

    private func cardBackground(focused: Bool) -> some View {
        RoundedRectangle(cornerRadius: 22)
            .fill(LinearGradient(
                colors: [Color.white.opacity(0.13), Color.white.opacity(0.05)],
                startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(
                RoundedRectangle(cornerRadius: 22)
                    .strokeBorder(focused ? Self.cyan : Color.white.opacity(0.16),
                                  lineWidth: focused ? 4 : 1.5))
    }

    private func cardMeta(_ ch: Channel) -> String {
        if let kickoff = ch.kickoff {
            let t = Self.timeFormatter.string(from: kickoff)
            return ch.group.isEmpty ? t : t + "  ·  " + ch.group
        }
        return ch.group
    }

    // MARK: - Crests and logos

    @ViewBuilder
    private func crestRow(_ ch: Channel) -> some View {
        let pair = Crests.crests(forTitle: ch.title)
        if let pair, pair.0 != nil || pair.1 != nil {
            HStack(spacing: 10) {
                crestImage(pair.0, size: 62)
                if pair.0 != nil && pair.1 != nil {
                    Text("vs")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
                crestImage(pair.1, size: 62)
                if (pair.0 == nil) != (pair.1 == nil) {
                    channelLogo(ch, height: 46)
                }
            }
        } else {
            channelLogo(ch, height: 54)
        }
    }

    private func crestImage(_ url: URL?, size: CGFloat) -> some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit()
                    default:
                        soccerPlaceholder(size: size * 0.5)
                    }
                }
            } else {
                soccerPlaceholder(size: size * 0.5)
            }
        }
        .frame(width: size, height: size)
    }

    private func channelLogo(_ ch: Channel, height: CGFloat) -> some View {
        Group {
            if let url = ch.logoURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit()
                    default:
                        soccerPlaceholder(size: height * 0.6)
                    }
                }
            } else {
                soccerPlaceholder(size: height * 0.6)
            }
        }
        .frame(height: height)
    }

    private func soccerPlaceholder(size: CGFloat) -> some View {
        Image(systemName: "soccerball")
            .font(.system(size: size))
            .foregroundStyle(.white.opacity(0.35))
    }

    // MARK: - Playing

    private func play(_ ch: Channel) {
        playRequest = PlayRequest(sources: fixtureSources(for: ch))
    }

    /// Every channel carrying the same match (the tapped one first),
    /// deduplicated by URL — the player's fallback ladder.
    private func fixtureSources(for ch: Channel) -> [Channel] {
        let key = MatchTitle.fixtureKey(ch.title)
        if key.isEmpty { return [ch] }
        var seen = Set<String>()
        var out: [Channel] = []
        for candidate in [ch] + store.channels + store.hotChannels {
            if MatchTitle.fixtureKey(candidate.title) == key,
               seen.insert(candidate.url).inserted {
                out.append(candidate)
                if out.count >= 8 { break }
            }
        }
        return out.isEmpty ? [ch] : out
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm · dd/MM"
        f.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")
        return f
    }()
}
