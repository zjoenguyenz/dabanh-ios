import SwiftUI
import Darwin

/// Joe TV for Apple TV — one app for live TV, the aggregated Phim
/// library (KKPhim + Film4K + VSMOV + Tủ Phim) and the debrid
/// Torrent section. v1.1 reaches parity with the Android app the
/// owner verified on his Sony (v1.9.2): Tủ Phim Gold + CacheVideo
/// joined the library, and PNG-disguised streams play through the
/// in-app cleaning proxy (JoeProxy). Bundle com.luun.nguyen.joetv.
@main
struct JoeTVApp: App {
    @StateObject private var tvStore = TVStore()
    @StateObject private var watchStore = WatchStore()
    @StateObject private var phimStore = PhimStore()
    @StateObject private var torStore = TorHomeStore()

    init() {
        // Posters come from slow overseas CDNs; give the shared
        // URL cache real room so rails stop repainting blank art
        // on every scroll and section switch.
        //
        // v2.0.8 (Phase 7 — cache budget): the memory capacity
        // is no longer a flat 64 MB picked without reference to
        // the box. The floor box (owner decision) is the Apple
        // TV 4K 1st gen (A10X, 3 GB RAM). Apple publishes NO
        // per-app memory ceiling for that box — the real ceiling
        // is device-measured-later — so the budget is derived
        // at runtime from what the OS says this process may
        // still use: one thirty-second of
        // os_proc_available_memory(), clamped to
        // [16 MB, 64 MB] (the old flat value survives as the
        // ceiling, never exceeded; the 16 MB floor keeps the
        // cache useful even if the probe reads low). The disk
        // capacity stays 512 MB: the tvOS disk cache is
        // purgeable under pressure, so it holds no resident
        // memory and needs no derivation.
        let availableMemory = Int(os_proc_available_memory())
        let memoryCapacity = min(64 * 1024 * 1024,
                                 max(16 * 1024 * 1024, availableMemory / 32))
        URLCache.shared = URLCache(memoryCapacity: memoryCapacity,
                                   diskCapacity: 512 * 1024 * 1024,
                                   diskPath: "joetv-images")
        // CONVERGENCE (Team 7 D7, 2026-11-15): the proxy is NOT
        // warmed here any more. JoeProxy.start() binds a
        // loopback port and starts a socket pump on a background
        // queue during application init; Đá Banh TV — the proven
        // app on the owner's box — has no equivalent launch
        // work. The proxy already starts lazily at the first
        // play tap (JoeProxy.playlistURL / resolveForPlayback),
        // so nothing is lost by removing the warm start.
    }

    var body: some Scene {
        WindowGroup {
            JoeRootView()
                .environmentObject(tvStore)
                .environmentObject(watchStore)
                .environmentObject(phimStore)
                .environmentObject(torStore)
        }
    }
}

/// App-wide navigation state for the two detail pages. v1.1 pushed
/// details through NavigationStacks nested inside the shell's
/// sections; with focus resting on the rail, the Menu button fell
/// through to the system and EXITED THE APP from a detail page
/// (the owner's video, 2026-11-14). v1.2 presents details as
/// full-screen layers of the root view instead, and the root's
/// exit command closes exactly one layer per Menu press.
final class JoeNavigator: ObservableObject {
    /// The shell's five sections. Moved here from JoeRootView
    /// in 1.9.2 (Team 9 item 4): the section views themselves
    /// must be able to send the shell back to Phim (their Menu
    /// handlers set section = .phim), so the state lives on
    /// the navigator they all already observe.
    enum Section: String, CaseIterable {
        case tv, phim, tvb, torrent, settings

        var title: String {
            switch self {
            case .tv: return "TV"
            case .phim: return "Phim"
            case .tvb: return "TVB"
            case .torrent: return "Phim Torrent"
            case .settings: return "Cài đặt"
            }
        }
        var icon: String {
            switch self {
            case .tv: return "tv"
            case .phim: return "film"
            case .tvb: return "play.tv"
            case .torrent: return "magnet"
            case .settings: return "gearshape"
            }
        }
    }

    @Published var section: Section = .phim
    @Published var movie: MovieRoute?
    @Published var tor: TorRoute?
    @Published var searchOpen = false
    /// v2.0.5 (N3): the shell root's Menu delivery channel.
    /// Menu pressed while focus sits on a shell pill reaches
    /// JoeRootView's exit handler (the topBar is OUTSIDE the
    /// Phim subtree, so JoePhimHome's handler is not an
    /// ancestor of the focused pill and can never see the
    /// press). When the state machine has walked every layer
    /// home and only the exit confirmation remains, the root
    /// sets this flag; JoePhimHome — the owner of the ONE
    /// exit confirmation — observes it and presents its own
    /// alert. The root routes; it never presents a second
    /// confirmation.
    @Published var exitRequested = false
    /// v2.0.0 (UI-5): the browse/grid layer inside the Phim
    /// section (genre filter). Like searchOpen it lives inside
    /// JoePhimHome's tree; the Phim root's exit handler closes
    /// it before offering the exit confirmation.
    @Published var browseOpen = false

    // CONVERGENCE (Team 7 D4/D5, 2026-11-15): the v1.5 focus hub
    // (focusTarget / focusNonce / requestFocus) is REMOVED. It
    // was the write side of the convicted feedback loop: hub
    // requests landed in @FocusState properties whose flips
    // installed and uninstalled the conditional move/exit
    // traps, changing the view tree's identity under the focus
    // engine. Focus routing is geometric again — the Đá Banh TV
    // construction (pills directly above content, plain Buttons,
    // no programmatic focus writes on the launch path).
    // v2.0.5 (N1/N2): geometry ALONE proved insufficient on
    // this shell (the owner's error 5/6: off-column presses
    // dropped, the Tìm phim pill a dead end). Routing is now
    // geometric + DECLARED: static .focusSection() regions,
    // per-section .defaultFocus landings, and always-installed
    // arithmetic handlers on the elements whose exits are
    // writable in their own view (the pill row, the detail
    // blocks, the grids). The hub stays removed — no central
    // focus target, no nonce, and still no structure anywhere
    // depends on a focus value (law D4).
    // v2.0.8 (Phase 1) SUPERSESSION for THIS shell and the Phim
    // home: the pill row's arithmetic handlers are RETIRED, as
    // are the Phim home's first-rail and band handlers — an
    // attached .onMoveCommand owns every direction and
    // swallows the rest, which is the single-axis trap itself.
    // Routing here is geometric over the declared
    // .focusSection()s, with .defaultFocus kept strictly as an
    // ENTRY policy (the pill row's entry is the pill the user
    // left — see the pillFocus note in JoeRootView). The hub
    // stays removed and law D4 stands unchanged.

