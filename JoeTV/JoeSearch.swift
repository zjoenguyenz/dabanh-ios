import SwiftUI

/// Merged search across KKPhim + Film4K + VSMOV: all providers
/// answer, results are listed together with provider badges (the
/// Android behaviour — a film carried by several shows once per
/// source, so the owner picks the source himself).
struct JoeSearchView: View {
    @EnvironmentObject private var nav: JoeNavigator
    @State private var query = ""
    @State private var results: [Movie] = []
    @State private var searching = false
    @State private var searched = false
    @FocusState private var focusedMovie: Movie.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(spacing: 18) {
                TextField("Tên phim…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 28))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                    .background(RoundedRectangle(cornerRadius: 14)
                        .fill(Color.white.opacity(0.10)))
                    .frame(width: 900)
                    .onSubmit { runSearch() }
                Button {
                    runSearch()
                } label: {
                    Text(searching ? "Đang tìm…" : "Tìm")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 30)
                        .padding(.vertical, 16)
                        .background(Capsule().fill(JoeTheme.accentViolet.opacity(0.45)))
                        .overlay(JoeFocusRing(shape: Capsule()))
                }
                .buttonStyle(.card)
                .disabled(searching || query.trimmingCharacters(in: .whitespaces).isEmpty)
                Button {
                    nav.searchOpen = false
                } label: {
                    Text("⟵ Quay lại")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 30)
                        .padding(.vertical, 16)
                        .background(Capsule().fill(JoeTheme.accentViolet.opacity(0.45)))
                        .overlay(JoeFocusRing(shape: Capsule()))
                }
                .buttonStyle(.card)
            }
            if searched && results.isEmpty && !searching {
                Text("Không thấy phim nào với từ khoá này.")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.6))
            }
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 26)],
                          alignment: .leading, spacing: 30) {
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
                                focused: focusedMovie == movie.id)
                        }
                        .buttonStyle(.card)
                        .focused($focusedMovie, equals: movie.id)
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 4)
            }
        }
    }

    private func runSearch() {
        let kw = query.trimmingCharacters(in: .whitespaces)
        guard !kw.isEmpty, !searching else { return }
        searching = true
        Task {
            async let kk = try? Providers.search(Providers.KK, keyword: kw)
            async let f4k = try? Providers.search(Providers.F4K, keyword: kw)
            async let vs = try? Providers.search(Providers.VS, keyword: kw)
            async let tp = try? Providers.search(Providers.TP, keyword: kw)
            let (a, b, c, d) = await (kk, f4k, vs, tp)
            results = (a ?? []) + (b ?? []) + (c ?? []) + (d ?? [])
            searched = true
            searching = false
        }
    }
}
