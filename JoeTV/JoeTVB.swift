import SwiftUI

// MARK: - TVB catalogue snapshot (bundled)
//
// The TVB tab renders ONE offline snapshot, tvb-catalog.json,
// produced by the pipeline in tvos-training/tvb-pipeline (plan:
// tvos-training/TVB-TAB-BUILD-PLAN.md; audit: TVB-PHASE1-AUDIT.md).
// The snapshot carries the full TMDB network-48 spine (1,561
// titles) with per-provider resolution records; only titles that
// resolved on at least one provider (790) are displayed — an
// unresolved title has an empty `providers` map and never renders
// (plan §1.4). Playback priority inside the snapshot is
// TP → KK → VS, already encoded per title as `primaryProvider`.
//
// The Codable shapes below mirror the real file field by field
// (validated against the shipped snapshot): the nulls the file
// actually carries are `imdbId`, `posterPath`, `backdropPath`,
// `year`, `primaryProvider`, `providerUpdatedAt` (all null on the
// 771 unresolved titles) and the TP records' `claimedTotal`.
// `voteAverage` arrives as a JSON int on some titles and a float
// on others — a Swift Double decodes both. Unknown future keys
// are ignored by the decoder; every key the file carries today
// is modelled.

struct TVBCatalog: Codable, Sendable {
    let version: Int
    let generatedAt: String
    let source: String
    let spineCount: Int
    let resolvedCount: Int
    let titles: [TVBTitle]
    /// Genre name → tmdbId list (the seven shelves of plan §3.2).
    let shelves: [String: [Int]]
    let rails: TVBRails

    /// Load the bundled snapshot; nil on any failure (missing
    /// resource or a decode mismatch) so the tab can show its
    /// plain load-failure line instead of trapping.
    static func loadBundled() -> TVBCatalog? {
        guard let url = Bundle.main.url(forResource: "tvb-catalog",
                                        withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(TVBCatalog.self, from: data)
    }
}

struct TVBRails: Codable, Sendable {
    let dangHot: [Int]
    let deCu: [Int]
    let moiCapNhat: [Int]
    let moiPhatHanh: [Int]
    let kinhDien: [Int]
}

struct TVBSeason: Codable, Sendable {
    let season: Int
    let episodes: Int
}

struct TVBProviderRecord: Codable, Sendable {
    let slugs: [String]
    /// "tmdb" | "imdb" | "fallback" — how the pipeline matched.
    let matchKey: String
    let matchConfidence: String
    let episodesListed: Int
    let episodesExpected: Int
    let completeness: Double
    let countSource: String
    /// TP only in practice; null on 16 TP records in the file.
    let claimedTotal: Int?
    /// The provider's own dub form ("Lồng Tiếng", "Vietsub", …),
    /// read from `lang` per plan §1.3 — never relabelled.
    let dubForm: String
    let dubbed: Bool
    let categories: [String]
    let updatedAt: String?
    /// Full poster URL on the provider's own CDN — the fallback
    /// art when the TMDB poster path is missing (plan §3).
    let posterFallback: String
}

struct TVBTitle: Codable, Sendable, Identifiable {
    let tmdbId: Int
    let imdbId: String?
    let titleVi: String
    let titleViTmdb: String
    let titleEn: String
    let titleOriginal: String
    let year: Int?
    let status: String
    let seasons: [TVBSeason]
    let episodeTotalTmdb: Int
    let genreIds: [Int]
    let cast: [String]
    let popularity: Double
    let voteAverage: Double
    let voteCount: Int
    let posterPath: String?
    let backdropPath: String?
    /// Catalogue provider keys: "tp" | "kk" | "vs". NOTE: the
    /// catalogue's "vs" is the app's Providers.VS code ("vsmov")
    /// — see appProviderCode below. Empty on unresolved titles.
    let providers: [String: TVBProviderRecord]
    /// First of TP → KK → VS holding the title; null exactly
    /// when `providers` is empty.
    let primaryProvider: String?
    let categories: [String]
    let providerUpdatedAt: String?
    /// Precomputed normalized search keys (plan §3.1): display
    /// title, TMDB vi title, EN + original titles, every holder's
    /// own names, top-billed cast, year — already folded with
    /// Providers.normalizeTitle by the pipeline.
    let searchKeys: [String]

