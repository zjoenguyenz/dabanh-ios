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
                        .buttonStyle(.card)
                        .focused($focusedRetry)
                    }
                    .padding(.top, 60)
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
            // TMDB enrichment (v1.6), fail-soft: only when the
            // loaded detail carries a TMDB id AND a TMDB API key
            // is available — the bundled key injected at build
            // time, or one the owner saved in Settings (the saved
            // key wins). Any failure leaves tmdb nil and the
            // screen is the provider-only one.
            guard let detail, !detail.movie.tmdbId.isEmpty,
                  !TMDBClient.apiKey.isEmpty else {
                tmdb = nil
                return
            }
            tmdb = await TMDBClient.fetch(tmdbId: detail.movie.tmdbId,
                                          type: detail.movie.tmdbType)
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
        var m = Movie()
        m.provider = provider
        m.slug = slug
        m.name = route.name
        m.poster = route.poster
        m.year = route.year
        switch theme.id {
        case .posterWall:
            VStack(alignment: .center, spacing: 18) {
                posterArt(m)
                Text(route.name)
                    .font(.system(size: 56, weight: .heavy))
                    .foregroundStyle(theme.text)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                providerChip
            }
            .frame(maxWidth: .infinity)
        case .sourceBoard:
            HStack(alignment: .top, spacing: 32) {
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
            HStack(alignment: .top, spacing: 40) {
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
        }
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
        VStack(alignment: .leading, spacing: 32) {
            VStack(alignment: .leading, spacing: 0) {
                backdropBand(d)
                header(d)
                    .padding(.top, hasBackdrop(d) ? -168 : 0)
            }
            sourceChips
            servers(d, heading: "Chọn tập", headingSize: 30)
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
        VStack(alignment: .center, spacing: 28) {
            posterArt(d.movie)
            Text(d.movie.name)
                .font(.system(size: 56, weight: .heavy))
                .foregroundStyle(theme.text)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            if !d.movie.originName.isEmpty {
                Text(d.movie.originName)
                    .font(.system(size: 29))
                    .foregroundStyle(theme.meta)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
            }
            if !d.metaLine.isEmpty {
                // UI-6 defect D-14: D's detail meta reads in
                // the theme's heroMeta (the render's meta
                // colour), not the dimmer rail meta.
                Text(d.metaLine)
                    .font(.system(size: 29))
                    .foregroundStyle(theme.heroMeta)
            }
            genreChips(d)
            if !(tmdb?.overview.isEmpty ?? true) || !d.content.isEmpty {
                Text((tmdb?.overview.isEmpty ?? true)
                     ? d.content : (tmdb?.overview ?? ""))
                    .font(.system(size: 29))
                    .foregroundStyle(theme.meta)
                    .lineSpacing(8)
                    .lineLimit(5)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 920)
            }
            HStack(spacing: 16) {
                playButton(d)
                favButton(d)
                providerChip
            }
            if let tmdb, !tmdb.cast.isEmpty {
                castRow(tmdb.cast)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // The Nguồn phát row is unconditional in D too —
            // it carries the policy's Tự động chip even when
            // this film has no alternative source.
            altChips
                .frame(maxWidth: .infinity, alignment: .leading)
            servers(d)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }

    /// F — Source Board: compact meta head, then the Nguồn phát
    /// source rows as the PRIMARY block (the current source,
    /// the alternatives as switch actions, the torrent rung's
    /// state), episode chips under them, cast, and the synopsis
    /// demoted to a small 2-line tail.
    private func boardDetail(_ d: Detail) -> some View {
        VStack(alignment: .leading, spacing: 30) {
            HStack(alignment: .top, spacing: 32) {
                posterArt(d.movie)
                VStack(alignment: .leading, spacing: 16) {
                    Text(d.movie.name)
                        .font(.system(size: 54, weight: .heavy))
                        .foregroundStyle(theme.text)
                        .lineLimit(3)
                    if !d.movie.originName.isEmpty {
                        Text(d.movie.originName)
                            .font(.system(size: 27))
                            .foregroundStyle(theme.meta)
                            .lineLimit(1)
                    }
                    if !d.metaLine.isEmpty {
                        Text(d.metaLine)
                            .font(.system(size: 27))
                            .foregroundStyle(theme.meta)
                    }
                    genreChips(d)
                    HStack(spacing: 16) {
                        playButton(d)
                        favButton(d)
                    }
                }
                Spacer(minLength: 0)
            }
            sourceRows(d)
            // UI-6 defect D-11: in F the "Chọn tập" heading is
            // the render's INLINE label beside the chip rows,
            // not a block heading above them.
            HStack(alignment: .top, spacing: 20) {
                Text("Chọn tập")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(theme.text)
                    .padding(.top, 8)
                serverGroups(d)
            }
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
            }
        }
    }

    /// F's source rows: one row per source family. The
    /// policy's Tự động row leads (owner source-priority
    /// policy, 2026-11-15); the current provider's row pins
    /// that source when tapped; alternative rows are Buttons
    /// performing the same provider switch the alt chips
    /// perform in A/D (with the C-9 revert behind load()) —
    /// every specific-source tap PINS (autoSource off); the
    /// torrent row reports the substitution rung's readiness
    /// (it fires automatically inside the director — the row
    /// is status, not a control).
    private func sourceRows(_ d: Detail) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Nguồn phát — chọn là xem")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(theme.text)
            sourceRow(name: "Tự động",
                      meta: "Phim Âu Mỹ chiếu rạp: ưu tiên Torrent chất lượng cao · còn lại theo thứ tự nguồn",
                      state: autoSource ? "● Đang chọn" : "Sẵn sàng",
                      stateColor: autoSource ? JoeTheme.okGreen : theme.meta) {
                autoSource = true
            }
            sourceRow(name: Providers.displayName(provider),
                      meta: d.servers.map { $0.name }.filter { !$0.isEmpty }
                        .joined(separator: " · "),
                      state: autoSource ? "Sẵn sàng" : "● Đang phát",
                      stateColor: autoSource ? theme.meta : JoeTheme.okGreen) {
                autoSource = false
            }
            ForEach(alternatives, id: \.code) { alt in
                sourceRow(name: Providers.displayName(alt.code),
                          meta: "Nguồn khác của phim này",
                          state: "Sẵn sàng", stateColor: theme.meta) {
                    switchNotice = nil
                    autoSource = false
                    provider = alt.code
                    slug = alt.slug
                }
            }
            sourceRow(name: "Torrent",
                      meta: "Nguồn thay thế tự động khi các nguồn trên đều chết",
                      state: TorrentSettings.isConfigured ? "Sẵn sàng" : "Cần token",
                      stateColor: TorrentSettings.isConfigured ? theme.meta : .orange,
                      action: nil)
            if switching {
                HStack(spacing: 12) {
                    ProgressView().tint(theme.text)
                    Text("Đang đổi nguồn…")
                        .font(.system(size: 25))
                        .foregroundStyle(theme.meta)
                }
            }
        }
    }

    /// One source row (UI-6 defect D-6): SINGLE line — name and
    /// meta inline on one row (the render's .srcrow), radius
    /// theme.rField, the theme's surface-gradient fill.
    @ViewBuilder
    private func sourceRow(name: String, meta: String, state: String,
                           stateColor: Color,
                           action: (() -> Void)?) -> some View {
        let row = HStack(alignment: .center, spacing: 20) {
            Text(name)
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(theme.text)
            if !meta.isEmpty {
                Text(meta)
                    .font(.system(size: 23))
                    .foregroundStyle(theme.meta)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(state)
                .font(.system(size: 25, weight: .semibold))
                .foregroundStyle(stateColor)
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: theme.rField)
            .fill(theme.surfaceGradient))
        if let action {
            Button(action: action) {
                row.overlay(JoeFocusRing(shape: RoundedRectangle(cornerRadius: theme.rField)))
            }
            .buttonStyle(.card)
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
            HStack(spacing: 10) {
                ForEach(genres, id: \.self) { genre in
                    Text(genre)
                        .font(.system(size: 23, weight: .semibold))
                        .foregroundStyle(theme.text)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(theme.surface2))
                }
            }
        }
    }

    // MARK: - Header (design A composition; pieces shared by D/F heads)

    private func header(_ d: Detail) -> some View {
        HStack(alignment: .top, spacing: 40) {
            posterArt(d.movie)
            // OWNER FIDELITY RULE (design A render, 2026-11-15):
            // the info column's order is the render's — origin
            // name, title, meta line, genre chips, synopsis,
            // actors line, action buttons. (1.9.2 item 1b's
            // spacing defence is kept: the gaps keep a focused
            // button's ring clear of the line above it.)
            VStack(alignment: .leading, spacing: 20) {
                if !d.movie.originName.isEmpty {
                    Text(d.movie.originName)
                        .font(.system(size: 29))
                        .foregroundStyle(theme.heroMeta)
                        .lineLimit(1)
                }
                Text(d.movie.name)
                    .font(.system(size: 60, weight: .heavy))
                    .foregroundStyle(theme.text)
                    .lineLimit(3)
                if !d.metaLine.isEmpty {
                    Text(d.metaLine)
                        .font(.system(size: 29))
                        .foregroundStyle(theme.heroMeta)
                }
                genreChips(d)
                if !(tmdb?.overview.isEmpty ?? true) || !d.content.isEmpty {
                    Text((tmdb?.overview.isEmpty ?? true)
                         ? d.content : (tmdb?.overview ?? ""))
                        .font(.system(size: 29))
                        .foregroundStyle(theme.heroMeta)
                        .lineSpacing(8)
                        .lineLimit(5)
                        .frame(maxWidth: 1050, alignment: .leading)
                }
                actorsLine
                HStack(spacing: 16) {
                    playButton(d)
                    favButton(d)
                }
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
            Text("Diễn viên: " + tmdb.cast.prefix(6)
                .map { $0.name }.joined(separator: ", "))
                .font(.system(size: 25))
                .foregroundStyle(theme.heroMeta)
                .lineLimit(2)
                .frame(maxWidth: 1050, alignment: .leading)
        }
    }

    /// Design A's Nguồn phát block (UI-6 defects D-11 + D-12;
    /// owner source-priority policy): the render's bold
    /// "Nguồn phát" block heading over the chip row — Tự động
    /// FIRST (the policy's default), the current source's chip
    /// (tapping PINS it), one chip per alternative source
    /// (tapping switches AND pins — C-9 revert behind load()),
    /// and the Torrent status chip when the torrent rung is
    /// configured (status semantics, mirroring F's torrent
    /// row: the rung fires inside the director, the chip is
    /// not a control).
    private var sourceChips: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Nguồn phát")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(theme.text)
            HStack(spacing: 14) {
                if switching {
                    ProgressView().tint(theme.text)
                }
                Button {
                    autoSource = true
                } label: {
                    JoeChipLabel(title: "Tự động", selected: autoSource)
                }
                .buttonStyle(.card)
                .focused($focusedAlt, equals: "auto")
                Button {
                    autoSource = false
                } label: {
                    JoeChipLabel(title: Providers.displayName(provider),
                                 selected: !autoSource)
                }
                .buttonStyle(.card)
                .focused($focusedAlt, equals: "current")
                ForEach(alternatives, id: \.code) { alt in
                    Button {
                        switchNotice = nil
                        autoSource = false
                        provider = alt.code
                        slug = alt.slug
                    } label: {
                        JoeChipLabel(title: Providers.displayName(alt.code), selected: false)
                    }
                    .buttonStyle(.card)
                    .focused($focusedAlt, equals: alt.code)
                }
                if TorrentSettings.isConfigured {
                    JoeChipLabel(title: "Torrent", selected: false)
                }
            }
        }
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
                           fit: true) {
                Text(m.name)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(18)
            }
        }
        .frame(width: size.width, height: size.height)
        // UI-6 defect D-13: concentric radii — the art's clip
        // follows the frame it sits in (A: square 0, accepted;
        // D: the wall's 18 stroke radius; F: rCard − artInset).
        .clipShape(RoundedRectangle(cornerRadius: theme.id == .billboard
                                    ? 0
                                    : (theme.id == .posterWall
                                       ? 18
                                       : max(theme.rCard - theme.artInset, 0))))
        if theme.id == .posterWall {
            image
                .overlay(RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 2))
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

    private func hasBackdrop(_ d: Detail) -> Bool {
        d.movie.thumbURL != nil || tmdbBackdropURL != nil
    }

    /// Design A's backdrop band (430 tall): the provider
    /// landscape thumb, with the TMDB backdrop over it when the
    /// enrichment arrives — both through the image pipeline.
    /// UI-3 SCRIM FLOOR: the fade reaches the token floor
    /// (0.55 black) by 60% of the band's height (UI-6 defect
    /// D-8 — the render's stop) and the band's foot is fully
    /// the foundation colour, so the header text overlapping
    /// the band's lower zone always sits on at least the
    /// guaranteed floor. Pure decoration — no focusable
    /// elements. Hidden entirely when neither image exists
    /// (the header then renders un-overlapped).
    @ViewBuilder
    private func backdropBand(_ d: Detail) -> some View {
        if hasBackdrop(d) {
            ZStack {
                Color.black.opacity(0.45)
                if let url = d.movie.thumbURL {
                    JoeRemoteImage(url: url, targetPixels: 1920) { Color.clear }
                }
                if let url = tmdbBackdropURL {
                    JoeRemoteImage(url: url, targetPixels: 1920) { Color.clear }
                }
                LinearGradient(stops: [
                    .init(color: .clear, location: 0.35),
                    .init(color: .black.opacity(theme.scrimFloor), location: 0.60),
                    .init(color: theme.bg, location: 1)
                ], startPoint: .top, endPoint: .bottom)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 430)
            .clipped()
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
        .buttonStyle(.card)
        .focused($focusedPlay)
        .disabled(startEpisode(d) == nil || switching)
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
            // metrics (JoeSecondaryLabel: 29 pt semibold,
            // 30 pt horizontal padding, fixed 58 height) so
            // the favourite toggle can never drift from the
            // other action labels again.
            Text(isFav ? "♥ Đã thích" : "♡ Yêu thích")
                .font(.system(size: 29, weight: .semibold))
                .foregroundStyle(isFav ? JoeTheme.accentRed : theme.text)
                .padding(.horizontal, 30)
                .frame(height: 58)
                .background(Capsule().fill(theme.surface2))
                .overlay(JoeFocusRing(shape: Capsule()))
        }
        .buttonStyle(.card)
    }

    // MARK: - Nguồn phát chips (design D)

    /// Design D's Nguồn phát row (owner source-priority
    /// policy): Tự động first, the current source (tap pins),
    /// then the alternative sources (tap switches + pins).
    private var altChips: some View {
        HStack(spacing: 14) {
            if switching {
                ProgressView().tint(theme.text)
            }
            Text("Nguồn phát:")
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(theme.meta)
            Button {
                autoSource = true
            } label: {
                JoeChipLabel(title: "Tự động", selected: autoSource)
            }
            .buttonStyle(.card)
            .focused($focusedAlt, equals: "auto")
            Button {
                autoSource = false
            } label: {
                JoeChipLabel(title: Providers.displayName(provider),
                             selected: !autoSource)
            }
            .buttonStyle(.card)
            .focused($focusedAlt, equals: "current")
            ForEach(alternatives, id: \.code) { alt in
                Button {
                    switchNotice = nil
                    autoSource = false
                    provider = alt.code
                    slug = alt.slug
                } label: {
                    JoeChipLabel(title: Providers.displayName(alt.code), selected: false)
                }
                .buttonStyle(.card)
                .focused($focusedAlt, equals: alt.code)
            }
        }
    }

    // MARK: - Servers & episodes

    /// Episode block with an optional block heading (design
    /// A: "Chọn tập" at 30 — UI-6 defect D-11; design D: no
    /// heading, the render's call). Design F uses
    /// serverGroups directly beside its inline label.
    private func servers(_ d: Detail, heading: String? = nil,
                         headingSize: CGFloat = 34) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            if let heading {
                Text(heading)
                    .font(.system(size: headingSize, weight: .bold))
                    .foregroundStyle(theme.text)
            }
            serverGroups(d)
        }
    }

    /// The per-server episode groups. UI-6 defect D-4: the
    /// chips are content-sized CAPSULES in a wrapping flow row
    /// (the renders' shape, and the owner's photo of the
    /// shipped design) — no stretched grid cells.
    private func serverGroups(_ d: Detail) -> some View {
        VStack(alignment: .leading, spacing: 34) {
            ForEach(Array(d.servers.enumerated()), id: \.offset) { serverIndex, server in
                VStack(alignment: .leading, spacing: 14) {
                    if d.servers.count > 1 || !server.name.isEmpty {
                        Text(server.name)
                            .font(.system(size: 25, weight: .semibold))
                            .foregroundStyle(theme.meta)
                    }
                    FlowLayout(spacing: 16) {
                        ForEach(Array(server.episodes.enumerated()), id: \.offset) { _, ep in
                            epChip(d, ep: ep, focusKey: "\(serverIndex)|\(ep.name)")
                        }
                    }
                }
            }
        }
    }

    private func epChip(_ d: Detail, ep: Episode, focusKey: String) -> some View {
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
        .buttonStyle(.card)
        .focused($focusedEp, equals: focusKey)
        .disabled(!playable || switching)
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
        do {
            let d = try await Providers.detail(provider, slug: slug)
            detail = d
            switching = false
            lastGoodProvider = provider
            lastGoodSlug = slug
            alternatives = await Providers.findAlternatives(
                fromCode: provider, name: d.movie.name,
                origin: d.movie.originName, year: d.movie.year)
        } catch {
            switching = false
            if !hadDetail {
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
    /// (Tủ Phim does), else its TMDB id → TMDB external_ids →
    /// IMDB id, with the TMDB id hunted through the KK
    /// alternative when this provider's detail lacks one (the
    /// hop's own findAlternatives call — KK is the provider
    /// whose details carry TMDB ids). Series episodes address
    /// Torrentio as imdbId:season:episode. Fail-soft end to
    /// end: any gap returns [] and the director shows its
    /// exhausted slate — the honest end state.
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
