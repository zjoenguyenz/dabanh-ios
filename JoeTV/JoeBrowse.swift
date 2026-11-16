import SwiftUI

// MARK: - Multi-facet browse filter (owner expansion, 2026-11-15)
//
// The complete filter set, one row per facet, on every browse
// surface (A/F grid, D wall): Thể loại / Năm / Quốc gia / Loại
// phim / Ngôn ngữ / Sắp xếp. Facets combine with AND; every
// facet defaults to "Tất cả"; state is per-session (@State in
// the surface views — recreated per open, so it resets on
// section change).
//
// GROUNDING (pre-build test, ui-redesign/filter-predicate-test.py
// — run against the REAL list payloads before this code was
// written; every check passed): the predicates below mirror
// that script line by line. Rules the test proved:
//  - Filters run client-side over the loaded browse set using
//    the fields the payloads actually carry (KK/VS: year, type,
//    lang, country, categories; Film4K: year, mediaType→type,
//    lang flags, + country/genres read additively; Tủ Phim:
//    year, type, lang, + categories/countries read additively).
//  - VS list payloads are SPARSE (year only — no type/lang/
//    country/category keys at all): VS items therefore match
//    only the year facet and "Tất cả" elsewhere.
//  - MISSING-FIELD RULE: an item missing the faceted field
//    never matches a non-"Tất cả" selection for that facet.
//  - A facet row is HIDDEN when no item in the loaded set
//    carries that facet's field at all (never shown dead).
//  - Year buckets are derived from the loaded data: every
//    year ≥ 2020 present, descending, plus "Trước 2020".

enum JoeYearBucket: Hashable {
    case all
    case year(Int)
    case before2020

    var chipID: String {
        switch self {
        case .all: return "year:all"
        case .year(let y): return "year:\(y)"
        case .before2020: return "year:before"
        }
    }
}

enum JoeCountryBucket: String, CaseIterable {
    case auMy, hanQuoc, trungQuoc, nhatBan, vietNam, thaiLan, daiLoan, hongKong, khac

    var title: String {
        switch self {
        case .auMy: return "Âu Mỹ"
        case .hanQuoc: return "Hàn Quốc"
        case .trungQuoc: return "Trung Quốc"
        case .nhatBan: return "Nhật Bản"
        case .vietNam: return "Việt Nam"
        case .thaiLan: return "Thái Lan"
        case .daiLoan: return "Đài Loan"
        case .hongKong: return "Hồng Kông"
        case .khac: return "Khác"
        }
    }

    var chipID: String { "country:" + rawValue }
}

enum JoeTypeFacet: Hashable {
    case all, series, single, anime, chieuRap

    var title: String {
        switch self {
        case .all: return "Tất cả"
        case .series: return "Phim bộ"
        case .single: return "Phim lẻ"
        case .anime: return "Hoạt hình"
        case .chieuRap: return "Chiếu rạp"
        }
    }

    var chipID: String {
        switch self {
        case .all: return "type:all"
        case .series: return "type:series"
        case .single: return "type:single"
        case .anime: return "type:anime"
        case .chieuRap: return "type:chieuRap"
        }
    }
}

enum JoeSortOrder: String, Hashable {
    case updated, newest, oldest

    var title: String {
        switch self {
        case .updated: return "Mới cập nhật"
        case .newest: return "Năm mới nhất"
        case .oldest: return "Năm cũ nhất"
        }
    }

    var chipID: String { "sort:" + rawValue }
}

struct JoeBrowseFilter: Hashable {
    var genre: String? = nil
    var year: JoeYearBucket = .all
    var country: JoeCountryBucket? = nil
    var type: JoeTypeFacet = .all
    var lang: String? = nil
    var sort: JoeSortOrder = .updated

    /// Any FILTER facet off its default (sort is not a filter:
    /// it never hides the owner/category shelves).
    var filtersActive: Bool {
        genre != nil || year != .all || country != nil
            || type != .all || lang != nil
    }

    var sortChipID: String { sort.chipID }

    static let langNeedles = ["Vietsub", "Lồng Tiếng", "Thuyết Minh"]

    // MARK: Base set + predicates + sort

