import SwiftUI
import Darwin

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

/// The Phim section root (v2.0.0, Team UI-5). One root, three
/// design trees over the unchanged data layer:
///  - A Billboard: full-bleed backdrop hero + every rail below
///  - D Poster Wall: JoeWallHomeView (JoeBrowse.swift)
///  - F Source Board: source bands over the provider rails +
///    every category shelf as rails below the bands
/// Search and the browse/grid layer swap in above the home,
/// exactly as search always has.
///
/// MENU (v2.0.0): this root carries the eighth exit handler
/// (UI-1's exit-dialog spec) — always installed, state-checked
/// inside: browse open → close browse; otherwise present the
/// exit confirmation. Search and the detail/player layers keep
/// their own nearer handlers, so one press still closes exactly
/// one layer. WatchStore persists synchronously on every
/// mutation (1.9.2), so the destructive action's flush is
/// already done by construction; it dismisses the alert and
/// exits on the next main-actor turn.
struct JoePhimHome: View {
    @EnvironmentObject private var watch: WatchStore
    @EnvironmentObject private var nav: JoeNavigator
    @EnvironmentObject private var phim: PhimStore
    @Environment(\.joeTheme) private var theme
    @FocusState private var focusedMovie: Movie.ID?
    @FocusState private var focusedEntry: String?
    @FocusState private var headerFocused: Bool
    @FocusState private var heroPlayFocused: Bool
    @FocusState private var bandFocused: String?
    @FocusState private var retryFocused: Bool
    /// Team 4 fix-round minor: the state surfaces (G3/G5) are
    /// gated on "a load has been attempted" so they cannot flash
    /// for a frame at cold entry, before the first loadIfNeeded
    /// has even run (at that instant loading == false and the
    /// catalogue is trivially empty).
    @State private var attempted = false
    @State private var exitConfirm = false
    /// UI-6 defect D-2: the featured film's DETAIL, fetched
    /// fail-soft for the hero's synopsis (the list payloads
    /// carry no synopsis) and as the fallback source for the
    /// meta fields a sparse list item left empty.
    @State private var heroDetail: Detail?
    /// Hero forensics fix (2026-11-15): the featured film's
    /// TMDB w1280 backdrop URL, resolved by the hero task.
    /// The list thumb cannot be the hero's only art source —
    /// for many KK titles it is a 780×438 marketing composite
    /// with the title logo baked into the art, and no window
    /// of it reads as a backdrop in the 668-tall hero (the
    /// owner's "hầu như hư hết" photos). The detail screen
    /// already holds the owner's standard — TMDB backdrop
    /// first, provider art as fallback; the hero now mirrors
    /// it (see the stage stack in `hero`).
    @State private var heroBackdropURL: URL?

    var body: some View {
        Group {
            if nav.searchOpen {
                JoeSearchView()
            } else if nav.browseOpen {
                JoeBrowseView()
            } else if theme.id == .posterWall {
                JoeWallHomeView()
            } else {
                railHome
            }
        }
        .task {
            attempted = true
            phim.loadIfNeeded()
        }
        // CONVERGENCE (spec item 3, 2026-11-15): no programmatic
        // focus writes on the launch path. DOWN from the pills
        // lands on the home's top element geometrically.
        //
        // EXIT DIALOG (UI-5, handler #8 of the 8 in
        // JoeTV/*.swift — the compiled target also carries the
        // shared TV player's own cover handler in
        // DaBanhTV/TVPlayerView.swift:47; inventory wording per
        // UI-7 F-3 / APPLE-CONFORMANCE G-EXIT-2): always
        // installed on the Phim section root; the state check
        // lives INSIDE the closure, so the handler's
        // installation never depends on any state (the D4-safe
        // shape). Search has its own nearer handler while it is
        // open; details and the player are nearer still.
        .onExitCommand {
            if nav.browseOpen {
                nav.browseOpen = false
            } else if !nav.searchOpen {
                exitConfirm = true
            }
        }
        .alert("Thoát Joe TV?", isPresented: $exitConfirm) {
            Button("Thoát", role: .destructive) {
                exitConfirm = false
                DispatchQueue.main.async { exit(0) }
            }
            Button("Ở lại", role: .cancel) { }
        } message: {
            Text("Phim đang xem dở vẫn được lưu lại cho lần mở sau.")
        }
    }

