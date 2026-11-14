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
/// Every pill now uses .buttonStyle(.card) with a label fully
/// backed by its own solid capsule, exactly like Đá Banh.
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
            Text("Joe TV v1.4")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.4))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var wordmark: some View {
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
            // The label's own solid capsule is what keeps the
            // text readable under the .card focus treatment —
            // exactly like Đá Banh's tealFill selected pill.
            .background(Capsule().fill(selected ? JoeTheme.accentViolet
                                       : Color.white.opacity(0.08)))
            .overlay(Capsule().strokeBorder(focused ? Color.white : Color.clear,
                                            lineWidth: 2.5))
        }
        .buttonStyle(.card)
        .focused($focusedSection, equals: s)
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