    /// The filtered, sorted browse list. Base-set selection:
    /// the genre facet keeps its server-side KK genre lists
    /// (the built, proven path); "Chiếu rạp" selects the
    /// store's chiếu-rạp list (no payload flag exists on the
    /// merged items — the list IS the source); both together
    /// intersect by movie id. Every other facet is a pure
    /// predicate over the base; sort applies last.
    @MainActor
    func apply(phim: PhimStore) -> [Movie] {
        var base: [Movie]
        if type == .chieuRap, let slug = genre {
            let inGenre = Set((phim.genreLists[slug] ?? []).map { $0.id })
            base = phim.chieuRap.filter { inGenre.contains($0.id) }
        } else if type == .chieuRap {
            base = phim.chieuRap
        } else if let slug = genre {
            base = phim.genreLists[slug] ?? []
        } else {
            base = phim.merged
        }
        let filtered = base.filter { m in
            Self.matchesYear(m, year)
                && Self.matchesCountry(m, country)
                && Self.matchesType(m, type)
                && Self.matchesLang(m, lang)
        }
        return Self.sorted(filtered, by: sort)
    }

    static func yearInt(_ m: Movie) -> Int? {
        Int(Providers.yearOf(m))
    }

    static func matchesYear(_ m: Movie, _ bucket: JoeYearBucket) -> Bool {
        switch bucket {
        case .all:
            return true
        case .year(let y):
            return yearInt(m) == y
        case .before2020:
            guard let y = yearInt(m) else { return false }
            return y < 2020
        }
    }

    /// Source country name → facet bucket. The eight named
    /// buckets match exactly; clearly-Western country names
    /// fold into Âu Mỹ (the KK catalogue's own aggregate);
    /// everything else is Khác.
    static func countryBucket(ofName name: String) -> JoeCountryBucket {
        switch name {
        case "Âu Mỹ": return .auMy
        case "Hàn Quốc": return .hanQuoc
        case "Trung Quốc": return .trungQuoc
        case "Nhật Bản": return .nhatBan
        case "Việt Nam": return .vietNam
        case "Thái Lan": return .thaiLan
        case "Đài Loan": return .daiLoan
        case "Hồng Kông": return .hongKong
        case "Anh", "Pháp", "Đức", "Ý", "Tây Ban Nha", "Bồ Đào Nha",
             "Hà Lan", "Bỉ", "Đan Mạch", "Thụy Điển", "Na Uy",
             "Phần Lan", "Áo", "Thụy Sĩ", "Ireland", "Canada",
             "Mỹ", "Hoa Kỳ", "Úc", "New Zealand", "Nga":
            return .auMy
        default:
            return .khac
        }
    }

    static func matchesCountry(_ m: Movie, _ bucket: JoeCountryBucket?) -> Bool {
        guard let bucket else { return true }
        guard !m.country.isEmpty else { return false }
        return m.country
            .components(separatedBy: "·")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .contains { countryBucket(ofName: $0) == bucket }
    }

    /// Type vocabularies differ per source (KK/VS raw values,
    /// Film4K normalised to series/single, Tủ Phim mapped to
    /// phim-bo/phim-le) — the predicates accept every spelling.
    /// Hoạt hình is a FLAG, not an exclusive type: the type
    /// field where the source models it that way, else the
    /// "Hoạt Hình" genre name in the item's categories (Tủ
    /// Phim's type mapping folds hoathinh into phim-le; its
    /// categories carry the flag).
    static func matchesType(_ m: Movie, _ facet: JoeTypeFacet) -> Bool {
        switch facet {
        case .all, .chieuRap:
            return true
        case .series:
            return m.type == "series" || m.type == "phim-bo"
        case .single:
            return m.type == "single" || m.type == "phim-le" || m.type == "movie"
        case .anime:
            if m.type == "hoathinh" || m.type == "hoat-hinh" { return true }
            return m.categories.contains {
                $0.localizedCaseInsensitiveContains("hoạt hình")
            }
        }
    }

    /// Language needles match as substrings (case-insensitive):
    /// combo lang strings ("Vietsub + Lồng Tiếng") match each
    /// of their languages; Film4K's "Thuyết minh" spelling
    /// matches "Thuyết Minh".
    static func matchesLang(_ m: Movie, _ needle: String?) -> Bool {
        guard let needle else { return true }
        guard !m.lang.isEmpty else { return false }
        return m.lang.localizedCaseInsensitiveContains(needle)
    }

