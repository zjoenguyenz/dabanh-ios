import SwiftUI

/// The TV section: the owner's merged playlist (data-582047),
/// served by the shared TVStore — cache-first, device-side link
/// validation with the proven-dead set persisted, .flv hidden,
/// manual "✓ Kiểm tra link" re-probe. Layout inside Joe TV's
/// shell: a hero that follows focus, a group chip row, then one
/// logo-tile rail per visible group. Playback goes through the
/// shared TVPlayerView with same-name fallback sources.
struct JoeTVSection: View {
    @EnvironmentObject private var store: TVStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var playRequest: PlayRequest?
    @State private var selectedGroup: String?
    @FocusState private var focusedChannel: Channel.ID?
    @FocusState private var focusedChip: String?

    private struct PlayRequest: Identifiable {
        let id = UUID()
        let sources: [Channel]
    }

    private var effectiveGroup: String? {
        if let selectedGroup, store.groups.contains(selectedGroup) { return selectedGroup }
        return store.groups.first
    }

    private var heroChannel: Channel? {
        if let id = focusedChannel,
           let ch = store.channels.first(where: { $0.id == id }),
           !store.invalidURLs.contains(ch.url) {
            return ch
        }
        if let group = effectiveGroup {
            return store.visibleChannels(in: group).first
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            hero
            chipRow
            if let message = store.statusMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            sections
            footer
        }
        .padding(.leading, 44)
        .padding(.trailing, 52)
        .padding(.top, 40)
        .padding(.bottom, 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await store.start() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await store.refreshIfStale() } }
        }
        .fullScreenCover(item: $playRequest) { request in
            TVPlayerView(sources: request.sources)
        }
        .onChange(of: store.channels) { _, _ in
            if selectedGroup == nil { selectedGroup = store.groups.first }
            store.noteSelectedGroup(effectiveGroup)
        }
    }

    // MARK: - Hero

    @ViewBuilder
    private var hero: some View {
        if let ch = heroChannel {
            HStack(alignment: .center, spacing: 40) {
                heroArt(ch)
                VStack(alignment: .leading, spacing: 14) {
                    Text(ch.group.uppercased())
                        .font(.system(size: 21, weight: .semibold))
                        .tracking(4)
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                    Text(ch.title)
                        .font(.system(size: 54, weight: .heavy))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    if fallbackCount(for: ch) > 0 {
                        Text("Nguồn dự phòng: \(fallbackCount(for: ch))")
                            .font(.system(size: 21, weight: .medium))
                            .foregroundStyle(.white.opacity(0.8))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color.white.opacity(0.10)))
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(height: 220)
        } else {
            HStack {
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
            }
            .frame(height: 220)
        }
    }

    private func heroArt(_ channel: Channel) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22)
                .fill(Color.black.opacity(0.42))
            if let url = channel.logoURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit().padding(28)
                    default:
                        fallbackText(channel)
                    }
                }
            } else {
                fallbackText(channel)
            }
        }
        .frame(width: 340, height: 204)
        .overlay(RoundedRectangle(cornerRadius: 22)
            .strokeBorder(Color.white.opacity(0.14), lineWidth: 1.2))
    }

    private func fallbackText(_ channel: Channel) -> some View {
        Text(channel.title)
            .font(.system(size: 28, weight: .bold))
            .foregroundStyle(.white.opacity(0.85))
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .padding(22)
    }

    private func fallbackCount(for channel: Channel) -> Int {
        let name = channel.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let total = store.channels.filter {
            $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == name
        }.count
        return max(0, total - 1)
    }

    // MARK: - Group chips + actions (their own row, never squeezed)

    private var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(store.visibleGroups, id: \.self) { group in
                    chip(group)
                }
                actionChip(id: "refresh", title: "↻ Làm mới") {
                    Task { await store.refresh() }
                }
                actionChip(id: "validate",
                           title: store.isValidating ? "Đang kiểm tra…" : "✓ Kiểm tra link") {
                    Task { await store.refreshAndValidate() }
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
        }
    }

    private func chip(_ group: String) -> some View {
        let selected = group == effectiveGroup
        let focused = focusedChip == group
        return Button {
            selectedGroup = group
            store.noteSelectedGroup(group)
        } label: {
            Text(group)
                .font(.system(size: 22, weight: selected ? .bold : .medium))
                .foregroundStyle(selected ? JoeTheme.accentRed : .white.opacity(0.85))
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Capsule().fill(focused ? Color.white.opacity(0.14)
                                           : Color.white.opacity(0.07)))
                .overlay(Capsule().strokeBorder(focused ? Color.white : Color.clear,
                                                lineWidth: 2.5))
        }
        .buttonStyle(.plain)
        .focused($focusedChip, equals: group)
    }

    private func actionChip(id: String, title: String, action: @escaping () -> Void) -> some View {
        let focused = focusedChip == id
        return Button(action: action) {
            Text(title)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Capsule().fill(focused ? Color.white.opacity(0.14)
                                           : Color.white.opacity(0.07)))
                .overlay(Capsule().strokeBorder(focused ? Color.white : Color.clear,
                                                lineWidth: 2.5))
        }
        .buttonStyle(.plain)
        .focused($focusedChip, equals: id)
        .disabled(store.isLoading || store.isValidating)
    }

    // MARK: - Sections

    @ViewBuilder
    private var sections: some View {
        if store.channels.isEmpty {
            Spacer()
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 38) {
                    ForEach(orderedGroups, id: \.self) { group in
                        section(group)
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    /// Selected group first, then the rest in file order.
    private var orderedGroups: [String] {
        var out: [String] = []
        if let lead = effectiveGroup, store.visibleGroups.contains(lead) { out.append(lead) }
        for g in store.visibleGroups where g != effectiveGroup { out.append(g) }
        return out
    }

    private func section(_ group: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(group)
                    .font(.system(size: 29, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("\(store.visibleChannels(in: group).count) kênh")
                    .font(.system(size: 20))
                    .foregroundStyle(.white.opacity(0.5))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 22) {
                    ForEach(store.visibleChannels(in: group)) { channel in
                        tile(channel)
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
            }
        }
    }

    private func tile(_ channel: Channel) -> some View {
        let focused = focusedChannel == channel.id
        return Button {
            play(channel)
        } label: {
            VStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(Color.black.opacity(0.45))
                    if let url = channel.logoURL {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().scaledToFit()
                            default:
                                fallbackText(channel)
                            }
                        }
                        .padding(20)
                    } else {
                        fallbackText(channel)
                    }
                }
                .frame(width: 280, height: 158)
                .overlay(RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(focused ? Color.white : Color.white.opacity(0.10),
                                  lineWidth: focused ? 4.5 : 1.2))
                Text(channel.title)
                    .font(.system(size: 20, weight: focused ? .semibold : .medium))
                    .foregroundStyle(focused ? .white : .white.opacity(0.72))
                    .lineLimit(1)
                    .frame(width: 280)
            }
        }
        .buttonStyle(.plain)
        .focused($focusedChannel, equals: channel.id)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if store.isValidating {
                Text("Đang kiểm tra link…")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.45))
            }
            Spacer()
            if !store.channels.isEmpty {
                Text("\(store.channels.count) kênh")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    // MARK: - Playing

    private func play(_ channel: Channel) {
        playRequest = PlayRequest(sources: sources(for: channel))
    }

    /// Same-name entries are the player's fallback ladder; proven
    /// dead links and .flv entries are left out (the TV app's rule).
    private func sources(for channel: Channel) -> [Channel] {
        let name = channel.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var seen = Set<String>()
        var out: [Channel] = []
        for candidate in [channel] + store.channels
        where !store.invalidURLs.contains(candidate.url) && !LinkProbe.isFLV(candidate.url) {
            if candidate.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == name,
               seen.insert(candidate.url).inserted {
                out.append(candidate)
                if out.count >= 6 { break }
            }
        }
        return out.isEmpty ? [channel] : out
    }
}