    /// Close the topmost layer; returns false when nothing is
    /// open (the caller then lets the system have the press).
    func closeTop() -> Bool {
        if movie != nil { movie = nil; return true }
        if tor != nil { tor = nil; return true }
        if searchOpen { searchOpen = false; return true }
        return false
    }
}

/// The shell (v1.4 rework): a single VStack — topBar (wordmark +
/// five section pills + version) on top, content filling the rest
/// below. This mirrors the proven Đá Banh tvOS geometry (pills
/// directly above content) so focus flows DOWN into the content
/// and UP back to the pills by construction. v1.3's left rail is
/// gone: with the rail, focus could not move from the rail into
/// the TV section's channels or the Settings fields at all, and
/// the system card focus effect washed a pale halo over the
/// focused rail rows. (v2.0.5 note: an earlier draft of this
/// comment claimed the effect was already disabled on those
/// buttons — it never was; the halo WAS the enabled effect.
/// The effect is disabled for real only now, centrally, by
/// .joeCardButton() in JoeTheme.swift.)
/// v1.5: pills draw focus themselves (violet fill +
/// lighter-violet outline + scale) — .card's pale focus card
/// washed titles out in the owner's v1.4 videos and is banned.
/// CONVERGENCE (Team 7, 2026-11-15): v1.9's answer to the pale
/// blob — .focusable() non-Button pills, a @FocusState hub, and
/// conditional move/exit traps that installed and uninstalled
/// themselves as focus moved — is CONVICTED as the freeze/crash
/// mechanism on the owner's tvOS (the trap bodies switched the
/// view structure on @FocusState values the focus engine itself
/// writes: focus lands → trap flips → subtree identity changes
/// → teardown/rebuild → focus re-resolves → can flip again).
/// The pills are real Buttons again (.joeCardButton(), the
/// Đá Banh TV construction) with the app-drawn look kept via a
/// label that reads its own focus from the environment and
/// the system focus effect disabled on the Button itself;
/// routing between pills and sections is geometric.
///
/// MENU SEMANTICS (1.9.2, Team 9 item 4 — G-EXIT REDEFINED by
/// the owner's explicit order, mirroring the Android app):
/// Back walks INSIDE the app, one layer per press, and exits
/// only from the Phim root. Every handler is UNCONDITIONAL
/// and lives on the root of the view that owns the focus:
/// the player cover (JoePlayerView), the search layer
/// (JoeSearchView), the two detail views (JoeMovieDetail /
/// JoeTorrentDetail — moved INTO them in 1.9.2; the wrapper
/// handlers that used to sit on the ZStack layers below were
/// device-proven NOT to intercept), and the three non-Phim
/// section roots (JoeTVSection / JoeTorrentHome /
/// JoeSettingsView — Menu there returns to the Phim section).
/// v2.0.0 (UI-5): JoePhimHome now carries the eighth handler —
/// at the Phim root a Menu press first closes the browse layer
/// when it is open, otherwise presents the exit confirmation
/// ("Thoát Joe TV?" / "Ở lại" / "Thoát" → exit(0)), per UI-1's
/// spec. Inner Back levels are unchanged.
/// v2.0.5 (N3): a NINTH handler, on JoeRootView itself, covers
/// the one focus position none of the eight could reach — a
/// shell pill (the topBar is outside every section subtree).
/// It runs the same state machine (layers → Phim → the ONE
/// confirmation, the last step delegated back to JoePhimHome
/// via nav.exitRequested); nearer handlers keep precedence,
/// so one press still closes exactly one layer.
struct JoeRootView: View {
    @StateObject private var nav = JoeNavigator()
    /// v2.0.22: the launch gate (see LaunchGate below) — the
    /// root shows its loading screen until the gate's real
    /// work (connection check → catalogue → poster preload)
    /// completes, then hands over to the shell.
    @StateObject private var launchGate = LaunchGate()
    @EnvironmentObject private var watch: WatchStore
    /// v2.0.10 (Package B): the Top Shelf writer resolves its
    /// hot list against the catalogue, so the root also reads
    /// the Phim store (already injected at the App level).
    @EnvironmentObject private var phim: PhimStore
    /// v2.0.0 (UI-5): the active design, chosen in Settings'
    /// "Giao diện" row. Default = F Bảng Nguồn (the UI-1 system).
    @AppStorage("joeThemeID") private var themeIDRaw = JoeThemeID.ultra.rawValue
    /// v2.0.19: one-time landing on Ultra — the owner's Apple
    /// TV already carries a stored picker choice from an older
    /// build, which would otherwise win over the new default
    /// and hide this release's design behind a Settings hunt.
    /// The flag flips once; any later picker choice stands.
    @AppStorage("joeThemeUltraV2019") private var ultraMigrated = false
    /// The pill row's focus identity — the six pills (five
    /// sections + Tìm phim) share this one @FocusState, written
    /// ONLY by the focus engine itself.
    ///
    /// v2.0.5 (N2) history: this state also fed an arithmetic
    /// move handler (pillMove, installed on every pill via
    /// .joeBoundaryMove) that chained LEFT/RIGHT over a
    /// declared order across the Spacer void in front of Tìm
    /// phim, and whose DOWN branch RESIGNED this state
    /// (pillFocus = nil) and trusted the content section's
    /// .defaultFocus to land somewhere — the resign-and-pray
    /// trap (audit T-C4).
    ///
    /// v2.0.8 (Phase 1): the handler is RETIRED and this state's
    /// job is now focus MEMORY. LEFT/RIGHT along the row and
    /// DOWN into the content are the engine's geometric moves
    /// between the bar's .focusSection() and the content's
    /// .focusSection(). Because a @FocusState reads nil while
    /// focus sits outside its bindings, the memory itself is
    /// kept in `lastFocusedPill` below (recorded by an
    /// always-installed .onChange observer — it changes no
    /// structure, so law D4 is untouched), and the top bar
    /// declares its entry landing with
    /// .defaultFocus($pillFocus, lastFocusedPill ??
    /// nav.section.rawValue): focus returning UP into the bar
    /// lands on the pill the user LEFT — or, before any pill
    /// was ever focused, on the CURRENT section's pill — never
    /// a fixed first pill.
    @FocusState private var pillFocus: String?
    /// v2.0.8 (Phase 1): the last pill that actually held
    /// focus — the pill row's focus memory (see the pillFocus
    /// note above). Written only by the .onChange observer in
    /// `body`; read only by the top bar's .defaultFocus entry
    /// declaration. No view's structure depends on it.
    @State private var lastFocusedPill: String?