    /// Stable sort on the year field; items without a year go
    /// last in both directions; .updated keeps source order.
    static func sorted(_ movies: [Movie], by order: JoeSortOrder) -> [Movie] {
        switch order {
        case .updated:
            return movies
        case .newest, .oldest:
            return movies.enumerated().sorted { a, b in
                let ya = yearInt(a.element), yb = yearInt(b.element)
                switch (ya, yb) {
                case (nil, nil):
                    return a.offset < b.offset
                case (nil, _):
                    return false
                case (_, nil):
                    return true
                case let (x?, y?):
                    if x != y { return order == .newest ? x > y : x < y }
                    return a.offset < b.offset
                }
            }.map { $0.element }
        }
    }

    // MARK: Facet derivation + visibility

    /// Year buckets from the loaded data: every year ≥ 2020
    /// present, descending (with today's catalogues that is
    /// 2026…2020 — the owner's list, extended by the years the
    /// data actually carries).
    static func yearBuckets(for movies: [Movie]) -> [Int] {
        Set(movies.compactMap { yearInt($0) }.filter { $0 >= 2020 })
            .sorted(by: >)
    }

    static func hasBefore2020(_ movies: [Movie]) -> Bool {
        movies.contains { (yearInt($0) ?? Int.max) < 2020 }
    }

    /// A facet row is shown only when the loaded set carries
    /// that facet's field at all (never shown dead).
    static func facetVisibility(for movies: [Movie])
        -> (year: Bool, country: Bool, type: Bool, lang: Bool) {
        (year: movies.contains { yearInt($0) != nil },
         country: movies.contains { !$0.country.isEmpty },
         type: movies.contains { !$0.type.isEmpty || !$0.categories.isEmpty },
         lang: movies.contains { !$0.lang.isEmpty })
    }
}

// MARK: - Facet bar (shared by the browse grid and the wall)

