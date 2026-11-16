import SwiftUI

// MARK: - Joe TV v2.0.0 theme system (Team UI-5)
//
// Three structural designs chosen by the owner (UI-4 pack, 2026-11-15):
//   A Billboard   — Netflix structure, crimson system (old theme 2)
//   D Poster Wall — hi-contrast system verbatim (old theme 7): yellow on black
//   F Source Board— UI-1 green system verbatim (old theme 1), the default
//
// One ThemeTokens value is injected at the root via the environment; every
// leaf component reads it. The data layer (stores, providers, WatchStore,
// navigator) is theme-blind and untouched. Switching the theme swaps the
// Phim home / browse / detail / search compositions; the Settings tree keeps
// one stable structure so focus survives the switch on the theme chips.

enum JoeThemeID: String, CaseIterable {
    case billboard
    case posterWall
    case sourceBoard

    var pickerLabel: String {
        switch self {
        case .billboard: return "Billboard"
        case .posterWall: return "Tường Poster"
        case .sourceBoard: return "Bảng Nguồn"
        }
    }
}

struct ThemeTokens {
    let id: JoeThemeID
    // Foundations
    let bg: Color
    let surfaceTop: Color          // card face gradient, top stop
    let surfaceBottom: Color       // card face gradient, bottom stop
    let surface2: Color            // rest fill: pills, chips, secondary buttons
    let stroke: Color              // rest stroke
    // Accents
    let accent: Color              // selected fill
    let accent2: Color             // primary action fill
    let onAccent: Color            // text on accent / accent2
    let focus: Color               // focus ring + focused affordances
    let focusTitle: Color          // focused card title colour
    // Text
    let text: Color
    let meta: Color
    let heroMeta: Color
    // Badges (on art)
    let badgeBg: Color
    let badgeText: Color
    // Geometry
    let rCard: CGFloat
    let rField: CGFloat
    let artInset: CGFloat          // card face padding around the art
    let cardArtW: CGFloat          // poster art width inside a card
    let railGap: CGFloat
    let ringWidth: CGFloat
    let cardTitleSize: CGFloat
    let cardMetaSize: CGFloat
    // Design A only: guaranteed minimum scrim alpha under hero/detail text
    // (UI-3 hard note — worst-case contrast never depends on the backdrop).
    let scrimFloor: Double

    var surfaceGradient: LinearGradient {
        LinearGradient(colors: [surfaceTop, surfaceBottom],
                       startPoint: .top, endPoint: .bottom)
    }
    var cardWidth: CGFloat { cardArtW + artInset * 2 }
    var cardArtH: CGFloat { cardArtW * 1.5 }

    // Light-by-design fields — identical in all three themes (UI-1 law).
    static let fieldBg = Color(red: 0.961, green: 0.961, blue: 0.969)      // #F5F5F7
    static let fieldText = Color(red: 0.078, green: 0.078, blue: 0.086)    // #141416
    static let fieldPlaceholder = Color(red: 0.431, green: 0.431, blue: 0.451) // #6E6E73
    /// Field text size (UI-6 defect D-22): the renders' fields
    /// are 31 pt — every TextField/SecureField site uses this.
    static let fieldTextSize: CGFloat = 31

    static let billboard = ThemeTokens(
        id: .billboard,
        bg: Color(red: 0.039, green: 0.039, blue: 0.039),                  // #0A0A0A
        surfaceTop: Color(red: 0.137, green: 0.137, blue: 0.137),          // #232323
        surfaceBottom: Color(red: 0.090, green: 0.090, blue: 0.090),       // #171717
        surface2: Color(red: 0.110, green: 0.110, blue: 0.110),            // #1C1C1C
        stroke: Color.white.opacity(0.14),
        accent: Color(red: 0.702, green: 0.071, blue: 0.180),              // #B3122E
        accent2: Color(red: 0.851, green: 0.137, blue: 0.180),             // #D9232E
        onAccent: .white,
        focus: .white,
        focusTitle: .white,
        text: .white,
        meta: Color(red: 0.659, green: 0.659, blue: 0.659),                // #A8A8A8
        heroMeta: Color(red: 0.910, green: 0.910, blue: 0.910),            // #E8E8E8
        badgeBg: Color.black.opacity(0.70),
        badgeText: .white,
        rCard: 10, rField: 10, artInset: 10, cardArtW: 240, railGap: 26,
        ringWidth: 4, cardTitleSize: 25, cardMetaSize: 23,
        scrimFloor: 0.55)

