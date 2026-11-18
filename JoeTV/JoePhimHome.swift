import SwiftUI
import Darwin

/// Route into a movie detail, from any rail or search result.
struct MovieRoute: Hashable {
    var provider: String
    var slug: String
    var name: String
    var poster: String
    var year: String
    /// Episode to preselect (Continue Watching taps).
    var preselectEp: String = ""
}

/// The Phim section root (v2.0.0, Team UI-5). One root, three
/// design trees over the unchanged data layer:
///  - A Billboard: full-bleed backdrop hero + every rail below
///  - D Poster Wall: JoeWallHomeView (JoeBrowse.swift)
///  - F Source Board: source bands over the provider rails +
///    every category shelf as rails below the bands
/// Search and the browse/grid layer swap in above the home,
/// exactly as search always has.
///
/// MENU (v2.0.0): this root carries the eighth exit handler
/// (UI-1's exit-dialog spec) — always installed, state-checked
/// inside: browse open → close browse; otherwise present the
/// exit confirmation. Search and the detail/player layers keep
/// their own nearer handlers, so one press still closes exactly
/// one layer. WatchStore persists synchronously on every
/// mutation (1.9.2), so the destructive action's flush is
/// already done by construction; it dismisses the alert and
/// exits on the next main-actor turn.
struct JoePhimHome: View {
    @EnvironmentObject private var watch: WatchStore
    @EnvironmentObject private var nav: JoeNavigator
    @EnvironmentObject private var phim: PhimStore
    @Environment(\.joeTheme) private var theme
    // v2.0.8 (Phase 1 — focus memory): these seven @FocusState
    // values are the home's focus MEMORY and nothing else. The
    // engine writes them as focus moves; the move handlers
    // that used to write landings are retired, and nothing
    // resets them: this file has no .onAppear, its two .task
    // blocks write only `attempted` / catalogue state and
    // heroDetail / heroBackdropURL, and the root presents the
    // detail as a ZStack overlay over this still-living view —
    // so the card the owner left is the card focus returns to
    // when the detail closes. The .focused bindings below are
    // what keep each card's identity stable for that return.
    // ONE sanctioned write remains: the browse layer SWAPS
    // this home out of the tree (it is not an overlay), so on
    // browse close the browse-return observer in `body` writes
    // the invoking browse entry's state back (F5 restoration —
    // see browseReturnTarget).
    @FocusState private var focusedMovie: Movie.ID?
    @FocusState private var focusedEntry: String?
    @FocusState private var headerFocused: Bool
    @FocusState private var heroPlayFocused: Bool
    @FocusState private var heroBrowseFocused: Bool
    @FocusState private var bandFocused: String?
    @FocusState private var retryFocused: Bool
    /// v2.0.8 (Phase 5/F5): which of this home's three browse
    /// entries opened the browse layer — the hero's "Tất cả
    /// phim" button, the slim header's "Tất cả phim" button, or
    /// a source band's "Xem tất cả ›" (by rail scope). Recorded
    /// in the entry's own action, consumed by the browse-close
    /// observer in `body`, which restores focus to exactly
    /// that entry. (Design F's slim-header entry was already
    /// the .defaultFocus landing; the hero's entry and the
    /// band entries were not — returning from browse landed on
    /// Play / the header button instead of the invoking box.)
    @State private var browseReturnTarget: BrowseReturnTarget?
    private enum BrowseReturnTarget {
        case heroBrowse
        case header
        case band(String)
    }
    /// Team 4 fix-round minor: the state surfaces (G3/G5) are
    /// gated on "a load has been attempted" so they cannot flash
    /// for a frame at cold entry, before the first loadIfNeeded
    /// has even run (at that instant loading == false and the
    /// catalogue is trivially empty).
    @State private var attempted = false
    @State private var exitConfirm = false
    /// UI-6 defect D-2: the featured film's DETAIL, fetched
    /// fail-soft for the hero's synopsis (the list payloads
    /// carry no synopsis) and as the fallback source for the
    /// meta fields a sparse list item left empty.
    @State private var heroDetail: Detail?
    /// Hero forensics fix (2026-11-15): the featured film's
    /// TMDB w1280 backdrop URL, resolved by the hero task.
    /// The list thumb cannot be the hero's only art source —
    /// for many KK titles it is a 780×438 marketing composite
    /// with the title logo baked into the art, and no window
    /// of it reads as a backdrop in the 668-tall hero (the
    /// owner's "hầu như hư hết" photos). The detail screen
    /// already holds the owner's standard — TMDB backdrop
    /// first, provider art as fallback; the hero now mirrors
    /// it (see the stage stack in `hero`).
    @State private var heroBackdropURL: URL?
    /// Ultra hero (v2.0.19): the featured film's TMDB logo
    /// art and vote average, resolved by the same task.
    @State private var heroLogoURL: URL?
    @State private var heroRating: Double = 0