/// One horizontally scrolling chip row per facet, facet label
/// at the left. Chips are the shared painted JoeChipLabel
/// under .card; focus is value-only (the chip's own ring and
/// title colour), and chip ids are namespaced per facet so a
/// single FocusState serves the whole bar.
struct JoeFilterBar: View {
    @Environment(\.joeTheme) private var theme
    @Binding var filter: JoeBrowseFilter
    let years: [Int]
    let hasBefore2020: Bool
    let showYear: Bool
    let showCountry: Bool
    let showType: Bool
    let showLang: Bool
    var chipFocus: FocusState<String?>.Binding
    /// Browse surface only: the landing of a DOWN press on a
    /// sort-row chip — the results grid's first item, the
    /// reciprocal of the grid's UP → sort-chip landing
    /// (JoeBrowseView.gridMove). The wall passes nil: owner
    /// rails sit between its bar and its grid, so its sort row
    /// keeps geometric DOWN and its chips carry no move
    /// handler.
    var onSortChipDown: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            facetRow("Thể loại") {
                chip(id: "genre:all", title: "Tất cả",
                     selected: filter.genre == nil) { filter.genre = nil }
                ForEach(Array(PhimStore.genreSpec.enumerated()), id: \.offset) { _, spec in
                    chip(id: "genre:" + spec.slug, title: spec.title,
                         selected: filter.genre == spec.slug) {
                        filter.genre = spec.slug
                    }
                }
            }
            if showYear {
                facetRow("Năm") {
                    chip(id: JoeYearBucket.all.chipID, title: "Tất cả",
                         selected: filter.year == .all) { filter.year = .all }
                    ForEach(years, id: \.self) { y in
                        chip(id: JoeYearBucket.year(y).chipID, title: "\(y)",
                             selected: filter.year == .year(y)) {
                            filter.year = .year(y)
                        }
                    }
                    if hasBefore2020 {
                        chip(id: JoeYearBucket.before2020.chipID, title: "Trước 2020",
                             selected: filter.year == .before2020) {
                            filter.year = .before2020
                        }
                    }
                }
            }
            if showCountry {
                facetRow("Quốc gia") {
                    chip(id: "country:all", title: "Tất cả",
                         selected: filter.country == nil) { filter.country = nil }
                    ForEach(JoeCountryBucket.allCases, id: \.self) { bucket in
                        chip(id: bucket.chipID, title: bucket.title,
                             selected: filter.country == bucket) {
                            filter.country = bucket
                        }
                    }
                }
            }
            if showType {
                facetRow("Loại phim") {
                    ForEach([JoeTypeFacet.all, .series, .single, .anime, .chieuRap],
                            id: \.self) { facet in
                        chip(id: facet.chipID, title: facet.title,
                             selected: filter.type == facet) {
                            filter.type = facet
                        }
                    }
                }
            }
            if showLang {
                facetRow("Ngôn ngữ") {
                    chip(id: "lang:all", title: "Tất cả",
                         selected: filter.lang == nil) { filter.lang = nil }
                    ForEach(JoeBrowseFilter.langNeedles, id: \.self) { needle in
                        chip(id: "lang:" + needle, title: needle,
                             selected: filter.lang == needle) {
                            filter.lang = needle
                        }
                    }
                }
            }
            facetRow("Sắp xếp") {
                ForEach([JoeSortOrder.updated, .newest, .oldest], id: \.self) { order in
                    chip(id: order.chipID, title: order.title,
                         selected: filter.sort == order,
                         onMove: sortMoveHandler(for: order.chipID)) {
                        filter.sort = order
                    }
                }
                // Đặt lại (owner, error 7): one press returns
                // EVERY facet and the sort to defaults — the
                // filter is a single value, so one assignment
                // is the whole reset (no more un-tapping six
                // rows of "Tất cả" chips). It rides the sort
                // row's end and the row's focus system like
                // any chip; it is never "selected".
                chip(id: "sort:reset", title: "Đặt lại",
                     selected: false,
                     onMove: sortMoveHandler(for: "sort:reset")) {
                    filter = JoeBrowseFilter()
                }
            }
        }
    }

    private func facetRow<Content: View>(_ title: String,
                                         @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 20) {
            Text(title)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(theme.meta)
                .frame(width: 170, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) { content() }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 6)
            }
        }
    }

    @ViewBuilder
    private func chip(id: String, title: String, selected: Bool,
                      onMove: ((MoveCommandDirection) -> Void)? = nil,
                      action: @escaping () -> Void) -> some View {
        let button = Button(action: action) {
            JoeChipLabel(title: title, selected: selected)
        }
        .joeCardButton()
        .focused(chipFocus, equals: id)
        // The attachment follows the SURFACE (browse vs wall —
        // see onSortChipDown), never focus state: the
        // JoeSearchView.resultCard construction.
        if let onMove {
            button.onMoveCommand(perform: onMove)
        } else {
            button
        }
    }

    /// The sort row's chip ids in visual order — the three
    /// sort chips plus Đặt lại riding last.
    private var sortRowChipIDs: [String] {
        [JoeSortOrder.updated, .newest, .oldest].map { $0.chipID } + ["sort:reset"]
    }

    /// The sort row's move handler, present only where the
    /// surface declared a DOWN landing (onSortChipDown);
    /// everywhere else the chips carry no handler at all.
    private func sortMoveHandler(for id: String) -> ((MoveCommandDirection) -> Void)? {
        guard onSortChipDown != nil else { return nil }
        return { direction in sortMove(direction, from: id) }
    }

    /// Sort-row routing (browse surface): once a chip carries
    /// a move handler the handler owns every direction, so
    /// LEFT/RIGHT are the row's own arithmetic (stopping at
    /// the row's ends, the file's chip convention), UP lands
    /// on the ACTIVE chip of the facet row directly above —
    /// the same active-chip landing the grids use in reverse
    /// (gridMove / wallMove) — and DOWN is the surface's
    /// declared landing: the results grid's first item.
    private func sortMove(_ direction: MoveCommandDirection, from id: String) {
        let ids = sortRowChipIDs
        switch direction {
        case .left:
            if let i = ids.firstIndex(of: id), i > 0 {
                chipFocus.wrappedValue = ids[i - 1]
            }
        case .right:
            if let i = ids.firstIndex(of: id), i + 1 < ids.count {
                chipFocus.wrappedValue = ids[i + 1]
            }
        case .up:
            chipFocus.wrappedValue = showLang
                ? (filter.lang.map { "lang:" + $0 } ?? "lang:all")
                : filter.type.chipID
        case .down:
            onSortChipDown?()
        @unknown default:
            break
        }
    }
}

