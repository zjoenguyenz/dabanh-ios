import SwiftUI

/// Merged search across KKPhim + Film4K + VSMOV + Tủ Phim: all
/// providers answer, results are listed together with provider
/// badges (the Android behaviour — a film carried by several
/// shows once per source, so the owner picks the source himself).
struct JoeSearchView: View {
    @EnvironmentObject private var nav: JoeNavigator
    @EnvironmentObject private var phim: PhimStore
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
    // v2.0.1 search-round state (Android FIX2/FIX3 parity):
    // the two render pools, the round generation (a new press
    // supersedes any in-flight round), and the settle
    // bookkeeping. `searching` is the VISIBLE settle (soft
    // deadline); `roundActive` runs to the hard settle.
    @State private var localPool: [Movie] = []
    @State private var serverPool: [Movie] = []
    @State private var roundID = 0
    @State private var roundActive = false
    @State private var branchesDone = 0
    @State private var branchesOK = 0
    @State private var branchesFailed = 0
    @State private var firstPaintLogged = false
    @State private var pressStart = Date()
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
            // v2.0.1: while a round is active with an empty
            // grid the surface stays "Đang tìm…" even past the
            // soft deadline (nothing found YET is not a
            // no-match); with results on screen the spinner
            // rides above them until the visible settle.
            if roundActive && results.isEmpty && !searchFailed {
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
                    .joeCardButton()
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
            } else if searching {
                // Results are already on screen; branches are
                // still merging (the visible settle — soft
                // deadline or last branch — ends this line).
                ProgressView("Đang tìm…")
                    .font(.system(size: 29))
                    .foregroundStyle(theme.text)
                    .tint(theme.text)
            }
            // UI-6 defect D-19: the results carry the render's
            // heading naming the searched term — design D's
            // search drawing has it, and design A's search
            // drawing has the same heading ("Kết quả cho "…"",
            // rail-title 34 bold), so A takes it too. F keeps
            // its per-source grouped rails without it.
            if theme.id != .sourceBoard && searched && !results.isEmpty {
                Text("Kết quả cho “\(searchedQuery)”")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(theme.text)
            }
            // v2.0.5 (N1, pair k): the results area is a
            // declared focus region, paired with the query
            // row's own section above.
            resultsArea
                .focusSection()
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
            .joeCardButton()
            .focused($topFocus, equals: .search)
            .disabled(searching || query.trimmingCharacters(in: .whitespaces).isEmpty)
            Button {
                nav.searchOpen = false
            } label: {
                JoeSecondaryLabel(title: "⟵ Quay lại")
            }
            .joeCardButton()
            .focused($topFocus, equals: .back)
        }
        // v2.0.5 (N1, pair k): the query row is a declared
        // focus region; the results area is another (see the
        // body's resultsArea), and resultMove's UP already
        // lands back on this row's field.
        .focusSection()
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
                // Column gap = the theme's rail gap (design
                // card pitch: A 26, D 24, F 28).
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: theme.railGap),
                                         count: 6),
                          alignment: .leading, spacing: 40) {
                    ForEach(results) { movie in
                        resultCard(movie, routed: true)
                    }
                }
                .padding(.vertical, 8)
                // Design D's wall ring is an OUTSET band around
                // the art (6 pt): the grid's edge clearance
                // grows past it under D so the outer columns'
                // rings are never clipped by the scroll frame.
                .padding(.horizontal, theme.id == .posterWall ? 8 : 4)
            }
        }
    }

    @ViewBuilder
    private func resultCard(_ movie: Movie, routed: Bool) -> some View {
        let card = Button { nav.movie = MovieRoute(
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

    // MARK: - Search round (v2.0.1 — Android FIX2 + FIX3 parity)
    //
    // One press runs ONE round:
    //  1. LOCAL FIRST: the title pool (everything already
    //     downloaded — home rails, the browse dataset, genre /
    //     country lists, all resident in PhimStore — plus every
    //     earlier round's branch results) answers synchronously
    //     at the press. The search never waits on the store's
    //     load: an unloaded store simply yields fewer local hits
    //     and the branches carry the round.
    //  2. The four provider branches fan out; each merges into
    //     the server pool and re-renders THE MOMENT IT LANDS
    //     (progressive merge — the pre-fix round rendered
    //     nothing until the slowest branch answered).
    //  3. Two settles: the VISIBLE settle at the 2.5 s soft
    //     deadline (or when the last branch lands, if sooner)
    //     flips `searching` off; branches keep merging until
    //     the 15 s hard budget, where stragglers are cut and
    //     counted failed.
    //  4. Bookkeeping is honest (the FIX2 rule): only a round
    //     with ZERO failed branches is snapshotted for instant
    //     replay; an all-failed round is never cached — a
    //     re-press re-runs it — and shows the failure surface,
    //     never the no-match line.
    // JOESEARCH lines ride the house signpost log (LoadSignpost)
    // with per-branch timings and the round's first paint.

    private func runSearch() {
        let kw = query.trimmingCharacters(in: .whitespaces)
        guard !kw.isEmpty else { return }
        searchedQuery = kw
        searchFailed = false

        // Snapshot restore: a clean earlier round for this
        // name replays instantly with zero network. (Facet
        // state is not part of the key — on tvOS the facets
        // live in the browse layer, where they re-apply at
        // render over the store, so there is nothing to key.)
        if let snap = JoeSearchSession.shared.snapshot(for: kw) {
            roundID += 1
            roundActive = false
            searching = false
            searched = true
            results = Self.renderPool(local: snap.local,
                                      server: snap.server, query: kw)
            LoadSignpost.log("JOESEARCH snapshot query=\"\(kw)\" results=\(results.count)")
            return
        }

        roundID += 1
        let gen = roundID
        roundActive = true
        searching = true
        searched = false
        branchesDone = 0
        branchesOK = 0
        branchesFailed = 0
        firstPaintLogged = false
        pressStart = Date()

        // 1. Local first.
        JoeSearchSession.shared.feed(storeMovies())
        let hits = JoeSearchSession.shared.localHits(for: kw)
        localPool = hits
        serverPool = []
        results = Self.renderPool(local: hits, server: [], query: kw)
        if !hits.isEmpty { logFirstPaint(localHits: hits.count) }

        // 2. Branch fan-out with progressive merge.
        for code in Providers.priority {
            Task {
                let t0 = Date()
                let res = try? await Providers.search(code, keyword: kw)
                guard gen == roundID, roundActive else { return }
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                branchesDone += 1
                if let res {
                    branchesOK += 1
                    JoeSearchSession.shared.feed(res)
                    serverPool = Self.mergePool(serverPool, res)
                    LoadSignpost.log("JOESEARCH provider=\(code) ms=\(ms) results=\(res.count) timeout=0 error=0 query=\"\(kw)\"")
                } else {
                    branchesFailed += 1
                    LoadSignpost.log("JOESEARCH provider=\(code) ms=\(ms) results=0 timeout=0 error=1 query=\"\(kw)\"")
                }
                results = Self.renderPool(local: localPool,
                                          server: serverPool, query: kw)
                if !results.isEmpty { logFirstPaint(localHits: hits.count) }
                if branchesDone == Providers.priority.count {
                    hardSettle(gen: gen, kw: kw)
                }
            }
        }

        // 3a. Soft deadline: the visible settle.
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard gen == roundID, roundActive, searching else { return }
            searching = false
            LoadSignpost.log("JOESEARCH soft_settle ms=2500 query=\"\(kw)\" results=\(results.count)")
        }

        // 3b. Hard budget: cut the stragglers, settle with
        // what the round has.
        Task {
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard gen == roundID, roundActive else { return }
            let missing = Providers.priority.count - branchesDone
            if missing > 0 {
                branchesFailed += missing
                LoadSignpost.log("JOESEARCH hard_budget missing=\(missing) query=\"\(kw)\"")
            }
            hardSettle(gen: gen, kw: kw)
        }
    }

    /// The hard settle: failure honesty + the snapshot rule.
    private func hardSettle(gen: Int, kw: String) {
        guard gen == roundID, roundActive else { return }
        roundActive = false
        searching = false
        searched = true
        // Failure means every provider threw (or was cut by
        // the hard budget); a provider that answered empty is
        // a (partial) success. The failure surface itself only
        // shows when the grid is empty (body rule) — local
        // hits stand even under an all-failed round.
        if branchesFailed >= Providers.priority.count {
            searchFailed = true
        }
        if branchesFailed == 0 {
            JoeSearchSession.shared.storeSnapshot(
                name: kw, local: localPool, server: serverPool)
        }
        let totalMs = Int(Date().timeIntervalSince(pressStart) * 1000)
        LoadSignpost.log("JOESEARCH total ms=\(totalMs) ok=\(branchesOK) failed=\(branchesFailed) query=\"\(kw)\"")
    }

    private func logFirstPaint(localHits: Int) {
        guard !firstPaintLogged else { return }
        firstPaintLogged = true
        let ms = Int(Date().timeIntervalSince(pressStart) * 1000)
        LoadSignpost.log("JOESEARCH first_paint ms=\(ms) local_hits=\(localHits) query=\"\(searchedQuery)\"")
    }

    /// Everything the Phim store has already downloaded: the
    /// merged newest rails, the type lists, chiếu rạp, the
    /// Vietnam block, and every genre / country list. (The
    /// merged rail already covers the four newest rails;
    /// feeding duplicates is harmless — the pool dedupes.)
    private func storeMovies() -> [Movie] {
        var all: [Movie] = []
        all += phim.merged
        all += phim.kkSeries + phim.kkMovies + phim.kkAnime
        all += phim.f4kNew + phim.f4kMovies
        all += phim.vsNew + phim.vsSeries
        all += phim.tpNew + phim.tpMovies + phim.tpSeries
        all += phim.chieuRap + phim.vietnamAll
        for list in phim.genreLists.values { all += list }
        for list in phim.countryLists.values { all += list }
        return all
    }

    /// Append `extra` to `base`, dropping later duplicates of
    /// an already-kept film (provider|slug, first copy wins —
    /// store copies carry the richer facet fields).
    private static func mergePool(_ base: [Movie], _ extra: [Movie]) -> [Movie] {
        var seen = Set(base.map { $0.id })
        var out = base
        for m in extra where !m.slug.isEmpty && !seen.contains(m.id) {
            seen.insert(m.id)
            out.append(m)
        }
        return out
    }

    /// The render pool: local hits first, then the server pool
    /// grouped in provider priority order (the shipped grid
    /// order), with the ONE sanctioned reordering — the
    /// exact-match tier: a film whose normalized name OR
    /// origin name EQUALS the query leads, in arrival order.
    /// Every other card keeps its pool order and never moves
    /// within its tier, so a branch landing late only appends
    /// (or upgrades its own exact match into the front block).
    private static func renderPool(local: [Movie], server: [Movie],
                                   query: String) -> [Movie] {
        var merged = mergePool([], local)
        for code in Providers.priority {
            merged = mergePool(merged, server.filter { $0.provider == code })
        }
        merged = mergePool(merged, server)
        let q = Providers.normalizeTitle(query)
        let exact = merged.filter {
            Providers.normalizeTitle($0.name) == q
                || Providers.normalizeTitle($0.originName) == q
        }
        guard !exact.isEmpty else { return merged }
        let exactIDs = Set(exact.map { $0.id })
        return exact + merged.filter { !exactIDs.contains($0.id) }
    }
}

/// Session search memory (v2.0.1 — the Android TitleIndex +
/// query cache, tvOS form): the local title pool and the
/// clean-round snapshots. Lock-guarded static state (the
/// Providers.altCache pattern) because the search view is
/// recreated on every open while the session memory must
/// survive it. Keys are precomputed at feed time, so a query
/// costs two substring checks per entry.
private final class JoeSearchSession: @unchecked Sendable {
    static let shared = JoeSearchSession()

    private let lock = NSLock()
    private var poolOrder: [String] = []
    private var pool: [String: Movie] = [:]
    private var poolKeys: [String: (name: String, origin: String)] = [:]
    private var snapshots: [(name: String, local: [Movie], server: [Movie])] = []

    /// Feed downloaded titles into the pool: first copy wins,
    /// cap 6000 entries with eldest-first eviction.
    func feed(_ movies: [Movie]) {
        lock.lock()
        for m in movies where !m.slug.isEmpty {
            if pool[m.id] == nil {
                pool[m.id] = m
                poolKeys[m.id] = (Providers.normalizeTitle(m.name),
                                  Providers.normalizeTitle(m.originName))
                poolOrder.append(m.id)
            }
        }
        while poolOrder.count > 6000 {
            let evicted = poolOrder.removeFirst()
            pool.removeValue(forKey: evicted)
            poolKeys.removeValue(forKey: evicted)
        }
        lock.unlock()
    }

    /// Local hits for a name — the search's own match rule:
    /// normalized substring over the name OR the origin name.
    func localHits(for query: String) -> [Movie] {
        let q = Providers.normalizeTitle(query)
        guard !q.isEmpty else { return [] }
        lock.lock()
        let ids = poolOrder
        let poolCopy = pool
        let keysCopy = poolKeys
        lock.unlock()
        return ids.compactMap { id in
            guard let m = poolCopy[id], let k = keysCopy[id] else { return nil }
            return (k.name.contains(q) || k.origin.contains(q)) ? m : nil
        }
    }

    /// A snapshotted clean round for this name (LRU touch on
    /// hit), or nil.
    func snapshot(for name: String) -> (local: [Movie], server: [Movie])? {
        lock.lock()
        defer { lock.unlock() }
        if let i = snapshots.firstIndex(where: { $0.name == name }) {
            let hit = snapshots.remove(at: i)
            snapshots.append(hit)
            return (hit.local, hit.server)
        }
        return nil
    }

    /// Snapshot a round. The CALLER enforces the FIX2 rule —
    /// only rounds with zero failed branches are stored, so a
    /// failed round can never be replayed as a result.
    func storeSnapshot(name: String, local: [Movie], server: [Movie]) {
        lock.lock()
        snapshots.removeAll { $0.name == name }
        snapshots.append((name, local, server))
        if snapshots.count > 12 {
            snapshots.removeFirst(snapshots.count - 12)
        }
        lock.unlock()
    }
}

// CONVERGENCE RECORD (2026-11-15): JoeSearchMoveTrap — this
// file's copy of the conditional move-trap pattern — is
// DELETED; see the record at the end of JoeTVApp.swift. The
// top-row and Retry traps it powered are replaced by geometric
// focus movement; the per-result grid handler (resultMove)
// stays, as it was always per-element and unconditional.
