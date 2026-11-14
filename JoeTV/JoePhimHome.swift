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
    @FocusState private var focusedMovie: Movie.ID?
    @FocusState private var focusedEntry: String?
    @State private var merged: [Movie] = []
    @State private var kkNew: [Movie] = []
    @State private var kkSeries: [Movie] = []
    @State private var kkMovies: [Movie] = []
    @State private var kkAnime: [Movie] = []
    @State private var f4kNew: [Movie] = []
    @State private var f4kMovies: [Movie] = []
    @State private var vsNew: [Movie] = []
    @State private var vsSeries: [Movie] = []
    @State private var loading = true

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 36) {
                    header
                    cwRail
                    favRail
                    if !merged.isEmpty {
                        movieRail("✨ Mới cập nhật · Tổng hợp", merged, badges: true)
                    }
                    if !kkNew.isEmpty {
                        movieRail("✨ Mới cập nhật", kkNew, badges: false)
                    }
                    if !kkSeries.isEmpty {
                        movieRail("📺 Phim bộ mới", kkSeries, badges: false)
                    }
                    if !kkMovies.isEmpty {
                        movieRail("🎞️ Phim lẻ mới", kkMovies, badges: false)
                    }
                    if !kkAnime.isEmpty {
                        movieRail("🐣 Hoạt hình", kkAnime, badges: false)
                    }
                    if !f4kNew.isEmpty {
                        movieRail("✨ Film4K · Mới cập nhật", f4kNew, badges: false)
                    }
                    if !f4kMovies.isEmpty {
                        movieRail("🎞️ Film4K · Phim lẻ mới", f4kMovies, badges: false)
                    }
                    if !vsNew.isEmpty {
                        movieRail("🎬 VSMOV · Mới cập nhật", vsNew, badges: false)
                    }
                    if !vsSeries.isEmpty {
                        movieRail("🎬 VSMOV · Phim bộ mới", vsSeries, badges: false)
                    }
                    if loading && merged.isEmpty {
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
            .navigationDestination(for: MovieRoute.self) { route in
                JoeMovieDetail(route: route)
            }
        }
        .task { await load() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 28) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Thư viện phim")
                    .font(.system(size: 44, weight: .heavy))
                    .foregroundStyle(.white)
                Text("KKPhim · Film4K · VSMOV — link được lấy mới mỗi lần bấm xem")
                    .font(.system(size: 21))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
            NavigationLink {
                JoeSearchView()
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
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - WatchStore rails

    private var movieProgress: [WatchStore.Entry] {
        Array(WatchStore.filterKinds(watch.progress(),
                                     [WatchStore.kindKK, WatchStore.kindF4K, WatchStore.kindVS])
            .prefix(WatchStore.railCap))
    }

    private var movieFavorites: [WatchStore.Entry] {
        Array(WatchStore.filterKinds(watch.favorites(),
                                     [WatchStore.kindKK, WatchStore.kindF4K, WatchStore.kindVS])
            .prefix(WatchStore.railCap))
    }

    @ViewBuilder
    private var cwRail: some View {
        if !movieProgress.isEmpty {
            JoeTheme.Rail(title: "▶ Đang xem dở") {
                ForEach(movieProgress) { entry in
                    NavigationLink(value: MovieRoute(
                        provider: entry.source, slug: entry.slug,
                        name: entry.title, poster: entry.poster,
                        year: entry.year, preselectEp: entry.ep)) {
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
                    NavigationLink(value: MovieRoute(
                        provider: entry.source, slug: entry.slug,
                        name: entry.title, poster: entry.poster,
                        year: entry.year)) {
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
                NavigationLink(value: MovieRoute(
                    provider: movie.provider, slug: movie.slug,
                    name: movie.name, poster: movie.poster, year: movie.year)) {
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

    // MARK: - Loading (fail-soft per rail, like the Android home)

    private func load() async {
        loading = true
        defer { loading = false }
        async let kkN = try? Providers.newest(Providers.KK, page: 1)
        async let f4kN = try? Providers.newest(Providers.F4K, page: 1)
        async let vsN = try? Providers.newest(Providers.VS, page: 1)
        async let kkS = try? Providers.listByType(Providers.KK, type: "phim-bo", page: 1)
        async let kkM = try? Providers.listByType(Providers.KK, type: "phim-le", page: 1)
        async let kkA = try? Providers.listByType(Providers.KK, type: "hoat-hinh", page: 1)
        async let f4kM = try? Providers.listByType(Providers.F4K, type: "phim-le", page: 1)
        async let vsS = try? Providers.listByType(Providers.VS, type: "phim-bo", page: 1)
        let (a, b, c, d, e, f, g, h) = await (kkN, f4kN, vsN, kkS, kkM, kkA, f4kM, vsS)
        kkNew = a ?? []
        f4kNew = b ?? []
        vsNew = c ?? []
        kkSeries = d ?? []
        kkMovies = e ?? []
        kkAnime = f ?? []
        f4kMovies = g ?? []
        vsSeries = h ?? []
        merged = Providers.mergeDedupe([kkNew, f4kNew, vsNew])
    }
}