    var id: Int { tmdbId }

    /// Displayed = resolved on at least one provider (plan §1.4).
    var isDisplayed: Bool { !providers.isEmpty }

    var yearString: String { year.map(String.init) ?? "" }

    // MARK: Provider resolution

    /// Catalogue key → the app's provider code. Only "vs"
    /// differs: Providers.VS is "vsmov", and Providers.detail /
    /// search dispatch on that code — handing the detail the
    /// raw catalogue key "vs" would fall through to the KKPhim
    /// default with a VSMOV slug.
    static func appProviderCode(_ catalogueKey: String) -> String {
        switch catalogueKey {
        case "vs": return Providers.VS
        case "tp": return Providers.TP
        default: return Providers.KK
        }
    }

    /// Playback priority inside the snapshot (plan §1.2/§1.4).
    static let priorityKeys = ["tp", "kk", "vs"]

    var primaryRecord: TVBProviderRecord? {
        guard let primaryProvider else { return nil }
        return providers[primaryProvider]
    }

    /// The route target for a tap: the primary provider's FIRST
    /// slug (plan §3 / build spec), with a defensive fallback to
    /// the first holder in TP → KK → VS order carrying a slug —
    /// unreachable on the shipped snapshot (every displayed
    /// title's primary record has ≥1 slug, verified in the
    /// audit pass), kept so a future snapshot can never render
    /// a dead card.
    var routeTarget: (provider: String, slug: String)? {
        if let primaryProvider,
           let record = providers[primaryProvider],
           let slug = record.slugs.first, !slug.isEmpty {
            return (Self.appProviderCode(primaryProvider), slug)
        }
        for key in Self.priorityKeys {
            if let record = providers[key],
               let slug = record.slugs.first, !slug.isEmpty {
                return (Self.appProviderCode(key), slug)
            }
        }
        return nil
    }

    /// The primary holder's dub form, exactly as the provider
    /// states it (plan §2: non-dubbed titles are shown by their
    /// real form, never relabelled).
    var dubForm: String {
        if let form = primaryRecord?.dubForm, !form.isEmpty { return form }
        for key in Self.priorityKeys {
            if let form = providers[key]?.dubForm, !form.isEmpty { return form }
        }
        return ""
    }

