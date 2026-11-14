import SwiftUI

/// TV app home v2.0 — redesigned in the TV360 design language (the
/// owner's reference video, 2026-11-13; notes in tv-app-ref):
/// a deep indigo→violet gradient, a collapsible LEFT RAIL (an icon
/// strip that expands to icon+label rows while focus is inside it),
/// a calm hero that follows the focused channel, and per-group
/// horizontal rails of logo tiles whose focus state is a thick
/// white outline — no scale-up, no glow.
///
/// Deliberately UNLIKE the Đá Banh app (deep teal, top pill tabs,
/// crest hero, bottom rails) so the two can never be mistaken for
/// each other at a glance.
///
/// The rail's bottom carries the two actions — Làm mới and Kiểm tra
/// link — as full-width rows. They never sit in a crowded horizontal
/// row: that is exactly how the tvOS Đá Banh 1.2.6 header crushed
/// its buttons vertically until one was unfocusable.
///
/// Data: TVStore (the owner's merged self-updating playlist),
/// groups in file order, with channels proven dead FROM THIS DEVICE
/// already hidden by the store. Selecting a channel plays it in the
/// shared native player, with same-name channels as automatic
/// fallback sources. Football entries wear the shared status chip
/// (● LIVE · minute, ⏰ kickoff while waiting, ↺ PHÁT LẠI for replay
/// sources); plain TV channels stay unmarked — they are live
/// broadcasts by nature.
struct TVHomeView: View {
    @EnvironmentObject private var store: TVStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var playRequest: PlayRequest?
    @State private var selectedGroup: String?
    @FocusState private var focusedGroup: String?
    @FocusState private var focusedChannel: Channel.ID?
    @FocusState private var focusedAction: String?

    private static let accentRed = Color(red: 1.0, green: 0.27, blue: 0.23)

    private struct PlayRequest: Identifiable {
        let id = UUID()
        let sources: [Channel]
    }

    /// The group to lead with: the explicit selection when it still
    /// exists, otherwise the first group in the file.
    private var effectiveGroup: String? {
        if let selectedGroup, store.groups.contains(selectedGroup) {
            return selectedGroup
        }
        return store.groups.first
    }

    /// True while focus sits anywhere inside the rail (a group row or
    /// an action row): the rail is expanded then, and collapses back
    /// to an icon strip when focus moves out to the content.
    private var railExpanded: Bool {
        focusedGroup != nil || focusedAction != nil
    }

    /// Sections on screen: the selected group first, then the other
    /// groups that still have visible channels, in file order.
    private var sectionGroups: [String] {
        var out: [String] = []
        if let lead = effectiveGroup, store.visibleGroups.contains(lead) {
            out.append(lead)
        }
        for group in store.visibleGroups where group != effectiveGroup {
            out.append(group)
        }
        return out
    }