    var body: some View {
        Group {
            if nav.searchOpen {
                JoeSearchView()
            } else if theme.id == .posterWall {
                // v2.0.11: theme D's wall stays mounted and
                // switches between its home shelves and the
                // "Tất cả phim" panel on nav.browseOpen
                // internally (see JoeWallHomeView in
                // JoeBrowse.swift), so the posterWall branch
                // must win over the browse branch — with the
                // old order, opening the panel in D would swap
                // in the A/F browse surface instead. For A/F
                // nothing changes: their posterWall check is
                // false and the browse branch follows as before.
                JoeWallHomeView()
            } else if nav.browseOpen {
                JoeBrowseView()
            } else if theme.id == .ultra {
                ultraHome
            } else {
                railHome
            }
        }
        .task {
            attempted = true
            phim.loadIfNeeded()
        }
        // CONVERGENCE (spec item 3, 2026-11-15): no programmatic
        // focus writes on the launch path. DOWN from the pills
        // lands on the home's top element geometrically.
        //
        // EXIT DIALOG (UI-5, handler #8 of the 8 in
        // JoeTV/*.swift — the compiled target also carries the
        // shared TV player's own cover handler in
        // DaBanhTV/TVPlayerView.swift:47; inventory wording per
        // UI-7 F-3 / APPLE-CONFORMANCE G-EXIT-2): always
        // installed on the Phim section root; the state check
        // lives INSIDE the closure, so the handler's
        // installation never depends on any state (the D4-safe
        // shape). Search has its own nearer handler while it is
        // open; details and the player are nearer still.
        .onExitCommand {
            if nav.browseOpen {
                nav.browseOpen = false
            } else if !nav.searchOpen {
                exitConfirm = true
            }
        }
        // v2.0.5 (N3): delivery for the presses this handler
        // cannot see. Exit commands only reach ANCESTORS of
        // the focused view, and the shell's topBar is a
        // sibling of this subtree — a Menu press with focus
        // on a pill never arrives here. JoeRootView's root
        // handler runs the shell state machine for those
        // presses and, when only the exit confirmation
        // remains, sets nav.exitRequested; this observer
        // presents THIS view's one confirmation for it (the
        // root never grows a second alert). The state checks
        // mirror the handler above exactly.
        .onChange(of: nav.exitRequested) { _, requested in
            guard requested else { return }
            nav.exitRequested = false
            if nav.browseOpen {
                nav.browseOpen = false
            } else if !nav.searchOpen {
                exitConfirm = true
            }
        }
        // v2.0.8 (Phase 5/F5): browse-return focus restoration.
        // The browse layer swaps this home out of the tree, so
        // the persisting-@FocusState return the detail overlay
        // gets for free does not happen here — without this
        // write, focus re-enters at the home's .defaultFocus
        // (the hero's Play button, or the slim header's browse
        // button), not at the entry that opened browse. On the
        // true→false transition, restore focus to the recorded
        // invoking entry (browseReturnTarget). The guards keep
        // the write honest: it fires only when the home is
        // actually coming back on screen (Phim section current,
        // search not open) — a browse closed as a side effect
        // of leaving the section restores nothing. This is a
        // restoration write on layer close, not a landing
        // write on appear; it changes no structure (law D4).
        .onChange(of: nav.browseOpen) { wasOpen, isOpen in
            guard wasOpen, !isOpen else { return }
            let target = browseReturnTarget
            browseReturnTarget = nil
            guard let target, nav.section == .phim,
                  !nav.searchOpen else { return }
            switch target {
            case .heroBrowse:
                heroBrowseFocused = true
            case .header:
                headerFocused = true
            case .band(let scope):
                bandFocused = scope
            }
        }
        .alert("Thoát Joe TV?", isPresented: $exitConfirm) {
            Button("Thoát", role: .destructive) {
                exitConfirm = false
                DispatchQueue.main.async { exit(0) }
            }
            Button("Ở lại", role: .cancel) { }
        } message: {
            Text("Phim đang xem dở vẫn được lưu lại cho lần mở sau.")
        }
    }

    // MARK: - Rail home (designs A and F)