    private var theme: ThemeTokens {
        ThemeTokens.tokens(for: JoeThemeID(rawValue: themeIDRaw) ?? .ultra)
    }

    /// The corner version label reads the REAL bundle version
    /// (CFBundleShortVersionString, stamped from project.yml
    /// at build time) — never a hardcoded string. Forensics
    /// 2026-11-15: the label was frozen at "v2.0.0" through
    /// the whole v2.0.1 round, so the owner's defect photos
    /// could not establish which build his TV was running.
    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    /// S1.1 (freeze audit, 2026-11-15): search lives INSIDE the
    /// Phim section's view. If the owner opened search, escaped
    /// UP to the pills and selected another section, searchOpen
    /// stayed true while no search was on screen — and an exit
    /// handler keyed on it stayed armed, so the next Menu press
    /// was eaten closing an invisible "layer" instead of
    /// exiting the app. Leaving the Phim section now always
    /// closes search, so searchOpen == true implies the search
    /// is actually visible.

    var body: some View {
        ZStack {
            theme.bg.ignoresSafeArea()
            // §4 (DESIGN-SPEC-V19): the tvOS safe area IS the
            // HIG inset (80 pt sides, 60 pt top/bottom) — the
            // content container respects it and adds NO further
            // padding, so the total inset is exactly 80/60 and
            // never stacks (the old manual 56/34/24 did stack).
            VStack(spacing: 32) {
                topBar
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // v2.0.5 (N1): the content is ONE declared
                    // focus region under the bar's own region —
                    // pill ↔ section movement is section-to-
                    // section navigation, and each section's
                    // .defaultFocus declaration (its top
                    // element) is the landing the engine picks
                    // inside this region.
                    .focusSection()
            }
            .disabled(nav.movie != nil || nav.tor != nil || !launchGate.finished)
            if let route = nav.movie {
                ZStack {
                    theme.bg.ignoresSafeArea()
                    JoeMovieDetail(route: route)
                }
                // 1.9.2 (Team 9 item 4): NO exit handler on
                // this wrapper any more. The 1.9.1 wrapper
                // handler was desk-verified as an ancestor of
                // the focused view and device-proved NOT to
                // intercept — Menu exited the app from the
                // detail (the second time a cross-subtree
                // placement failed this way; v1.1's
                // NavigationStack did the same). The handler
                // now lives on JoeMovieDetail's OWN root, the
                // placement the player's handler device-proves.
                .transition(.opacity)
                .zIndex(2)
            }
            if let route = nav.tor {
                ZStack {
                    theme.bg.ignoresSafeArea()
                    JoeTorrentDetail(route: route)
                }
                // Same move as the movie layer above: the
                // handler lives on JoeTorrentDetail's own root.
                .transition(.opacity)
                .zIndex(3)
            }
            // v2.0.22: the launch loading screen — above the
            // shell, below nothing else; it has no focusable
            // elements and the shell beneath it is disabled
            // while it is up (see the .disabled above), so a
            // launch can never take input meant for the home.
            if !launchGate.finished {
                LaunchLoadingView(progress: launchGate.progress)
                    .zIndex(10)
            }
        }
        .onAppear {
            if !ultraMigrated {
                themeIDRaw = JoeThemeID.ultra.rawValue
                ultraMigrated = true
            }
        }
        .onChange(of: nav.section) { _, _ in
            // S1.1: see the note above `body` — search must
            // not outlive the Phim section. The v2.0.0 browse
            // layer follows the same rule.
            if nav.searchOpen { nav.searchOpen = false }
            if nav.browseOpen { nav.browseOpen = false }
        }
        .onChange(of: pillFocus) { _, focused in
            // v2.0.8 (Phase 1): the pill row's focus-memory
            // recorder (see the pillFocus note). Only landings
            // are recorded — the nil the state reads while
            // focus sits in the content must not erase the
            // memory. This observer changes no structure; it
            // feeds only the top bar's .defaultFocus value.
            if let focused { lastFocusedPill = focused }
        }
        .onChange(of: watch.progressEntries) { _, _ in
            // v2.0.10 (Package B): the Top Shelf payload
            // mirrors Continue Watching — rebuild it whenever
            // the CW store changes (forced; the launch refresh
            // in .task below is the throttled one).
            Task {
                await JoeTopShelfWriter.refresh(
                    watch: watch, phim: phim, force: true)
            }
        }
        // v2.0.5 (N2 item 3 + N3): the ROOT exit handler — the
        // shell state machine, always installed. Exit commands
        // travel to the NEAREST handler above the focused
        // view, so every press inside a section, a detail, the
        // search layer or the player is still consumed by that
        // view's own nearer handler exactly as before (one
        // press, one layer). This root handler only ever sees
        // the presses no nearer handler claimed — above all,
        // Menu pressed while focus sits on a SHELL PILL: the
        // topBar is a sibling of the content, outside every
        // section subtree, so pre-fix those presses fell
        // through to the system and exited the app with no
        // confirmation and no walk home (error 6's Back
        // chain). The machine mirrors the app's layer order:
        // close the topmost layer, else walk to the Phim
        // section, else — already home — hand the press to
        // JoePhimHome's ONE exit confirmation via
        // nav.exitRequested (the root never presents its own).
        .onExitCommand {
            if nav.movie != nil {
                nav.movie = nil
            } else if nav.tor != nil {
                nav.tor = nil
            } else if nav.searchOpen {
                nav.searchOpen = false
            } else if nav.browseOpen {
                nav.browseOpen = false
            } else if nav.section != .phim {
                nav.section = .phim
            } else {
                nav.exitRequested = true
            }
        }
        // v2.0.10 (Package B): Top Shelf deep links (joetv://,
        // written by JoeTopShelfWriter) land here — nav is this
        // view's @StateObject, so the routes below are built in
        // scope. An additive handler: nothing else in the shell
        // consumes URLs.
        .onOpenURL { url in handleDeepLink(url) }
        .task {
            // v2.0.22: the launch gate runs FIRST (connection
            // check → catalogue → poster preload behind the
            // loading screen). Idempotent — its own `started`
            // flag makes repeat .task firings no-ops.
            launchGate.run(phim: phim, watch: watch, nav: nav)
            // UI-5 pipeline: warm the owner's own posters at
            // launch (Continue Watching + favourites render from
            // the decoded cache on cold open, no network wait).
            let entries = watch.progress() + watch.favorites()
            JoeImagePipeline.shared.prefetch(
                entries.compactMap { $0.posterURL }, targetPixels: 720)
            // v2.0.10 (Package B): refresh the Top Shelf
            // payload (App Group hand-off; throttled inside
            // the writer, fail-soft when the group container
            // is unavailable under the owner's signing).
            await JoeTopShelfWriter.refresh(watch: watch, phim: phim)
        }
        .task {
            // Idea 7: the app-open hooks (episode re-check +
            // match-reminder revalidation — see appOpenHooks()
            // below). A SEPARATE .task from the launch gate's
            // above: it starts only once this root view has
            // appeared, runs BESIDE the gate — never inside it,
            // never awaited by it — and neither the gate's
            // overlay nor the first paint waits on it. It
            // fires once per app session: JoeRootView is
            // created once by the WindowGroup and lives for
            // the whole session, and a section switch only
            // swaps its `content`, so this task does NOT
            // re-run on a tab switch.
            await appOpenHooks()
        }
        .environment(\.joeTheme, theme)
        .environmentObject(nav)
        // CONSTRUCTION LAW (v2.0.8 — supersedes the v2.0.5 N4
        // text that stood here): NO .scaleEffect anywhere in
        // the target. Buttons are built by ONE shared
        // construction (.joeCardButton() in JoeTheme.swift),
        // which installs a custom ButtonStyle defined centrally
        // in JoeTheme.swift — the system .card style and its
        // platter are GONE, so no system focus treatment exists
        // to stack over the app's drawn rings. The
        // .focusEffectDisabled disablement lives in the shared
        // constructions and nowhere else: inside that shared
        // button modifier AND inside the shared field chrome
        // (both in JoeTheme.swift), so a text field's drawn
        // outset ring is likewise the sole treatment on fields.
        // Per-site .focusEffectDisabled remains banned: the
        // disablement lives in the shared constructions or
        // nowhere. (The v2.0.5 text claimed the disablement
        // lived in exactly ONE place, .joeCardButton() alone,
        // back when .card still supplied the button style —
        // both halves of that sentence stopped being true in
        // the v2.0.8 programme; do not let it mislead the next
        // round.)
    }

