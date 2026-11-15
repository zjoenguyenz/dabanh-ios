import SwiftUI

/// Joe TV's visual language (v1.9 rework): PURE BLACK background
/// (no gradient, no hue — see `background` below), violet accent,
/// red accent, thick VIOLET focus outline drawn by the app itself
/// on the focused element's own shape (the TV360 language with
/// the owner's override: white/pale focus styling is banned, and
/// the system focus effect is disabled on every focusable). The
/// chrome is a top bar — the real "Joe TV" wordmark plus four
/// section pills — over full-bleed section content, and it is
/// deliberately UNLIKE Đá Banh tvOS (emerald, crest hero) so the
/// owner can never open the wrong app by silhouette.

/// The app's own focus ring, drawn over a button's label. The
/// system focus effect is disabled app-wide (on this tvOS it
/// washed a huge white halo over every focused element and made
/// white labels unreadable — the owner's v1.1 verdict), so every
/// focusable element must show focus itself. A Button propagates
/// its focus state to its label through the environment, which is
/// what this view reads.
struct JoeFocusRing<S: InsettableShape>: View {
    @Environment(\.isFocused) private var isFocused
    let shape: S
    var lineWidth: CGFloat = 4

    var body: some View {
        shape.strokeBorder(isFocused ? JoeTheme.focusViolet : Color.clear,
                           lineWidth: isFocused ? lineWidth : 0)
    }
}

enum JoeTheme {
    static let accentRed = Color(red: 1.0, green: 0.27, blue: 0.23)
    static let accentViolet = Color(red: 0.62, green: 0.45, blue: 1.0)
    /// The one focus-outline colour app-wide (lighter violet).
    static let focusViolet = Color(red: 0.72, green: 0.58, blue: 1.0)
    /// §3 token `surface`: the sanctioned fill for cards, tiles,
    /// fields and primary-action chrome at REST (unfocused,
    /// unselected) — white @ 0.07 over the black background.
    /// Translucent accent fills at rest (the old accentViolet
    /// at 45% opacity) are banned by the spec.
    static let surface = Color.white.opacity(0.07)
    /// §3 token `okGreen` (#30D158): positive-status colour —
    /// diagnostics pass dots, "configured / saved" status text,
    /// the playable-stream tag. (Spec §3 named it for the
    /// diagnostics dot; Team 4's pre-build gate extended it to
    /// every positive-status use so no raw `.green` remains.)
    static let okGreen = Color(red: 0.19, green: 0.82, blue: 0.35)

    /// v1.9: SOLID PURE BLACK — no gradient, no stops. The v1.8
    /// "Apple black" gradient still carried a hue: its stops
    /// (#0B0B0D / #1B1B20 family) have blue ≈ 1.18× red/green,
    /// and the owner's panel amplified that single hue until
    /// the whole screen photographed bright BLUE, brightest
    /// exactly where the gradient peaked (his photo,
    /// 2026-11-14). Pure black has no hue for any display
    /// chain to amplify — the worst it can render is grey.
    /// Never reintroduce unequal-channel "blacks" here.
    static var background: some View {
        Color.black.ignoresSafeArea()
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
        var width: CGFloat = 240

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
                .overlay(alignment: .topLeading) {
                    if let badge {
                        Text(badge)
                            .font(.system(size: 23, weight: .heavy))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color.black.opacity(0.65)))
                            .padding(10)
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
                    .font(.system(size: 25, weight: focused ? .semibold : .medium))
                    .foregroundStyle(focused ? JoeTheme.focusViolet : .white)
                    .lineLimit(1)
                    .frame(width: width, alignment: .leading)
                if let subline {
                    Text(subline)
                        .font(.system(size: 23))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                        .frame(width: width, alignment: .leading)
                } else if !meta.isEmpty {
                    Text(meta)
                        .font(.system(size: 23))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                        .frame(width: width, alignment: .leading)
                }
            }
            .padding(12)
            // F3: focus treatment is outline + scale ONLY — the
            // old focus drop shadow is removed (spec §5 F3 and
            // acceptance item 12: no focus-only shadow anywhere).
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.white.opacity(0.07))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(focused ? JoeTheme.focusViolet : Color.white.opacity(0.10),
                                          lineWidth: focused ? 4 : 2)))
            .scaleEffect(focused ? 1.05 : 1.0)
        }

        private var placeholder: some View {
            Text(title)
                .font(.system(size: 23, weight: .semibold))
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
            VStack(alignment: .leading, spacing: 16) {
                Text(title)
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 28) {
                        content()
                    }
                    .padding(.vertical, 16)
                    .padding(.horizontal, 4)
                }
            }
        }
    }
}
