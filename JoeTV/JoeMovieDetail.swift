import SwiftUI
import UIKit

/// Movie detail: header (poster, meta, synopsis), the favourite
/// toggle, "Nguồn khác:" chips for the other provider carrying
/// the same film, and per-server episode chips. Tapping an
/// episode builds a PlayDirector — links are resolved FRESH
/// inside the director (never from this screen, never stored),
/// with the Android failover ladder behind it.
struct JoeMovieDetail: View {
    let route: MovieRoute
    @EnvironmentObject private var watch: WatchStore
    @EnvironmentObject private var nav: JoeNavigator
    /// Idea 7a: the follow store (FollowStore.shared) —
    /// observed so the "Theo dõi" toggle's label re-renders
    /// the moment a follow / unfollow lands.
    @ObservedObject private var followStore = FollowStore.shared
    @Environment(\.joeTheme) private var theme
    @State private var provider: String
    @State private var slug: String
    @State private var detail: Detail?
    @State private var tmdb: TMDBInfo?
    /// Idea 3(c) (checkpoint 2.0.25): the title logo lives in
    /// its OWN state now — TMDBClient.fetchInfo no longer
    /// awaits the logo (its TMDBInfo.logoURL is always ""),
    /// so the detail fetches the logo in parallel via
    /// TMDBClient.fetchLogo and publishes it here the moment
    /// it lands ("" until then). The backdrop/overview in
    /// `tmdb` apply as soon as fetchInfo returns; nothing
    /// serialises behind the logo.
    @State private var tmdbLogoURL: String = ""
    @State private var alternatives: [(code: String, slug: String)] = []
    /// Idea 20: the actor page presented over this detail
    /// when a TMDB cast member is tapped — see
    /// JoeActorPage.swift (.tmdb mode).
    @State private var actorRoute: JoeActorRoute?
    /// Idea 21: the franchise strip's resolved state — the
    /// collection name and its PLAYABLE parts only (matched
    /// via Providers.search on the part's TMDB id; unmatched
    /// parts are dropped silently, and the current title's
    /// own part is excluded). Empty = no strip.
    @State private var franchiseName = ""
    @State private var franchiseMovies: [Movie] = []
    /// The film's resolved cross-service identity (v2.0.5,
    /// D3): the detail-time ladder's result (Providers
    /// .resolveIdentity, run in load() alongside
    /// findAlternatives). nil = the ladder has not landed
    /// for this record yet; a landed value with an empty
    /// imdbId is a resolved NEGATIVE — the Torrent entry's
    /// honest state, not a loading state.
    @State private var filmIdentity: Providers.FilmIdentity?
    @State private var loadFailed = false
    /// v2.0.29 (cluster A, items 1b + 4): the first-open
    /// initial-focus landing has been WRITTEN (see
    /// landInitialFocus(on:)) — the write happens once per
    /// detail, at its first paint, never on a provider
    /// switch (the switch path of load() does not call it,
    /// so a switch never yanks focus off the chip the owner
    /// tapped).
    @State private var didLandInitialFocus = false
    @State private var playerHolder: DirectorHolder?
    @State private var switching = false
    /// C-9: the last provider/slug whose detail actually loaded.
    /// A failed switch reverts to these (see load()).
    @State private var lastGoodProvider: String
    @State private var lastGoodSlug: String
    @State private var switchNotice: String?
    /// v2.0.31 (L7): TVB holders struck during this page's
    /// life — a holder whose loaded payload CONTRADICTED
    /// the snapshot identity (or, for a name-fallback
    /// record, failed to affirm it), or that failed to
    /// load at all, is never retried on this page; the
    /// load walks the remaining holders and lands on the
    /// honest no-exact-source state when none are left.
    /// Empty on every non-TVB page.
    @State private var tvbStruck: Set<String> = []
    /// v2.0.31 (L7): every TVB holder struck — the error
    /// slate is showing the no-exact-source wording
    /// instead of a film (and instead of the generic
    /// network wording).
    @State private var tvbNoExactSource = false
    /// v2.0.31 (I1): the auto-pick runs at most once per
    /// page — after it moves the page to a playable
    /// holder, later loads (the switch that follows
    /// included) never re-evaluate into a second move.
    @State private var tvbAutoPickDone = false
    /// Owner source-priority policy (2026-11-15, IN v2.0.0 per
    /// the owner's 16:08 ruling): the Nguồn phát mode for THIS
    /// film's play sessions — Tự động (true, the default) or a
    /// pinned source (false, set by tapping any specific source
    /// chip/row). Per-session state on the detail view: it is
    /// never persisted and resets with the film.
    @State private var autoSource = true
    @FocusState private var focusedEp: String?
    @FocusState private var focusedPlay: Bool
    /// v2.0.5 (N1, pair h): the favourite button joins the
    /// detail's focus system — pre-fix it was the one header
    /// control with NO binding, so the play ↔ favourite pair
    /// had no declared route at all.
    @FocusState private var focusedFav: Bool
    /// Idea 7a: the follow toggle's focus binding, paired
    /// with focusedFav exactly as the favourite button's is.
    @FocusState private var focusedFollow: Bool
    @FocusState private var focusedAlt: String?
    @FocusState private var focusedRetry: Bool
    /// Idea 20: the cast row's focus binding (member ids).
    @FocusState private var focusedCast: Int?
    /// Idea 21: the franchise strip's focus binding.
    @FocusState private var focusedFranchise: String?

    struct DirectorHolder: Identifiable {
        let id = UUID()
        let director: PlayDirector
        /// Player-slate heading data (UI-6 defect D-18): the
        /// film title + episode for the slate's kicker line.
        var title = ""
        var episode = ""
        /// The active source mode for the slate's source line
        /// (owner source-priority policy): "Nguồn: Tự động…"
        /// or the pinned source's name.
        var sourceLine = ""
    }

    init(route: MovieRoute) {
        self.route = route
        _provider = State(initialValue: route.provider)
        _slug = State(initialValue: route.slug)
        _lastGoodProvider = State(initialValue: route.provider)
        _lastGoodSlug = State(initialValue: route.slug)
    }

