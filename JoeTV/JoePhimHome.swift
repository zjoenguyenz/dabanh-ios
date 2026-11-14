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

    var body: some View {
        Group {
            if nav.searchOpen {
                JoeSearchView()
            } else {
                grid
            }
        }
        .task { phim.loadIfNeeded() }
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
                .padding(.leading, 44)
                .padding(.trailing, 52)
                .padding(.top, 36)
                .padding(.bottom, 30)
            }
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
                .background(Capsule().fill(Color.white.opacity(0.10)))
                .overlay(JoeFocusRing(shape: Capsule()))
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
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
                    .focusEffectDisabled()
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
                    .focusEffectDisabled()
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
                .focusEffectDisabled()
                .focused($focusedMovie, equals: movie.id)
            }
        }
    }

}
