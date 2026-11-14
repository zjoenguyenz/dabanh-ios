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

/// The shell: Joe TV's own left rail (wordmark + four sections),
/// content swapping on the right. The rail never collapses — the
/// Android app's rail is permanent too, and a stable silhouette is
/// what keeps this app unmistakable next to Đá Banh.
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
            HStack(spacing: 0) {
                rail
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
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

    private var rail: some View {
        VStack(alignment: .leading, spacing: 0) {
            wordmark
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Section.allCases, id: \.self) { s in
                    railRow(s)
                }
            }
            Spacer()
            Text("Joe TV v1.3")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.4))
                .padding(.leading, 12)
        }
        .padding(.horizontal, 16)
        .padding(.top, 44)
        .padding(.bottom, 30)
        .frame(width: 300)
        .frame(maxHeight: .infinity)
        .background(Color.black.opacity(0.30))
    }

    private var wordmark: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text("Joe TV")
                .font(.system(size: 36, weight: .heavy))
                .foregroundStyle(.white)
            Text(".")
                .font(.system(size: 36, weight: .heavy))
                .foregroundStyle(JoeTheme.accentRed)
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.leading, 12)
        .padding(.bottom, 30)
    }

    private func railRow(_ s: Section) -> some View {
        let selected = section == s
        let focused = focusedSection == s
        return Button {
            section = s
        } label: {
            HStack(spacing: 14) {
                Image(systemName: s.icon)
                    .font(.system(size: 24, weight: .medium))
                    .frame(width: 40)
                Text(s.title)
                    .font(.system(size: 25, weight: (selected || focused) ? .bold : .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(focused ? .white
                             : (selected ? JoeTheme.accentRed : .white.opacity(0.82)))
            .padding(.vertical, 12)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 13)
                    .fill(focused ? JoeTheme.accentViolet
                          : (selected ? Color.white.opacity(0.06) : Color.clear)))
            .overlay(
                RoundedRectangle(cornerRadius: 13)
                    .strokeBorder(focused ? Color.white : Color.clear, lineWidth: 2.5))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
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