    private var favKey: String { WatchStore.movieFavKey(provider: provider, slug: slug) }
    private var isFav: Bool { watch.isFavorite(key: favKey) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if theme.id == .ultra {
                ultraBackdrop
            }
            detailScroll
        }
    }

    private var detailScroll: some View {
        ScrollView(.vertical, showsIndicators: false) {
            // v2.0.8 (Phase 7): lazy root — server groups and
            // their episode chips build as they scroll into
            // view instead of all up front. Children, order
            // and the 32 gap are identical to the eager stack.
            LazyVStack(alignment: .leading, spacing: 32) {
                if let detail {
                    if let switchNotice {
                        // C-9: a failed provider switch reverted —
                        // say so, naming both providers (§8).
                        Text(switchNotice)
                            .font(.system(size: 25))
                            .foregroundStyle(.orange)
                    }
                    // v2.0.0 (UI-5): the detail's anatomy follows
                    // the active design over the SAME state, load
                    // logic and actions — A backdrop-led with the
                    // poster overlapping the band, D centred, F
                    // source-list-first.
                    switch theme.id {
                    case .billboard:
                        billboardDetail(detail)
                    case .posterWall:
                        wallDetail(detail)
                    case .sourceBoard:
                        boardDetail(detail)
                    case .ultra:
                        ultraDetail(detail)
                    }
                    // Idea 21: the franchise strip sits at the
                    // END of the detail, below every theme's
                    // episode/server region — one shared slot,
                    // so no theme composition moves. It renders
                    // only when a collection part matched a
                    // playable title (see loadFranchise).
                    franchiseStrip
                } else if loadFailed {
                    // §8: the G3 error shape + Retry.
                    // v2.0.31 (L7): a TVB page that exhausted
                    // its holders says THAT — the app never
                    // substitutes a different film, and the
                    // wording must not blame the network for
                    // an identity verdict.
                    VStack(alignment: .leading, spacing: 16) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 44))
                            .foregroundStyle(.orange)
                        Text(tvbNoExactSource
                             ? "Không mở được đúng phim này."
                             : "Không tải được thông tin phim.")
                            .font(.system(size: 29, weight: .semibold))
                            .foregroundStyle(theme.text)
                        Text(tvbNoExactSource
                             ? "Các nguồn TVB đều không dùng được hoặc không khớp đúng phim — app không mở thay bằng phim khác."
                             : "Kiểm tra mạng rồi thử lại.")
                            .font(.system(size: 25))
                            .foregroundStyle(theme.meta)
                        Button { Task { await retryLoad() } } label: {
                            JoePrimaryLabel(title: "Thử lại")
                        }
                        .joeCardButton()
                        .focused($focusedRetry)
                    }
                    .padding(.top, 60)
                    // v2.0.6 (leader hardening, error-8b doctrine):
                    // the landing on this surface is DECLARED, not
                    // left to load()'s one-shot focusedRetry write
                    // racing the branch swap — the same cure the
                    // player slate got in v2.0.5.
                    .defaultFocus($focusedRetry, true)
                } else {
                    placeholderHeader
                    ProgressView("Đang tải danh sách tập…")
                        .font(.system(size: 29))
                        .foregroundStyle(theme.text)
                        .tint(theme.text)
                }
            }
            // No manual padding: the layer sits inside the root
            // safe area, which IS the §4 inset (80/60).
        }
        .task(id: slug + "|" + provider) { await load() }
        .task(id: detail?.movie.id ?? "") {
            // TMDB enrichment (v1.6), fail-soft: runs when a
            // TMDB API key is available — the bundled key
            // injected at build time, or one the owner saved in
            // Settings (the saved key wins). Any failure leaves
            // tmdb nil and the screen is the provider-only one.
            //
            // v2.0.1 (Android FIX2 parity): the task stays
            // decoupled from the detail fetch (it always was —
            // a separate task) and publishes in stages, so the
            // band never waits behind the credits call. A film
            // whose payload carries no TMDB id — or a record
            // with no backdrop — is hunted by the name + year
            // title search for a backdrop, exactly like the
            // Android pipeline.
            //
            // v2.0.8 (Phase 2): the staging is now literal —
            // fetchInfo's result publishes the MOMENT it lands
            // (before the backdrop hunt starts), then the
            // backdrop hunt (only when still needed) and the
            // cast fetch run as concurrent async lets, each
            // merging into tmdb when it lands: the hunt fills
            // backdropURL, the credits fill cast. Fail-soft
            // everywhere, exactly as before: no info and no
            // hunted backdrop leaves tmdb nil, and cast only
            // ever merges onto a published info.
            guard let detail, !TMDBClient.apiKey.isEmpty else {
                tmdb = nil
                return
            }
            let movie = detail.movie
            var info: TMDBInfo?
            if !movie.tmdbId.isEmpty {
                info = await TMDBClient.fetchInfo(
                    tmdbId: movie.tmdbId, type: movie.tmdbType)
            }
            if let info {
                tmdb = info
            }
            let needsBackdrop = info?.backdropURL.isEmpty ?? true
            async let backdropFetch = backdropHunt(
                needed: needsBackdrop, movie: movie)
            async let castFetch = castIfAvailable(movie: movie)
            let backdropURL = await backdropFetch
            if let backdropURL {
                if var current = tmdb {
                    if current.backdropURL.isEmpty {
                        current.backdropURL = backdropURL
                        tmdb = current
                    }
                } else {
                    var created = TMDBInfo()
                    created.backdropURL = backdropURL
                    tmdb = created
                }
            }
            let cast = await castFetch
            if !cast.isEmpty, var current = tmdb {
                current.cast = cast
                tmdb = current
            }
            if info == nil, backdropURL == nil {
                tmdb = nil
            }
        }
        .task(id: detail?.movie.id ?? "") {
            // Idea 3(c) (checkpoint 2.0.25): the title logo is
            // fetched in PARALLEL with the enrichment task
            // above — its own .task, keyed on the same detail
            // identity, so it starts when the detail loads its
            // TMDB info, is cancelled/restarted with it, and
            // publishes into tmdbLogoURL the moment it lands.
            // fetchInfo's backdrop/overview never wait for it.
            // Fail-soft exactly like the rest of the TMDB
            // chain: no key / no TMDB id / a failed call
            // leaves the logo empty and the text title stands.
            tmdbLogoURL = ""
            guard let detail, !TMDBClient.apiKey.isEmpty,
                  !detail.movie.tmdbId.isEmpty else { return }
            let logo = await TMDBClient.fetchLogo(
                tmdbId: detail.movie.tmdbId, type: detail.movie.tmdbType)
            guard !Task.isCancelled else { return }
            tmdbLogoURL = logo
        }
        .task(id: provider + "|" + slug + "|" + (focusedEp ?? "")
              + "|" + (detail == nil ? "0" : "1")) {
            // v2.0.8 (Phase 2/3): dwell pre-resolve — see
            // dwellPreResolve(). SwiftUI cancels and restarts
            // this task whenever the key changes (provider,
            // slug, focused episode, detail arrival), so
            // speculative work dies on exit/switch by itself.
            await dwellPreResolve()
        }
        .task(id: tmdb?.collectionId ?? 0) {
            // Idea 21: the franchise load — keyed on the
            // loaded TMDBInfo's collection id, so it starts
            // the moment fetchInfo lands a collection and
            // re-runs only for a different one. Fail-soft:
            // no collection / no matched part leaves the
            // strip absent and the detail exactly as it was.
            await loadFranchise()
        }
        .fullScreenCover(item: $actorRoute) { route in
            JoeActorPage(route: route)
        }
        .fullScreenCover(item: $playerHolder) { holder in
            JoePlayerView(director: holder.director,
                          attemptRows: [Providers.displayName(Providers.KK),
                                        Providers.displayName(Providers.VS),
                                        Providers.displayName(Providers.F4K),
                                        Providers.displayName(Providers.TP)],
                          filmTitle: holder.title,
                          filmEpisode: holder.episode,
                          sourceLine: holder.sourceLine)
        }
        .defaultFocus($focusedPlay, true)
        // Menu closes THIS detail (1.9.2, Team 9 item 4): the
        // handler lives on the detail's OWN root — the
        // placement the player's own-root handler device-proves.
        // The 1.9.1 handler sat on the root ZStack's wrapper
        // layer, outside this view, and Menu exited the app
        // from here on device. Unconditional: it exists exactly
        // while the detail does.
        .onExitCommand { nav.movie = nil }
    }

    /// Instant header built from the tapped card's own data,
    /// shown while the provider detail is still loading — the
    /// page never opens on a bare full-screen spinner again
    /// (in v1.1 a detail could spin for 15–20 s). v2.0.0: the
    /// placeholder follows the active design's head anatomy.
    @ViewBuilder
    private var placeholderHeader: some View {
        let m = placeholderMovie()
        switch theme.id {
        case .posterWall:
            // The loaded D detail's rhythm (title margin-top
            // 24 below the poster), so the page keeps its
            // shape when the detail lands.
            VStack(alignment: .center, spacing: 0) {
                posterArt(m)
                Text(route.name)
                    .font(.system(size: 56, weight: .heavy))
                    .foregroundStyle(theme.text)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.top, 24)
                providerChip
                    .padding(.top, 10)
            }
            .frame(maxWidth: .infinity)
        case .sourceBoard:
            HStack(alignment: .top, spacing: 36) {
                posterArt(m)
                VStack(alignment: .leading, spacing: 14) {
                    Text(route.name)
                        .font(.system(size: 54, weight: .heavy))
                        .foregroundStyle(theme.text)
                        .lineLimit(3)
                    if !route.year.isEmpty {
                        Text(route.year)
                            .font(.system(size: 27))
                            .foregroundStyle(theme.meta)
                    }
                    providerChip
                }
                Spacer(minLength: 0)
            }
        case .ultra:
            // Ultra's placeholder rides the full-screen
            // backdrop layer in body (painted from the launch
            // payload): just the title column, in the loaded
            // composition's rhythm.
            VStack(alignment: .leading, spacing: 0) {
                Text(route.name)
                    .font(.system(size: 60, weight: .heavy))
                    .foregroundStyle(theme.text)
                    .lineLimit(3)
                    .padding(.top, 30)
                if !route.year.isEmpty {
                    Text(route.year)
                        .font(.system(size: 29))
                        .foregroundStyle(theme.heroMeta)
                        .padding(.top, 12)
                }
                providerChip
                    .padding(.top, 14)
            }
        case .billboard:
            // v2.0.1: the placeholder carries the SAME band +
            // overlap composition as the loaded detail (the
            // Android pipeline starts at open from the launch
            // payload): the band's poster treatment paints
            // from the tapped card's decoded cache on the
            // first frame, and the page does not change shape
            // when the detail lands.
            VStack(alignment: .leading, spacing: 0) {
                backdropBand(movie: m, tmdbURL: nil)
                HStack(alignment: .top, spacing: 44) {
                    posterArt(m)
                    VStack(alignment: .leading, spacing: 16) {
                        Text(route.name)
                            .font(.system(size: 60, weight: .heavy))
                            .foregroundStyle(theme.text)
                            .lineLimit(3)
                        if !route.year.isEmpty {
                            Text(route.year)
                                .font(.system(size: 29))
                                .foregroundStyle(theme.heroMeta)
                        }
                        providerChip
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, bandVisible(movie: m, tmdbURL: nil) ? -168 : 0)
            }
        }
    }

    /// The placeholder header's movie, assembled OUTSIDE the
    /// @ViewBuilder block above: assignment statements are ()
    /// expressions, and a () child cannot conform to View —
    /// the builder block may only declare the finished value.
    private func placeholderMovie() -> Movie {
        var m = Movie()
        m.provider = provider
        m.slug = slug
        m.name = route.name
        m.poster = route.poster
        m.year = route.year
        return m
    }

    private var providerChip: some View {
        Text(Providers.displayName(provider))
            .font(.system(size: 25, weight: .semibold))
            .foregroundStyle(theme.text.opacity(0.85))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Capsule().fill(theme.surface2))
    }

    // MARK: - Themed detail compositions (v2.0.0)

    /// A — Billboard: backdrop band (430) with the scrim floor,
    /// the poster frame overlapping the band's lower edge, info
    /// to its right; then the Nguồn phát chips and the episode
    /// chips. OWNER FIDELITY RULE (2026-11-15, with his photo of
    /// the render): this page keeps the render's composition
    /// exactly — inside the info column: origin-name, title,
    /// meta line, genre chips, synopsis, actors line, then
    /// Xem ngay / Yêu thích; below the header block: Nguồn phát
    /// chips, then Chọn tập chips. No re-layout.
    private func billboardDetail(_ d: Detail) -> some View {
        // Design-A detail margins (design-A/detail.html): the
        // "Nguồn phát" block sits margin-top 38 below the header
        // block; the "Chọn tập" block is a rail-title block
        // (margin-top 36). Per-element margins, spacing 0 — the
        // uniform 32 gap matched neither drawing value.
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                backdropBand(movie: d.movie, tmdbURL: tmdbBackdropURL)
                header(d)
                    .padding(.top, bandVisible(movie: d.movie,
                                                tmdbURL: tmdbBackdropURL)
                             ? -168 : 0)
            }
            // v2.0.8 (Phase 1): the header region (band +
            // poster + Play/Favourite) joins the section
            // system — composition and margins unchanged.
            .focusSection()
            sourceChips
                .padding(.top, 38)
            servers(d, heading: "Chọn tập", headingSize: 30)
                .padding(.top, 36)
        }
    }

    /// Ultra's fixed full-screen backdrop (v2.0.19): the same
    /// staged stack as the home hero — poster blur field,
    /// provider thumb, TMDB backdrop — behind the whole
    /// detail page, with the Sony scrims (left + a gentle
    /// vertical melt to the page background at the bottom).
    private var ultraBackdrop: some View {
        let m = detail?.movie ?? placeholderMovie()
        return ZStack {
            if let url = m.posterURL {
                JoeBandImage(url: url, targetPixels: 1920,
                             anchor: 0.16, portraitMode: .blurField)
            }
            if let url = m.thumbURL, url != m.posterURL {
                JoeBandImage(url: url, targetPixels: 1920,
                             anchor: 0.16, portraitMode: .blurField)
            }
            if let u = tmdbBackdropURL {
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
        // v2.0.22 (owner photo verdict on 2.0.21: "Ko tràn
        // hết màn hình"): the frame above filled only the
        // SAFE-AREA rect — neither this layer nor the detail's
        // presenting layer in JoeRootView ignores the safe
        // area (only the theme.bg behind them does), so the
        // "full-screen" backdrop painted as an inset picture
        // with near-black bands on all four sides (80 pt
        // sides, 60 pt top/bottom) and the scroll's last rows
        // sat over its raw bottom edge. The backdrop layer
        // now bleeds edge-to-edge, the platform's own idiom
        // (background layers ignore, content respects): the
        // detailScroll beside it keeps the HIG inset exactly
        // as before, so no text moves. Ultra-only — this
        // layer exists for no other theme.
        .ignoresSafeArea()
    }

    /// Ultra — the Sony detail composition (v2.0.19): no
    /// poster frame; one left column over the full-screen
    /// backdrop — logo art (or the text title), gold origin,
    /// gold meta with the IMDb pill, genre chips, the action
    /// row (play + favourite CIRCLE), synopsis, cast circles —
    /// then the shared source chips and episode servers.
    private func ultraDetail(_ d: Detail) -> some View {
        let hasGenres = !d.categories
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .isEmpty
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                if !tmdbLogoURL.isEmpty,
                   let u = URL(string: tmdbLogoURL) {
                    JoeRemoteImage(url: u, targetPixels: 1000, fit: true) {
                        Color.clear
                    }
                    .frame(maxWidth: 640, maxHeight: 120, alignment: .leading)
                    .padding(.top, 30)
                } else {
                    Text(d.movie.name)
                        .font(.system(size: 60, weight: .heavy))
                        .foregroundStyle(theme.text)
                        .lineLimit(3)
                        .padding(.top, 30)
                }
                if tmdbLogoURL.isEmpty,
                   !d.movie.originName.isEmpty,
                   d.movie.originName != d.movie.name {
                    Text(d.movie.originName.uppercased())
                        .font(.system(size: 24, weight: .semibold))
                        .tracking(4)
                        .foregroundStyle(theme.heroMeta)
                        .lineLimit(1)
                        .padding(.top, 10)
                }
                HStack(spacing: 16) {
                    if !d.metaLine.isEmpty {
                        Text(d.metaLine)
                            .font(.system(size: 27, weight: .medium))
                            .foregroundStyle(theme.heroMeta)
                            .lineLimit(1)
                    }
                    if let r = tmdb?.voteAverage, r > 0 {
                        Text(String(format: "IMDb %.1f", r))
                            .font(.system(size: 23, weight: .bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 7)
                                .fill(Color(red: 0.961, green: 0.773, blue: 0.094)))
                    }
                }
                .padding(.top, 12)
                genreChips(d)
                    .padding(.top, hasGenres ? 14 : 0)
                HStack(spacing: 18) {
                    playButton(d)
                    ultraFavCircle(d)
                    followButton(d)
                }
                .padding(.top, 22)
                if !(tmdb?.overview.isEmpty ?? true) || !d.content.isEmpty {
                    Text((tmdb?.overview.isEmpty ?? true)
                         ? d.content : (tmdb?.overview ?? ""))
                        .font(.system(size: 27))
                        .foregroundStyle(theme.text.opacity(0.92))
                        .lineSpacing(8)
                        .lineLimit(4)
                        .frame(maxWidth: 1150, alignment: .leading)
                        .padding(.top, 20)
                }
                if let tmdb, !tmdb.cast.isEmpty {
                    castRow(tmdb.cast)
                        .padding(.top, 24)
                }
            }
            .focusSection()
            sourceChips
                .padding(.top, 38)
            servers(d, heading: "Chọn tập", headingSize: 30)
                .padding(.top, 36)
        }
    }

    /// Ultra's favourite: the reference's round heart button
    /// (favButton's action, a circle face).
    private func ultraFavCircle(_ d: Detail) -> some View {
        Button {
            var e = WatchStore.Entry()
            e.kind = Providers.kindOf(provider)
            e.key = favKey
            e.title = d.movie.name
            e.poster = d.movie.poster
            e.year = d.movie.year
            e.slug = slug
            e.source = provider
            e.ts = Int64(Date().timeIntervalSince1970 * 1000)
            watch.toggleFavorite(e)
        } label: {
            Text(isFav ? "♥" : "♡")
                .font(.system(size: 34))
                .foregroundStyle(isFav
                                 ? Color(red: 0.878, green: 0.169, blue: 0.227)
                                 : theme.text)
                .frame(width: 76, height: 76)
                .background(Circle().fill(theme.surface2))
                .overlay(Circle().strokeBorder(
                    focusedFav ? theme.focus : theme.stroke,
                    lineWidth: focusedFav ? theme.ringWidth : 1.5))
        }
        .joeCardButton()
        .focused($focusedFav)
    }

    /// D — Poster Wall: everything centred (poster, title, meta,
    /// genre chips, synopsis, actions); cast and servers follow
    /// as full-width blocks.
    ///
    /// UI-6 defect D-14 — DECLARED ADDITIONS (UI-6's own
    /// recommendation): two elements on this composition are
    /// not in D's render fingerprint and are kept deliberately
    /// — the origin-name line under the title (the wall cards
    /// carry origin names everywhere else in the app; dropping
    /// it here would make D the only surface that hides a
    /// film's original title) and the providerChip in the
    /// action row (the current source's name, the same status
    /// the other themes' Nguồn phát blocks show). Declared,
    /// not silent.
    private func wallDetail(_ d: Detail) -> some View {
        // Design-D detail (design-D/detail.html): a CENTRED
        // column whose elements carry the drawing's own
        // margins — title 24 below the poster, meta 10, genre
        // chips 16, synopsis 18, buttons 26 (row gap 18),
        // source chips 30, episode chips 16 — so the column
        // runs at spacing 0 with per-element top paddings
        // (absent elements collapse with their margin, like
        // CSS). The origin line and the cast row are app-only
        // elements (kept); they ride the same rhythm.
        let hasGenres = !d.categories
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .isEmpty
        return VStack(alignment: .center, spacing: 0) {
            // v2.0.8 (Phase 1): the header region (poster
            // through the Play/Favourite row) is its own
            // focus section. The Group is layout-transparent,
            // so the centred column's composition, spacing
            // and per-element margins are unchanged.
            Group {
            posterArt(d.movie)
            Text(d.movie.name)
                .font(.system(size: 56, weight: .heavy))
                .foregroundStyle(theme.text)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.top, 24)
            if !d.movie.originName.isEmpty {
                Text(d.movie.originName)
                    .font(.system(size: 29))
                    .foregroundStyle(theme.meta)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .padding(.top, 10)
            }
            if !d.metaLine.isEmpty {
                // UI-6 defect D-14: D's detail meta reads in
                // the theme's heroMeta (the render's meta
                // colour), not the dimmer rail meta. Design
                // size: .hero-meta, 27px medium.
                Text(d.metaLine)
                    .font(.system(size: 27, weight: .medium))
                    .foregroundStyle(theme.heroMeta)
                    .padding(.top, 10)
            }
            genreChips(d)
                .padding(.top, hasGenres ? 16 : 0)
            if !(tmdb?.overview.isEmpty ?? true) || !d.content.isEmpty {
                // Design .hero-syn under D: 27px, white at
                // .92 (the base rule's opacity survives D's
                // size override), max-width 920, centred.
                Text((tmdb?.overview.isEmpty ?? true)
                     ? d.content : (tmdb?.overview ?? ""))
                    .font(.system(size: 27))
                    .foregroundStyle(theme.text.opacity(0.92))
                    .lineSpacing(8)
                    .lineLimit(5)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 920)
                    .padding(.top, 18)
            }
            HStack(spacing: 18) {
                playButton(d)
                favButton(d)
                followButton(d)
                providerChip
            }
            .padding(.top, 26)
            }
            .focusSection()
            if let tmdb, !tmdb.cast.isEmpty {
                // v2.0.29 (cluster A, item 1b): the cast row
                // is its own declared focus region here — in
                // D it stood between the header section and
                // the source section in NO section at all,
                // while every other block on the page (header,
                // sources, episodes) declares one. (Ultra's
                // cast row rides inside its header section and
                // A's actors line inside its header section;
                // neither needs this.)
                castRow(tmdb.cast)
                    .focusSection()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 26)
            }
            // The Nguồn phát row is unconditional in D too —
            // it carries the policy's Tự động chip even when
            // this film has no alternative source. Design-D
            // centres the row (justify-content: center) — no
            // leading frame.
            altChips
                .padding(.top, 30)
            servers(d, centered: true)
                .padding(.top, 16)
        }
        .frame(maxWidth: .infinity)
    }

    /// F — Source Board: compact meta head, then the Nguồn phát
    /// source rows as the PRIMARY block (the current source,
    /// the alternatives as switch actions, the torrent rung's
    /// state), episode chips under them, cast, and the synopsis
    /// demoted to a small 2-line tail.
    private func boardDetail(_ d: Detail) -> some View {
        // Design-F detail (design-F/detail.html): the column
        // carries the drawing's own margins — content row gap
        // 36; title → meta 10, meta → genre chips 16, chips →
        // buttons 22 (button gap 18); the "Nguồn phát" heading
        // margin-top 30; the episode row margin-top 6 below
        // the source rows; the synopsis margin-top 16 — so the
        // column runs at spacing 0 with per-element top
        // paddings (absent elements collapse with their
        // margin, like CSS). The meta line is the drawing's
        // .hero-meta: 27 medium in the heroMeta colour.
        let hasGenres = d.categories.split(separator: ",")
            .contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 36) {
                posterArt(d.movie)
                VStack(alignment: .leading, spacing: 0) {
                    Text(d.movie.name)
                        .font(.system(size: 54, weight: .heavy))
                        .foregroundStyle(theme.text)
                        .lineLimit(3)
                    if !d.movie.originName.isEmpty {
                        Text(d.movie.originName)
                            .font(.system(size: 27))
                            .foregroundStyle(theme.meta)
                            .lineLimit(1)
                            .padding(.top, 10)
                    }
                    if !d.metaLine.isEmpty {
                        Text(d.metaLine)
                            .font(.system(size: 27, weight: .medium))
                            .foregroundStyle(theme.heroMeta)
                            .padding(.top, 10)
                    }
                    genreChips(d)
                        .padding(.top, hasGenres ? 16 : 0)
                    HStack(spacing: 18) {
                        playButton(d)
                        favButton(d)
                        followButton(d)
                    }
                    .padding(.top, 22)
                }
                Spacer(minLength: 0)
            }
            // v2.0.8 (Phase 1): the header region (poster +
            // Play/Favourite block) joins the section
            // system — composition and margins unchanged.
            .focusSection()
            sourceRows(d)
                .padding(.top, 30)
            // UI-6 defect D-11: in F the "Chọn tập" heading is
            // the render's INLINE label beside the chip rows,
            // not a block heading above them.
            HStack(alignment: .top, spacing: 14) {
                Text("Chọn tập")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(theme.text)
                    .padding(.top, 8)
                serverGroups(d)
            }
            .padding(.top, 6)
            // UI-6 defect D-17: F's fingerprint has NO cast
            // row (D keeps its own) — the castRow call that
            // stood here is removed.
            // FIX4 (fix 3) — labelled DEVIATION from D-17:
            // the owner tested 2.0.27 and found no cast
            // anywhere in this theme, so the actor pages
            // (idea 20) were unreachable from every F detail.
            // The shared focusable cast row (the Ultra/D
            // construction) is restored at exactly the slot
            // D-17 emptied, with D's own top margin. The F
            // drawing gains this one row; nothing else in
            // the board changes.
            if let tmdb, !tmdb.cast.isEmpty {
                // v2.0.29 (cluster A, item 1b): its own
                // declared focus region, as in D — the row
                // stood in no section between the source rows'
                // section and the episode block's section.
                castRow(tmdb.cast)
                    .focusSection()
                    .padding(.top, 26)
            }
            if !(tmdb?.overview.isEmpty ?? true) || !d.content.isEmpty {
                Text((tmdb?.overview.isEmpty ?? true)
                     ? d.content : (tmdb?.overview ?? ""))
                    .font(.system(size: 23))
                    .foregroundStyle(theme.meta)
                    .lineSpacing(6)
                    .lineLimit(2)
                    .frame(maxWidth: 1500, alignment: .leading)
                    .padding(.top, 16)
            }
        }
    }

    /// F's source rows: one row per source family, over the
    /// shared membership model (v2.0.5, D1). The policy's
    /// Tự động row leads (owner source-priority policy,
    /// 2026-11-15); the current provider's row pins that
    /// source when tapped; alternative rows are Buttons
    /// performing the same provider switch the alt chips
    /// perform in A/D (with the C-9 revert behind load()) —
    /// every specific-source tap PINS (autoSource off). The
    /// Torrent row (v2.0.5, D2) is a control now, like the
    /// chip anatomies' Torrent chip: pressing it in the
    /// .ready state opens the film's torrent detail; the
    /// substitution rung still fires automatically inside
    /// the director exactly as before.
    private func sourceRows(_ d: Detail) -> some View {
        // Design-F detail: the heading is the .rail-title at
        // the detail's inline 30px (margin-top 30 — applied by
        // boardDetail), margin-bottom 18 to the first row;
        // rows follow at the .srcrow margin-bottom 16. The
        // stack runs at 16 with the heading carrying the extra
        // 2 of bottom margin.
        VStack(alignment: .leading, spacing: 16) {
            Text("Nguồn phát — chọn là xem")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(theme.text)
                .padding(.bottom, 2)
            ForEach(sourceEntries) { entry in
                sourceRowEntry(entry, detail: d)
            }
            if switching {
                HStack(spacing: 12) {
                    ProgressView().tint(theme.text)
                    Text("Đang đổi nguồn…")
                        .font(.system(size: 25))
                        .foregroundStyle(theme.meta)
                }
            }
        }
        // v2.0.5 (N1, pair h): F's source block — the same
        // declared region as the chip anatomies'.
        .focusSection()
    }

    /// One row-anatomy entry (F's half of the shared
    /// membership model).
    @ViewBuilder
    private func sourceRowEntry(_ entry: SourceEntry, detail d: Detail) -> some View {
        switch entry {
        case .auto:
            sourceRow(name: "Tự động",
                      meta: "Phim Âu Mỹ chiếu rạp: ưu tiên Torrent chất lượng cao · còn lại theo thứ tự nguồn",
                      state: autoSource ? "● Đang chọn" : "Sẵn sàng",
                      stateColor: autoSource ? JoeTheme.okGreen : theme.meta,
                      stateWeight: autoSource ? .semibold : .regular,
                      focusID: "auto") {
                autoSource = true
            }
        case .current:
            sourceRow(name: Providers.displayName(provider),
                      meta: d.servers.map { $0.name }.filter { !$0.isEmpty }
                        .joined(separator: " · "),
                      state: autoSource ? "Sẵn sàng" : "● Đang phát",
                      stateColor: autoSource ? theme.meta : JoeTheme.okGreen,
                      stateWeight: autoSource ? .regular : .semibold,
                      focusID: "current") {
                autoSource = false
            }
        case .alternative(let code, let altSlug):
            sourceRow(name: Providers.displayName(code),
                      meta: "Nguồn khác của phim này",
                      state: "Sẵn sàng", stateColor: theme.meta,
                      focusID: code) {
                switchNotice = nil
                autoSource = false
                provider = code
                slug = altSlug
            }
        case .torrent:
            torrentRow
        }
    }

    /// F's Torrent row, by entry state (v2.0.5, D2). The
    /// meta line is unchanged (the rung still substitutes
    /// automatically); what changed is the row's agency:
    /// .ready → a Button opening the film's torrent detail;
    /// .pending / .unresolved → a Button whose press is a
    /// no-op, the state text saying why (never a vanished
    /// row, never a dead press into nowhere); .notConfigured
    /// keeps the shipped status-only "Cần token" row.
    @ViewBuilder
    private var torrentRow: some View {
        switch torrentEntryState {
        case .notConfigured:
            // Design-F detail: the Torrent row's "Cần token"
            // state is the plain .st (meta colour, regular
            // weight) — no warning colour in the drawing.
            sourceRow(name: "Torrent",
                      meta: "Nguồn thay thế tự động khi các nguồn trên đều chết",
                      state: "Cần token",
                      stateColor: theme.meta,
                      action: nil)
        case .pending:
            sourceRow(name: "Torrent",
                      meta: "Nguồn thay thế tự động khi các nguồn trên đều chết",
                      state: "Đang tìm mã IMDb…",
                      stateColor: theme.meta,
                      focusID: "torrent") { }
        case .unresolved:
            sourceRow(name: "Torrent",
                      meta: "Nguồn thay thế tự động khi các nguồn trên đều chết",
                      state: "Chưa tìm được mã IMDb",
                      stateColor: .orange,
                      focusID: "torrent") { }
        case .ready:
            sourceRow(name: "Torrent",
                      meta: "Nguồn thay thế tự động khi các nguồn trên đều chết",
                      state: "Sẵn sàng",
                      stateColor: theme.meta,
                      focusID: "torrent") {
                openTorrentDetail()
            }
        }
    }

    /// One source row (UI-6 defect D-6): SINGLE line — name and
    /// meta inline on one row (the render's .srcrow: name 30
    /// bold, meta 24 in the meta colour, state 25 — regular at
    /// rest, semibold only in the .st.ok / .st.bad variants —
    /// padding 22/30, radius theme.rField, the theme's
    /// surface-gradient fill, and the resting inset stroke 1.5
    /// under the focus ring).
    /// v2.0.5 (N1, pair h): a row with an action AND a focusID
    /// joins the detail's focus system (focusedAlt, the same
    /// binding the chip anatomies use). v2.0.8 (Phase 1):
    /// movement is the focus engine's geometric search — no
    /// hand-written routing. The status-only row
    /// (action nil — "Cần token") stays non-focusable text.
    @ViewBuilder
    private func sourceRow(name: String, meta: String, state: String,
                           stateColor: Color,
                           stateWeight: Font.Weight = .regular,
                           focusID: String? = nil,
                           action: (() -> Void)?) -> some View {
        let row = HStack(alignment: .center, spacing: 20) {
            Text(name)
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(theme.text)
            if !meta.isEmpty {
                Text(meta)
                    .font(.system(size: 24))
                    .foregroundStyle(theme.meta)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(state)
                .font(.system(size: 25, weight: stateWeight))
                .foregroundStyle(stateColor)
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: theme.rField)
            .fill(theme.surfaceGradient))
        .overlay(RoundedRectangle(cornerRadius: theme.rField)
            .strokeBorder(theme.stroke, lineWidth: 1.5))
        if let action {
            let button = Button(action: action) {
                row.overlay(JoeFocusRing(shape: RoundedRectangle(cornerRadius: theme.rField)))
            }
            .joeCardButton()
            if let focusID {
                button
                    .focused($focusedAlt, equals: focusID)
            } else {
                button
            }
        } else {
            row
        }
    }

    /// Genre chips from the detail's categories string (shared
    /// by all three heads; non-focusable decoration).
    @ViewBuilder
    private func genreChips(_ d: Detail) -> some View {
        let genres = d.categories
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if !genres.isEmpty {
            // Design .chip geometry (all three detail drawings):
            // 24px medium, padding 11px 22px, surface2 capsule
            // with the resting inset stroke 1.5 theme.stroke;
            // row gap 12. Non-focusable decoration, so the stroke
            // is unconditional (never the focus ring).
            HStack(spacing: 12) {
                ForEach(genres, id: \.self) { genre in
                    Text(genre)
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(theme.text)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 11)
                        .background(Capsule().fill(theme.surface2))
                        .overlay(Capsule().strokeBorder(theme.stroke,
                                                        lineWidth: 1.5))
                }
            }
        }
    }

    // MARK: - Header (design A composition; pieces shared by D/F heads)

    private func header(_ d: Detail) -> some View {
        // Design-A detail (design-A/detail.html): content row
        // gap 44; the info column's elements carry the drawing's
        // own margins — title margin-top 8 below the origin line,
        // meta 10, genre chips 18, synopsis 18, cast line 14,
        // buttons 26 with gap 18 — so the column runs at
        // spacing 0 with per-element top paddings (absent
        // elements collapse with their margin, like CSS).
        let hasGenres = d.categories.split(separator: ",")
            .contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return HStack(alignment: .top, spacing: 44) {
            posterArt(d.movie)
            // OWNER FIDELITY RULE (design A render, 2026-11-15):
            // the info column's order is the render's — origin
            // name, title, meta line, genre chips, synopsis,
            // actors line, action buttons.
            VStack(alignment: .leading, spacing: 0) {
                if !d.movie.originName.isEmpty {
                    Text(d.movie.originName)
                        .font(.system(size: 24))
                        .foregroundStyle(theme.meta)
                        .lineLimit(1)
                }
                Text(d.movie.name)
                    .font(.system(size: 60, weight: .heavy))
                    .foregroundStyle(theme.text)
                    .lineLimit(3)
                    .padding(.top, 8)
                if !d.metaLine.isEmpty {
                    Text(d.metaLine)
                        .font(.system(size: 27, weight: .medium))
                        .foregroundStyle(theme.heroMeta)
                        .padding(.top, 10)
                }
                genreChips(d)
                    .padding(.top, hasGenres ? 18 : 0)
                if !(tmdb?.overview.isEmpty ?? true) || !d.content.isEmpty {
                    Text((tmdb?.overview.isEmpty ?? true)
                         ? d.content : (tmdb?.overview ?? ""))
                        .font(.system(size: 26))
                        .foregroundStyle(theme.text.opacity(0.92))
                        .lineSpacing(8)
                        .lineLimit(5)
                        .frame(maxWidth: 1020, alignment: .leading)
                        .padding(.top, 18)
                }
                actorsLine
                HStack(spacing: 18) {
                    playButton(d)
                    favButton(d)
                    followButton(d)
                }
                .padding(.top, 26)
            }
            Spacer(minLength: 0)
        }
    }

    /// The render's actors line (design A): the TMDB cast as one
    /// text line inside the info column, between the synopsis
    /// and the buttons. (Designs D and F keep the photo cast
    /// row; in A the line is the render's own presentation.)
    ///
    /// FIX4 (fix 3): the names are BUTTONS now — each opens
    /// its actor page, exactly like the castRow cells in
    /// Ultra/D. Pre-fix the line was one plain Text: visible
    /// but not focusable, so idea 20 was unreachable in this
    /// theme and the owner reported the cast as missing. The
    /// line keeps its slot, prefix, 24 pt size and meta
    /// colour; the separators ride between the buttons as
    /// plain text, and focus paints the name alone (see
    /// JoeActorNameLabel) — at rest the line renders as the
    /// drawing's line.
    ///
    /// v2.0.30 (FIX6): the drawing's separators are " · "
    /// (design-A/detail.html), and its names are WHOLE —
    /// the pre-fix line fed six names into the 1050-pt
    /// column and SwiftUI compressed every label, so the
    /// owner's photo shows each name cut mid-word ("Paul
    /// Betta...", "James Spa..."). The line now admits
    /// whole names only, while they fit (fittedActors);
    /// the names left off stay reachable through the
    /// shown names' actor pages and the other themes'
    /// photo rows.
    @ViewBuilder
    private var actorsLine: some View {
        if let tmdb, !tmdb.cast.isEmpty {
            // Design-A detail cast line: 24px in the meta colour,
            // margin-top 14 (the padding lives inside the
            // conditional so an absent cast collapses fully).
            HStack(spacing: 2) {
                Text("Diễn viên: ")
                    .font(.system(size: 24))
                    .foregroundStyle(theme.meta)
                ForEach(Array(Self.fittedActors(tmdb.cast).enumerated()),
                        id: \.offset) { index, member in
                    if index > 0 {
                        Text(" · ")
                            .font(.system(size: 24))
                            .foregroundStyle(theme.meta)
                    }
                    Button {
                        actorRoute = .tmdb(personId: member.id,
                                            name: member.name,
                                            photoURL: member.photoURL)
                    } label: {
                        JoeActorNameLabel(name: member.name)
                    }
                    .joeCardButton()
                    .focused($focusedCast, equals: member.id)
                }
            }
            .frame(maxWidth: 1050, alignment: .leading)
            .padding(.top, 14)
        }
    }

    /// v2.0.30 (FIX6): which of the cast the design-A line
    /// shows — whole names, in order, while they fit the
    /// line's 1050-pt column at the drawing's own values:
    /// the "Diễn viên: " prefix and each name at 24 pt,
    /// " · " separators, plus each name button's 16 pt of
    /// horizontal plate inset (JoeActorNameLabel's 8 + 8)
    /// and the HStack's 2-pt inter-element gaps.
    /// Measured with the real font (NSString/UIFont), not
    /// estimated. The walk stops at the first name that
    /// would not fit whole — a later, shorter name never
    /// jumps the queue — and the first name always rides,
    /// even if it alone overflows (it then truncates as a
    /// single label, the least-bad state). The standing
    /// six-name presentation cap is kept.
    private static func fittedActors(_ cast: [TMDBCastMember]) -> [TMDBCastMember] {
        let font = UIFont.systemFont(ofSize: 24)
        func width(_ string: String) -> CGFloat {
            (string as NSString).size(withAttributes: [.font: font]).width
        }
        var used = width("Diễn viên: ")
        var fitted: [TMDBCastMember] = []
        for member in cast.prefix(6) {
            // Each name also pays the HStack's 2-pt gaps:
            // one before its button, plus one before its
            // separator when it has one.
            let extra = (fitted.isEmpty ? 2 : 4 + width(" · "))
                + width(member.name) + 16
            guard used + extra <= 1050 else { break }
            used += extra
            fitted.append(member)
        }
        if fitted.isEmpty, let first = cast.first {
            fitted = [first]
        }
        return fitted
    }