    // The top row stays well under ~1,800pt wide on purpose
    // (Đá Banh lesson: an over-wide row crushes its trailing
    // buttons until the focus engine cannot land on them) —
    // every pill label is .lineLimit(1) + .fixedSize so it can
    // never be squeezed.
    //
    // v2.0.0 (UI-5): the bar follows the active design — A and F
    // keep the pill row (token colours; A renders approved the
    // pills translucent over the hero, but the shell geometry is
    // the device-proven pills-above-content, so the hero starts
    // below the bar and the pills take A's surface token), D
    // replaces the pills with text links (its system verbatim).
    // Both variants carry a "Tìm phim" control into the Phim
    // search layer.
    @ViewBuilder
    private var topBar: some View {
        if theme.id == .posterWall {
            // Design .topbar gap: 20 (all three drawings).
            HStack(alignment: .center, spacing: 20) {
                wordmark
                Spacer()
                ForEach(JoeNavigator.Section.allCases, id: \.self) { s in
                    topLink(s.title, id: s.rawValue, selected: nav.section == s) {
                        nav.section = s
                    }
                }
                topLink("Tìm phim", id: "search", selected: false) { openSearch() }
            }
            .frame(height: 76)
            // v2.0.5 (N1): the bar is a declared focus region,
            // the content below it the other — pill ↔ section
            // movement is section-to-section navigation.
            .focusSection()
            // v2.0.8 (Phase 1): the bar's ENTRY landing — the
            // pill the user left (lastFocusedPill), else the
            // current section's pill; never a fixed first pill.
            // An entry policy only: it steers no directional
            // movement (the sections do that).
            .defaultFocus($pillFocus, lastFocusedPill ?? nav.section.rawValue)
        } else {
            HStack(alignment: .center, spacing: 20) {
                wordmark
                ForEach(JoeNavigator.Section.allCases, id: \.self) { s in
                    sectionPill(s)
                }
                Spacer()
                Button { openSearch() } label: {
                    PillLabel(title: "Tìm phim", icon: "magnifyingglass", selected: false)
                }
                .joeCardButton()
                .focused($pillFocus, equals: "search")
                // v2.0.8 (Phase 1): plain button — the pillMove
                // handler that owned this pill's four directions
                // (and resigned focus on DOWN) is retired; see
                // the pillFocus note.
                Text("Joe TV v\(Self.appVersion)")
                    .font(.system(size: 23))
                    .foregroundStyle(theme.meta)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(height: 76)
            .focusSection()
            // v2.0.8 (Phase 1): the bar's ENTRY landing — the
            // pill the user left (lastFocusedPill), else the
            // current section's pill; never a fixed first pill.
            // An entry policy only: it steers no directional
            // movement (the sections do that).
            .defaultFocus($pillFocus, lastFocusedPill ?? nav.section.rawValue)
        }
    }

    // v2.0.8 (Phase 1): pillOrder and pillMove — the pill row's
    // declared order and its arithmetic move handler — are
    // DELETED from here. The handler owned every direction on
    // every pill (LEFT/RIGHT arithmetic over the order, UP a
    // declared no-op, DOWN a resign of pillFocus that trusted
    // the content's .defaultFocus to land somewhere — the
    // resign-and-pray trap, audit T-C4). The pills are plain
    // buttons in the bar's .focusSection() now: the engine's
    // geometric search moves along the row and down into the
    // content's .focusSection(), and the bar's entry landing
    // is declared by .defaultFocus on the bar itself (see the
    // pillFocus note in this view).

    /// Top Shelf deep links (joetv://), written by
    /// JoeTopShelfWriter. Parsing is fail-soft: a malformed
    /// link opens nothing, exactly like a cold launch.
    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "joetv",
              let c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return }
        let q = Dictionary(uniqueKeysWithValues:
            (c.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        switch c.host {
        case "tmdb":
            // v2.0.11: Top Shelf FALLBACK links. When the App
            // Group hand-off is unavailable under the owner's
            // signing, the extension builds hero/hot itself
            // from TMDB trending and can only name titles by
            // TMDB id (it has no catalogue access) — resolve
            // the id against the app's own catalogue here, the
            // same match the writer performs. The link can
            // cold-launch the app before the catalogue has
            // loaded, so the lookup waits (bounded) instead of
            // failing soft on an empty store.
            guard let tmdbId = q["id"], !tmdbId.isEmpty else { return }
            let type = q["type"] ?? ""
            nav.section = .phim
            Task { @MainActor in
                for _ in 0..<40 {
                    if let m = phim.merged.first(where: {
                        $0.tmdbId == tmdbId &&
                        (type.isEmpty || $0.tmdbType.isEmpty
                         || $0.tmdbType == type)
                    }) {
                        nav.movie = MovieRoute(
                            provider: m.provider, slug: m.slug,
                            name: m.name, poster: m.poster,
                            year: m.year, preselectEp: "")
                        return
                    }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        case "movie":
            guard let provider = q["provider"], let slug = q["slug"],
                  !provider.isEmpty, !slug.isEmpty else { return }
            nav.section = .phim
            nav.movie = MovieRoute(provider: provider, slug: slug,
                                   name: q["name"] ?? "",
                                   poster: q["poster"] ?? "",
                                   year: q["year"] ?? "",
                                   preselectEp: q["ep"] ?? "")
        case "torrent":
            guard let metaId = q["id"], !metaId.isEmpty else { return }
            var meta = TorMeta()
            meta.id = metaId
            meta.type = q["type"] ?? "movie"
            meta.name = q["name"] ?? ""
            meta.poster = q["poster"] ?? ""
            meta.background = q["background"] ?? ""
            meta.year = q["year"] ?? ""
            meta.desc = q["desc"] ?? ""
            nav.section = .torrent
            nav.tor = TorRoute(meta: meta, base: q["base"] ?? "",
                               preselectStreamId: q["stream"] ?? "")
        default:
            return
        }
    }

    /// Idea 7 — the app-open hooks: fresh-data checks that
    /// run ONLY when the app is opened (driven by the root
    /// view's own .task in `body` above). There is no
    /// background refresh anywhere in this feature: nothing
    /// here runs while the app is closed or suspended, and
    /// no timer re-runs it — the next check happens at the
    /// next app open. Both halves are fail-soft: a dead
    /// network leaves the stored follow / reminder state
    /// exactly as it was.
    private func appOpenHooks() async {
        // (a) Episode re-check: one detail fetch per followed
        // title, all in flight together in a task group; a
        // failed fetch is silent (try?) and leaves that
        // title's stored count untouched. The stores are
        // @MainActor, so the snapshot and each apply hop back
        // to the main actor; the network waits happen off it.
        let followed = await MainActor.run { FollowStore.shared.followed }
        if !followed.isEmpty {
            await withTaskGroup(of: Void.self) { group in
                for title in followed {
                    group.addTask {
                        guard let detail = try? await Providers.detail(
                            title.provider, slug: title.slug)
                        else { return }
                        let count = FollowStore.episodeCount(
                            from: detail.movie.episodeCurrent)
                        await MainActor.run {
                            FollowStore.shared.applyEpisodeCheck(
                                provider: title.provider, slug: title.slug,
                                currentEpisodes: count)
                        }
                    }
                }
            }
        }
        // (b) Match-reminder revalidation, after the episode
        // checks: the fixture list comes from the SAME entry
        // point the Thể Thao Torrent tab loads with
        // (TorrentClient.fetchSportsEvents — the Nuvio →
        // MediaFusion → StremVerse chain, first non-empty
        // wins, fail-soft to an empty list). TorMeta carries
        // no kickoff field, so a fixture's kickoff is read
        // from its title with the target's own KickoffParser
        // (the "HH:MM DD/MM" stamp); fixtures whose title
        // has no parseable kickoff are skipped.
        let result = await TorrentClient.fetchSportsEvents()
        let matches: [(key: String, title: String, kickoff: Date)] =
            result.metas.compactMap { meta in
                guard let kickoff = KickoffParser.parse(from: meta.name)
                else { return nil }
                return (key: MatchReminderStore.matchKey(forTitle: meta.name),
                        title: meta.name, kickoff: kickoff)
            }
        await MainActor.run {
            MatchReminderStore.shared.revalidate(matches: matches)
        }
    }

    /// Open the Phim search layer from any section. When the
    /// section changes in the same action, the search flag is
    /// set on the next main-actor turn — after the root's
    /// section-change consumer (S1.1) has run — so the layer
    /// opens instead of being closed by that rule.
    private func openSearch() {
        if nav.section == .phim {
            nav.searchOpen = true
        } else {
            nav.section = .phim
            Task { @MainActor in nav.searchOpen = true }
        }
    }

    private func topLink(_ title: String, id: String, selected: Bool,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            TopLinkLabel(title: title, selected: selected)
        }
        .joeCardButton()
        .focused($pillFocus, equals: id)
        // v2.0.8 (Phase 1): plain button — no move handler (see
        // the pillFocus note).
    }

    /// v1.8: the real Joe TV wordmark (the approved master, the
    /// same art the Android app carries) replaces the plain text
    /// wordmark, per the owner-approved design render. Falls back
    /// to the text wordmark if the image asset is ever missing.
    @ViewBuilder
    private var wordmark: some View {
        if UIImage(named: "LogoWordmark") != nil {
            Image("LogoWordmark")
                .resizable()
                .scaledToFit()
                .frame(height: 54)
                .accessibilityLabel("Joe TV")
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("Joe TV")
                    .font(.system(size: 34, weight: .heavy))
                    .foregroundStyle(.white)
                Text(".")
                    .font(.system(size: 34, weight: .heavy))
                    .foregroundStyle(JoeTheme.accentRed)
            }
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    /// CONVERGENCE (Team 7 item 2 — the middle path, 2026-11-15):
    /// the pills are real Buttons again, exactly the Đá Banh TV
    /// TVContentView construction — Button + card style,
    /// selection in the action, no .onTapGesture, no hub write
    /// on focus.
    /// v2.0.0 (UI-5): the label's look is theme-tokenised; no
    /// scale on focus (construction law).
    /// v2.0.5 (N2/N4): the style is .joeCardButton() (v2.0.8:
    /// the custom ButtonStyle installed centrally by that
    /// construction — see the CONSTRUCTION LAW in `body`). The
    /// row also carried a plain @FocusState + an always-
    /// installed arithmetic move handler (pillMove): pure
    /// geometry had device-failed on this shell (error 6 — the
    /// Tìm phim void and the Settings DOWN dead end).
    /// v2.0.8 (Phase 1): that handler is RETIRED — it owned
    /// every direction on every pill and its DOWN branch
    /// resigned focus (the T-C4 trap). The pills are plain
    /// Buttons in the bar's .focusSection(); movement along
    /// the row and into the content is the engine's geometric
    /// search between the two sections, and @FocusState
    /// pillFocus remains only as the focus-memory record
    /// behind the bar's .defaultFocus entry declaration (see
    /// the pillFocus note).
    private func sectionPill(_ s: JoeNavigator.Section) -> some View {
        Button {
            nav.section = s
        } label: {
            PillLabel(title: s.title, icon: s.icon, selected: nav.section == s)
        }
        .joeCardButton()
        .focused($pillFocus, equals: s.rawValue)
        // v2.0.8 (Phase 1): plain button — no move handler (see
        // the pillFocus note).
    }

    @ViewBuilder
    private var content: some View {
        switch nav.section {
        case .tv:
            JoeTVSection()
        case .phim:
            JoePhimHome()
        case .tvb:
            JoeTVBView()
        case .torrent:
            JoeTorrentHome()
        case .settings:
            JoeSettingsView()
        }
    }
}

/// The pill's label (convergence, Team 7 item 2): reads its OWN
/// focus state from the environment — the focus engine writes
/// `isFocused` into a focused view's subtree as a pure rendering
/// input; the label branches on it only to pick colours INSIDE
/// one stable view, writes nothing back, and no view's structure
/// depends on it. v2.0.0 (UI-5): theme tokens — selected or
/// focused wears the theme accent fill, focus adds the theme
/// ring; NO scale (construction law).
private struct PillLabel: View {
    let title: String
    let icon: String
    let selected: Bool
    @Environment(\.isFocused) private var isFocused
    @Environment(\.joeTheme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .medium))
            Text(title)
                .font(.system(size: 29, weight: (selected || isFocused) ? .semibold : .medium))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        // Design .pill: 29px medium (semibold when selected or
        // focused), padding 15px 30px; the accent fill belongs
        // to the SELECTED state only — a focused-but-unselected
        // pill keeps the surface2 fill and shows the inside ring
        // + semibold text at full text colour. The resting
        // state carries the drawing's inset stroke (1.5
        // theme.stroke; the selected fill replaces it —
        // box-shadow: none), so the ring is an explicit
        // strokeBorder in the JoeChipLabel form, not
        // JoeFocusRing (which paints clear at rest).
        .foregroundStyle(selected ? theme.onAccent : theme.text)
        .padding(.horizontal, 30)
        .padding(.vertical, 15)
        .background(Capsule().fill(selected ? theme.accent : theme.surface2))
        .overlay(Capsule().strokeBorder(
            isFocused
                ? (theme.id == .posterWall && selected
                   ? Color.white : theme.focus)
                : (selected ? .clear : theme.stroke),
            lineWidth: isFocused ? theme.ringWidth : 1.5))
    }
}

/// Design D's top-bar link (UI-4 spec verbatim): plain text —
/// selected is bold with the yellow underline bar, focused is
/// yellow text with a 3 pt inset ring. Values only, one shape.
/// UI-6 defect D-3: the label PAINTS its full frame with the
/// theme foundation — a bare-text .card label leaves the
/// system focus platter exposed behind the text (the 1.9.2
/// slab mechanism); the foundation paint is the same recipe
/// PosterCard.wallBody uses.
private struct TopLinkLabel: View {
    let title: String
    let selected: Bool
    @Environment(\.isFocused) private var isFocused
    @Environment(\.joeTheme) private var theme

