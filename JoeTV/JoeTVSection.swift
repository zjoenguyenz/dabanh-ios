import SwiftUI

/// The TV section: the owner's merged playlist (data-582047),
/// served by the shared TVStore — cache-first, device-side link
/// validation with the proven-dead set persisted, .flv hidden,
/// manual "✓ Kiểm tra link" re-probe. Layout inside Joe TV's
/// shell: a hero that follows focus, a group chip row, then ONE
/// channel grid (LazyVGrid, 6 columns) for the selected group —
/// v1.5 deleted the per-group horizontal rails whose nested
/// ScrollViews broke the focus engine's UP geometry. Playback goes through the
/// shared TVPlayerView with same-name fallback sources.

/// v1.5 focus outline colour (lighter violet) — the style law's
/// focus stroke on every focusable element in this file.
private let joeFocusViolet = Color(red: 0.72, green: 0.58, blue: 1.0)

struct JoeTVSection: View {
    @EnvironmentObject private var store: TVStore
    @EnvironmentObject private var nav: JoeNavigator
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
                // Hero stabilisation (v1.5): focus changes swap the
                // hero channel instantly — no implicit animation
                // can ghost/overlap the old and new titles.
                .animation(nil, value: heroChannel?.id)
            chipRow
            if let message = store.statusMessage {
                Text(message)
                    .font(.system(size: 25))
                    .foregroundStyle(.orange)
            }
            gridSection
            footer
        }
        // No outer padding here: the shell (JoeRootView) owns the
        // screen padding since v1.4, so focus geometry is one
        // single VStack hierarchy from the pills down.
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
        // CONVERGENCE (spec item 3, 2026-11-15): the focus-hub
        // consumer that used to sit here (onChange of
        // nav.focusNonce → focusedChip / focusedChannel writes)
        // is REMOVED — no programmatic focus writes on the
        // launch path. DOWN from the pills lands on the chip row
        // geometrically (the chips sit directly below the hero),
        // and DOWN from a chip enters the grid the same way.
    }

    // MARK: - Hero

    @ViewBuilder
    private var hero: some View {
        if let ch = heroChannel {
            HStack(alignment: .center, spacing: 40) {
                heroArt(ch)
                VStack(alignment: .leading, spacing: 14) {
                    Text(ch.group.uppercased())
                        .font(.system(size: 25, weight: .semibold))
                        .tracking(4)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                    Text(ch.title)
                        .font(.system(size: 56, weight: .heavy))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    if fallbackCount(for: ch) > 0 {
                        Text("Nguồn dự phòng: \(fallbackCount(for: ch))")
                            .font(.system(size: 25, weight: .medium))
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
                        .font(.system(size: 29))
                        .foregroundStyle(.white)
                        .tint(.white)
                } else {
                    Text("Chưa có kênh nào.")
                        .font(.system(size: 29))
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
            .strokeBorder(Color.white.opacity(0.14), lineWidth: 2))
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
            HStack(spacing: 16) {
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
            // Chip text is ALWAYS .white. Selection AND focus are
            // carried by the violet family (DESIGN-SPEC §3.1
            // reserves red for LIVE + watch progress only): the
            // selected chip wears the accentViolet fill; a focused
            // chip adds the 4pt lighter-violet outline + scale
            // (F3), drawn by hand under .plain.
            Text(group)
                .font(.system(size: 29, weight: selected ? .bold : .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(Capsule().fill(selected ? JoeTheme.accentViolet
                                           : (focused ? JoeTheme.accentViolet
                                                      : Color.white.opacity(0.07))))
                .overlay(Capsule().strokeBorder(focused ? joeFocusViolet : Color.clear,
                                                lineWidth: 4))
                .scaleEffect(focused ? 1.05 : 1.0)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled(true)
        .focused($focusedChip, equals: group)
    }

    private func actionChip(id: String, title: String, action: @escaping () -> Void) -> some View {
        let focused = focusedChip == id
        return Button(action: action) {
            Text(title)
                .font(.system(size: 29, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(Capsule().fill(focused ? JoeTheme.accentViolet
                                           : Color.white.opacity(0.07)))
                .overlay(Capsule().strokeBorder(focused ? joeFocusViolet : Color.clear,
                                                lineWidth: 4))
                .scaleEffect(focused ? 1.05 : 1.0)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled(true)
        .focused($focusedChip, equals: id)
        .disabled(store.isLoading || store.isValidating)
    }

    // CONVERGENCE (2026-11-15): the chips' per-chip move
    // handler (moveChip) and its chipIDs table are DELETED.
    // Their outcomes are what geometric focus movement does on
    // this layout unaided: LEFT/RIGHT walk the chip row in
    // visual order (the engine also skips the action chips
    // while they are disabled — the case chipIDs hand-managed),
    // UP reaches the pills, DOWN enters the grid at its first
    // tile. The grid tiles keep their own per-tile handler
    // (moveInGrid below): exact 6-column arithmetic the owner
    // asked for, always installed, per-element — its UP from
    // the first row writes focusedChip, a plain focus move
    // between stable elements that no structure depends on.

    // MARK: - Channel grid (v1.5: ONE grid, no nested rails)

    /// The v1.4 layout nested a horizontal ScrollView per group
    /// inside the vertical one; the focus engine's geometry then
    /// never carried UP from deep tiles back to the chips. v1.5
    /// shows exactly ONE grid — the effective group's channels —
    /// inside the section's single vertical ScrollView, and every
    /// tile routes focus arithmetically (see moveInGrid).

    private let gridColumns = Array(repeating: GridItem(.fixed(273), spacing: 24),
                                    count: 6)

    /// The grid's data: the effective group's visible channels
    /// (invalid-link filtering lives in store.visibleChannels).
    private var gridChannels: [Channel] {
        guard let group = effectiveGroup else { return [] }
        return store.visibleChannels(in: group)
    }

    @ViewBuilder
    private var gridSection: some View {
        if store.channels.isEmpty {
            Spacer()
        } else if let group = effectiveGroup {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text(group)
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("\(gridChannels.count) kênh")
                        .font(.system(size: 25))
                        .foregroundStyle(.white.opacity(0.7))
                }
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 24) {
                        ForEach(gridChannels) { channel in
                            tile(channel)
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 4)
                }
            }
        } else {
            Spacer()
        }
    }

    /// One grid cell (DESIGN-SPEC §7.5): a single focusable
    /// 273×150 surface — channel logo centred (max 180×90) with
    /// the channel name (25pt) in the tile's lower band INSIDE
    /// the tile. Focus is the F3 tile treatment, drawn by hand
    /// under .plain: 4pt lighter-violet outline + scale 1.05 +
    /// the name turns focusViolet. No shadow (F3). Tiles of a
    /// LIVE group carry the LIVE badge (red dot + "LIVE") at
    /// top-right — red is reserved for LIVE (§3.1).
    private func tile(_ channel: Channel) -> some View {
        let focused = focusedChannel == channel.id
        let isLiveGroup = (effectiveGroup ?? "").uppercased().contains("LIVE")
        return Button {
            play(channel)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.white.opacity(0.07))
                VStack(spacing: 6) {
                    ZStack {
                        if let url = channel.logoURL {
                            AsyncImage(url: url) { phase in
                                switch phase {
                                case .success(let image):
                                    image.resizable().scaledToFit()
                                default:
                                    fallbackText(channel)
                                }
                            }
                        } else {
                            fallbackText(channel)
                        }
                    }
                    .frame(maxWidth: 180, maxHeight: 90)
                    Text(channel.title)
                        .font(.system(size: 25, weight: focused ? .semibold : .medium))
                        .foregroundStyle(focused ? joeFocusViolet : .white)
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
                if isLiveGroup {
                    HStack(spacing: 6) {
                        Circle().fill(JoeTheme.accentRed).frame(width: 12, height: 12)
                        Text("LIVE")
                            .font(.system(size: 23, weight: .heavy))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.black.opacity(0.65)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(8)
                }
            }
            .frame(width: 273, height: 150)
            .overlay(RoundedRectangle(cornerRadius: 16)
                .strokeBorder(focused ? joeFocusViolet : Color.white.opacity(0.10),
                              lineWidth: focused ? 4 : 2))
            .scaleEffect(focused ? 1.05 : 1.0)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled(true)
        .focused($focusedChannel, equals: channel.id)
        .onMoveCommand { direction in
            moveInGrid(direction, from: channel)
        }
    }

    /// Manual grid routing: the handler sits on each tile, so it
    /// is active exactly while that tile holds focus, and every
    /// direction is arithmetic over gridChannels with 6 columns —
    /// LEFT/RIGHT stop at row edges, DOWN past the last row is a
    /// defined no-op, and UP from the first row escapes to the
    /// chips (focusedChip = effectiveGroup).
    private func moveInGrid(_ direction: MoveCommandDirection, from channel: Channel) {
        let channels = gridChannels
        guard let idx = channels.firstIndex(where: { $0.id == channel.id }) else { return }
        let columns = 6
        switch direction {
        case .left:
            if idx % columns > 0 { focusedChannel = channels[idx - 1].id }
        case .right:
            if idx + 1 < channels.count, idx % columns < columns - 1 {
                focusedChannel = channels[idx + 1].id
            }
        case .up:
            if idx >= columns {
                focusedChannel = channels[idx - columns].id
            } else {
                focusedChip = effectiveGroup
            }
        case .down:
            if idx + columns < channels.count {
                focusedChannel = channels[idx + columns].id
            }
        @unknown default:
            break
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if store.isValidating {
                Text("Đang kiểm tra link…")
                    .font(.system(size: 23))
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
            if !store.channels.isEmpty {
                Text("\(store.channels.count) kênh")
                    .font(.system(size: 23))
                    .foregroundStyle(.white.opacity(0.7))
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
