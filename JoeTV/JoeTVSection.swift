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

struct JoeTVSection: View {
    @EnvironmentObject private var store: TVStore
    @EnvironmentObject private var nav: JoeNavigator
    @Environment(\.joeTheme) private var theme
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
        // 1.9.2 (Team 9 item 4): Menu in this SECTION returns
        // to the Phim section — the app's main menu — instead
        // of exiting the app (the owner's Android model).
        // Unconditional, on this section's own root; the player
        // cover above this view carries its own handler and is
        // the nearer consumer while it is up.
        .onExitCommand { nav.section = .phim }
        // v2.0.5 (N1/N2): the chip row's first group chip is
        // the section's DECLARED top element — the landing
        // the pill row's DOWN resigns focus to (the hero above
        // the chips is decoration, not focusable). The value
        // tracks the store's first visible group; with no
        // groups loaded it is nil and declares nothing.
        .defaultFocus($focusedChip, store.visibleGroups.first)
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
                        .foregroundStyle(theme.meta)
                        .lineLimit(1)
                    Text(ch.title)
                        .font(.system(size: 56, weight: .heavy))
                        .foregroundStyle(theme.text)
                        .lineLimit(2)
                    if fallbackCount(for: ch) > 0 {
                        Text("Nguồn dự phòng: \(fallbackCount(for: ch))")
                            .font(.system(size: 25, weight: .medium))
                            .foregroundStyle(theme.text.opacity(0.8))
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
                        .foregroundStyle(theme.text)
                        .tint(.white)
                } else {
                    Text("Chưa có kênh nào.")
                        .font(.system(size: 29))
                        .foregroundStyle(theme.meta)
                }
                Spacer()
            }
            .frame(height: 220)
        }
    }

    private func heroArt(_ channel: Channel) -> some View {
        ZStack {
            // UI-6 defect D-21: shared-section radii follow
            // the active theme's scale.
            RoundedRectangle(cornerRadius: theme.rCard)
                .fill(Color.black.opacity(0.42))
            if let url = channel.logoURL {
                JoeRemoteImage(url: url, targetPixels: 720, fit: true) {
                    fallbackText(channel)
                }
                .padding(28)
            } else {
                fallbackText(channel)
            }
        }
        .frame(width: 340, height: 204)
        .overlay(RoundedRectangle(cornerRadius: theme.rCard)
            .strokeBorder(Color.white.opacity(0.14), lineWidth: 2))
    }

    private func fallbackText(_ channel: Channel) -> some View {
        Text(channel.title)
            .font(.system(size: 28, weight: .bold))
            .foregroundStyle(theme.text.opacity(0.85))
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
        // v2.0.5 (N1, pair f): the chip row is a declared
        // focus region, the grid below it another — chip ↔
        // grid movement is section-to-section. v2.0.8
        // (Phase 1): that movement is the engine's geometric
        // search — moveInGrid's declared UP landing onto the
        // active group's chip is deleted with its handler,
        // so the grid is enterable from any chip and UP
        // leaves it from any column.
        .focusSection()
    }

    private func chip(_ group: String) -> some View {
        let selected = group == effectiveGroup
        return Button {
            selectedGroup = group
            store.noteSelectedGroup(group)
        } label: {
            // v2.0.0 (UI-5): the shared chip leaf — selection
            // wears the theme accent fill, focus the theme ring;
            // values only inside one painted capsule.
            JoeChipLabel(title: group, selected: selected)
        }
        .joeCardButton()
        .focused($focusedChip, equals: group)
    }

    private func actionChip(id: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            JoeChipLabel(title: title, selected: false)
        }
        .joeCardButton()
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
    // tile.
    // v2.0.8 (Phase 1): the grid tiles' per-tile handler
    // (moveInGrid) is DELETED too — an attached .onMoveCommand
    // owned every direction and made undeclared ones no-ops.
    // Tiles are plain buttons now; the engine moves within
    // the grid and back UP to the chip row geometrically,
    // from any column.

    // MARK: - Channel grid (v1.5: ONE grid, no nested rails)

    /// The v1.4 layout nested a horizontal ScrollView per group
    /// inside the vertical one; the focus engine's geometry then
    /// never carried UP from deep tiles back to the chips. v1.5
    /// shows exactly ONE grid — the effective group's channels —
    /// inside the section's single vertical ScrollView. v2.0.8
    /// (Phase 1): tiles are plain buttons and focus moves
    /// geometrically — the v1.5 arithmetic routing (moveInGrid)
    /// is deleted.

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
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                    Text("\(gridChannels.count) kênh")
                        .font(.system(size: 25))
                        .foregroundStyle(theme.meta)
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
                // v2.0.8 (Phase 4): a focused tile's ring is
                // never clipped by the scroll container.
                .scrollClipDisabled()
                // v2.0.5 (N1, pair f): the grid's focus region
                // (see chipRow) — entering it from the chips is
                // section-to-section navigation; within it the
                // engine's geometric search rules (v2.0.8
                // Phase 1 — moveInGrid deleted).
                .focusSection()
            }
        } else {
            Spacer()
        }
    }

    /// One grid cell (DESIGN-SPEC §7.5): a single focusable
    /// 273×150 surface — channel logo centred (max 180×90) with
    /// the channel name (25pt) in the tile's lower band INSIDE
    /// the tile. v2.0.0 (UI-5): focus is value-only — the theme
    /// ring colour/width and the name's focus colour change
    /// inside the always-installed tile shape; no scale. Tiles
    /// of a LIVE group carry the LIVE badge (red dot + "LIVE")
    /// at top-right — red is reserved for LIVE (§3.1).
    private func tile(_ channel: Channel) -> some View {
        let focused = focusedChannel == channel.id
        let isLiveGroup = (effectiveGroup ?? "").uppercased().contains("LIVE")
        return Button {
            play(channel)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: theme.rCard)
                    .fill(theme.surface2)
                VStack(spacing: 6) {
                    ZStack {
                        if let url = channel.logoURL {
                            JoeRemoteImage(url: url, targetPixels: 480, fit: true) {
                                fallbackText(channel)
                            }
                        } else {
                            fallbackText(channel)
                        }
                    }
                    .frame(maxWidth: 180, maxHeight: 90)
                    Text(channel.title)
                        .font(.system(size: 25, weight: focused ? .semibold : .medium))
                        .foregroundStyle(focused ? theme.focusTitle : theme.text)
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
                if isLiveGroup {
                    HStack(spacing: 6) {
                        Circle().fill(JoeTheme.accentRed).frame(width: 12, height: 12)
                        Text("LIVE")
                            .font(.system(size: 23, weight: .heavy))
                            .foregroundStyle(theme.text)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.black.opacity(0.65)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(8)
                }
            }
            .frame(width: 273, height: 150)
            // The focused band is an INSIDE strokeBorder (the
            // v2.0.6 outset band — inset by −ringWidth — is
            // retired: the owner's fidelity ruling puts every
            // focus frame inside its element, and this tile was
            // the tree's last outset ring outside the design
            // system's two drawn ones, the field's and design
            // D's wall art). The resting 2 pt border is
            // unchanged; only the focused band's placement and
            // width move.
            .overlay(RoundedRectangle(cornerRadius: theme.rCard)
                .strokeBorder(focused ? theme.focus : theme.stroke,
                              lineWidth: focused ? theme.ringWidth : 2))
        }
        .joeCardButton()
        .focused($focusedChannel, equals: channel.id)
    }

    // v2.0.8 (Phase 1): moveInGrid is DELETED — tiles are
    // plain buttons in the grid's focus section; the engine
    // moves within the grid geometrically and out of it (UP
    // to the chip row, from any column) the same way. No
    // coded no-op directions remain in this view.

    private var footer: some View {
        HStack(spacing: 10) {
            if store.isValidating {
                Text("Đang kiểm tra link…")
                    .font(.system(size: 23))
                    .foregroundStyle(theme.meta)
            }
            Spacer()
            if !store.channels.isEmpty {
                Text("\(store.channels.count) kênh")
                    .font(.system(size: 23))
                    .foregroundStyle(theme.meta)
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