    var body: some View {
        Text(title)
            .font(.system(size: 27, weight: (selected || isFocused) ? .bold : .medium))
            .foregroundStyle(isFocused ? theme.focus
                             : (selected ? theme.text : theme.meta))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(theme.bg)
            // Design .toplink.sel: box-shadow inset 0 -4px 0 —
            // the underline spans the link's FULL width (the
            // whole padded box), not just the text.
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(selected ? theme.focus : .clear)
                    .frame(height: 4)
            }
            // Design .toplink.focused: box-shadow inset 0 0 0
            // 3px #FFD60A, border-radius 8 — the ring is INSIDE
            // the link's bounds. (The v2.0.6 outset band is
            // retired here; width stays a constant 3 — only the
            // colour changes with focus, as before.)
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isFocused ? theme.focus : .clear, lineWidth: 3))
    }
}

// CONVERGENCE RECORD (2026-11-15): JoeMoveTrap and JoeExitTrap
// — the conditional ViewModifiers whose bodies switched between
// `content` and `content.onMoveCommand/.onExitCommand` on an
// `enabled` flag fed by @FocusState — are DELETED, here and in
// every file that duplicated them (JoePhimHome, JoeTorrent,
// JoeSearch, JoeSettings, JoeTVSection). Team 7 convicted that
// shape (D4) as the launch freeze/crash mechanism: every
// `enabled` input was a value the focus engine itself writes,
// so a focus landing could install/uninstall a handler over a
// whole subtree, change its identity, force a rebuild, and
// re-resolve focus — a feedback loop on the main thread that
// needs no remote input to start. The routing the traps
// provided is preserved by construction instead: geometric
// focus movement between plain focusable elements (the Đá
// Banh TV pattern), per-element .onMoveCommand handlers that
// are ALWAYS installed on the specific cards that need
// arithmetic routing, and unconditional .onExitCommand
// handlers attached to the detail/search layers themselves.
// Team 4 gate going forward: NO @FocusState-driven conditional
// view modifier anywhere in this target.
// v2.0.8 ADDENDUM (Phase 1): the always-installed per-element
// handlers this record preserved are retired on THIS file's
// surface — the pill row's .joeBoundaryMove/pillMove is
// deleted; the pills are plain buttons whose movement is
// geometric between the bar's and the content's
// .focusSection()s, with .defaultFocus as the bar's entry
// policy only (see the pillFocus note in JoeRootView).

