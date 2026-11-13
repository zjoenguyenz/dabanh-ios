import SwiftUI

/// TV app home v1.1 — a warm "cinema guide" identity, deliberately
/// UNLIKE the Đá Banh app (deep teal, top pill tabs, match hero,
/// rails): this app is a channel browser with an espresso-charcoal
/// palette, amber accents, a left group sidebar and a logo grid, so
/// the two apps can never be mistaken for each other at a glance.
///
/// Data: the owner's merged self-updating playlist (TVStore), groups
/// in file order. Selecting a channel plays it in the shared native
/// player, with same-name channels as automatic fallback sources.
struct TVHomeView: View {
    @EnvironmentObject private var store: TVStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var playRequest: PlayRequest?
    @State private var selectedGroup: String?
    @FocusState private var focusedGroup: String?
    @FocusState private var focusedChannel: Channel.ID?

    private static let amber = Color(red: 1.0, green: 0.70, blue: 0.25)

    private struct PlayRequest: Identifiable {
        let id = UUID()
        let sources: [Channel]
    }

    /// The group to show: the explicit selection when it still exists,
    /// otherwise the first group in the file.
    private var effectiveGroup: String? {
        if let selectedGroup, store.groups.contains(selectedGroup) {
            return selectedGroup
        }
        return store.groups.first
    }

    var body: some View {
        ZStack {
            background
            HStack(spacing: 0) {
                sidebar
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 1)
                    .padding(.vertical, 8)
                rightPane
            }
            .padding(.horizontal, 56)
            .padding(.vertical, 36)
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
        .onChange(of: store.channels) { _, _ in
            if selectedGroup == nil {
                selectedGroup = store.groups.first
            }
        }
        .onChange(of: focusedGroup) { _, group in
            // Sidebar browsing is live: focusing a group shows it.
            if let group {
                selectedGroup = group
            }
        }
    }

    // MARK: - Chrome

    private var background: some View {
        LinearGradient(
            colors: [Color(red: 0.13, green: 0.10, blue: 0.07),
                     Color(red: 0.07, green: 0.05, blue: 0.04),
                     Color(red: 0.03, green: 0.02, blue: 0.02)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: "tv")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(Self.amber)
                Text("TV")
                    .font(.system(size: 48, weight: .heavy))
                    .foregroundStyle(.white)
            }
            Text("TRUYỀN HÌNH")
                .font(.system(size: 20, weight: .semibold))
                .tracking(5)
                .foregroundStyle(Self.amber.opacity(0.9))
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(store.groups, id: \.self) { group in
                        groupRow(group)
                    }
                }
                .padding(.vertical, 6)
                .padding(.trailing, 14)
            }
            HStack {
                Text("TV v1.1")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.4))
                Spacer()
                if !store.channels.isEmpty {
                    Text("\(store.channels.count) kênh")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .padding(.trailing, 14)
        }
        .frame(width: 410)
    }

    private func groupRow(_ group: String) -> some View {
        let selected = group == effectiveGroup
        let focused = focusedGroup == group
        return Button {
            selectedGroup = group
        } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(selected ? Self.amber : Color.clear)
                    .frame(width: 6, height: 32)
                Text(group)
                    .font(.system(size: 25, weight: selected ? .bold : .medium))
                    .foregroundStyle(focused ? Self.amber : .white)
                    .lineLimit(1)
                Spacer()
                Text("\(store.channels(in: group).count)")
                    .font(.system(size: 20))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(selected ? Color.white.opacity(0.10) : Color.clear))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(focused ? Self.amber : Color.clear, lineWidth: 3))
        }
        .buttonStyle(.plain)
        .focused($focusedGroup, equals: group)
    }

    // MARK: - Right pane

    private var rightPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                Text((effectiveGroup ?? "TV").uppercased())
                    .font(.system(size: 40, weight: .heavy))
                    .tracking(1.5)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let group = effectiveGroup {
                    Text("\(store.channels(in: group).count) kênh")
                        .font(.system(size: 22))
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
                Button {
                    Task { await store.refresh() }
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "arrow.clockwise")
                        Text("Làm mới")
                    }
                    .font(.system(size: 22, weight: .medium))
                    .padding(.horizontal, 22)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.card)
                .disabled(store.isLoading)
            }
            HStack {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Self.amber)
                    .frame(width: 220, height: 4)
                Spacer()
            }
            if let message = store.statusMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            grid
        }
        .padding(.leading, 44)
    }

    @ViewBuilder
    private var grid: some View {
        if store.channels.isEmpty {
            Spacer()
            if store.isLoading {
                ProgressView("Đang tải danh sách…")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .tint(.white)
            } else {
                Text("Chưa có kênh nào.")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
        } else if let group = effectiveGroup {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 26), count: 5),
                    spacing: 26
                ) {
                    ForEach(store.channels(in: group)) { channel in
                        tile(channel)
                    }
                }
                .padding(.vertical, 10)
                .padding(.trailing, 6)
            }
            .id(group)
        } else {
            Spacer()
        }
    }

    private func tile(_ channel: Channel) -> some View {
        let focused = focusedChannel == channel.id
        return Button {
            play(channel)
        } label: {
            VStack(spacing: 12) {
                logoView(channel)
                Text(channel.title)
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(focused ? Self.amber : .white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .padding(18)
            .frame(maxWidth: .infinity)
            .frame(height: 208)
            .background(tileBackground(focused: focused))
        }
        .buttonStyle(.card)
        .focused($focusedChannel, equals: channel.id)
    }

    private func tileBackground(focused: Bool) -> some View {
        RoundedRectangle(cornerRadius: 18)
            .fill(LinearGradient(
                colors: [Color.white.opacity(0.09), Color.white.opacity(0.04)],
                startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(focused ? Self.amber : Color.white.opacity(0.10),
                                  lineWidth: focused ? 3.5 : 1.2))
    }

    private func logoView(_ channel: Channel) -> some View {
        Group {
            if let url = channel.logoURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit()
                    default:
                        Image(systemName: "tv")
                            .font(.system(size: 44))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
            } else {
                Image(systemName: "tv")
                    .font(.system(size: 44))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .frame(height: 104)
    }

    // MARK: - Playing

    private func play(_ channel: Channel) {
        playRequest = PlayRequest(sources: sources(for: channel))
    }

    /// The same channel often appears on several CDNs (same display
    /// name, different URL): those are the player's fallback ladder.
    private func sources(for channel: Channel) -> [Channel] {
        let name = channel.title
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var seen = Set<String>()
        var out: [Channel] = []
        for candidate in [channel] + store.channels {
            let other = candidate.title
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if other == name, seen.insert(candidate.url).inserted {
                out.append(candidate)
                if out.count >= 6 { break }
            }
        }
        return out.isEmpty ? [channel] : out
    }
}
