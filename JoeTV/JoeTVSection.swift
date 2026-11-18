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
    @EnvironmentObject private var watch: WatchStore
    @Environment(\.joeTheme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @State private var playRequest: PlayRequest?
    @State private var selectedGroup: String?
    @FocusState private var focusedChannel: Channel.ID?
    @FocusState private var focusedChip: String?

    // v2.0.16: the Thể Thao Torrent tab — MediaFusion live
    // sport events as a synthetic chip beside Live Events
    // (owner: "Để tab thể thao torrent / Để kế bên live
    // event luôn"), never a playlist group and never mixed
    // into Live Events itself.
    @State private var sportsOn = false
    @State private var mfEvents: [TorMeta] = []
    @State private var mfEventsLoaded = false
    @State private var mfLoading = false
    /// v2.0.21: the manifest WAS read and exposes no live
    /// catalogs at all — the one case where the profile is
    /// truly the cause of an empty tab (see the empty state).
    @State private var mfNoLiveCatalogs = false
    @State private var sportsHolder: JoeMovieDetail.DirectorHolder?
    @FocusState private var focusedEvent: String?

    private static let sportsChipID = "mf|thethao-torrent"

    // Idea 4: favourite TV channels — a synthetic chip +
    // a grid fed by ChannelFavouritesStore's stored order.
    // Idea 7b/7c (Thể Thao Torrent fixtures only): match
    // reminders + pinned teams, observed so a long-press
    // change re-renders the sports grid in place.
    @ObservedObject private var channelFavourites = ChannelFavouritesStore.shared
    @ObservedObject private var matchReminders = MatchReminderStore.shared
    @ObservedObject private var pinnedTeams = PinnedTeamsStore.shared
    @State private var favouritesOn = false

    private static let favouritesChipID = "fav|yeu-thich"

    private struct PlayRequest: Identifiable {
        let id = UUID()
        let sources: [Channel]
    }

    private var effectiveGroup: String? {
        if let selectedGroup, store.groups.contains(selectedGroup) { return selectedGroup }
        return store.groups.first
    }

    private var heroChannel: Channel? {
        if favouritesOn {
            if let id = focusedChannel,
               let ch = favouriteChannels.first(where: { $0.id == id }) {
                return ch
            }
            return favouriteChannels.first
        }
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
            heroBlock
            chipRow
            if let message = store.statusMessage {
                Text(message)
                    .font(.system(size: 25))
                    .foregroundStyle(.orange)
            }
            contentSection
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
        .fullScreenCover(item: $sportsHolder) { holder in
            JoePlayerView(director: holder.director,
                          filmTitle: holder.title,
                          filmEpisode: holder.episode,
                          sourceLine: holder.sourceLine)
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

    @ViewBuilder
    private var heroBlock: some View {
        if sportsOn {
            sportsHero
                .animation(nil, value: focusedEvent)
        } else {
            hero
                // Hero stabilisation (v1.5): focus changes swap the
                // hero channel instantly — no implicit animation
                // can ghost/overlap the old and new titles.
                .animation(nil, value: heroChannel?.id)
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

    private func fallbackText(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 28, weight: .bold))
            .foregroundStyle(theme.text.opacity(0.85))
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .padding(22)
    }

    // MARK: - Thể Thao Torrent hero

    private var sportsHeroEvent: TorMeta? {
        if let id = focusedEvent,
           let ev = mfEvents.first(where: { $0.id == id }) {
            return ev
        }
        return mfEvents.first
    }

    @ViewBuilder
    private var sportsHero: some View {
        if let ev = sportsHeroEvent {
            HStack(alignment: .center, spacing: 40) {
                ZStack {
                    RoundedRectangle(cornerRadius: theme.rCard)
                        .fill(Color.black.opacity(0.42))
                    if let url = ev.posterURL {
                        JoeRemoteImage(url: url, targetPixels: 720, fit: true) {
                            fallbackText(ev.name)
                        }
                        .padding(28)
                    } else {
                        fallbackText(ev.name)
                    }
                }
                .frame(width: 340, height: 204)
                .overlay(RoundedRectangle(cornerRadius: theme.rCard)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 2))
                VStack(alignment: .leading, spacing: 14) {
                    Text("THỂ THAO TORRENT")
                        .font(.system(size: 25, weight: .semibold))
                        .tracking(4)
                        .foregroundStyle(theme.meta)
                        .lineLimit(1)
                    Text(ev.name)
                        .font(.system(size: 56, weight: .heavy))
                        .foregroundStyle(theme.text)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .frame(height: 220)
        } else {
            HStack {
                if mfLoading {
                    ProgressView("Đang tải sự kiện…")
                        .font(.system(size: 29))
                        .foregroundStyle(theme.text)
                        .tint(.white)
                } else {
                    Text("Chưa có sự kiện nào.")
                        .font(.system(size: 29))
                        .foregroundStyle(theme.meta)
                }
                Spacer()
            }
            .frame(height: 220)
        }
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
                favouritesChip
                ForEach(store.visibleGroups, id: \.self) { group in
                    chip(group)
                    // v2.0.16: the Thể Thao Torrent chip sits
                    // immediately beside Live Events (owner:
                    // "Để kế bên live event luôn"). It exists
                    // only while a sports source is in play —
                    // the Android kill-switch rule: none
                    // configured ⇒ fully absent.
                    // v2.0.24: the gate is sportsAvailable
                    // (Nuvio / StremVerse slots or
                    // MediaFusion), the Sony 2.3.37 rule.
                    if group == sportsChipAnchor,
                       TorrentSettings.sportsAvailable {
                        sportsChip
                    }
                }
                if store.visibleGroups.isEmpty,
                   TorrentSettings.sportsAvailable {
                    sportsChip
                }
                actionChip(id: "refresh", title: "↻ Làm mới") {
                    Task {
                        if sportsOn {
                            mfEventsLoaded = false
                            await loadSportsEvents()
                        } else {
                            await store.refresh()
                        }
                    }
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

    /// The group the Thể Thao Torrent chip sits beside —
    /// the LIVE EVENTS group when the playlist has one,
    /// else the first visible group.
    private var sportsChipAnchor: String? {
        if let live = store.visibleGroups.first(where: {
            $0.uppercased().contains("LIVE EVENTS") }) {
            return live
        }
        return store.visibleGroups.first
    }

    /// Idea 4: the synthetic "⭐ Yêu thích" chip, built on
    /// the Thể Thao Torrent chip's pattern (a mode flag, not
    /// a playlist group; selecting it notes no group).
    private var favouritesChip: some View {
        Button {
            favouritesOn = true
            sportsOn = false
            store.noteSelectedGroup(nil)
        } label: {
            JoeChipLabel(title: "⭐ Yêu thích", selected: favouritesOn)
        }
        .joeCardButton()
        .focused($focusedChip, equals: Self.favouritesChipID)
    }

    private var sportsChip: some View {
        Button {
            sportsOn = true
            favouritesOn = false
            store.noteSelectedGroup(nil)
            // v2.0.16 (post-test fix, mirroring Android
            // 2.3.20): a settled-but-EMPTY result is not
            // latched for the whole session — the endpoint
            // answers empty in waves, so re-selecting the
            // chip while the grid sits empty fetches again.
            // (The Làm mới chip forces a refetch either way.)
            if mfEventsLoaded && mfEvents.isEmpty && !mfLoading {
                mfEventsLoaded = false
            }
            Task { await loadSportsEvents() }
        } label: {
            // The owner's exact label (2026-11-17): "Thể
            // Thao Torrent" — so he recognises it at a glance.
            JoeChipLabel(title: "Thể Thao Torrent", selected: sportsOn)
        }
        .joeCardButton()
        .focused($focusedChip, equals: Self.sportsChipID)
    }

    private func chip(_ group: String) -> some View {
        let selected = !sportsOn && !favouritesOn && group == effectiveGroup
        return Button {
            selectedGroup = group
            sportsOn = false
            favouritesOn = false
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
                // v2.0.16 (owner's 2026-11-17 videos, TV +
                // Live Events): this grid CLIPS at its frame
                // — no .scrollClipDisabled(). The v2.0.8
                // Phase 4 unclip existed for a focused tile's
                // ring, but the tile's outset band was retired
                // since (its ring is an inside strokeBorder —
                // see tile()), so the escape bought nothing
                // and cost the defect he filmed: rows
                // scrolling past the frame's top edge kept
                // painting over the group title above, then
                // the chips and hero, and over the footer at
                // the bottom edge. The v2.0.12 search rule
                // applies here unchanged.
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

    // MARK: - Favourite channels (Idea 4)

    /// The favourited channels in the store's stored order,
    /// looked up by key from the playlist's channels. A key
    /// with no matching channel is hidden, never deleted —
    /// it reappears if the channel returns to the playlist.
    private var favouriteChannels: [Channel] {
        channelFavourites.keys.compactMap { key in
            store.channels.first { ChannelFavouritesStore.key(for: $0) == key }
        }
    }

    @ViewBuilder
    private var favouritesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text("⭐ Yêu thích")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                Text("\(favouriteChannels.count) kênh")
                    .font(.system(size: 25))
                    .foregroundStyle(theme.meta)
            }
            if favouriteChannels.isEmpty {
                // Honest empty state: no favourites yet, or
                // none of them is in the current playlist.
                Text(channelFavourites.keys.isEmpty
                     ? "Chưa có kênh yêu thích — bấm giữ một kênh để ghim"
                     : "Kênh yêu thích hiện không có trong danh sách kênh.")
                    .font(.system(size: 25))
                    .foregroundStyle(theme.meta)
                    .frame(maxWidth: 1200, alignment: .leading)
                Spacer()
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 24) {
                        ForEach(favouriteChannels) { channel in
                            tile(channel)
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 4)
                }
                // Same clipping + focus-region rule as the
                // group grid beside it (see gridSection).
                .focusSection()
            }
        }
    }

    @ViewBuilder
    private var contentSection: some View {
        if sportsOn {
            sportsSection
        } else if favouritesOn {
            favouritesSection
        } else {
            gridSection
        }
    }

    // MARK: - Thể Thao Torrent grid (v2.0.16)

    /// Idea 7c: fixtures mentioning a pinned team sort
    /// BEFORE the rest — a stable partition of the grid's
    /// existing order, never a re-sort: pinned fixtures keep
    /// their relative order, and so does everything else
    /// (non-fixture events included).
    private var orderedSportsEvents: [TorMeta] {
        guard mfEvents.contains(where: { pinnedTeams.matches(title: $0.name) })
        else { return mfEvents }
        return mfEvents.filter { pinnedTeams.matches(title: $0.name) }
            + mfEvents.filter { !pinnedTeams.matches(title: $0.name) }
    }

    @ViewBuilder
    private var sportsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text("Thể Thao Torrent")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                Text("\(mfEvents.count) sự kiện")
                    .font(.system(size: 25))
                    .foregroundStyle(theme.meta)
            }
            if mfLoading && mfEvents.isEmpty {
                ProgressView("Đang lấy sự kiện trực tiếp…")
                    .font(.system(size: 29))
                    .foregroundStyle(theme.text)
                    .tint(.white)
                Spacer()
            } else if mfEvents.isEmpty {
                if mfNoLiveCatalogs {
                    Text("Các nguồn thể thao (Nuvio, MediaFusion, StremVerse) đều không có danh mục trực tiếp nào, nên mục này trống. Nếu anh dùng MediaFusion, kiểm tra trang cấu hình đã bật danh mục trực tiếp (Live Sport Events / kênh TV) chưa, rồi bấm Làm mới.")
                        .font(.system(size: 25))
                        .foregroundStyle(theme.meta)
                        .frame(maxWidth: 1200, alignment: .leading)
                } else {
                    Text("Chưa có sự kiện trực tiếp nào. Nguồn trả trống từng đợt — bấm Làm mới hoặc chọn lại Thể Thao Torrent để lấy lại.")
                        .font(.system(size: 25))
                        .foregroundStyle(theme.meta)
                        .frame(maxWidth: 1200, alignment: .leading)
                }
                Spacer()
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 24) {
                        ForEach(orderedSportsEvents) { event in
                            eventTile(event)
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 4)
                }
                // v2.0.16: this grid CLIPS at its frame, like
                // the channel grid beside it (the section
                // rule — see gridSection).
                .focusSection()
            }
        }
    }

    /// One event cell: the channel tile's anatomy (273×150,
    /// inside focus ring, LIVE badge) carrying the event's
    /// poster art and name.
    private func eventTile(_ event: TorMeta) -> some View {
        let focused = focusedEvent == event.id
        return Button {
            playEvent(event)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: theme.rCard)
                    .fill(theme.surface2)
                VStack(spacing: 6) {
                    ZStack {
                        if let url = event.posterURL {
                            JoeRemoteImage(url: url, targetPixels: 480, fit: true) {
                                fallbackText(event.name)
                            }
                        } else {
                            fallbackText(event.name)
                        }
                    }
                    .frame(maxWidth: 240, maxHeight: 90)
                    Text(event.name)
                        .font(.system(size: 25, weight: focused ? .semibold : .medium))
                        .foregroundStyle(focused ? theme.focusTitle : theme.text)
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
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
            .frame(width: 273, height: 150)
            .overlay(RoundedRectangle(cornerRadius: theme.rCard)
                .strokeBorder(focused ? theme.focus : theme.stroke,
                              lineWidth: focused ? theme.ringWidth : 2))
        }
        .joeCardButton()
        .focused($focusedEvent, equals: event.id)
        // Idea 7b/7c: long-press menu — match reminder +
        // team pinning. The tile's appearance, focus and
        // play path are unchanged.
        .contextMenu {
            sportsReminderMenuItem(event)
            ForEach(fixtureSides(event.name), id: \.self) { side in
                Button(pinnedTeams.isPinned(side)
                       ? "Bỏ ghim đội: \(side)" : "Ghim đội: \(side)") {
                    pinnedTeams.toggle(side)
                }
            }
        }
    }

    /// Idea 7b: the reminder toggle for one fixture. A
    /// fixture's kickoff is read from its title with the
    /// same KickoffParser that fills Channel.kickoff in the
    /// playlist; the item is offered only when that kickoff
    /// exists and is still in the future.
    @ViewBuilder
    private func sportsReminderMenuItem(_ event: TorMeta) -> some View {
        if let kickoff = KickoffParser.parse(from: event.name),
           kickoff > Date() {
            let key = MatchReminderStore.matchKey(forTitle: event.name)
            if matchReminders.reminder(forKey: key) != nil {
                Button("Huỷ nhắc") {
                    matchReminders.cancelReminder(matchKey: key)
                }
            } else {
                Button("Nhắc trước 15 phút") {
                    matchReminders.setReminder(matchKey: key,
                                               title: event.name,
                                               kickoff: kickoff)
                }
            }
        }
    }

    /// Idea 7c: a fixture's two sides, split on " vs " /
    /// " v " (case-insensitive). A title that does not parse
    /// into two non-empty sides yields no pin items.
    private func fixtureSides(_ title: String) -> [String] {
        for separator in [" vs ", " v "] {
            if let range = title.range(of: separator, options: .caseInsensitive) {
                let home = String(title[..<range.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let away = String(title[range.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !home.isEmpty, !away.isEmpty { return [home, away] }
            }
        }
        return []
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
        // The badge reads the CHANNEL's own group: on the
        // group grid every tile's group IS the effective
        // group, so this is unchanged there, and on the
        // favourites grid (mixed groups) it stays truthful
        // per channel.
        let isLiveGroup = channel.group.uppercased().contains("LIVE")
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
        // Idea 4: long-press toggles the channel's
        // favourite. Appearance, focus and the play path
        // are unchanged.
        .contextMenu {
            Button(channelFavourites.isFavourite(channel)
                   ? "Bỏ khỏi Yêu thích" : "Ghim vào Yêu thích") {
                channelFavourites.toggle(channel)
            }
        }
    }

    // v2.0.8 (Phase 1): moveInGrid is DELETED — tiles are
    // plain buttons in the grid's focus section; the engine
    // moves within the grid geometrically and out of it (UP
    // to the chip row, from any column) the same way. No
    // coded no-op directions remain in this view.

    private var footer: some View {
        HStack(spacing: 10) {
            if store.isValidating && !sportsOn {
                Text("Đang kiểm tra link…")
                    .font(.system(size: 23))
                    .foregroundStyle(theme.meta)
            }
            Spacer()
            if sportsOn {
                if !mfEvents.isEmpty {
                    Text("\(mfEvents.count) sự kiện")
                        .font(.system(size: 23))
                        .foregroundStyle(theme.meta)
                }
            } else if favouritesOn {
                if !favouriteChannels.isEmpty {
                    Text("\(favouriteChannels.count) kênh")
                        .font(.system(size: 23))
                        .foregroundStyle(theme.meta)
                }
            } else if !store.channels.isEmpty {
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

    // MARK: - Thể Thao Torrent (v2.0.16)

    private func loadSportsEvents() async {
        guard !mfLoading, !mfEventsLoaded,
              TorrentSettings.sportsAvailable else { return }
        mfLoading = true
        defer { mfLoading = false }
        // v2.0.24: the chain fetch (Nuvio → MediaFusion →
        // StremVerse, first non-empty wins) — the merge cap
        // lives in the fetch itself now.
        let result = await TorrentClient.fetchSportsEvents()
        mfEvents = result.metas
        mfNoLiveCatalogs = (result.manifestLiveCatalogs == false)
        mfEventsLoaded = true
    }

    /// Tap an event → play it through the torrent player:
    /// the ladder is the event's own streams from its
    /// serving base, ranked like a film's, and the director
    /// fails over inside it — the TV section's
    /// click-and-play rule, no intermediate list.
    private func playEvent(_ event: TorMeta) {
        var entry = WatchStore.Entry()
        entry.kind = WatchStore.kindTor
        entry.key = "mf-event|" + event.id
        entry.title = event.name
        entry.poster = event.poster
        entry.metaId = event.id
        // v2.0.21: metas harvested from the profile's type
        // "tv" catalogs (standing live channels) resolve
        // their streams under "tv"; events metas keep the
        // "events" route exactly as before.
        entry.metaType = event.type == "tv" ? "tv" : "events"
        entry.streamId = event.id
        // v2.0.24: streams resolve from the base that SERVED
        // the meta (its servingBase stamp — Nuvio,
        // StremVerse, or MediaFusion), never a fixed MF base.
        let servingBase = event.servingBase.isEmpty
            ? (TorrentSettings.mfBase ?? "") : event.servingBase
        entry.metaBase = servingBase
        entry.background = event.background
        entry.desc = event.desc
        let eventId = event.id
        let eventType = event.type == "tv" ? "tv" : "events"
        let director = PlayDirector(
            store: watch,
            identity: PlayIdentity(entry: entry),
            resumeMs: 0,
            resolveLadder: { _ in
                guard !servingBase.isEmpty else { return [] }
                // The live fetch (own health + gateway tags),
                // ranked best-first by the shared pool
                // ranking, then the shared candidate
                // conversion — the tab's click-and-play rule
                // with the film path's ordering discipline.
                let streams = (try? await TorrentClient.fetchStreamsLive(
                    base: servingBase, type: eventType, id: eventId)) ?? []
                return await TorrentClient.playCandidates(
                    streams: TorrentClient.rankPool(streams), preferred: nil)
            },
            hopIdentity: nil)
        sportsHolder = JoeMovieDetail.DirectorHolder(
            director: director,
            title: event.name,
            episode: "",
            sourceLine: "Nguồn: Thể Thao Torrent · \(Self.sportsSourceName(servingBase))")
    }

    /// The serving source's display name for the player's
    /// source line, read from the serving base's host.
    private static func sportsSourceName(_ base: String) -> String {
        let host = URL(string: base)?.host?.lowercased() ?? ""
        if host.contains("nuvio") { return "Nuvio" }
        if host.contains("stremverse") { return "StremVerse" }
        return "MediaFusion"
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