    /// The hero's channel: the focused tile's channel, else the first
    /// visible channel of the selected group.
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
        ZStack {
            background
            HStack(spacing: 0) {
                rail
                content
            }
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
            store.noteSelectedGroup(effectiveGroup)
        }
        .onChange(of: focusedGroup) { _, group in
            // Rail browsing is live: focusing a group leads with it,
            // and the store probes that group first.
            if let group {
                selectedGroup = group
                store.noteSelectedGroup(group)
            }
        }
    }

    // MARK: - Chrome

    private var background: some View {
        LinearGradient(
            colors: [Color(red: 0.14, green: 0.13, blue: 0.48),
                     Color(red: 0.10, green: 0.08, blue: 0.35),
                     Color(red: 0.05, green: 0.04, blue: 0.18)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
    }

    // MARK: - Rail

    private var rail: some View {
        VStack(alignment: .leading, spacing: 0) {
            wordmark
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(store.groups, id: \.self) { group in
                        groupRow(group)
                    }
                }
                .padding(.vertical, 8)
            }
            Rectangle()
                .fill(Color.white.opacity(0.14))
                .frame(height: 1)
                .padding(.vertical, 10)
            actionRow(id: "refresh", icon: "arrow.clockwise", title: "Làm mới") {
                Task { await store.refresh() }
            }
            .disabled(store.isLoading)
            actionRow(
                id: "validate",
                icon: "checkmark.shield",
                title: store.isValidating ? "Đang kiểm tra…" : "Kiểm tra link"
            ) {
                Task { await store.refreshAndValidate() }
            }
            .disabled(store.isLoading || store.isValidating)
        }
        .padding(.horizontal, 16)
        .padding(.top, 40)
        .padding(.bottom, 28)
        .frame(width: railExpanded ? 330 : 92)
        .frame(maxHeight: .infinity)
        .background(Color.black.opacity(0.28))
        .clipped()
        .animation(.easeInOut(duration: 0.25), value: railExpanded)
    }

    private var wordmark: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text("TV")
                .font(.system(size: 34, weight: .heavy))
                .foregroundStyle(.white)
            Text(".")
                .font(.system(size: 34, weight: .heavy))
                .foregroundStyle(Self.accentRed)
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.leading, 10)
        .padding(.bottom, 22)
    }

    private func groupRow(_ group: String) -> some View {
        let selected = group == effectiveGroup
        let focused = focusedGroup == group
        return Button {
            selectedGroup = group
            store.noteSelectedGroup(group)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: Self.icon(for: group))
                    .font(.system(size: 23, weight: .medium))
                    .frame(width: 56)
                if railExpanded {
                    Text(group)
                        .font(.system(size: 24, weight: selected ? .bold : .medium))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text("\(store.visibleChannels(in: group).count)")
                        .font(.system(size: 19))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            .foregroundStyle(
                focused ? .white
                    : (selected ? Self.accentRed : .white.opacity(0.82)))
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 13)
                    .fill(focused ? Color.white.opacity(0.12)
                        : (selected ? Color.white.opacity(0.06) : Color.clear)))
            .overlay(
                RoundedRectangle(cornerRadius: 13)
                    .strokeBorder(focused ? Color.white : Color.clear, lineWidth: 2.5))
        }
        .buttonStyle(.plain)
        .focused($focusedGroup, equals: group)
    }

    private func actionRow(id: String, icon: String, title: String,
                           action: @escaping () -> Void) -> some View {
        let focused = focusedAction == id
        return Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 23, weight: .medium))
                    .frame(width: 56)
                if railExpanded {
                    Text(title)
                        .font(.system(size: 23, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .foregroundStyle(.white)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 13)
                    .fill(focused ? Color.white.opacity(0.12) : Color.clear))
            .overlay(
                RoundedRectangle(cornerRadius: 13)
                    .strokeBorder(focused ? Color.white : Color.clear, lineWidth: 2.5))
        }
        .buttonStyle(.plain)
        .focused($focusedAction, equals: id)
    }

    /// Rail icon per group, by simple keyword mapping on the group
    /// name (checked in this order: hot, sport, kids, news, music,
    /// film, science, entertainment — film last among content words
    /// so e.g. "Phim hoạt hình" lands on kids).
    private static func icon(for group: String) -> String {
        let g = group.lowercased()
        if g.contains("🔥") || g.contains("hot") { return "flame" }
        if g.contains("thể thao") || g.contains("sport") || g.contains("bóng đá") {
            return "sportscourt"
        }
        if g.contains("thiếu nhi") || g.contains("trẻ em")
            || g.contains("hoạt hình") || g.contains("kids") {
            return "teddybear"
        }
        if g.contains("tin tức") || g.contains("thời sự") || g.contains("news") {
            return "newspaper"
        }
        if g.contains("nhạc") || g.contains("music") { return "music.note" }
        if g.contains("khoa học") || g.contains("discovery") || g.contains("tài liệu") {
            return "globe"
        }
        if g.contains("phim") || g.contains("movie") || g.contains("cinema") {
            return "film"
        }
        if g.contains("giải trí") { return "sparkles" }
        return "tv"
    }

    // MARK: - Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 24) {
            hero
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
                        .font(.system(size: 58, weight: .heavy))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    HStack(spacing: 14) {
                        statusChip(ch)
                        if fallbackCount(for: ch) > 0 {
                            metaPill("Nguồn dự phòng: \(fallbackCount(for: ch))")
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(height: 240)
        } else {
            // Same height as the loaded hero, so the rails never jump
            // while the first list (or a validation pass) lands.
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
            .frame(height: 240)
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
                        image.resizable().scaledToFit().padding(30)
                    default:
                        heroFallbackText(channel)
                    }
                }
            } else {
                heroFallbackText(channel)
            }
        }
        .frame(width: 360, height: 216)
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1.2))
    }

    private func heroFallbackText(_ channel: Channel) -> some View {
        Text(channel.title)
            .font(.system(size: 30, weight: .bold))
            .foregroundStyle(.white.opacity(0.85))
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .padding(24)
    }

    private func metaPill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 21, weight: .medium))
            .foregroundStyle(.white.opacity(0.8))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.white.opacity(0.10)))
    }

    /// Same-name entries beyond the channel itself: the player's
    /// automatic fallback ladder, counted for the hero's meta line.
    private func fallbackCount(for channel: Channel) -> Int {
        let name = channel.title
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let total = store.channels.filter {
            $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == name
        }.count
        return max(0, total - 1)
    }

    // MARK: - Sections

    @ViewBuilder
    private var sections: some View {
        if store.channels.isEmpty {
            Spacer()
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 40) {
                    ForEach(sectionGroups, id: \.self) { group in
                        section(group)
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    private func section(_ group: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(group)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("\(store.visibleChannels(in: group).count) kênh")
                    .font(.system(size: 21))
                    .foregroundStyle(.white.opacity(0.5))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 24) {
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
            VStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color.black.opacity(0.45))
                    tileLogo(channel)
                }
                .frame(width: 300, height: 170)
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .strokeBorder(
                            focused ? Color.white : Color.white.opacity(0.10),
                            lineWidth: focused ? 4.5 : 1.2))
                .overlay(alignment: .topLeading) {
                    statusChip(channel)
                        .padding(10)
                }
                Text(channel.title)
                    .font(.system(size: 20, weight: focused ? .semibold : .medium))
                    .foregroundStyle(focused ? .white : .white.opacity(0.72))
                    .lineLimit(1)
                    .frame(width: 300)
            }
        }
        .buttonStyle(.plain)
        .focused($focusedChannel, equals: channel.id)
    }

    @ViewBuilder
    private func tileLogo(_ channel: Channel) -> some View {
        if let url = channel.logoURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFit()
                default:
                    tileFallback(channel)
                }
            }
            .padding(22)
        } else {
            tileFallback(channel)
        }
    }

    private func tileFallback(_ channel: Channel) -> some View {
        Text(channel.title)
            .font(.system(size: 23, weight: .semibold))
            .foregroundStyle(.white.opacity(0.8))
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .padding(16)
    }

    // MARK: - Status chip (shared language with the Đá Banh app)

    /// Status chip for match entries only (kickoff-bearing titles):
    /// red ● LIVE · minute while the match is in its live window,
    /// amber ⏰ kickoff while it is still to come, grey ↺ PHÁT LẠI
    /// once its window has passed (a replay/highlight source).
    /// Plain channels get no chip at all.
    @ViewBuilder
    private func statusChip(_ channel: Channel) -> some View {
        if let kickoff = channel.kickoff {
            let now = Date()
            let bucket = LeagueClassifier.bucket(of: channel, now: now)
            if bucket == 0 {
                let mins = max(1, Int(now.timeIntervalSince(kickoff) / 60))
                chip(text: "● LIVE · \(mins)'",
                     color: Color(red: 1.0, green: 0.30, blue: 0.25))
            } else if kickoff > now {
                chip(text: "⏰ " + Self.timeFormatter.string(from: kickoff),
                     color: Color(red: 1.0, green: 0.78, blue: 0.35))
            } else {
                chip(text: "↺ PHÁT LẠI",
                     color: .white.opacity(0.65))
            }
        }
    }

    private func chip(text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 17, weight: .heavy))
            .foregroundStyle(color)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.black.opacity(0.55)))
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm · dd/MM"
        f.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")
        return f
    }()

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if store.isValidating {
                Text("Đang kiểm tra link…")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.45))
            }
            Spacer()
            Text("TV v2.0")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.4))
            if !store.channels.isEmpty {
                Text("· \(store.channels.count) kênh")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    // MARK: - Playing

    private func play(_ channel: Channel) {
        playRequest = PlayRequest(sources: sources(for: channel))
    }

    /// The same channel often appears on several CDNs (same display
    /// name, different URL): those are the player's fallback ladder.
    /// Links already proven dead from this device (and .flv entries,
    /// unplayable in AVPlayer) are left out of the ladder.
    private func sources(for channel: Channel) -> [Channel] {
        let name = channel.title
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var seen = Set<String>()
        var out: [Channel] = []
        for candidate in [channel] + store.channels
        where !store.invalidURLs.contains(candidate.url) && !LinkProbe.isFLV(candidate.url) {
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
