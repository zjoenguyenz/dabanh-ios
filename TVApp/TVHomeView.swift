import SwiftUI

/// TV app home: a vertical stack of group rails (one rail per playlist
/// group, in the file's order), cards in the same glass style as the Đá Banh
/// TV app. Selecting a card plays it full-screen in the native player.
struct TVHomeView: View {
    @EnvironmentObject private var store: TVStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var playing: Channel?

    var body: some View {
        ZStack {
            background
            VStack(spacing: 24) {
                header
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
            Image(systemName: "tv")
                .font(.system(size: 38))
                .foregroundStyle(.white)
            Text("TV")
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(.white)
            Spacer()
            if !store.channels.isEmpty {
                Text("\(store.channels.count) kênh")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.6))
            }
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

    private var footer: some View {
        HStack {
            Spacer()
            Text("TV v1.0")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.45))
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.channels.isEmpty {
            Spacer()
            if store.isLoading {
                ProgressView("Đang tải danh sách…")
                    .font(.title3)
            } else {
                Text("Chưa có kênh nào.")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 40) {
                    ForEach(store.groups, id: \.self) { group in
                        VStack(alignment: .leading, spacing: 18) {
                            HStack(alignment: .firstTextBaseline, spacing: 14) {
                                Text(group)
                                    .font(.system(size: 34, weight: .bold))
                                    .foregroundStyle(.white)
                                Text("\(store.channels(in: group).count)")
                                    .font(.title3)
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 28) {
                                    ForEach(store.channels(in: group)) { channel in
                                        card(channel)
                                    }
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 14)
                            }
                        }
                    }
                }
                .padding(.bottom, 24)
            }
        }
    }

    private func card(_ channel: Channel) -> some View {
        Button {
            playing = channel
        } label: {
            VStack(spacing: 12) {
                logoView(channel)
                Text(channel.title)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(width: 340, height: 230)
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(LinearGradient(
                        colors: [Color.white.opacity(0.14), Color.white.opacity(0.05)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24)
                            .strokeBorder(Color.white.opacity(0.18), lineWidth: 1.5)))
        }
        .buttonStyle(.card)
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
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
            } else {
                Image(systemName: "tv")
                    .font(.system(size: 44))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .frame(height: 96)
    }
}