// MARK: - Launch gate (v2.0.22)

/// The launch sequence (owner order 2026-11-17 — the Ultra
/// launch pattern he specified from the Phim4K reference and
/// had built into the Sony app the same evening): at app
/// open the app FIRST establishes its connections, THEN
/// loads the catalogue, THEN preloads the home's posters —
/// and the home is entered ready. Idea 17: the loading
/// screen now covers only the first two phases — the gate
/// completes at the end of the data phase and the shell
/// goes interactive — while the poster preload continues
/// as a detached background task behind it (same list, same
/// 80 cap, same pipeline). Phase 1 and phase 2 also no
/// longer fetch the same four "newest" endpoints twice:
/// the probe's fresh Providers responses land in the
/// Providers raw memo and phase 2's store jobs read them
/// back (see Providers.fetchListRaw / fetchListRawFresh).
/// It exists because of the 2.0.21 cold-start disease
/// he reported verbatim: posters hung at first open until he
/// went into Settings and pressed the connection check
/// himself, after which they loaded. The check he pressed is
/// SourceProbe.run (the Settings "Kiểm tra ngay" diagnostics
/// — the providers exercised through the SAME client calls
/// the home makes); the gate runs exactly that check
/// automatically as phase 1, so no manual step remains.
///
/// Progress is REAL, by the phase model the owner approved
/// on the Sony build: while the gate is visible the bar
/// keeps its original scale — fixed phase weights (probe
/// 0–10, data 10–30) and, inside each phase, the measured
/// fraction (probes answered of four, "newest" rails landed
/// of four). At gate completion finish() fills the bar to
/// 1.0 exactly as it always has at handover, so the fill
/// stays monotonic and never re-scales mid-gate. The poster
/// preload that used to own 30–100 now runs detached in
/// the background and publishes no progress. No animation,
/// no timer-driven creep: the loading view sets the fill
/// width straight from `progress` with no .animation
/// anywhere.
///
/// Bounds: a hard 50 s cap ends the gate whatever state the
/// phases are in (the home's own error surfaces own a dead
/// network from there — the bar can never spin forever);
/// a Top Shelf deep link ends it at once (a link launch
/// must land on its route, not on a loading screen — and
/// skips the background preload too); the screen dwells at
/// least 0.7 s so a fully cached launch does not flash it
/// for a single frame.
@MainActor
final class LaunchGate: ObservableObject {
    @Published private(set) var progress: Double = 0
    @Published private(set) var finished = false
    private var started = false