// MARK: - Browse / grid layer (designs A and F)
//
// The browse surface every theme exposes: the multi-facet
// filter bar over a 6-column poster grid. Filter state is
// per-session: it lives in this view's @State, the view is
// recreated per open, and the root closes the layer on section
// change — so the filter always starts at Tất cả. An empty
// result is a clean text state; the spinner exists only while
// the store itself is still inside its bounded load.

struct JoeBrowseView: View {
    @EnvironmentObject private var nav: JoeNavigator
    @EnvironmentObject private var phim: PhimStore
    @Environment(\.joeTheme) private var theme
    @State private var filter = JoeBrowseFilter()
    @FocusState private var chipFocus: String?
    @FocusState private var gridFocus: Movie.ID?

    private var movies: [Movie] { filter.apply(phim: phim) }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: theme.railGap), count: 6)
    }

    var body: some View {
        // Error 7 (owner): the bar used to be PINNED above a
        // separate results ScrollView — ~525 pt of fixed
        // header on a 1080 pt screen, leaving the grid a
        // single poster row. The bar now rides INSIDE the one
        // scroll container, the theme D wall's construction
        // (JoeWallHomeView): it scrolls away and the grid gets
        // the screen. The title stays the fixed header above
        // the scroll.
        VStack(alignment: .leading, spacing: 26) {
            Text("Tất cả phim")
                .font(.system(size: 44, weight: .heavy))
                .foregroundStyle(theme.text)
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 26) {
                    JoeFilterBar(filter: $filter,
                                 years: JoeBrowseFilter.yearBuckets(for: phim.merged),
                                 hasBefore2020: JoeBrowseFilter.hasBefore2020(phim.merged),
                                 showYear: JoeBrowseFilter.facetVisibility(for: phim.merged).year,
                                 showCountry: JoeBrowseFilter.facetVisibility(for: phim.merged).country,
                                 showType: JoeBrowseFilter.facetVisibility(for: phim.merged).type,
                                 showLang: JoeBrowseFilter.facetVisibility(for: phim.merged).lang,
                                 chipFocus: $chipFocus,
                                 onSortChipDown: {
                                     if let first = movies.first {
                                         gridFocus = "browse|" + first.id
                                     }
                                 })
                        // v2.0.5 (N1, pair e): the bar is a
                        // declared focus region, the grid
                        // below it another; the Wave-1 pair
                        // (sortMove DOWN → first item, gridMove
                        // UP → active sort chip) routes between
                        // them.
                        .focusSection()
                    if movies.isEmpty {
                        if phim.loading && !phim.loadTimedOut {
                            ProgressView("Đang tải…")
                                .font(.system(size: 29))
                                .foregroundStyle(theme.text)
                                .tint(theme.text)
                        } else if filter.filtersActive {
                            Text("Không có phim nào khớp bộ lọc.")
                                .font(.system(size: 29))
                                .foregroundStyle(theme.meta)
                        } else {
                            Text("Chưa có phim trong mục này.")
                                .font(.system(size: 29))
                                .foregroundStyle(theme.meta)
                        }
                    } else {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 40) {
                            ForEach(movies) { movie in
                                Button { nav.movie = MovieRoute(
                                    provider: movie.provider, slug: movie.slug,
                                    name: movie.name, poster: movie.poster,
                                    year: movie.year) } label: {
                                    PosterCard(
                                        title: movie.name,
                                        posterURL: movie.posterURL,
                                        tmdbId: movie.tmdbId,
                                        tmdbType: movie.tmdbType,
                                        meta: movie.cardMeta,
                                        badge: Providers.badge(movie.provider),
                                        quality: movie.quality)
                                }
                                .joeCardButton()
                                .focused($gridFocus, equals: "browse|" + movie.id)
                                .onMoveCommand { direction in
                                    gridMove(direction, from: movie)
                                }
                            }
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 4)
                        .focusSection()
                    }
                }
            }
        }
        // v2.0.5 (N1): the layer's DECLARED top element — the
        // filter bar's first chip. The browse layer swaps in
        // over the home (the tapped button's subtree is
        // destroyed), so focus needs a declared landing here
        // exactly as the search layer declares its field.
        .defaultFocus($chipFocus, "genre:all")
        .task(id: filter) {
            JoeImagePipeline.shared.prefetch(
                movies.compactMap { $0.posterURL }, targetPixels: 720)
        }
    }

    /// Grid routing, the JoeSearchView.resultMove shape: UP from
    /// the first row lands on the sort row's ACTIVE chip (the
    /// facet row nearest the grid); LEFT/RIGHT stop at row
    /// edges; DOWN past the end is a defined no-op. The
    /// reciprocal DOWN from the sort row is declared by the
    /// bar (JoeFilterBar.sortMove → this view's onSortChipDown
    /// → gridFocus on the grid's first item), so the
    /// bar ↔ grid pair is explicit in both directions.
    private func gridMove(_ direction: MoveCommandDirection, from movie: Movie) {
        guard let idx = movies.firstIndex(where: { $0.id == movie.id }) else { return }
        let columns = 6
        switch direction {
        case .left:
            if idx % columns > 0 { gridFocus = "browse|" + movies[idx - 1].id }
        case .right:
            if idx + 1 < movies.count, idx % columns < columns - 1 {
                gridFocus = "browse|" + movies[idx + 1].id
            }
        case .up:
            if idx >= columns {
                gridFocus = "browse|" + movies[idx - columns].id
            } else {
                chipFocus = filter.sortChipID
            }
        case .down:
            if idx + columns < movies.count {
                gridFocus = "browse|" + movies[idx + columns].id
            }
        @unknown default:
            break
        }
    }
}

