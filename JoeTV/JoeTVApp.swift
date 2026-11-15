import SwiftUI

/// v1.5 focus outline colour (lighter violet) — the style law's
/// focus stroke on every focusable element in this file.
private let joeFocusViolet = Color(red: 0.72, green: 0.58, blue: 1.0)

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
        // Warm the segment-cleaning proxy so its loopback port is
        // ready long before the first play tap.
        JoeProxy.shared.start()
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
    @Published var movie: MovieRoute?
    @Published var tor: TorRoute?
    @Published var searchOpen = false

    /// v1.5 focus hub: explicit, guaranteed focus routing between
    /// the shell's pill row and the visible section. A section (or
    /// the search view) calls requestFocus(.pills) to escape
    /// upward; the shell calls requestFocus(.sectionTop) on pill
    /// DOWN and the visible section lands focus on its own first
    /// element. focusNonce increments on EVERY request so repeated
    /// requests to the same target still fire .onChange.
    enum JoeFocusTarget { case pills, sectionTop }
    @Published var focusTarget: JoeFocusTarget?
    @Published var focusNonce = 0
    func requestFocus(_ target: JoeFocusTarget) {
        focusTarget = target
        focusNonce &+= 1
    }

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
/// the system focus effect washed a pale halo over focused rail
/// rows despite .buttonStyle(.plain)+.focusEffectDisabled().
/// v1.5: pills use .buttonStyle(.plain) and draw focus themselves
/// (violet fill + lighter-violet outline + scale) — .card's pale
/// focus card washed titles out in the owner's v1.4 videos and is
/// banned. Focus routing between pills and sections is explicit
/// through the JoeNavigator focus hub, never left to geometry.
struct JoeRootView: View {
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

    @State private var section: Section = .phim
    @FocusState private var focusedSection: Section?
    @StateObject private var nav = JoeNavigator()

    var body: some View {
        ZStack {
            JoeTheme.background
            VStack(spacing: 24) {
                topBar
                    .modifier(JoeMoveTrap(enabled: focusedSection != nil) { direction in
                        pillMove(direction)
                    })
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, 56)
            .padding(.top, 34)
            .padding(.bottom, 24)
            .disabled(nav.movie != nil || nav.tor != nil)
            if let route = nav.movie {
                ZStack {
                    JoeTheme.background
                    JoeMovieDetail(route: route)
                }
                .transition(.opacity)
                .zIndex(2)
            }
            if let route = nav.tor {
                ZStack {
                    JoeTheme.background
                    JoeTorrentDetail(route: route)
                }
                .transition(.opacity)
                .zIndex(3)
            }
        }
        .environmentObject(nav)
        // v1.8: the "no system focus effect" law was previously
        // only a comment — .focusEffectDisabled was never actually
        // applied anywhere, so on the owner's Apple TV the system
        // washed a huge pale card over the focused pill (his photo,
        // 2026-11-14). Applied ONCE here, it covers the whole
        // hierarchy: pills, sections, search and both detail layers.
        .focusEffectDisabled(true)
        .onChange(of: nav.focusNonce) { _, _ in
            // Hub consumer (shell side): a section escaping upward
            // lands focus back on the CURRENT section's pill.
            if nav.focusTarget == .pills {
                focusedSection = section
            }
        }
        .modifier(JoeExitTrap(enabled: nav.movie != nil || nav.tor != nil
                                       || nav.searchOpen) {
            _ = nav.closeTop()
        })
    }

    // The top row stays well under ~1,800pt wide on purpose
    // (Đá Banh lesson: an over-wide row crushes its trailing
    // buttons until the focus engine cannot land on them) —
    // every pill label is .lineLimit(1) + .fixedSize so it can
    // never be squeezed.
    private var topBar: some View {
        HStack(alignment: .center, spacing: 28) {
            wordmark
            ForEach(Section.allCases, id: \.self) { s in
                sectionPill(s)
            }
            Spacer()
            Text("Joe TV v1.8")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.4))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
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

    private func sectionPill(_ s: Section) -> some View {
        let selected = section == s
        let focused = focusedSection == s
        return Button {
            section = s
        } label: {
            HStack(spacing: 10) {
                Image(systemName: s.icon)
                    .font(.system(size: 24, weight: .medium))
                Text(s.title)
                    .font(.system(size: 24, weight: selected ? .bold : .medium))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle((selected || focused) ? .white : .white.opacity(0.85))
            .padding(.horizontal, 26)
            .padding(.vertical, 12)
            // v1.5 style law: .plain draws NO system focus effect,
            // so focus is drawn here and only here — the violet
            // fill on the pill's own dark capsule keeps the white
            // text readable; a focused pill adds the lighter-violet
            // outline and a slight scale. No pale card, no white
            // ring (both banned after the v1.4 videos).
            .background(Capsule().fill(selected ? JoeTheme.accentViolet
                                       : (focused ? JoeTheme.accentViolet
                                                  : Color.white.opacity(0.08))))
            .overlay(Capsule().strokeBorder(focused ? joeFocusViolet : Color.clear,
                                            lineWidth: 2.5))
            .scaleEffect(focused ? 1.06 : 1.0)
        }
        .buttonStyle(.plain)
        .focused($focusedSection, equals: s)
    }

    /// Guaranteed pill-row routing (v1.5 hub): the topBar move
    /// trap is enabled ONLY while a pill holds focus, and every
    /// direction has a defined outcome — LEFT/RIGHT walk the
    /// CaseIterable order arithmetically (no-op at the ends),
    /// DOWN hands off to the visible section through the hub,
    /// UP is a defined no-op (the pills are the top screen edge).
    /// Pills still change section only on select-press.
    private func pillMove(_ direction: MoveCommandDirection) {
        guard let current = focusedSection,
              let idx = Section.allCases.firstIndex(of: current) else { return }
        switch direction {
        case .left:
            if idx > 0 { focusedSection = Section.allCases[idx - 1] }
        case .right:
            if idx + 1 < Section.allCases.count {
                focusedSection = Section.allCases[idx + 1]
            }
        case .down:
            nav.requestFocus(.sectionTop)
        case .up:
            break
        @unknown default:
            break
        }
    }

    @ViewBuilder
    private var content: some View {
        switch section {
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

/// Installs the root Menu handler ONLY while a layer is open.
/// With no handler installed, Menu at the section roots keeps
/// its system behaviour (exit the app) — the trap must never
/// swallow that press.
private struct JoeExitTrap: ViewModifier {
    let enabled: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.onExitCommand(perform: action)
        } else {
            content
        }
    }
}

/// Conditional move trap, same shape as JoeExitTrap: the move
/// handler exists ONLY while `enabled`. A trap is enabled only
/// while focus sits on a boundary element, and while enabled its
/// handler must give ALL FOUR directions a defined outcome
/// (forced target, arithmetic neighbour, or explicit no-op at a
/// screen edge) — never swallow a direction silently.
private struct JoeMoveTrap: ViewModifier {
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