    /// Card meta line in the Movie.cardMeta shape: year · dub form.
    var cardMeta: String {
        [yearString, dubForm].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    // MARK: Artwork

    /// TMDB poster first (the house w500 convention —
    /// JoeImagePipeline.tmdbPosterURL builds the same URL from
    /// a path), the primary holder's posterFallback behind it,
    /// then any holder's fallback in priority order (plan §3).
    var posterURLString: String {
        if let path = posterPath, !path.isEmpty {
            return "https://image.tmdb.org/t/p/w500"
                + (path.hasPrefix("/") ? path : "/" + path)
        }
        if let fallback = primaryRecord?.posterFallback, !fallback.isEmpty {
            return fallback
        }
        for key in Self.priorityKeys {
            if let fallback = providers[key]?.posterFallback, !fallback.isEmpty {
                return fallback
            }
        }
        return ""
    }

    var posterURL: URL? {
        posterURLString.isEmpty ? nil : URL(string: posterURLString)
    }

    // MARK: Search index

    /// The in-tab search corpus for this title (plan §3.1): the
    /// pipeline's precomputed searchKeys, plus the raw title and
    /// cast fields normalized here so the corpus stays correct
    /// even if a future snapshot's key list thins out. All keys
    /// pass through Providers.normalizeTitle — the same folding
    /// the query gets — so diacritics-free typing matches.
    var normalizedKeys: [String] {
        (searchKeys + [titleVi, titleEn, titleOriginal] + cast)
            .map { Providers.normalizeTitle($0) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - TVB section root
//
// One new section beside the existing ones, on the shell's
// unchanged scaffolding: a header (title + the tab's own search
// entry, the Phim slim-header construction), the genre chips
// row (plan §3.2), then either the rails home (the five pipeline
// rails of plan §3.3/§3 in build order, then the seven genre
// shelves) or — while a genre chip is selected — that shelf's
// grid (the JoeBrowseView 6-column construction). The in-tab
// search (plan §3.1) swaps in above the home exactly as the
// Phim search swaps in above JoePhimHome.
//
// MENU: this root carries the section handler in the
// JoeTVSection / JoeSettingsView shape — Menu returns to the
// Phim section. The search layer carries its own nearer handler
// (the JoeSearchView placement), so while search is open one
// press closes search and nothing else; the state check inside
// this root's handler mirrors JoePhimHome's for the presses the
// root itself sees. Focus is geometric throughout: plain
// buttons in declared .focusSection()s, the shared
// .joeCardButton() construction, no handlers, no focus writes
// beyond the header's .defaultFocus entry declaration (the
// slim-header pattern).
struct JoeTVBView: View {
    @EnvironmentObject private var nav: JoeNavigator
    @Environment(\.joeTheme) private var theme
    @State private var catalog: TVBCatalog?
    @State private var loadFailed = false
    @State private var searchOpen = false
    /// The selected genre shelf's name; nil = the rails home.
    @State private var selectedGenre: String?
    @FocusState private var headerSearchFocused: Bool
    @FocusState private var chipFocus: String?
    @FocusState private var cardFocus: String?

    /// The seven genre shelves, in the snapshot's audit order
    /// (TVB-PHASE1-AUDIT §5). A shelf renders only when the
    /// loaded snapshot carries it.
    static let genreOrder = [
        "Cổ Trang / Kiếm Hiệp",
        "Hình Sự / Phá Án",
        "Tình Cảm",
        "Gia Đình",
        "Hài Hước",
        "Hành Động",
        "Tâm Lý / Chính Kịch",
    ]

    /// Displayed titles by TMDB id, built once at load.
    @State private var byId: [Int: TVBTitle] = [:]
    @State private var displayed: [TVBTitle] = []

    var body: some View {
        Group {
            if searchOpen {
                JoeTVBSearchView(titles: displayed) { searchOpen = false }
            } else {
                home
            }
        }
        // Menu in this SECTION returns to the Phim section —
        // the app's main menu — instead of exiting the app
        // (the JoeTVSection / JoeSettingsView handler, on this
        // section's own root). The search layer's own handler
        // is the nearer consumer while search is open.
        .onExitCommand {
            if searchOpen {
                searchOpen = false
            } else {
                nav.section = .phim
            }
        }
        .task { await loadCatalog() }
    }

    // MARK: - Load

    private func loadCatalog() async {
        guard catalog == nil, !loadFailed else { return }
        let loaded = await Task.detached(priority: .userInitiated) {
            TVBCatalog.loadBundled()
        }.value
        guard let loaded else {
            loadFailed = true
            return
        }
        catalog = loaded
        displayed = loaded.titles.filter { $0.isDisplayed }
        byId = Dictionary(uniqueKeysWithValues: displayed.map { ($0.tmdbId, $0) })
        // Warm the first rails' posters (the JoePhimHome launch
        // prefetch pattern) so the home paints with art, not
        // placeholders, on its first scroll.
        let warm = (loaded.rails.dangHot + loaded.rails.deCu
            + loaded.rails.moiCapNhat)
            .compactMap { byId[$0]?.posterURL }
        JoeImagePipeline.shared.prefetch(warm, targetPixels: 720)
    }

    private func titles(for ids: [Int]) -> [TVBTitle] {
        ids.compactMap { byId[$0] }
    }

    // MARK: - Home

    private var home: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 40) {
                header
                if let catalog {
                    chipsRow(catalog)
                    if let genre = selectedGenre,
                       let ids = catalog.shelves[genre] {
                        genreSection(genre, ids: ids)
                    } else {
                        railSections(catalog)
                    }
                } else if loadFailed {
                    Text("Không tải được danh sách TVB.")
                        .font(.system(size: 29))
                        .foregroundStyle(theme.meta)
                        .padding(.top, 30)
                } else {
                    ProgressView("Đang tải danh sách TVB…")
                        .font(.system(size: 29))
                        .foregroundStyle(theme.text)
                        .tint(theme.text)
                        .padding(.top, 30)
                }
            }
        }
        // Focus rings are never clipped by the scroll
        // container (the v2.0.8 Phase 4 construction).
        .scrollClipDisabled()
    }

    /// The header mirrors JoePhimHome's slim header: section
    /// title + subtitle on the left, ONE entry button on the
    /// right carrying the section's .defaultFocus declaration —
    /// here the entry into the tab's own search.
    private var header: some View {
        HStack(alignment: .center, spacing: 28) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Phim bộ TVB")
                    .font(.system(size: 44, weight: .heavy))
                    .foregroundStyle(theme.text)
                Text("Phim bộ Hồng Kông lồng tiếng — Tủ Phim · KKPhim · VSMOV")
                    .font(.system(size: 25))
                    .foregroundStyle(theme.meta)
            }
            Spacer()
            Button {
                if catalog != nil { searchOpen = true }
            } label: {
                JoeSecondaryLabel(title: "Tìm trong TVB",
                                  systemImage: "magnifyingglass")
            }
            .joeCardButton()
            .focused($headerSearchFocused)
        }
        .defaultFocus($headerSearchFocused, true)
    }