    private var railHome: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 40) {
                if theme.id == .billboard {
                    if heroMovie != nil {
                        hero
                    } else {
                        slimHeader
                    }
                } else {
                    slimHeader
                }
                cwRail
                favRail
                ForEach(railSpecs) { spec in
                    if !spec.movies.isEmpty {
                        if let band = spec.bandName {
                            bandHeader(name: band, note: spec.bandNote ?? "", scope: spec.scope)
                        }
                        movieRail(spec.title, spec.movies, badges: spec.badges, scope: spec.scope)
                    }
                }
                // §8/G1: the spinner exists only while a load
                // is running, nothing has landed, and the 20 s
                // store deadline has not fired — never longer.
                if catalogueEmpty && phim.loading && !phim.loadTimedOut {
                    ProgressView("Đang tải thư viện phim…")
                        .font(.system(size: 29))
                        .foregroundStyle(theme.text)
                        .tint(theme.text)
                        .padding(.top, 30)
                }
                // §8/G3 + C-8 + BLOCK-2: the error surface
                // shows ONLY when no catalogue rail has data
                // (never under healthy rails), and only in
                // Team 4's two failure states — the deadline
                // fired, or the load ended with real provider
                // errors. An all-empty SUCCESS is G5 below,
                // not an error (spec-wins ruling (d)).
                if showPhimError {
                    errorSurface
                }
                // §8/G5: every provider answered, nothing
                // failed, the catalogue is simply empty —
                // message only, no spinner, no Retry.
                if showPhimEmpty {
                    Text("Thư viện chưa có dữ liệu.")
                        .font(.system(size: 29))
                        .foregroundStyle(theme.meta)
                        .padding(.top, 30)
                }
                // §8/G4: partial failure — content renders,
                // one non-focusable warning line at the very
                // bottom names the providers with no content.
                if phim.hasData && !failedProviders.isEmpty {
                    Text("Chưa tải được: " + failedProviders.joined(separator: ", "))
                        .font(.system(size: 25))
                        .foregroundStyle(.orange)
                }
            }
        }
        // v2.0.8 (Phase 1 — navigation freedom): routing between
        // the header/hero and the rails is FULLY geometric. The
        // first rail's arithmetic .onMoveCommand handler
        // (handleFirstRailMove) is RETIRED: an attached handler
        // owns every direction and swallows the directions it
        // does not declare, which is what trapped movement on a
        // single axis. Every rail is its own .focusSection()
        // (the shared Rail view), so the focus engine's
        // geometric search over the declared sections owns all
        // movement here — the deeper rails' long-standing shape
        // (see the focus-memory note at the @FocusState block),
        // now the whole home's shape.
    }

    // MARK: - Ultra home (v2.0.19 — the Sony Ultra port)

    /// Ultra's home: a FIXED full-bleed backdrop of the
    /// featured film behind the whole page (the Sony shape —
    /// no band), the hero text column floating over its lower
    /// left, and the rails scrolling over the backdrop's fade
    /// to the page background.
    private var ultraHome: some View {
        ZStack(alignment: .topLeading) {
            if let featured = heroMovie {
                ZStack {
                    if let url = featured.posterURL {
                        JoeBandImage(url: url, targetPixels: 1920,
                                     anchor: 0.20, portraitMode: .blurField)
                    }
                    if let url = featured.thumbURL, url != featured.posterURL {
                        JoeBandImage(url: url, targetPixels: 1920,
                                     anchor: 0.20, portraitMode: .blurField)
                    }
                    if let heroBackdropURL {
                        JoeBandImage(url: heroBackdropURL, targetPixels: 1920,
                                     anchor: 0.20, portraitMode: .slice)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                LinearGradient(stops: [
                    .init(color: .black.opacity(0.88), location: 0),
                    .init(color: .black.opacity(0.45), location: 0.45),
                    .init(color: .black.opacity(0.10), location: 0.75),
                    .init(color: .black.opacity(0.05), location: 1)
                ], startPoint: .leading, endPoint: .trailing)
                LinearGradient(stops: [
                    .init(color: .clear, location: 0.42),
                    .init(color: theme.bg.opacity(0.85), location: 0.62),
                    .init(color: theme.bg, location: 0.78)
                ], startPoint: .top, endPoint: .bottom)
            }
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 40) {
                    if heroMovie != nil {
                        ultraHeroZone
                    } else {
                        slimHeader
                    }
                    cwRail
                    favRail
                    ForEach(railSpecs) { spec in
                        if !spec.movies.isEmpty {
                            if let band = spec.bandName {
                                bandHeader(name: band, note: spec.bandNote ?? "", scope: spec.scope)
                            }
                            movieRail(spec.title, spec.movies, badges: spec.badges, scope: spec.scope)
                        }
                    }
                    if catalogueEmpty && phim.loading && !phim.loadTimedOut {
                        ProgressView("Đang tải thư viện phim…")
                            .font(.system(size: 29))
                            .foregroundStyle(theme.text)
                            .tint(theme.text)
                            .padding(.top, 30)
                    }
                    if showPhimError {
                        errorSurface
                    }
                    if showPhimEmpty {
                        Text("Thư viện chưa có dữ liệu.")
                            .font(.system(size: 29))
                            .foregroundStyle(theme.meta)
                            .padding(.top, 30)
                    }
                    if phim.hasData && !failedProviders.isEmpty {
                        Text("Chưa tải được: " + failedProviders.joined(separator: ", "))
                            .font(.system(size: 25))
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    /// The Ultra hero text zone: a clear 600-tall stage over
    /// the fixed backdrop — logo art first (the Sony rule: the
    /// logo replaces the text title and hides the origin
    /// line), gold meta with the IMDb pill appended, synopsis
    /// up to 4 lines, then the action row.
    @ViewBuilder
    private var ultraHeroZone: some View {
        if let featured = heroMovie {
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 0)
                if let heroLogoURL {
                    JoeRemoteImage(url: heroLogoURL, targetPixels: 1000, fit: true) {
                        Color.clear
                    }
                    .frame(maxWidth: 640, maxHeight: 120, alignment: .leading)
                } else {
                    Text(featured.name)
                        .font(.system(size: 68, weight: .heavy))
                        .foregroundStyle(theme.text)
                        .lineLimit(2)
                }
                if heroLogoURL == nil, !featured.originName.isEmpty,
                   featured.originName != featured.name {
                    Text(featured.originName.uppercased())
                        .font(.system(size: 24, weight: .semibold))
                        .tracking(4)
                        .foregroundStyle(theme.heroMeta)
                        .lineLimit(1)
                        .padding(.top, 10)
                }
                HStack(spacing: 16) {
                    Text(heroMetaLine(featured))
                        .font(.system(size: 27, weight: .medium))
                        .foregroundStyle(theme.heroMeta)
                        .lineLimit(1)
                    if heroRating > 0 {
                        Text(String(format: "IMDb %.1f", heroRating))
                            .font(.system(size: 23, weight: .bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 7)
                                .fill(Color(red: 0.961, green: 0.773, blue: 0.094)))
                    }
                }
                .padding(.top, 12)
                if !heroGenres.isEmpty {
                    Text(heroGenres.joined(separator: " · "))
                        .font(.system(size: 23))
                        .foregroundStyle(theme.text.opacity(0.85))
                        .lineLimit(1)
                        .padding(.top, 10)
                }
                if let synopsis = heroDetail?.content, !synopsis.isEmpty {
                    Text(synopsis)
                        .font(.system(size: 26))
                        .foregroundStyle(theme.text.opacity(0.92))
                        .lineSpacing(6)
                        .lineLimit(4)
                        .frame(maxWidth: 1000, alignment: .leading)
                        .padding(.top, 16)
                }
                HStack(spacing: 18) {
                    Button {
                        nav.movie = MovieRoute(provider: featured.provider,
                                               slug: featured.slug,
                                               name: featured.name,
                                               poster: featured.poster,
                                               year: featured.year)
                    } label: {
                        JoePrimaryLabel(title: "Xem ngay", systemImage: "play.fill")
                    }
                    .joeCardButton()
                    .focused($heroPlayFocused)
                    Button {
                        toggleHeroFavorite(featured)
                    } label: {
                        JoeSecondaryLabel(title: isHeroFavorite(featured)
                                          ? "♥ Đã thích" : "♡ Yêu thích")
                    }
                    .joeCardButton()
                    Button {
                        browseReturnTarget = .heroBrowse
                        nav.browseOpen = true
                    } label: {
                        JoeSecondaryLabel(title: "Tất cả phim",
                                          systemImage: "square.grid.2x2")
                    }
                    .joeCardButton()
                    .focused($heroBrowseFocused)
                }
                .padding(.top, 26)
            }
            .frame(height: 600, alignment: .bottomLeading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .defaultFocus($heroPlayFocused, true)
            // The Billboard hero's resolve task, extended to
            // publish the logo + rating (fetchInfo is cached
            // in TMDBClient, so the second read is free).
            .task(id: featured.id) {
                heroDetail = nil
                heroBackdropURL = nil
                heroLogoURL = nil
                heroRating = 0
                async let detailFetch = Providers.detail(
                    featured.provider, slug: featured.slug)
                async let earlyInfo = TMDBClient.fetchInfo(
                    tmdbId: featured.tmdbId, type: featured.tmdbType)
                heroDetail = try? await detailFetch
                guard !TMDBClient.apiKey.isEmpty else { return }
                let m = heroDetail?.movie ?? featured
                var backdrop = ""
                if !m.tmdbId.isEmpty {
                    if m.tmdbId == featured.tmdbId,
                       m.tmdbType == featured.tmdbType {
                        if let info = await earlyInfo {
                            backdrop = info.backdropURL
                        }
                    } else {
                        backdrop = await TMDBClient.fetchInfo(
                            tmdbId: m.tmdbId, type: m.tmdbType)?.backdropURL ?? ""
                    }
                }
                if backdrop.isEmpty {
                    backdrop = await TMDBClient.searchBackdrop(
                        name: m.name, origin: m.originName,
                        year: Providers.yearOf(m)) ?? ""
                }
                if !backdrop.isEmpty {
                    heroBackdropURL = URL(string: backdrop)
                }
                if !m.tmdbId.isEmpty,
                   let info = await TMDBClient.fetchInfo(
                    tmdbId: m.tmdbId, type: m.tmdbType) {
                    if !info.logoURL.isEmpty {
                        heroLogoURL = URL(string: info.logoURL)
                    }
                    if info.voteAverage > 0 {
                        heroRating = info.voteAverage
                    }
                }
            }
        }
    }

    // MARK: - Rail specs (single source of truth for order)

    /// The rail list lives at file scope (joeRailSpecs below)
    /// since UI-6 defect D-1: design D's wall renders the same
    /// category shelves as titled wall sections, driven by this
    /// one list — the completeness A/F have, from one source.
    private var railSpecs: [JoeRailSpec] {
        joeRailSpecs(phim: phim, themeID: theme.id)
    }

    // MARK: - Design A hero

    /// The featured slot: the first thumb-bearing film in rail
    /// order (thumb-bearing sources only — UI-4's cost note),
    /// falling back to the first film's poster as the backdrop.
    private var heroMovie: Movie? {
        let all = railSpecs.flatMap { $0.movies }
        return all.first(where: { !$0.thumb.isEmpty }) ?? all.first
    }

    @ViewBuilder
    private var hero: some View {
        if let featured = heroMovie {
            ZStack(alignment: .bottomLeading) {
                // v2.0.1 (Android hero parity): the hero art
                // paints through the band layer — a landscape
                // thumb as a top-anchored slice (anchor 0.20,
                // the Android hero anchor) instead of the
                // centred fill that cut faces, and a poster-
                // only feature falls back to the blurred field
                // rather than a cropped poster. The scrims
                // below are untouched.
                //
                // Hero forensics fix (2026-11-15): the single
                // layer above became a three-stage stack — the
                // detail band's own discipline, each stage
                // painting the moment its bitmap lands, higher
                // stages covering lower ones:
                //   1. the poster as a blurred field — the
                //      stand-in. The rail card below already
                //      decoded this bitmap, so the hero never
                //      sits black while a usable image is on
                //      the device (the Android FIX4 lesson the
                //      port applied to the detail band but not
                //      to the hero: the old single layer's
                //      thumb URL is decoded nowhere else, so
                //      one failed load = an empty hero for the
                //      view's whole life — the owner's wide
                //      photo);
                //   2. the provider thumb slice (the v2.0.1
                //      art, kept as the fallback) — skipped
                //      when it is the same URL as the poster
                //      (the KK/VS poster fallback), which
                //      stage 1 already paints;
                //   3. the featured film's TMDB w1280 backdrop
                //      (heroBackdropURL, resolved by the task
                //      below) — the primary art, per the
                //      owner's backdrop standard.
                if let url = featured.posterURL {
                    JoeBandImage(url: url, targetPixels: 1920,
                                 anchor: 0.20, portraitMode: .blurField)
                    .frame(maxWidth: .infinity)
                    .frame(height: 668)
                    .clipped()
                }
                if let url = featured.thumbURL, url != featured.posterURL {
                    JoeBandImage(url: url, targetPixels: 1920,
                                 anchor: 0.20, portraitMode: .blurField)
                    .frame(maxWidth: .infinity)
                    .frame(height: 668)
                    .clipped()
                }
                if let heroBackdropURL {
                    JoeBandImage(url: heroBackdropURL, targetPixels: 1920,
                                 anchor: 0.20, portraitMode: .slice)
                    .frame(maxWidth: .infinity)
                    .frame(height: 668)
                    .clipped()
                }
                // UI-3 SCRIM FLOOR (hard requirement): the
                // horizontal scrim never drops below the token
                // floor (0.55 black) anywhere inside the text
                // zone (the left ~65% of the hero), so worst-case
                // text contrast is guaranteed by the TOKEN, not
                // by the backdrop's brightness. The bottom fade
                // only takes over below the text block.
                LinearGradient(stops: [
                    .init(color: .black.opacity(0.92), location: 0),
                    .init(color: .black.opacity(0.80), location: 0.45),
                    .init(color: .black.opacity(theme.scrimFloor), location: 0.65),
                    .init(color: .black.opacity(0.15), location: 0.82),
                    .init(color: .black.opacity(0.05), location: 1)
                ], startPoint: .leading, endPoint: .trailing)
                LinearGradient(stops: [
                    .init(color: .clear, location: 0.55),
                    .init(color: theme.bg, location: 1)
                ], startPoint: .top, endPoint: .bottom)
                // Design-A home hero text column (design-A/home.html):
                // the drawing spaces its elements with per-element
                // margins, not a uniform gap — kicker →(0) title
                // →(12) meta →(10) genres →(16) synopsis →(26)
                // buttons — so the column runs at spacing 0 and each
                // element carries its own top padding (an absent
                // element collapses with its margin, like CSS).
                VStack(alignment: .leading, spacing: 0) {
                    Text("Nổi bật hôm nay")
                        .font(.system(size: 22, weight: .bold))
                        .tracking(4)
                        .foregroundStyle(theme.text)
                    Text(featured.name)
                        .font(.system(size: 68, weight: .heavy))
                        .foregroundStyle(theme.text)
                        .lineLimit(2)
                    // App-only line (the home drawing has no origin
                    // line; it sits between title and meta here).
                    if !featured.originName.isEmpty, featured.originName != featured.name {
                        Text(featured.originName)
                            .font(.system(size: 27))
                            .foregroundStyle(theme.heroMeta)
                            .lineLimit(1)
                            .padding(.top, 10)
                    }
                    Text(heroMetaLine(featured))
                        .font(.system(size: 27, weight: .medium))
                        .foregroundStyle(theme.heroMeta)
                        .padding(.top, 12)
                    // UI-6 D-2: the render's genres line and
                    // synopsis — genres from the list payload's
                    // own category names (heroDetail's parsed
                    // categories behind them), the synopsis from
                    // the featured film's detail fetch.
                    if !heroGenres.isEmpty {
                        Text(heroGenres.joined(separator: " · "))
                            .font(.system(size: 23))
                            .foregroundStyle(theme.heroMeta)
                            .lineLimit(1)
                            .padding(.top, 10)
                    }
                    if let synopsis = heroDetail?.content, !synopsis.isEmpty {
                        Text(synopsis)
                            .font(.system(size: 26))
                            .foregroundStyle(theme.text.opacity(0.92))
                            .lineSpacing(6)
                            .lineLimit(3)
                            .frame(maxWidth: 880, alignment: .leading)
                            .padding(.top, 16)
                    }
                    HStack(spacing: 18) {
                        Button {
                            nav.movie = MovieRoute(provider: featured.provider,
                                                   slug: featured.slug,
                                                   name: featured.name,
                                                   poster: featured.poster,
                                                   year: featured.year)
                        } label: {
                            JoePrimaryLabel(title: "Xem ngay", systemImage: "play.fill")
                        }
                        .joeCardButton()
                        .focused($heroPlayFocused)
                        Button {
                            toggleHeroFavorite(featured)
                        } label: {
                            JoeSecondaryLabel(title: isHeroFavorite(featured)
                                              ? "♥ Đã thích" : "♡ Yêu thích")
                        }
                        .joeCardButton()
                        Button {
                            browseReturnTarget = .heroBrowse
                            nav.browseOpen = true
                        } label: {
                            JoeSecondaryLabel(title: "Tất cả phim",
                                              systemImage: "square.grid.2x2")
                        }
                        .joeCardButton()
                        // v2.0.8 (Phase 5/F5): bound so the
                        // browse-close observer can restore focus
                        // to THIS button — the hero's .defaultFocus
                        // stays on Play (the section entry), which
                        // is exactly why the return needed its own
                        // restoration path.
                        .focused($heroBrowseFocused)
                    }
                    .padding(.top, 26)
                }
                // Design: hero content max-width 1000, starting at
                // the screen padding edge (the rails' left edge) —
                // no extra horizontal inset; the 40 vertical inset
                // keeps the bottom-anchored column off the band's
                // bottom edge.
                .padding(.vertical, 40)
                .frame(maxWidth: 1000, alignment: .leading)
            }
            .frame(height: 668)
            // v2.0.5 (N1/N2), v2.0.8: the hero's play button is
            // this section's DECLARED top element while a hero
            // is on screen — the content section's entry landing
            // when focus moves DOWN from the pill row (the
            // engine resolves that move between the two focus
            // sections; since v2.0.8 nothing resigns focus to
            // force it) and the section's entry when focus
            // re-resolves into the home. Static declaration,
            // the JoeSearchView shape.
            .defaultFocus($heroPlayFocused, true)
            // UI-6 D-2: fetch the featured film's detail for
            // the synopsis (fail-soft — a failed fetch simply
            // leaves the hero without one).
            //
            // Hero forensics fix (2026-11-15): the same task
            // then resolves the featured film's TMDB backdrop
            // for stage 3 of the hero stack — by the payload
            // TMDB id when one is carried (the detail's movie
            // first, the list item behind it: KK parses the
            // tmdb object in both), else the name + year hunt
            // — the detail screen's exact pattern
            // (JoeMovieDetail's TMDB task). Fail-soft end to
            // end: no key, no id and no match simply leave the
            // hero on its provider-art stages.
            //
            // v2.0.8 (S-A4 parallelised): fetchInfo's inputs
            // (tmdbId + tmdbType) are carried by the featured
            // LIST record itself, so when the list item carries
            // an id the TMDB call no longer queues behind the
            // provider detail fetch — both start together
            // (async let) and the backdrop waits only for the
            // slower of the two. What PUBLISHES is unchanged:
            // heroDetail still lands the moment the detail
            // returns (before any TMDB wait), and the backdrop
            // is still decided by the serial rule — the
            // authoritative record is the detail's movie when
            // the detail landed, the list item behind it. The
            // early fetchInfo result is used ONLY when its
            // inputs are exactly the authoritative record's;
            // when the detail supplies a different id (or the
            // list item carried none and only the detail has
            // one), fetchInfo runs then with the authoritative
            // inputs, as before. searchBackdrop stays exactly
            // where it was: conditional on fetchInfo yielding
            // no backdrop, with the authoritative record's
            // name/origin/year.
            .task(id: featured.id) {
                heroDetail = nil
                heroBackdropURL = nil
                async let detailFetch = Providers.detail(
                    featured.provider, slug: featured.slug)
                async let earlyInfo = TMDBClient.fetchInfo(
                    tmdbId: featured.tmdbId, type: featured.tmdbType)
                heroDetail = try? await detailFetch
                guard !TMDBClient.apiKey.isEmpty else { return }
                let m = heroDetail?.movie ?? featured
                var backdrop = ""
                if !m.tmdbId.isEmpty {
                    if m.tmdbId == featured.tmdbId,
                       m.tmdbType == featured.tmdbType {
                        if let info = await earlyInfo {
                            backdrop = info.backdropURL
                        }
                    } else {
                        backdrop = await TMDBClient.fetchInfo(
                            tmdbId: m.tmdbId, type: m.tmdbType)?.backdropURL ?? ""
                    }
                }
                if backdrop.isEmpty {
                    backdrop = await TMDBClient.searchBackdrop(
                        name: m.name, origin: m.originName,
                        year: Providers.yearOf(m)) ?? ""
                }
                if !backdrop.isEmpty {
                    heroBackdropURL = URL(string: backdrop)
                }
            }
        }
    }

    /// The render's full hero meta (UI-6 D-2): year · quality
    /// · lang · episode (with the total appended as
    /// "Tập x / y tập" when both are known) · runtime ·
    /// country. Sparse list items borrow the missing fields
    /// from the featured film's detail movie.
    private func heroMetaLine(_ m: Movie) -> String {
        var episode = m.episodeCurrent
        let total = !m.episodeTotal.isEmpty
            ? m.episodeTotal : (heroDetail?.movie.episodeTotal ?? "")
        if episode.hasPrefix("Tập"), !total.isEmpty, total != "0" {
            episode = "\(episode) / \(total) tập"
        }
        let time = !m.time.isEmpty ? m.time : (heroDetail?.movie.time ?? "")
        let country = !m.country.isEmpty
            ? m.country : (heroDetail?.movie.country ?? "")
        return [m.year, m.quality, m.lang, episode, time, country]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// The hero's genre names: the list item's own categories
    /// first (the payloads carry them — D-2), the detail's
    /// parsed categories behind them, its joined categories
    /// string last.
    private var heroGenres: [String] {
        if let featured = heroMovie, !featured.categories.isEmpty {
            return featured.categories
        }
        if let fromDetail = heroDetail?.movie.categories, !fromDetail.isEmpty {
            return fromDetail
        }
        guard let joined = heroDetail?.categories, !joined.isEmpty else { return [] }
        return joined.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func isHeroFavorite(_ m: Movie) -> Bool {
        watch.isFavorite(key: WatchStore.movieFavKey(provider: m.provider, slug: m.slug))
    }

    private func toggleHeroFavorite(_ m: Movie) {
        var e = WatchStore.Entry()
        e.kind = Providers.kindOf(m.provider)
        e.key = WatchStore.movieFavKey(provider: m.provider, slug: m.slug)
        e.title = m.name
        e.poster = m.poster
        e.year = m.year
        e.slug = m.slug
        e.source = m.provider
        e.ts = Int64(Date().timeIntervalSince1970 * 1000)
        watch.toggleFavorite(e)
    }

    // MARK: - Design F header + source bands

    /// F's slim header (the band stack carries the screen; the
    /// header keeps the "Tất cả phim" browse entry). Also
    /// design A's fallback when no catalogue film exists yet
    /// to feature.
    ///
    /// UI-6 defect D-16 — DECLARED RETENTION (UI-6's fix text
    /// offers "remove or declare"): this header is F's ONLY
    /// focusable element above the owner rails. UP from the
    /// first rail lands on its browse button geometrically —
    /// v2.0.8 retired the first-rail move handler whose UP
    /// branch used to write that landing (headerFocused); the
    /// button's .focused binding and its .defaultFocus entry
    /// declaration below are what remain, and they are enough:
    /// from the button the pills are one geometric UP away.
    /// Removing the header would leave nothing above the
    /// entry rails for that UP to land on. It stays, declared,
    /// in both roles.
    private var slimHeader: some View {
        HStack(alignment: .center, spacing: 28) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Thư viện phim")
                    .font(.system(size: 44, weight: .heavy))
                    .foregroundStyle(theme.text)
                Text("KKPhim · Film4K · VSMOV · Tủ Phim — link được lấy mới mỗi lần bấm xem")
                    .font(.system(size: 25))
                    .foregroundStyle(theme.meta)
            }
            Spacer()
            Button {
                browseReturnTarget = .header
                nav.browseOpen = true
            } label: {
                JoeSecondaryLabel(title: "Tất cả phim", systemImage: "square.grid.2x2")
            }
            .joeCardButton()
            .focused($headerFocused)
        }
        // v2.0.5 (N1/N2): with no hero on screen (design F, or
        // A before the catalogue lands) the header's browse
        // button is the section's DECLARED top element — the
        // same landing role the hero play button plays above.
        // Only one of the two headers ever renders at a time.
        .defaultFocus($headerFocused, true)
    }

    /// F's source band header (UI-6 defects D-15 + D-3): ONE
    /// row — source name and catalogue note inline on the same
    /// baseline row (the render's .band: gap 22, padding 28/18,
    /// radius 14, the flat surface2 fill with the inset stroke
    /// 1.5 over it). The "Xem tất cả ›" label is the drawing's
    /// plain cyan text (.band .all: 25 semibold, focus colour)
    /// — no capsule behind it (the old bg capsule was a
    /// system-platter defence from before .joeCardButton
    /// disabled that effect centrally); focus shows as the
    /// inside ring around the padded label, and the text stays
    /// cyan in every state, as drawn.
    private func bandHeader(name: String, note: String, scope: String) -> some View {
        HStack(alignment: .center, spacing: 22) {
            Text(name)
                .font(.system(size: 34, weight: .heavy))
                .foregroundStyle(theme.text)
            Text(note)
                .font(.system(size: 24))
                .foregroundStyle(theme.meta)
                .lineLimit(1)
            Spacer()
            Button {
                browseReturnTarget = .band(scope)
                nav.browseOpen = true
            } label: {
                Text("Xem tất cả ›")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(theme.focusTitle)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .overlay(JoeFocusRing(shape: Capsule()))
            }
            .joeCardButton()
            .focused($bandFocused, equals: scope)
            // v2.0.8 (Phase 1): NO move handler on this button.
            // The v2.0.5 bandMove handler existed because the
            // button sits at the FAR RIGHT with its rail's cards
            // at the far left — the cross-column DOWN/UP pair
            // the beam was seen to drop — but the handler owned
            // every direction and made LEFT/RIGHT declared
            // no-ops (the band row's only focusable element
            // became a trap). Movement to and from the band is
            // now the focus engine's geometric search: the rail
            // below is its own .focusSection() (the shared Rail
            // view), so DOWN/UP cross between the band row and
            // the rail by geometry, like every other region
            // pair in the app.
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .background(RoundedRectangle(cornerRadius: 14).fill(theme.surface2))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .strokeBorder(theme.stroke, lineWidth: 1.5))
    }

    // MARK: - Load states (§8)

    /// True when NO catalogue rail has anything — the C-8
    /// condition for the error surface (CW/Favourites are the
    /// owner's own data, not catalogue health). The predicate
    /// itself lives on the store (PhimStore.catalogueIsEmpty)
    /// so the poster wall's D-20 parity surfaces read the
    /// identical condition.
    private var catalogueEmpty: Bool { phim.catalogueIsEmpty }

    /// Team 4's BLOCK-2 predicate (spec-wins over the old board
    /// contract): G3 fires when the store deadline fired
    /// (loadTimedOut — possibly with jobs still in flight), OR
    /// when a load has ENDED with real provider errors on record.
    /// C-8 still applies: never while any catalogue rail has
    /// data. The attempted gate (fix-round minor) keeps the
    /// surface from flashing at cold entry, before the first
    /// load has run.
    private var showPhimError: Bool {
        attempted && catalogueEmpty
            && (phim.loadTimedOut
                || (!phim.loading && !phim.providerErrors.isEmpty))
    }

    /// §8/G5: the load ended, nothing timed out, NO provider
    /// errored, and the catalogue is still empty — every source
    /// answered empty-but-valid. Its own quiet surface: no
    /// spinner, no Retry (nothing failed, so there is nothing
    /// for a retry to fix).
    private var showPhimEmpty: Bool {
        attempted && catalogueEmpty && !phim.loading
            && !phim.loadTimedOut && phim.providerErrors.isEmpty
    }

    /// G4's failed-provider names, from the store's own error
    /// attribution: providerErrors holds an entry exactly while
    /// that provider's latest load failed (it clears when one of
    /// its rails lands). A provider that answered empty-but-valid
    /// has no entry and is correctly NOT named — the earlier
    /// rail-emptiness heuristic could not tell the two apart.
    /// The computation lives on the store (D-20 parity).
    private var failedProviders: [String] { phim.failedProviderNames }

    private func providerDisplayName(_ code: String) -> String {
        switch code {
        case "kk": return "KKPhim"
        case "f4k": return "Film4K"
        case "vsmov": return "VSMOV"
        case "tp": return "Tủ Phim"
        default: return code
        }
    }

    /// The one G3 error shape: warning icon, message, cause,
    /// Retry primary button.
    private var errorSurface: some View {
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
            // G3: the cause line carries the store's REAL captured
            // errors (providerErrors — what each provider actually
            // threw; pre-v1.9 every error was discarded by try?).
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
        .padding(.top, 30)
    }

    // MARK: - WatchStore rails

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

    // MARK: - Focus memory (v2.0.8, Phase 1)

    // The first-rail routing apparatus that lived here —
    // RailItem, phimRails, firstRailScope, setRailFocus,
    // handleFirstRailMove and bandMove — is DELETED. It existed
    // only to serve the per-card .onMoveCommand handlers and
    // the band header's .joeBoundaryMove, and an attached move
    // handler owns every direction: the presses it did not
    // declare were no-ops instead of geometric moves (the
    // single-axis trap). All rail cards are plain buttons now;
    // movement is the focus engine's geometric search over the
    // rails' .focusSection()s, and the @FocusState declarations
    // at the top of this view serve purely as focus memory for
    // the return trip.

    @ViewBuilder
    private var cwRail: some View {
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
                    .focused($focusedEntry, equals: "cw|" + entry.key)
                    .contextMenu {
                        Button(role: .destructive) {
                            watch.removeProgress(key: entry.key)
                        } label: {
                            Text("Xoá khỏi Đang xem dở")
                        }
                    }
                    // v2.0.8 (Phase 1): plain button — no move
                    // handler. This rail is the first rail
                    // whenever it renders; its cards used to carry
                    // the first-rail .onMoveCommand, now retired
                    // (see the focus-memory note above).
                }
            }
        }
    }

    @ViewBuilder
    private var favRail: some View {
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
                    .focused($focusedEntry, equals: "fav|" + entry.key)
                    .contextMenu {
                        Button(role: .destructive) {
                            watch.removeFavorite(key: entry.key)
                        } label: {
                            Text("Bỏ yêu thích")
                        }
                    }
                    // v2.0.8 (Phase 1): plain button — no move
                    // handler (the conditional first-rail handler
                    // this spot carried when Continue Watching was
                    // empty is retired; see the focus-memory note
                    // above).
                }
            }
        }
    }

    // MARK: - Catalogue rails

    private func movieRail(_ title: String, _ movies: [Movie], badges: Bool,
                           scope: String) -> some View {
        Rail(title: title) {
            ForEach(movies) { movie in
                Button { nav.movie = MovieRoute(
                    provider: movie.provider, slug: movie.slug,
                    name: movie.name, poster: movie.poster, year: movie.year) } label: {
                    PosterCard(
                        title: movie.name,
                        posterURL: movie.posterURL,
                        tmdbId: movie.tmdbId,
                        tmdbType: movie.tmdbType,
                        meta: movie.cardMeta,
                        badge: badges ? Providers.badge(movie.provider) : nil,
                        quality: movie.quality,
                        timeBadge: movie.time,
                        yearBadge: movie.year,
                        form: .rail)
                }
                .joeCardButton()
                .focused($focusedMovie, equals: scope + "|" + movie.id)
                // v2.0.8 (Phase 1): plain button — no move
                // handler on ANY catalogue rail's cards (the
                // first rail's used to carry the retired
                // first-rail handler; see the focus-memory note
                // above).
            }
        }
    }

}

