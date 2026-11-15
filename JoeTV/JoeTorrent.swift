import SwiftUI

/// Route into a torrent title.
struct TorRoute: Hashable {
    var meta: TorMeta
    /// The catalog base this meta came from (meta/videos source).
    var base: String
    /// Continue Watching taps: the episode stream id to preselect.
    var preselectStreamId: String = ""
}

/// Phim Torrent home: Cinemeta/Torrentio catalog rails + search +
/// the torrent Continue Watching rail — everything fetched live
/// at open, like the Android section. Streams come from the
/// owner's configured addon; nothing renders as playable until a
/// source is configured in Cài đặt.
struct JoeTorrentHome: View {
    @EnvironmentObject private var watch: WatchStore
    @EnvironmentObject private var nav: JoeNavigator
    @EnvironmentObject private var store: TorHomeStore
    @Environment(\.joeTheme) private var theme
    @State private var query = ""
    @State private var searchResults: [TorMeta] = []
    @State private var searching = false
    @State private var searchAttempted = false
    @State private var searchError: String?
    /// Team 4 fix-round minor: the home state surfaces (G3/G5)
    /// are gated on "a load has been attempted" so they cannot
    /// flash for a frame at cold entry, before the first
    /// loadIfNeeded has even run.
    @State private var torAttempted = false
    @FocusState private var focusedMeta: TorMeta.ID?
    @FocusState private var focusedEntry: String?
    @FocusState private var torRetryFocused: Bool
    @FocusState private var searchRetryFocused: Bool

    /// The search row's focusable elements, in visual order.
    private enum SearchRowFocus: Hashable {
        case field, search, clear
    }
    @FocusState private var searchFocus: SearchRowFocus?