    // MARK: - Genre chips (plan §3.2)

    private func chipsRow(_ catalog: TVBCatalog) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                chip(id: "genre:all", title: "Tất cả",
                     selected: selectedGenre == nil) {
                    selectedGenre = nil
                }
                ForEach(Self.genreOrder, id: \.self) { name in
                    if catalog.shelves[name] != nil {
                        chip(id: "genre:" + name, title: name,
                             selected: selectedGenre == name) {
                            selectedGenre = name
                        }
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
        }
        .focusSection()
    }

    private func chip(id: String, title: String, selected: Bool,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            JoeChipLabel(title: title, selected: selected)
        }
        .joeCardButton()
        .focused($chipFocus, equals: id)
    }

    // MARK: - Rails home (plan §3 + §3.3)

    private struct RailSpec: Identifiable {
        let scope: String
        let title: String
        let ids: [Int]
        var id: String { scope }
    }

    /// The five pipeline rails in build order, then the seven
    /// genre shelves in audit order. A rail renders only when
    /// it resolves to at least one displayed title.
    private func railSpecs(_ catalog: TVBCatalog) -> [RailSpec] {
        var specs = [
            RailSpec(scope: "dangHot", title: "🔥 Đang hot",
                     ids: catalog.rails.dangHot),
            RailSpec(scope: "deCu", title: "⭐ Đề cử",
                     ids: catalog.rails.deCu),
            RailSpec(scope: "moiCapNhat", title: "✨ Mới cập nhật",
                     ids: catalog.rails.moiCapNhat),
            RailSpec(scope: "moiPhatHanh", title: "🆕 Mới phát hành",
                     ids: catalog.rails.moiPhatHanh),
            RailSpec(scope: "kinhDien", title: "🏛️ Kinh điển",
                     ids: catalog.rails.kinhDien),
        ]
        for name in Self.genreOrder {
            if let ids = catalog.shelves[name] {
                specs.append(RailSpec(scope: "shelf:" + name, title: name,
                                      ids: ids))
            }
        }
        return specs
    }

    @ViewBuilder
    private func railSections(_ catalog: TVBCatalog) -> some View {
        ForEach(railSpecs(catalog)) { spec in
            let movies = titles(for: spec.ids)
            if !movies.isEmpty {
                Rail(title: spec.title) {
                    ForEach(movies) { title in
                        card(title, focusID: spec.scope + "|" + "\(title.tmdbId)",
                             form: .rail)
                    }
                }
            }
        }
    }

    // MARK: - Genre shelf grid (chip selected)

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: theme.railGap), count: 6)
    }

    @ViewBuilder
    private func genreSection(_ genre: String, ids: [Int]) -> some View {
        let movies = titles(for: ids)
        Text(genre)
            .font(.system(size: theme.id == .posterWall ? 40 : 34,
                          weight: theme.id == .posterWall ? .heavy : .bold))
            .foregroundStyle(theme.text)
        if movies.isEmpty {
            Text("Chưa có phim trong mục này.")
                .font(.system(size: 29))
                .foregroundStyle(theme.meta)
        } else {
            LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 40) {
                ForEach(movies) { title in
                    card(title, focusID: "genre|" + "\(title.tmdbId)",
                         form: .wall)
                }
            }
            .padding(.vertical, 8)
            // Design D's wall ring is an OUTSET band around the
            // art (6 pt): the grid's edge clearance grows past
            // it under D so the outer columns' rings are never
            // clipped by the scroll frame (the JoeBrowseView
            // construction).
            .padding(.horizontal, theme.id == .posterWall ? 8 : 4)
            .focusSection()
        }
    }

    // MARK: - Cards + detail routing

    private func card(_ title: TVBTitle, focusID: String,
                      form: PosterCard.Form) -> some View {
        Button { open(title) } label: {
            PosterCard(
                title: title.titleVi,
                posterURL: title.posterURL,
                tmdbId: "\(title.tmdbId)",
                tmdbType: "tv",
                meta: title.cardMeta,
                badge: title.routeTarget.map { Providers.badge($0.provider) },
                form: form)
        }
        .joeCardButton()
        .focused($cardFocus, equals: focusID)
    }

    /// A tap mints the SAME MovieRoute every other rail mints:
    /// the detail loads Providers.detail(provider, slug) from
    /// it, resolves the series' TMDB identity from the provider
    /// detail payload, and finds the other holders through its
    /// existing alternatives search (Providers.findAlternatives,
    /// name + year over the other providers) — the detail's
    /// source chips cover switching, exactly as for any title.
    private func open(_ title: TVBTitle) {
        guard let target = title.routeTarget else { return }
        nav.movie = MovieRoute(
            provider: target.provider, slug: target.slug,
            name: title.titleVi, poster: title.posterURLString,
            year: title.yearString)
    }
}

