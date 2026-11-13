import SwiftUI

/// Đá Banh TV home — launcher-style, mirroring the owner's Sony TV launcher:
/// dark teal glass, a pill tab bar, a rail of big LIVE cards with the tvOS
/// focus zoom, and grids of upcoming/other channels below. All data comes
/// from the shared PlaylistStore (same engine as the iOS app).
struct TVContentView: View {
    @EnvironmentObject private var store: PlaylistStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var playing: Channel?

    var body: some View {
        ZStack {
            background
            VStack(spacing: 28) {
                header
                tabBar
                if let message = store.statusMessage {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                content
                footer
            }
            .padding(.horizontal, 64)
            .padding(.vertical, 36)
        }
        .task { await store.start() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await store.refreshIfStale() }
            }
        }
        .fullScreenCover(item: $playing) { channel in
            TVPlayerView(channel: channel)
        }
    }

    // MARK: - Chrome

    private var background: some View {
        LinearGradient(
            colors: [Color(red: 0.02, green: 0.10, blue: 0.12),
                     Color(red: 0.01, green: 0.16, blue: 0.18),
                     Color(red: 0.02, green: 0.05, blue: 0.07)],
            startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }

    private var header: some View {
        HStack(spacing: 18) {
            Image(systemName: "soccerball")
                .font(.system(size: 40))
                .foregroundStyle(.white)
            Text("Đá Banh")
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(.white)
            Spacer()
            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 30, weight: .semibold))
                    .padding(14)
            }
            .buttonStyle(.card)
            .disabled(store.isLoading)
        }
    }

    private var tabBar: some View {
        HStack(spacing: 16) {
            tabPill(title: "🔥 Hot", value: PlaylistStore.hotTabValue, hot: true)
            ForEach(League.allCases) { league in
                tabPill(title: league.name, value: league.rawValue, hot: false)
            }
            Spacer()
        }
    }

    private func tabPill(title: String, value: Int, hot: Bool) -> some View {
        let selected = store.selectedLeague == value
        return Button {
            store.selectedLeague = value
        } label: {
            Text(title)
                .font(.system(size: 26, weight: selected ? .bold : .medium))
                .padding(.horizontal, 30)
                .padding(.vertical, 14)
                .background(
                    Capsule().fill(selected
                        ? (hot ? Color.orange : Color.teal)
                        : Color.white.opacity(0.10)))
                .foregroundStyle(.white)
        }
        .buttonStyle(.card)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Text("Đá Banh TV v1.0")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.45))
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        let list = store.selectedLeague == PlaylistStore.hotTabValue
            ? store.hotChannels
            : store.channels(in: League(rawValue: store.selectedLeague) ?? .england)
        if list.isEmpty {
            Spacer()
            if store.isLoading {
                ProgressView("Đang tải danh sách…")
                    .font(.title3)
            } else {
                Text(store.selectedLeague == PlaylistStore.hotTabValue
                     ? "Chưa có trận hot nào. Trang nguồn gắn cờ hot cho trận nào thì trận đó hiện ở đây."
                     : "Chưa có trận nào trong mục này.")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
        } else {
            channelSections(list)
        }
    }

    private func channelSections(_ list: [Channel]) -> some View {
        let now = Date()
        let live = list.filter { LeagueClassifier.bucket(of: $0, now: now) == 0 }
        let upcoming = list.filter {
            let b = LeagueClassifier.bucket(of: $0, now: now)
            return b == 1 || b == 2
        }
        let rest = list.filter { LeagueClassifier.bucket(of: $0, now: now) == 3 }
        return ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 44) {
                if !live.isEmpty {
                    sectionHeader("🔴 Đang đá")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 36) {
                            ForEach(live) { channel in
                                bigCard(channel, live: true)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 16)
                    }
                }
                if !upcoming.isEmpty {
                    sectionHeader("⏰ Sắp đá")
                    cardGrid(upcoming, live: false)
                }
                if !rest.isEmpty {
                    sectionHeader("📺 Kênh khác")
                    cardGrid(rest, live: false)
                }
            }
            .padding(.bottom, 24)
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 36, weight: .bold))
            .foregroundStyle(.white)
    }

    // MARK: - Cards

    private func bigCard(_ channel: Channel, live: Bool) -> some View {
        Button {
            playing = channel
        } label: {
            ZStack(alignment: .topLeading) {
                cardBackground
                VStack(spacing: 14) {
                    logoView(channel, height: 120)
                    Text(channel.title)
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    kickoffChip(channel)
                    if !channel.group.isEmpty {
                        Text(channel.group)
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.65))
                            .lineLimit(1)
                    }
                }
                .padding(28)
                .frame(width: 540, height: 320)
                if live {
                    Text("LIVE")
                        .font(.system(size: 20, weight: .heavy))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.red))
                        .foregroundStyle(.white)
                        .padding(20)
                }
            }
        }
        .buttonStyle(.card)
    }

    private func cardGrid(_ channels: [Channel], live: Bool) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 32), count: 4),
                  spacing: 32) {
            ForEach(channels) { channel in
                Button {
                    playing = channel
                } label: {
                    VStack(spacing: 12) {
                        logoView(channel, height: 72)
                        Text(channel.title)
                            .font(.system(size: 23, weight: .medium))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                        kickoffChip(channel)
                    }
                    .padding(22)
                    .frame(maxWidth: .infinity, minHeight: 210)
                    .background(cardBackground)
                }
                .buttonStyle(.card)
            }
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 24)
            .fill(LinearGradient(
                colors: [Color.white.opacity(0.14), Color.white.opacity(0.05)],
                startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(
                RoundedRectangle(cornerRadius: 24)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1.5))
    }

    private func logoView(_ channel: Channel, height: CGFloat) -> some View {
        Group {
            if let url = channel.logoURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit()
                    default:
                        Image(systemName: "soccerball")
                            .font(.system(size: height * 0.6))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
            } else {
                Image(systemName: "soccerball")
                    .font(.system(size: height * 0.6))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .frame(height: height)
    }

    private func kickoffChip(_ channel: Channel) -> some View {
        Group {
            if let kickoff = channel.kickoff {
                Text(Self.kickoffFormatter.string(from: kickoff))
                    .font(.system(size: 21, weight: .medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.white.opacity(0.16)))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
    }

    private static let kickoffFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm dd/MM"
        f.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")
        return f
    }()
}
