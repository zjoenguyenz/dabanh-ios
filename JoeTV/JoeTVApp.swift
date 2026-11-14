import SwiftUI

/// Joe TV for Apple TV — one app for live TV, the aggregated Phim
/// library (KKPhim + Film4K + VSMOV) and the debrid Torrent
/// section, mirroring the Android app the owner verified on his
/// Sony (v1.5.1). Bundle com.luun.nguyen.joetv.
@main
struct JoeTVApp: App {
    @StateObject private var tvStore = TVStore()
    @StateObject private var watchStore = WatchStore()

    var body: some Scene {
        WindowGroup {
            JoeRootView()
                .environmentObject(tvStore)
                .environmentObject(watchStore)
        }
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

    var body: some View {
        ZStack {
            JoeTheme.background
            HStack(spacing: 0) {
                rail
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
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
            Text("Joe TV v1.0")
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
                    .font(.system(size: 25, weight: selected ? .bold : .medium))
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
                    .fill(focused ? Color.white.opacity(0.12)
                          : (selected ? Color.white.opacity(0.06) : Color.clear)))
            .overlay(
                RoundedRectangle(cornerRadius: 13)
                    .strokeBorder(focused ? Color.white : Color.clear, lineWidth: 2.5))
        }
        .buttonStyle(.plain)
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