    var body: some View {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 36) {
                    header
                    searchRow
                    if searching {
                        // C-10: searching is a visible state, not
                        // an empty grid.
                        ProgressView("Đang tìm…")
                            .font(.system(size: 29))
                            .foregroundStyle(theme.text)
                            .tint(.white)
                    } else if !searchResults.isEmpty {
                        searchGrid
                    } else if searchAttempted {
                        searchMessage
                    } else {
                        cwRail
                        favRail
                        ForEach(Array(store.catalogs.enumerated()), id: \.offset) { _, cat in
                            if let metas = store.rails[cat.id + "|" + cat.type], !metas.isEmpty {
                                metaRail(cat.name, metas, base: cat.base,
                                         scope: "torCat:\(cat.id)|\(cat.type)")
                            }
                        }
                        ForEach(Array(store.genreRails.enumerated()), id: \.offset) { _, rail in
                            if !rail.metas.isEmpty {
                                metaRail(rail.title, rail.metas, base: TorrentSettings.cinemeta,
                                         scope: "torGenre:\(rail.type):\(rail.genre)")
                            }
                        }
                        // C-4 + BLOCK-1: the torrent home's
                        // state surfaces are keyed on RAILS, not
                        // hasData — discoverCatalogs never returns
                        // empty (Cinemeta fallbacks), so hasData
                        // was always true and the old error
                        // surface could never fire in the
                        // dead-route case (~100 s of bare header).
                        // Spinner: bounded by the store's 20 s
                        // watchdog, and only while no catalogue
                        // rail has landed.
                        if store.loading && !store.loadTimedOut && torCatalogueEmpty {
                            ProgressView("Đang tải danh mục…")
                                .font(.system(size: 29))
                                .foregroundStyle(theme.text)
                                .tint(.white)
                        }
                        if torErrorVisible {
                            torErrorSurface
                        }
                        if torEmptyVisible {
                            Text("Chưa có danh mục nào.")
                                .font(.system(size: 29))
                                .foregroundStyle(theme.meta)
                        }
                        if !failedCatalogNames.isEmpty {
                            Text("Chưa tải được: " + failedCatalogNames.joined(separator: ", "))
                                .font(.system(size: 25))
                                .foregroundStyle(.orange)
                        }
                        if !TorrentSettings.isConfigured {
                            Text("Chưa cấu hình nguồn phát: vào Cài đặt nhập link Torrentio hoặc token Real-Debrid/TorBox của anh để lấy nguồn.")
                                .font(.system(size: 25))
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            // CONVERGENCE (Team 7 D4, 2026-11-15): the four
            // JoeMoveTrap modifiers that wrapped this ScrollView
            // (enabled by searchFocus / firstRailFocusIndex /
            // torRetryFocused / searchRetryFocused) are REMOVED —
            // each flip rebuilt the ENTIRE ScrollView subtree
            // under the focus engine. Routing now: the search
            // row, the Retry buttons and the rails are plain
            // focusable elements in one stack, so UP/DOWN/LEFT/
            // RIGHT between them is geometric (the search row's
            // LEFT/RIGHT order — field → Tìm → Xoá — is its
            // visual order; a disabled Tìm during search is
            // skipped by the engine, which the old arithmetic
            // walk did not do); the first rail's exact arithmetic
            // survives as an ALWAYS-installed .onMoveCommand on
            // the first rail's own cards (handleFirstRailMove).
        .task {
            torAttempted = true
            store.loadIfNeeded()
        }
        // 1.9.2 (Team 9 items 4 + 8): Menu in this SECTION
        // returns to the Phim section — the app's main menu —
        // instead of exiting the app (the owner's Android
        // model: Back walks inside the app; exit only from the
        // Phim root, which carries no handler). Unconditional,
        // on this section's own root. And the search field is
        // the section's declared initial focus — the same
        // static .defaultFocus construction as JoeSearchView's
        // (the convergence round's geometric assumption left
        // the torrent search row with no declared landing).
        .onExitCommand { nav.section = .phim }
        .defaultFocus($searchFocus, .field)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Phim Torrent")
                .font(.system(size: 56, weight: .heavy))
                .foregroundStyle(theme.text)
            Text("Nguồn Torrentio + Real-Debrid của anh — lấy mới mỗi lần mở")
                .font(.system(size: 25))
                .foregroundStyle(theme.meta)
        }
    }

    private var searchRow: some View {
        HStack(spacing: 18) {
            TextField("", text: $query,
                      prompt: Text("Tìm phim torrent…")
                        .foregroundColor(ThemeTokens.fieldPlaceholder))
                .textFieldStyle(.plain)
                .font(.system(size: ThemeTokens.fieldTextSize))
                .joeFieldChrome(focused: searchFocus == .field)
                .frame(width: 820)
                .focused($searchFocus, equals: .field)
                .onSubmit { runSearch() }
            Button {
                runSearch()
            } label: {
                JoeSecondaryLabel(title: searching ? "Đang tìm…" : "Tìm")
            }
            .buttonStyle(.card)
            .focused($searchFocus, equals: .search)
            .disabled(searching)
            if !searchResults.isEmpty {
                Button {
                    searchResults = []
                    query = ""
                    searchAttempted = false
                    searchError = nil
                } label: {
                    JoeSecondaryLabel(title: "Xoá tìm kiếm")
                }
                .buttonStyle(.card)
                .focused($searchFocus, equals: .clear)
            }
        }
    }

    private var torProgress: [WatchStore.Entry] {
        Array(WatchStore.filterKinds(watch.progress(), [WatchStore.kindTor])
            .prefix(WatchStore.railCap))
    }

    @ViewBuilder
    private var cwRail: some View {
        if !torProgress.isEmpty {
            Rail(title: "▶ Đang xem dở") {
                ForEach(torProgress) { entry in
                    let card = Button { nav.tor = TorRoute(
                        meta: TorMeta(id: entry.metaId, type: entry.metaType,
                                      name: entry.title, poster: entry.poster,
                                      background: entry.background,
                                      year: entry.year, desc: entry.desc),
                        base: entry.metaBase,
                        preselectStreamId: entry.streamId) } label: {
                        PosterCard(
                            title: entry.title,
                            posterURL: entry.posterURL,
                            meta: entry.epLabel,
                            progress: entry.fraction,
                            subline: "Còn \(WatchStore.fmtClock(entry.dur - entry.pos))",
                            focused: focusedEntry == "cw|" + entry.key)
                    }
                    .buttonStyle(.card)
                    .focused($focusedEntry, equals: "cw|" + entry.key)
                    .contextMenu {
                        Button(role: .destructive) {
                            watch.removeProgress(key: entry.key)
                        } label: {
                            Text("Xoá khỏi Đang xem dở")
                        }
                    }
                    // This rail IS the first rail whenever it
                    // renders, so its cards always carry the
                    // first-rail move handler.
                    card.onMoveCommand { dir in handleFirstRailMove(dir) }
                }
            }
        }
    }

    private var torFavorites: [WatchStore.Entry] {
        Array(WatchStore.filterKinds(watch.favorites(), [WatchStore.kindTor])
            .prefix(WatchStore.railCap))
    }

    @ViewBuilder
    private var favRail: some View {
        if !torFavorites.isEmpty {
            Rail(title: "♥ Yêu thích") {
                ForEach(torFavorites) { entry in
                    let card = Button { nav.tor = TorRoute(
                        meta: TorMeta(id: entry.metaId, type: entry.metaType,
                                      name: entry.title, poster: entry.poster,
                                      background: entry.background,
                                      year: entry.year, desc: entry.desc),
                        base: entry.metaBase) } label: {
                        PosterCard(
                            title: entry.title,
                            posterURL: entry.posterURL,
                            meta: entry.year,
                            focused: focusedEntry == "fav|" + entry.key)
                    }
                    .buttonStyle(.card)
                    .focused($focusedEntry, equals: "fav|" + entry.key)
                    .contextMenu {
                        Button(role: .destructive) {
                            watch.removeFavorite(key: entry.key)
                        } label: {
                            Text("Bỏ yêu thích")
                        }
                    }
                    // First rail only when Continue Watching is
                    // empty (it precedes this rail when present).
                    if torProgress.isEmpty {
                        card.onMoveCommand { dir in handleFirstRailMove(dir) }
                    } else {
                        card
                    }
                }
            }
        }
    }

    // MARK: - Focus traversal (first-rail routing)

    /// One focusable card in a rail, whichever FocusState owns it.
    private enum TorRailItem: Equatable {
        case entry(String)
        case meta(TorMeta.ID)
    }

    /// Every rail in on-screen order, empty rails skipped. In
    /// search mode the single "rail" is the results grid. The
    /// first element is the section's first rail: the
    /// Continue-Watching entry rail when non-empty, else the
    /// ♥ Yêu thích entry rail, else the first catalog rail.
    private var torRails: [[TorRailItem]] {
        // Browse rails only. Search results are a GRID and are
        // routed geometrically by searchResultMove — v1.8 modelled
        // them as one flat rail here, which swallowed every DOWN
        // press inside the results (C-2).
        var rails: [[TorRailItem]] = []
        if !torProgress.isEmpty {
            rails.append(torProgress.map { .entry("cw|" + $0.key) })
        }
        if !torFavorites.isEmpty {
            rails.append(torFavorites.map { .entry("fav|" + $0.key) })
        }
        for cat in store.catalogs {
            if let metas = store.rails[cat.id + "|" + cat.type], !metas.isEmpty {
                rails.append(metas.map {
                    .meta("torCat:\(cat.id)|\(cat.type)|" + $0.id) })
            }
        }
        for rail in store.genreRails {
            if !rail.metas.isEmpty {
                rails.append(rail.metas.map {
                    .meta("torGenre:\(rail.type):\(rail.genre)|" + $0.id) })
            }
        }
        return rails
    }

    /// True when NO catalogue rail has anything — the catalogue
    /// rails dict and the genre rails are both empty. (The
    /// owner's own CW/Favourites rails do not count: they are
    /// not catalogue health, same C-8 logic as the Phim home.)
    private var torCatalogueEmpty: Bool {
        store.genreRails.allSatisfy { $0.metas.isEmpty }
            && store.rails.values.allSatisfy { $0.isEmpty }
    }

    /// BLOCK-1 (Team 4): the G3 error surface is keyed on RAILS,
    /// never on hasData (discoverCatalogs' Cinemeta fallbacks
    /// make hasData permanently true). It fires when the store's
    /// 20 s watchdog tripped (loadTimedOut — possibly with jobs
    /// still in flight), OR when a load has ENDED with the
    /// catalogue list known but zero rails landed — every
    /// catalogue fetch came back empty or failed, which on a
    /// dead route is the failure case that used to sit at a bare
    /// header for ~100 s. The attempted gate keeps it from
    /// flashing at cold entry.
    private var torErrorVisible: Bool {
        torAttempted && torCatalogueEmpty
            && (store.loadTimedOut
                || (!store.loading && !store.catalogs.isEmpty))
    }

    /// §8/G5, folded per Team 4's instruction: the store exposes
    /// no per-catalogue error state the view could use to tell
    /// "every fetch failed" from "genuinely nothing exists", so
    /// the truly-empty line is reserved for the one state that
    /// can honestly carry it — a load that ended with NO
    /// catalogue list at all, no timeout, no rails. (With the
    /// Cinemeta fallbacks in discoverCatalogs this state is
    /// currently unreachable; an ended load with catalogues but
    /// zero rails is the G3 surface above, whose Retry forces a
    /// real reload.)
    private var torEmptyVisible: Bool {
        torAttempted && torCatalogueEmpty && !store.loading
            && !store.loadTimedOut && store.catalogs.isEmpty
    }

    /// Catalogues that produced no rail after a completed load,
    /// for the G4 bottom line (only when at least one catalogue
    /// DID produce a rail — the all-failed case is the G5/G3
    /// surface's job).
    private var failedCatalogNames: [String] {
        guard !store.loading, store.hasData else { return [] }
        let names = store.catalogs.compactMap { cat -> String? in
            let metas = store.rails[cat.id + "|" + cat.type]
            return (metas?.isEmpty ?? true) ? cat.name : nil
        }
        return names.count < store.catalogs.count ? names : []
    }

    /// The G3 error shape, torrent edition (C-4 + BLOCK-1).
    /// Retry calls the store's FORCED reload — loadIfNeeded's
    /// freshness guard could no-op here, which is exactly the
    /// dead-end BLOCK-1 names.
    private var torErrorSurface: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
            Text("Không tải được danh mục torrent.")
                .font(.system(size: 29, weight: .semibold))
                .foregroundStyle(theme.text)
            // 1.9.2 (Team 9 item 6): the copy names the likely
            // cause — the torrent route itself, and the tunnel
            // profile's known habit of blocking it — instead of
            // a generic network shrug.
            Text("Chưa tải được mục Torrent — đường tới Torrentio/Cinemeta đang không thông. Nếu profile hầm đang bật, đường này thường bị chặn; thử tắt hầm rồi bấm Thử lại.")
                .font(.system(size: 25))
                .foregroundStyle(theme.meta)
            Button { store.reload() } label: {
                JoePrimaryLabel(title: "Thử lại")
            }
            .buttonStyle(.card)
            .focused($torRetryFocused)
        }
    }

    /// C-10: after a search, the results area says what happened —
    /// "no matches" and "the search failed" are different surfaces.
    @ViewBuilder
    private var searchMessage: some View {
        if let searchError {
            VStack(alignment: .leading, spacing: 16) {
                Text(searchError)
                    .font(.system(size: 25))
                    .foregroundStyle(.orange)
                Button { runSearch() } label: {
                    JoePrimaryLabel(title: "Thử lại")
                }
                .buttonStyle(.card)
                .focused($searchRetryFocused)
            }
        } else {
            Text("Không tìm thấy kết quả nào.")
                .font(.system(size: 29))
                .foregroundStyle(theme.meta)
        }
    }

    private var currentTorRailItem: TorRailItem? {
        if let focusedEntry { return .entry(focusedEntry) }
        if let focusedMeta { return .meta(focusedMeta) }
        return nil
    }

    /// Non-nil only while focus sits in the FIRST rail — the
    /// cards of that rail carry the always-installed
    /// .onMoveCommand whose handler (handleFirstRailMove)
    /// reads this.
    private var firstRailFocusIndex: Int? {
        guard let item = currentTorRailItem,
              let first = torRails.first,
              let idx = first.firstIndex(of: item) else { return nil }
        return idx
    }

    /// The scope of the first CATALOGUE rail on screen, or nil
    /// when an entry rail (Continue Watching / Favourites)
    /// leads. Mirrors torRails' order exactly; metaRail
    /// compares its own scope against this to decide whether
    /// its cards carry the first-rail move handler. A pure
    /// function of catalogue data — the attachment changes
    /// only when the DATA changes, never when focus moves.
    private var firstTorScope: String? {
        if !torProgress.isEmpty || !torFavorites.isEmpty { return nil }
        for cat in store.catalogs {
            if let metas = store.rails[cat.id + "|" + cat.type], !metas.isEmpty {
                return "torCat:\(cat.id)|\(cat.type)"
            }
        }
        for rail in store.genreRails where !rail.metas.isEmpty {
            return "torGenre:\(rail.type):\(rail.genre)"
        }
        return nil
    }

    private func setTorRailFocus(_ item: TorRailItem) {
        switch item {
        case .entry(let key):
            focusedMeta = nil
            focusedEntry = key
        case .meta(let id):
            focusedEntry = nil
            focusedMeta = id
        }
    }

    // CONVERGENCE (2026-11-15): the search-row boundary
    // handler (handleSearchRowMove) is DELETED with its trap.
    // Its outcomes are what geometric focus movement does on
    // this layout unaided: UP → the pills, LEFT/RIGHT → the
    // row's elements in visual order (the engine additionally
    // skips the Tìm button while it is disabled mid-search —
    // an improvement over the old arithmetic walk), DOWN →
    // the first result / first rail card / the visible Retry.
    // The two Retry buttons' UP-to-field routing is likewise
    // geometric (the field is the nearest focusable above).

    /// First-rail boundary: UP to the search row (the field),
    /// LEFT/RIGHT arithmetic neighbours inside the rail (no-op
    /// at its ends), DOWN to the same-index card (clamped) in
    /// the next rail; with a single rail, DOWN lands on the
    /// error surface's Retry when one is showing (Scope-3),
    /// else a no-op. Installed per-card on the first rail's
    /// cards only; deeper rails carry no handler — the focus
    /// engine's geometry handles them.
    private func handleFirstRailMove(_ dir: MoveCommandDirection) {
        guard let idx = firstRailFocusIndex,
              let first = torRails.first else { return }
        if dir == .up {
            searchFocus = .field
        } else if dir == .left {
            if idx > 0 { setTorRailFocus(first[idx - 1]) }
        } else if dir == .right {
            if idx < first.count - 1 { setTorRailFocus(first[idx + 1]) }
        } else if dir == .down {
            if torRails.count > 1 {
                let next = torRails[1]
                setTorRailFocus(next[min(idx, next.count - 1)])
            } else if torErrorVisible {
                torRetryFocused = true
            }
        }
    }

    private func metaRail(_ title: String, _ metas: [TorMeta], base: String,
                          scope: String) -> some View {
        Rail(title: title) {
            ForEach(metas) { meta in
                let card = Button { nav.tor = TorRoute(meta: meta, base: base) } label: {
                    PosterCard(
                        title: meta.name,
                        posterURL: meta.posterURL,
                        meta: meta.year,
                        focused: focusedMeta == scope + "|" + meta.id)
                }
                .buttonStyle(.card)
                .focused($focusedMeta, equals: scope + "|" + meta.id)
                // Only the FIRST catalogue rail's cards carry
                // the first-rail move handler (see
                // firstTorScope); the attachment follows the
                // catalogue data, never the focus state.
                if scope == firstTorScope {
                    card.onMoveCommand { dir in handleFirstRailMove(dir) }
                } else {
                    card
                }
            }
        }
    }

    private var searchGrid: some View {
        // Fixed 6 columns (§7.6: 6×264 + 5×28 = 1724 ≤ 1760) so
        // result routing is exact arithmetic, like JoeSearch.
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 28),
                                 count: 6),
                  alignment: .leading, spacing: 40) {
            ForEach(searchResults) { meta in
                Button { nav.tor = TorRoute(meta: meta, base: TorrentSettings.cinemeta) } label: {
                    PosterCard(
                        title: meta.name,
                        posterURL: meta.posterURL,
                        meta: meta.year,
                        focused: focusedMeta == "torSearch|" + meta.id)
                }
                .buttonStyle(.card)
                .focused($focusedMeta, equals: "torSearch|" + meta.id)
                .onMoveCommand { direction in
                    searchResultMove(direction, from: meta)
                }
            }
        }
    }

    /// Search-grid routing (C-2): the handler sits on each result,
    /// so it is active exactly while that result holds focus.
    /// Exact arithmetic over the fixed 6-column grid — UP from a
    /// first-row result returns to the search row, LEFT/RIGHT stop
    /// at row edges, DOWN past the last row is a defined no-op.
    /// (v1.8 routed the grid as a flat rail whose handler required
    /// a second rail for DOWN, so DOWN was swallowed everywhere.)
    private func searchResultMove(_ dir: MoveCommandDirection, from meta: TorMeta) {
        guard let idx = searchResults.firstIndex(where: { $0.id == meta.id })
        else { return }
        let columns = 6
        switch dir {
        case .left:
            if idx % columns > 0 {
                focusedMeta = "torSearch|" + searchResults[idx - 1].id
            }
        case .right:
            if idx + 1 < searchResults.count, idx % columns < columns - 1 {
                focusedMeta = "torSearch|" + searchResults[idx + 1].id
            }
        case .up:
            if idx >= columns {
                focusedMeta = "torSearch|" + searchResults[idx - columns].id
            } else {
                searchFocus = .field
            }
        case .down:
            if idx + columns < searchResults.count {
                focusedMeta = "torSearch|" + searchResults[idx + columns].id
            }
        @unknown default:
            break
        }
    }

    private func runSearch() {
        let kw = query.trimmingCharacters(in: .whitespaces)
        guard !kw.isEmpty else { return }
        searching = true
        searchError = nil
        Task {
            let searchable = store.catalogs.filter { $0.searchable }
            var out: [TorMeta] = []
            var failures = 0
            for cat in searchable {
                do {
                    out.append(contentsOf: try await TorrentClient.search(cat, keyword: kw))
                } catch {
                    failures += 1
                }
            }
            searchResults = out
            searching = false
            searchAttempted = true
            // C-10: "no catalogues to search" and "every search
            // failed" are explicit surfaces, not a silent empty.
            if searchable.isEmpty {
                searchError = "Chưa tải được danh mục — kiểm tra mạng rồi thử lại."
            } else if failures == searchable.count {
                searchError = "Không tải được kết quả tìm kiếm. Kiểm tra mạng rồi thử lại."
            }
        }
    }
}

