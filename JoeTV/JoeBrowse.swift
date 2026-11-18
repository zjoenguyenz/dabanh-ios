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
    // v2.0.8 (Phase 1): no move handlers anywhere in the bar
    // and no DOWN landing callback — every chip is a plain
    // button in the bar's focus section and the engine's
    // geometric search moves focus between rows, out the
    // top, and into the grid/shelves below, from any side.
    // The v2.0.6 declared row chain (chipRowMove) and the
    // sort row's onSortChipDown landing are deleted: an
    // attached .onMoveCommand owned EVERY direction and
    // turned undeclared ones into no-ops (audit T-C3/T-C4).

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
                         selected: filter.year == .all) {
                        filter.year = .all
                    }
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
                         selected: filter.country == nil) {
                        filter.country = nil
                    }
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
                         selected: filter.lang == nil) {
                        filter.lang = nil
                    }
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
                         selected: filter.sort == order) {
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
                     selected: false) {
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
                // Design chip-row gap: 14 (the drawings' chip
                // rows — detail sources, search facets).
                HStack(spacing: 14) { content() }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 6)
            }
        }
    }

    private func chip(id: String, title: String, selected: Bool,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            JoeChipLabel(title: title, selected: selected)
        }
        .joeCardButton()
        .focused(chipFocus, equals: id)
    }

    // v2.0.8 (Phase 1): the bar's declared routing record
    // (sortRowChipIDs / FilterRow / filterRows /
    // rowMoveHandler / chipRowMove) is DELETED with the
    // .onMoveCommand it fed. The facet rows are sibling
    // horizontal scrolls inside this one focus section; the
    // engine moves between rows geometrically, and the
    // surfaces below the bar are reached the same way.
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
    @FocusState private var closeFocused: Bool

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
            // v2.0.8 (Phase 5): the header row carries the
            // owner's close control — one focusable "Đóng"
            // button that folds this expanded browse back to
            // the collapsed single "Tất cả phim" box on the
            // home (nav.browseOpen = false — the same state
            // the Menu handlers clear). It is a plain button
            // in its own focus section, reachable from the bar
            // and grid by the engine's geometry. Menu/Back
            // from this layer already returns to the
            // collapsed box first: JoePhimHome's own exit
            // handler closes browse before the exit
            // confirmation, and the root shell's handler
            // closes browse before leaving the Phim section
            // (verified in JoePhimHome.swift / JoeTVApp.swift,
            // read-only for this worker).
            HStack(alignment: .center, spacing: 28) {
                Text("Tất cả phim")
                    .font(.system(size: 44, weight: .heavy))
                    .foregroundStyle(theme.text)
                Spacer()
                Button {
                    nav.browseOpen = false
                } label: {
                    JoeSecondaryLabel(title: "Đóng", systemImage: "xmark")
                }
                .joeCardButton()
                .focused($closeFocused)
            }
            .focusSection()
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 26) {
                    JoeFilterBar(filter: $filter,
                                 years: JoeBrowseFilter.yearBuckets(for: phim.merged),
                                 hasBefore2020: JoeBrowseFilter.hasBefore2020(phim.merged),
                                 showYear: JoeBrowseFilter.facetVisibility(for: phim.merged).year,
                                 showCountry: JoeBrowseFilter.facetVisibility(for: phim.merged).country,
                                 showType: JoeBrowseFilter.facetVisibility(for: phim.merged).type,
                                 showLang: JoeBrowseFilter.facetVisibility(for: phim.merged).lang,
                                 chipFocus: $chipFocus)
                        // v2.0.5 (N1, pair e): the bar is a
                        // declared focus region, the grid
                        // below it another. v2.0.8 (Phase 1):
                        // movement between them is the engine's
                        // geometric search — the declared pair
                        // (chipRowMove DOWN / gridMove UP) is
                        // deleted with its .onMoveCommand, so
                        // the grid is enterable from any side
                        // and UP leaves from any column.
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
                            }
                        }
                        .padding(.vertical, 8)
                        // Design D's wall ring is an OUTSET band
                        // around the art (6 pt): the grid's edge
                        // clearance grows past it under D so the
                        // outer columns' rings are never clipped
                        // by the scroll frame.
                        .padding(.horizontal, theme.id == .posterWall ? 8 : 4)
                        .focusSection()
                    }
                }
            }
            // v2.0.16 (owner's 2026-11-17 sweep): this
            // container CLIPS at its frame — the
            // .scrollClipDisabled() here was the same
            // construction the v2.0.12 search fix convicted:
            // the "Tất cả phim" header + Đóng button are
            // pinned siblings directly above this ScrollView,
            // and unclipped grid content scrolling past the
            // frame's top edge painted over them. The grid's
            // own clearances (vertical 8, horizontal 8 under
            // D — past the 6 pt outset ring) are unchanged,
            // so a focused card's ring keeps its room inside
            // the frame.
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

    // v2.0.8 (Phase 1): gridMove is DELETED — grid cards
    // are plain buttons in the grid's focus section; the
    // engine moves within the grid geometrically and out of
    // it (UP to the filter bar, from any column) the same
    // way. No coded no-op directions remain in this view.
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
    /// FIX4 (fix 7): the wall observes the follow store so
    /// the "📌 Đang theo dõi" shelf below appears the moment
    /// anything is followed (and empties when the last
    /// follow goes) — the same observation JoePhimHome's
    /// rail home carries.
    @ObservedObject private var followStore = FollowStore.shared
    @Environment(\.joeTheme) private var theme
    @State private var filter = JoeBrowseFilter()
    /// D-20: same "a load has been attempted" gate as the rail
    /// home, so the state surfaces cannot flash at cold entry.
    @State private var attempted = false
    @FocusState private var chipFocus: String?
    @FocusState private var wallFocus: Movie.ID?
    @FocusState private var entryFocus: String?
    @FocusState private var retryFocused: Bool
    /// v2.0.9: the header close control's focus identity
    /// (see the header note in `body`).
    @FocusState private var closeFocused: Bool
    /// v2.0.11: the home mode's "Tất cả phim" entry — the
    /// landing Đóng writes when the panel folds (see the
    /// header note in `body`).
    @FocusState private var openerFocused: Bool

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
        // v2.0.9 (owner defect #1, theme D only): the wall IS
        // design D's "Tất cả phim" surface — design-D/grid.html
        // carries that title over this same wall — but the
        // v2.0.8 Phase-5 close control was built only into
        // JoeBrowseView's header, a layer theme D never
        // presents (every browseOpen entry lives in the A/F
        // rail home), so D's opened all-movies surface had no
        // "Đóng" at all (the owner's photo: this wall, no
        // header, no close). The header row below mirrors the
        // browse header's construction — the surface title
        // plus the shared JoeSecondaryLabel close button in
        // its own focus section, fixed above the scroll — with
        // the title at design D's own sheet value (.wall-title:
        // 40 pt, weight 800).
        //
        // v2.0.11 (owner, verbatim: "Không tắt được bảng tất
        // cả các phim" — his clip: Đóng takes focus, the wall
        // does not close): the v2.0.9 header wired Đóng to a
        // FILTER RESET only — it never touched the state that
        // presents/dismisses an all-movies surface, because in
        // theme D no such state existed: this view was the
        // section's face unconditionally and every browseOpen
        // entry lived in the A/F rail home, so the real panel
        // (JoeBrowseView, dismissed by nav.browseOpen) was
        // unreachable in D and this home wore the panel's
        // header instead. The wall now carries the same
        // two-state anatomy as every other theme, keyed on
        // the SAME state: nav.browseOpen == false is the D
        // home (design-D/home.html: the entry box + shelves);
        // == true is the "Tất cả phim" panel (design-D/
        // grid.html: header + filter + merged grid), and
        // Đóng clears nav.browseOpen — the exact dismissal
        // JoeBrowseView's Đóng performs (JoeBrowse.swift's
        // browse header) and the Menu handlers clear first
        // (JoePhimHome / JoeRootView). JoePhimHome's Group
        // presents this view ahead of the browse branch so
        // the wall stays mounted and switches modes itself;
        // the scroll surface is re-ided on the state so each
        // mode starts at the top, like the A/F layer swap.
        // The filter reset the old action performed now lives
        // in the browseOpen observer below, so EVERY close
        // path (Đóng, Menu, section change) resets it — the
        // per-open semantics the browse layer gets from being
        // recreated (REWORK-LOOP state note).
        VStack(alignment: .leading, spacing: 26) {
            if nav.browseOpen {
                HStack(alignment: .center, spacing: 28) {
                    Text("Tất cả phim")
                        .font(.system(size: 40, weight: .heavy))
                        .foregroundStyle(theme.text)
                    Spacer()
                    Button {
                        nav.browseOpen = false
                        chipFocus = nil
                        openerFocused = true
                    } label: {
                        JoeSecondaryLabel(title: "Đóng", systemImage: "xmark")
                    }
                    .joeCardButton()
                    .focused($closeFocused)
                }
                .focusSection()
            }
            ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 36) {
                if nav.browseOpen {
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
                        // shared Rail, the grid below). v2.0.8
                        // (Phase 1): movement between the regions
                        // is the engine's geometric search — the
                        // bar's declared DOWN landing below it is
                        // deleted with the bar's handlers.
                        .focusSection()
                    if !filter.filtersActive {
                        cwWallRail
                        favWallRail
                        followWallRail
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
                            }
                        }
                        // The wall grid is a D-only surface: its
                        // outset art rings (6 pt) need the wider
                        // edge clearance (see JoeBrowseView).
                        .padding(.horizontal, 8)
                        .focusSection()
                    }
                } else {
                    // v2.0.11: the D home mode — the single
                    // "Tất cả phim" entry box (the F slim-header
                    // entry's shared label) over the shelves.
                    // Opening it raises the panel above; Đóng
                    // (or Menu) folds back to exactly this.
                    Button {
                        nav.browseOpen = true
                    } label: {
                        JoeSecondaryLabel(title: "Tất cả phim",
                                          systemImage: "square.grid.2x2")
                    }
                    .joeCardButton()
                    .focused($openerFocused)
                    if wallMovies.isEmpty {
                        wallStateSurface
                    }
                    cwWallRail
                    favWallRail
                    followWallRail
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
        // v2.0.16 (owner's 2026-11-17 sweep): this container
        // CLIPS at its frame — no .scrollClipDisabled(). In
        // panel mode (browseOpen) the "Tất cả phim" header is
        // a pinned sibling directly above this ScrollView,
        // and the unclip let the panel grid paint over it
        // while scrolling — the v2.0.12 search construction,
        // third conviction. Design D's outset wall ring keeps
        // its room at rest: the wall grid carries the wider
        // horizontal clearance (8 pt, past the 6 pt ring),
        // and vertically the stack's 36 pt spacing holds the
        // grid's first row a ring's width and more inside
        // the frame; the shelves' rails keep their own
        // bounded horizontal escape (JoeTheme.Rail).
        // v2.0.11: the scroll surface is re-ided on the panel
        // state, so opening or folding the "Tất cả phim" panel
        // rebuilds it at the top — the same fresh landing the
        // A/F browse layer gets from being swapped in and out.
        .id(nav.browseOpen)
        } // v2.0.9: closes the header VStack opened in `body`.
        // v2.0.5 (N1/N2): the wall home's DECLARED top element
        // — the filter bar's first chip, the landing the pill
        // row's DOWN resigns focus to while the Poster Wall
        // home is the Phim section's face. (v2.0.11: the chip
        // exists only in the panel mode; in the home mode the
        // declaration matches nothing and focus falls back to
        // the first focusable element — the "Tất cả phim"
        // entry, which is also where Đóng's explicit write
        // lands on a fold.)
        .defaultFocus($chipFocus, "genre:all")
        // v2.0.11: every panel close (Đóng, Menu, section
        // change) resets the filter — the per-open semantics
        // the A/F browse layer gets from being recreated per
        // open (REWORK-LOOP state note). This observer owns
        // the reset so no close path can skip it.
        .onChange(of: nav.browseOpen) { _, isOpen in
            if !isOpen { filter = JoeBrowseFilter() }
        }
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
            // v2.0.6 (leader hardening, error-8b doctrine):
            // retryFocused was bound but never written — this
            // surface had NO declared landing. Declared now,
            // like the player slate (v2.0.5) and the detail
            // load-failure surface.
            .defaultFocus($retryFocused, true)
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
                            quality: movie.quality,
                            form: .rail)
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
                            subline: "Còn \(WatchStore.fmtClock(entry.dur - entry.pos))",
                            form: .rail)
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
                            badge: Providers.badge(entry.source),
                            form: .rail)
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

    /// FIX4 (fix 7): the third owner shelf — "📌 Đang theo
    /// dõi" (idea 7a). It shipped in 2.0.25 for the A/F/Ultra
    /// rail home only: this wall builds its shelves from the
    /// raw joeRailSpecs list, which carries no Following
    /// entry, so an owner on design D who pressed Theo dõi
    /// on a detail page found the rail NOWHERE (his 2.0.27
    /// finding). The shelf takes its place beside the other
    /// two owner shelves (Continue Watching / Favourites —
    /// the wall's own grouping for owner data, above the
    /// catalogue), in their exact card construction: tap
    /// clears the new-episode badge (markSeen, the A/F
    /// rail's rule) and opens the title's detail; the meta
    /// line carries the same episode text the A/F rail's
    /// followedMovies mapping builds.
    @ViewBuilder
    private var followWallRail: some View {
        if !followStore.followed.isEmpty {
            Rail(title: "📌 Đang theo dõi") {
                ForEach(followStore.followed) { f in
                    Button {
                        FollowStore.shared.markSeen(provider: f.provider,
                                                    slug: f.slug)
                        nav.movie = MovieRoute(
                            provider: f.provider, slug: f.slug,
                            name: f.title, poster: f.poster, year: "")
                    } label: {
                        PosterCard(
                            title: f.title,
                            posterURL: f.poster.isEmpty
                                ? nil : URL(string: f.poster),
                            meta: f.hasNewEpisodes
                                ? "Tập mới · \(f.latestEpisodes) tập"
                                : (f.latestEpisodes > 0
                                    ? "\(f.latestEpisodes) tập" : ""),
                            badge: Providers.badge(f.provider),
                            form: .rail)
                    }
                    .joeCardButton()
                    .focused($entryFocus, equals: "fol|" + f.id)
                }
            }
        }
    }

    // v2.0.8 (Phase 1): wallMove is DELETED — wall cards
    // are plain buttons in the grid's focus section; the
    // engine moves within the grid geometrically and out of
    // it (UP to the owner rails / filter bar, DOWN to the
    // category shelves) the same way. No coded no-op
    // directions remain in this view.
}
