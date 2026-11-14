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

    var body: some View {
        Group {
            if nav.searchOpen {
                JoeSearchView()
            } else {
                grid
            }
        }
        .task { phim.loadIfNeeded() }
        .onChange(of: nav.focusNonce) { _, _ in
            // Hub contract: the shell asks this section to take
            // focus at its top — the "Tìm phim" header button.
            if nav.focusTarget == .sectionTop {
                headerFocused = true
            }
        }
    }

    private var grid: some View {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 36) {
                    header
                    cwRail
                    favRail
                    if !phim.merged.isEmpty {
                        movieRail("✨ Mới cập nhật · Tổng hợp", phim.merged, badges: true)
                    }
                    if !phim.chieuRap.isEmpty {
                        movieRail("🔥 Phim chiếu rạp", phim.chieuRap, badges: true)
                    }
                    ForEach(Array(PhimStore.genreSpec.enumerated()), id: \.offset) { _, spec in
                        if let list = phim.genreLists[spec.slug], !list.isEmpty {
                            movieRail(spec.title, list, badges: true)
                        }
                    }
                    ForEach(Array(PhimStore.countrySpec.enumerated()), id: \.offset) { _, spec in
                        if let list = phim.countryLists[spec.slug], !list.isEmpty {
                            movieRail(spec.title, list, badges: true)
                        }
                    }
                    if !phim.kkNew.isEmpty {
                        movieRail("✨ Mới cập nhật", phim.kkNew, badges: false)
                    }
                    if !phim.kkSeries.isEmpty {
                        movieRail("📺 Phim bộ mới", phim.kkSeries, badges: false)
                    }
                    if !phim.kkMovies.isEmpty {
                        movieRail("🎞️ Phim lẻ mới", phim.kkMovies, badges: false)
                    }
                    if !phim.kkAnime.isEmpty {
                        movieRail("🐣 Hoạt hình", phim.kkAnime, badges: false)
                    }
                    if !phim.f4kNew.isEmpty {
                        movieRail("✨ Film4K · Mới cập nhật", phim.f4kNew, badges: false)
                    }
                    if !phim.f4kMovies.isEmpty {
                        movieRail("🎞️ Film4K · Phim lẻ mới", phim.f4kMovies, badges: false)
                    }
                    if !phim.vsNew.isEmpty {
                        movieRail("🎬 VSMOV · Mới cập nhật", phim.vsNew, badges: false)
                    }
                    if !phim.vsSeries.isEmpty {
                        movieRail("🎬 VSMOV · Phim bộ mới", phim.vsSeries, badges: false)
                    }
                    if !phim.tpMovies.isEmpty {
                        movieRail("📚 Tủ Phim · Phim lẻ mới", phim.tpMovies, badges: false)
                    }
                    if !phim.tpSeries.isEmpty {
                        movieRail("📚 Tủ Phim · Phim bộ mới", phim.tpSeries, badges: false)
                    }
                    if phim.loading && !phim.hasData {
                        ProgressView("Đang tải thư viện phim…")
                            .font(.title3)
                            .foregroundStyle(.white)
                            .tint(.white)
                            .padding(.top, 30)
                    }
                }
            }
            .modifier(JoeMoveTrap(enabled: headerFocused) { dir in
                handleHeaderMove(dir)
            })
            .modifier(JoeMoveTrap(enabled: firstRailFocusIndex != nil) { dir in
                handleFirstRailMove(dir)
            })
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 28) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Thư viện phim")
                    .font(.system(size: 44, weight: .heavy))
                    .foregroundStyle(.white)
                Text("KKPhim · Film4K · VSMOV · Tủ Phim — link được lấy mới mỗi lần bấm xem")
                    .font(.system(size: 21))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
            Button {
                nav.searchOpen = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                    Text("Tìm phim")
                }
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 26)
                .padding(.vertical, 14)
                .background(Capsule().fill(headerFocused ? JoeTheme.accentViolet
                                           : JoeTheme.accentViolet.opacity(0.45)))
                .overlay(JoeFocusRing(shape: Capsule()))
                .scaleEffect(headerFocused ? 1.05 : 1.0)
            }
            .buttonStyle(.plain)
            .focused($headerFocused)
        }
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

    // MARK: - Focus traversal (boundary traps)

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
            rails.append(movieProgress.map { .entry($0.key) })
        }
        if !movieFavorites.isEmpty {
            rails.append(movieFavorites.map { .entry($0.key) })
        }
        var movieRails: [[Movie]] = [phim.merged, phim.chieuRap]
        for (slug, _) in PhimStore.genreSpec {
            movieRails.append(phim.genreLists[slug] ?? [])
        }
        for (slug, _) in PhimStore.countrySpec {
            movieRails.append(phim.countryLists[slug] ?? [])
        }
        movieRails.append(contentsOf: [phim.kkNew, phim.kkSeries,
                                       phim.kkMovies, phim.kkAnime, phim.f4kNew,
                                       phim.f4kMovies, phim.vsNew, phim.vsSeries,
                                       phim.tpMovies, phim.tpSeries])
        for movies in movieRails where !movies.isEmpty {
            rails.append(movies.map { .movie($0.id) })
        }
        return rails
    }

    private var currentRailItem: RailItem? {
        if let focusedEntry { return .entry(focusedEntry) }
        if let focusedMovie { return .movie(focusedMovie) }
        return nil
    }

    /// Non-nil only while focus sits in the FIRST rail — that is
    /// the one state where the first-rail trap is enabled.
    private var firstRailFocusIndex: Int? {
        guard let item = currentRailItem,
              let first = phimRails.first,
              let idx = first.firstIndex(of: item) else { return nil }
        return idx
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

    /// Header boundary: UP escapes the section to the shell
    /// pills, DOWN lands on the first rail's first card,
    /// LEFT/RIGHT are explicit no-ops (the header button is the
    /// only focusable element in its row, at the screen's top).
    private func handleHeaderMove(_ dir: MoveCommandDirection) {
        if dir == .up {
            nav.requestFocus(.pills)
        } else if dir == .down {
            if let first = phimRails.first?.first {
                setRailFocus(first)
            }
        }
        // .left / .right: explicit no-op (see above).
    }

    /// First-rail boundary: UP to the header button, LEFT/RIGHT
    /// arithmetic neighbours inside the rail (no-op at its ends),
    /// DOWN to the same-index card (clamped) in the next rail
    /// (no-op when there is no next rail). Deeper rails are not
    /// trapped — the focus engine's geometry handles them.
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
            }
        }
    }

    @ViewBuilder
    private var cwRail: some View {
        if !movieProgress.isEmpty {
            JoeTheme.Rail(title: "▶ Đang xem dở") {
                ForEach(movieProgress) { entry in
                    Button { nav.movie = MovieRoute(
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
                            focused: focusedEntry == entry.key)
                    }
                    .buttonStyle(.plain)
                    .focused($focusedEntry, equals: entry.key)
                    .contextMenu {
                        Button(role: .destructive) {
                            watch.removeProgress(key: entry.key)
                        } label: {
                            Text("Xoá khỏi Đang xem dở")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var favRail: some View {
        if !movieFavorites.isEmpty {
            JoeTheme.Rail(title: "♥ Yêu thích") {
                ForEach(movieFavorites) { entry in
                    Button { nav.movie = MovieRoute(
                        provider: entry.source, slug: entry.slug,
                        name: entry.title, poster: entry.poster,
                        year: entry.year) } label: {
                        JoeTheme.PosterCard(
                            title: entry.title,
                            posterURL: entry.posterURL,
                            meta: entry.year,
                            badge: Providers.badge(entry.source),
                            focused: focusedEntry == entry.key)
                    }
                    .buttonStyle(.plain)
                    .focused($focusedEntry, equals: entry.key)
                    .contextMenu {
                        Button(role: .destructive) {
                            watch.removeFavorite(key: entry.key)
                        } label: {
                            Text("Bỏ yêu thích")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Catalogue rails

    private func movieRail(_ title: String, _ movies: [Movie], badges: Bool) -> some View {
        JoeTheme.Rail(title: title) {
            ForEach(movies) { movie in
                Button { nav.movie = MovieRoute(
                    provider: movie.provider, slug: movie.slug,
                    name: movie.name, poster: movie.poster, year: movie.year) } label: {
                    JoeTheme.PosterCard(
                        title: movie.name,
                        posterURL: movie.posterURL,
                        meta: movie.cardMeta,
                        badge: badges ? Providers.badge(movie.provider) : nil,
                        focused: focusedMovie == movie.id)
                }
                .buttonStyle(.plain)
                .focused($focusedMovie, equals: movie.id)
            }
        }
    }

}

/// Conditional move trap (hub contract): installed only while
/// focus sits on a boundary element, so every direction it
/// intercepts must have a defined outcome in the handler.
private struct JoeMoveTrap: ViewModifier {
    let enabled: Bool
    let action: (MoveCommandDirection) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.onMoveCommand(perform: action)
        } else {
            content
        }
    }
}
