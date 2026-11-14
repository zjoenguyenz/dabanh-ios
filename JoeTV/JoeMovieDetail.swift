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
    @State private var provider: String
    @State private var slug: String
    @State private var detail: Detail?
    @State private var alternatives: [(code: String, slug: String)] = []
    @State private var loadFailed = false
    @State private var playerHolder: DirectorHolder?
    @State private var switching = false
    @FocusState private var focusedEp: String?
    @FocusState private var focusedPlay: Bool

    struct DirectorHolder: Identifiable {
        let id = UUID()
        let director: PlayDirector
    }

    init(route: MovieRoute) {
        self.route = route
        _provider = State(initialValue: route.provider)
        _slug = State(initialValue: route.slug)
    }

    private var favKey: String { WatchStore.movieFavKey(provider: provider, slug: slug) }
    private var isFav: Bool { watch.isFavorite(key: favKey) }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 30) {
                if let detail {
                    header(detail)
                    if !alternatives.isEmpty || switching { altChips }
                    servers(detail)
                } else if loadFailed {
                    Text("Không tải được thông tin phim. Kiểm tra mạng rồi quay lại.")
                        .font(.title3)
                        .foregroundStyle(.orange)
                        .padding(.top, 60)
                } else {
                    placeholderHeader
                    ProgressView("Đang tải danh sách tập…")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .tint(.white)
                }
            }
            .padding(.leading, 44)
            .padding(.trailing, 52)
            .padding(.top, 36)
            .padding(.bottom, 40)
        }
        .task(id: slug + "|" + provider) { await load() }
        .fullScreenCover(item: $playerHolder) { holder in
            JoePlayerView(director: holder.director)
        }
        .defaultFocus($focusedPlay, true)
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
                    .font(.system(size: 50, weight: .heavy))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                if !route.year.isEmpty {
                    Text(route.year)
                        .font(.system(size: 23))
                        .foregroundStyle(.white.opacity(0.75))
                }
                Text(Providers.displayName(provider))
                    .font(.system(size: 21, weight: .semibold))
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
            VStack(alignment: .leading, spacing: 16) {
                Text(d.movie.name)
                    .font(.system(size: 50, weight: .heavy))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                if !d.movie.originName.isEmpty {
                    Text(d.movie.originName)
                        .font(.system(size: 26))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
                if !d.metaLine.isEmpty {
                    Text(d.metaLine)
                        .font(.system(size: 23))
                        .foregroundStyle(.white.opacity(0.75))
                }
                if !d.categories.isEmpty {
                    Text(d.categories)
                        .font(.system(size: 22))
                        .foregroundStyle(JoeTheme.accentViolet)
                }
                HStack(spacing: 16) {
                    playButton(d)
                    favButton(d)
                    Text(Providers.displayName(provider))
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Color.white.opacity(0.10)))
                }
                if !d.content.isEmpty {
                    Text(d.content)
                        .font(.system(size: 22))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(6)
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
        .frame(width: 300, height: 450)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18)
            .strokeBorder(Color.white.opacity(0.14), lineWidth: 1.2))
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
            .font(.system(size: 25, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 32)
            .padding(.vertical, 13)
            .background(Capsule().fill(JoeTheme.accentViolet))
            .overlay(JoeFocusRing(shape: Capsule(), lineWidth: 3.5))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
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
            Text(isFav ? "♥ Đã thích" : "♡ Yêu thích")
                .font(.system(size: 23, weight: .medium))
                .foregroundStyle(isFav ? JoeTheme.accentRed : .white)
                .padding(.horizontal, 22)
                .padding(.vertical, 11)
                .background(Capsule().fill(Color.white.opacity(0.10)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
                .overlay(JoeFocusRing(shape: Capsule()))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    // MARK: - "Nguồn khác:" chips

    private var altChips: some View {
        HStack(spacing: 14) {
            if switching {
                ProgressView().tint(.white)
            }
            Text("Nguồn khác:")
                .font(.system(size: 23, weight: .medium))
                .foregroundStyle(.white.opacity(0.65))
            ForEach(alternatives, id: \.code) { alt in
                Button {
                    provider = alt.code
                    slug = alt.slug
                } label: {
                    Text(Providers.displayName(alt.code))
                        .font(.system(size: 23, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(JoeTheme.accentViolet.opacity(0.35)))
                        .overlay(JoeFocusRing(shape: Capsule()))
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }
        }
    }

    // MARK: - Servers & episodes

    private func servers(_ d: Detail) -> some View {
        VStack(alignment: .leading, spacing: 34) {
            ForEach(Array(d.servers.enumerated()), id: \.offset) { _, server in
                VStack(alignment: .leading, spacing: 14) {
                    if d.servers.count > 1 || !server.name.isEmpty {
                        Text(server.name)
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 178), spacing: 16)],
                              alignment: .leading, spacing: 16) {
                        ForEach(Array(server.episodes.enumerated()), id: \.offset) { _, ep in
                            epChip(d, ep: ep)
                        }
                    }
                }
            }
        }
    }

    private func epChip(_ d: Detail, ep: Episode) -> some View {
        let playable = Providers.isPlayable(code: provider, episode: ep)
        let storedEp = watch.progress().first(where: {
            $0.slug == slug && $0.source == provider })?.ep
        let preselected = ep.name == (!route.preselectEp.isEmpty
                                      ? route.preselectEp : storedEp)
        let focused = focusedEp == ep.name
        return Button {
            play(d, epName: ep.name)
        } label: {
            Text(ep.name)
                .font(.system(size: 22, weight: preselected ? .bold : .medium))
                .foregroundStyle(playable ? .white : .white.opacity(0.35))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(RoundedRectangle(cornerRadius: 12)
                    .fill(preselected ? JoeTheme.accentViolet.opacity(0.30)
                          : Color.white.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(focused ? Color.white
                                  : (preselected ? JoeTheme.accentViolet : Color.clear),
                                  lineWidth: focused ? 3 : 2))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .focused($focusedEp, equals: ep.name)
        .disabled(!playable || switching)
    }

    // MARK: - Loading + playing

    private func load() async {
        // First open: the placeholder header carries the page.
        // Provider switch: the CURRENT detail stays on screen
        // until the new one lands — v1.1 blanked the page back
        // to a spinner, which read as "another sources page".
        let hadDetail = detail != nil
        if !hadDetail { loadFailed = false }
        switching = hadDetail
        do {
            let d = try await Providers.detail(provider, slug: slug)
            detail = d
            switching = false
            alternatives = await Providers.findAlternatives(
                fromCode: provider, name: d.movie.name,
                origin: d.movie.originName, year: d.movie.year)
        } catch {
            switching = false
            if !hadDetail { loadFailed = true }
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
                guard let alt = alts.first,
                      let d = try? await Providers.detail(alt.code, slug: alt.slug)
                else { return nil }
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
            })
    }
}