    func run(phim: PhimStore, watch: WatchStore, nav: JoeNavigator) {
        if started { return }
        started = true
        Task { await execute(phim: phim, watch: watch, nav: nav) }
    }

    private func execute(phim: PhimStore, watch: WatchStore,
                         nav: JoeNavigator) async {
        let t0 = Date()
        let hardCap: TimeInterval = 50
        func overCap() -> Bool { Date().timeIntervalSince(t0) > hardCap }
        func deepLinked() -> Bool { nav.movie != nil || nav.tor != nil }

        // Phase 1 — the connection check (0 → 0.10): the
        // Settings diagnostics run, automatic. The probe runs
        // detached; each provider's answer increments the
        // box, and this loop publishes the answered fraction.
        let probeBox = LaunchProgressBox()
        let probeTask = Task.detached {
            _ = await SourceProbe.run { _ in probeBox.increment() }
        }
        while probeBox.count < 4, !overCap(), !deepLinked() {
            progress = 0.10 * Double(probeBox.count) / 4
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        probeTask.cancel()
        if deepLinked() { await finish(t0: t0); return }
        progress = max(progress, 0.10)

        // Phase 2 — catalogue data (0.10 → 0.30): the store's
        // own load (cache-first, staged, deadline-bounded —
        // unchanged). The phase ends on the FIRST data (the
        // home can paint) or when the load itself ends; the
        // fraction inside the phase is the landed count of
        // the four "newest" rails that head the home.
        phim.loadIfNeeded()
        while !overCap(), !deepLinked() {
            let landed = [phim.kkNew, phim.f4kNew, phim.vsNew, phim.tpNew]
                .filter { !$0.isEmpty }.count
            progress = 0.10 + 0.20 * Double(landed) / 4
            if phim.hasData || !phim.loading { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if deepLinked() { await finish(t0: t0); return }
        progress = max(progress, 0.30)

        // Phase 3 — poster preload (Idea 17): NO LONGER PART
        // OF THE VISIBLE GATE. The gate completes HERE, at
        // the end of phase 2 — finish() below enforces the
        // minimum dwell, fills the bar to 1.0 and lifts the
        // screen, exactly the handover contract finish() has
        // always had — and the preload continues as a
        // DETACHED background task that runs to completion
        // behind the interactive shell: the same deduped
        // list (preloadTargets), the same 80 cap, the same
        // six-worker pool feeding the same image pipeline
        // (runPosterPreload). A deep link still skips the
        // preload entirely, as it always has.
        let targets = preloadTargets(phim: phim, watch: watch)
        if !targets.isEmpty && !deepLinked() {
            Task.detached {
                await LaunchGate.runPosterPreload(targets: targets)
            }
        }
        await finish(t0: t0)
    }

    /// The phase-3 preload list, built exactly as the gated
    /// phase 3 built it: every poster of the home as it will
    /// first render — the owner's rails, then the catalogue
    /// rails in home order, then the genre/country shelves —
    /// deduped, capped at 80, plus the featured film's hero
    /// thumb.
    private func preloadTargets(phim: PhimStore, watch: WatchStore) -> [URL] {
        var urls: [URL] = []
        var seen = Set<String>()
        func add(_ u: URL?) {
            guard let u, seen.insert(u.absoluteString).inserted
            else { return }
            urls.append(u)
        }
        for e in watch.progress() + watch.favorites() { add(e.posterURL) }
        let railsInOrder: [[Movie]] = [
            phim.merged, phim.chieuRap, phim.vietnamAll,
            phim.kkNew, phim.kkSeries, phim.kkMovies, phim.kkAnime,
            phim.f4kNew, phim.f4kMovies, phim.vsNew, phim.vsSeries,
            phim.tpNew, phim.tpMovies, phim.tpSeries]
        for rail in railsInOrder {
            for m in rail { add(m.posterURL) }
        }
        for spec in PhimStore.genreSpec {
            for m in phim.genreLists[spec.slug] ?? [] { add(m.posterURL) }
        }
        for spec in PhimStore.countrySpec {
            for m in phim.countryLists[spec.slug] ?? [] { add(m.posterURL) }
        }
        if let featured = (phim.merged + phim.kkNew)
            .first(where: { !$0.thumb.isEmpty }) {
            add(featured.thumbURL)
        }
        return Array(urls.prefix(80))
    }

    /// The phase-3 worker pool, unchanged from the gated
    /// phase 3: six workers pull from a shared claim counter;
    /// each awaited pipeline load (hit or miss) is one
    /// completion. It now runs detached behind the shell, so
    /// its completions feed only the image pipeline's cache
    /// — never the gate's progress — and nothing cancels it:
    /// it runs to completion. nonisolated: it is called from
    /// a detached task and must keep the old pool's off-actor
    /// execution, not hop back onto the gate's main actor.
    nonisolated private static func runPosterPreload(targets: [URL]) async {
        let posterBox = LaunchProgressBox()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    while let i = posterBox.claim(total: targets.count) {
                        _ = await JoeImagePipeline.shared.image(
                            for: targets[i], targetPixels: 720)
                        posterBox.increment()
                    }
                }
            }
        }
    }

