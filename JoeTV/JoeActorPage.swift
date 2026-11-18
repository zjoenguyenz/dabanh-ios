import SwiftUI

// MARK: - Actor page (Ideas 1 + 20)
//
// ONE shared page for an actor, reached from two places:
//   - the TVB tab's "🎭 Diễn viên" rail (Idea 1) — .tvb
//     mode: the filmography is the bundled snapshot's
//     displayed titles whose `cast` carries the name;
//   - a movie detail's TMDB cast row (Idea 20) — .tmdb
//     mode: the person's TMDB credits, each matched to a
//     PLAYABLE title before it may render as a card.
//
// Playable matches open through the navigator's normal
// movie route, minted exactly as the presenting surface
// mints it (a PhimStore Movie's own provider/slug, or a
// TVB title's routeTarget — the JoeTVBView.open mirror).
// Credits with no playable match are NEVER dead focusable
// cards: they list as plain rows under "Chưa có nguồn
// phát", honestly labelled as having no source yet.

enum JoeActorRoute: Identifiable {
    case tmdb(personId: Int, name: String, photoURL: String)
    case tvb(name: String)

    var id: String {
        switch self {
        case .tmdb(let personId, _, _): return "tmdb|\(personId)"
        case .tvb(let name): return "tvb|\(name)"
        }
    }

    var name: String {
        switch self {
        case .tmdb(_, let name, _): return name
        case .tvb(let name): return name
        }
    }

    var photoURL: String {
        switch self {
        case .tmdb(_, _, let photoURL): return photoURL
        case .tvb: return ""
        }
    }
}