    static let posterWall = ThemeTokens(
        id: .posterWall,
        bg: .black,
        surfaceTop: Color(red: 0.102, green: 0.102, blue: 0.102),          // #1A1A1A
        surfaceBottom: Color(red: 0.102, green: 0.102, blue: 0.102),
        surface2: Color(red: 0.102, green: 0.102, blue: 0.102),
        stroke: Color.white.opacity(0.38),
        accent: Color(red: 1.0, green: 0.839, blue: 0.039),                // #FFD60A
        accent2: Color(red: 1.0, green: 0.839, blue: 0.039),
        onAccent: .black,
        focus: Color(red: 1.0, green: 0.839, blue: 0.039),
        focusTitle: Color(red: 1.0, green: 0.839, blue: 0.039),
        text: .white,
        meta: Color(red: 0.898, green: 0.898, blue: 0.898),                // #E5E5E5
        heroMeta: Color(red: 1.0, green: 0.914, blue: 0.361),              // #FFE95C
        badgeBg: Color(red: 1.0, green: 0.839, blue: 0.039),
        badgeText: .black,
        rCard: 18, rField: 16, artInset: 0, cardArtW: 264, railGap: 24,
        ringWidth: 6, cardTitleSize: 27, cardMetaSize: 25,
        scrimFloor: 0)

    static let sourceBoard = ThemeTokens(
        id: .sourceBoard,
        bg: .black,
        surfaceTop: Color.white.opacity(0.13),
        surfaceBottom: Color.white.opacity(0.05),
        surface2: Color.white.opacity(0.07),
        stroke: Color.white.opacity(0.16),
        accent: Color(red: 0.051, green: 0.361, blue: 0.302),              // #0D5C4D
        accent2: Color(red: 0.055, green: 0.478, blue: 0.392),             // #0E7A64
        onAccent: .white,
        focus: Color(red: 0.0, green: 0.898, blue: 1.0),                   // #00E5FF
        focusTitle: Color(red: 0.0, green: 0.898, blue: 1.0),
        text: .white,
        meta: Color.white.opacity(0.62),
        heroMeta: Color(red: 0.749, green: 0.941, blue: 0.902),            // #BFF0E6
        badgeBg: Color.black.opacity(0.65),
        badgeText: .white,
        rCard: 22, rField: 18, artInset: 12, cardArtW: 240, railGap: 28,
        ringWidth: 4, cardTitleSize: 25, cardMetaSize: 23,
        scrimFloor: 0)

    static func tokens(for id: JoeThemeID) -> ThemeTokens {
        switch id {
        case .billboard: return .billboard
        case .posterWall: return .posterWall
        case .sourceBoard: return .sourceBoard
        }
    }
}

private struct JoeThemeKey: EnvironmentKey {
    static let defaultValue: ThemeTokens = .sourceBoard
}

extension EnvironmentValues {
    var joeTheme: ThemeTokens {
        get { self[JoeThemeKey.self] }
        set { self[JoeThemeKey.self] = newValue }
    }
}

// MARK: - Legacy palette (theme-independent semantics only)

enum JoeTheme {
    static let accentRed = Color(red: 1.0, green: 0.27, blue: 0.23)   // LIVE / errors
    static let okGreen = Color(red: 0.188, green: 0.82, blue: 0.345)   // #30D158
    static let background = Color.black                               // player foundation
}

// MARK: - Focus ring (value-only: colour/width change inside an always-installed shape)

struct JoeFocusRing<S: InsettableShape>: View {
    let shape: S
    var lineWidth: CGFloat? = nil
    @Environment(\.isFocused) private var isFocused
    @Environment(\.joeTheme) private var theme

    var body: some View {
        shape.strokeBorder(isFocused ? theme.focus : .clear,
                           lineWidth: isFocused ? (lineWidth ?? theme.ringWidth) : 0)
    }
}

// MARK: - Shared control labels (single painted shape; focus = value-only)

/// Primary action label (hero "Xem ngay", slate "Thử lại", detail play).
struct JoePrimaryLabel: View {
    let title: String
    var systemImage: String? = nil
    @Environment(\.isFocused) private var isFocused
    @Environment(\.joeTheme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 24, weight: .bold))
            }
            Text(title).font(.system(size: 29, weight: .bold))
        }
        .foregroundStyle(theme.onAccent)
        .padding(.horizontal, 30)
        .frame(height: 58)
        .background(Capsule().fill(theme.accent2))
        .overlay(JoeFocusRing(shape: Capsule()))
    }
}