/// FIX4 (fix 3): one actor name inside design A's cast
/// line. At rest it IS the drawing's line — 24 pt, meta
/// colour, no chrome. Focused, the name alone gains a
/// quiet plate and semibold weight (the house value-only
/// focus convention for text, JoeChipLabel's family):
/// the line's geometry and resting colours never change.
private struct JoeActorNameLabel: View {
    let name: String
    @Environment(\.isFocused) private var isFocused
    @Environment(\.joeTheme) private var theme

    var body: some View {
        Text(name)
            .font(.system(size: 24,
                          weight: isFocused ? .semibold : .regular))
            .foregroundStyle(isFocused ? theme.text : theme.meta)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(isFocused ? theme.surface2 : Color.clear))
    }
}

    // MARK: - Nguồn phát membership (ONE shared model, v2.0.5)

    /// ONE membership model for the Nguồn phát block
    /// (v2.0.5, D1): the ordered source entries every detail
    /// anatomy renders — Tự động, the current provider, one
    /// entry per alternative provider, and the Torrent
    /// entry LAST, always. Until now each anatomy kept a
    /// private builder and D's never created a Torrent
    /// element at all (the owner's yellow-theme photo: the
    /// chip missing for every title); with membership
    /// computed HERE, an anatomy owns only its layout (A/D
    /// chips, F rows) and cannot silently drop an entry —
    /// the Torrent entry's absence from a layout is now a
    /// compile-visible choice, not an omission.
    private enum SourceEntry: Identifiable {
        case auto
        case current
        case alternative(code: String, slug: String)
        case torrent

        var id: String {
            switch self {
            case .auto: return "auto"
            case .current: return "current"
            case .alternative(let code, _): return "alt|" + code
            case .torrent: return "torrent"
            }
        }
    }

    private var sourceEntries: [SourceEntry] {
        var entries: [SourceEntry] = [.auto, .current]
        entries += alternatives.map {
            .alternative(code: $0.code, slug: $0.slug)
        }
        entries.append(.torrent)
        return entries
    }

    /// The Torrent entry's state (D1/D2): configuration from
    /// TorrentSettings, identity from the detail-time ladder
    /// (filmIdentity). `.pending` = the ladder has not landed
    /// for this record; `.unresolved` = it landed EMPTY — the
    /// honest end state, rendered visibly, never a vanished
    /// entry.
    private enum TorrentEntryState {
        case notConfigured
        case pending
        case ready(imdbId: String)
        case unresolved
    }

    private var torrentEntryState: TorrentEntryState {
        guard TorrentSettings.isConfigured else { return .notConfigured }
        guard let filmIdentity else { return .pending }
        return filmIdentity.imdbId.isEmpty
            ? .unresolved : .ready(imdbId: filmIdentity.imdbId)
    }

    /// The Torrent entry pressed in its .ready state (D2):
    /// open THIS film's torrent detail — the torrent tab's
    /// own screen (JoeTorrentDetail), layered over this
    /// detail by the root (nav.tor, zIndex above the movie
    /// layer), so its own-root Menu handler closes back to
    /// this page with this page's state intact. The meta is
    /// keyed by the resolved IMDb id and addressed through
    /// Cinemeta (the FIX9b lesson: Torrentio serves no
    /// metadata — its base must never be a meta base). Any
    /// other state: the press is a no-op and the entry's
    /// state stays on screen.
    private func openTorrentDetail() {
        guard case .ready(let imdbId) = torrentEntryState,
              let d = detail else { return }
        var meta = TorMeta()
        meta.id = imdbId
        meta.type = torrentMetaType(d)
        meta.name = d.movie.name
        meta.poster = d.movie.poster
        meta.background = tmdb?.backdropURL ?? ""
        meta.year = d.movie.year
        meta.desc = (tmdb?.overview.isEmpty ?? true)
            ? d.content : (tmdb?.overview ?? "")
        nav.tor = TorRoute(meta: meta, base: TorrentSettings.cinemeta)
    }

    /// Movie vs series for the torrent meta: the TMDB type
    /// when any record carries one (the detail's own first,
    /// then the ladder's — the ladder may hold the type the
    /// opened record lacked); with no type on record, a
    /// multi-episode detail is a series (the substitution
    /// rung's own test).
    private func torrentMetaType(_ d: Detail) -> String {
        var type = d.movie.tmdbType
        if type.isEmpty, let resolved = filmIdentity?.tmdbType,
           !resolved.isEmpty {
            type = resolved
        }
        if type == "tv" { return "series" }
        if type.isEmpty {
            let episodeCount = d.servers.reduce(0) { $0 + $1.episodes.count }
            if episodeCount > 1 { return "series" }
        }
        return "movie"
    }

    /// The Torrent entry in the chip anatomies (A + D),
    /// v2.0.5 (D2): a real focusable control now — until now
    /// A rendered a bare non-focusable label and D rendered
    /// nothing. Configured → the button stands (press opens
    /// the torrent detail when the identity is .ready; the
    /// press is a no-op while .pending / .unresolved, with
    /// the state note under the row saying why). Unconfigured
    /// → no chip: design A's shipped treatment (F carries
    /// the "Cần token" row for that state instead).
    @ViewBuilder
    private var torrentChip: some View {
        if TorrentSettings.isConfigured {
            Button {
                openTorrentDetail()
            } label: {
                JoeChipLabel(title: "Torrent", selected: false)
            }
            .joeCardButton()
            .focused($focusedAlt, equals: "torrent")
        }
    }

    /// One chip-anatomy entry (shared by A's sourceChips and
    /// D's altChips — the two rows' buttons were byte-identical
    /// copies; they are one builder now, over the shared
    /// membership model).
    @ViewBuilder
    private func sourceChip(_ entry: SourceEntry) -> some View {
        switch entry {
        case .auto:
            Button {
                autoSource = true
            } label: {
                JoeChipLabel(title: "Tự động", selected: autoSource)
            }
            .joeCardButton()
            .focused($focusedAlt, equals: "auto")
        case .current:
            Button {
                autoSource = false
            } label: {
                JoeChipLabel(title: Providers.displayName(provider),
                             selected: !autoSource)
            }
            .joeCardButton()
            .focused($focusedAlt, equals: "current")
        case .alternative(let code, let altSlug):
            Button {
                switchNotice = nil
                autoSource = false
                provider = code
                slug = altSlug
            } label: {
                JoeChipLabel(title: Providers.displayName(code), selected: false)
            }
            .joeCardButton()
            .focused($focusedAlt, equals: code)
        case .torrent:
            torrentChip
        }
    }

    /// The unresolved-identity note under a chip row: the
    /// row's own meta text treatment (25 pt, theme.meta —
    /// the size/style D's "Nguồn phát:" label already uses).
    @ViewBuilder
    private var torrentUnresolvedNote: some View {
        if case .unresolved = torrentEntryState {
            Text("Chưa tìm được mã IMDb")
                .font(.system(size: 25))
                .foregroundStyle(theme.meta)
        }
    }

    /// Design A's Nguồn phát block (UI-6 defects D-11 + D-12;
    /// owner source-priority policy): the render's bold
    /// "Nguồn phát" block heading over the chip row — Tự động
    /// FIRST (the policy's default), the current source's chip
    /// (tapping PINS it), one chip per alternative source
    /// (tapping switches AND pins — C-9 revert behind load()),
    /// and the Torrent chip (v2.0.5: a real control over the
    /// shared membership model — see sourceChip/torrentChip).
    private var sourceChips: some View {
        // Design-A: the heading→chips gap is the rail-title
        // margin-bottom, 18.
        VStack(alignment: .leading, spacing: 18) {
            Text("Nguồn phát")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(theme.text)
            HStack(spacing: 14) {
                if switching {
                    ProgressView().tint(theme.text)
                }
                ForEach(sourceEntries) { entry in
                    sourceChip(entry)
                }
            }
            torrentUnresolvedNote
        }
        // v2.0.5 (N1, pair h): the source block is a declared
        // focus region between the header pair and the
        // episode block.
        .focusSection()
    }

    /// Poster size per design (A frame 288×432, D 300×450,
    /// F compact 160×240).
    private var posterSize: CGSize {
        switch theme.id {
        case .billboard: return CGSize(width: 288, height: 432)
        case .posterWall: return CGSize(width: 300, height: 450)
        case .sourceBoard: return CGSize(width: 160, height: 240)
        case .ultra: return CGSize(width: 288, height: 432)
        }
    }

    /// The poster, pipeline-backed (v2.0.0 — AsyncImage is gone
    /// from every poster path). A and F set it in a painted
    /// frame (surface fill + padding, the renders' posterframe);
    /// D shows the bare art with a hairline stroke.
    /// IMAGE INTEGRITY (owner rule, 2026-11-15): the slot is an
    /// exact 2:3 frame in every theme (288×432 / 300×450 /
    /// 160×240) and the image is FIT into it — the whole poster
    /// visible, aspect preserved; the painted frame/surface is
    /// the fallback when a poster is missing.
    @ViewBuilder
    private func posterArt(_ m: Movie) -> some View {
        let size = posterSize
        let image = ZStack {
            Color.black.opacity(0.45)
            JoeRemoteImage(url: m.posterURL,
                           targetPixels: theme.id == .sourceBoard ? 480 : 960,
                           fit: true,
                           slotClass: .portrait,
                           fallbackProvider: {
                               await JoeImagePipeline.shared.tmdbPosterURL(
                                   tmdbId: m.tmdbId, type: m.tmdbType)
                           }) {
                Text(m.name)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(18)
            }
        }
        .frame(width: size.width, height: size.height)
        // Concentric radii — the art's clip follows the frame it
        // sits in. Design values (posterframe img radius):
        // A 2px (the approved drawing — an earlier "A: square 0,
        // accepted" note is superseded by the drawing itself);
        // D: the wall's 18 stroke radius; F: rCard − artInset.
        .clipShape(RoundedRectangle(cornerRadius: theme.id == .billboard
                                    ? 2
                                    : (theme.id == .posterWall
                                       ? 18
                                       : max(theme.rCard - theme.artInset, 0))))
        if theme.id == .posterWall {
            // Design-D detail: the poster's frame line is a
            // 2px OUTSET shadow — box-shadow: 0 0 0 2px
            // rgba(255,255,255,.38) — and theme.stroke carries
            // exactly that colour under D.
            image
                .overlay(RoundedRectangle(cornerRadius: 18)
                    .joeOutsetStrokeBorder(theme.stroke, lineWidth: 2))
        } else {
            image
                .padding(theme.artInset)
                .background(RoundedRectangle(cornerRadius: theme.rCard)
                    .fill(theme.surfaceGradient))
                .overlay(RoundedRectangle(cornerRadius: theme.rCard)
                    .strokeBorder(theme.stroke, lineWidth: 1.5))
        }
    }

    private var tmdbBackdropURL: URL? {
        (tmdb?.backdropURL).flatMap { $0.isEmpty ? nil : URL(string: $0) }
    }

    /// The band exists whenever ANY band art can paint: the
    /// TMDB backdrop, the provider thumb, or — v2.0.1 — the
    /// poster itself (the portrait treatment is a real band,
    /// so a poster-only film no longer opens on a missing
    /// band while its TMDB search is still in flight).
    private func bandVisible(movie: Movie, tmdbURL: URL?) -> Bool {
        movie.thumbURL != nil || tmdbURL != nil || movie.posterURL != nil
    }

    /// Design A's backdrop band (430 tall), v2.0.1 — the
    /// Android v2.3 backdrop pipeline expressed natively.
    /// Three image stages in one stack, each painting the
    /// moment its bitmap is on the device, higher stages
    /// covering lower ones as they land (the declarative form
    /// of the Android stage guards — the TMDB layer sits on
    /// top, so nothing can ever paint over the final):
    ///   1. the poster treatment (JoeBandImage): blurred
    ///      field + the whole poster at band height — fed
    ///      from the decoded cache the tapped card warmed,
    ///      so the band's first frame is instant (FIX4 peek);
    ///   2. the provider's landscape thumb as a full-size
    ///      top-anchored slice (FIX round 1 — the centred
    ///      slice cut faces);
    ///   3. the TMDB w1280 backdrop, same slice.
    /// The fade over the whole composite is the design's own
    /// (design-A/detail.html .fade, verbatim):
    /// linear-gradient(0deg, #0A0A0A 5%, rgba(10,10,10,.25)
    /// 60%, rgba(10,10,10,.45)) — read top→bottom: 45% shade
    /// at the top, 25% at 40% of the height, solid foundation
    /// from 95% down, so the poster copy's foot and the
    /// overlapping header text melt into the foundation
    /// exactly as the render has them (this replaces the UI-3
    /// scrim-floor approximation with the design's literal
    /// stops — the same stops the Android build ships).
    /// Pure decoration — no focusable elements. Hidden
    /// entirely when no art exists at all (the header then
    /// renders un-overlapped).
    @ViewBuilder
    private func backdropBand(movie: Movie, tmdbURL: URL?) -> some View {
        if bandVisible(movie: movie, tmdbURL: tmdbURL) {
            ZStack {
                Color.black.opacity(0.45)
                if let url = movie.posterURL {
                    JoeBandImage(url: url, targetPixels: 1920,
                                 anchor: 0.16, portraitMode: .treatment)
                }
                if let url = movie.thumbURL {
                    JoeBandImage(url: url, targetPixels: 1920,
                                 anchor: 0.16, portraitMode: .slice)
                }
                if let url = tmdbURL {
                    JoeBandImage(url: url, targetPixels: 1920,
                                 anchor: 0.16, portraitMode: .slice)
                }
                LinearGradient(stops: [
                    .init(color: theme.bg.opacity(0.45), location: 0),
                    .init(color: theme.bg.opacity(0.25), location: 0.40),
                    .init(color: theme.bg, location: 0.95),
                    .init(color: theme.bg, location: 1)
                ], startPoint: .top, endPoint: .bottom)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 430)
            // v2.0.5 (N5 — design fidelity): DESIGN-SPEC-V19
            // §7.4 specifies this strip with corner radius 18
            // and a white @ 0.14 stroke at 2 pt, and
            // acceptance shot 16 requires the radius VISIBLE;
            // the shipped band was square-cornered (the
            // owner's "Backdrop của theme ko có bo góc").
            // Applied on the band's EXISTING geometry: the
            // height stays 430 — §7.4's frozen 540 predates
            // the approved composition this page was built
            // from (the render + Android pipeline both run
            // 430), so the dimension is flagged in the wave
            // report rather than silently changed here.
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 2))
        }
    }

    // MARK: - Cast (TMDB)

    /// "Diễn viên" row (v1.6): placed right after the header's
    /// overview/meta block, before the alternative-source chips
    /// and the episode servers. Idea 20 (owner-approved): the
    /// cells are now focusable buttons presenting the actor
    /// page — the house .joeCardButton() construction, with
    /// the cell's visuals byte-identical to the non-button
    /// form they replace. (Design A's actorsLine was a plain
    /// text line until v2.0.28 (FIX4 fix 3): its names are
    /// buttons in the line's own dress now — see actorsLine.)
    private func castRow(_ cast: [TMDBCastMember]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Diễn viên")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(theme.text.opacity(0.9))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 24) {
                    ForEach(cast) { member in
                        castCell(member)
                    }
                }
            }
        }
    }

    private func castCell(_ member: TMDBCastMember) -> some View {
        Button {
            actorRoute = .tmdb(personId: member.id, name: member.name,
                                photoURL: member.photoURL)
        } label: {
            JoeCastCellLabel(member: member)
        }
        .joeCardButton()
        .focused($focusedCast, equals: member.id)
    }