    /// Handover: enforce the minimum dwell, then the bar
    /// reads full and the screen lifts. The shell's content
    /// was live beneath the screen the whole time (disabled),
    /// so the lift is a pure overlay removal — no view is
    /// rebuilt and no focus state is disturbed.
    private func finish(t0: Date) async {
        let remaining = 0.7 - Date().timeIntervalSince(t0)
        if remaining > 0 {
            try? await Task.sleep(
                nanoseconds: UInt64(remaining * 1_000_000_000))
        }
        progress = 1
        finished = true
    }
}

/// Lock-guarded counters shared between the launch gate's
/// detached workers and its main-actor publisher (the
/// codebase's box pattern — PhimLoadBox, KKProbeBox): the
/// workers never touch the published progress directly.
private final class LaunchProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var counted = 0
    private var claimed = 0

    func increment() {
        lock.lock()
        counted += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return counted
    }

    /// Claim the next work index, or nil when the list is
    /// drained — each index is claimed exactly once.
    func claim(total: Int) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        if claimed >= total { return nil }
        let i = claimed
        claimed += 1
        return i
    }
}

/// The launch loading screen (owner spec, verbatim): ONLY
/// the big Joe TV wordmark and one slim cyan loading bar on
/// a glossy black ground — no text, no other UI, and NO
/// animation of any kind: the fill width is the gate's real
/// progress value, set directly.
private struct LaunchLoadingView: View {
    let progress: Double

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.075, green: 0.075, blue: 0.08),
                         .black],
                startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 56) {
                if UIImage(named: "LogoWordmark") != nil {
                    Image("LogoWordmark")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 150)
                        .accessibilityLabel("Joe TV")
                } else {
                    Text("Joe TV")
                        .font(.system(size: 84, weight: .heavy))
                        .foregroundStyle(.white)
                }
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.14))
                    Capsule()
                        .fill(LinearGradient(colors: [
                            Color(red: 0.0, green: 0.533, blue: 0.639),
                            Color(red: 0.0, green: 0.898, blue: 1.0),
                            Color(red: 0.49, green: 0.957, blue: 1.0)
                        ], startPoint: .leading, endPoint: .trailing))
                        .frame(width: 560 * CGFloat(min(max(progress, 0), 1)))
                }
                .frame(width: 560, height: 10)
            }
        }
    }
}
