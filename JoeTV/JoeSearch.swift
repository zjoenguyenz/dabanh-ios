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

    /// The top row's three focusable elements, in visual order —
    /// the conditional move trap routes among them explicitly.
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
            .modifier(JoeSearchMoveTrap(enabled: topFocus != nil) { direction in
                topMove(direction)
            })
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
                    .modifier(JoeSearchMoveTrap(enabled: retryFocused) { direction in
                        if direction == .up { topFocus = .field }
                    })
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
        .onChange(of: nav.focusNonce) { _, _ in
            // Hub entry (v1.5): pill DOWN while search is open
            // lands focus on the query field.
            if nav.focusTarget == .sectionTop {
                topFocus = .field
            }
        }
    }

    /// The Tìm button's disabled condition, mirrored so LEFT/RIGHT
    /// routing can skip it while it cannot take focus.
    private var searchEnabled: Bool {
        !searching && !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Top-row routing: the trap is enabled ONLY while a top-row
    /// element holds focus, and all four directions are defined —
    /// UP escapes to the shell pills through the hub (this closes
    /// the v1.4 "LEFT from search cannot reach Cài đặt" class of
    /// failure by construction), LEFT/RIGHT walk field ↔ Tìm ↔
    /// Quay lại in visual order (skipping Tìm while disabled,
    /// no-op at the ends), DOWN drops to the first result when
    /// results exist, else no-op.
    private func topMove(_ direction: MoveCommandDirection) {
        switch direction {
        case .up:
            nav.requestFocus(.pills)
        case .down:
            if let first = results.first {
                focusedMovie = "search|" + first.id
            } else if searchFailed {
                retryFocused = true
            }
        case .left:
            switch topFocus {
            case .search: topFocus = .field
            case .back: topFocus = searchEnabled ? .search : .field
            default: break
            }
        case .right:
            switch topFocus {
            case .field: topFocus = searchEnabled ? .search : .back
            case .search: topFocus = .back
            default: break
            }
        @unknown default:
            break
        }
    }

    /// Result-grid routing: the handler sits on each result, so
    /// it is active exactly while that result holds focus. Exact
    /// arithmetic over the fixed 6-column grid — UP from a
    /// first-row result returns focus to the query field,
    /// LEFT/RIGHT stop at row edges, DOWN past the last row is a
    /// defined no-op.
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

/// Local copy of the shell's conditional move-trap pattern (the
/// shell's JoeMoveTrap is file-private to JoeTVApp.swift): the
/// move handler exists ONLY while `enabled`, and while enabled
/// its handler gives all four directions a defined outcome.
private struct JoeSearchMoveTrap: ViewModifier {
    let enabled: Bool
    let action: (MoveCommandDirection) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.onMoveCommand(perform: action)
        } else {
            content
        }
    }
}
