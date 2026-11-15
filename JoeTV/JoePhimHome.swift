import SwiftUI

/// Route into a movie detail, from any rail or search result.
struct MovieRoute: Hashable {
    var provider: String
    var slug: String
    var name: String
    var poster: String
    var year: String
    /// Episode to preselect (Continue Watching taps).
    var preselectEp: String = ""
}

/// The Phim home: the owner's aggregated library — KKPhim +
/// Film4K.net + VSMOV behind one screen, exactly like the
/// Android app he verified (v1.5.1 shape, RapPhim removed by his
/// 2026-11-14 order; Film4K.net added from the same night's link
/// hunt). Continue Watching + Favorites lead (from WatchStore),
/// then the merged rail, then per-provider rails. Every tile
/// carries its provider badge so the sources never blur.
struct JoePhimHome: View {
    @EnvironmentObject private var watch: WatchStore
    @EnvironmentObject private var nav: JoeNavigator
    @EnvironmentObject private var phim: PhimStore
    @FocusState private var focusedMovie: Movie.ID?
    @FocusState private var focusedEntry: String?
    @FocusState private var headerFocused: Bool
    @FocusState private var retryFocused: Bool
    /// Team 4 fix-round minor: the state surfaces (G3/G5) are
    /// gated on "a load has been attempted" so they cannot flash
    /// for a frame at cold entry, before the first loadIfNeeded
    /// has even run (at that instant loading == false and the
    /// catalogue is trivially empty).
    @State private var attempted = false

    var body: some View {
        Group {
            if nav.searchOpen {
                JoeSearchView()
            } else {
                grid
            }
        }
        .task {
            attempted = true
            phim.loadIfNeeded()
        }
        // CONVERGENCE (spec item 3, 2026-11-15): the focus-hub
        // consumer that used to sit here (onChange of
        // nav.focusNonce → headerFocused = true) is REMOVED —
        // no programmatic focus writes on the launch path.
        // DOWN from the pills lands on the header geometrically.
    }

