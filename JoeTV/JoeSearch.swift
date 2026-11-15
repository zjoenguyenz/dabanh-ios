import SwiftUI

/// Merged search across KKPhim + Film4K + VSMOV + Tủ Phim: all
/// providers answer, results are listed together with provider
/// badges (the Android behaviour — a film carried by several
/// shows once per source, so the owner picks the source himself).
struct JoeSearchView: View {
    @EnvironmentObject private var nav: JoeNavigator
    @Environment(\.joeTheme) private var theme
    @State private var query = ""
    /// The term the on-screen results belong to (UI-6 defect
    /// D-19: D's results heading names it — the live field
    /// text can already have been edited past it).
    @State private var searchedQuery = ""
    @State private var results: [Movie] = []
    @State private var searching = false
    @State private var searched = false
    @State private var searchFailed = false
    @FocusState private var focusedMovie: Movie.ID?
    @FocusState private var retryFocused: Bool

    /// The top row's three focusable elements, in visual order.
    private enum TopFocus: Hashable { case field, search, back }
    @FocusState private var topFocus: TopFocus?

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            // v2.0.0 (UI-5): the field is light by design in
            // every theme (UI-1 law — the 1.9.2 white-on-dark
            // slab was the defect construction). A/F centre the
            // field row (maxW 1150, the render anatomy); D runs
            // it full width at the top of the wall.
            if theme.id == .posterWall {
                fieldRow
            } else {
                HStack(spacing: 0) {
                    Spacer()
                    fieldRow
                    Spacer()
                }
            }
            // CONVERGENCE (Team 7 D4, 2026-11-15): the
            // JoeSearchMoveTrap that wrapped this row (enabled:
            // topFocus != nil) is REMOVED — its flips rebuilt
            // the row subtree under the focus engine. The row's
            // routing is geometric now: LEFT/RIGHT walk the
            // three elements in visual order (the engine skips
            // the Tìm button while it is disabled — the skip
            // the old arithmetic walk hand-coded), UP reaches
            // the pills, DOWN reaches the first result / Retry.
            // §8: searching, failure and no-results are three
            // DIFFERENT surfaces. v1.8 merged the last two into
            // one line, so a dead network read as "no such film".
            if searching {
                ProgressView("Đang tìm…")
                    .font(.system(size: 29))
                    .foregroundStyle(theme.text)
                    .tint(theme.text)
            } else if searchFailed && results.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 44))
                        .foregroundStyle(.orange)
                    Text("Không tải được kết quả tìm kiếm.")
                        .font(.system(size: 29, weight: .semibold))
                        .foregroundStyle(theme.text)
                    Text("Các nguồn phim đều lỗi. Kiểm tra mạng rồi thử lại.")
                        .font(.system(size: 25))
                        .foregroundStyle(theme.meta)
                    Button { runSearch() } label: {
                        JoePrimaryLabel(title: "Thử lại")
                    }
                    .buttonStyle(.card)
                    .focused($retryFocused)
                    // (Its UP-to-field routing is geometric:
                    // the field is the nearest focusable above.
                    // The conditional trap that used to force
                    // it is removed — see the note at the top
                    // row.)
                }
            } else if searched && results.isEmpty {
                Text("Không tìm thấy phim nào.")
                    .font(.system(size: 29))
                    .foregroundStyle(theme.meta)
            }
            // UI-6 defect D-19: D's results carry the render's
            // heading naming the searched term.
            if theme.id == .posterWall && searched && !results.isEmpty {
                Text("Kết quả cho “\(searchedQuery)”")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(theme.text)
            }
            resultsArea
        }
        // Menu closes the search layer (convergence, Team 7):
        // the handler is unconditional and lives on the layer
        // itself, so it exists exactly while the layer does —
        // and while a movie detail is open above the search,
        // the detail's own handler is the nearer ancestor and
        // wins, preserving exactly-one-layer-per-press.
        .onExitCommand { nav.searchOpen = false }
        // 1.9.2 (Team 9 item 8): the query field is the
        // layer's declared initial focus — a static,
        // appearance-time .defaultFocus, the same construction
        // JoeMovieDetail's play button device-proves
        // (JoeMovieDetail.swift). The convergence round removed
        // the focus-hub consumer and assumed DOWN from the pills
        // would land here geometrically; after the grid→search
        // swap destroyed the tapped button's subtree, focus had
        // NO declared landing inside this layer at all, and on
        // device the owner could not get into search at all.
        // D4-safe: the declaration installs nothing in response
        // to focus state and no structure depends on it.
        .defaultFocus($topFocus, .field)
    }

    /// The query row: light field + Tìm + Quay lại. In A/F the
    /// row is centred by the body; its field is narrower so the
    /// whole row stays inside the renders' 1150 max width.
    private var fieldRow: some View {
        HStack(spacing: 18) {
            TextField("", text: $query,
                      prompt: Text("Tên phim…")
                        .foregroundColor(ThemeTokens.fieldPlaceholder))
                .textFieldStyle(.plain)
                .font(.system(size: ThemeTokens.fieldTextSize))
                .joeFieldChrome(focused: topFocus == .field)
                // UI-6 defects D-22 (31 pt field text, above)
                // and D-19: D's field runs the FULL width of
                // the wall (the render's block field); A/F keep
                // their centred 700.
                .frame(maxWidth: theme.id == .posterWall ? .infinity : 700)
                .focused($topFocus, equals: .field)
                .onSubmit { runSearch() }
            Button {
                runSearch()
            } label: {
                JoeSecondaryLabel(title: searching ? "Đang tìm…" : "Tìm")
            }
            .buttonStyle(.card)
            .focused($topFocus, equals: .search)
            .disabled(searching || query.trimmingCharacters(in: .whitespaces).isEmpty)
            Button {
                nav.searchOpen = false
            } label: {
                JoeSecondaryLabel(title: "⟵ Quay lại")
            }
            .buttonStyle(.card)
            .focused($topFocus, equals: .back)
        }
    }

    /// Results: design F groups them by source (one rail per
    /// provider, in failover priority order, with counts);
    /// designs A and D keep the 6-column grid (D's cards render
    /// in wall anatomy via the shared PosterCard).
    @ViewBuilder
    private var resultsArea: some View {
        if theme.id == .sourceBoard && !results.isEmpty {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 36) {
                    ForEach([Providers.KK, Providers.F4K, Providers.VS, Providers.TP],
                            id: \.self) { code in
                        let list = results.filter { $0.provider == code }
                        if !list.isEmpty {
                            Rail(title: "\(Providers.displayName(code)) — \(list.count) kết quả") {
                                ForEach(list) { movie in
                                    resultCard(movie, routed: false)
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 8)
            }
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                // Fixed 6 columns (was .adaptive(minimum: 240),
                // whose column count the code cannot enumerate) so
                // result focus routing is exact arithmetic — see
                // resultMove.
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 28),
                                         count: 6),
                          alignment: .leading, spacing: 40) {
                    ForEach(results) { movie in
                        resultCard(movie, routed: true)
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 4)
            }
        }
    }

    private func resultCard(_ movie: Movie, routed: Bool) -> some View {
        let card = Button { nav.movie = MovieRoute(
            provider: movie.provider, slug: movie.slug,
            name: movie.name, poster: movie.poster,
            year: movie.year) } label: {
            PosterCard(
                title: movie.name,
                posterURL: movie.posterURL,
                meta: movie.cardMeta,
                badge: Providers.badge(movie.provider),
                quality: movie.quality,
                focused: focusedMovie == "search|" + movie.id)
        }
        .buttonStyle(.card)
        .focused($focusedMovie, equals: "search|" + movie.id)
        // The arithmetic handler belongs to the GRID layout
        // (resultMove counts 6 columns); F's grouped rails route
        // geometrically. The attachment follows the LAYOUT (theme
        // + result set), never focus state.
        if routed {
            card.onMoveCommand { direction in
                resultMove(direction, from: movie)
            }
        } else {
            card
        }
    }

    /// Result-grid routing: the handler sits on each result, so
    /// it is active exactly while that result holds focus. Exact
    /// arithmetic over the fixed 6-column grid — UP from a
    /// first-row result returns focus to the query field,
    /// LEFT/RIGHT stop at row edges, DOWN past the last row is a
    /// defined no-op. (KEPT under convergence spec item 3: this
    /// is a per-element handler inside the search layer; its
    /// @FocusState writes are plain focus moves between stable
    /// elements — no view's structure depends on them any more.)
    private func resultMove(_ direction: MoveCommandDirection, from movie: Movie) {
        guard let idx = results.firstIndex(where: { $0.id == movie.id }) else { return }
        let columns = 6
        switch direction {
        case .left:
            if idx % columns > 0 { focusedMovie = "search|" + results[idx - 1].id }
        case .right:
            if idx + 1 < results.count, idx % columns < columns - 1 {
                focusedMovie = "search|" + results[idx + 1].id
            }
        case .up:
            if idx >= columns {
                focusedMovie = "search|" + results[idx - columns].id
            } else {
                topFocus = .field
            }
        case .down:
            if idx + columns < results.count {
                focusedMovie = "search|" + results[idx + columns].id
            }
        @unknown default:
            break
        }
    }

    private func runSearch() {
        let kw = query.trimmingCharacters(in: .whitespaces)
        guard !kw.isEmpty, !searching else { return }
        searching = true
        searchFailed = false
        searchedQuery = kw
        Task {
            async let kk = try? Providers.search(Providers.KK, keyword: kw)
            async let f4k = try? Providers.search(Providers.F4K, keyword: kw)
            async let vs = try? Providers.search(Providers.VS, keyword: kw)
            async let tp = try? Providers.search(Providers.TP, keyword: kw)
            let (a, b, c, d) = await (kk, f4k, vs, tp)
            results = (a ?? []) + (b ?? []) + (c ?? []) + (d ?? [])
            // Failure means every provider threw; a provider
            // that answered empty is a (partial) success.
            searchFailed = a == nil && b == nil && c == nil && d == nil
            searched = true
            searching = false
        }
    }
}

// CONVERGENCE RECORD (2026-11-15): JoeSearchMoveTrap — this
// file's copy of the conditional move-trap pattern — is
// DELETED; see the record at the end of JoeTVApp.swift. The
// top-row and Retry traps it powered are replaced by geometric
// focus movement; the per-result grid handler (resultMove)
// stays, as it was always per-element and unconditional.