/// Secondary action label (surface fill; focus shown by ring + title colour).
struct JoeSecondaryLabel: View {
    let title: String
    var systemImage: String? = nil
    @Environment(\.isFocused) private var isFocused
    @Environment(\.joeTheme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 24, weight: .semibold))
            }
            Text(title).font(.system(size: 29, weight: .semibold))
        }
        .foregroundStyle(isFocused ? theme.focusTitle : theme.text)
        .padding(.horizontal, 30)
        .frame(height: 58)
        .background(Capsule().fill(theme.surface2))
        .overlay(JoeFocusRing(shape: Capsule()))
    }
}

/// Filter / option chip (genre filter, theme picker, server chips).
struct JoeChipLabel: View {
    let title: String
    let selected: Bool
    @Environment(\.isFocused) private var isFocused
    @Environment(\.joeTheme) private var theme

    var body: some View {
        Text(title)
            .font(.system(size: 24, weight: selected ? .bold : .semibold))
            .foregroundStyle(selected ? theme.onAccent : (isFocused ? theme.focusTitle : theme.text))
            .lineLimit(1)
            .padding(.horizontal, 22)
            .frame(height: 48)
            .background(Capsule().fill(selected ? theme.accent : theme.surface2))
            .overlay(JoeFocusRing(shape: Capsule()))
    }
}

/// Light-by-design field chrome for TextField / SecureField (UI-1 law:
/// fields are light in every theme; focus is the theme ring value only).
struct JoeFieldChrome: ViewModifier {
    let focused: Bool
    @Environment(\.joeTheme) private var theme

    func body(content: Content) -> some View {
        content
            .foregroundStyle(ThemeTokens.fieldText)
            .padding(.horizontal, 24)
            .frame(height: 64)
            .background(RoundedRectangle(cornerRadius: theme.rField)
                .fill(ThemeTokens.fieldBg))
            .overlay(RoundedRectangle(cornerRadius: theme.rField)
                .strokeBorder(focused ? theme.focus : .clear,
                              lineWidth: focused ? theme.ringWidth : 0))
    }
}

extension View {
    func joeFieldChrome(focused: Bool) -> some View {
        modifier(JoeFieldChrome(focused: focused))
    }
}

// MARK: - Card button (the system focus effect, disabled ONCE, centrally)
//
// v2.0.5 (owner errors 1+2): every Button in the app used the
// bare .card style, so TWO focus visuals stacked — the app's
// JoeFocusRing (drawn inside the label's own bounds) AND the
// tvOS system card effect (a scale + outset shadow platter
// larger than the button), which is what clipped the "2026"
// line on Poster Wall cards, threw grey silhouettes around
// inset art, and pushed neighbouring chips off their row.
// The cure is central, not per-site: this ONE modifier keeps
// the .card style's press/focus behaviour and disables its
// system focus effect, so JoeFocusRing is the only visible
// focus treatment in the app. It is safe now for the reason
// the old 1.9.2 ban's precondition no longer holds: every
// label in the target paints one full shape (the slab defect
// came from bare-text labels over the platter), so nothing
// needs the platter to read as a surface. (focusEffectDisabled
// is tvOS 17+; the target's minimum is 17.0.)
struct JoeCardButton: ViewModifier {
    func body(content: Content) -> some View {
        content
            .buttonStyle(.card)
            .focusEffectDisabled()
    }
}

extension View {
    /// The app's only card-button construction — see
    /// JoeCardButton above. Every `.card` call site in the
    /// target goes through here.
    func joeCardButton() -> some View {
        modifier(JoeCardButton())
    }
}

// MARK: - Boundary routing (v2.0.5, N1 — one shared construction)
//
// The shared boundary-routing helper. The repo's standing
// rule, learned from every handler that device-proves
// (JoeTVSection.moveInGrid, JoeSearch.resultMove,
// JoeBrowse.gridMove): an attached .onMoveCommand owns EVERY
// direction — the engine delivers the press to the handler
// INSTEAD of moving focus geometrically. So a call site that
// attaches this helper declares all four exits: a direction
// with a closure performs that closure's landing (in-region
// arithmetic or a boundary landing — the call site's own
// knowledge), and a direction left nil is a DECLARED no-op
// (the element sits at a region edge with nothing beyond it
// in that direction — the screen's top edge, a full-width
// row's sides), never an accidental swallow. Handlers are
// always installed where the helper is applied; attachment
// follows the surface, never focus state (law D4).
struct JoeBoundaryMove: ViewModifier {
    var up: (() -> Void)? = nil
    var down: (() -> Void)? = nil
    var left: (() -> Void)? = nil
    var right: (() -> Void)? = nil