    private var grid: some View {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 40) {
                    header
                    cwRail
                    favRail
                    if !phim.merged.isEmpty {
                        movieRail("✨ Mới cập nhật · Tổng hợp", phim.merged, badges: true, scope: "merged")
                    }
                    if !phim.chieuRap.isEmpty {
                        movieRail("🔥 Phim chiếu rạp", phim.chieuRap, badges: true, scope: "chieuRap")
                    }
                    if !phim.vietnamAll.isEmpty {
                        movieRail("🇻🇳 Phim Việt Nam", phim.vietnamAll, badges: true, scope: "vnAll")
                    }
                    if !phim.vietnamSeries.isEmpty {
                        movieRail("🇻🇳 Phim bộ Việt Nam", phim.vietnamSeries, badges: true, scope: "vnSeries")
                    }
                    if !phim.vietnamSingle.isEmpty {
                        movieRail("🇻🇳 Phim lẻ Việt Nam", phim.vietnamSingle, badges: true, scope: "vnSingle")
                    }
                    ForEach(Array(PhimStore.genreSpec.enumerated()), id: \.offset) { _, spec in
                        if let list = phim.genreLists[spec.slug], !list.isEmpty {
                            movieRail(spec.title, list, badges: true, scope: "genre:" + spec.slug)
                        }
                    }
                    ForEach(Array(PhimStore.countrySpec.enumerated()), id: \.offset) { _, spec in
                        if let list = phim.countryLists[spec.slug], !list.isEmpty {
                            movieRail(spec.title, list, badges: true, scope: "country:" + spec.slug)
                        }
                    }
                    if !phim.kkNew.isEmpty {
                        movieRail("✨ Mới cập nhật", phim.kkNew, badges: false, scope: "kkNew")
                    }
                    if !phim.kkSeries.isEmpty {
                        movieRail("📺 Phim bộ mới", phim.kkSeries, badges: false, scope: "kkSeries")
                    }
                    if !phim.kkMovies.isEmpty {
                        movieRail("🎞️ Phim lẻ mới", phim.kkMovies, badges: false, scope: "kkMovies")
                    }
                    if !phim.kkAnime.isEmpty {
                        movieRail("🐣 Hoạt hình", phim.kkAnime, badges: false, scope: "kkAnime")
                    }
                    if !phim.f4kNew.isEmpty {
                        movieRail("✨ Film4K · Mới cập nhật", phim.f4kNew, badges: false, scope: "f4kNew")
                    }
                    if !phim.f4kMovies.isEmpty {
                        movieRail("🎞️ Film4K · Phim lẻ mới", phim.f4kMovies, badges: false, scope: "f4kMovies")
                    }
                    if !phim.vsNew.isEmpty {
                        movieRail("🎬 VSMOV · Mới cập nhật", phim.vsNew, badges: false, scope: "vsNew")
                    }
                    if !phim.vsSeries.isEmpty {
                        movieRail("🎬 VSMOV · Phim bộ mới", phim.vsSeries, badges: false, scope: "vsSeries")
                    }
                    if !phim.tpMovies.isEmpty {
                        movieRail("📚 Tủ Phim · Phim lẻ mới", phim.tpMovies, badges: false, scope: "tpMovies")
                    }
                    if !phim.tpSeries.isEmpty {
                        movieRail("📚 Tủ Phim · Phim bộ mới", phim.tpSeries, badges: false, scope: "tpSeries")
                    }
                    // §8/G1: the spinner exists only while a load
                    // is running, nothing has landed, and the 20 s
                    // store deadline has not fired — never longer.
                    if catalogueEmpty && phim.loading && !phim.loadTimedOut {
                        ProgressView("Đang tải thư viện phim…")
                            .font(.system(size: 29))
                            .foregroundStyle(.white)
                            .tint(.white)
                            .padding(.top, 30)
                    }
                    // §8/G3 + C-8 + BLOCK-2: the error surface
                    // shows ONLY when no catalogue rail has data
                    // (never under healthy rails), and only in
                    // Team 4's two failure states — the deadline
                    // fired, or the load ended with real provider
                    // errors. An all-empty SUCCESS is G5 below,
                    // not an error (spec-wins ruling (d)).
                    if showPhimError {
                        errorSurface
                    }
                    // §8/G5: every provider answered, nothing
                    // failed, the catalogue is simply empty —
                    // message only, no spinner, no Retry.
                    if showPhimEmpty {
                        Text("Thư viện chưa có dữ liệu.")
                            .font(.system(size: 29))
                            .foregroundStyle(.white.opacity(0.7))
                            .padding(.top, 30)
                    }
                    // §8/G4: partial failure — content renders,
                    // one non-focusable warning line at the very
                    // bottom names the providers with no content.
                    if phim.hasData && !failedProviders.isEmpty {
                        Text("Chưa tải được: " + failedProviders.joined(separator: ", "))
                            .font(.system(size: 25))
                            .foregroundStyle(.orange)
                    }
                }
            }
            // CONVERGENCE (Team 7 D4, 2026-11-15): the three
            // JoeMoveTrap modifiers that wrapped this ScrollView
            // (enabled by headerFocused / firstRailFocusIndex /
            // retryFocused) are REMOVED — each flip rebuilt the
            // ENTIRE ScrollView subtree under the focus engine.
            // Routing now: header and Retry are plain focusable
            // elements in the stack, so UP/DOWN between them and
            // the pills is geometric; the first rail's exact
            // arithmetic routing survives as an ALWAYS-installed
            // .onMoveCommand on the first rail's own cards (see
            // handleFirstRailMove), the codebase's per-element
            // shape that never fed back into the tree's identity.
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 28) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Thư viện phim")
                    .font(.system(size: 56, weight: .heavy))
                    .foregroundStyle(.white)
                Text("KKPhim · Film4K · VSMOV · Tủ Phim — link được lấy mới mỗi lần bấm xem")
                    .font(.system(size: 25))
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
            Button {
                nav.searchOpen = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                    Text("Tìm phim")
                }
                .font(.system(size: 29, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 26)
                .padding(.vertical, 14)
                .background(Capsule().fill(headerFocused ? JoeTheme.accentViolet
                                           : JoeTheme.surface))
                .overlay(JoeFocusRing(shape: Capsule()))
                .scaleEffect(headerFocused ? 1.05 : 1.0)
            }
            .buttonStyle(.card)
            .focusEffectDisabled(true)
            .focused($headerFocused)
        }
    }

    // MARK: - Load states (§8)

    /// True when NO catalogue rail has anything — the C-8
    /// condition for the error surface (CW/Favourites are the
    /// owner's own data, not catalogue health).
    private var catalogueEmpty: Bool {
        phim.merged.isEmpty && phim.chieuRap.isEmpty && phim.vietnamAll.isEmpty
            && phim.kkNew.isEmpty && phim.kkSeries.isEmpty && phim.kkMovies.isEmpty
            && phim.kkAnime.isEmpty && phim.f4kNew.isEmpty && phim.f4kMovies.isEmpty
            && phim.vsNew.isEmpty && phim.vsSeries.isEmpty
            && phim.tpMovies.isEmpty && phim.tpSeries.isEmpty
            && phim.genreLists.values.allSatisfy { $0.isEmpty }
            && phim.countryLists.values.allSatisfy { $0.isEmpty }
    }

    /// Team 4's BLOCK-2 predicate (spec-wins over the old board
    /// contract): G3 fires when the store deadline fired
    /// (loadTimedOut — possibly with jobs still in flight), OR
    /// when a load has ENDED with real provider errors on record.
    /// C-8 still applies: never while any catalogue rail has
    /// data. The attempted gate (fix-round minor) keeps the
    /// surface from flashing at cold entry, before the first
    /// load has run.
    private var showPhimError: Bool {
        attempted && catalogueEmpty
            && (phim.loadTimedOut
                || (!phim.loading && !phim.providerErrors.isEmpty))
    }

    /// §8/G5: the load ended, nothing timed out, NO provider
    /// errored, and the catalogue is still empty — every source
    /// answered empty-but-valid. Its own quiet surface: no
    /// spinner, no Retry (nothing failed, so there is nothing
    /// for a retry to fix).
    private var showPhimEmpty: Bool {
        attempted && catalogueEmpty && !phim.loading
            && !phim.loadTimedOut && phim.providerErrors.isEmpty
    }

    /// G4's failed-provider names, from the store's own error
    /// attribution: providerErrors holds an entry exactly while
    /// that provider's latest load failed (it clears when one of
    /// its rails lands). A provider that answered empty-but-valid
    /// has no entry and is correctly NOT named — the earlier
    /// rail-emptiness heuristic could not tell the two apart.
    private var failedProviders: [String] {
        guard !phim.loading, phim.hasData else { return [] }
        return ["kk", "f4k", "vsmov", "tp"]
            .filter { phim.providerErrors[$0] != nil }
            .map(providerDisplayName)
    }

    private func providerDisplayName(_ code: String) -> String {
        switch code {
        case "kk": return "KKPhim"
        case "f4k": return "Film4K"
        case "vsmov": return "VSMOV"
        case "tp": return "Tủ Phim"
        default: return code
        }
    }

    /// The one G3 error shape: warning icon, message, cause,
    /// Retry primary button.
    private var errorSurface: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
            Text("Không tải được thư viện phim.")
                .font(.system(size: 29, weight: .semibold))
                .foregroundStyle(.white)
            Text(phim.loadTimedOut
                 ? "Quá 20 giây chưa có dữ liệu. Kiểm tra mạng và profile Sing-box trên Apple TV."
                 : "Các nguồn phim đều lỗi hoặc trả về trống. Kiểm tra mạng rồi thử lại.")
                .font(.system(size: 25))
                .foregroundStyle(.white.opacity(0.7))
            // G3: the cause line carries the store's REAL captured
            // errors (providerErrors — what each provider actually
            // threw; pre-v1.9 every error was discarded by try?).
            if !phim.providerErrors.isEmpty {
                Text(phim.providerErrors
                        .sorted { $0.key < $1.key }
                        .map { "\(providerDisplayName($0.key)): \($0.value)" }
                        .joined(separator: " · "))
                    .font(.system(size: 25))
                    .foregroundStyle(.white.opacity(0.7))
            }
            Button { phim.retry() } label: {
                Text("Thử lại")
                    .font(.system(size: 29, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 36)
                    .padding(.vertical, 16)
                    .background(Capsule().fill(JoeTheme.accentViolet))
                    .overlay(JoeFocusRing(shape: Capsule()))
            }
            .buttonStyle(.card)
            .focusEffectDisabled(true)
            .focused($retryFocused)
            .scaleEffect(retryFocused ? 1.05 : 1.0)
        }
        .padding(.top, 30)
    }

    // MARK: - WatchStore rails

    private var movieProgress: [WatchStore.Entry] {
        Array(WatchStore.filterKinds(watch.progress(),
                                     [WatchStore.kindKK, WatchStore.kindF4K, WatchStore.kindVS, WatchStore.kindTP])
            .prefix(WatchStore.railCap))
    }

    private var movieFavorites: [WatchStore.Entry] {
        Array(WatchStore.filterKinds(watch.favorites(),
                                     [WatchStore.kindKK, WatchStore.kindF4K, WatchStore.kindVS, WatchStore.kindTP])
            .prefix(WatchStore.railCap))
    }

    // MARK: - Focus traversal (first-rail routing)

    /// One focusable card in a rail, whichever FocusState owns it.
    private enum RailItem: Equatable {
        case entry(String)
        case movie(Movie.ID)
    }

    /// Every rail in on-screen order, empty rails skipped — the
    /// first element is the section's first rail (the
    /// Continue-Watching entry rail when non-empty, else the
    /// first movie rail).
    private var phimRails: [[RailItem]] {
        var rails: [[RailItem]] = []
        if !movieProgress.isEmpty {
            rails.append(movieProgress.map { .entry("cw|" + $0.key) })
        }
        if !movieFavorites.isEmpty {
            rails.append(movieFavorites.map { .entry("fav|" + $0.key) })
        }
        // F4: every movie focus key is "<railKey>|<movie.id>" —
        // the same film in three rails is three distinct focus
        // targets, so exactly one card can show focus (C-3).
        var scopedRails: [(scope: String, movies: [Movie])] = [
            ("merged", phim.merged), ("chieuRap", phim.chieuRap),
            ("vnAll", phim.vietnamAll), ("vnSeries", phim.vietnamSeries),
            ("vnSingle", phim.vietnamSingle),
        ]
        for (slug, _) in PhimStore.genreSpec {
            scopedRails.append(("genre:" + slug, phim.genreLists[slug] ?? []))
        }
        for (slug, _) in PhimStore.countrySpec {
            scopedRails.append(("country:" + slug, phim.countryLists[slug] ?? []))
        }
        scopedRails.append(contentsOf: [
            ("kkNew", phim.kkNew), ("kkSeries", phim.kkSeries),
            ("kkMovies", phim.kkMovies), ("kkAnime", phim.kkAnime),
            ("f4kNew", phim.f4kNew), ("f4kMovies", phim.f4kMovies),
            ("vsNew", phim.vsNew), ("vsSeries", phim.vsSeries),
            ("tpMovies", phim.tpMovies), ("tpSeries", phim.tpSeries),
        ])
        for scoped in scopedRails where !scoped.movies.isEmpty {
            rails.append(scoped.movies.map { .movie(scoped.scope + "|" + $0.id) })
        }
        return rails
    }

    private var currentRailItem: RailItem? {
        if let focusedEntry { return .entry(focusedEntry) }
        if let focusedMovie { return .movie(focusedMovie) }
        return nil
    }

    /// Non-nil only while focus sits in the FIRST rail — the
    /// cards of that rail carry the always-installed
    /// .onMoveCommand whose handler (handleFirstRailMove)
    /// reads this.
    private var firstRailFocusIndex: Int? {
        guard let item = currentRailItem,
              let first = phimRails.first,
              let idx = first.firstIndex(of: item) else { return nil }
        return idx
    }

    /// The scope of the first CATALOGUE rail on screen, or nil
    /// when an entry rail (Continue Watching / Favourites)
    /// leads. Mirrors the body's rail order exactly; movieRail
    /// compares its own scope against this to decide whether
    /// its cards carry the first-rail move handler. This is a
    /// pure function of catalogue data — the handler attachment
    /// changes only when the DATA changes (a rail landing),
    /// never when focus moves.
    private var firstRailScope: String? {
        if !movieProgress.isEmpty || !movieFavorites.isEmpty { return nil }
        var scoped: [(scope: String, hasData: Bool)] = [
            ("merged", !phim.merged.isEmpty),
            ("chieuRap", !phim.chieuRap.isEmpty),
            ("vnAll", !phim.vietnamAll.isEmpty),
            ("vnSeries", !phim.vietnamSeries.isEmpty),
            ("vnSingle", !phim.vietnamSingle.isEmpty),
        ]
        for (slug, _) in PhimStore.genreSpec {
            scoped.append(("genre:" + slug, !(phim.genreLists[slug] ?? []).isEmpty))
        }
        for (slug, _) in PhimStore.countrySpec {
            scoped.append(("country:" + slug, !(phim.countryLists[slug] ?? []).isEmpty))
        }
        scoped.append(contentsOf: [
            ("kkNew", !phim.kkNew.isEmpty),
            ("kkSeries", !phim.kkSeries.isEmpty),
            ("kkMovies", !phim.kkMovies.isEmpty),
            ("kkAnime", !phim.kkAnime.isEmpty),
            ("f4kNew", !phim.f4kNew.isEmpty),
            ("f4kMovies", !phim.f4kMovies.isEmpty),
            ("vsNew", !phim.vsNew.isEmpty),
            ("vsSeries", !phim.vsSeries.isEmpty),
            ("tpMovies", !phim.tpMovies.isEmpty),
            ("tpSeries", !phim.tpSeries.isEmpty),
        ])
        return scoped.first { $0.hasData }?.scope
    }

    private func setRailFocus(_ item: RailItem) {
        switch item {
        case .entry(let key):
            focusedMovie = nil
            focusedEntry = key
        case .movie(let id):
            focusedEntry = nil
            focusedMovie = id
        }
    }

    // CONVERGENCE (2026-11-15): the header and Retry boundary
    // handlers (handleHeaderMove / handleRetryMove) are DELETED
    // with their traps. Every outcome they produced is what
    // geometric focus movement does on this layout unaided:
    // header UP → the pills (the row directly above), header
    // DOWN → the first rail's first card, or — in the C-1/F5.6
    // error state — the Retry button, the only focusable
    // element below the header; Retry UP → the header. The
    // header's LEFT/RIGHT no-ops were the screen edge, which
    // geometry also gives. What geometry does NOT reproduce is
    // the first rail's exact arithmetic, kept below.

    /// First-rail boundary: UP to the header button, LEFT/RIGHT
    /// arithmetic neighbours inside the rail (no-op at its ends),
    /// DOWN to the same-index card (clamped) in the next rail;
    /// with a single rail, DOWN lands on the error surface's
    /// Retry when one is showing (Scope-3), else a no-op.
    /// Installed per-card on the first rail's cards only (the
    /// handler is unconditional; it reads the CURRENT focus
    /// index when a press arrives). Deeper rails carry no
    /// handler — the focus engine's geometry handles them.
    private func handleFirstRailMove(_ dir: MoveCommandDirection) {
        guard let idx = firstRailFocusIndex,
              let first = phimRails.first else { return }
        if dir == .up {
            headerFocused = true
        } else if dir == .left {
            if idx > 0 { setRailFocus(first[idx - 1]) }
        } else if dir == .right {
            if idx < first.count - 1 { setRailFocus(first[idx + 1]) }
        } else if dir == .down {
            if phimRails.count > 1 {
                let next = phimRails[1]
                setRailFocus(next[min(idx, next.count - 1)])
            } else if showPhimError {
                // Scope-3 residual (Team 4 re-gate): with a
                // single owner rail (CW/favourites) and a dead
                // catalogue, the error surface below is the only
                // thing DOWN can reach — land on its Retry
                // instead of consuming the press as a no-op.
                retryFocused = true
            }
            // else: defined no-op (no next rail, no error
            // surface — nothing below the first rail).
        }
    }

    @ViewBuilder
    private var cwRail: some View {
        if !movieProgress.isEmpty {
            JoeTheme.Rail(title: "▶ Đang xem dở") {
                ForEach(movieProgress) { entry in
                    let card = Button { nav.movie = MovieRoute(
                        provider: entry.source, slug: entry.slug,
                        name: entry.title, poster: entry.poster,
                        year: entry.year, preselectEp: entry.ep) } label: {
                        JoeTheme.PosterCard(
                            title: entry.title,
                            posterURL: entry.posterURL,
                            meta: entry.epLabel,
                            badge: Providers.badge(entry.source),
                            progress: entry.fraction,
                            subline: "Còn \(WatchStore.fmtClock(entry.dur - entry.pos))",
                            focused: focusedEntry == "cw|" + entry.key)
                    }
                    .buttonStyle(.card)
                    .focusEffectDisabled(true)
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

    @ViewBuilder
    private var favRail: some View {
        if !movieFavorites.isEmpty {
            JoeTheme.Rail(title: "♥ Yêu thích") {
                ForEach(movieFavorites) { entry in
                    let card = Button { nav.movie = MovieRoute(
                        provider: entry.source, slug: entry.slug,
                        name: entry.title, poster: entry.poster,
                        year: entry.year) } label: {
                        JoeTheme.PosterCard(
                            title: entry.title,
                            posterURL: entry.posterURL,
                            meta: entry.year,
                            badge: Providers.badge(entry.source),
                            focused: focusedEntry == "fav|" + entry.key)
                    }
                    .buttonStyle(.card)
                    .focusEffectDisabled(true)
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
                    if movieProgress.isEmpty {
                        card.onMoveCommand { dir in handleFirstRailMove(dir) }
                    } else {
                        card
                    }
                }
            }
        }
    }

    // MARK: - Catalogue rails

    private func movieRail(_ title: String, _ movies: [Movie], badges: Bool,
                           scope: String) -> some View {
        JoeTheme.Rail(title: title) {
            ForEach(movies) { movie in
                let card = Button { nav.movie = MovieRoute(
                    provider: movie.provider, slug: movie.slug,
                    name: movie.name, poster: movie.poster, year: movie.year) } label: {
                    JoeTheme.PosterCard(
                        title: movie.name,
                        posterURL: movie.posterURL,
                        meta: movie.cardMeta,
                        badge: badges ? Providers.badge(movie.provider) : nil,
                        focused: focusedMovie == scope + "|" + movie.id)
                }
                .buttonStyle(.card)
                .focusEffectDisabled(true)
                .focused($focusedMovie, equals: scope + "|" + movie.id)
                // Only the FIRST catalogue rail's cards carry
                // the first-rail move handler (see
                // firstRailScope); the attachment follows the
                // catalogue data, never the focus state.
                if scope == firstRailScope {
                    card.onMoveCommand { dir in handleFirstRailMove(dir) }
                } else {
                    card
                }
            }
        }
    }

}

// CONVERGENCE RECORD (2026-11-15): this file's duplicated
// JoeMoveTrap struct is DELETED — see the record at the end of
// JoeTVApp.swift. The header/Retry/first-rail traps it powered
// are replaced by geometric focus movement plus the per-card
// always-installed first-rail handler above.
