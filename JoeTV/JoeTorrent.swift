import SwiftUI

/// Route into a torrent title.
struct TorRoute: Hashable {
    var meta: TorMeta
    /// The catalog base this meta came from (meta/videos source).
    var base: String
    /// Continue Watching taps: the episode stream id to preselect.
    var preselectStreamId: String = ""
}

/// Phim Torrent home: Cinemeta/Torrentio catalog rails + search +
/// the torrent Continue Watching rail — everything fetched live
/// at open, like the Android section. Streams come from the
/// owner's configured addon; nothing renders as playable until a
/// source is configured in Cài đặt.
struct JoeTorrentHome: View {
    @EnvironmentObject private var watch: WatchStore
    @State private var catalogs: [TorCatalog] = []
    @State private var rails: [String: [TorMeta]] = [:]
    @State private var query = ""
    @State private var searchResults: [TorMeta] = []
    @State private var searching = false
    @FocusState private var focusedMeta: TorMeta.ID?
    @FocusState private var focusedEntry: String?

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 36) {
                    header
                    searchRow
                    if searching || !searchResults.isEmpty {
                        searchGrid
                    } else {
                        cwRail
                        ForEach(Array(catalogs.enumerated()), id: \.offset) { _, cat in
                            if let metas = rails[cat.id + "|" + cat.type], !metas.isEmpty {
                                metaRail(cat.name, metas, base: cat.base)
                            }
                        }
                        if !TorrentSettings.isConfigured {
                            Text("Chưa cấu hình nguồn phát: vào Cài đặt nhập link Torrentio hoặc token Real-Debrid/TorBox của anh để lấy nguồn.")
                                .font(.system(size: 22))
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .padding(.leading, 44)
                .padding(.trailing, 52)
                .padding(.top, 36)
                .padding(.bottom, 30)
            }
            .navigationDestination(for: TorRoute.self) { route in
                JoeTorrentDetail(route: route)
            }
        }
        .task { await load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Phim Torrent")
                .font(.system(size: 44, weight: .heavy))
                .foregroundStyle(.white)
            Text("Nguồn Torrentio + Real-Debrid của anh — lấy mới mỗi lần mở")
                .font(.system(size: 21))
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    private var searchRow: some View {
        HStack(spacing: 18) {
            TextField("Tìm phim torrent…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 26))
                .foregroundStyle(.white)
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 14)
                    .fill(Color.white.opacity(0.10)))
                .frame(width: 820)
                .onSubmit { runSearch() }
            Button {
                runSearch()
            } label: {
                Text("Tìm")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 14)
                    .background(Capsule().fill(JoeTheme.accentViolet.opacity(0.45)))
            }
            .buttonStyle(.plain)
            if !searchResults.isEmpty {
                Button {
                    searchResults = []
                    query = ""
                } label: {
                    Text("Xoá tìm kiếm")
                        .font(.system(size: 22))
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.horizontal, 22)
                        .padding(.vertical, 14)
                        .background(Capsule().fill(Color.white.opacity(0.10)))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var torProgress: [WatchStore.Entry] {
        Array(WatchStore.filterKinds(watch.progress(), [WatchStore.kindTor])
            .prefix(WatchStore.railCap))
    }

    @ViewBuilder
    private var cwRail: some View {
        if !torProgress.isEmpty {
            JoeTheme.Rail(title: "▶ Đang xem dở") {
                ForEach(torProgress) { entry in
                    NavigationLink(value: TorRoute(
                        meta: TorMeta(id: entry.metaId, type: entry.metaType,
                                      name: entry.title, poster: entry.poster,
                                      background: entry.background,
                                      year: entry.year, desc: entry.desc),
                        base: entry.metaBase,
                        preselectStreamId: entry.streamId)) {
                        JoeTheme.PosterCard(
                            title: entry.title,
                            posterURL: entry.posterURL,
                            meta: entry.epLabel,
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

    private func metaRail(_ title: String, _ metas: [TorMeta], base: String) -> some View {
        JoeTheme.Rail(title: title) {
            ForEach(metas) { meta in
                NavigationLink(value: TorRoute(meta: meta, base: base)) {
                    JoeTheme.PosterCard(
                        title: meta.name,
                        posterURL: meta.posterURL,
                        meta: meta.year,
                        focused: focusedMeta == meta.id)
                }
                .buttonStyle(.plain)
                .focused($focusedMeta, equals: meta.id)
            }
        }
    }

    private var searchGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 26)],
                  alignment: .leading, spacing: 30) {
            ForEach(searchResults) { meta in
                NavigationLink(value: TorRoute(meta: meta, base: TorrentSettings.cinemeta)) {
                    JoeTheme.PosterCard(
                        title: meta.name,
                        posterURL: meta.posterURL,
                        meta: meta.year,
                        focused: focusedMeta == meta.id)
                }
                .buttonStyle(.plain)
                .focused($focusedMeta, equals: meta.id)
            }
        }
    }

    private func load() async {
        let base = TorrentSettings.effectiveBase ?? TorrentSettings.cinemeta
        catalogs = await TorrentClient.discoverCatalogs(addonBase: base)
        for cat in catalogs {
            if let metas = try? await TorrentClient.fetchCatalog(cat) {
                rails[cat.id + "|" + cat.type] = metas
            }
        }
    }

    private func runSearch() {
        let kw = query.trimmingCharacters(in: .whitespaces)
        guard !kw.isEmpty else { return }
        searching = true
        Task {
            var out: [TorMeta] = []
            for cat in catalogs where cat.searchable {
                if let metas = try? await TorrentClient.search(cat, keyword: kw) {
                    out.append(contentsOf: metas)
                }
            }
            searchResults = out
            searching = false
        }
    }
}

/// Torrent title detail: hero, favourite toggle, episode list
/// (series), then the stream list for the chosen video — direct
/// links play at once, hash-only entries resolve through the
/// owner's Real-Debrid account at tap time.
struct JoeTorrentDetail: View {
    let route: TorRoute
    @EnvironmentObject private var watch: WatchStore
    @State private var videos: [TorVideo] = []
    @State private var selectedVideo: TorVideo?
    @State private var streams: [TorStream] = []
    @State private var loadingStreams = false
    @State private var notice: String?
    @State private var hasViSub = false
    @State private var playerHolder: JoeMovieDetail.DirectorHolder?
    @FocusState private var focusedRow: String?

    private var meta: TorMeta { route.meta }
    private var favKey: String { WatchStore.torFavKey(metaId: meta.id, type: meta.type) }
    private var isFav: Bool { watch.isFavorite(key: favKey) }
    private var videoId: String { selectedVideo?.id ?? meta.id }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 30) {
                hero
                if meta.type == "series" {
                    episodeList
                }
                streamSection
            }
            .padding(.leading, 44)
            .padding(.trailing, 52)
            .padding(.top, 36)
            .padding(.bottom, 40)
        }
        .task { await load() }
        .fullScreenCover(item: $playerHolder) { holder in
            JoePlayerView(director: holder.director)
        }
    }

    // MARK: - Hero

    private var hero: some View {
        HStack(alignment: .top, spacing: 40) {
            ZStack {
                RoundedRectangle(cornerRadius: 18).fill(Color.black.opacity(0.45))
                if let url = meta.posterURL {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image): image.resizable().scaledToFill()
                        default: Text(meta.name)
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.8))
                            .multilineTextAlignment(.center).padding(18)
                        }
                    }
                }
            }
            .frame(width: 300, height: 450)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1.2))

            VStack(alignment: .leading, spacing: 16) {
                Text(meta.name)
                    .font(.system(size: 50, weight: .heavy))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                if !meta.year.isEmpty {
                    Text(meta.year)
                        .font(.system(size: 25))
                        .foregroundStyle(.white.opacity(0.65))
                }
                HStack(spacing: 16) {
                    favButton
                    if hasViSub {
                        Text("Phụ đề Việt: có (OpenSubtitles)")
                            .font(.system(size: 21))
                            .foregroundStyle(.white.opacity(0.8))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(Color.white.opacity(0.10)))
                    }
                }
                if !meta.desc.isEmpty {
                    Text(meta.desc)
                        .font(.system(size: 22))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(6)
                        .frame(maxWidth: 1050, alignment: .leading)
                }
                if let notice {
                    Text(notice)
                        .font(.system(size: 22))
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var favButton: some View {
        Button {
            var e = WatchStore.Entry()
            e.kind = WatchStore.kindTor
            e.key = favKey
            e.title = meta.name
            e.poster = meta.poster
            e.year = meta.year
            e.metaId = meta.id
            e.metaType = meta.type
            e.metaBase = route.base
            e.background = meta.background
            e.desc = meta.desc
            e.ts = Int64(Date().timeIntervalSince1970 * 1000)
            watch.toggleFavorite(e)
        } label: {
            Text(isFav ? "♥ Đã thích" : "♡ Yêu thích")
                .font(.system(size: 23, weight: .medium))
                .foregroundStyle(isFav ? JoeTheme.accentRed : .white)
                .padding(.horizontal, 22)
                .padding(.vertical, 11)
                .background(Capsule().fill(Color.white.opacity(0.10)))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Episodes (series)

    @ViewBuilder
    private var episodeList: some View {
        if !videos.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("Tập")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16)],
                          alignment: .leading, spacing: 16) {
                    ForEach(videos) { video in
                        let selected = videoId == video.id
                        Button {
                            selectedVideo = video
                            Task { await loadStreams() }
                        } label: {
                            Text(video.label)
                                .font(.system(size: 21, weight: selected ? .bold : .medium))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 13)
                                .background(RoundedRectangle(cornerRadius: 12)
                                    .fill(selected ? JoeTheme.accentViolet.opacity(0.30)
                                          : Color.white.opacity(0.08)))
                        }
                        .buttonStyle(.plain)
                        .focused($focusedRow, equals: "ep|" + video.id)
                    }
                }
            }
        }
    }

    // MARK: - Streams

    @ViewBuilder
    private var streamSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Nguồn phát")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.white)
            if loadingStreams {
                ProgressView("Đang lấy nguồn…")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .tint(.white)
            } else if streams.isEmpty {
                Text(TorrentSettings.isConfigured
                     ? "Chưa có nguồn nào cho mục này."
                     : "Chưa cấu hình nguồn — vào Cài đặt nhập link Torrentio hoặc token Real-Debrid/TorBox.")
                    .font(.system(size: 22))
                    .foregroundStyle(.white.opacity(0.6))
            } else {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(streams) { stream in
                        streamRow(stream)
                    }
                }
            }
        }
    }

    private func streamRow(_ stream: TorStream) -> some View {
        let focused = focusedRow == "st|" + stream.id.uuidString
        return Button {
            play(stream)
        } label: {
            HStack(spacing: 16) {
                Text(streamTag(stream))
                    .font(.system(size: 19, weight: .heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(stream.playable
                                               ? Color.green.opacity(0.35)
                                               : Color.orange.opacity(0.35)))
                VStack(alignment: .leading, spacing: 3) {
                    Text(stream.label)
                        .font(.system(size: 23, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if !stream.title.isEmpty && stream.title != stream.label {
                        Text(stream.title)
                            .font(.system(size: 20))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 13)
                .fill(focused ? Color.white.opacity(0.13) : Color.white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 13)
                .strokeBorder(focused ? Color.white : Color.clear, lineWidth: 2.5))
        }
        .buttonStyle(.plain)
        .focused($focusedRow, equals: "st|" + stream.id.uuidString)
    }

    private func streamTag(_ s: TorStream) -> String {
        if s.playable { return "PHÁT NGAY" }
        if !s.infoHash.isEmpty { return "RD · GIẢI LINK" }
        return "TORRENT"
    }

    // MARK: - Loading + playing

    private func load() async {
        if meta.type == "series" {
            videos = (try? await TorrentClient.fetchVideos(
                metaBase: route.base, type: meta.type, id: meta.id)) ?? []
            if let pre = route.preselectStreamId.isEmpty ? nil
                : videos.first(where: { $0.id == route.preselectStreamId }) {
                selectedVideo = pre
            } else {
                selectedVideo = videos.first
            }
        }
        await loadStreams()
    }

    private func loadStreams() async {
        guard let base = TorrentSettings.effectiveBase else {
            streams = []
            return
        }
        loadingStreams = true
        defer { loadingStreams = false }
        streams = (try? await TorrentClient.fetchStreams(
            addonBase: base, type: meta.type, id: videoId)) ?? []
        let subs = await TorrentClient.fetchSubtitles(
            base: TorrentSettings.subtitleBase(addonBase: base),
            type: meta.type, id: videoId)
        hasViSub = TorrentClient.bestVietnamese(subs) != nil
    }

    /// Direct URL, or a hash resolved through the owner's own
    /// Real-Debrid account. Fail-soft to nil.
    static func resolvePlayable(_ s: TorStream) async -> URL? {
        if s.playable { return URL(string: s.url) }
        guard !s.infoHash.isEmpty else { return nil }
        let token = TorrentSettings.rdToken
        guard !token.isEmpty else { return nil }
        if let r = try? await RdClient.resolve(
            token: token, infoHash: s.infoHash, fileIdx: s.fileIdx) {
            return URL(string: r.url)
        }
        return nil
    }

    private func play(_ stream: TorStream) {
        let sid = videoId
        var entry = WatchStore.Entry()
        entry.kind = WatchStore.kindTor
        entry.key = WatchStore.torProgressKey(streamId: sid)
        entry.ep = selectedVideo?.label ?? ""
        entry.epLabel = selectedVideo.map { "Đang xem: \($0.label)" } ?? ""
        entry.title = meta.name
        entry.poster = meta.poster
        entry.year = meta.year
        entry.metaId = meta.id
        entry.metaType = meta.type
        entry.streamId = sid
        entry.metaBase = route.base
        entry.background = meta.background
        entry.desc = meta.desc
        let resume = watch.progressFor(key: entry.key)?.pos ?? 0
        let wantName = stream.name
        let wantTitle = stream.title
        let type = meta.type
        let director = PlayDirector(
            store: watch,
            identity: PlayIdentity(entry: entry),
            resumeMs: resume,
            resolveLadder: { identity in
                guard let base = TorrentSettings.effectiveBase else { return [] }
                let fresh = (try? await TorrentClient.fetchStreams(
                    addonBase: base, type: type, id: identity.entry.streamId)) ?? []
                // The tapped stream first (a hash entry earns its
                // ONE Real-Debrid resolution here), then any
                // direct-URL streams — resolving every hash in the
                // list through RD would spam the account, so other
                // hash entries are never auto-resolved.
                var out: [PlayCandidate] = []
                if let match = fresh.first(where: {
                    $0.name == wantName && $0.title == wantTitle }),
                   let url = await Self.resolvePlayable(match) {
                    out.append(PlayCandidate(url: url, label: match.label))
                }
                for s in fresh where s.playable
                    && !(s.name == wantName && s.title == wantTitle) {
                    if let url = URL(string: s.url) {
                        out.append(PlayCandidate(url: url, label: s.label))
                    }
                }
                return out
            },
            hopIdentity: nil)
        playerHolder = JoeMovieDetail.DirectorHolder(director: director)
    }
}