    func body(content: Content) -> some View {
        content.onMoveCommand { direction in
            switch direction {
            case .up: up?()
            case .down: down?()
            case .left: left?()
            case .right: right?()
            @unknown default: break
            }
        }
    }
}

extension View {
    func joeBoundaryMove(up: (() -> Void)? = nil,
                         down: (() -> Void)? = nil,
                         left: (() -> Void)? = nil,
                         right: (() -> Void)? = nil) -> some View {
        modifier(JoeBoundaryMove(up: up, down: down, left: left, right: right))
    }
}

// MARK: - Wrapping flow layout (UI-6 defect D-4)

/// Rows of content-sized items that wrap onto the next line —
/// the episode chips' layout in all three renders (capsules in
/// a wrapping row, never a stretched grid cell). Pure geometry:
/// a static Layout, no state, nothing focus-driven.
struct FlowLayout: Layout {
    var spacing: CGFloat = 16

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                      cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        let width = maxWidth.isFinite ? maxWidth : max(x - spacing, 0)
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout Void) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Poster card (theme-parameterised leaf)

/// One card for every poster surface. Anatomy follows the active theme:
///  - A / F: PosterCard v2 — art and title/meta INSIDE one painted face
///    (UI-1 recipe verbatim: the text never touches the system platter).
///  - D: poster-only art; title/meta BELOW the art on the opaque foundation
///    (the label paints the foundation colour over its full frame, so the
///    system platter can never lighten behind the text).
/// Focus changes values only (title colour, ring colour/width) inside shapes
/// that are always installed. No scale, no focus-conditional structure.
struct PosterCard: View {
    let title: String
    let posterURL: URL?
    /// TMDB identity for the art slot's fallback ladder
    /// (v2.0.5): when the primary poster is missing or fails
    /// the portrait aspect gate, the slot resolves the
    /// record's TMDB poster instead of painting a band.
    /// Defaulted empty — call sites without an identity in
    /// hand keep compiling and simply have no TMDB leg.
    var tmdbId: String = ""
    var tmdbType: String = ""
    var meta: String = ""
    var badge: String? = nil        // provider code (KK / F4K / VS / TP)
    var quality: String = ""        // quality tag (FHD / HD / CAM …)
    var progress: Double? = nil
    var subline: String? = nil

    // v2.0.5 (N4): ONE focus source of truth — the card reads
    // its own focus from the environment, exactly like every
    // other label in the theme system (PillLabel, JoeChipLabel,
    // JoePrimaryLabel). The caller-passed `focused:` argument
    // is gone: it duplicated the environment value through a
    // second channel (the caller's @FocusState), and the two
    // could disagree for a frame whenever a landing write and
    // the engine's own update raced.
    @Environment(\.isFocused) private var isFocused
    @Environment(\.joeTheme) private var theme

    private var artRadius: CGFloat { max(theme.rCard - theme.artInset, 0) }

    var body: some View {
        if theme.id == .posterWall {
            wallBody
        } else {
            faceBody
        }
    }

    // Art block shared by both anatomies: poster, quality badge (top-left),
    // provider badge (bottom-left), continue-watching bar (bottom).
    // IMAGE INTEGRITY (owner rule, 2026-11-15): poster sources are 2:3
    // and this frame is exactly 2:3, and the image is FIT into it —
    // the whole poster is always visible, aspect preserved end-to-end,
    // never cropped or stretched; a missing poster leaves the painted
    // surface below, never a broken hole. v2.0.5: the slot also gates
    // on the decoded bitmap's aspect (slotClass .portrait) — a source
    // whose "poster" field actually serves a landscape still (the Tủ
    // Phim name swap) is rejected and the TMDB fallback runs, instead
    // of the bitmap letterboxing into a band inside the frame.
    /// The TMDB leg of the art slot's fallback ladder,
    /// present only when the record carries a TMDB identity.
    /// The pipeline caches the path lookup per identity, so
    /// repeated appearances never re-ask.
    private var tmdbFallback: (() async -> URL?)? {
        guard !tmdbId.isEmpty else { return nil }
        let id = tmdbId, type = tmdbType
        return {
            await JoeImagePipeline.shared.tmdbPosterURL(
                tmdbId: id, type: type)
        }
    }