/// v2.0.29 (cluster A, item 1a): one cast cell's label.
/// Until now this label painted NO focus state at all —
/// .joeCardButton() suppresses the system focus effect
/// centrally, and every other focusable surface in the app
/// survives that by reading its own focus from the
/// environment and painting a value-only ring (PosterCard,
/// JoeChipLabel, JoePrimaryLabel). The cast cell never did,
/// so a focused cast cell was pixel-identical to an
/// unfocused one and the owner could not tell which actor
/// held focus ("không có focus"). The label now reads
/// \.isFocused exactly like PosterCard does: focused, the
/// photo gains the theme's ring (ringWidth, theme.focus —
/// the cell carries no selected fill, so the posterWall
/// white-ring exception for yellow-filled items does not
/// apply) and the name takes the focus title colour.
/// Every resting value (110 pt circle, white .10 fill,
/// white .14 / 1.2 resting stroke, 23 pt name/character,
/// 120 width) is byte-identical to the pre-fix label.
private struct JoeCastCellLabel: View {
    let member: TMDBCastMember
    @Environment(\.isFocused) private var isFocused
    @Environment(\.joeTheme) private var theme

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().fill(Color.white.opacity(0.10))
                if !member.photoURL.isEmpty, let url = URL(string: member.photoURL) {
                    JoeRemoteImage(url: url, targetPixels: 240) {
                        initial
                    }
                } else {
                    initial
                }
            }
            .frame(width: 110, height: 110)
            .clipShape(Circle())
            .overlay(Circle()
                .strokeBorder(isFocused ? theme.focus
                                        : Color.white.opacity(0.14),
                              lineWidth: isFocused ? theme.ringWidth : 1.2))
            Text(member.name)
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(isFocused ? theme.focusTitle : theme.text)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            if !member.character.isEmpty {
                Text(member.character)
                    .font(.system(size: 23))
                    .foregroundStyle(theme.meta)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(width: 120)
    }

    private var initial: some View {
        Text(String(member.name.prefix(1)))
            .font(.system(size: 38, weight: .bold))
            .foregroundStyle(.white.opacity(0.8))
    }
}

    // MARK: - Franchise strip (Idea 21)

    /// The collection strip at the END of the detail: the
    /// house Rail over the matched parts' PosterCards. A
    /// tap opens that part's Movie through the navigator —
    /// the detail's own route is cleared and re-minted, the
    /// same fresh-detail build a rail tap gets (this detail's
    /// @State was built from ITS route and cannot retarget
    /// in place).
    @ViewBuilder
    private var franchiseStrip: some View {
        if !franchiseMovies.isEmpty {
            Rail(title: "🎞️ Thuộc bộ phim: \(franchiseName)") {
                ForEach(franchiseMovies) { movie in
                    Button { openFranchise(movie) } label: {
                        PosterCard(
                            title: movie.name,
                            posterURL: movie.posterURL,
                            tmdbId: movie.tmdbId,
                            tmdbType: movie.tmdbType,
                            meta: movie.cardMeta,
                            badge: Providers.badge(movie.provider),
                            form: .rail)
                    }
                    .joeCardButton()
                    .focused($focusedFranchise, equals: movie.id)
                }
            }
        }
    }

    private func openFranchise(_ movie: Movie) {
        let movieRoute = MovieRoute(
            provider: movie.provider, slug: movie.slug,
            name: movie.name, poster: movie.poster, year: movie.year)
        nav.movie = nil
        Task { @MainActor in nav.movie = movieRoute }
    }

    /// Resolve the loaded TMDBInfo's collection into
    /// PLAYABLE parts. Each part is searched by title across
    /// the providers (priority order) and accepted ONLY on a
    /// TMDB-id match — a title lookalike is not the part.
    /// Bounded: at most one search pass per part, at most 8
    /// cards. The current title's own part is EXCLUDED (the
    /// owner is already on its detail; a "Đang xem" card for
    /// it would be a dead-end duplicate). Unmatched parts
    /// are dropped silently. Fail-soft throughout.
    private func loadFranchise() async {
        franchiseName = ""
        franchiseMovies = []
        guard let info = tmdb, info.collectionId > 0 else { return }
        let parts = await TMDBClient.fetchCollection(id: info.collectionId)
        let selfKey = detail?.movie.tmdbId ?? ""
        var matched: [Movie] = []
        for part in parts {
            if Task.isCancelled { return }
            if matched.count >= 8 { break }
            let partKey = part.tmdbId
            if !selfKey.isEmpty, partKey == selfKey { continue }
            if matched.contains(where: { $0.tmdbId == partKey }) { continue }
            for code in Providers.priority {
                guard let results = try? await Providers.search(
                    code, keyword: part.title)
                else { continue }
                if let hit = results.first(where: {
                    $0.tmdbId == partKey && !$0.slug.isEmpty
                        && ($0.tmdbType.isEmpty || $0.tmdbType == "movie")
                }) {
                    matched.append(hit)
                    break
                }
            }
        }
        guard !Task.isCancelled else { return }
        franchiseName = info.collectionName
        franchiseMovies = matched
    }

    // MARK: - Play now

    /// The episode the big play button starts: the route's
    /// preselected episode, else the stored Continue Watching
    /// episode for this title, else the first playable episode.
    private func startEpisode(_ d: Detail) -> String? {
        let all = d.servers.flatMap { $0.episodes }
        func exists(_ name: String) -> Bool {
            all.contains { $0.name == name
                && Providers.isPlayable(code: provider, episode: $0) }
        }
        if !route.preselectEp.isEmpty, exists(route.preselectEp) {
            return route.preselectEp
        }
        if let e = watch.progressForTitle(slug: slug, provider: provider,
                                          title: d.movie.name,
                                          year: d.movie.year), exists(e.ep) {
            return e.ep
        }
        return all.first { Providers.isPlayable(code: provider, episode: $0) }?.name
    }

    private func playButton(_ d: Detail) -> some View {
        let isResume = !route.preselectEp.isEmpty
            || watch.progressForTitle(slug: slug, provider: provider,
                                      title: d.movie.name,
                                      year: d.movie.year) != nil
        return Button {
            if let ep = startEpisode(d) { play(d, epName: ep) }
        } label: {
            JoePrimaryLabel(title: isResume ? "Xem tiếp" : "Xem ngay",
                            systemImage: "play.fill")
        }
        .joeCardButton()
        .focused($focusedPlay)
        .disabled(startEpisode(d) == nil || switching)
        // v2.0.8 (Phase 1): no hand-written exits — the
        // header sits in its own .focusSection() (see the
        // themed compositions) and the focus engine moves
        // geometrically from here.
    }

    private func favButton(_ d: Detail) -> some View {
        Button {
            var e = WatchStore.Entry()
            e.kind = Providers.kindOf(provider)
            e.key = favKey
            e.title = d.movie.name
            e.poster = d.movie.poster
            e.year = d.movie.year
            e.slug = slug
            e.source = provider
            e.ts = Int64(Date().timeIntervalSince1970 * 1000)
            watch.toggleFavorite(e)
        } label: {
            // UI-6 defect D-10: built on the shared label
            // metrics (JoeSecondaryLabel — design .btn: 29 pt
            // semibold, padding 17 vertical / 36 horizontal,
            // resting inset stroke 1.5 theme.stroke, focused
            // ring inside at ringWidth) so the favourite toggle
            // can never drift from the other action labels
            // again. The ring reads this button's own
            // focusedFav binding — the same focus value the
            // environment ring would see.
            Text(isFav ? "♥ Đã thích" : "♡ Yêu thích")
                .font(.system(size: 29, weight: .semibold))
                .foregroundStyle(isFav ? JoeTheme.accentRed : theme.text)
                .padding(.horizontal, 36)
                .padding(.vertical, 17)
                .background(Capsule().fill(theme.surface2))
                .overlay(Capsule().strokeBorder(
                    focusedFav ? theme.focus : theme.stroke,
                    lineWidth: focusedFav ? theme.ringWidth : 1.5))
        }
        .joeCardButton()
        // v2.0.5 (N1, pair h): the favourite button's binding
        // (see focusedFav). v2.0.8 (Phase 1): its exits are
        // the focus engine's geometric moves — no
        // hand-written routing.
        .focused($focusedFav)
    }

    /// Idea 7a: is this detail a SERIES? Counted over the
    /// SAME episode lists the episode UI renders
    /// (serverGroups over d.servers), playable-only — the
    /// test startEpisode applies to the same lists. More
    /// than one playable episode across all servers =
    /// series; a "Full" / single-episode movie is not, and
    /// shows no follow toggle at all.
    private func isSeries(_ d: Detail) -> Bool {
        d.servers.flatMap { $0.episodes }
            .filter { Providers.isPlayable(code: provider, episode: $0) }
            .count > 1
    }

    private func isFollowing(_ d: Detail) -> Bool {
        followStore.isFollowing(provider: provider, slug: d.movie.slug)
    }

    /// Idea 7a: the "Theo dõi" (follow) toggle — SERIES
    /// titles only (see isSeries), standing beside the
    /// favourite control in every detail anatomy. Built
    /// EXACTLY as favButton is built (the same Text label
    /// construction: 29 pt semibold, 36/17 padding,
    /// surface2 capsule, the label's stroke reading this
    /// button's own focus binding, .joeCardButton()) — no
    /// new visual language. The selected-state treatment
    /// matches the favourite button's: the accent-red
    /// foreground while following, theme.text otherwise.
    /// Tapping toggles through FollowStore.shared; the
    /// current episode count is parsed from the detail
    /// movie's episodeCurrent string by the store's own
    /// parser.
    @ViewBuilder
    private func followButton(_ d: Detail) -> some View {
        if isSeries(d) {
            Button {
                _ = FollowStore.shared.toggle(
                    provider: provider,
                    slug: d.movie.slug,
                    title: d.movie.name,
                    poster: d.movie.poster,
                    currentEpisodes: FollowStore.episodeCount(
                        from: d.movie.episodeCurrent))
            } label: {
                Text(isFollowing(d) ? "Đang theo dõi" : "Theo dõi")
                    .font(.system(size: 29, weight: .semibold))
                    .foregroundStyle(isFollowing(d)
                                     ? JoeTheme.accentRed : theme.text)
                    .padding(.horizontal, 36)
                    .padding(.vertical, 17)
                    .background(Capsule().fill(theme.surface2))
                    .overlay(Capsule().strokeBorder(
                        focusedFollow ? theme.focus : theme.stroke,
                        lineWidth: focusedFollow ? theme.ringWidth : 1.5))
            }
            .joeCardButton()
            .focused($focusedFollow)
        }
    }

    // MARK: - Nguồn phát chips (design D)

    /// Design D's Nguồn phát row (owner source-priority
    /// policy): Tự động first, the current source (tap pins),
    /// then the alternative sources (tap switches + pins) —
    /// and, since v2.0.5, the Torrent chip: D's private
    /// builder used to end at the alternatives, so the chip
    /// was missing here for EVERY title (the owner's
    /// yellow-theme photo). Membership comes from the shared
    /// model now (sourceEntries/sourceChip); D keeps only
    /// its inline "Nguồn phát:" label and the centred
    /// composition around the row.
    private var altChips: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                if switching {
                    ProgressView().tint(theme.text)
                }
                Text("Nguồn phát:")
                    .font(.system(size: 25, weight: .medium))
                    .foregroundStyle(theme.meta)
                ForEach(sourceEntries) { entry in
                    sourceChip(entry)
                }
            }
            torrentUnresolvedNote
        }
        // v2.0.5 (N1, pair h): D's source block — the same
        // declared region as A's (see sourceChips).
        .focusSection()
    }

    // MARK: - Servers & episodes

    /// Episode block with an optional block heading (design
    /// A: "Chọn tập" at 30 — UI-6 defect D-11; design D: no
    /// heading, the render's call). Design F uses
    /// serverGroups directly beside its inline label.
    private func servers(_ d: Detail, heading: String? = nil,
                         headingSize: CGFloat = 34,
                         centered: Bool = false) -> some View {
        // Design-A: heading→groups gap = rail-title
        // margin-bottom 18 (with no heading the stack has a
        // single child and the spacing never paints).
        // Design-D centres the block (its detail column is
        // centred end to end); A and F keep the leading form.
        VStack(alignment: centered ? .center : .leading, spacing: 18) {
            if let heading {
                Text(heading)
                    .font(.system(size: headingSize, weight: .bold))
                    .foregroundStyle(theme.text)
            }
            serverGroups(d, centered: centered)
        }
    }

    /// The per-server episode groups. UI-6 defect D-4: the
    /// chips are content-sized CAPSULES in a wrapping flow row
    /// (the renders' shape, and the owner's photo of the
    /// shipped design) — no stretched grid cells.
    private func serverGroups(_ d: Detail, centered: Bool = false) -> some View {
        VStack(alignment: centered ? .center : .leading, spacing: 34) {
            ForEach(Array(d.servers.enumerated()), id: \.offset) { serverIndex, server in
                VStack(alignment: centered ? .center : .leading, spacing: 14) {
                    if d.servers.count > 1 || !server.name.isEmpty {
                        Text(server.name)
                            .font(.system(size: 25, weight: .semibold))
                            .foregroundStyle(theme.meta)
                    }
                    // Design chip-row gap: 14 (design-A detail
                    // episode chips; the flow layout's spacing is
                    // both the horizontal and vertical gap).
                    // Design-D centres each row.
                    FlowLayout(spacing: 14, centered: centered) {
                        ForEach(Array(server.episodes.enumerated()), id: \.offset) { epIndex, ep in
                            epChip(d, ep: ep, serverIndex: serverIndex,
                                   episodeIndex: epIndex)
                        }
                    }
                }
            }
        }
        // v2.0.5 (N1, pair h): the episode block is a
        // declared focus region in every anatomy (it is the
        // Dark Waters "link list" the owner's video starts
        // from).
        .focusSection()
    }

    private func epChip(_ d: Detail, ep: Episode, serverIndex: Int,
                        episodeIndex: Int) -> some View {
        let focusKey = "\(serverIndex)|\(ep.name)"
        let playable = Providers.isPlayable(code: provider, episode: ep)
        let storedEp = watch.progressForTitle(slug: slug, provider: provider,
                                              title: d.movie.name,
                                              year: d.movie.year)?.ep
        let preselected = ep.name == (!route.preselectEp.isEmpty
                                      ? route.preselectEp : storedEp)
        // F4: focus identity is "<serverIndex>|<episodeName>" —
        // every server has its own "Tập 1", and keying by name
        // alone lit up one chip per server at once (C-3).
        let focused = focusedEp == focusKey
        return Button {
            play(d, epName: ep.name)
        } label: {
            // UI-6 defect D-4: the renders' capsule chip —
            // content-sized, 24 pt, 22/11 padding; the
            // preselected episode is a SOLID accent fill with
            // onAccent text (not a 30% tint); focus is the
            // theme ring value inside the always-installed
            // capsule stroke.
            Text(ep.name)
                .font(.system(size: 24, weight: preselected ? .semibold : .medium))
                .foregroundStyle(!playable ? theme.text.opacity(0.35)
                                  : (preselected ? theme.onAccent : theme.text))
                .lineLimit(1)
                .padding(.horizontal, 22)
                .padding(.vertical, 11)
                .background(Capsule()
                    .fill(preselected ? theme.accent : theme.surface2))
                // v2.0.9 (owner defect, theme D only): the same
                // colour collision as JoeChipLabel — in D the
                // preselected episode's fill (accent #FFD60A)
                // and the focus ring (focus #FFD60A) are one
                // colour, so focus on the preselected chip was
                // invisible. The owner's ruling applies here
                // too: preselected + focused in D wears the
                // opaque-white (trắng đục) frame; every other
                // state and theme keeps the expression below
                // unchanged.
                .overlay(Capsule()
                    .strokeBorder(focused
                                  ? (theme.id == .posterWall && preselected
                                     ? Color.white : theme.focus)
                                  : (preselected ? Color.clear : theme.stroke),
                                  lineWidth: focused ? theme.ringWidth : 1.5))
        }
        .joeCardButton()
        .focused($focusedEp, equals: focusKey)
        .disabled(!playable || switching)
        // v2.0.8 (Phase 1): geometric movement only — the
        // episode block is a .focusSection() and the engine
        // crosses it (and leaves it in every direction)
        // without hand-written routing.
    }

    // MARK: - Loading + playing

    /// v2.0.29 (cluster A, items 1b + 4): write the detail's
    /// initial focus ONCE, at its first paint. The page's
    /// only other landing declaration is the appearance-time
    /// .defaultFocus($focusedPlay, true) on detailScroll —
    /// but the play button does not exist while the
    /// placeholder stands, and when the loaded detail has NO
    /// playable episode (a movie whose provider detail
    /// carries no playable server/episode — TpClient and
    /// KkClient both append a server only when its episodes
    /// are non-empty, so such a detail's servers list is
    /// empty and startEpisode is nil) the play button is
    /// DISABLED, i.e. not focusable at all. The declared
    /// landing then resolves to nothing the owner can see
    /// or move: the page sits on its header block with no
    /// focus anywhere, no remote press can move, and the
    /// ScrollView — which scrolls by following focus — can
    /// never scroll (the owner's poster-wall photo: a movie
    /// detail showing poster/title/meta/genres/synopsis and
    /// nothing reachable below; series, whose play button is
    /// enabled, land and scroll normally on the same code).
    /// Writing the landing at first paint — the same
    /// mechanism the error branch already uses
    /// (focusedRetry = true) — makes it deterministic:
    /// Xem ngay when it can take focus, Yêu thích when it
    /// cannot (the favourite button is never disabled, so
    /// the page always has a live focus and can scroll to
    /// its source chips, cast and episode blocks).
    private func landInitialFocus(on d: Detail) {
        guard !didLandInitialFocus else { return }
        didLandInitialFocus = true
        if startEpisode(d) != nil {
            focusedPlay = true
        } else {
            focusedFav = true
        }
    }

    private func load() async {
        // First open: the placeholder header carries the page.
        // Provider switch: the CURRENT detail stays on screen
        // until the new one lands — v1.1 blanked the page back
        // to a spinner, which read as "another sources page".
        let hadDetail = detail != nil
        let attemptedProvider = provider
        let attemptedSlug = slug
        if !hadDetail { loadFailed = false }
        switching = hadDetail
        // v2.0.8 (Phase 3g): warm the loopback proxy as the
        // detail opens — a play tap from here is predictable,
        // so the listener's port is ready before it. This is
        // the SAME entry point the tap path uses (playlistURL
        // calls start()); start() is idempotent. App launch
        // stays unwarmed (the standing decision in JoeTVApp).
        JoeProxy.shared.start()
        if hadDetail {
            // Provider switch: the pre-v2.0.8 behaviour,
            // exactly — no cache read, the current detail
            // stays on screen through the fetch, the
            // alternatives/identity chain is awaited inline,
            // and the C-9 revert below is unchanged in
            // behaviour. (v2.0.8 adds only the TP probe merge
            // and the PerfLog paint marks — diagnostics, not
            // behaviour.)
            do {
                let d = try await Providers.detail(provider, slug: slug)
                JoeDetailCache.write(d, provider: attemptedProvider,
                                     slug: attemptedSlug)
                // v2.0.31 (L7): the TVB identity gate — a
                // payload that is not the snapshot's film
                // never paints (see tvbGate). Non-TVB
                // routes pass straight through.
                guard tvbGate(d, attemptedProvider: attemptedProvider) else {
                    switching = false
                    return
                }
                detail = d
                PerfLog.mark("detail.networkPaint")
                switching = false
                lastGoodProvider = provider
                lastGoodSlug = slug
                launchTPProbe(painted: d,
                              paintedProvider: attemptedProvider,
                              paintedSlug: attemptedSlug)
                // v2.0.31 (L7): a TVB page's alternatives
                // are the snapshot's own holders, never a
                // name search (see tvbOrderedAlternatives);
                // every other route keeps findAlternatives.
                if route.tvb != nil {
                    alternatives = await tvbOrderedAlternatives(playable: nil)
                } else {
                    alternatives = await Providers.findAlternatives(
                        fromCode: provider, name: d.movie.name,
                        origin: d.movie.originName, year: d.movie.year,
                        tmdbId: d.movie.tmdbId)
                }
                PerfLog.mark("detail.alternativesPaint")
                // v2.0.5 (D3): the detail-time identity ladder
                // runs alongside the alternatives lookup and lands
                // in view state, so the source row re-renders with
                // the Torrent entry's state the moment it resolves.
                // v2.0.31 (L7): for a TVB session the ladder's
                // answer is pinned to the snapshot's ids.
                filmIdentity = tvbPinnedIdentity(
                    await Providers.resolveIdentity(
                        movie: d.movie, fromCode: provider,
                        alternatives: alternatives))
                PerfLog.mark("detail.identityPaint")
            } catch {
                switching = false
                if attemptedProvider != lastGoodProvider
                    || attemptedSlug != lastGoodSlug {
                    // C-9: the switch failed — REVERT to the provider
                    // whose detail is actually on screen and say so.
                    // (v1.8 left provider/slug pointing at the new
                    // source over the old source's data: a silent
                    // hybrid page whose favourite key and playability
                    // checks belonged to a different film.) The
                    // revert re-fires this task for the good provider;
                    // its success path leaves switchNotice standing.
                    provider = lastGoodProvider
                    slug = lastGoodSlug
                    switchNotice = "Không tải được nguồn \(Providers.displayName(attemptedProvider)) — vẫn dùng nguồn \(Providers.displayName(lastGoodProvider))"
                }
            }
            return
        }
        // First open (v2.0.8, Phase 2): the cache read and the
        // network fetch RACE. v2.0.1 DetailCache (Android FIX2
        // parity): a cached payload paints the full detail as
        // soon as the read lands — now via readAsync, off the
        // view's synchronous path, and only if the fetch has
        // not painted first. The fetch then acts as a refresh:
        // it writes the cache as always and repaints only when
        // the payload actually changed (fingerprint); a failed
        // fetch never errors over a cache-filled screen.
        // The race bookkeeping lives in a reference box
        // (DetailLoadRace): both racers run on the main actor,
        // so each paint block executes atomically between
        // awaits and the flags can never tear.
        let race = DetailLoadRace()
        let cacheTask = Task {
            if let cached = await JoeDetailCache.readAsync(
                provider: attemptedProvider, slug: attemptedSlug),
               !race.networkPainted {
                // v2.0.31 (L7): the TVB identity gate covers
                // the cache paint too — a cached payload for
                // a name-fallback slug can be a different
                // film, and the owner's complaint is exactly
                // that the wrong film OPENS.
                guard tvbGate(cached, attemptedProvider: attemptedProvider)
                else { return }
                detail = cached
                landInitialFocus(on: cached)
                race.cachedPaint = cached
                PerfLog.mark("detail.cachePaint")
                launchTPProbe(painted: cached,
                              paintedProvider: attemptedProvider,
                              paintedSlug: attemptedSlug)
            }
        }
        do {
            let d = try await Providers.detail(provider, slug: slug)
            JoeDetailCache.write(d, provider: attemptedProvider,
                                 slug: attemptedSlug)
            race.networkPainted = true
            // v2.0.31 (L7): the TVB identity gate (see
            // tvbGate). A strike here advances provider/slug
            // and the .task(id:) re-fire loads the next
            // holder; nothing of this payload paints.
            guard tvbGate(d, attemptedProvider: attemptedProvider) else {
                switching = false
                return
            }
            if let cachedPaint = race.cachedPaint {
                if JoeDetailCache.fingerprint(d)
                    != JoeDetailCache.fingerprint(cachedPaint) {
                    detail = d
                    landInitialFocus(on: d)
                    PerfLog.mark("detail.networkPaint")
                    launchTPProbe(painted: d,
                                  paintedProvider: attemptedProvider,
                                  paintedSlug: attemptedSlug)
                }
                // Same payload: the cached render stands. The
                // fresh copy's stream URLs are NOT needed —
                // the play path re-resolves them fresh at tap
                // time (makeDirector's ladder resolves stream
                // URLs through the memoised resolver), so
                // nothing stale can reach the player from
                // either copy.
            } else {
                detail = d
                landInitialFocus(on: d)
                PerfLog.mark("detail.networkPaint")
                launchTPProbe(painted: d,
                              paintedProvider: attemptedProvider,
                              paintedSlug: attemptedSlug)
            }
            switching = false
            lastGoodProvider = provider
            lastGoodSlug = slug
            // Progressive alternatives + identity (Phase 2):
            // launched, not awaited — the source row and the
            // Torrent entry's state fill in as they land, and
            // neither blocks this return, the paint above, or
            // the switching transition.
            launchAlternativesAndIdentity(movie: d.movie,
                                          fromCode: provider,
                                          forSlug: slug)
        } catch {
            switching = false
            // The fetch failed: if the cache read is still in
            // flight, wait for its verdict before deciding —
            // its paint (if any) runs inside cacheTask before
            // the value lands here.
            if race.cachedPaint == nil {
                _ = await cacheTask.value
            }
            if let cachedPaint = race.cachedPaint {
                // The cache-filled screen stays — no error
                // surface, no revert (the painted detail IS
                // the attempted provider's own). Alternatives
                // and identity still run off the cached
                // payload: the source row must not wait on a
                // detail fetch that already failed once.
                launchAlternativesAndIdentity(
                    movie: cachedPaint.movie,
                    fromCode: attemptedProvider,
                    forSlug: attemptedSlug)
            } else if route.tvb != nil,
                      attemptedProvider == provider,
                      attemptedSlug == slug,
                      tvbStrikeAndAdvance(reason: "không tải được") {
                // v2.0.31 (I1/L7): a TVB holder that fails
                // to LOAD at all is struck like a
                // contradicting one — the page walks the
                // snapshot's holders before it gives up,
                // instead of dying on the first source.
                // The provider/slug change re-fires this
                // task for the next holder. Exhaustion
                // (tvbStrikeAndAdvance returning false) has
                // already set the no-exact-source state and
                // falls through to the plain error below.
                // The attempted==current guard keeps a
                // CANCELLED fetch (the owner switched
                // provider mid-flight) from striking the
                // provider he just chose.
            } else {
                loadFailed = true
                focusedRetry = true
            }
        }
    }

    /// The TP CacheVideo probe merge (v2.0.8, Phase 2):
    /// Providers.detail for TP now returns WITHOUT the
    /// CacheVideo server (the probe is TpClient
    /// .probeCacheVideoServer, a separate call), so after any
    /// successful paint of a TP detail — fresh, cache-painted
    /// or failure-path cache paint — the probe runs as its
    /// own task and its server is appended to the CURRENT
    /// detail when it lands, provided the view still shows
    /// the painted provider/slug and no server of that name
    /// is present yet (a second paint's probe therefore
    /// cannot duplicate the row).
    private func launchTPProbe(painted: Detail, paintedProvider: String,
                               paintedSlug: String) {
        guard paintedProvider == Providers.TP else { return }
        Task {
            guard let server = await TpClient.probeCacheVideoServer(
                detail: painted, slug: paintedSlug) else { return }
            guard provider == paintedProvider, slug == paintedSlug,
                  let current = detail,
                  !current.servers.contains(where: { $0.name == server.name })
            else { return }
            var updated = current
            updated.servers.append(server)
            detail = updated
        }
    }

    /// Progressive alternatives + identity (v2.0.8, Phase 2):
    /// findAlternatives assigns `alternatives` the moment it
    /// lands; resolveIdentity runs after it (it consumes the
    /// alternatives — a true data dependency) and assigns
    /// `filmIdentity` when it lands. The task is detached
    /// from load()'s return; the provider/slug guards keep a
    /// late landing from a previous film (or a switched
    /// provider) from overwriting the current screen's state.
    private func launchAlternativesAndIdentity(movie: Movie,
                                               fromCode: String,
                                               forSlug: String) {
        Task {
            // v2.0.31 (L7 + I1): a TVB session's alternatives
            // are the snapshot's own holders (never a name
            // search), ordered by whether their ladders
            // actually resolve (I1 — see tvbPlayableHolders);
            // when the CURRENT holder does not resolve and
            // another does, the page auto-picks the playable
            // holder — Tự động mode only (a pinned source is
            // never overridden), never once playback has
            // started, and at most once per page.
            if route.tvb != nil {
                let playable = await tvbPlayableHolders()
                guard provider == fromCode, slug == forSlug else { return }
                alternatives = await tvbOrderedAlternatives(playable: playable)
                PerfLog.mark("detail.alternativesPaint")
                if !playable.contains(provider), autoSource,
                   playerHolder == nil, !tvbAutoPickDone,
                   let pick = alternatives.first(where: {
                       playable.contains($0.code)
                   }) {
                    tvbAutoPickDone = true
                    switchNotice = "Nguồn \(Providers.displayName(provider)) không phát được tập này — đã tự chọn nguồn \(Providers.displayName(pick.code))"
                    provider = pick.code
                    slug = pick.slug
                    return
                }
                let identity = await Providers.resolveIdentity(
                    movie: movie, fromCode: fromCode,
                    alternatives: alternatives)
                guard provider == fromCode, slug == forSlug else { return }
                filmIdentity = tvbPinnedIdentity(identity)
                PerfLog.mark("detail.identityPaint")
                return
            }
            let alts = await Providers.findAlternatives(
                fromCode: fromCode, name: movie.name,
                origin: movie.originName, year: movie.year,
                tmdbId: movie.tmdbId)
            guard provider == fromCode, slug == forSlug else { return }
            alternatives = alts
            PerfLog.mark("detail.alternativesPaint")
            // v2.0.5 (D3): the identity ladder's result lands
            // in view state, so the source row re-renders with
            // the Torrent entry's state the moment it resolves.
            let identity = await Providers.resolveIdentity(
                movie: movie, fromCode: fromCode, alternatives: alts)
            guard provider == fromCode, slug == forSlug else { return }
            filmIdentity = identity
            PerfLog.mark("detail.identityPaint")
        }
    }

    // MARK: - v2.0.31 TVB identity + auto-pick (L7 / I1)
    //
    // Everything below serves ONLY routes carrying a TVB
    // snapshot context (route.tvb != nil); the non-TVB
    // flows never reach it (tvbGate passes straight
    // through, the alternatives builders are only called
    // behind the same condition).

    /// The identity gate every TVB paint passes through
    /// (L7): the payload must be ACCEPTED by the snapshot
    /// context for the provider it was fetched from
    /// (TVBRouteContext.accepts). A rejected payload
    /// strikes its holder and advances the page to the
    /// next one — the change re-fires load() through
    /// .task(id:) — or lands on the no-exact-source state
    /// at exhaustion. A landing for a provider the page
    /// has already left (attempted != current) is dropped
    /// silently: never painted, never struck twice — the
    /// current holder's own load is deciding.
    private func tvbGate(_ d: Detail, attemptedProvider: String) -> Bool {
        guard let ctx = route.tvb else { return true }
        guard attemptedProvider == provider else { return false }
        if ctx.accepts(d.movie, provider: attemptedProvider) { return true }
        _ = tvbStrikeAndAdvance(reason: "không khớp đúng phim này")
        return false
    }

    /// Strike the CURRENT holder and move the page to the
    /// next unstruck snapshot holder, if one remains.
    /// Returns true when it advanced. At exhaustion: with
    /// a detail on screen (a switch-path strike-out) the
    /// page reverts to the last-good holder — the C-9
    /// shape — and says so; with nothing on screen (a
    /// first-open strike-out) it sets the no-exact-source
    /// error state. Either way it returns false. The
    /// notice names the providers so the owner sees the
    /// move and its reason (§8).
    @discardableResult
    private func tvbStrikeAndAdvance(reason: String) -> Bool {
        guard let ctx = route.tvb else { return false }
        tvbStruck.insert(provider)
        if let next = ctx.holders.first(where: {
            $0.provider != provider && !tvbStruck.contains($0.provider)
        }) {
            switchNotice = "Nguồn \(Providers.displayName(provider)) \(reason) — đã chuyển sang nguồn \(Providers.displayName(next.provider))"
            provider = next.provider
            slug = next.slug
            return true
        }
        if detail != nil {
            provider = lastGoodProvider
            slug = lastGoodSlug
            switchNotice = "Không nguồn nào khớp đúng phim này — vẫn dùng nguồn \(Providers.displayName(lastGoodProvider))"
            return false
        }
        tvbNoExactSource = true
        loadFailed = true
        focusedRetry = true
        return false
    }

    /// The error slate's Retry: for a TVB page that
    /// exhausted its holders, a retry first clears the
    /// strikes and restarts from the snapshot's primary
    /// holder (a changed provider/slug re-fires load()
    /// through .task(id:) by itself; an unchanged pair
    /// runs load() here). Every other page retries
    /// exactly as before.
    private func retryLoad() async {
        guard route.tvb != nil else { await load(); return }
        tvbStruck = []
        tvbNoExactSource = false
        loadFailed = false
        if let first = route.tvb?.holders.first,
           first.provider != provider || first.slug != slug {
            provider = first.provider
            slug = first.slug
        } else {
            await load()
        }
    }

    /// For a TVB session the SNAPSHOT is the identity
    /// authority: the ladder's answer is pinned to its
    /// ids, so the Torrent entry and the substitution
    /// rung address the snapshot's series, never an
    /// identity a name search drifted to.
    private func tvbPinnedIdentity(
        _ id: Providers.FilmIdentity
    ) -> Providers.FilmIdentity {
        guard let ctx = route.tvb else { return id }
        var pinned = id
        if !ctx.imdbId.isEmpty { pinned.imdbId = ctx.imdbId }
        pinned.tmdbId = "\(ctx.tmdbId)"
        pinned.tmdbType = "tv"
        return pinned
    }

    /// The TVB alternatives list, built from the
    /// snapshot's holders only (excluding the current
    /// provider and any struck holder): with a
    /// playability verdict (the first-open evaluation),
    /// resolving holders lead in snapshot order with
    /// SourceHealth-demoted providers behind healthy
    /// ones (the standing orderedAlternatives
    /// discipline), and non-resolving holders follow in
    /// snapshot order — the manual source chips list
    /// every surviving holder either way, so manual
    /// selection is untouched. Without a verdict
    /// (provider switches) the order is plain snapshot
    /// order — the chain's TP → KK → VS priority. The
    /// Film4K leg — found by Providers.findSlug, whose
    /// Film4K acceptance is a TMDB-id detail match —
    /// closes the list when Film4K is not itself a
    /// holder: the chain's standing last rung.
    private func tvbOrderedAlternatives(
        playable: Set<String>?
    ) async -> [(code: String, slug: String)] {
        guard let ctx = route.tvb else { return [] }
        let others = ctx.holders.filter {
            $0.provider != provider && !tvbStruck.contains($0.provider)
        }
        let ordered: [TVBRouteContext.Holder]
        if let playable {
            let resolving = others.filter { playable.contains($0.provider) }
            ordered = resolving.filter {
                !SourceHealth.providerDemoted($0.provider)
            } + resolving.filter {
                SourceHealth.providerDemoted($0.provider)
            } + others.filter { !playable.contains($0.provider) }
        } else {
            ordered = others
        }
        var result = ordered.map { (code: $0.provider, slug: $0.slug) }
        if !ctx.holders.contains(where: { $0.provider == Providers.F4K }),
           !tvbStruck.contains(Providers.F4K),
           let f4kSlug = await Providers.findSlug(
               code: Providers.F4K, name: route.name, origin: "",
               year: route.year, tmdbId: "\(ctx.tmdbId)") {
            result.append((code: Providers.F4K, slug: f4kSlug))
        }
        return result
    }

    /// I1's playability verdict: which of the snapshot's
    /// holders can actually play this title's start
    /// episode, judged by the app's own resolution
    /// machinery — each holder's detail is fetched and
    /// Providers.ladderFor must produce at least one
    /// entry, the same ladder the player would build,
    /// with SourceHealth's server gates inside it. The
    /// CURRENT holder is judged from the detail already
    /// on screen (no second fetch). A holder whose
    /// payload fails the L7 identity verdict is never
    /// playable. All other holders are judged
    /// concurrently; a failed fetch or empty ladder
    /// simply reads unplayable (fail-soft). The
    /// resolutions land in the resolver memo, so the
    /// Play tap that follows starts warm.
    private func tvbPlayableHolders() async -> Set<String> {
        guard let ctx = route.tvb, let current = detail else { return [] }
        let target = dwellTarget(detail: current)
        var playable: Set<String> = []
        if let target {
            let ladder = await Providers.ladderFor(
                code: provider, detail: current,
                filmTitle: current.movie.name,
                epName: target.name, epNum: target.num)
            if !ladder.entries.isEmpty { playable.insert(provider) }
        }
        let others = ctx.holders.filter {
            $0.provider != provider && !tvbStruck.contains($0.provider)
        }
        if !others.isEmpty {
            let epName = target?.name
            let epNum = target?.num ?? 0
            let found = await withTaskGroup(of: String?.self) { group in
                for holder in others {
                    group.addTask {
                        guard let d = try? await Providers.detail(
                            holder.provider, slug: holder.slug)
                        else { return nil }
                        guard ctx.accepts(d.movie, provider: holder.provider)
                        else { return nil }
                        let ladder = await Providers.ladderFor(
                            code: holder.provider, detail: d,
                            filmTitle: d.movie.name,
                            epName: epName, epNum: epNum)
                        return ladder.entries.isEmpty ? nil : holder.provider
                    }
                }
                var collected: [String] = []
                for await r in group { if let r { collected.append(r) } }
                return collected
            }
            playable.formUnion(found)
        }
        return playable
    }

    /// TMDB backdrop hunt for the staged TMDB task (Phase 2):
    /// the search runs only when a backdrop is still needed
    /// after fetchInfo; the async-let gate keeps the call
    /// itself inside the concurrent leg.
    private func backdropHunt(needed: Bool, movie: Movie) async -> String? {
        guard needed else { return nil }
        return await TMDBClient.searchBackdrop(
            name: movie.name, origin: movie.originName,
            year: Providers.yearOf(movie))
    }

    /// TMDB cast for the staged TMDB task (Phase 2): cast
    /// exists only when a TMDB id exists — the same rule the
    /// serial chain applied.
    private func castIfAvailable(movie: Movie) async -> [TMDBCastMember] {
        guard !movie.tmdbId.isEmpty else { return [] }
        return await TMDBClient.fetchCast(
            tmdbId: movie.tmdbId, type: movie.tmdbType)
    }

    /// Dwell pre-resolve (v2.0.8, Phase 2/3): after ~1.5 s
    /// resting on one episode context, speculatively resolve
    /// that episode's first server through Providers
    /// .preResolve — the result lands in the resolver memo,
    /// so the Play tap that follows starts from a warm
    /// ladder. The driving .task(id:) is keyed on
    /// provider|slug|focusedEp|detail-arrival, so SwiftUI
    /// cancels this and restarts it as focus moves, the
    /// provider switches, or the view exits — speculative
    /// work never outlives its context. preResolve is cheap
    /// when nothing needs the network (direct-m3u8 providers
    /// resolve instantly; a memo hit is a dictionary read).
    private func dwellPreResolve() async {
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        guard !Task.isCancelled, let d = detail,
              let target = dwellTarget(detail: d) else { return }
        await Providers.preResolve(code: provider, detail: d,
                                   epName: target.name,
                                   epNum: target.num)
        // Idea 23: VSMOV / Tủ Phim dwell warm — their first
        // ladder entries are PROXY entries, so the warm
        // builds the playable proxy URL EXACTLY as the play
        // path in makeDirector's resolveLadder does (the
        // JoeProxy.shared.playlistURL conversion) and warms
        // THAT through warmUpcoming: the tap's first
        // candidate is then the warmed item, and the
        // StreamWarmer's take() can hand it over. If the
        // proxy conversion fails (proxy down), the warm is
        // skipped — never warm the direct URL behind the
        // proxy's back. Film4K is EXCLUDED by law: its
        // tokens rotate per API call, so a warmed F4K URL
        // would be stale on arrival; F4K keeps only the
        // URL-level pre-resolve above.
        if provider == Providers.VS || provider == Providers.TP {
            guard !Task.isCancelled else { return }
            let ladder = await Providers.ladderFor(
                code: provider, detail: d, filmTitle: d.movie.name,
                epName: target.name, epNum: target.num)
            if let first = ladder.entries.first, first.proxy,
               let proxyURL = JoeProxy.shared.playlistURL(
                   for: first.url, headers: first.headers) {
                StreamWarmer.shared.warmUpcoming(
                    url: proxyURL, headers: first.headers)
            }
            return
        }
        // v2.0.24 (Sony D2's tvOS shape): for KK only, the
        // dwell warm now extends from the resolved URL to
        // the media itself. Build this episode's ladder —
        // cheap on the memo hit preResolve just landed —
        // and hand its first entry to the StreamWarmer,
        // which loads that stream's playlists and initial
        // segments into a paused AVPlayer while the owner
        // keeps browsing; the Play tap then starts from
        // warm bytes (see JoeStreamWarmer.swift for the
        // mechanism and its honest bounds). KK only here:
        // its entries are direct m3u8 from this session's
        // fresh detail payload. VS/TP warm through the
        // proxy in the Idea 23 branch above; F4K stays
        // excluded (rotating tokens). A proxy entry is
        // skipped too (KK never proxies; the guard keeps
        // the warm honest if that ever changes). Fail-soft
        // throughout: a missed or stale warm leaves the
        // tap's cold path exactly as it was.
        guard !Task.isCancelled, provider == Providers.KK
        else { return }
        let ladder = await Providers.ladderFor(
            code: provider, detail: d, filmTitle: d.movie.name,
            epName: target.name, epNum: target.num)
        if let first = ladder.entries.first, !first.proxy,
           let url = URL(string: first.url) {
            StreamWarmer.shared.warm(url: url, headers: first.headers)
        }
    }

    /// The dwell target: the focused episode when focus rests
    /// on an episode chip (the focus key is
    /// "<serverIndex>|<name>", matched back against the
    /// servers exactly), else the default first playable
    /// episode in server order.
    private func dwellTarget(detail d: Detail) -> (name: String, num: Int)? {
        if let focusedEp {
            for (si, server) in d.servers.enumerated() {
                for ep in server.episodes
                where "\(si)|\(ep.name)" == focusedEp {
                    return (ep.name, Providers.episodeNumber(ep.name))
                }
            }
        }
        for server in d.servers {
            for ep in server.episodes
            where Providers.isPlayable(code: provider, episode: ep) {
                return (ep.name, Providers.episodeNumber(ep.name))
            }
        }
        return nil
    }

    /// Idea 6 (checkpoint 2.0.25): the NEXT episode after
    /// `epName` in the episode list this detail already
    /// holds, or nil when there is none (a movie / single-
    /// episode session, or the last episode). The successor
    /// in the SAME server's list wins — that is the list the
    /// owner tapped through; when that slot is missing or
    /// unplayable, the episode numbered N+1 anywhere in the
    /// detail (server order) is the fallback, mirroring the
    /// ladder's own number matching. Playable-only: an
    /// unplayable "next" is no next at all.
    private func nextEpisodeName(in d: Detail, after epName: String) -> String? {
        for server in d.servers {
            if let idx = server.episodes.firstIndex(where: { $0.name == epName }) {
                if idx + 1 < server.episodes.count {
                    let candidate = server.episodes[idx + 1]
                    if Providers.isPlayable(code: provider, episode: candidate) {
                        return candidate.name
                    }
                }
                break
            }
        }
        let currentNum = Providers.episodeNumber(epName)
        guard currentNum >= 1 else { return nil }
        for server in d.servers {
            for ep in server.episodes
            where Providers.episodeNumber(ep.name) == currentNum + 1
                && Providers.isPlayable(code: provider, episode: ep) {
                return ep.name
            }
        }
        return nil
    }

    private func play(_ d: Detail, epName: String) {
        PerfLog.mark("play.tap")
        // Owner source-priority policy: in Tự động mode a US
        // theatrical film probes the torrent rung FIRST (the
        // probe itself decides — only a high-quality release
        // answers); every other film, and every pinned session,
        // keeps the current ladder order exactly.
        let torrentFirst = autoSource && Self.isUSTheatrical(d.movie)
        let sourceLine = autoSource
            ? (torrentFirst ? "Nguồn: Tự động · ưu tiên Torrent chất lượng cao"
                            : "Nguồn: Tự động")
            : "Nguồn: \(Providers.displayName(provider)) · đã ghim"
        let director = Self.makeDirector(
            provider: provider, detail: d, epName: epName,
            watch: watch, torrentFirst: torrentFirst,
            tvb: route.tvb, tvbHopList: alternatives)
        // Idea 6 (checkpoint 2.0.25) — Up Next wiring,
        // EPISODE sessions only. Every play in this file is
        // built from the detail's CURRENT provider state
        // (episode chips and the big Play button alike; an
        // alternative-source tap switches + pins the detail
        // itself before any play, it never starts a one-off
        // cross-provider session), so the guard is exactly:
        // a next episode exists in this same detail. Movie
        // (single-episode) sessions find no next and wire
        // nothing. The factory and the warm below capture
        // the session's OWN provider code and torrentFirst
        // flag as plain values — no new source decision is
        // ever taken for the next episode, so a user-pinned
        // source (autoSource off, torrentFirst false) stays
        // the lead source there too, and the director's own
        // failover machinery is unchanged.
        if let nextName = nextEpisodeName(in: d, after: epName) {
            let sessionProvider = provider
            let sessionDetail = d
            let sessionWatch = watch
            // v2.0.31 (L7/I1): the next-episode session
            // inherits the TVB context + hop list exactly
            // as it inherits the provider (see above).
            let sessionTVB = route.tvb
            let sessionHopList = alternatives
            let nextNum = Providers.episodeNumber(nextName)
            director.nextEpisodeTitle = nextName
            director.nextEpisodeFactory = {
                Self.makeDirector(
                    provider: sessionProvider, detail: sessionDetail,
                    epName: nextName, watch: sessionWatch,
                    torrentFirst: torrentFirst,
                    tvb: sessionTVB, tvbHopList: sessionHopList)
            }
            director.onPlayingStarted = {
                // Playback has started: prepare episode N+1
                // off the critical path. Every provider gets
                // the resolver-memo pre-resolve; KK additionally
                // warms the media itself, via the same ladder +
                // first-entry pattern (and the same proxy guard)
                // as the dwell warm in dwellPreResolve() — KK
                // entries are direct m3u8. VSMOV / Tủ Phim warm
                // through the proxy instead (Idea 23, the branch
                // below — the same conversion the dwell warm
                // performs); Film4K keeps the URL-level
                // preparation only (rotating tokens). Fail-soft
                // throughout.
                Task.detached {
                    await Providers.preResolve(
                        code: sessionProvider, detail: sessionDetail,
                        epName: nextName, epNum: nextNum)
                    // Idea 23: the VS/TP proxy warm for the
                    // NEXT episode — the first ladder entry is
                    // a proxy entry, so the playable proxy URL
                    // is built exactly as makeDirector's
                    // resolveLadder builds the play candidate
                    // (JoeProxy.shared.playlistURL); a failed
                    // conversion skips the warm.
                    if sessionProvider == Providers.VS
                        || sessionProvider == Providers.TP {
                        let ladder = await Providers.ladderFor(
                            code: sessionProvider, detail: sessionDetail,
                            filmTitle: sessionDetail.movie.name,
                            epName: nextName, epNum: nextNum)
                        if let first = ladder.entries.first, first.proxy,
                           let proxyURL = JoeProxy.shared.playlistURL(
                               for: first.url, headers: first.headers) {
                            StreamWarmer.shared.warmUpcoming(
                                url: proxyURL, headers: first.headers)
                        }
                        return
                    }
                    guard sessionProvider == Providers.KK else { return }
                    let ladder = await Providers.ladderFor(
                        code: sessionProvider, detail: sessionDetail,
                        filmTitle: sessionDetail.movie.name,
                        epName: nextName, epNum: nextNum)
                    if let first = ladder.entries.first, !first.proxy,
                       let url = URL(string: first.url) {
                        StreamWarmer.shared.warmUpcoming(
                            url: url, headers: first.headers)
                    }
                }
            }
        }
        playerHolder = DirectorHolder(
            director: director,
            title: d.movie.name, episode: epName, sourceLine: sourceLine)
    }

    /// The policy's US-theatrical test, from the detail
    /// payload's own fields: the Âu Mỹ country bucket (the
    /// same name mapping the browse filter's country facet
    /// uses) AND a single/theatrical signal — the KK/VS
    /// `chieurap` flag or a single-class type (phim lẻ).
    static func isUSTheatrical(_ m: Movie) -> Bool {
        let western = m.country
            .components(separatedBy: "·")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .contains { JoeBrowseFilter.countryBucket(ofName: $0) == .auMy }
        guard western else { return false }
        return m.chieurap
            || m.type == "single" || m.type == "phim-le" || m.type == "movie"
    }

    /// The session factory: identity + fresh-resolution ladder +
    /// one cross-provider hop (KK ↔ Film4K ↔ VSMOV), with the
    /// resume position carried from the stored entry. Mirrors
    /// the Android player wiring.
    /// v2.0.31 (L7): `tvb` carries the TVB snapshot context
    /// for TVB sessions (nil otherwise) — the hop then walks
    /// only the snapshot's holders (`tvbHopList` first: the
    /// detail's evaluated alternatives) under the identity
    /// verdict, and the torrent rung is pinned to the
    /// snapshot's IMDb id. Non-TVB sessions are unchanged.
    static func makeDirector(provider: String, detail: Detail,
                             epName: String, watch: WatchStore,
                             torrentFirst: Bool = false,
                             tvb: TVBRouteContext? = nil,
                             tvbHopList: [(code: String, slug: String)] = [])
        -> PlayDirector {
        let m = detail.movie
        var entry = WatchStore.Entry()
        entry.kind = Providers.kindOf(provider)
        entry.key = Providers.progressKey(provider, slug: m.slug, epName: epName)
        entry.ep = epName
        entry.epLabel = "Đang xem: \(epName)"
        entry.title = m.name
        entry.poster = m.poster
        entry.year = m.year
        entry.slug = m.slug
        entry.source = provider
        // v2.0.29 (cluster C, §4.3 O1): stamp the stable
        // ids so a later torrent-side save of the same
        // title can canonical-match this entry by id even
        // when the two catalogues title it differently.
        entry.imdbId = m.imdbId
        entry.tmdbId = m.tmdbId
        let resume = watch.progressFor(matching: entry)?.pos ?? 0
        // v2.0.8 (Phase 3): the resolveLadder closure's FIRST
        // invocation for the origin identity builds its ladder
        // from the detail already on screen (the `detail`
        // value captured here) instead of re-fetching the
        // metadata — the screen paid for that payload once.
        // Only the stream-URL resolve inside ladderFor runs at
        // tap time, through the memoised resolver, so the
        // fresh-resolution rule's substance (URLs resolved at
        // tap, never stored) is untouched. Every later
        // invocation — the failover refresh rung, post-hop
        // identities — fetches fresh exactly as before. The
        // flag lives in a reference box because the closure is
        // escaping and called many times over the session.
        let originBox = LadderFirstCallBox()
        return PlayDirector(
            store: watch,
            identity: PlayIdentity(entry: entry),
            resumeMs: resume,
            resolveLadder: { identity in
                // Owner source-priority policy: torrentFirst
                // (Auto + US-theatrical) probes the torrent
                // rung FIRST. The probe is the rung's own
                // stream fetch inside its existing budget
                // (TorrentClient's 15 s cap): a qualifying
                // high-quality release leads the ladder; no
                // qualifying stream — or an unconfigured /
                // unreachable rung — answers empty and the
                // streaming ladder runs in the normal order.
                // Auto never dead-ends on this rule.
                var first: [PlayCandidate] = []
                if torrentFirst {
                    first = await JoeMovieDetail.torrentFallbackCandidates(
                        identity: identity, originDetail: detail,
                        originProvider: provider, highQualityOnly: true,
                        pinnedImdbId: tvb?.imdbId ?? "")
                }
                // First call for the ORIGIN identity: the
                // on-screen detail IS the metadata (see the
                // originBox note at the factory head). Any
                // other call — refresh rung, post-hop identity,
                // or an identity that is not the origin — takes
                // the fresh fetch exactly as before.
                let d: Detail
                if !originBox.consumed,
                   identity.entry.source == provider,
                   identity.entry.slug == detail.movie.slug {
                    originBox.consumed = true
                    d = detail
                } else if let fresh = try? await Providers.detail(
                    identity.entry.source, slug: identity.entry.slug) {
                    d = fresh
                } else {
                    return first
                }
                let ladder = await Providers.ladderFor(
                    code: identity.entry.source, detail: d,
                    filmTitle: identity.entry.title,
                    epName: identity.entry.ep,
                    epNum: Providers.episodeNumber(identity.entry.ep))
                let streaming = ladder.entries.compactMap { entry in
                    // PNG-disguised / header-gated streams reach
                    // AVPlayer through the in-app cleaning proxy;
                    // if the proxy is somehow down, fall back to
                    // the direct URL rather than no candidate.
                    if entry.proxy,
                       let local = JoeProxy.shared.playlistURL(
                           for: entry.url, headers: entry.headers) {
                        return PlayCandidate(url: local, label: entry.title)
                    }
                    return URL(string: entry.url).map {
                        PlayCandidate(url: $0, headers: entry.headers,
                                      label: entry.title)
                    }
                }
                var seen = Set<String>()
                return (first + streaming).filter {
                    seen.insert($0.url.absoluteString).inserted
                }
            },
            hopIdentity: { identity in
                // v2.0.31 (L7): a TVB session hops ONLY
                // inside the snapshot's holders — the
                // detail's evaluated hop list first, then
                // any remaining holders — and every
                // candidate payload must pass the snapshot
                // identity verdict before it is adopted.
                // The name-search hop below never runs for
                // TVB: a same-named different film is not a
                // failover target, it is the fault itself.
                let hopCandidates: [(code: String, slug: String)]
                if let tvb {
                    var order = tvbHopList
                    for holder in tvb.holders
                    where !order.contains(where: {
                        $0.code == holder.provider
                    }) {
                        order.append((code: holder.provider,
                                      slug: holder.slug))
                    }
                    hopCandidates = order.filter {
                        $0.code != identity.entry.source
                    }
                } else {
                    guard let cur = try? await Providers.detail(
                        identity.entry.source, slug: identity.entry.slug)
                    else { return nil }
                    let alts = await Providers.findAlternatives(
                        fromCode: identity.entry.source, name: cur.movie.name,
                        origin: cur.movie.originName, year: cur.movie.year,
                        tmdbId: cur.movie.tmdbId)
                    // 1.9.2 (Team 9 item 2): iterate the alternatives
                    // in failover order (up to 3) instead of trying
                    // only alts.first — a first alternative whose
                    // detail fetch fails no longer ends the hop while
                    // a second carrier of the same film stands ready.
                    hopCandidates = Array(alts.prefix(3))
                }
                for alt in hopCandidates {
                    guard let d = try? await Providers.detail(alt.code, slug: alt.slug)
                    else { continue }
                    if let tvb, !tvb.accepts(d.movie, provider: alt.code) {
                        continue
                    }
                    let epNum = Providers.episodeNumber(identity.entry.ep)
                    var newEp = identity.entry.ep
                    outer: for s in d.servers {
                        for e in s.episodes where Providers.episodeNumber(e.name) == epNum {
                            newEp = e.name
                            break outer
                        }
                    }
                    var e2 = WatchStore.Entry()
                    e2.kind = Providers.kindOf(alt.code)
                    e2.key = Providers.progressKey(alt.code, slug: alt.slug, epName: newEp)
                    e2.ep = newEp
                    e2.epLabel = "Đang xem: \(newEp)"
                    e2.title = d.movie.name
                    e2.poster = d.movie.poster
                    e2.year = d.movie.year
                    e2.slug = alt.slug
                    e2.source = alt.code
                    // v2.0.29 (cluster C, §4.3 O2): the hop
                    // identity carries the same stable ids.
                    e2.imdbId = d.movie.imdbId
                    e2.tmdbId = d.movie.tmdbId
                    return PlayIdentity(entry: e2)
                }
                return nil
            },
            fallbackCandidates: { identity in
                // When the torrent rung already probed FIRST
                // (torrentFirst), it has had its chance at the
                // front of this session's ladder — probing it
                // again as the last resort would only repeat
                // the same fetch against the same title.
                if torrentFirst { return [] }
                return await JoeMovieDetail.torrentFallbackCandidates(
                    identity: identity, originDetail: detail,
                    originProvider: provider,
                    pinnedImdbId: tvb?.imdbId ?? "")
            })
    }

    /// The substitution rung's candidate hunt (owner law,
    /// v1.9): every Phim source for this title is dead, so find
    /// the SAME title on the torrent side and offer its streams
    /// as the replacement — the director plays them under the
    /// CURRENT identity, so resume and Continue Watching stay
    /// on the Phim entry (one CW row per title, as the owner
    /// expects). Identity is by ID only, never by title text:
    /// the detail's own IMDB id when a provider carried one
    /// (Tủ Phim does); else — v2.0.5 — the detail-time
    /// ladder's cached identity (Providers.resolveIdentity:
    /// external_ids, every alternative's detail, the strict
    /// TMDB title search), consumed first, negatives
    /// included; only when that ladder never ran for the
    /// film does the rung fall back to its original
    /// derivation (TMDB id → TMDB external_ids → IMDB id,
    /// with the TMDB id hunted through the KK alternative
    /// when this provider's detail lacks one). Series
    /// episodes address Torrentio as imdbId:season:episode.
    /// Fail-soft end to end: any gap returns [] and the
    /// director shows its exhausted slate — the honest end
    /// state.
    /// `highQualityOnly` is the source-priority policy's
    /// front-probe form: only streams whose release passes
    /// TorStream.isHighQualityRelease may lead the ladder;
    /// the last-resort rung (false) keeps its historic
    /// any-stream behaviour.
    private static func torrentFallbackCandidates(
        identity: PlayIdentity, originDetail: Detail,
        originProvider: String,
        highQualityOnly: Bool = false,
        pinnedImdbId: String = "") async -> [PlayCandidate] {
        guard let base = TorrentSettings.effectiveBase else { return [] }

        // After a hop the session lives on another provider:
        // read THAT detail (fresh, like the ladder and hop do);
        // the origin detail otherwise, and as the fallback if
        // the fresh fetch fails.
        var d = originDetail
        if identity.entry.source != originProvider
            || identity.entry.slug != originDetail.movie.slug,
           let fresh = try? await Providers.detail(
               identity.entry.source, slug: identity.entry.slug) {
            d = fresh
        }

        var imdbId = d.movie.imdbId
        var tmdbType = d.movie.tmdbType
        var tmdbSeason = d.movie.tmdbSeason
        // v2.0.31 (L7): a TVB session's snapshot IMDb id,
        // when the spine carries one, outranks every
        // derivation below — the rung addresses the
        // snapshot's series directly, as a TV series, and
        // the derivation block (which contains the
        // name-search KK leg) is skipped entirely.
        if !pinnedImdbId.isEmpty {
            imdbId = pinnedImdbId
            tmdbType = "tv"
        }
        if imdbId.isEmpty {
            // v2.0.5 (D3): consume the detail-time ladder's
            // result FIRST. The ladder (Providers
            // .resolveIdentity, run when this film's detail
            // page loaded) is a superset of the derivation
            // below — own ids, external_ids, EVERY
            // alternative's detail, the strict TMDB title
            // search — and its answer is session-cached,
            // negatives included. A cached NEGATIVE is
            // consumed as-is: re-running the weaker derivation
            // could only repeat its answer, slower. Only a
            // cache MISS (the ladder never ran for this film —
            // a programmatic director entry) falls back to the
            // derivation below.
            if let cached = Providers.identityCacheGet(
                Providers.identityKey(name: originDetail.movie.name,
                                      year: originDetail.movie.year,
                                      fromCode: originProvider)) {
                imdbId = cached.imdbId
                if tmdbType.isEmpty { tmdbType = cached.tmdbType }
                if tmdbSeason <= 0 { tmdbSeason = cached.tmdbSeason }
            } else {
                var tmdbId = d.movie.tmdbId
                if tmdbId.isEmpty {
                    let alts = await Providers.findAlternatives(
                        fromCode: identity.entry.source,
                        name: d.movie.name, origin: d.movie.originName,
                        year: d.movie.year,
                        tmdbId: d.movie.tmdbId)
                    if let kk = alts.first(where: { $0.code == Providers.KK }),
                       let kd = try? await Providers.detail(kk.code, slug: kk.slug) {
                        tmdbId = kd.movie.tmdbId
                        imdbId = kd.movie.imdbId
                        if tmdbType.isEmpty { tmdbType = kd.movie.tmdbType }
                        if tmdbSeason <= 0 { tmdbSeason = kd.movie.tmdbSeason }
                    }
                }
                if imdbId.isEmpty, !tmdbId.isEmpty {
                    imdbId = await TMDBClient.imdbId(
                        tmdbId: tmdbId, type: tmdbType) ?? ""
                }
            }
        }
        guard !imdbId.isEmpty else { return [] }

        // Movie vs series for the Torrentio address: the TMDB
        // type when known; with no type on record, a numbered
        // episode inside a multi-episode detail reads as a
        // series (a movie's "Full" never numbers).
        let epNum = Providers.episodeNumber(identity.entry.ep)
        let episodeCount = d.servers.reduce(0) { $0 + $1.episodes.count }
        let isSeries = tmdbType == "tv"
            || (tmdbType.isEmpty && epNum >= 1 && episodeCount > 1)
        let streamId: String
        if isSeries {
            // Season: an explicit marker in the episode name
            // wins; else the detail's TMDB season (the house
            // rule — TpClient addresses CacheVideo the same
            // way); else 1.
            let season = Providers.seasonNumber(identity.entry.ep)
                ?? (tmdbSeason > 0 ? tmdbSeason : 1)
            streamId = "\(imdbId):\(season):\(max(epNum, 1))"
        } else {
            streamId = imdbId
        }
        guard let streams = try? await TorrentClient.fetchStreams(
            addonBase: base, type: isSeries ? "series" : "movie",
            id: streamId), !streams.isEmpty else { return [] }
        let usable = highQualityOnly
            ? streams.filter { $0.isHighQualityRelease }
            : streams
        guard !usable.isEmpty else { return [] }
        // The shared builder: Torrentio's own top-ranked stream
        // leads (and earns the one RD resolution if it is a
        // bare hash), the B-5 container rule filters, and the
        // "Torrent" prefix tells the owner which source family
        // is playing in the player's status capsule.
        return await TorrentClient.playCandidates(
            streams: usable, preferred: nil, labelPrefix: "Torrent")
    }
}

/// Shared state for load()'s first-open cache/network race
/// (v2.0.8, Phase 2). Both racers run on the main actor, so
/// the flags are only ever touched between awaits; the box
/// exists because the cache racer is an escaping Task
/// closure and needs a reference to write back through.
/// `networkPainted` flips the moment the fetch lands (win or
/// lose the paint decision, the fetch has spoken);
/// `cachedPaint` records the payload the cache racer
/// actually painted, for the fingerprint comparison and the
/// failure path.
private final class DetailLoadRace {
    var cachedPaint: Detail?
    var networkPainted = false
}

/// First-call flag for makeDirector's resolveLadder closure
/// (v2.0.8, Phase 3): reference type because the escaping
/// closure must mutate it across invocations. `consumed`
/// flips on the first origin-identity invocation; every
/// later invocation fetches its detail fresh.
private final class LadderFirstCallBox {
    var consumed = false
}