// MARK: - Design D home: the poster wall (UI-5; D-1/D-20 UI-5-FIXUP)
//
// Home IS the wall: the shared multi-facet filter bar over a
// 6-column wall of poster-only cards. Continue Watching /
// Favourites ride above the wall as titled wall rows while no
// filter facet is active (they are owner shelves, not
// catalogue filters), and — UI-6 defect D-1 — EVERY category
// shelf rides BELOW the wall as a titled wall section in the
// same state, driven by the shared joeRailSpecs list: design
// D has the same catalogue completeness as A/F. Load states
// are at parity with the rail home (UI-6 defect D-20): the
// bounded spinner, the G3 two-state error surface with its
// cause line and Retry, the G5 empty surface, and the G4
// partial-failure line. Filter state is per-session (@State;
// the section view is recreated on section change).

struct JoeWallHomeView: View {
    @EnvironmentObject private var watch: WatchStore
    @EnvironmentObject private var nav: JoeNavigator
    @EnvironmentObject private var phim: PhimStore
    @Environment(\.joeTheme) private var theme
    @State private var filter = JoeBrowseFilter()
    /// D-20: same "a load has been attempted" gate as the rail
    /// home, so the state surfaces cannot flash at cold entry.
    @State private var attempted = false
    @FocusState private var chipFocus: String?
    @FocusState private var wallFocus: Movie.ID?
    @FocusState private var entryFocus: String?
    @FocusState private var retryFocused: Bool