// MARK: - In-tab search (plan §3.1)
//
// The tab's OWN search over the snapshot's displayed titles
// only — it never calls the providers and never touches the
// global catalogue, and it works fully offline from the file
// the tab already holds. The field row is JoeSearchView's
// construction verbatim in shape (light field, Tìm, Quay lại,
// the field as the layer's declared focus); ranking mirrors
// the existing search's tiers over Providers.normalizeTitle:
// exact normalized match first, then prefix, then contains
// (JoeSearch.renderPool's exact-tier promotion, extended with
// the plan §3.1 prefix tier). A search with no hits says so
// plainly — JoeSearchView's own empty line — and never falls
// through to the global search.
struct JoeTVBSearchView: View {
    let titles: [TVBTitle]
    let onClose: () -> Void
    @EnvironmentObject private var nav: JoeNavigator
    @Environment(\.joeTheme) private var theme
    @State private var query = ""
    @State private var results: [TVBTitle] = []
    @State private var searched = false
    @FocusState private var cardFocus: String?

    private enum TopFocus: Hashable { case field, search, back }
    @FocusState private var topFocus: TopFocus?

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            if theme.id == .posterWall {
                fieldRow
            } else {
                HStack(spacing: 0) {
                    Spacer()
                    fieldRow
                    Spacer()
                }
            }
            if searched && results.isEmpty {
                Text("Không tìm thấy phim nào.")
                    .font(.system(size: 29))
                    .foregroundStyle(theme.meta)
            }
            resultsArea
                .focusSection()
        }
        // Menu closes the search layer: the handler is
        // unconditional and lives on the layer itself (the
        // JoeSearchView placement), so it exists exactly while
        // the layer does.
        .onExitCommand { onClose() }
        // The query field is the layer's declared initial
        // focus (the JoeSearchView construction).
        .defaultFocus($topFocus, .field)
    }

    private var fieldRow: some View {
        HStack(spacing: 18) {
            TextField("", text: $query,
                      prompt: Text("Tên phim, diễn viên…")
                        .foregroundColor(ThemeTokens.fieldPlaceholder))
                .textFieldStyle(.plain)
                .font(.system(size: ThemeTokens.fieldTextSize))
                .joeFieldChrome(focused: topFocus == .field)
                .frame(maxWidth: theme.id == .posterWall ? .infinity : 700)
                .focused($topFocus, equals: .field)
                .onSubmit { runSearch() }
            Button {
                runSearch()
            } label: {
                JoeSecondaryLabel(title: "Tìm")
            }
            .joeCardButton()
            .focused($topFocus, equals: .search)
            .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
            Button {
                onClose()
            } label: {
                JoeSecondaryLabel(title: "⟵ Quay lại")
            }
            .joeCardButton()
            .focused($topFocus, equals: .back)
        }
        .focusSection()
    }

    private var resultsArea: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: theme.railGap),
                                     count: 6),
                      alignment: .leading, spacing: 40) {
                ForEach(results) { title in
                    Button { open(title) } label: {
                        PosterCard(
                            title: title.titleVi,
                            posterURL: title.posterURL,
                            tmdbId: "\(title.tmdbId)",
                            tmdbType: "tv",
                            meta: title.cardMeta,
                            badge: title.routeTarget.map { Providers.badge($0.provider) })
                    }
                    .joeCardButton()
                    .focused($cardFocus, equals: "tvbsearch|" + "\(title.tmdbId)")
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, theme.id == .posterWall ? 8 : 4)
        }
        .scrollClipDisabled()
    }

    private func runSearch() {
        let kw = query.trimmingCharacters(in: .whitespaces)
        guard !kw.isEmpty else { return }
        results = Self.ranked(query: kw, titles: titles)
        searched = true
    }

    private func open(_ title: TVBTitle) {
        guard let target = title.routeTarget else { return }
        nav.movie = MovieRoute(
            provider: target.provider, slug: target.slug,
            name: title.titleVi, poster: title.posterURLString,
            year: title.yearString)
    }

    /// Tier ranking over the normalized keys (plan §3.1): a
    /// title takes its BEST tier across all its keys — any key
    /// equal to the query, else any key starting with it, else
    /// any key containing it. Catalogue order is preserved
    /// inside each tier (the shipped snapshot's order).
    static func ranked(query: String, titles: [TVBTitle]) -> [TVBTitle] {
        let q = Providers.normalizeTitle(query)
        guard !q.isEmpty else { return [] }
        var exact: [TVBTitle] = []
        var prefix: [TVBTitle] = []
        var contains: [TVBTitle] = []
        for title in titles {
            let keys = title.normalizedKeys
            if keys.contains(q) {
                exact.append(title)
            } else if keys.contains(where: { $0.hasPrefix(q) }) {
                prefix.append(title)
            } else if keys.contains(where: { $0.contains(q) }) {
                contains.append(title)
            }
        }
        return exact + prefix + contains
    }
}
