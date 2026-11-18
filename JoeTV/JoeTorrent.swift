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
            // under the focus engine.
            // v2.0.8 (Phase 1): the first rail's surviving
            // arithmetic handler (handleFirstRailMove) is now
            // REMOVED too, with the search grid's handler. An
            // attached .onMoveCommand owns EVERY direction and
            // undeclared directions die instead of falling
            // through to the focus engine, so routing is now
            // entirely the engine's geometric search: the
            // search row, the Retry buttons and the rails are
            // plain focusable elements in one stack, each rail
            // a .focusSection() via the shared Rail view, so
            // UP/DOWN/LEFT/RIGHT between them is geometric
            // (the search row's LEFT/RIGHT order — field → Tìm
            // → Xoá — is its visual order; a disabled Tìm
            // during search is skipped by the engine).
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
            .joeCardButton()
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
                .joeCardButton()
                .focused($searchFocus, equals: .clear)
            }
        }
        // v2.0.5 (N1, pair g): the search row is a declared
        // focus region; the rails below are regions of their
        // own (the shared Rail carries .focusSection()).
        // v2.0.8: no handler declares an UP landing back onto
        // this row any more — the engine's geometric search
        // finds this region from the rails below on its own.
        .focusSection()
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
                            form: .rail)
                    }
                    .joeCardButton()
                    .focused($focusedEntry, equals: "cw|" + entry.key)
                    .contextMenu {
                        Button(role: .destructive) {
                            watch.removeProgress(key: entry.key)
                        } label: {
                            Text("Xoá khỏi Đang xem dở")
                        }
                    }
                    // v2.0.8 (Phase 1): no move handler — the
                    // card is a plain focusable in its rail's
                    // .focusSection(); movement is geometric.
                    card
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
                            form: .rail)
                    }
                    .joeCardButton()
                    .focused($focusedEntry, equals: "fav|" + entry.key)
                    .contextMenu {
                        Button(role: .destructive) {
                            watch.removeFavorite(key: entry.key)
                        } label: {
                            Text("Bỏ yêu thích")
                        }
                    }
                    // v2.0.8 (Phase 1): no move handler (the
                    // first-rail arithmetic that used to attach
                    // here when Continue Watching was empty is
                    // removed) — movement is geometric.
                    card
                }
            }
        }
    }

    // v2.0.8 (Phase 1): the first-rail routing model that
    // lived here (TorRailItem / torRails, under a "Focus
    // traversal" mark) is DELETED with its handler — nothing
    // in this file routes focus by hand any more; the
    // engine's geometric search over the declared
    // .focusSection() regions owns all movement.

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
            .joeCardButton()
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
                .joeCardButton()
                .focused($searchRetryFocused)
            }
        } else {
            Text("Không tìm thấy kết quả nào.")
                .font(.system(size: 29))
                .foregroundStyle(theme.meta)
        }
    }

    // v2.0.8 (Phase 1): currentTorRailItem /
    // firstRailFocusIndex / firstTorScope / setTorRailFocus
    // are DELETED with handleFirstRailMove below — they
    // existed only to feed the first-rail arithmetic. The
    // @FocusState declarations themselves stay: their
    // .focused bindings still give every card its focus
    // identity for the engine (and its per-screen memory).

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

    // v2.0.8 (Phase 1): handleFirstRailMove is DELETED. Its
    // UP landing (the search field), its LEFT/RIGHT rail
    // neighbours and its DOWN same-index landing in the next
    // rail are all moves the focus engine's geometric search
    // makes unaided inside the rails' .focusSection()
    // regions; the single-rail DOWN landing on the error
    // surface's Retry is likewise the nearest focusable
    // below. No direction is hand-routed in this file now.

    private func metaRail(_ title: String, _ metas: [TorMeta], base: String,
                          scope: String) -> some View {
        Rail(title: title) {
            ForEach(metas) { meta in
                let card = Button { nav.tor = TorRoute(meta: meta, base: base) } label: {
                    PosterCard(
                        title: meta.name,
                        posterURL: meta.posterURL,
                        meta: meta.year,
                        form: .rail)
                }
                .joeCardButton()
                .focused($focusedMeta, equals: scope + "|" + meta.id)
                // v2.0.8 (Phase 1): no move handler on any
                // catalogue rail (the first rail's used to
                // attach here) — movement is geometric.
                card
            }
        }
    }

    private var searchGrid: some View {
        // Fixed 6 columns (§7.6: 6×264 + 5×28 = 1724 ≤ 1760).
        // v2.0.8: the fixed columns now serve the focus
        // engine's geometric search (a regular grid gives it
        // clean candidates), not a hand-written router.
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 28),
                                 count: 6),
                  alignment: .leading, spacing: 40) {
            ForEach(searchResults) { meta in
                Button { nav.tor = TorRoute(meta: meta, base: TorrentSettings.cinemeta) } label: {
                    PosterCard(
                        title: meta.name,
                        posterURL: meta.posterURL,
                        meta: meta.year)
                }
                .joeCardButton()
                .focused($focusedMeta, equals: "torSearch|" + meta.id)
                // v2.0.8 (Phase 1): no move handler — the
                // grid's movement (including UP from the
                // first row back to the search row) is the
                // engine's geometric search.
            }
        }
        // Design D's wall ring is an OUTSET band around the
        // art (6 pt): under D the grid takes edge clearance
        // past it so the outer columns' rings are never
        // clipped by the scroll frame.
        .padding(.horizontal, theme.id == .posterWall ? 8 : 0)
    }

    // v2.0.8 (Phase 1): searchResultMove is DELETED (C-2's
    // arithmetic grid router). It was NOT a composite
    // control — it handled plain grid cards and coded DOWN
    // past the last row as a no-op — so no exception
    // applies: the grid's movement is geometric now, and
    // UP from a first-row result reaches the search row as
    // the nearest focusable above.

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
    /// v2.0.16: the best Vietnamese subtitle itself (not only
    /// the hasViSub flag) — play() attaches it to every ladder
    /// candidate so the player loads it beside the embedded
    /// tracks.
    @State private var viSubtitleURL: URL?
    @State private var playerHolder: JoeMovieDetail.DirectorHolder?
    @FocusState private var focusedRow: String?

    private var meta: TorMeta { route.meta }
    private var favKey: String { WatchStore.torFavKey(metaId: meta.id, type: meta.type) }
    private var isFav: Bool { watch.isFavorite(key: favKey) }
    private var videoId: String { selectedVideo?.id ?? meta.id }

    var body: some View {
        Group {
            // v2.0.19 (Ultra): the Phim4K composition — full-bleed
            // backdrop, title bottom-left, frosted Chọn Server
            // panel on the right. Every other theme keeps the
            // standard single-column body below; state, load logic
            // and actions are shared, only the composition moves.
            if theme.id == .ultra {
                ultraBody
            } else {
                standardBody
            }
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

    private var standardBody: some View {
        ScrollView(.vertical, showsIndicators: false) {
            // v2.0.8 (Phase 7d): LazyVStack — the eager VStack
            // built the hero, episode block and stream block
            // (and every stream row) up front; children,
            // order and spacing are identical.
            LazyVStack(alignment: .leading, spacing: 32) {
                hero
                if meta.type == "series" {
                    // v2.0.5 (N1, pair i): the episode block
                    // and the stream block are declared focus
                    // regions inside the detail's single column.
                    episodeSection
                        .focusSection()
                }
                streamSection
                    .focusSection()
            }
            // No manual padding: the layer sits inside the root
            // safe area, which IS the §4 inset (80/60).
        }
    }

    // MARK: - Ultra composition (v2.0.19)

    /// Full-bleed backdrop for the Ultra torrent detail: the
    /// portrait poster as a blur field first, the Cinemeta
    /// landscape background sliced over it when present, then
    /// the same left + vertical scrims as the Ultra movie
    /// detail, so the title block and the panel stay readable.
    private var ultraTorBackdrop: some View {
        ZStack {
            if let url = meta.posterURL {
                JoeBandImage(url: url, targetPixels: 1920,
                             anchor: 0.16, portraitMode: .blurField)
            }
            if !meta.background.isEmpty,
               let u = URL(string: meta.background), u != meta.posterURL {
                JoeBandImage(url: u, targetPixels: 1920,
                             anchor: 0.16, portraitMode: .slice)
            }
            LinearGradient(stops: [
                .init(color: .black.opacity(0.85), location: 0),
                .init(color: .black.opacity(0.40), location: 0.5),
                .init(color: .black.opacity(0.05), location: 1)
            ], startPoint: .leading, endPoint: .trailing)
            LinearGradient(stops: [
                .init(color: .black.opacity(0.30), location: 0),
                .init(color: .clear, location: 0.35),
                .init(color: theme.bg.opacity(0.88), location: 0.85),
                .init(color: theme.bg, location: 1)
            ], startPoint: .top, endPoint: .bottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var ultraBody: some View {
        ZStack {
            ultraTorBackdrop
            HStack(alignment: .bottom, spacing: 40) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(meta.name)
                        .font(.system(size: 54, weight: .heavy))
                        .foregroundStyle(theme.text)
                        .lineLimit(3)
                    if !meta.year.isEmpty {
                        Text(meta.year)
                            .font(.system(size: 29, weight: .bold))
                            .foregroundStyle(theme.heroMeta)
                    }
                    if !meta.desc.isEmpty {
                        Text(meta.desc)
                            .font(.system(size: 25))
                            .foregroundStyle(theme.text.opacity(0.85))
                            .lineSpacing(6)
                            .lineLimit(4)
                    }
                }
                .frame(maxWidth: 600, alignment: .leading)
                Spacer(minLength: 0)
                ultraPanel
            }
            .frame(maxHeight: .infinity)
        }
    }

    /// The frosted Chọn Server panel: favourite row, the
    /// episode block (series) and the stream block, inside a
    /// translucent plate — the Sony 2.3.31 row-10 composition
    /// carried to tvOS.
    private var ultraPanel: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 22) {
                Text("Chọn Server")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(theme.text)
                    .frame(maxWidth: .infinity, alignment: .center)
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
                if let notice {
                    Text(notice)
                        .font(.system(size: 25))
                        .foregroundStyle(.orange)
                }
                if meta.type == "series" {
                    episodeSection
                        .focusSection()
                }
                streamSection
                    .focusSection()
            }
            .padding(36)
        }
        .frame(width: 1040)
        .background(RoundedRectangle(cornerRadius: 24)
            .fill(Color.white.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 24)
            .strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 24))
    }

    // MARK: - Hero

    private var hero: some View {
        HStack(alignment: .top, spacing: 40) {
            ZStack {
                RoundedRectangle(cornerRadius: theme.rCard).fill(Color.black.opacity(0.45))
                if let url = meta.posterURL {
                    // v2.0.5 (N6): the portrait aspect gate, as
                    // on every other 2:3 slot — a landscape
                    // bitmap in this frame is rejected instead
                    // of letterboxing into a band. TorMeta
                    // carries no TMDB identity (its id is the
                    // Cinemeta/IMDb id), so there is no TMDB
                    // fallback leg here; the placeholder stands.
                    JoeRemoteImage(url: url, targetPixels: 720, fit: true,
                                   slotClass: .portrait) {
                        Text(meta.name)
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(theme.text.opacity(0.8))
                            .multilineTextAlignment(.center).padding(18)
                    }
                }
            }
            .frame(width: 240, height: 360)
            .clipShape(RoundedRectangle(cornerRadius: theme.rCard))
            // The hairline is an INSIDE strokeBorder (the
            // v2.0.6 outset band is retired on this frame —
            // the torrent surfaces carry no drawing of their
            // own, and the inside form is the system's resting
            // frame treatment outside the two drawn outset
            // rings: the field's and design D's wall art).
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
        .joeCardButton()
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
        // v2.0.8 (Phase 1): the declared DOWN exit
        // (.joeBoundaryMove → favDownLanding) is REMOVED,
        // and favDownLanding with it. The button is the
        // layer's top element and alone in its row (the
        // subtitle capsule beside it is not focusable); DOWN
        // from it is the engine's geometric move to the
        // nearest focusable below — the episode block's
        // first chip, a failure surface's Retry, or the
        // first stream row, each inside its declared
        // .focusSection() region.
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
        .joeCardButton()
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
                        .joeCardButton()
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
                Text(TorrentSettings.isConfigured || TorrentSettings.mfBase != nil
                     ? "Chưa có nguồn phát."
                     : "Chưa cấu hình nguồn — vào Cài đặt nhập link Torrentio, token Real-Debrid/TorBox hoặc link MediaFusion.")
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
        Button {
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
                    if theme.id == .ultra {
                        // v2.0.19: the Sony panel's tech-spec +
                        // language lines, parsed ONLY from
                        // tokens the stream's own name/title
                        // states — nothing inferred.
                        let spec = Self.ultraSpec(stream)
                        if !spec.line.isEmpty {
                            Text(spec.line)
                                .font(.system(size: 23))
                                .foregroundStyle(theme.text.opacity(0.78))
                                .lineLimit(1)
                        }
                        if !spec.lang.isEmpty {
                            Text(spec.lang)
                                .font(.system(size: 23, weight: .semibold))
                                .foregroundStyle(theme.heroMeta)
                                .lineLimit(1)
                        }
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
            // v2.0.3: the outline is the shared JoeFocusRing
            // primitive — the same shape instance geometry as the
            // fill (rField), drawn inside the row's own bounds,
            // environment-driven like every other control in the
            // app (the hand-rolled copy here keyed off the
            // parent's FocusState instead).
            .background(RoundedRectangle(cornerRadius: theme.rField)
                .fill(theme.id == .ultra
                      ? Color.white.opacity(0.16) : theme.surface2))
            .overlay(JoeFocusRing(shape: RoundedRectangle(cornerRadius: theme.rField)))
        }
        .joeCardButton()
        .focused($focusedRow, equals: "st|" + stream.id.uuidString)
    }

    private func streamTag(_ s: TorStream) -> String {
        // v2.0.16: a playable row whose debrid is still
        // fetching the release says so (the pooled ranking
        // already sorts it below the cached rows).
        if s.playable { return s.awaitingDisplay ? "CHỜ DEBRID" : "PHÁT NGAY" }
        if !s.infoHash.isEmpty { return "RD · GIẢI LINK" }
        return "TORRENT"
    }

    /// v2.0.19 (Ultra): the server row's spec + language lines.
    /// Every token is read from the stream's OWN name/title text
    /// (the Torrentio grammar carries 💾 size and 👤 seeders in
    /// the title) — a fact the text does not state is never
    /// shown. Mirrors the Sony Feat tokenizer's honesty rule.
    private static func ultraSpec(_ s: TorStream) -> (line: String, lang: String) {
        let raw = s.name + " " + s.title
        let up = raw.uppercased()
        func has(_ tokens: [String]) -> Bool {
            tokens.contains { up.contains($0) }
        }
        var parts: [String] = []
        if has(["2160P", "2160", "4K"]) { parts.append("4K") }
        else if has(["1080P", "1080"]) { parts.append("1080p") }
        else if has(["720P", "720"]) { parts.append("720p") }
        if up.contains("REMUX") { parts.append("REMUX") }
        else if has(["BLURAY", "BLU-RAY", "BDRIP"]) { parts.append("BluRay") }
        else if has(["WEB-DL", "WEBDL"]) { parts.append("WEB-DL") }
        else if up.contains("WEBRIP") { parts.append("WEBRip") }
        else if up.contains("HDTV") { parts.append("HDTV") }
        if has(["DOLBY VISION", "DOVI", ".DV.", ".DV "]) {
            parts.append("Dolby Vision")
        }
        else if up.contains("HDR10+") { parts.append("HDR10+") }
        else if up.contains("HDR10") { parts.append("HDR10") }
        else if up.contains("HDR") { parts.append("HDR") }
        if has(["X265", "HEVC", "H.265", "H265"]) { parts.append("HEVC") }
        else if has(["X264", "AVC", "H.264", "H264"]) { parts.append("AVC") }
        else if up.contains("AV1") { parts.append("AV1") }
        if up.contains("TRUEHD") { parts.append("TrueHD") }
        if up.contains("ATMOS") { parts.append("Atmos") }
        if has(["DTS-HD", "DTSHD"]) { parts.append("DTS-HD") }
        else if up.contains("DTS") { parts.append("DTS") }
        if has(["DDP", "EAC3", "E-AC-3", "DD+"]) { parts.append("DD+") }
        else if up.contains("AAC") { parts.append("AAC") }
        // 💾 size / 👤 seeders, copied verbatim from the title.
        if let r = raw.range(of: "💾") {
            let words = raw[r.upperBound...]
                .split(whereSeparator: { $0 == " " || $0 == "\n" })
                .prefix(2).map(String.init)
            if !words.isEmpty { parts.append(words.joined(separator: " ")) }
        }
        if let r = raw.range(of: "👤") {
            let words = raw[r.upperBound...]
                .split(whereSeparator: { $0 == " " || $0 == "\n" })
                .prefix(1).map(String.init)
            if let n = words.first { parts.append("👤 " + n) }
        }
        var langs: [String] = []
        if has(["VIETSUB", "VIET SUB", "VI.SUB"]) { langs.append("Vietsub") }
        if has(["THUYET MINH", "THUYẾT MINH"]) { langs.append("Thuyết minh") }
        if has(["LONG TIENG", "LỒNG TIẾNG"]) { langs.append("Lồng tiếng") }
        if has(["ENGSUB", "ENG SUB"]) { langs.append("EngSub") }
        if up.contains("MULTI") { langs.append("MultiSub") }
        return (parts.joined(separator: " · "),
                langs.joined(separator: " · "))
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
        let torBase = TorrentSettings.effectiveBase
        let mfBase = TorrentSettings.mfBase
        guard torBase != nil || mfBase != nil else {
            streams = []
            streamsFailed = false
            return
        }
        loadingStreams = true
        defer { loadingStreams = false }
        // v2.0.16: the pooled fetch — Torrentio + MediaFusion
        // in parallel, deduped to one row per release, ranked
        // best-first, cut to 30 (the Sony 2.3.16 form the
        // owner approved). The error surface stays honest:
        // it shows only when the Torrentio leg failed AND
        // nothing came back from either gateway.
        let pooled = await TorrentClient.fetchPooledStreams(
            torrentioBase: torBase, mfBase: mfBase,
            type: meta.type, id: videoId)
        streams = pooled.streams
        streamsFailed = pooled.primaryFailed && pooled.streams.isEmpty
        let subs = await TorrentClient.fetchSubtitles(
            base: TorrentSettings.subtitleBase(addonBase: torBase ?? mfBase ?? ""),
            type: meta.type, id: videoId)
        let bestVi = TorrentClient.bestVietnamese(subs)
        hasViSub = bestVi != nil
        viSubtitleURL = bestVi.flatMap { URL(string: $0.url) }
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
        let viURL = viSubtitleURL
        let director = PlayDirector(
            store: watch,
            identity: PlayIdentity(entry: entry),
            resumeMs: resume,
            resolveLadder: { identity in
                // v2.0.16: the ladder re-fetches the SAME
                // pooled list the rows came from (Torrentio +
                // MediaFusion, ranked) — pre-fix it re-asked
                // Torrentio alone, so a tapped MediaFusion row
                // was not even present in its own ladder. The
                // shared conversion (TorrentClient): the tapped
                // stream leads — a hash entry earns its ONE
                // Real-Debrid resolution there — then any
                // direct-URL streams in list order.
                let pooled = await TorrentClient.fetchPooledStreams(
                    torrentioBase: TorrentSettings.effectiveBase,
                    mfBase: TorrentSettings.mfBase,
                    type: type, id: identity.entry.streamId)
                var cands = await TorrentClient.playCandidates(
                    streams: pooled.streams, preferred: tapped)
                // The session's Vietnamese subtitle rides
                // every candidate, so failover keeps it.
                if let viURL {
                    for i in cands.indices { cands[i].subtitleURL = viURL }
                }
                return cands
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
// powered are replaced by geometric focus movement.
// v2.0.8 (Phase 1): the per-card first-rail handler that
// briefly survived that record, the search grid's handler
// and the favourite button's boundary move are now deleted
// too — this file carries no .onMoveCommand and no
// .joeBoundaryMove; all movement is the engine's geometric
// search over the declared .focusSection() regions.
