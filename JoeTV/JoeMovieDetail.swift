import SwiftUI

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
    @Environment(\.joeTheme) private var theme
    @State private var provider: String
    @State private var slug: String
    @State private var detail: Detail?
    @State private var tmdb: TMDBInfo?
    @State private var alternatives: [(code: String, slug: String)] = []
    /// The film's resolved cross-service identity (v2.0.5,
    /// D3): the detail-time ladder's result (Providers
    /// .resolveIdentity, run in load() alongside
    /// findAlternatives). nil = the ladder has not landed
    /// for this record yet; a landed value with an empty
    /// imdbId is a resolved NEGATIVE — the Torrent entry's
    /// honest state, not a loading state.
    @State private var filmIdentity: Providers.FilmIdentity?
    @State private var loadFailed = false
    @State private var playerHolder: DirectorHolder?
    @State private var switching = false
    /// C-9: the last provider/slug whose detail actually loaded.
    /// A failed switch reverts to these (see load()).
    @State private var lastGoodProvider: String
    @State private var lastGoodSlug: String
    @State private var switchNotice: String?
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
    @FocusState private var focusedAlt: String?
    @FocusState private var focusedRetry: Bool

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
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 32) {
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
                    }
                } else if loadFailed {
                    // §8: the G3 error shape + Retry.
                    VStack(alignment: .leading, spacing: 16) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 44))
                            .foregroundStyle(.orange)
                        Text("Không tải được thông tin phim.")
                            .font(.system(size: 29, weight: .semibold))
                            .foregroundStyle(theme.text)
                        Text("Kiểm tra mạng rồi thử lại.")
                            .font(.system(size: 25))
                            .foregroundStyle(theme.meta)
                        Button { Task { await load() } } label: {
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
            // a separate task) and now publishes in TWO stages:
            // backdrop + overview land with the TMDB detail
            // call; the cast merges when the credits call
            // returns, so the band never waits behind credits.
            // A film whose payload carries no TMDB id — or a
            // record with no backdrop — is hunted by the
            // name + year title search for a backdrop, exactly
            // like the Android pipeline.
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
            if info?.backdropURL.isEmpty ?? true {
                if let url = await TMDBClient.searchBackdrop(
                    name: movie.name, origin: movie.originName,
                    year: Providers.yearOf(movie)) {
                    if info == nil { info = TMDBInfo() }
                    info?.backdropURL = url
                }
            }
            guard let resolved = info else {
                tmdb = nil
                return
            }
            tmdb = resolved
            if !movie.tmdbId.isEmpty {
                let cast = await TMDBClient.fetchCast(
                    tmdbId: movie.tmdbId, type: movie.tmdbType)
                if !cast.isEmpty, var current = tmdb {
                    current.cast = cast
                    tmdb = current
                }
            }
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
            sourceChips
                .padding(.top, 38)
            servers(d, heading: "Chọn tập", headingSize: 30)
                .padding(.top, 36)
        }
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
                providerChip
            }
            .padding(.top, 26)
            if let tmdb, !tmdb.cast.isEmpty {
                castRow(tmdb.cast)
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
                    }
                    .padding(.top, 22)
                }
                Spacer(minLength: 0)
            }
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
    /// binding the chip anatomies use) and carries the
    /// vertical form of sourceMove; the status-only row
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
                    .joeBoundaryMove(
                        up: { sourceMove(.up, from: focusID, vertical: true) },
                        down: { sourceMove(.down, from: focusID, vertical: true) },
                        left: { sourceMove(.left, from: focusID, vertical: true) },
                        right: { sourceMove(.right, from: focusID, vertical: true) })
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
    @ViewBuilder
    private var actorsLine: some View {
        if let tmdb, !tmdb.cast.isEmpty {
            // Design-A detail cast line: 24px in the meta colour,
            // margin-top 14 (the padding lives inside the
            // conditional so an absent cast collapses fully).
            Text("Diễn viên: " + tmdb.cast.prefix(6)
                .map { $0.name }.joined(separator: ", "))
                .font(.system(size: 24))
                .foregroundStyle(theme.meta)
                .lineLimit(2)
                .frame(maxWidth: 1050, alignment: .leading)
                .padding(.top, 14)
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
            .joeBoundaryMove(
                up: { sourceMove(.up, from: "torrent", vertical: false) },
                down: { sourceMove(.down, from: "torrent", vertical: false) },
                left: { sourceMove(.left, from: "torrent", vertical: false) },
                right: { sourceMove(.right, from: "torrent", vertical: false) })
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
            .joeBoundaryMove(
                up: { sourceMove(.up, from: "auto", vertical: false) },
                down: { sourceMove(.down, from: "auto", vertical: false) },
                left: { sourceMove(.left, from: "auto", vertical: false) },
                right: { sourceMove(.right, from: "auto", vertical: false) })
        case .current:
            Button {
                autoSource = false
            } label: {
                JoeChipLabel(title: Providers.displayName(provider),
                             selected: !autoSource)
            }
            .joeCardButton()
            .focused($focusedAlt, equals: "current")
            .joeBoundaryMove(
                up: { sourceMove(.up, from: "current", vertical: false) },
                down: { sourceMove(.down, from: "current", vertical: false) },
                left: { sourceMove(.left, from: "current", vertical: false) },
                right: { sourceMove(.right, from: "current", vertical: false) })
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
            .joeBoundaryMove(
                up: { sourceMove(.up, from: code, vertical: false) },
                down: { sourceMove(.down, from: code, vertical: false) },
                left: { sourceMove(.left, from: code, vertical: false) },
                right: { sourceMove(.right, from: code, vertical: false) })
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
    /// and the episode servers. The cells are deliberately NOT
    /// buttons and carry no focus handling, so the v1.5 focus
    /// traversal (play → chips → episodes) is untouched.
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
        VStack(spacing: 8) {
            ZStack {
                Circle().fill(Color.white.opacity(0.10))
                if !member.photoURL.isEmpty, let url = URL(string: member.photoURL) {
                    JoeRemoteImage(url: url, targetPixels: 240) {
                        castInitial(member)
                    }
                } else {
                    castInitial(member)
                }
            }
            .frame(width: 110, height: 110)
            .clipShape(Circle())
            .overlay(Circle()
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1.2))
            Text(member.name)
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(theme.text)
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

    private func castInitial(_ member: TMDBCastMember) -> some View {
        Text(String(member.name.prefix(1)))
            .font(.system(size: 38, weight: .bold))
            .foregroundStyle(.white.opacity(0.8))
    }

    // MARK: - Boundary routing (v2.0.5, N1 pair h)

    /// The source block's FOCUSABLE entry ids, in on-screen
    /// order — the arithmetic both source anatomies route
    /// over (A/D chips horizontally, F rows vertically; one
    /// model, two orientations). The Torrent entry joins the
    /// list only while it is a control: in the chip anatomies
    /// it renders only when configured, and in F the
    /// unconfigured state is the non-focusable "Cần token"
    /// status row — in both, unconfigured ⟺ absent here.
    private var sourceFocusIDs: [String] {
        var ids = ["auto", "current"]
        ids += alternatives.map { $0.code }
        if TorrentSettings.isConfigured { ids.append("torrent") }
        return ids
    }

    /// The episode block's entry: the first PLAYABLE
    /// episode's focus key ("<serverIndex>|<name>", the
    /// chips' F4 identity), or nil when nothing below the
    /// source block can take focus.
    private var firstEpisodeFocusKey: String? {
        guard let d = detail else { return nil }
        for (si, server) in d.servers.enumerated() {
            for ep in server.episodes
            where Providers.isPlayable(code: provider, episode: ep) {
                return "\(si)|\(ep.name)"
            }
        }
        return nil
    }

    /// Source-block routing, shared by the chips (A/D:
    /// `vertical` false — LEFT/RIGHT are the row's own
    /// arithmetic, UP exits to the play button, DOWN enters
    /// the episode block) and by F's rows (`vertical` true —
    /// UP/DOWN are the list's arithmetic, LEFT/RIGHT are
    /// declared no-ops on full-width rows, the ends exit to
    /// the play button / the episode block). The Dark Waters
    /// case is the contract: from ANY source entry, the
    /// Torrent entry is reachable by walking this list, and
    /// from the episode block UP returns here (epMove).
    private func sourceMove(_ direction: MoveCommandDirection,
                            from id: String, vertical: Bool) {
        let ids = sourceFocusIDs
        guard let i = ids.firstIndex(of: id) else { return }
        switch direction {
        case .left:
            if !vertical, i > 0 { focusedAlt = ids[i - 1] }
        case .right:
            if !vertical, i + 1 < ids.count { focusedAlt = ids[i + 1] }
        case .up:
            if vertical, i > 0 {
                focusedAlt = ids[i - 1]
            } else {
                focusedPlay = true
            }
        case .down:
            if vertical, i + 1 < ids.count {
                focusedAlt = ids[i + 1]
            } else if let key = firstEpisodeFocusKey {
                focusedEp = key
            }
        @unknown default:
            break
        }
    }

    /// Episode-block routing. The chips live in wrapping
    /// flow rows (FlowLayout), whose wrapped rows have no
    /// enumerable column structure, so the block routes like
    /// the homes' rails: LEFT/RIGHT step within the server
    /// group (skipping unplayable chips, which are disabled
    /// and cannot hold focus), UP/DOWN step between server
    /// groups (previous group's last playable chip / next
    /// group's first), and UP from the first group lands on
    /// the source block's ACTIVE entry — the reciprocal of
    /// sourceMove's DOWN. DOWN out of the last group is a
    /// defined no-op: nothing focusable sits below the
    /// episode block in any anatomy.
    private func epMove(_ direction: MoveCommandDirection,
                        detail d: Detail, serverIndex si: Int,
                        episodeIndex ei: Int) {
        guard !switching else { return }
        let servers = d.servers
        guard servers.indices.contains(si) else { return }
        func playable(_ s: Int, _ e: Int) -> Bool {
            Providers.isPlayable(code: provider,
                                 episode: servers[s].episodes[e])
        }
        func land(_ s: Int, _ e: Int) {
            focusedEp = "\(s)|\(servers[s].episodes[e].name)"
        }
        switch direction {
        case .left, .right:
            var idx = ei + (direction == .left ? -1 : 1)
            while servers[si].episodes.indices.contains(idx) {
                if playable(si, idx) { land(si, idx); return }
                idx += (direction == .left ? -1 : 1)
            }
        case .up:
            if si > 0 {
                var e = servers[si - 1].episodes.count - 1
                while e >= 0 {
                    if playable(si - 1, e) { land(si - 1, e); return }
                    e -= 1
                }
            }
            focusedAlt = autoSource ? "auto" : "current"
        case .down:
            if si + 1 < servers.count {
                var e = 0
                while e < servers[si + 1].episodes.count {
                    if playable(si + 1, e) { land(si + 1, e); return }
                    e += 1
                }
            }
        @unknown default:
            break
        }
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
        if let e = watch.progress().first(where: {
            $0.slug == slug && $0.source == provider }), exists(e.ep) {
            return e.ep
        }
        return all.first { Providers.isPlayable(code: provider, episode: $0) }?.name
    }

    private func playButton(_ d: Detail) -> some View {
        let isResume = !route.preselectEp.isEmpty
            || watch.progress().contains { $0.slug == slug && $0.source == provider }
        return Button {
            if let ep = startEpisode(d) { play(d, epName: ep) }
        } label: {
            JoePrimaryLabel(title: isResume ? "Xem tiếp" : "Xem ngay",
                            systemImage: "play.fill")
        }
        .joeCardButton()
        .focused($focusedPlay)
        .disabled(startEpisode(d) == nil || switching)
        // v2.0.5 (N1, pair h): the header pair's exits —
        // RIGHT to the favourite button, DOWN to the source
        // block's first entry. LEFT/UP are declared no-ops
        // (the poster/band beside and above are decoration;
        // the layer's top is here, Menu is the way out).
        .joeBoundaryMove(
            down: { focusedAlt = "auto" },
            right: { focusedFav = true })
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
        // (new — see focusedFav) and its exits: LEFT back to
        // play, DOWN to the source block's first entry.
        // RIGHT/UP are declared no-ops (nothing focusable
        // beside or above it in any anatomy).
        .focused($focusedFav)
        .joeBoundaryMove(
            down: { focusedAlt = "auto" },
            left: { focusedPlay = true })
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
        let storedEp = watch.progress().first(where: {
            $0.slug == slug && $0.source == provider })?.ep
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
                .overlay(Capsule()
                    .strokeBorder(focused ? theme.focus
                                  : (preselected ? Color.clear : theme.stroke),
                                  lineWidth: focused ? theme.ringWidth : 1.5))
        }
        .joeCardButton()
        .focused($focusedEp, equals: focusKey)
        .disabled(!playable || switching)
        // v2.0.5 (N1, pair h): the episode block's own
        // routing (see epMove) — the detail's first
        // onMoveCommand on its chips; pre-fix this file had
        // none, so the block could only be crossed
        // geometrically, which is exactly what failed on
        // the owner's Dark Waters case (from the link list,
        // UP never reached the source row).
        .joeBoundaryMove(
            up: { epMove(.up, detail: d, serverIndex: serverIndex,
                         episodeIndex: episodeIndex) },
            down: { epMove(.down, detail: d, serverIndex: serverIndex,
                           episodeIndex: episodeIndex) },
            left: { epMove(.left, detail: d, serverIndex: serverIndex,
                           episodeIndex: episodeIndex) },
            right: { epMove(.right, detail: d, serverIndex: serverIndex,
                            episodeIndex: episodeIndex) })
    }

    // MARK: - Loading + playing

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
        // v2.0.1 DetailCache (Android FIX2 parity): on a FIRST
        // open, a cached payload paints the full detail
        // immediately; the fetch below then runs as a
        // background refresh — it repaints only when the
        // payload actually changed (fingerprint), and a failed
        // refresh never errors over the cache-filled screen.
        // Switches keep the pre-cache behaviour exactly (the
        // current detail already stays on screen through one).
        var cachedPaint: Detail?
        if !hadDetail,
           let cached = JoeDetailCache.read(provider: attemptedProvider,
                                            slug: attemptedSlug) {
            detail = cached
            cachedPaint = cached
        }
        do {
            let d = try await Providers.detail(provider, slug: slug)
            JoeDetailCache.write(d, provider: attemptedProvider,
                                 slug: attemptedSlug)
            if let cachedPaint {
                if JoeDetailCache.fingerprint(d)
                    != JoeDetailCache.fingerprint(cachedPaint) {
                    detail = d
                }
                // Same payload: the cached render stands. The
                // fresh copy's stream URLs are NOT needed —
                // the play path re-resolves them fresh at tap
                // time (makeDirector's ladder re-fetches the
                // detail), so nothing stale can reach the
                // player from either copy.
            } else {
                detail = d
            }
            switching = false
            lastGoodProvider = provider
            lastGoodSlug = slug
            alternatives = await Providers.findAlternatives(
                fromCode: provider, name: d.movie.name,
                origin: d.movie.originName, year: d.movie.year)
            // v2.0.5 (D3): the detail-time identity ladder
            // runs alongside the alternatives lookup and lands
            // in view state, so the source row re-renders with
            // the Torrent entry's state the moment it resolves.
            filmIdentity = await Providers.resolveIdentity(
                movie: d.movie, fromCode: provider,
                alternatives: alternatives)
        } catch {
            switching = false
            if let cachedPaint {
                // The cache-filled screen stays — no error
                // surface, no revert (the painted detail IS
                // the attempted provider's own). Alternatives
                // still run: the source row must not wait on a
                // detail fetch that already failed once.
                alternatives = await Providers.findAlternatives(
                    fromCode: attemptedProvider,
                    name: cachedPaint.movie.name,
                    origin: cachedPaint.movie.originName,
                    year: cachedPaint.movie.year)
                // v2.0.5 (D3): the identity ladder runs here
                // too — the painted film's Torrent entry must
                // not wait on a detail fetch that already
                // failed once either.
                filmIdentity = await Providers.resolveIdentity(
                    movie: cachedPaint.movie, fromCode: attemptedProvider,
                    alternatives: alternatives)
            } else if !hadDetail {
                loadFailed = true
                focusedRetry = true
            } else if attemptedProvider != lastGoodProvider
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
    }

    private func play(_ d: Detail, epName: String) {
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
        playerHolder = DirectorHolder(
            director: Self.makeDirector(
                provider: provider, detail: d, epName: epName,
                watch: watch, torrentFirst: torrentFirst),
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
    static func makeDirector(provider: String, detail: Detail,
                             epName: String, watch: WatchStore,
                             torrentFirst: Bool = false) -> PlayDirector {
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
        let resume = watch.progressFor(key: entry.key)?.pos ?? 0
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
                        originProvider: provider, highQualityOnly: true)
                }
                guard let d = try? await Providers.detail(
                    identity.entry.source, slug: identity.entry.slug)
                else { return first }
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
                guard let cur = try? await Providers.detail(
                    identity.entry.source, slug: identity.entry.slug)
                else { return nil }
                let alts = await Providers.findAlternatives(
                    fromCode: identity.entry.source, name: cur.movie.name,
                    origin: cur.movie.originName, year: cur.movie.year)
                // 1.9.2 (Team 9 item 2): iterate the alternatives
                // in failover order (up to 3) instead of trying
                // only alts.first — a first alternative whose
                // detail fetch fails no longer ends the hop while
                // a second carrier of the same film stands ready.
                for alt in alts.prefix(3) {
                    guard let d = try? await Providers.detail(alt.code, slug: alt.slug)
                    else { continue }
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
                    originProvider: provider)
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
        highQualityOnly: Bool = false) async -> [PlayCandidate] {
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
                        year: d.movie.year)
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
