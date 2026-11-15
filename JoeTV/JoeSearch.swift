import SwiftUI

/// Merged search across KKPhim + Film4K + VSMOV + Tủ Phim: all
/// providers answer, results are listed together with provider
/// badges (the Android behaviour — a film carried by several
/// shows once per source, so the owner picks the source himself).
struct JoeSearchView: View {
    @EnvironmentObject private var nav: JoeNavigator
    @State private var query = ""
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
            HStack(spacing: 18) {
                TextField("Tên phim…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 29))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                    .background(RoundedRectangle(cornerRadius: 14)
                        .fill(Color.white.opacity(0.07)))
                    .overlay(RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(topFocus == .field ? joeFocusViolet : Color.clear,
                                      lineWidth: 4))
                    .frame(width: 900)
                    .focused($topFocus, equals: .field)
                    .focusEffectDisabled(true)
                    .onSubmit { runSearch() }
                Button {
                    runSearch()
                } label: {
                    Text(searching ? "Đang tìm…" : "Tìm")
                        .font(.system(size: 29, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 30)
                        .padding(.vertical, 16)
                        .background(Capsule().fill(topFocus == .search
                                                   ? JoeTheme.accentViolet
                                                   : JoeTheme.surface))
                        .overlay(Capsule().strokeBorder(topFocus == .search ? joeFocusViolet : Color.clear,
                                                        lineWidth: 4))
                        .scaleEffect(topFocus == .search ? 1.05 : 1.0)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled(true)
                .focused($topFocus, equals: .search)
                .disabled(searching || query.trimmingCharacters(in: .whitespaces).isEmpty)
                Button {
                    nav.searchOpen = false
                } label: {
                    Text("⟵ Quay lại")
                        .font(.system(size: 29, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 30)
                        .padding(.vertical, 16)
                        .background(Capsule().fill(topFocus == .back
                                                   ? JoeTheme.accentViolet
                                                   : JoeTheme.surface))
                        .overlay(Capsule().strokeBorder(topFocus == .back ? joeFocusViolet : Color.clear,
                                                        lineWidth: 4))
                        .scaleEffect(topFocus == .back ? 1.05 : 1.0)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled(true)
                .focused($topFocus, equals: .back)
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
                    .foregroundStyle(.white)
                    .tint(.white)
            } else if searchFailed && results.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 44))
                        .foregroundStyle(.orange)
                    Text("Không tải được kết quả tìm kiếm.")
                        .font(.system(size: 29, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Các nguồn phim đều lỗi. Kiểm tra mạng rồi thử lại.")
                        .font(.system(size: 25))
                        .foregroundStyle(.white.opacity(0.7))
                    Button { runSearch() } label: {
                        Text("Thử lại")
                            .font(.system(size: 29, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 36)
                            .padding(.vertical, 16)
                            .background(Capsule().fill(JoeTheme.accentViolet))
                            .overlay(JoeFocusRing(shape: Capsule()))
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled(true)
                    .focused($retryFocused)
                    .scaleEffect(retryFocused ? 1.05 : 1.0)
                    // (Its UP-to-field routing is geometric:
                    // the field is the nearest focusable above.
                    // The conditional trap that used to force
                    // it is removed — see the note at the top
                    // row.)
                }
            } else if searched && results.isEmpty {
                Text("Không tìm thấy phim nào.")
                    .font(.system(size: 29))
                    .foregroundStyle(.white.opacity(0.7))
            }
            ScrollView(.vertical, showsIndicators: false) {
                // Fixed 6 columns (was .adaptive(minimum: 240),
                // whose column count the code cannot enumerate) so
                // result focus routing is exact arithmetic — see
                // resultMove. PosterCard art is 240 wide (§7.2),
                // so the flexible columns render as before.
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 28),
                                         count: 6),
                          alignment: .leading, spacing: 40) {
                    ForEach(results) { movie in
                        Button { nav.movie = MovieRoute(
                            provider: movie.provider, slug: movie.slug,
                            name: movie.name, poster: movie.poster,
                            year: movie.year) } label: {
                            JoeTheme.PosterCard(
                                title: movie.name,
                                posterURL: movie.posterURL,
                                meta: movie.cardMeta,
                                badge: Providers.badge(movie.provider),
                                focused: focusedMovie == "search|" + movie.id)
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled(true)
                        .focused($focusedMovie, equals: "search|" + movie.id)
                        .onMoveCommand { direction in
                            resultMove(direction, from: movie)
                        }
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 4)
            }
        }
        // Menu closes the search layer (convergence, Team 7):
        // the handler is unconditional and lives on the layer
        // itself, so it exists exactly while the layer does —
        // and while a movie detail is open above the search,
        // the detail's own handler is the nearer ancestor and
        // wins, preserving exactly-one-layer-per-press.
        .onExitCommand { nav.searchOpen = false }
        // CONVERGENCE (spec item 3): the focus-hub consumer
        // (onChange of nav.focusNonce → topFocus = .field) is
        // REMOVED — DOWN from the pills lands on the query
        // field geometrically.
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

/// v1.5 focus outline colour (lighter violet) — the style law's
/// focus stroke on every focusable element in this file.
private let joeFocusViolet = Color(red: 0.72, green: 0.58, blue: 1.0)

// CONVERGENCE RECORD (2026-11-15): JoeSearchMoveTrap — this
// file's copy of the conditional move-trap pattern — is
// DELETED; see the record at the end of JoeTVApp.swift. The
// top-row and Retry traps it powered are replaced by geometric
// focus movement; the per-result grid handler (resultMove)
// stays, as it was always per-element and unconditional.
