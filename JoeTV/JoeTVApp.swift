import SwiftUI

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
        URLCache.shared = URLCache(memoryCapacity: 64 * 1024 * 1024,
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
    /// The shell's four sections. Moved here from JoeRootView
    /// in 1.9.2 (Team 9 item 4): the section views themselves
    /// must be able to send the shell back to Phim (their Menu
    /// handlers set section = .phim), so the state lives on
    /// the navigator they all already observe.
    enum Section: String, CaseIterable {
        case tv, phim, torrent, settings

        var title: String {
            switch self {
            case .tv: return "TV"
            case .phim: return "Phim"
            case .torrent: return "Phim Torrent"
            case .settings: return "Cài đặt"
            }
        }
        var icon: String {
            switch self {
            case .tv: return "tv"
            case .phim: return "film"
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
/// four section pills + version) on top, content filling the rest
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
    @EnvironmentObject private var watch: WatchStore
    /// v2.0.0 (UI-5): the active design, chosen in Settings'
    /// "Giao diện" row. Default = F Bảng Nguồn (the UI-1 system).
    @AppStorage("joeThemeID") private var themeIDRaw = JoeThemeID.sourceBoard.rawValue
    /// v2.0.5 (N2): the pill row's own focus identity — the
    /// five pills (four sections + Tìm phim) as one declared
    /// order, so LEFT/RIGHT can chain arithmetically across
    /// the Spacer void in front of Tìm phim (error 6: the
    /// void defeated the focus engine's beam and stranded
    /// the owner on that pill). A plain @FocusState on the
    /// row, written only by the pills' own always-installed
    /// move handler and by the engine itself — the grids'
    /// device-proven shape, NOT the removed v1.5 hub (no
    /// other view reads it, no structure depends on it).
    @FocusState private var pillFocus: String?

    private var theme: ThemeTokens {
        ThemeTokens.tokens(for: JoeThemeID(rawValue: themeIDRaw) ?? .sourceBoard)
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
            .disabled(nav.movie != nil || nav.tor != nil)
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
        }
        .onChange(of: nav.section) { _, _ in
            // S1.1: see the note above `body` — search must
            // not outlive the Phim section. The v2.0.0 browse
            // layer follows the same rule.
            if nav.searchOpen { nav.searchOpen = false }
            if nav.browseOpen { nav.browseOpen = false }
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
        .task {
            // UI-5 pipeline: warm the owner's own posters at
            // launch (Continue Watching + favourites render from
            // the decoded cache on cold open, no network wait).
            let entries = watch.progress() + watch.favorites()
            JoeImagePipeline.shared.prefetch(
                entries.compactMap { $0.posterURL }, targetPixels: 720)
        }
        .environment(\.joeTheme, theme)
        .environmentObject(nav)
        // CONSTRUCTION LAW (v2.0.5, N4 — supersedes the v2.0.0
        // absolute ban that stood here): NO .scaleEffect
        // anywhere in the target, and the system card focus
        // effect is disabled in exactly ONE place — centrally,
        // inside .joeCardButton() (JoeTheme.swift), the only
        // button construction the target uses. The v2.0.0 ban
        // on .focusEffectDisabled rested on the 1.9.2 slab
        // defect, whose mechanism was a BARE-TEXT label leaving
        // the system platter exposed; that precondition no
        // longer holds — every label in the target paints one
        // full shape and draws its own JoeFocusRing — so the
        // platter is now pure harm (owner errors 1+2: its
        // scale + outset shadow stacked over the app ring,
        // clipped card text and shoved chips off their rows).
        // Per-site .focusEffectDisabled remains banned: the
        // disablement lives in the shared modifier or nowhere.
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
            HStack(alignment: .center, spacing: 26) {
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
                .joeBoundaryMove(
                    up: { pillMove(.up, from: "search") },
                    down: { pillMove(.down, from: "search") },
                    left: { pillMove(.left, from: "search") },
                    right: { pillMove(.right, from: "search") })
                Text("Joe TV v\(Self.appVersion)")
                    .font(.system(size: 23))
                    .foregroundStyle(theme.meta)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(height: 76)
            .focusSection()
        }
    }

    /// The pill row's declared order, left to right, in BOTH
    /// bar variants (design D renders the same five controls
    /// as text links at the bar's right; the order is the
    /// same). LEFT/RIGHT chain arithmetically over this list.
    private static let pillOrder = ["tv", "phim", "torrent",
                                    "settings", "search"]

    /// The pill row's move handler (v2.0.5, N2 — error 6).
    /// Installed on every pill via the shared joeBoundaryMove
    /// construction, so it owns every direction:
    ///  - LEFT/RIGHT: arithmetic over pillOrder. This is the
    ///    void crossing: LEFT from Tìm phim and RIGHT from
    ///    Cài đặt step over the Spacer gap by declaration,
    ///    where the engine's beam dropped both presses.
    ///  - UP: a defined no-op — the bar is the screen's top
    ///    edge; nothing exists above it.
    ///  - DOWN: the declared landing into the active section.
    ///    The handler cannot write the section's own focus
    ///    state (each section owns its @FocusState), so it
    ///    RESIGNS the row's focus instead: with the press
    ///    answered, the engine re-resolves focus into the
    ///    content focus section, whose active section root
    ///    declares its top element via .defaultFocus
    ///    (JoeTVSection's first group chip, JoePhimHome's
    ///    hero play / header browse button, JoeTorrentHome's
    ///    search field, JoeSettingsView's first theme chip,
    ///    JoeSearchView's field while search is open) — that
    ///    declaration is the landing. The reciprocal UP out
    ///    of a section's top elements is the same section
    ///    mechanism in reverse (the bar is the neighbouring
    ///    focus section), served by each section's own UP
    ///    handlers where they exist (first-rail → header,
    ///    grid → chips) and by section-guided geometry for
    ///    the last hop, which is a full-width row directly
    ///    above the content — the reliable geometric case.
    private func pillMove(_ direction: MoveCommandDirection, from id: String) {
        switch direction {
        case .left:
            if let i = Self.pillOrder.firstIndex(of: id), i > 0 {
                pillFocus = Self.pillOrder[i - 1]
            }
        case .right:
            if let i = Self.pillOrder.firstIndex(of: id),
               i + 1 < Self.pillOrder.count {
                pillFocus = Self.pillOrder[i + 1]
            }
        case .down:
            pillFocus = nil
        case .up:
            break
        @unknown default:
            break
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
        .joeBoundaryMove(
            up: { pillMove(.up, from: id) },
            down: { pillMove(.down, from: id) },
            left: { pillMove(.left, from: id) },
            right: { pillMove(.right, from: id) })
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
    /// v2.0.5 (N2/N4): two measured changes on top of that
    /// base. The style is .joeCardButton() — the card style
    /// with the system focus effect disabled centrally (the
    /// label paints the full capsule and draws the app's ring,
    /// so the platter is never needed and never shows). And
    /// the row carries a plain @FocusState + an always-
    /// installed arithmetic move handler after all: pure
    /// geometry device-failed on this shell (error 6 — the
    /// Tìm phim void and the Settings DOWN dead end), and the
    /// handler is the grids' own device-proven shape (a local
    /// binding written only by the row's handler and the
    /// engine; nothing's structure depends on it). See
    /// pillMove for the four declared exits.
    private func sectionPill(_ s: JoeNavigator.Section) -> some View {
        Button {
            nav.section = s
        } label: {
            PillLabel(title: s.title, icon: s.icon, selected: nav.section == s)
        }
        .joeCardButton()
        .focused($pillFocus, equals: s.rawValue)
        .joeBoundaryMove(
            up: { pillMove(.up, from: s.rawValue) },
            down: { pillMove(.down, from: s.rawValue) },
            left: { pillMove(.left, from: s.rawValue) },
            right: { pillMove(.right, from: s.rawValue) })
    }

    @ViewBuilder
    private var content: some View {
        switch nav.section {
        case .tv:
            JoeTVSection()
        case .phim:
            JoePhimHome()
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
        .foregroundStyle((selected || isFocused) ? theme.onAccent : theme.text.opacity(0.85))
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
        .background(Capsule().fill(selected || isFocused ? theme.accent : theme.surface2))
        .overlay(JoeFocusRing(shape: Capsule()))
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
            .font(.system(size: 27, weight: selected ? .bold : .medium))
            .foregroundStyle(isFocused ? theme.focus
                             : (selected ? theme.text : theme.meta))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(theme.bg)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(selected ? theme.focus : .clear)
                    .frame(height: 4)
                    .padding(.horizontal, 18)
            }
            // v2.0.6 (Team Ring): band outset like every
            // focus ring (width still a constant 3 — only the
            // colour changes with focus, as before).
            .overlay(RoundedRectangle(cornerRadius: 8)
                .joeOutsetStrokeBorder(isFocused ? theme.focus : .clear, lineWidth: 3))
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
