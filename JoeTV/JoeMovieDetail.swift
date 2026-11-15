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
    @FocusState private var focusedEp: String?
    @FocusState private var focusedPlay: Bool
    @FocusState private var focusedAlt: String?
    @FocusState private var focusedRetry: Bool

    struct DirectorHolder: Identifiable {
        let id = UUID()
        let director: PlayDirector
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
                    backdropStrip(detail)
                    header(detail)
                    if let tmdb, !tmdb.cast.isEmpty { castRow(tmdb.cast) }
                    if !alternatives.isEmpty || switching { altChips }
                    servers(detail)
                } else if loadFailed {
                    // §8: the G3 error shape + Retry.
                    VStack(alignment: .leading, spacing: 16) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 44))
                            .foregroundStyle(.orange)
                        Text("Không tải được thông tin phim.")
                            .font(.system(size: 29, weight: .semibold))
                            .foregroundStyle(.white)
                        Text("Kiểm tra mạng rồi thử lại.")
                            .font(.system(size: 25))
                            .foregroundStyle(.white.opacity(0.7))
                        Button { Task { await load() } } label: {
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
                        .focused($focusedRetry)
                        .scaleEffect(focusedRetry ? 1.05 : 1.0)
                    }
                    .padding(.top, 60)
                } else {
                    placeholderHeader
                    ProgressView("Đang tải danh sách tập…")
                        .font(.system(size: 29))
                        .foregroundStyle(.white)
                        .tint(.white)
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
            JoePlayerView(director: holder.director)
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
    /// (in v1.1 a detail could spin for 15–20 s).
    private var placeholderHeader: some View {
        var m = Movie()
        m.provider = provider
        m.slug = slug
        m.name = route.name
        m.poster = route.poster
        m.year = route.year
        return HStack(alignment: .top, spacing: 40) {
            posterArt(m)
            VStack(alignment: .leading, spacing: 16) {
                Text(route.name)
                    .font(.system(size: 64, weight: .heavy))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                if !route.year.isEmpty {
                    Text(route.year)
                        .font(.system(size: 29))
                        .foregroundStyle(.white.opacity(0.75))
                }
                Text(Providers.displayName(provider))
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Color.white.opacity(0.10)))
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Header

    private func header(_ d: Detail) -> some View {
        HStack(alignment: .top, spacing: 40) {
            posterArt(d.movie)
            // 1.9.2 (Team 9 item 1b): gap 16 → 24 — defence in
            // depth so a focused button's focus treatment can
            // never visually touch the genre line above the
            // button row (the owner's photo 2).
            VStack(alignment: .leading, spacing: 24) {
                Text(d.movie.name)
                    .font(.system(size: 64, weight: .heavy))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                if !d.movie.originName.isEmpty {
                    Text(d.movie.originName)
                        .font(.system(size: 29))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
                if !d.metaLine.isEmpty {
                    Text(d.metaLine)
                        .font(.system(size: 29))
                        .foregroundStyle(.white.opacity(0.75))
                }
                if !d.categories.isEmpty {
                    Text(d.categories)
                        .font(.system(size: 25))
                        .foregroundStyle(JoeTheme.accentViolet)
                }
                HStack(spacing: 16) {
                    playButton(d)
                    favButton(d)
                    Text(Providers.displayName(provider))
                        .font(.system(size: 25, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Color.white.opacity(0.10)))
                }
                if !(tmdb?.overview.isEmpty ?? true) || !d.content.isEmpty {
                    Text((tmdb?.overview.isEmpty ?? true)
                         ? d.content : (tmdb?.overview ?? ""))
                        .font(.system(size: 29))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineSpacing(8)
                        .lineLimit(5)
                        .frame(maxWidth: 1050, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func posterArt(_ m: Movie) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.black.opacity(0.45))
            if let url = m.posterURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        Text(m.name)
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.8))
                            .multilineTextAlignment(.center)
                            .padding(18)
                    }
                }
            }
        }
        .frame(width: 240, height: 360)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .strokeBorder(Color.white.opacity(0.14), lineWidth: 2))
    }

    /// Full-width backdrop strip (v1.7, Android parity): a wide
    /// cinematic frame across the top of the detail page, above
    /// the poster header, separated from it by the stack spacing
    /// so the two read as distinct parts. The provider landscape
    /// thumb (KK/VS thumb_url) shows the moment the detail lands;
    /// the TMDB backdrop fades in over it when the enrichment
    /// arrives. Pure decoration — no focusable elements — so the
    /// v1.5 focus traversal is untouched. Hidden entirely when
    /// neither image exists.
    @ViewBuilder
    private func backdropStrip(_ d: Detail) -> some View {
        let tmdbURL = (tmdb?.backdropURL).flatMap {
            $0.isEmpty ? nil : URL(string: $0) }
        if d.movie.thumbURL != nil || tmdbURL != nil {
            ZStack {
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color.black.opacity(0.45))
                if let url = d.movie.thumbURL {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        default:
                            Color.clear
                        }
                    }
                }
                if let url = tmdbURL {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        default:
                            Color.clear
                        }
                    }
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 540)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 2))
            .animation(.easeIn(duration: 0.3), value: tmdbURL != nil)
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
                .foregroundStyle(.white.opacity(0.9))
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
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        default:
                            castInitial(member)
                        }
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
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            if !member.character.isEmpty {
                Text(member.character)
                    .font(.system(size: 23))
                    .foregroundStyle(.white.opacity(0.7))
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
            HStack(spacing: 12) {
                Image(systemName: "play.fill")
                Text(isResume ? "Xem tiếp" : "Xem ngay")
            }
            .font(.system(size: 29, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 36)
            .padding(.vertical, 16)
            .background(Capsule().fill(JoeTheme.accentViolet))
            .overlay(JoeFocusRing(shape: Capsule()))
        }
        .buttonStyle(.card)
        .focusEffectDisabled(true)
        .focused($focusedPlay)
        .scaleEffect(focusedPlay ? 1.05 : 1.0)
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
            Text(isFav ? "♥ Đã thích" : "♡ Yêu thích")
                .font(.system(size: 29, weight: .medium))
                .foregroundStyle(isFav ? JoeTheme.accentRed : .white)
                .padding(.horizontal, 36)
                .padding(.vertical, 16)
                .background(Capsule().fill(Color.white.opacity(0.07)))
                .overlay(JoeFocusRing(shape: Capsule()))
        }
        .buttonStyle(.card)
        .focusEffectDisabled(true)
    }

    // MARK: - "Nguồn khác:" chips

    private var altChips: some View {
        HStack(spacing: 14) {
            if switching {
                ProgressView().tint(.white)
            }
            Text("Nguồn khác:")
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
            ForEach(alternatives, id: \.code) { alt in
                Button {
                    switchNotice = nil
                    provider = alt.code
                    slug = alt.slug
                } label: {
                    Text(Providers.displayName(alt.code))
                        .font(.system(size: 25, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(Capsule().fill(focusedAlt == alt.code
                                                   ? JoeTheme.accentViolet
                                                   : JoeTheme.accentViolet.opacity(0.35)))
                        .overlay(JoeFocusRing(shape: Capsule()))
                }
                .buttonStyle(.card)
                .focusEffectDisabled(true)
                .focused($focusedAlt, equals: alt.code)
                .scaleEffect(focusedAlt == alt.code ? 1.05 : 1.0)
            }
        }
    }

    // MARK: - Servers & episodes

    private func servers(_ d: Detail) -> some View {
        VStack(alignment: .leading, spacing: 34) {
            ForEach(Array(d.servers.enumerated()), id: \.offset) { serverIndex, server in
                VStack(alignment: .leading, spacing: 14) {
                    if d.servers.count > 1 || !server.name.isEmpty {
                        Text(server.name)
                            .font(.system(size: 25, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 178), spacing: 16)],
                              alignment: .leading, spacing: 16) {
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
            Text(ep.name)
                .font(.system(size: 25, weight: preselected ? .bold : .medium))
                .foregroundStyle(playable ? .white : .white.opacity(0.35))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 12)
                    .fill(preselected ? JoeTheme.accentViolet.opacity(0.30)
                          : Color.white.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(focused ? JoeTheme.focusViolet
                                  : (preselected ? JoeTheme.accentViolet : Color.clear),
                                  lineWidth: focused ? 3 : 2))
        }
        .buttonStyle(.card)
        .focusEffectDisabled(true)
        .focused($focusedEp, equals: focusKey)
        .scaleEffect(focused ? 1.05 : 1.0)
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
        playerHolder = DirectorHolder(director: Self.makeDirector(
            provider: provider, detail: d, epName: epName, watch: watch))
    }

    /// The session factory: identity + fresh-resolution ladder +
    /// one cross-provider hop (KK ↔ Film4K ↔ VSMOV), with the
    /// resume position carried from the stored entry. Mirrors
    /// the Android player wiring.
    static func makeDirector(provider: String, detail: Detail,
                             epName: String, watch: WatchStore) -> PlayDirector {
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
                guard let d = try? await Providers.detail(
                    identity.entry.source, slug: identity.entry.slug)
                else { return [] }
                let ladder = await Providers.ladderFor(
                    code: identity.entry.source, detail: d,
                    filmTitle: identity.entry.title,
                    epName: identity.entry.ep,
                    epNum: Providers.episodeNumber(identity.entry.ep))
                return ladder.entries.compactMap { entry in
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
                await JoeMovieDetail.torrentFallbackCandidates(
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
    private static func torrentFallbackCandidates(
        identity: PlayIdentity, originDetail: Detail,
        originProvider: String) async -> [PlayCandidate] {
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
        // The shared builder: Torrentio's own top-ranked stream
        // leads (and earns the one RD resolution if it is a
        // bare hash), the B-5 container rule filters, and the
        // "Torrent" prefix tells the owner which source family
        // is playing in the player's status capsule.
        return await TorrentClient.playCandidates(
            streams: streams, preferred: nil, labelPrefix: "Torrent")
    }
}
