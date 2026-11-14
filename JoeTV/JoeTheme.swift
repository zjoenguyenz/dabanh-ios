import SwiftUI

/// Joe TV's visual language — the same family as the Android app:
/// deep indigo → violet gradient, red accent, thick white focus
/// outline, no scale-up. It shares the TV app's gradient DNA (the
/// two are sister apps) but the chrome is its own — a four-section
/// left rail and a "Joe TV" wordmark — and it is deliberately
/// UNLIKE Đá Banh tvOS (emerald, top pill tabs, crest hero) so the
/// owner can never open the wrong app by silhouette.
enum JoeTheme {
    static let accentRed = Color(red: 1.0, green: 0.27, blue: 0.23)
    static let accentViolet = Color(red: 0.62, green: 0.45, blue: 1.0)

    static var background: some View {
        LinearGradient(
            colors: [Color(red: 0.16, green: 0.12, blue: 0.52),
                     Color(red: 0.11, green: 0.08, blue: 0.38),
                     Color(red: 0.05, green: 0.04, blue: 0.20)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
    }

    /// Poster card used by every Phim/Torrent rail: 2:3 art, title
    /// under it, provider badge top-left when aggregated, progress
    /// bar at the art's bottom edge for Continue Watching tiles.
    struct PosterCard: View {
        let title: String
        let posterURL: URL?
        let meta: String
        var badge: String? = nil
        var progress: Double? = nil
        var subline: String? = nil
        let focused: Bool
        var width: CGFloat = 218

        var body: some View {
            VStack(alignment: .leading, spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.black.opacity(0.45))
                    if let posterURL {
                        AsyncImage(url: posterURL) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().scaledToFill()
                            default:
                                placeholder
                            }
                        }
                    } else {
                        placeholder
                    }
                }
                .frame(width: width, height: width * 1.5)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(focused ? Color.white : Color.white.opacity(0.10),
                                      lineWidth: focused ? 4.5 : 1.2))
                .overlay(alignment: .topLeading) {
                    if let badge {
                        Text(badge)
                            .font(.system(size: 16, weight: .heavy))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.black.opacity(0.62)))
                            .padding(9)
                    }
                }
                .overlay(alignment: .bottom) {
                    if let progress {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Rectangle().fill(Color.white.opacity(0.25))
                                Rectangle().fill(JoeTheme.accentRed)
                                    .frame(width: geo.size.width * CGFloat(min(1, max(0, progress))))
                            }
                        }
                        .frame(height: 6)
                    }
                }
                Text(title)
                    .font(.system(size: 21, weight: focused ? .semibold : .medium))
                    .foregroundStyle(focused ? .white : .white.opacity(0.78))
                    .lineLimit(1)
                    .frame(width: width, alignment: .leading)
                if let subline {
                    Text(subline)
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                        .frame(width: width, alignment: .leading)
                } else if !meta.isEmpty {
                    Text(meta)
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                        .frame(width: width, alignment: .leading)
                }
            }
        }

        private var placeholder: some View {
            Text(title)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .padding(16)
        }
    }

    /// A titled horizontal rail of poster cards.
    struct Rail<Content: View>: View {
        let title: String
        @ViewBuilder let content: () -> Content

        var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                Text(title)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 24) {
                        content()
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 4)
                }
            }
        }
    }
}