    private var wallMovies: [Movie] { filter.apply(phim: phim) }

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

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: theme.railGap), count: 6)
    }

    // MARK: D-20 load-state predicates (rail-home parity)

    private var showWallError: Bool {
        attempted && phim.catalogueIsEmpty
            && (phim.loadTimedOut
                || (!phim.loading && !phim.providerErrors.isEmpty))
    }

    private var showWallEmpty: Bool {
        attempted && phim.catalogueIsEmpty && !phim.loading
            && !phim.loadTimedOut && phim.providerErrors.isEmpty
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 36) {
                JoeFilterBar(filter: $filter,
                             years: JoeBrowseFilter.yearBuckets(for: phim.merged),
                             hasBefore2020: JoeBrowseFilter.hasBefore2020(phim.merged),
                             showYear: JoeBrowseFilter.facetVisibility(for: phim.merged).year,
                             showCountry: JoeBrowseFilter.facetVisibility(for: phim.merged).country,
                             showType: JoeBrowseFilter.facetVisibility(for: phim.merged).type,
                             showLang: JoeBrowseFilter.facetVisibility(for: phim.merged).lang,
                             chipFocus: $chipFocus)
                    // v2.0.5 (N1, pair d): the wall's facet
                    // chain is a declared focus region; the
                    // owner rails and the wall grid below are
                    // regions of their own (rails via the
                    // shared Rail, the grid below).
                    .focusSection()
                if !filter.filtersActive {
                    cwWallRail
                    favWallRail
                }
                if wallMovies.isEmpty {
                    wallStateSurface
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 40) {
                        ForEach(wallMovies) { movie in
                            Button { nav.movie = MovieRoute(
                                provider: movie.provider, slug: movie.slug,
                                name: movie.name, poster: movie.poster,
                                year: movie.year) } label: {
                                PosterCard(
                                    title: movie.name,
                                    posterURL: movie.posterURL,
                                    tmdbId: movie.tmdbId,
                                    tmdbType: movie.tmdbType,
                                    meta: movie.cardMeta,
                                    badge: Providers.badge(movie.provider),
                                    quality: movie.quality)
                            }
                            .joeCardButton()
                            .focused($wallFocus, equals: "wall|" + movie.id)
                            .onMoveCommand { direction in
                                wallMove(direction, from: movie)
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                    .focusSection()
                }
                if !filter.filtersActive {
                    wallCategorySections
                }
                // §8/G4 parity (D-20): partial failure — one
                // non-focusable warning line at the very bottom.
                if phim.hasData && !phim.failedProviderNames.isEmpty {
                    Text("Chưa tải được: " + phim.failedProviderNames.joined(separator: ", "))
                        .font(.system(size: 25))
                        .foregroundStyle(.orange)
                }
            }
        }
        // v2.0.5 (N1/N2): the wall home's DECLARED top element
        // — the filter bar's first chip, the landing the pill
        // row's DOWN resigns focus to while the Poster Wall
        // home is the Phim section's face.
        .defaultFocus($chipFocus, "genre:all")
        .task {
            attempted = true
            JoeImagePipeline.shared.prefetch(
                phim.merged.compactMap { $0.posterURL }, targetPixels: 720)
        }
    }

    /// The wall's state surfaces, at rail-home parity (D-20):
    /// the bounded spinner; the G3 two-state error surface
    /// (deadline copy vs ended-with-errors copy, the store's
    /// real per-provider causes, Retry); the G5 quiet empty
    /// surface; and — when the catalogue is healthy but the
    /// active filter matches nothing — the filter-empty line.
    @ViewBuilder
    private var wallStateSurface: some View {
        if phim.loading && !phim.loadTimedOut {
            ProgressView("Đang tải thư viện phim…")
                .font(.system(size: 29))
                .foregroundStyle(theme.text)
                .tint(theme.text)
        } else if showWallError {
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
                .joeCardButton()
                .focused($retryFocused)
            }
        } else if showWallEmpty {
            Text("Thư viện chưa có dữ liệu.")
                .font(.system(size: 29))
                .foregroundStyle(theme.meta)
        } else if filter.filtersActive {
            Text("Không có phim nào khớp bộ lọc.")
                .font(.system(size: 29))
                .foregroundStyle(theme.meta)
        } else {
            Text("Chưa có phim trong mục này.")
                .font(.system(size: 29))
                .foregroundStyle(theme.meta)
        }
    }

    private func providerDisplayName(_ code: String) -> String {
        switch code {
        case "kk": return "KKPhim"
        case "f4k": return "Film4K"
        case "vsmov": return "VSMOV"
        case "tp": return "Tủ Phim"
        default: return code
        }
    }

    // MARK: D-1 category wall sections

    /// One titled wall section (a D-1 shelf).
    private struct WallSection: Identifiable {
        let scope: String
        let title: String
        let movies: [Movie]
        var id: String { scope }
    }

    /// Every category shelf as a wall section, in rail order:
    /// the shared spec list minus the merged rail (it IS the
    /// wall grid), the chiếu-rạp rail and the genre rails
    /// (those three are facets of the filter bar, not shelves).
    /// Tủ Phim's newest shelf — a band in F, folded into the
    /// merged rail in A — is inserted before its Phim lẻ shelf
    /// so D carries it too (UI-6's D-1 enumeration names it).
    private var wallSections: [WallSection] {
        var out: [WallSection] = []
        for spec in joeRailSpecs(phim: phim, themeID: theme.id) {
            if spec.scope == "merged" || spec.scope == "chieuRap"
                || spec.scope.hasPrefix("genre:") {
                continue
            }
            if spec.scope == "tpMovies", !phim.tpNew.isEmpty {
                out.append(WallSection(scope: "tpNew",
                                       title: "📚 Tủ Phim · Mới cập nhật",
                                       movies: phim.tpNew))
            }
            if !spec.movies.isEmpty {
                out.append(WallSection(scope: spec.scope, title: spec.title,
                                       movies: spec.movies))
            }
        }
        return out
    }

    @ViewBuilder
    private var wallCategorySections: some View {
        ForEach(wallSections) { section in
            Rail(title: section.title) {
                ForEach(section.movies) { movie in
                    Button { nav.movie = MovieRoute(
                        provider: movie.provider, slug: movie.slug,
                        name: movie.name, poster: movie.poster,
                        year: movie.year) } label: {
                        PosterCard(
                            title: movie.name,
                            posterURL: movie.posterURL,
                            tmdbId: movie.tmdbId,
                            tmdbType: movie.tmdbType,
                            meta: movie.cardMeta,
                            badge: Providers.badge(movie.provider),
                            quality: movie.quality)
                    }
                    .joeCardButton()
                    .focused($entryFocus, equals: "sec|" + section.scope + "|" + movie.id)
                }
            }
        }
    }

    @ViewBuilder
    private var cwWallRail: some View {
        if !movieProgress.isEmpty {
            Rail(title: "▶ Đang xem dở") {
                ForEach(movieProgress) { entry in
                    Button { nav.movie = MovieRoute(
                        provider: entry.source, slug: entry.slug,
                        name: entry.title, poster: entry.poster,
                        year: entry.year, preselectEp: entry.ep) } label: {
                        PosterCard(
                            title: entry.title,
                            posterURL: entry.posterURL,
                            meta: entry.epLabel,
                            badge: Providers.badge(entry.source),
                            progress: entry.fraction,
                            subline: "Còn \(WatchStore.fmtClock(entry.dur - entry.pos))")
                    }
                    .joeCardButton()
                    .focused($entryFocus, equals: "cw|" + entry.key)
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
    private var favWallRail: some View {
        if !movieFavorites.isEmpty {
            Rail(title: "♥ Yêu thích") {
                ForEach(movieFavorites) { entry in
                    Button { nav.movie = MovieRoute(
                        provider: entry.source, slug: entry.slug,
                        name: entry.title, poster: entry.poster,
                        year: entry.year) } label: {
                        PosterCard(
                            title: entry.title,
                            posterURL: entry.posterURL,
                            meta: entry.year,
                            badge: Providers.badge(entry.source))
                    }
                    .joeCardButton()
                    .focused($entryFocus, equals: "fav|" + entry.key)
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

    /// Wall routing: exact 6-column arithmetic; UP from the
    /// first wall row lands on the nearest owner rail above
    /// (Favourites, else Continue Watching) while no filter is
    /// active, else on the sort row's active chip (the facet
    /// row nearest the wall).
    private func wallMove(_ direction: MoveCommandDirection, from movie: Movie) {
        guard let idx = wallMovies.firstIndex(where: { $0.id == movie.id }) else { return }
        let columns = 6
        switch direction {
        case .left:
            if idx % columns > 0 { wallFocus = "wall|" + wallMovies[idx - 1].id }
        case .right:
            if idx + 1 < wallMovies.count, idx % columns < columns - 1 {
                wallFocus = "wall|" + wallMovies[idx + 1].id
            }
        case .up:
            if idx >= columns {
                wallFocus = "wall|" + wallMovies[idx - columns].id
            } else if !filter.filtersActive, let fav = movieFavorites.first {
                entryFocus = "fav|" + fav.key
            } else if !filter.filtersActive, let cw = movieProgress.first {
                entryFocus = "cw|" + cw.key
            } else {
                chipFocus = filter.sortChipID
            }
        case .down:
            if idx + columns < wallMovies.count {
                wallFocus = "wall|" + wallMovies[idx + columns].id
            } else if !filter.filtersActive,
                      let first = wallSections.first,
                      let firstMovie = first.movies.first {
                // UI-7 F-1: last grid row with the category
                // sections on screen below — hand focus to the
                // first section's first card instead of
                // consuming the press with no landing.
                entryFocus = "sec|" + first.scope + "|" + firstMovie.id
            }
        @unknown default:
            break
        }
    }
}