    private var art: some View {
        ZStack {
            Color.black.opacity(0.45)
            JoeRemoteImage(url: posterURL, targetPixels: 720, fit: true,
                           slotClass: .portrait,
                           fallbackProvider: tmdbFallback) {
                Image(systemName: "film")
                    .font(.system(size: 44))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .frame(width: theme.cardArtW, height: theme.cardArtH)
        .overlay(alignment: .topLeading) {
            if !quality.isEmpty {
                Text(quality)
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(theme.badgeText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(theme.badgeBg))
                    .padding(10)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let badge {
                Text(badge)
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(theme.id == .sourceBoard ? theme.focus : .white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(theme.badgeBg))
                    .padding(.leading, 10)
                    .padding(.bottom, progress != nil ? 16 : 10)
            }
        }
        .overlay(alignment: .bottom) {
            if let progress {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.white.opacity(0.25))
                        Rectangle().fill(JoeTheme.accentRed)
                            .frame(width: geo.size.width * CGFloat(min(max(progress, 0), 1)))
                    }
                }
                .frame(height: 6)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: artRadius))
    }

    private var faceBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            art
            Text(title)
                .font(.system(size: theme.cardTitleSize, weight: .semibold))
                .foregroundStyle(isFocused ? theme.focusTitle : theme.text)
                .lineLimit(1)
                .padding(.top, 12)
            if !meta.isEmpty {
                Text(meta)
                    .font(.system(size: theme.cardMetaSize))
                    .foregroundStyle(theme.meta)
                    .lineLimit(1)
                    .padding(.top, 3)
            }
            if let subline {
                Text(subline)
                    .font(.system(size: 21))
                    .foregroundStyle(JoeTheme.accentRed)
                    .lineLimit(1)
                    .padding(.top, 3)
            }
        }
        .padding(.horizontal, theme.artInset)
        .padding(.top, theme.artInset)
        .padding(.bottom, 14)
        .frame(width: theme.cardWidth, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: theme.rCard).fill(theme.surfaceGradient))
        .overlay(RoundedRectangle(cornerRadius: theme.rCard)
            .strokeBorder(isFocused ? theme.focus : theme.stroke,
                          lineWidth: isFocused ? theme.ringWidth : 1.5))
    }

    private var wallBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            art
            Text(title)
                .font(.system(size: theme.cardTitleSize, weight: .semibold))
                .foregroundStyle(isFocused ? theme.focusTitle : theme.text)
                .lineLimit(1)
                .padding(.top, 12)
            if !meta.isEmpty {
                Text(meta)
                    .font(.system(size: theme.cardMetaSize))
                    .foregroundStyle(theme.meta)
                    .lineLimit(1)
                    .padding(.top, 3)
            }
            if let subline {
                Text(subline)
                    .font(.system(size: 23))
                    .foregroundStyle(JoeTheme.accentRed)
                    .lineLimit(1)
                    .padding(.top, 3)
            }
        }
        .frame(width: theme.cardWidth, alignment: .leading)
        .background(theme.bg)
        // v2.0.3: the focus ring overlays the WHOLE card — the
        // bounds the focus engine (and the owner) sees. It used
        // to ride the art alone, so in this theme the app's ring
        // and the card's actual bounds disagreed (the ring
        // stopped at the art's bottom edge while the card runs
        // on through the title block). Same shape, colour and
        // width values as before; only the bounds are corrected.
        .overlay(RoundedRectangle(cornerRadius: theme.rCard)
            .strokeBorder(isFocused ? theme.focus : .clear,
                          lineWidth: isFocused ? theme.ringWidth : 0))
    }
}

// MARK: - Rail

struct Rail<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    @Environment(\.joeTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: theme.id == .posterWall ? 40 : 34,
                              weight: theme.id == .posterWall ? .heavy : .bold))
                .foregroundStyle(theme.text)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: theme.railGap) { content() }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 14)
            }
        }
        // v2.0.5 (N1): every rail is a declared focus region.
        // Between-region movement (rail ↔ rail, header ↔ rail)
        // is then section-to-section navigation — the engine
        // enters the rail as a unit and picks within it —
        // instead of a pure beam search that dropped presses
        // whose column held no card. Static and always
        // installed; it guides the engine, consumes nothing.
        .focusSection()
    }
}