/// Torrent title detail: hero, favourite toggle, episode list
/// (series), then the stream list for the chosen video — direct
/// links play at once, hash-only entries resolve through the
/// owner's Real-Debrid account at tap time.
struct JoeTorrentDetail: View {
    let route: TorRoute
    @EnvironmentObject private var watch: WatchStore
    @EnvironmentObject private var nav: JoeNavigator
    @Environment(\.joeTheme) private var theme
    @State private var videos: [TorVideo] = []
    @State private var selectedVideo: TorVideo?
    @State private var streams: [TorStream] = []
    @State private var loadingStreams = false
    @State private var videosFailed = false
    @State private var streamsFailed = false
    @State private var notice: String?
    @State private var hasViSub = false
    @State private var playerHolder: JoeMovieDetail.DirectorHolder?
    @FocusState private var focusedRow: String?

    private var meta: TorMeta { route.meta }
    private var favKey: String { WatchStore.torFavKey(metaId: meta.id, type: meta.type) }
    private var isFav: Bool { watch.isFavorite(key: favKey) }
    private var videoId: String { selectedVideo?.id ?? meta.id }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 32) {
                hero
                if meta.type == "series" {
                    episodeSection
                }
                streamSection
            }
            // No manual padding: the layer sits inside the root
            // safe area, which IS the §4 inset (80/60).
        }
        .task { await load() }
        .fullScreenCover(item: $playerHolder) { holder in
            JoePlayerView(director: holder.director,
                          filmTitle: holder.title,
                          filmEpisode: holder.episode,
                          sourceLine: holder.sourceLine)
        }
        // 1.9.2 (Team 9 items 4 + 9): Menu closes THIS detail
        // from its OWN root (the wrapper-handler lesson, same
        // as JoeMovieDetail), and the favourite button is the
        // declared initial focus — see favButton.
        .onExitCommand { nav.tor = nil }
        .defaultFocus($focusedRow, "fav")
    }

    // MARK: - Hero

    private var hero: some View {
        HStack(alignment: .top, spacing: 40) {
            ZStack {
                RoundedRectangle(cornerRadius: theme.rCard).fill(Color.black.opacity(0.45))
                if let url = meta.posterURL {
                    JoeRemoteImage(url: url, targetPixels: 720, fit: true) {
                        Text(meta.name)
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(theme.text.opacity(0.8))
                            .multilineTextAlignment(.center).padding(18)
                    }
                }
            }
            .frame(width: 240, height: 360)
            .clipShape(RoundedRectangle(cornerRadius: theme.rCard))
            .overlay(RoundedRectangle(cornerRadius: theme.rCard)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 2))

            VStack(alignment: .leading, spacing: 16) {
                Text(meta.name)
                    .font(.system(size: 64, weight: .heavy))
                    .foregroundStyle(theme.text)
                    .lineLimit(3)
                if !meta.year.isEmpty {
                    Text(meta.year)
                        .font(.system(size: 29))
                        .foregroundStyle(theme.meta)
                }
                HStack(spacing: 16) {
                    favButton
                    if hasViSub {
                        Text("Phụ đề Việt: có (OpenSubtitles)")
                            .font(.system(size: 25))
                            .foregroundStyle(theme.text.opacity(0.8))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(Color.white.opacity(0.10)))
                    }
                }
                if !meta.desc.isEmpty {
                    Text(meta.desc)
                        .font(.system(size: 29))
                        .foregroundStyle(theme.meta)
                        .lineSpacing(8)
                        .lineLimit(5)
                        .frame(maxWidth: 1050, alignment: .leading)
                }
                if let notice {
                    Text(notice)
                        .font(.system(size: 25))
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var favButton: some View {
        Button {
            var e = WatchStore.Entry()
            e.kind = WatchStore.kindTor
            e.key = favKey
            e.title = meta.name
            e.poster = meta.poster
            e.year = meta.year
            e.metaId = meta.id
            e.metaType = meta.type
            e.metaBase = route.base
            e.background = meta.background
            e.desc = meta.desc
            e.ts = Int64(Date().timeIntervalSince1970 * 1000)
            watch.toggleFavorite(e)
        } label: {
            Text(isFav ? "♥ Đã thích" : "♡ Yêu thích")
                .font(.system(size: 29, weight: .medium))
                .foregroundStyle(isFav ? JoeTheme.accentRed : .white)
                .padding(.horizontal, 36)
                .padding(.vertical, 16)
                .background(Capsule().fill(theme.surface2))
                .overlay(JoeFocusRing(shape: Capsule()))
        }
        .buttonStyle(.card)
        // 1.9.2 (Team 9 item 9): the button joins the detail's
        // FocusState and is its declared default focus. It was
        // the ONLY unbound focusable on this screen: for an
        // UNCONFIGURED title (no stream rows, no episodes) it
        // was also the only focusable element at all, so focus
        // never landed and the owner could not favourite such
        // a title — the toggle itself was never gated on
        // configuration. On configured titles the initial
        // landing is now this button (topmost action; one DOWN
        // reaches the stream rows) — accepted by the leader.
        .focused($focusedRow, equals: "fav")
    }

    // MARK: - Episodes (series)

    /// C-11: a failed videos fetch is a notice + Retry IN PLACE —
    /// v1.8 collapsed it to `?? []`, indistinguishable from a
    /// series with no episodes.
    @ViewBuilder
    private var episodeSection: some View {
        if videosFailed {
            VStack(alignment: .leading, spacing: 16) {
                Text("Không tải được danh sách tập.")
                    .font(.system(size: 25))
                    .foregroundStyle(.orange)
                retryButton(focusKey: "retry|videos") {
                    Task { await load() }
                }
            }
        } else {
            episodeList
        }
    }

    private func retryButton(focusKey: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            JoePrimaryLabel(title: "Thử lại")
        }
        .buttonStyle(.card)
        .focused($focusedRow, equals: focusKey)
    }

    @ViewBuilder
    private var episodeList: some View {
        if !videos.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("Tập")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(theme.text)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16)],
                          alignment: .leading, spacing: 16) {
                    ForEach(videos) { video in
                        let selected = videoId == video.id
                        Button {
                            selectedVideo = video
                            Task { await loadStreams() }
                        } label: {
                            Text(video.label)
                                .font(.system(size: 25, weight: selected ? .bold : .medium))
                                .foregroundStyle(theme.text)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 12)
                                .background(RoundedRectangle(cornerRadius: theme.rField)
                                    .fill(selected ? theme.accent.opacity(0.30)
                                          : theme.surface2))
                                .overlay(JoeFocusRing(shape: RoundedRectangle(cornerRadius: theme.rField)))
                        }
                        .buttonStyle(.card)
                        .focused($focusedRow, equals: "ep|" + video.id)
                    }
                }
            }
        }
    }

    // MARK: - Streams

    @ViewBuilder
    private var streamSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Nguồn phát")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(theme.text)
            if loadingStreams {
                ProgressView("Đang lấy nguồn…")
                    .font(.system(size: 29))
                    .foregroundStyle(theme.text)
                    .tint(.white)
            } else if streamsFailed {
                // C-11: "the fetch failed" is its own surface
                // with a Retry — never the empty copy below.
                VStack(alignment: .leading, spacing: 16) {
                    Text("Không lấy được nguồn phát. Kiểm tra mạng rồi thử lại.")
                        .font(.system(size: 25))
                        .foregroundStyle(.orange)
                    retryButton(focusKey: "retry|streams") {
                        Task { await loadStreams() }
                    }
                }
            } else if streams.isEmpty {
                Text(TorrentSettings.isConfigured
                     ? "Chưa có nguồn phát."
                     : "Chưa cấu hình nguồn — vào Cài đặt nhập link Torrentio hoặc token Real-Debrid/TorBox.")
                    .font(.system(size: 25))
                    .foregroundStyle(theme.meta)
            } else {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(streams) { stream in
                        streamRow(stream)
                    }
                }
            }
        }
    }

    private func streamRow(_ stream: TorStream) -> some View {
        let focused = focusedRow == "st|" + stream.id.uuidString
        return Button {
            play(stream)
        } label: {
            HStack(spacing: 16) {
                Text(streamTag(stream))
                    .font(.system(size: 23, weight: .heavy))
                    .foregroundStyle(theme.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(stream.playable
                                               ? JoeTheme.okGreen.opacity(0.35)
                                               : Color.orange.opacity(0.35)))
                VStack(alignment: .leading, spacing: 3) {
                    Text(stream.label)
                        .font(.system(size: 29, weight: .semibold))
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                    if !stream.title.isEmpty && stream.title != stream.label {
                        Text(stream.title)
                            .font(.system(size: 25))
                            .foregroundStyle(theme.meta)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            // §7.6: stream rows are the one sanctioned outline-only
            // focus variant — the fill NEVER changes on focus (the
            // old white 0.06→0.13 brightening was a focus wash).
            // v2.0.0: the fill is the theme's surface token and
            // the outline is the theme ring (value-only).
            .background(RoundedRectangle(cornerRadius: theme.rField)
                .fill(theme.surface2))
            .overlay(RoundedRectangle(cornerRadius: theme.rField)
                .strokeBorder(focused ? theme.focus : Color.clear,
                              lineWidth: focused ? theme.ringWidth : 0))
        }
        .buttonStyle(.card)
        .focused($focusedRow, equals: "st|" + stream.id.uuidString)
    }

    private func streamTag(_ s: TorStream) -> String {
        if s.playable { return "PHÁT NGAY" }
        if !s.infoHash.isEmpty { return "RD · GIẢI LINK" }
        return "TORRENT"
    }

    // MARK: - Loading + playing

    private func load() async {
        if meta.type == "series" {
            do {
                videos = try await TorrentClient.fetchVideos(
                    metaBase: route.base, type: meta.type, id: meta.id)
                videosFailed = false
            } catch {
                videos = []
                videosFailed = true
            }
            if let pre = route.preselectStreamId.isEmpty ? nil
                : videos.first(where: { $0.id == route.preselectStreamId }) {
                selectedVideo = pre
            } else {
                selectedVideo = videos.first
            }
        }
        await loadStreams()
    }

    private func loadStreams() async {
        guard let base = TorrentSettings.effectiveBase else {
            streams = []
            streamsFailed = false
            return
        }
        loadingStreams = true
        defer { loadingStreams = false }
        do {
            streams = try await TorrentClient.fetchStreams(
                addonBase: base, type: meta.type, id: videoId)
            streamsFailed = false
        } catch {
            streams = []
            streamsFailed = true
        }
        let subs = await TorrentClient.fetchSubtitles(
            base: TorrentSettings.subtitleBase(addonBase: base),
            type: meta.type, id: videoId)
        hasViSub = TorrentClient.bestVietnamese(subs) != nil
    }

    private func play(_ stream: TorStream) {
        let sid = videoId
        var entry = WatchStore.Entry()
        entry.kind = WatchStore.kindTor
        entry.key = WatchStore.torProgressKey(streamId: sid)
        entry.ep = selectedVideo?.label ?? ""
        entry.epLabel = selectedVideo.map { "Đang xem: \($0.label)" } ?? ""
        entry.title = meta.name
        entry.poster = meta.poster
        entry.year = meta.year
        entry.metaId = meta.id
        entry.metaType = meta.type
        entry.streamId = sid
        entry.metaBase = route.base
        entry.background = meta.background
        entry.desc = meta.desc
        let resume = watch.progressFor(key: entry.key)?.pos ?? 0
        let tapped = stream
        let type = meta.type
        let director = PlayDirector(
            store: watch,
            identity: PlayIdentity(entry: entry),
            resumeMs: resume,
            resolveLadder: { identity in
                guard let base = TorrentSettings.effectiveBase else { return [] }
                let fresh = (try? await TorrentClient.fetchStreams(
                    addonBase: base, type: type, id: identity.entry.streamId)) ?? []
                // The shared conversion (TorrentClient): the
                // tapped stream leads — a hash entry earns its
                // ONE Real-Debrid resolution there — then any
                // direct-URL streams in list order.
                return await TorrentClient.playCandidates(
                    streams: fresh, preferred: tapped)
            },
            hopIdentity: nil)
        playerHolder = JoeMovieDetail.DirectorHolder(
            director: director,
            title: meta.name,
            episode: selectedVideo?.label ?? "",
            sourceLine: "Nguồn: Torrent")
    }
}

// CONVERGENCE RECORD (2026-11-15): this file's duplicated
// JoeMoveTrap struct is DELETED — see the record at the end of
// JoeTVApp.swift. The search-row/first-rail/Retry traps it
// powered are replaced by geometric focus movement plus the
// per-card always-installed first-rail handler above.
