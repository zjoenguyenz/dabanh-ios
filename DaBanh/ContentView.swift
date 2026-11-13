import SwiftUI

/// Accent green used across the redesigned UI.
private let accentGreen = Color(red: 0.13, green: 0.77, blue: 0.37)

/// Root screen, styled like a TV/streaming app: dark gradient, a header
/// with the live count, a featured rail of live matches, league chips
/// instead of a tab bar, and match cards grouped by bucket (Đang đá /
/// Sắp đá / Khác). All data wiring is unchanged from the previous design:
/// PlaylistStore drives everything, the league order and the first-load
/// tab pick live in the store/classifier, and tapping any card or row
/// presents PlayerView full-screen.
struct ContentView: View {
    @EnvironmentObject private var store: PlaylistStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedChannel: Channel?
    @State private var searchText = ""

    private var liveChannels: [Channel] {
        store.channels.filter { LeagueClassifier.isLive($0) }
    }

    private var isSearching: Bool { !searchText.isEmpty }

    var body: some View {
        // NavigationStack is the host .searchable needs to actually show
        // its field; the bar itself carries no title and stays transparent
        // so the custom header below remains the visual header.
        NavigationStack {
            rootContent
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.hidden, for: .navigationBar)
        }
    }

    private var rootContent: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.04, green: 0.06, blue: 0.08),
                         Color.black],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                if let message = store.statusMessage, !store.channels.isEmpty {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .padding(.horizontal)
                        .padding(.bottom, 4)
                }
                if isSearching {
                    searchList
                } else {
                    if !liveChannels.isEmpty {
                        featuredRail
                    }
                    leagueChips
                    leagueList
                }
            }

            if store.channels.isEmpty {
                loadingOverlay
            }
        }
        .preferredColorScheme(.dark)
        .searchable(text: $searchText, prompt: "Tìm trận, đội bóng…")
        .task { await store.start() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await store.refreshIfStale() }
            }
        }
        .fullScreenCover(item: $selectedChannel) { channel in
            PlayerView(channel: channel)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle().fill(accentGreen)
                Image(systemName: "soccerball")
                    .font(.title3)
                    .foregroundStyle(.white)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text("Đá Banh")
                    .font(.title.bold())
                    .foregroundStyle(.white)
                if liveChannels.count > 0 {
                    HStack(spacing: 6) {
                        PulsingDot()
                        Text("\(liveChannels.count) trận đang đá")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.75))
                    }
                } else {
                    Text("\(store.channels.count) trận trong lịch")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
            Spacer()

            RoutePickerView()
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color.white.opacity(0.10)))

            Button {
                Task { await store.refresh() }
            } label: {
                ZStack {
                    Circle().fill(Color.white.opacity(0.10))
                    if store.isLoading {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.subheadline)
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 40, height: 40)
            }
            .disabled(store.isLoading)
            .accessibilityLabel("Làm mới")
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    // MARK: - Featured rail (live matches across all leagues)

    private var featuredRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(liveChannels.prefix(12)) { channel in
                    Button {
                        selectedChannel = channel
                    } label: {
                        FeaturedCard(channel: channel)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 4)
        }
    }

    // MARK: - League chips

    private var leagueChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if !store.liveChannels.isEmpty {
                    liveChip
                }
                hotChip
                ForEach(League.allCases) { league in
                    let selected = store.selectedLeague == league.rawValue
                    Button {
                        store.selectedLeague = league.rawValue
                    } label: {
                        Text(league.name)
                            .font(.subheadline.weight(selected ? .bold : .regular))
                            .foregroundStyle(selected ? .white : .white.opacity(0.7))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                Capsule().fill(selected ? accentGreen : Color.white.opacity(0.08))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
    }

    /// The 🔴 Trực tiếp chip: every match live right now across all
    /// leagues, same as the TV versions (owner sync request,
    /// 2026-11-13). Hidden when nothing is live.
    private var liveChip: some View {
        let selected = store.selectedLeague == PlaylistStore.liveTabValue
        return Button {
            store.selectedLeague = PlaylistStore.liveTabValue
        } label: {
            Text("🔴 Trực tiếp")
                .font(.subheadline.weight(selected ? .bold : .regular))
                .foregroundStyle(selected ? .white : .white.opacity(0.7))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule().fill(selected ? Color.red : Color.white.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
    }

    /// The 🔥 Hot chip: matches the source sites themselves flag hot,
    /// fed by the backup mirror's "🔥 Hot" group (see PlaylistStore).
    private var hotChip: some View {
        let selected = store.selectedLeague == PlaylistStore.hotTabValue
        return Button {
            store.selectedLeague = PlaylistStore.hotTabValue
        } label: {
            Text("🔥 Hot")
                .font(.subheadline.weight(selected ? .bold : .regular))
                .foregroundStyle(selected ? .white : .white.opacity(0.7))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule().fill(selected ? Color.orange : Color.white.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - League list (bucket sections)

    private var leagueList: some View {
        if store.selectedLeague == PlaylistStore.liveTabValue {
            return AnyView(liveList)
        }
        if store.selectedLeague == PlaylistStore.hotTabValue {
            return AnyView(hotList)
        }
        return AnyView(leagueBucketList)
    }

    private var liveList: some View {
        bucketList(channels: store.liveChannels,
                   emptyText: "Hiện không có trận nào đang đá. Các trận sắp tới nằm ở mục Hot và các giải.")
    }

    private var hotList: some View {
        bucketList(channels: store.hotChannels,
                   emptyText: "Chưa có trận hot nào. Trang nguồn gắn cờ hot cho trận nào thì trận đó hiện ở đây.")
    }

    private var leagueBucketList: some View {
        let league = League(rawValue: store.selectedLeague) ?? .england
        return bucketList(channels: store.channels(in: league),
                          emptyText: "Chưa có kênh nào trong mục này.")
    }

    private func bucketList(channels: [Channel], emptyText: String) -> some View {
        let now = Date()
        let live = channels.filter { LeagueClassifier.bucket(of: $0, now: now) == 0 }
        let upcoming = channels.filter {
            let b = LeagueClassifier.bucket(of: $0, now: now)
            return b == 1 || b == 2
        }
        let rest = channels.filter { LeagueClassifier.bucket(of: $0, now: now) == 3 }

        return List {
            if channels.isEmpty {
                Text(emptyText)
                    .foregroundStyle(.white.opacity(0.6))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            if !live.isEmpty {
                Section {
                    ForEach(live) { channel in matchRow(channel) }
                } header: {
                    sectionHeader("Đang đá", live: true)
                }
            }
            if !upcoming.isEmpty {
                Section {
                    ForEach(upcoming) { channel in matchRow(channel) }
                } header: {
                    sectionHeader("Sắp đá", live: false)
                }
            }
            if !rest.isEmpty {
                Section {
                    ForEach(rest) { channel in matchRow(channel) }
                } header: {
                    sectionHeader("Khác", live: false)
                }
            }
            footerRow
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { await store.refresh() }
    }

    // MARK: - Search results (all leagues, flat)

    private var searchList: some View {
        let query = searchText.lowercased()
        let mainURLs = Set(store.channels.map(\.url))
        let pool = store.channels + store.hotChannels.filter { !mainURLs.contains($0.url) }
        let matches = pool.filter { $0.title.lowercased().contains(query) }
        return List {
            if matches.isEmpty {
                Text("Không tìm thấy trận nào.")
                    .foregroundStyle(.white.opacity(0.6))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            ForEach(matches) { channel in
                matchRow(channel, caption: searchCaption(for: channel))
            }
            footerRow
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { await store.refresh() }
    }

    private func searchCaption(for channel: Channel) -> String {
        let leagueName = League(rawValue: channel.leagueRank)?.name ?? "Khác"
        return channel.group.isEmpty ? leagueName : "\(leagueName) • \(channel.group)"
    }

    // MARK: - Shared rows

    private func matchRow(_ channel: Channel, caption: String? = nil) -> some View {
        Button {
            selectedChannel = channel
        } label: {
            MatchCard(channel: channel, caption: caption ?? channel.group)
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
    }

    private func sectionHeader(_ title: String, live: Bool) -> some View {
        HStack(spacing: 6) {
            if live {
                Circle().fill(Color.red).frame(width: 7, height: 7)
            }
            Text(title.uppercased())
                .font(.caption.bold())
                .tracking(1)
                .foregroundStyle(.white.opacity(0.6))
        }
        .listRowBackground(Color.clear)
    }

    private var footerRow: some View {
        Text("Đá Banh v1.7 • \(store.channels.count) trận")
            .font(.caption)
            .foregroundStyle(.white.opacity(0.35))
            .frame(maxWidth: .infinity, alignment: .center)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .padding(.vertical, 8)
    }

    // MARK: - Loading / empty overlay (first load, or error with retry)

    private var loadingOverlay: some View {
        VStack(spacing: 14) {
            if store.isLoading {
                ProgressView().tint(.white)
            }
            Text(store.statusMessage ?? "Đang tải danh sách kênh…")
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            if !store.isLoading {
                Button("Thử lại") {
                    Task { await store.refresh() }
                }
                .buttonStyle(.borderedProminent)
                .tint(accentGreen)
            }
        }
        .padding()
    }
}

/// Small red dot that pulses while matches are live.
private struct PulsingDot: View {
    @State private var faded = false

    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 8, height: 8)
            .opacity(faded ? 0.25 : 1)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                       value: faded)
            .onAppear { faded = true }
    }
}

/// Kickoff formatting shared by the cards (Vietnam time, ICT).
private enum KickoffFormat {
    static let time: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")
        f.dateFormat = "HH:mm"
        return f
    }()

    static let day: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")
        f.dateFormat = "dd/MM"
        return f
    }()

    static let full: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")
        f.dateFormat = "HH:mm dd/MM"
        return f
    }()
}

/// Big horizontal card for a live match in the featured rail.
private struct FeaturedCard: View {
    let channel: Channel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                CardArt(channel: channel, crestSize: 40, logoSize: 54)
                Text(channel.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Text(channel.kickoff.map { "● ĐANG ĐÁ · \(max(1, Int(Date().timeIntervalSince($0) / 60)))'" } ?? "● ĐANG ĐÁ")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.red, in: Capsule())
                if let kickoff = channel.kickoff {
                    Text(KickoffFormat.full.string(from: kickoff))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.75))
                }
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .frame(width: 250, height: 118, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Color(red: 0.05, green: 0.23, blue: 0.13),
                         Color(red: 0.02, green: 0.09, blue: 0.06)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 16)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 16))
    }
}