// MARK: - Rail specs (file scope — shared with the poster wall)

/// One catalogue rail in on-screen order. In design F the
/// four "newest" provider rails carry a source band header;
/// the merged rail is replaced by those bands (it is their
/// aggregate). Every other shelf the app presents — chiếu
/// rạp, Việt Nam, genres, countries, per-provider series /
/// movies / anime — is present in BOTH rail designs, in the
/// 1.9.2 order. Design D's wall (JoeBrowse.swift) renders the
/// non-merged, non-genre specs of the SAME list as titled
/// wall sections (UI-6 defect D-1).
struct JoeRailSpec: Identifiable {
    let scope: String
    let title: String
    let movies: [Movie]
    let badges: Bool
    var bandName: String? = nil
    var bandNote: String? = nil
    var id: String { scope }
}

@MainActor
func joeRailSpecs(phim: PhimStore, themeID: JoeThemeID) -> [JoeRailSpec] {
    var specs: [JoeRailSpec] = []
    // Design F's cards carry BOTH badges in every rail (the
    // renders' .badge + .srcbadge — the banded rails included),
    // so every sourceBoard spec passes badges: true.
    if themeID == .sourceBoard {
        specs.append(JoeRailSpec(scope: "kkNew", title: "Mới cập nhật",
                                 movies: phim.kkNew, badges: true,
                                 bandName: "KKPhim",
                                 bandNote: "Kho phim lớn nhất · cập nhật liên tục"))
        specs.append(JoeRailSpec(scope: "f4kNew", title: "Mới cập nhật",
                                 movies: phim.f4kNew, badges: true,
                                 bandName: "Phim4K",
                                 bandNote: "Phim mới mỗi ngày"))
        specs.append(JoeRailSpec(scope: "vsNew", title: "Mới cập nhật",
                                 movies: phim.vsNew, badges: true,
                                 bandName: "VSMOV",
                                 bandNote: "Vietsub · phim bộ & phim lẻ"))
        specs.append(JoeRailSpec(scope: "tpNew", title: "Mới cập nhật",
                                 movies: phim.tpNew, badges: true,
                                 bandName: "Tủ Phim",
                                 bandNote: "Kho lưu trữ · phim chọn lọc"))
    } else {
        specs.append(JoeRailSpec(scope: "merged", title: "✨ Mới cập nhật · Tổng hợp",
                                 movies: phim.merged, badges: true))
    }
    specs.append(JoeRailSpec(scope: "chieuRap", title: "🔥 Phim chiếu rạp",
                             movies: phim.chieuRap, badges: true))
    specs.append(JoeRailSpec(scope: "vnAll", title: "🇻🇳 Phim Việt Nam",
                             movies: phim.vietnamAll, badges: true))
    specs.append(JoeRailSpec(scope: "vnSeries", title: "🇻🇳 Phim bộ Việt Nam",
                             movies: phim.vietnamSeries, badges: true))
    specs.append(JoeRailSpec(scope: "vnSingle", title: "🇻🇳 Phim lẻ Việt Nam",
                             movies: phim.vietnamSingle, badges: true))
    for spec in PhimStore.genreSpec {
        specs.append(JoeRailSpec(scope: "genre:" + spec.slug, title: spec.title,
                                 movies: phim.genreLists[spec.slug] ?? [], badges: true))
    }
    for spec in PhimStore.countrySpec {
        specs.append(JoeRailSpec(scope: "country:" + spec.slug, title: spec.title,
                                 movies: phim.countryLists[spec.slug] ?? [], badges: true))
    }
    if themeID == .sourceBoard {
        specs.append(JoeRailSpec(scope: "kkSeries", title: "📺 KKPhim · Phim bộ mới",
                                 movies: phim.kkSeries, badges: true))
        specs.append(JoeRailSpec(scope: "kkMovies", title: "🎞️ KKPhim · Phim lẻ mới",
                                 movies: phim.kkMovies, badges: true))
        specs.append(JoeRailSpec(scope: "kkAnime", title: "🐣 KKPhim · Hoạt hình",
                                 movies: phim.kkAnime, badges: true))
        specs.append(JoeRailSpec(scope: "f4kMovies", title: "🎞️ Film4K · Phim lẻ mới",
                                 movies: phim.f4kMovies, badges: true))
        specs.append(JoeRailSpec(scope: "vsSeries", title: "🎬 VSMOV · Phim bộ mới",
                                 movies: phim.vsSeries, badges: true))
        specs.append(JoeRailSpec(scope: "tpMovies", title: "📚 Tủ Phim · Phim lẻ mới",
                                 movies: phim.tpMovies, badges: true))
        specs.append(JoeRailSpec(scope: "tpSeries", title: "📚 Tủ Phim · Phim bộ mới",
                                 movies: phim.tpSeries, badges: true))
    } else {
        specs.append(JoeRailSpec(scope: "kkNew", title: "✨ Mới cập nhật",
                                 movies: phim.kkNew, badges: false))
        specs.append(JoeRailSpec(scope: "kkSeries", title: "📺 Phim bộ mới",
                                 movies: phim.kkSeries, badges: false))
        specs.append(JoeRailSpec(scope: "kkMovies", title: "🎞️ Phim lẻ mới",
                                 movies: phim.kkMovies, badges: false))
        specs.append(JoeRailSpec(scope: "kkAnime", title: "🐣 Hoạt hình",
                                 movies: phim.kkAnime, badges: false))
        specs.append(JoeRailSpec(scope: "f4kNew", title: "✨ Film4K · Mới cập nhật",
                                 movies: phim.f4kNew, badges: false))
        specs.append(JoeRailSpec(scope: "f4kMovies", title: "🎞️ Film4K · Phim lẻ mới",
                                 movies: phim.f4kMovies, badges: false))
        specs.append(JoeRailSpec(scope: "vsNew", title: "🎬 VSMOV · Mới cập nhật",
                                 movies: phim.vsNew, badges: false))
        specs.append(JoeRailSpec(scope: "vsSeries", title: "🎬 VSMOV · Phim bộ mới",
                                 movies: phim.vsSeries, badges: false))
        specs.append(JoeRailSpec(scope: "tpMovies", title: "📚 Tủ Phim · Phim lẻ mới",
                                 movies: phim.tpMovies, badges: false))
        specs.append(JoeRailSpec(scope: "tpSeries", title: "📚 Tủ Phim · Phim bộ mới",
                                 movies: phim.tpSeries, badges: false))
    }
    return specs
}

// CONVERGENCE RECORD (2026-11-15): this file's duplicated
// JoeMoveTrap struct is DELETED — see the record at the end of
// JoeTVApp.swift. The header/Retry/first-rail traps it powered
// are replaced by geometric focus movement plus the per-card
// always-installed first-rail handler above.
// v2.0.8 ADDENDUM (Phase 1): that first-rail handler is now
// ALSO deleted, with the band header's .joeBoundaryMove —
// this file carries no .onMoveCommand and no .joeBoundaryMove
// at all; movement is geometric throughout (see the
// focus-memory note at the @FocusState block).