    // MARK: - Rail home (designs A and F)

    private var railHome: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 40) {
                if theme.id == .billboard {
                    if heroMovie != nil {
                        hero
                    } else {
                        slimHeader
                    }
                } else {
                    slimHeader
                }
                cwRail
                favRail
                ForEach(railSpecs) { spec in
                    if !spec.movies.isEmpty {
                        if let band = spec.bandName {
                            bandHeader(name: band, note: spec.bandNote ?? "", scope: spec.scope)
                        }
                        movieRail(spec.title, spec.movies, badges: spec.badges, scope: spec.scope)
                    }
                }
                // §8/G1: the spinner exists only while a load
                // is running, nothing has landed, and the 20 s
                // store deadline has not fired — never longer.
                if catalogueEmpty && phim.loading && !phim.loadTimedOut {
                    ProgressView("Đang tải thư viện phim…")
                        .font(.system(size: 29))
                        .foregroundStyle(theme.text)
                        .tint(theme.text)
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
                        .foregroundStyle(theme.meta)
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
        // CONVERGENCE (Team 7 D4, 2026-11-15): routing between
        // the header/hero and the rails is geometric, except the
        // first rail's exact arithmetic, which survives as an
        // ALWAYS-installed .onMoveCommand on the first rail's own
        // cards (see handleFirstRailMove) — per-element, and its
        // attachment follows catalogue DATA (which rail is first),
        // never focus state.
    }

    // MARK: - Rail specs (single source of truth for order)

    /// The rail list lives at file scope (joeRailSpecs below)
    /// since UI-6 defect D-1: design D's wall renders the same
    /// category shelves as titled wall sections, driven by this
    /// one list — the completeness A/F have, from one source.
    private var railSpecs: [JoeRailSpec] {
        joeRailSpecs(phim: phim, themeID: theme.id)
    }

    // MARK: - Design A hero

    /// The featured slot: the first thumb-bearing film in rail
    /// order (thumb-bearing sources only — UI-4's cost note),
    /// falling back to the first film's poster as the backdrop.
    private var heroMovie: Movie? {
        let all = railSpecs.flatMap { $0.movies }
        return all.first(where: { !$0.thumb.isEmpty }) ?? all.first
    }

    @ViewBuilder
    private var hero: some View {
        if let featured = heroMovie {
            ZStack(alignment: .bottomLeading) {
                // v2.0.1 (Android hero parity): the hero art
                // paints through the band layer — a landscape
                // thumb as a top-anchored slice (anchor 0.20,
                // the Android hero anchor) instead of the
                // centred fill that cut faces, and a poster-
                // only feature falls back to the blurred field
                // rather than a cropped poster. The scrims
                // below are untouched.
                //
                // Hero forensics fix (2026-11-15): the single
                // layer above became a three-stage stack — the
                // detail band's own discipline, each stage
                // painting the moment its bitmap lands, higher
                // stages covering lower ones:
                //   1. the poster as a blurred field — the
                //      stand-in. The rail card below already
                //      decoded this bitmap, so the hero never
                //      sits black while a usable image is on
                //      the device (the Android FIX4 lesson the
                //      port applied to the detail band but not
                //      to the hero: the old single layer's
                //      thumb URL is decoded nowhere else, so
                //      one failed load = an empty hero for the
                //      view's whole life — the owner's wide
                //      photo);
                //   2. the provider thumb slice (the v2.0.1
                //      art, kept as the fallback) — skipped
                //      when it is the same URL as the poster
                //      (the KK/VS poster fallback), which
                //      stage 1 already paints;
                //   3. the featured film's TMDB w1280 backdrop
                //      (heroBackdropURL, resolved by the task
                //      below) — the primary art, per the
                //      owner's backdrop standard.
                if let url = featured.posterURL {
                    JoeBandImage(url: url, targetPixels: 1920,
                                 anchor: 0.20, portraitMode: .blurField)
                    .frame(maxWidth: .infinity)
                    .frame(height: 668)
                    .clipped()
                }
                if let url = featured.thumbURL, url != featured.posterURL {
                    JoeBandImage(url: url, targetPixels: 1920,
                                 anchor: 0.20, portraitMode: .blurField)
                    .frame(maxWidth: .infinity)
                    .frame(height: 668)
                    .clipped()
                }
                if let heroBackdropURL {
                    JoeBandImage(url: heroBackdropURL, targetPixels: 1920,
                                 anchor: 0.20, portraitMode: .slice)
                    .frame(maxWidth: .infinity)
                    .frame(height: 668)
                    .clipped()
                }
                // UI-3 SCRIM FLOOR (hard requirement): the
                // horizontal scrim never drops below the token
                // floor (0.55 black) anywhere inside the text
                // zone (the left ~65% of the hero), so worst-case
                // text contrast is guaranteed by the TOKEN, not
                // by the backdrop's brightness. The bottom fade
                // only takes over below the text block.
                LinearGradient(stops: [
                    .init(color: .black.opacity(0.92), location: 0),
                    .init(color: .black.opacity(0.80), location: 0.45),
                    .init(color: .black.opacity(theme.scrimFloor), location: 0.65),
                    .init(color: .black.opacity(0.15), location: 0.82),
                    .init(color: .black.opacity(0.05), location: 1)
                ], startPoint: .leading, endPoint: .trailing)
                LinearGradient(stops: [
                    .init(color: .clear, location: 0.55),
                    .init(color: theme.bg, location: 1)
                ], startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 14) {
                    Text("Nổi bật hôm nay")
                        .font(.system(size: 23, weight: .bold))
                        .tracking(3)
                        .foregroundStyle(theme.heroMeta)
                    Text(featured.name)
                        .font(.system(size: 68, weight: .heavy))
                        .foregroundStyle(theme.text)
                        .lineLimit(2)
                    if !featured.originName.isEmpty, featured.originName != featured.name {
                        Text(featured.originName)
                            .font(.system(size: 27))
                            .foregroundStyle(theme.heroMeta)
                            .lineLimit(1)
                    }
                    Text(heroMetaLine(featured))
                        .font(.system(size: 27))
                        .foregroundStyle(theme.heroMeta)
                    // UI-6 D-2: the render's genres line and
                    // synopsis — genres from the list payload's
                    // own category names (heroDetail's parsed
                    // categories behind them), the synopsis from
                    // the featured film's detail fetch.
                    if !heroGenres.isEmpty {
                        Text(heroGenres.joined(separator: " · "))
                            .font(.system(size: 25))
                            .foregroundStyle(theme.heroMeta)
                            .lineLimit(1)
                    }
                    if let synopsis = heroDetail?.content, !synopsis.isEmpty {
                        Text(synopsis)
                            .font(.system(size: 26))
                            .foregroundStyle(theme.text.opacity(0.92))
                            .lineSpacing(6)
                            .lineLimit(3)
                            .frame(maxWidth: 880, alignment: .leading)
                    }
                    HStack(spacing: 16) {
                        Button {
                            nav.movie = MovieRoute(provider: featured.provider,
                                                   slug: featured.slug,
                                                   name: featured.name,
                                                   poster: featured.poster,
                                                   year: featured.year)
                        } label: {
                            JoePrimaryLabel(title: "Xem ngay", systemImage: "play.fill")
                        }
                        .buttonStyle(.card)
                        .focused($heroPlayFocused)
                        Button {
                            toggleHeroFavorite(featured)
                        } label: {
                            JoeSecondaryLabel(title: isHeroFavorite(featured)
                                              ? "♥ Đã thích" : "♡ Yêu thích")
                        }
                        .buttonStyle(.card)
                        Button {
                            nav.browseOpen = true
                        } label: {
                            JoeSecondaryLabel(title: "Tất cả phim",
                                              systemImage: "square.grid.2x2")
                        }
                        .buttonStyle(.card)
                    }
                    .padding(.top, 8)
                }
                .padding(40)
                .frame(maxWidth: 1100, alignment: .leading)
            }
            .frame(height: 668)
            // UI-6 D-2: fetch the featured film's detail for
            // the synopsis (fail-soft — a failed fetch simply
            // leaves the hero without one).
            //
            // Hero forensics fix (2026-11-15): the same task
            // then resolves the featured film's TMDB backdrop
            // for stage 3 of the hero stack — by the payload
            // TMDB id when one is carried (the detail's movie
            // first, the list item behind it: KK parses the
            // tmdb object in both), else the name + year hunt
            // — the detail screen's exact pattern
            // (JoeMovieDetail's TMDB task). Fail-soft end to
            // end: no key, no id and no match simply leave the
            // hero on its provider-art stages.
            .task(id: featured.id) {
                heroDetail = nil
                heroBackdropURL = nil
                heroDetail = try? await Providers.detail(
                    featured.provider, slug: featured.slug)
                guard !TMDBClient.apiKey.isEmpty else { return }
                let m = heroDetail?.movie ?? featured
                var backdrop = ""
                if !m.tmdbId.isEmpty {
                    backdrop = await TMDBClient.fetchInfo(
                        tmdbId: m.tmdbId, type: m.tmdbType)?.backdropURL ?? ""
                }
                if backdrop.isEmpty {
                    backdrop = await TMDBClient.searchBackdrop(
                        name: m.name, origin: m.originName,
                        year: Providers.yearOf(m)) ?? ""
                }
                if !backdrop.isEmpty {
                    heroBackdropURL = URL(string: backdrop)
                }
            }
        }
    }

    /// The render's full hero meta (UI-6 D-2): year · quality
    /// · lang · episode (with the total appended as
    /// "Tập x / y tập" when both are known) · runtime ·
    /// country. Sparse list items borrow the missing fields
    /// from the featured film's detail movie.
    private func heroMetaLine(_ m: Movie) -> String {
        var episode = m.episodeCurrent
        let total = !m.episodeTotal.isEmpty
            ? m.episodeTotal : (heroDetail?.movie.episodeTotal ?? "")
        if episode.hasPrefix("Tập"), !total.isEmpty, total != "0" {
            episode = "\(episode) / \(total) tập"
        }
        let time = !m.time.isEmpty ? m.time : (heroDetail?.movie.time ?? "")
        let country = !m.country.isEmpty
            ? m.country : (heroDetail?.movie.country ?? "")
        return [m.year, m.quality, m.lang, episode, time, country]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// The hero's genre names: the list item's own categories
    /// first (the payloads carry them — D-2), the detail's
    /// parsed categories behind them, its joined categories
    /// string last.
    private var heroGenres: [String] {
        if let featured = heroMovie, !featured.categories.isEmpty {
            return featured.categories
        }
        if let fromDetail = heroDetail?.movie.categories, !fromDetail.isEmpty {
            return fromDetail
        }
        guard let joined = heroDetail?.categories, !joined.isEmpty else { return [] }
        return joined.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func isHeroFavorite(_ m: Movie) -> Bool {
        watch.isFavorite(key: WatchStore.movieFavKey(provider: m.provider, slug: m.slug))
    }

    private func toggleHeroFavorite(_ m: Movie) {
        var e = WatchStore.Entry()
        e.kind = Providers.kindOf(m.provider)
        e.key = WatchStore.movieFavKey(provider: m.provider, slug: m.slug)
        e.title = m.name
        e.poster = m.poster
        e.year = m.year
        e.slug = m.slug
        e.source = m.provider
        e.ts = Int64(Date().timeIntervalSince1970 * 1000)
        watch.toggleFavorite(e)
    }

    // MARK: - Design F header + source bands

    /// F's slim header (the band stack carries the screen; the
    /// header keeps the "Tất cả phim" browse entry and the
    /// first rail's UP landing). Also design A's fallback when
    /// no catalogue film exists yet to feature.
    ///
    /// UI-6 defect D-16 — DECLARED RETENTION (UI-6's fix text
    /// offers "remove or declare"): this header is F's ONLY
    /// focusable element above the owner rails. The first-rail
    /// move handler's UP branch lands on its browse button
    /// (headerFocused), and from there the pills are one
    /// geometric UP away. Removing it would strand the
    /// UP-to-pills chain whenever Continue Watching or
    /// Favourites is on screen (the handler consumes the press
    /// and no element above the entry rails would claim the
    /// focus write). It stays, declared, in both roles.
    private var slimHeader: some View {
        HStack(alignment: .center, spacing: 28) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Thư viện phim")
                    .font(.system(size: 44, weight: .heavy))
                    .foregroundStyle(theme.text)
                Text("KKPhim · Film4K · VSMOV · Tủ Phim — link được lấy mới mỗi lần bấm xem")
                    .font(.system(size: 25))
                    .foregroundStyle(theme.meta)
            }
            Spacer()
            Button {
                nav.browseOpen = true
            } label: {
                JoeSecondaryLabel(title: "Tất cả phim", systemImage: "square.grid.2x2")
            }
            .buttonStyle(.card)
            .focused($headerFocused)
        }
    }

    /// F's source band header (UI-6 defects D-15 + D-3): ONE
    /// row — source name and catalogue note inline on the same
    /// baseline row (the render's .band), padding 28/18, an
    /// inset stroke over the surface2 fill — and the "Xem tất
    /// cả ›" label PAINTS its full frame (a bg capsule behind
    /// the text), so the system platter can never show through
    /// the .card label.
    private func bandHeader(name: String, note: String, scope: String) -> some View {
        HStack(alignment: .center, spacing: 20) {
            Text(name)
                .font(.system(size: 34, weight: .heavy))
                .foregroundStyle(theme.text)
            Text(note)
                .font(.system(size: 24))
                .foregroundStyle(theme.meta)
                .lineLimit(1)
            Spacer()
            Button {
                nav.browseOpen = true
            } label: {
                Text("Xem tất cả ›")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(bandFocused == scope ? theme.text : theme.focusTitle)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(theme.bg))
                    .overlay(JoeFocusRing(shape: Capsule()))
            }
            .buttonStyle(.card)
            .focused($bandFocused, equals: scope)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .background(RoundedRectangle(cornerRadius: 14).fill(theme.surface2))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .strokeBorder(theme.stroke, lineWidth: 1))
    }

    // MARK: - Load states (§8)

    /// True when NO catalogue rail has anything — the C-8
    /// condition for the error surface (CW/Favourites are the
    /// owner's own data, not catalogue health). The predicate
    /// itself lives on the store (PhimStore.catalogueIsEmpty)
    /// so the poster wall's D-20 parity surfaces read the
    /// identical condition.
    private var catalogueEmpty: Bool { phim.catalogueIsEmpty }

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
    /// The computation lives on the store (D-20 parity).
    private var failedProviders: [String] { phim.failedProviderNames }

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
                .foregroundStyle(theme.text)
            Text(phim.loadTimedOut
                 ? "Quá 20 giây chưa có dữ liệu. Kiểm tra mạng và profile Sing-box trên Apple TV."
                 : "Các nguồn phim đều lỗi hoặc trả về trống. Kiểm tra mạng rồi thử lại.")
                .font(.system(size: 25))
                .foregroundStyle(theme.meta)
            // G3: the cause line carries the store's REAL captured
            // errors (providerErrors — what each provider actually
            // threw; pre-v1.9 every error was discarded by try?).
            if !phim.providerErrors.isEmpty {
                Text(phim.providerErrors
                        .sorted { $0.key < $1.key }
                        .map { "\(providerDisplayName($0.key)): \($0.value)" }
                        .joined(separator: " · "))
                    .font(.system(size: 25))
                    .foregroundStyle(theme.meta)
            }
            Button { phim.retry() } label: {
                JoePrimaryLabel(title: "Thử lại")
            }
            .buttonStyle(.card)
            .focused($retryFocused)
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
    /// first movie rail). Derived from the same railSpecs the
    /// body renders, so the two can never drift apart.
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
        for spec in railSpecs where !spec.movies.isEmpty {
            rails.append(spec.movies.map { .movie(spec.scope + "|" + $0.id) })
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
        return railSpecs.first { !$0.movies.isEmpty }?.scope
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
    // handlers are geometric on this layout: header/hero UP →
    // the pills (the row directly above), DOWN → the first
    // rail's first card, or — in the error state — the Retry
    // button, the only focusable element below the header.
    // What geometry does NOT reproduce is the first rail's
    // exact arithmetic, kept below.

    /// First-rail boundary: UP to the hero's play button
    /// (design A, when a hero is on screen) or the header's
    /// browse button (design F / A fallback), LEFT/RIGHT
    /// arithmetic neighbours inside the rail (no-op at its
    /// ends), DOWN to the same-index card (clamped) in the
    /// next rail; with a single rail, DOWN lands on the error
    /// surface's Retry when one is showing (Scope-3), else a
    /// no-op. Installed per-card on the first rail's cards
    /// only (the handler is unconditional; it reads the
    /// CURRENT focus index when a press arrives). Deeper rails
    /// carry no handler — the focus engine's geometry handles
    /// them.
    private func handleFirstRailMove(_ dir: MoveCommandDirection) {
        guard let idx = firstRailFocusIndex,
              let first = phimRails.first else { return }
        if dir == .up {
            if theme.id == .billboard && heroMovie != nil {
                heroPlayFocused = true
            } else {
                headerFocused = true
            }
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
            Rail(title: "▶ Đang xem dở") {
                ForEach(movieProgress) { entry in
                    let card = Button { nav.movie = MovieRoute(
                        provider: entry.source, slug: entry.slug,
                        name: entry.title, poster: entry.poster,
                        year: entry.year, preselectEp: entry.ep) } label: {
                        PosterCard(
                            title: entry.title,
                            posterURL: entry.posterURL,
                            meta: entry.epLabel,
                            badge: Providers.badge(entry.source),
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

    @ViewBuilder
    private var favRail: some View {
        if !movieFavorites.isEmpty {
            Rail(title: "♥ Yêu thích") {
                ForEach(movieFavorites) { entry in
                    let card = Button { nav.movie = MovieRoute(
                        provider: entry.source, slug: entry.slug,
                        name: entry.title, poster: entry.poster,
                        year: entry.year) } label: {
                        PosterCard(
                            title: entry.title,
                            posterURL: entry.posterURL,
                            meta: entry.year,
                            badge: Providers.badge(entry.source),
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
        Rail(title: title) {
            ForEach(movies) { movie in
                let card = Button { nav.movie = MovieRoute(
                    provider: movie.provider, slug: movie.slug,
                    name: movie.name, poster: movie.poster, year: movie.year) } label: {
                    PosterCard(
                        title: movie.name,
                        posterURL: movie.posterURL,
                        meta: movie.cardMeta,
                        badge: badges ? Providers.badge(movie.provider) : nil,
                        quality: movie.quality,
                        focused: focusedMovie == scope + "|" + movie.id)
                }
                .buttonStyle(.card)
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

// MARK: - Rail specs (file scope — shared with the poster wall)

/// One catalogue rail in on-screen order. In design F the
/// four "newest" provider rails carry a source band header;
/// the merged rail is replaced by those bands (it is their
/// aggregate). Every other shelf the app presents — chiếu
/// rạp, Việt Nam, genres, countries, per-provider series /
/// movies / anime — is present in BOTH rail designs, in the
/// 1.9.2 order. Design D's wall (JoeBrowse.swift) renders the
/// non-merged, non-genre specs of the SAME list as titled
/// wall sections (UI-6 defect D-1).
struct JoeRailSpec: Identifiable {
    let scope: String
    let title: String
    let movies: [Movie]
    let badges: Bool
    var bandName: String? = nil
    var bandNote: String? = nil
    var id: String { scope }
}

@MainActor
func joeRailSpecs(phim: PhimStore, themeID: JoeThemeID) -> [JoeRailSpec] {
    var specs: [JoeRailSpec] = []
    if themeID == .sourceBoard {
        specs.append(JoeRailSpec(scope: "kkNew", title: "Mới cập nhật",
                                 movies: phim.kkNew, badges: false,
                                 bandName: "KKPhim",
                                 bandNote: "Kho phim lớn nhất · cập nhật liên tục"))
        specs.append(JoeRailSpec(scope: "f4kNew", title: "Mới cập nhật",
                                 movies: phim.f4kNew, badges: false,
                                 bandName: "Phim4K",
                                 bandNote: "Phim mới mỗi ngày"))
        specs.append(JoeRailSpec(scope: "vsNew", title: "Mới cập nhật",
                                 movies: phim.vsNew, badges: false,
                                 bandName: "VSMOV",
                                 bandNote: "Vietsub · phim bộ & phim lẻ"))
        specs.append(JoeRailSpec(scope: "tpNew", title: "Mới cập nhật",
                                 movies: phim.tpNew, badges: false,
                                 bandName: "Tủ Phim",
                                 bandNote: "Kho lưu trữ · phim chọn lọc"))
    } else {
        specs.append(JoeRailSpec(scope: "merged", title: "✨ Mới cập nhật · Tổng hợp",
                                 movies: phim.merged, badges: true))
    }
    specs.append(JoeRailSpec(scope: "chieuRap", title: "🔥 Phim chiếu rạp",
                             movies: phim.chieuRap, badges: true))
    specs.append(JoeRailSpec(scope: "vnAll", title: "🇻🇳 Phim Việt Nam",
                             movies: phim.vietnamAll, badges: true))
    specs.append(JoeRailSpec(scope: "vnSeries", title: "🇻🇳 Phim bộ Việt Nam",
                             movies: phim.vietnamSeries, badges: true))
    specs.append(JoeRailSpec(scope: "vnSingle", title: "🇻🇳 Phim lẻ Việt Nam",
                             movies: phim.vietnamSingle, badges: true))
    for spec in PhimStore.genreSpec {
        specs.append(JoeRailSpec(scope: "genre:" + spec.slug, title: spec.title,
                                 movies: phim.genreLists[spec.slug] ?? [], badges: true))
    }
    for spec in PhimStore.countrySpec {
        specs.append(JoeRailSpec(scope: "country:" + spec.slug, title: spec.title,
                                 movies: phim.countryLists[spec.slug] ?? [], badges: true))
    }
    if themeID == .sourceBoard {
        specs.append(JoeRailSpec(scope: "kkSeries", title: "📺 KKPhim · Phim bộ mới",
                                 movies: phim.kkSeries, badges: false))
        specs.append(JoeRailSpec(scope: "kkMovies", title: "🎞️ KKPhim · Phim lẻ mới",
                                 movies: phim.kkMovies, badges: false))
        specs.append(JoeRailSpec(scope: "kkAnime", title: "🐣 KKPhim · Hoạt hình",
                                 movies: phim.kkAnime, badges: false))
        specs.append(JoeRailSpec(scope: "f4kMovies", title: "🎞️ Film4K · Phim lẻ mới",
                                 movies: phim.f4kMovies, badges: false))
        specs.append(JoeRailSpec(scope: "vsSeries", title: "🎬 VSMOV · Phim bộ mới",
                                 movies: phim.vsSeries, badges: false))
        specs.append(JoeRailSpec(scope: "tpMovies", title: "📚 Tủ Phim · Phim lẻ mới",
                                 movies: phim.tpMovies, badges: false))
        specs.append(JoeRailSpec(scope: "tpSeries", title: "📚 Tủ Phim · Phim bộ mới",
                                 movies: phim.tpSeries, badges: false))
    } else {
        specs.append(JoeRailSpec(scope: "kkNew", title: "✨ Mới cập nhật",
                                 movies: phim.kkNew, badges: false))
        specs.append(JoeRailSpec(scope: "kkSeries", title: "📺 Phim bộ mới",
                                 movies: phim.kkSeries, badges: false))
        specs.append(JoeRailSpec(scope: "kkMovies", title: "🎞️ Phim lẻ mới",
                                 movies: phim.kkMovies, badges: false))
        specs.append(JoeRailSpec(scope: "kkAnime", title: "🐣 Hoạt hình",
                                 movies: phim.kkAnime, badges: false))
        specs.append(JoeRailSpec(scope: "f4kNew", title: "✨ Film4K · Mới cập nhật",
                                 movies: phim.f4kNew, badges: false))
        specs.append(JoeRailSpec(scope: "f4kMovies", title: "🎞️ Film4K · Phim lẻ mới",
                                 movies: phim.f4kMovies, badges: false))
        specs.append(JoeRailSpec(scope: "vsNew", title: "🎬 VSMOV · Mới cập nhật",
                                 movies: phim.vsNew, badges: false))
        specs.append(JoeRailSpec(scope: "vsSeries", title: "🎬 VSMOV · Phim bộ mới",
                                 movies: phim.vsSeries, badges: false))
        specs.append(JoeRailSpec(scope: "tpMovies", title: "📚 Tủ Phim · Phim lẻ mới",
                                 movies: phim.tpMovies, badges: false))
        specs.append(JoeRailSpec(scope: "tpSeries", title: "📚 Tủ Phim · Phim bộ mới",
                                 movies: phim.tpSeries, badges: false))
    }
    return specs
}

// CONVERGENCE RECORD (2026-11-15): this file's duplicated
// JoeMoveTrap struct is DELETED — see the record at the end of
// JoeTVApp.swift. The header/Retry/first-rail traps it powered
// are replaced by geometric focus movement plus the per-card
// always-installed first-rail handler above.