/// One match as a card row: time block (or LIVE), logo tile, title +
/// source, play button.
private struct MatchCard: View {
    let channel: Channel
    let caption: String

    private var isLive: Bool { LeagueClassifier.isLive(channel) }

    var body: some View {
        HStack(spacing: 12) {
            // Four-state status block, same language as the TV
            // versions: LIVE + minute / kickoff time / ↺ PHÁT LẠI /
            // 📺 KÊNH — so a replay source is never mistaken for a
            // live one (owner, 2026-11-13).
            VStack(spacing: 2) {
                if isLive {
                    HStack(spacing: 3) {
                        Circle().fill(Color.red).frame(width: 7, height: 7)
                        Text("LIVE")
                            .font(.caption.bold())
                            .foregroundStyle(.red)
                    }
                    if let kickoff = channel.kickoff {
                        let mins = max(1, Int(Date().timeIntervalSince(kickoff) / 60))
                        Text("\(mins)'")
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
            .frame(width: 46)

            CardArt(channel: channel)

            VStack(alignment: .leading, spacing: 3) {
                Text(channel.title)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
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
}

/// Fixed-size channel logo with a placeholder that never breaks layout.
private struct LogoTile: View {
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

/// Card artwork synced with the TV versions (2026-11-13): the two
/// team crests when the title is a fixture in the crest map, the
/// channel logo when it is not. Reading `store.crestsRevision` makes
/// the card re-render when the remote crest map lands.
private struct CardArt: View {
    @EnvironmentObject private var store: PlaylistStore
    let channel: Channel
    var crestSize: CGFloat = 32
    var logoSize: CGFloat = 44

    var body: some View {
        let _ = store.crestsRevision
        if let pair = Crests.crests(forTitle: channel.title),
           pair.0 != nil || pair.1 != nil {
            if pair.0 != nil && pair.1 != nil {
                HStack(spacing: 4) {
                    CrestImg(url: pair.0, size: crestSize)
                    Text("vs")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.45))
                    CrestImg(url: pair.1, size: crestSize)
                }
            } else {
                HStack(spacing: 4) {
                    CrestImg(url: pair.0 ?? pair.1, size: crestSize)
                    LogoTile(channel: channel, size: crestSize, corner: 8)
                }
            }
        } else {
            LogoTile(channel: channel, size: logoSize, corner: 10)
        }
    }
}

/// One team crest with a shield placeholder while loading / missing.
private struct CrestImg: View {
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
