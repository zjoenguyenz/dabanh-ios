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
    // v2.0.13 (Netflix-style search — owner order
    // 2026-11-16, "Bỏ luôn cái lọc phim ra tùm lum thể
    // loại đi"): the facet bar is GONE from this screen —
    // no JoeFilterBar, no JoeBrowseFilter state here any
    // more (both types stay in JoeBrowse.swift for the
    // browse layer, untouched). The field drives the
    // search directly: every edit re-arms a ~300 ms
    // debounce (scheduleTypeAhead below); when it fires,
    // the round for the current text runs — local hits
    // paint first, provider branches merge behind them,
    // never wiping the screen. v2.0.17: the edits now come
    // from the on-screen letter strip (JoeLetterStrip,
    // below) — the system TextField and its full-screen
    // keyboard are gone, so the grid the rounds paint stays
    // visible while typing (the owner's Netflix comparison,
    // 2026-11-17). The debounce and the rounds are unchanged.
    @State private var typeAheadTask: Task<Void, Never>?
    @FocusState private var focusedMovie: Movie.ID?
    @FocusState private var retryFocused: Bool

    /// The top area's focus landing (v2.0.17): a letter-strip
    /// key or the Quay lại button — see JoeSearchKeyFocus.
    /// The TextField that used to own this landing is gone.
    @FocusState private var keyFocus: JoeSearchKeyFocus?

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
            // v2.0.17: the letter strip — typing lives here
            // now, under the query display, always visible.
            JoeLetterStrip(query: $query, focus: $keyFocus)
            // v2.0.13: NO filter bar on this screen — the
            // Phase 6 facet rows that sat here are removed
            // whole (owner order above). The field row above
            // and the results below keep their frame, order
            // and look; the bar's slot is simply empty, so
            // focus travel is field row ↔ results, section
            // to section geometrically, as it was around the
            // bar. No handlers anywhere (Phase 1 stands).
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
                    // (Its UP-to-strip routing is geometric:
                    // the letter strip is the nearest focusable above.
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
        // v2.0.17: strip edits drive the type-ahead round —
        // the onChange that used to sit on the TextField.
        .onChange(of: query) { _, _ in scheduleTypeAhead() }
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
        // v2.0.17: the landing is the strip's first key — the
        // field this declaration used to name no longer exists.
        .defaultFocus($keyFocus, .key("a"))
    }

    /// The query row (v2.0.17): the query as a light display
    /// (the field's chrome, never focused — there is no
    /// system field any more) + Quay lại. Typing happens on the letter strip
    /// directly below; the Tìm button is gone because typing
    /// IS the search (v2.0.13's rule, now visible while it
    /// happens). In A/F the row is centred by the body; D
    /// runs it full width.
    private var fieldRow: some View {
        HStack(spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 26, weight: .semibold))
                Text(query.isEmpty ? "Tên phim…" : query)
                    .font(.system(size: ThemeTokens.fieldTextSize))
                    .lineLimit(1)
            }
            // The inner frame makes the display greedy, so
            // the chrome paints the field's full width (D-19:
            // D full width; A/F keep their centred 700).
            .frame(maxWidth: .infinity, alignment: .leading)
            .joeFieldChrome(focused: false)
            .frame(maxWidth: theme.id == .posterWall ? .infinity : 700)
            Button {
                nav.searchOpen = false
            } label: {
                JoeSecondaryLabel(title: "⟵ Quay lại")
            }
            .joeCardButton()
            .focused($keyFocus, equals: .back)
        }
        // The row stays a declared focus region (v2.0.5 N1);
        // the strip below is a region of its own, and
        // movement between the regions is the engine's
        // geometric search, as it has been since v2.0.8.
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
                                    resultCard(movie)
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 8)
            }
            // v2.0.12 (search overlap fix): this container
            // deliberately CLIPS at its frame — no
            // .scrollClipDisabled() here. The status line
            // and the results heading are PINNED siblings
            // directly above this ScrollView in the body's
            // VStack (the facet bar that sat there until
            // v2.0.13 was one too); with clipping disabled,
            // results scrolling past the frame's top edge
            // kept rendering into their space, painting
            // posters and provider headers over them
            // (owner's 2.0.11 clip, shot when the bar was
            // the victim). The home's outer scroll
            // (JoePhimHome.railHome) ships clipped with the
            // same cards; the rails' own inner horizontal
            // scrolls keep their clip-disabled construction
            // (JoeTheme.Rail) — that escape is bounded inside
            // this container, and this container's frame is
            // now the hard boundary nothing crosses.
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                // Fixed 6 columns (was .adaptive(minimum: 240)).
                // v2.0.8 (Phase 1): no arithmetic routing any
                // more — resultMove is deleted and the engine
                // moves geometrically over this grid.
                // Column gap = the theme's rail gap (design
                // card pitch: A 26, D 24, F 28).
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: theme.railGap),
                                         count: 6),
                          alignment: .leading, spacing: 40) {
                    ForEach(results) { movie in
                        resultCard(movie)
                    }
                }
                .padding(.vertical, 8)
                // Design D's wall ring is an OUTSET band around
                // the art (6 pt): the grid's edge clearance
                // grows past it under D so the outer columns'
                // rings are never clipped by the scroll frame.
                .padding(.horizontal, theme.id == .posterWall ? 8 : 4)
            }
            // v2.0.12 (search overlap fix): CLIPS at its
            // frame, same as the source-board branch above —
            // no .scrollClipDisabled() on this container.
            // The pinned status/heading lines sit directly
            // above it in the stack; unclipped grid content
            // scrolling past the top edge rendered over
            // them.
            // The grid's own edge clearances (vertical 8,
            // horizontal 8 under D — past the 6 pt outset
            // ring) are unchanged, so a focused card's ring
            // keeps its room inside the frame.
        }
    }

    // v2.0.13: the results area renders `results` — the
    // round's render pool — directly. The Phase 6 facet
    // layer that used to sit between the pool and the grid
    // (displayedResults + facetFiltered over the shared
    // JoeBrowseFilter) is DELETED with the bar it served;
    // nothing filters or re-sorts a round's results on
    // this screen any more.

    private func resultCard(_ movie: Movie) -> some View {
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
        .focused($focusedMovie, equals: "search|" + movie.id)
    }

    // v2.0.8 (Phase 1): resultMove is DELETED — result
    // cards are plain buttons in the results focus section;
    // the engine moves within the grid geometrically and UP
    // out of it (to the query row, from any column) the
    // same way. No coded no-op directions remain in this
    // view.

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
    //
    // v2.0.13: rounds now fire from the keyboard as well —
    // scheduleTypeAhead() below debounces field edits by
    // ~300 ms and runs the round for the settled text, so
    // the grid follows the typing (local paint per round,
    // branches merging behind). runSearch itself is
    // unchanged: same local-first step, same fan-out, same
    // settles, same snapshot rule. A new round supersedes
    // the in-flight one by roundID, so a stale term's
    // branches can never land over a newer term's grid.

    /// The debounced type-ahead driver (v2.0.13). Every
    /// field edit cancels the pending firing and re-arms
    /// it; when the ~300 ms elapse with the text unchanged,
    /// the round for that text runs. An emptied field does
    /// NOT run a round — it resets the screen to its
    /// un-searched state (resetSearch), superseding any
    /// in-flight round so a late branch cannot repaint a
    /// screen the owner has already cleared.
    private func scheduleTypeAhead() {
        typeAheadTask?.cancel()
        let text = query
        typeAheadTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            // Belt and braces beside the cancellation: a
            // firing whose text is no longer the field's
            // stands down (a newer edit re-armed its own).
            guard query == text else { return }
            if text.trimmingCharacters(in: .whitespaces).isEmpty {
                resetSearch()
            } else {
                runSearch()
            }
        }
    }

    /// The field was cleared: back to the pre-search state.
    /// The roundID bump stands down the old round's branch
    /// tasks and both settle tasks (all guard on it).
    private func resetSearch() {
        roundID += 1
        roundActive = false
        searching = false
        searched = false
        searchFailed = false
        searchedQuery = ""
        localPool = []
        serverPool = []
        results = []
    }

    private func runSearch() {
        // An immediate round (Tìm / onSubmit, or the
        // type-ahead firing itself) supersedes any pending
        // debounce — its firing must not re-run this round
        // a second time for the same text.
        typeAheadTask?.cancel()
        let kw = query.trimmingCharacters(in: .whitespaces)
        guard !kw.isEmpty else { return }
        searchedQuery = kw
        searchFailed = false

        // Snapshot restore: a clean earlier round for this
        // name replays instantly with zero network.
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
    /// store copies carry the richer metadata).
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

/// Focus identity for the search screens' top area
/// (v2.0.17): a letter-strip key (its id IS its label —
/// "a"…"z", "1"…"0", "space", "del", "mode") or the Quay
/// lại button.
/// Shared by JoeSearchView and JoeTVBSearchView, whose top
/// areas are twins.
enum JoeSearchKeyFocus: Hashable {
    case key(String)
    case back
}

/// The Netflix-anatomy letter strip (v2.0.17 — the owner's
/// order, his Netflix photo as the drawing): ONE row of keys
/// on the search screen itself — a mode key, a space key,
/// the letters, a delete key — mutating the bound query;
/// the host's onChange fires its search round per edit, so
/// results repaint in this same screen while typing. The
/// system TextField it replaces summoned the full-screen
/// keyboard and hid the results until "done" (the owner's
/// screen recording, 2026-11-17). The second mode swaps the
/// letters for the digits and the few symbols film titles
/// carry.
struct JoeLetterStrip: View {
    @Binding var query: String
    var focus: FocusState<JoeSearchKeyFocus?>.Binding
    @State private var symbols = false

    private var letters: [String] {
        symbols
            ? ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0",
               "-", "'", ".", "&", ":"]
            : Array("abcdefghijklmnopqrstuvwxyz").map(String.init)
    }

    var body: some View {
        HStack(spacing: 8) {
            key(id: "mode", label: symbols ? "abc" : "123", width: 96) {
                symbols.toggle()
            }
            key(id: "space", label: "space", width: 128) {
                append(" ")
            }
            ForEach(letters, id: \.self) { letter in
                key(id: letter, label: letter, width: 42) {
                    append(letter)
                }
            }
            key(id: "del", label: "⌫", width: 96) {
                if !query.isEmpty { query.removeLast() }
            }
        }
        .focusSection()
    }

    private func append(_ s: String) {
        guard query.count < 48 else { return }
        query += s
    }

    private func key(id: String, label: String, width: CGFloat,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            JoeKeyCap(label: label, width: width,
                      focused: focus.wrappedValue == .key(id))
        }
        .joeCardButton()
        .focused(focus, equals: .key(id))
    }
}

/// One strip key's face: a quiet plate unfocused, the
/// theme's focus colour filled when focused — the label
/// paints its own focus, because the house button style
/// (JoeCardButton) deliberately paints nothing.
private struct JoeKeyCap: View {
    let label: String
    let width: CGFloat
    let focused: Bool
    @Environment(\.joeTheme) private var theme

    var body: some View {
        Text(label)
            .font(.system(size: 28, weight: .medium))
            .foregroundStyle(focused ? .black : theme.text)
            .frame(width: width, height: 58)
            .background(RoundedRectangle(cornerRadius: 12)
                .fill(focused ? theme.focus : Color.white.opacity(0.08)))
    }
}

// CONVERGENCE RECORD (2026-11-15): JoeSearchMoveTrap — this
// file's copy of the conditional move-trap pattern — is
// DELETED; see the record at the end of JoeTVApp.swift. The
// top-row and Retry traps it powered are replaced by geometric
// focus movement.
// v2.0.8 (Phase 1): the per-result grid handler (resultMove)
// is DELETED too — an attached .onMoveCommand owned every
// direction and made undeclared ones no-ops; result cards
// are plain buttons and movement is the engine's throughout
// this file.