struct JoeActorPage: View {
    let route: JoeActorRoute
    @EnvironmentObject private var nav: JoeNavigator
    @EnvironmentObject private var phim: PhimStore
    @Environment(\.joeTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var loaded = false
    /// .tvb mode: the snapshot filmography (popularity desc).
    @State private var tvbTitles: [TVBTitle] = []
    /// .tmdb mode: the person's credits, split by the match.
    @State private var credits: [TMDBCreditTitle] = []
    @State private var matchedMovies: [MovieMatch] = []
    @State private var matchedTVB: [TVBMatch] = []
    @State private var unmatched: [TMDBCreditTitle] = []
    @FocusState private var cardFocus: String?
    @FocusState private var backFocused: Bool

    private struct MovieMatch: Identifiable {
        let credit: TMDBCreditTitle
        let movie: Movie
        var id: String { movie.id }
    }

    private struct TVBMatch: Identifiable {
        let credit: TMDBCreditTitle
        let title: TVBTitle
        var id: Int { title.tmdbId }
    }

    var body: some View {
        ZStack {
            theme.bg.ignoresSafeArea()
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 40) {
                    header
                    content
                }
            }
        }
        // Menu closes THIS page (the detail's own-root
        // handler placement): one press, one layer.
        .onExitCommand { dismiss() }
        .task { await load() }
    }

    // MARK: - Header (the detail-header visual language)

    private var header: some View {
        HStack(alignment: .center, spacing: 28) {
            if !route.photoURL.isEmpty, let url = URL(string: route.photoURL) {
                ZStack {
                    Circle().fill(Color.white.opacity(0.10))
                    JoeRemoteImage(url: url, targetPixels: 240) {
                        Text(String(route.name.prefix(1)))
                            .font(.system(size: 38, weight: .bold))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                .frame(width: 110, height: 110)
                .clipShape(Circle())
                .overlay(Circle()
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 1.2))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(route.name)
                    .font(.system(size: 44, weight: .heavy))
                    .foregroundStyle(theme.text)
                    .lineLimit(2)
                Text(subtitle)
                    .font(.system(size: 25))
                    .foregroundStyle(theme.meta)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                JoeSecondaryLabel(title: "⟵ Quay lại")
            }
            .joeCardButton()
            .focused($backFocused)
        }
    }

    private var subtitle: String {
        switch route {
        case .tvb(_):
            return loaded ? "\(tvbTitles.count) phim trong mục TVB"
                          : "Đang tải danh sách…"
        case .tmdb(_, _, _):
            return "Các phim có diễn viên này"
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if !loaded {
            ProgressView("Đang tải…")
                .font(.system(size: 29))
                .foregroundStyle(theme.text)
                .tint(theme.text)
                .padding(.top, 30)
        } else {
            switch route {
            case .tvb(_): tvbContent
            case .tmdb(_, _, _): tmdbContent
            }
        }
    }

    @ViewBuilder
    private var tvbContent: some View {
        if tvbTitles.isEmpty {
            Text("Chưa có phim nào của diễn viên này trong danh sách TVB.")
                .font(.system(size: 29))
                .foregroundStyle(theme.meta)
        } else {
            cardGrid {
                ForEach(tvbTitles) { title in
                    tvbCard(title)
                }
            }
        }
    }

    @ViewBuilder
    private var tmdbContent: some View {
        if credits.isEmpty {
            // No credits loaded at all (no key / no network /
            // no filmography on record): say so plainly
            // instead of painting an empty page.
            Text("Chưa tải được danh sách phim của diễn viên này.")
                .font(.system(size: 29))
                .foregroundStyle(theme.meta)
        } else {
            if !matchedMovies.isEmpty || !matchedTVB.isEmpty {
                VStack(alignment: .leading, spacing: 18) {
                    sectionTitle("Có nguồn phát")
                    cardGrid {
                        ForEach(matchedMovies) { match in
                            movieCard(match.movie)
                        }
                        ForEach(matchedTVB) { match in
                            tvbCard(match.title)
                        }
                    }
                }
            }
            if !unmatched.isEmpty {
                VStack(alignment: .leading, spacing: 18) {
                    sectionTitle("Chưa có nguồn phát")
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(Array(unmatched.enumerated()),
                                id: \.offset) { _, credit in
                            unmatchedRow(credit)
                        }
                    }
                }
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: theme.id == .posterWall ? 40 : 34,
                          weight: theme.id == .posterWall ? .heavy : .bold))
            .foregroundStyle(theme.text)
    }

    /// The JoeBrowseView / TVB genre-grid construction:
    /// six columns, the wall card form under design D.
    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: theme.railGap), count: 6)
    }

    private func cardGrid<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 40) {
            content()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, theme.id == .posterWall ? 8 : 4)
        .focusSection()
    }

    // MARK: - Cards + rows

    /// A playable PhimStore title: the existing PosterCard
    /// over the Movie's own fields, badge from its provider.
    private func movieCard(_ movie: Movie) -> some View {
        Button { openMovie(movie) } label: {
            PosterCard(
                title: movie.name,
                posterURL: movie.posterURL,
                tmdbId: movie.tmdbId,
                tmdbType: movie.tmdbType,
                meta: movie.cardMeta,
                badge: Providers.badge(movie.provider))
        }
        .joeCardButton()
        .focused($cardFocus, equals: "movie|" + movie.id)
    }

    /// A playable TVB snapshot title: the TVB side's card
    /// construction (JoeTVBView.card / the search grid's
    /// card, same PosterCard fields), opening through the
    /// routeTarget mirror in openTVB below.
    private func tvbCard(_ title: TVBTitle) -> some View {
        Button { openTVB(title) } label: {
            PosterCard(
                title: title.titleVi,
                posterURL: title.posterURL,
                tmdbId: "\(title.tmdbId)",
                tmdbType: "tv",
                meta: title.cardMeta,
                badge: title.routeTarget.map { Providers.badge($0.provider) })
        }
        .joeCardButton()
        .focused($cardFocus, equals: "tvb|" + "\(title.tmdbId)")
    }

    /// An unmatched credit: poster + title + year (+ the
    /// character, when TMDB carries one) as a PLAIN row —
    /// deliberately not a Button and carrying no focus
    /// handling, so it can never read as a playable card.
    private func unmatchedRow(_ credit: TMDBCreditTitle) -> some View {
        HStack(alignment: .center, spacing: 22) {
            ZStack {
                Color.white.opacity(0.08)
                if !credit.posterURL.isEmpty,
                   let url = URL(string: credit.posterURL) {
                    JoeRemoteImage(url: url, targetPixels: 240) {
                        Text(String(credit.title.prefix(1)))
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                } else {
                    Text(String(credit.title.prefix(1)))
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            .frame(width: 80, height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 6) {
                Text(credit.title)
                    .font(.system(size: 27, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .lineLimit(2)
                let yearText = "\(credit.year)"
                let meta = [yearText == "0" ? "" : yearText, credit.character]
                    .filter { !$0.isEmpty }
                    .joined(separator: " · ")
                if !meta.isEmpty {
                    Text(meta)
                        .font(.system(size: 23))
                        .foregroundStyle(theme.meta)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Opening titles

    private func openMovie(_ movie: Movie) {
        open(MovieRoute(provider: movie.provider, slug: movie.slug,
                        name: movie.name, poster: movie.poster,
                        year: movie.year))
    }

    /// The JoeTVBView.open mirror, verbatim in shape: the
    /// title's routeTarget (primary provider's first slug,
    /// TP → KK → VS fallback) mints the MovieRoute.
    private func openTVB(_ title: TVBTitle) {
        guard let target = title.routeTarget else { return }
        open(MovieRoute(provider: target.provider, slug: target.slug,
                        name: title.titleVi, poster: title.posterURLString,
                        year: title.yearString))
    }

    /// Present the route through the navigator. This page
    /// is a cover: it dismisses itself first. When a detail
    /// is already open underneath (the .tmdb entry point),
    /// that detail's @State was built from ITS route, so
    /// the route is cleared and re-minted on the next turn
    /// — the fresh detail then builds from the new route
    /// exactly as a home/rail tap does.
    private func open(_ movieRoute: MovieRoute) {
        dismiss()
        if nav.movie != nil {
            nav.movie = nil
            Task { @MainActor in nav.movie = movieRoute }
        } else {
            nav.movie = movieRoute
        }
    }

    // MARK: - Load + matching

    private func load() async {
        switch route {
        case .tvb(let name):
            // The snapshot decode rides a detached task (the
            // TVB tab's own load pattern); the filmography
            // is the DISPLAYED titles whose cast carries the
            // name exactly, popularity desc.
            let titles = await Task.detached(priority: .userInitiated) {
                (TVBCatalog.loadBundled()?.titles ?? [])
                    .filter { $0.isDisplayed && $0.cast.contains(name) }
                    .sorted { $0.popularity > $1.popularity }
            }.value
            tvbTitles = titles
            loaded = true
        case .tmdb(let personId, _, _):
            async let creditsFetch =
                TMDBClient.fetchPersonCredits(personId: personId)
            let snapshot = await Task.detached(priority: .userInitiated) {
                TVBCatalog.loadBundled()
            }.value
            let fetched = await creditsFetch
            credits = fetched
            // tmdbId → Movie over every list the PhimStore
            // holds (the trending matcher's catalogue map,
            // JoePhimHome.catalogueByTmdbId, mirrored).
            let byTmdbId = catalogueByTmdbId()
            var tvbById: [Int: TVBTitle] = [:]
            for title in snapshot?.titles ?? [] where title.isDisplayed {
                if tvbById[title.tmdbId] == nil {
                    tvbById[title.tmdbId] = title
                }
            }
            var movies: [MovieMatch] = []
            var tvbs: [TVBMatch] = []
            var rest: [TMDBCreditTitle] = []
            for credit in fetched {
                // The credit's tmdbId is matched in its
                // string form (the Movie map's key form);
                // the same text reads back as the TVB map's
                // Int key.
                let key = String(describing: credit.tmdbId)
                let type = credit.type
                if let movie = byTmdbId[key],
                   movie.tmdbType.isEmpty || type.isEmpty
                    || movie.tmdbType == type {
                    movies.append(MovieMatch(credit: credit, movie: movie))
                } else if type.isEmpty || type == "tv",
                          let tvbKey = Int(key), let title = tvbById[tvbKey] {
                    tvbs.append(TVBMatch(credit: credit, title: title))
                } else {
                    rest.append(credit)
                }
            }
            matchedMovies = movies
            matchedTVB = tvbs
            unmatched = rest
            loaded = true
        }
    }

    /// tmdbId → Movie over every list the PhimStore holds.
    /// First carrier wins (lists are visited in rail/priority
    /// order, merged first); vietnamAll covers the store's
    /// derived vietnamSeries / vietnamSingle views. Mirrors
    /// JoePhimHome.catalogueByTmdbId.
    private func catalogueByTmdbId() -> [String: Movie] {
        var map: [String: Movie] = [:]
        func add(_ movies: [Movie]) {
            for m in movies where !m.tmdbId.isEmpty && map[m.tmdbId] == nil {
                map[m.tmdbId] = m
            }
        }
        add(phim.merged)
        add(phim.kkNew)
        add(phim.f4kNew)
        add(phim.vsNew)
        add(phim.tpNew)
        add(phim.chieuRap)
        add(phim.vietnamAll)
        add(phim.kkSeries)
        add(phim.kkMovies)
        add(phim.kkAnime)
        add(phim.f4kMovies)
        add(phim.vsSeries)
        add(phim.tpMovies)
        add(phim.tpSeries)
        for spec in PhimStore.genreSpec {
            add(phim.genreLists[spec.slug] ?? [])
        }
        for spec in PhimStore.countrySpec {
            add(phim.countryLists[spec.slug] ?? [])
        }
        return map
    }
}
