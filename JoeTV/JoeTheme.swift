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
    /// v2.0.19: the Phim4K "Ultra" design, ported from the
    /// Sony build the owner approved (2.3.31/2.3.32) — red
    /// system, gold meta, full-bleed backdrops, 4-badge
    /// posters, frosted server panel.
    case ultra

    var pickerLabel: String {
        switch self {
        case .billboard: return "Billboard"
        case .posterWall: return "Tường Poster"
        case .sourceBoard: return "Bảng Nguồn"
        case .ultra: return "Ultra"
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
        // The gradient DIRECTION is part of the drawing:
        // design-A's faces run 180deg (top to bottom) and
        // design-D's are solid, but design-F's card/row faces
        // run linear-gradient(135deg, ...) — a diagonal from
        // the top-left. The stops were always per-theme; the
        // direction now is too (v2.0.8 Phase 4d, coordinator
        // correction on Worker 1's flagged observation).
        if id == .sourceBoard {
            return LinearGradient(colors: [surfaceTop, surfaceBottom],
                                  startPoint: .topLeading,
                                  endPoint: .bottomTrailing)
        }
        return LinearGradient(colors: [surfaceTop, surfaceBottom],
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

    /// Ultra (v2.0.19) — the Sony build's token values: red
    /// accent #E02B3A, deep red #C81E30, gold #FFC759 meta,
    /// cyan #00E5FF focus, full-bleed art (inset 0).
    static let ultra = ThemeTokens(
        id: .ultra,
        bg: Color(red: 0.039, green: 0.039, blue: 0.039),                  // #0A0A0A
        surfaceTop: Color(red: 0.137, green: 0.137, blue: 0.137),          // #232323
        surfaceBottom: Color(red: 0.090, green: 0.090, blue: 0.090),       // #171717
        surface2: Color(red: 0.110, green: 0.110, blue: 0.110),            // #1C1C1C
        stroke: Color.white.opacity(0.14),
        accent: Color(red: 0.878, green: 0.169, blue: 0.227),              // #E02B3A
        accent2: Color(red: 0.784, green: 0.118, blue: 0.188),             // #C81E30
        onAccent: .white,
        focus: Color(red: 0.0, green: 0.898, blue: 1.0),                   // #00E5FF
        focusTitle: Color(red: 0.0, green: 0.898, blue: 1.0),
        text: .white,
        meta: Color(red: 0.659, green: 0.659, blue: 0.659),                // #A8A8A8
        heroMeta: Color(red: 1.0, green: 0.780, blue: 0.349),              // #FFC759
        badgeBg: Color.black.opacity(0.70),
        badgeText: .white,
        rCard: 10, rField: 10, artInset: 0, cardArtW: 240, railGap: 26,
        ringWidth: 4, cardTitleSize: 25, cardMetaSize: 23,
        scrimFloor: 0.55)

    static func tokens(for id: JoeThemeID) -> ThemeTokens {
        switch id {
        case .billboard: return .billboard
        case .posterWall: return .posterWall
        case .sourceBoard: return .sourceBoard
        case .ultra: return .ultra
        }
    }
}

private struct JoeThemeKey: EnvironmentKey {
    static let defaultValue: ThemeTokens = .ultra
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

// MARK: - Outset stroke (v2.0.6, Team Ring)

extension InsettableShape {
    /// A strokeBorder band moved OUTSIDE the shape's bounds:
    /// inset(by:) with a negative amount expands the path by
    /// `lineWidth`, and strokeBorder then paints its band
    /// inside that expanded path — so the band occupies the
    /// margin OUTSIDE the bounds, its inner edge flush with
    /// the bounds edge, and it can never paint over the
    /// element's own content. (The v2.0.5 defect: an inside
    /// strokeBorder ring ate the first glyphs of Poster Wall
    /// card titles and the edge pixels of flush art, whose
    /// content sits at the bounds edge.) Overlay-only — the
    /// layout frame never changes — and a lineWidth of 0
    /// expands by 0 and paints nothing, so resting states
    /// keep the identical view structure (value-only, like
    /// the width change it replaces).
    func joeOutsetStrokeBorder<Style: ShapeStyle>(_ style: Style,
                                                  lineWidth: CGFloat) -> some View {
        inset(by: -lineWidth).strokeBorder(style, lineWidth: lineWidth)
    }
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
        // Design .btn.primary (themes2 shared stylesheet): 29px
        // semibold, padding 17px 36px, capsule, accent2 fill, NO
        // resting stroke; focused ring = inside strokeBorder
        // (the JoeFocusRing values, spelt out — see below).
        HStack(spacing: 10) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 24, weight: .semibold))
            }
            Text(title).font(.system(size: 29, weight: .semibold))
        }
        .foregroundStyle(theme.onAccent)
        .padding(.horizontal, 36)
        .padding(.vertical, 17)
        .background(Capsule().fill(theme.accent2))
        // v2.0.9 (owner defect, theme D only — the JoeChipLabel
        // ruling extended to the primary button): the label is
        // PERMANENTLY accent2-filled, and in D's tokens accent2
        // == focus == #FFD60A, so the drawn yellow focus ring
        // painted over the yellow fill in the same yellow and
        // focus on "Xem ngay" was invisible — the same
        // collision the owner convicted on the selected chips
        // ("Cùng màu nên ko nhận ra đc"; his follow-up order
        // folds this button into the same fix). In D the
        // focused frame is OPAQUE WHITE (trắng đục); A/F keep
        // theme.focus exactly as JoeFocusRing painted it
        // (their accent2 and focus colours differ), and the
        // resting state stays clear/0 — A/F rendering is
        // byte-identical to before. JoeFocusRing itself is
        // untouched: its other callers are not accent-filled.
        .overlay(Capsule().strokeBorder(
            isFocused
                ? (theme.id == .posterWall ? Color.white : theme.focus)
                : .clear,
            lineWidth: isFocused ? theme.ringWidth : 0))
    }
}

/// Secondary action label (surface fill; focus shown by the
/// ring only — the drawings' .btn.focused never recolours the
/// text, in any of the three designs).
struct JoeSecondaryLabel: View {
    let title: String
    var systemImage: String? = nil
    @Environment(\.isFocused) private var isFocused
    @Environment(\.joeTheme) private var theme

    var body: some View {
        // Design .btn: 29px semibold, padding 17px 36px, capsule,
        // surface2 fill, resting inset stroke 1.5 theme.stroke;
        // focused ring = inside strokeBorder ringWidth theme.focus
        // (an explicit strokeBorder replaces JoeFocusRing here
        // because the drawing's resting state carries the 1.5
        // stroke, which JoeFocusRing paints clear at rest).
        HStack(spacing: 10) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 24, weight: .semibold))
            }
            Text(title).font(.system(size: 29, weight: .semibold))
        }
        .foregroundStyle(theme.text)
        .padding(.horizontal, 36)
        .padding(.vertical, 17)
        .background(Capsule().fill(theme.surface2))
        .overlay(Capsule().strokeBorder(
            isFocused ? theme.focus : theme.stroke,
            lineWidth: isFocused ? theme.ringWidth : 1.5))
    }
}

/// Filter / option chip (genre filter, theme picker, server chips).
struct JoeChipLabel: View {
    let title: String
    let selected: Bool
    @Environment(\.isFocused) private var isFocused
    @Environment(\.joeTheme) private var theme

    var body: some View {
        // Design .chip: 24px, medium at rest / semibold when selected
        // or focused, padding 11px 22px, capsule; resting inset
        // stroke 1.5 theme.stroke (none when selected — the accent
        // fill replaces it); focused ring = inside strokeBorder
        // ringWidth theme.focus. Same construction as the episode
        // chip in JoeMovieDetail (the drawing's reference chip).
        // Focused text keeps the resting colour — the drawings'
        // .chip.focused changes weight and ring only, never the
        // text colour (the episode chip agrees).
        Text(title)
            .font(.system(size: 24, weight: (selected || isFocused) ? .semibold : .medium))
            .foregroundStyle(selected ? theme.onAccent : theme.text)
            .lineLimit(1)
            .padding(.horizontal, 22)
            .padding(.vertical, 11)
            .background(Capsule().fill(selected ? theme.accent : theme.surface2))
            // v2.0.9 (owner defect, theme D only): design D's
            // sheets draw .chip.sel (fill #FFD60A, box-shadow:
            // none) and .chip.focused (inset 6 pt #FFD60A ring)
            // as separate states and draw NO combined state —
            // and in D's tokens accent == focus == #FFD60A, so
            // the focused ring painted over a selected chip's
            // yellow fill in the same yellow and the owner
            // could not tell focus was there ("Cùng màu nên ko
            // nhận ra đc"). His ruling: a selected + focused
            // chip in D wears an OPAQUE WHITE (trắng đục) frame.
            // Unselected + focused keeps the drawn yellow ring;
            // selected + unfocused keeps the plain yellow fill.
            // Themes A/F never take the branch (their accent
            // and focus colours differ) — their expression is
            // byte-identical to before.
            .overlay(Capsule().strokeBorder(
                isFocused
                    ? (theme.id == .posterWall && selected
                       ? Color.white : theme.focus)
                    : (selected ? .clear : theme.stroke),
                lineWidth: isFocused ? theme.ringWidth : 1.5))
    }
}

/// Light-by-design field chrome for TextField / SecureField (UI-1 law:
/// fields are light in every theme; focus is the theme ring value only).
struct JoeFieldChrome: ViewModifier {
    let focused: Bool
    @Environment(\.joeTheme) private var theme

    func body(content: Content) -> some View {
        // Design .field: padding 20px 28px, radius rField, light
        // fill; the focused ring in the drawing is an OUTSET shadow
        // (box-shadow: 0 0 0 ringWidth focus — the only outset ring
        // in the whole design system), so it is painted with
        // joeOutsetStrokeBorder, not an inside strokeBorder. Caret
        // = theme.accent2 (design caret: A #D9232E, D #FFD60A,
        // F #0E7A64 — accent2 carries exactly that colour in all
        // three themes).
        // v2.0.8 (Phase 4b): the system field focus treatment
        // is disabled HERE, in the shared field construction,
        // so every field site inherits it centrally (per-site
        // disables are banned by the construction law). The
        // drawn outset ring below is then the SOLE field focus
        // treatment — before this, fields ran the system
        // treatment AND the outset ring at once (the double
        // box in the owner's photos; Round-1 report §4.5).
        content
            .focusEffectDisabled()
            .foregroundStyle(ThemeTokens.fieldText)
            .tint(theme.accent2)
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
            .background(RoundedRectangle(cornerRadius: theme.rField)
                .fill(ThemeTokens.fieldBg))
            .overlay(RoundedRectangle(cornerRadius: theme.rField)
                .joeOutsetStrokeBorder(focused ? theme.focus : .clear,
                                       lineWidth: focused ? theme.ringWidth : 0))
    }
}

extension View {
    func joeFieldChrome(focused: Bool) -> some View {
        modifier(JoeFieldChrome(focused: focused))
    }
}

// MARK: - Card button (custom style, centrally — v2.0.8 Phase 4a)
//
// ROUND-1 VERDICT (tvos-training/TRAINING-REPORT.md §3–§4.1,
// replacing the wrong belief this comment recorded through
// v2.0.5–v2.0.7): the pale plate behind every focused element
// in the owner's device photos is the `.card` button style's
// OWN platter — a style-layer rendering ("A Card-Button
// creates a platter that raises and looks highlighted when
// it's focused", WWDC20-10042). `.focusEffectDisabled()`
// disables a DIFFERENT layer (the focus/hover effect); it
// does NOT strip the .card style's platter, and no redraw of
// the app's rings could ever fix a plate that lives in the
// style layer underneath them — that is why the pixel-faithful
// v2.0.7 rebuild changed nothing the owner could see.
//
// Apple's documented cure (WWDC20, same session): replace the
// preexisting style with a custom ButtonStyle, which "adds no
// existing effects for pressing and focused states". That is
// what JoeCardButtonStyle is: it returns the label untouched —
// no background, no scale, no highlight, no press animation —
// so the label paints everything and the app's drawn rings
// (JoeFocusRing and the faceBody/wallBody/railBody overlays)
// are now the ONLY focus treatment, as originally intended.
// `.focusEffectDisabled()` is KEPT alongside it: button style
// and focus effect are distinct layers, and both are now off.
// The construction remains central, not per-site: this ONE
// modifier is the app's only button construction, so every
// button inherits the same decision. (focusEffectDisabled is
// tvOS 17+; the target's minimum is 17.0.)
struct JoeCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

struct JoeCardButton: ViewModifier {
    func body(content: Content) -> some View {
        content
            .buttonStyle(JoeCardButtonStyle())
            .focusEffectDisabled()
    }
}

extension View {
    /// The app's only card-button construction — see
    /// JoeCardButton above. Every card-button call site in the
    /// target goes through here.
    func joeCardButton() -> some View {
        modifier(JoeCardButton())
    }
}

// MARK: - Boundary routing — REMOVED in v2.0.8 (Phase 1)
//
// The v2.0.5 JoeBoundaryMove helper (an .onMoveCommand
// wrapper whose house contract made an attached handler
// own EVERY direction, undeclared directions becoming
// coded no-ops) was deleted together with its last call
// sites: it routed away the focus engine's free 2-D
// geometric movement — the owner's "thiếu freedom"
// verdict on v2.0.7. Do not reintroduce handler-owned
// movement; movement belongs to the engine, structured
// by .focusSection() regions.

// MARK: - Wrapping flow layout (UI-6 defect D-4)

/// Rows of content-sized items that wrap onto the next line —
/// the episode chips' layout in all three renders (capsules in
/// a wrapping row, never a stretched grid cell). Pure geometry:
/// a static Layout, no state, nothing focus-driven.
struct FlowLayout: Layout {
    var spacing: CGFloat = 16
    /// Design D's detail rows are centred (justify-content:
    /// center in the drawing); every other surface keeps the
    /// leading rows. Placement-only: row breaks and heights
    /// are identical either way.
    var centered: Bool = false

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
        // Group into rows first (the same breaks sizeThatFits
        // makes), then place each row — centred rows start at
        // the row's centred offset, leading rows at minX.
        var rows: [[(Subviews.Element, CGSize)]] = []
        var row: [(Subviews.Element, CGSize)] = []
        var x = bounds.minX
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, !row.isEmpty {
                rows.append(row)
                row = []
                x = bounds.minX
            }
            row.append((sub, size))
            x += size.width + spacing
        }
        if !row.isEmpty { rows.append(row) }

        var y = bounds.minY
        for row in rows {
            let rowWidth = row.reduce(CGFloat(0)) { $0 + $1.1.width }
                + spacing * CGFloat(max(row.count - 1, 0))
            let rowHeight = row.map { $0.1.height }.max() ?? 0
            var px = centered
                ? bounds.minX + max(0, (bounds.width - rowWidth) / 2)
                : bounds.minX
            for (sub, size) in row {
                sub.place(at: CGPoint(x: px, y: y),
                          proposal: ProposedViewSize(size))
                px += size.width + spacing
            }
            y += rowHeight + spacing
        }
    }
}

// MARK: - Poster card (theme-parameterised leaf)

/// One card for every poster surface. Anatomy follows the active theme:
///  - A / F: PosterCard v2 — art and title/meta INSIDE one painted face
///    (UI-1 recipe verbatim: the text never touches the system platter).
///  - D carries BOTH of its drawing's card forms, chosen by the
///    `form` value: horizontal rails render .card (the painted
///    face — art full-bleed, title/meta inside, inset whole-card
///    ring); vertical walls/grids render .pcard (bare art on the
///    background, title/meta BELOW the art, the focus ring an
///    outset band around the ART alone).
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
    /// Ultra's corner badges (v2.0.19): runtime top-left and
    /// year bottom-left; the IMDb badge (bottom-right) reads
    /// the TMDB cache synchronously (v2.0.21 — see imdbRating).
    var timeBadge: String = ""
    var yearBadge: String = ""
    var progress: Double? = nil
    var subline: String? = nil
    /// Which of design D's two card forms a horizontal rail
    /// (.rail — the .card face) or a vertical wall/grid (.wall
    /// — the .pcard) renders. Read only under posterWall: A
    /// and F paint the face in every context. Default .wall —
    /// the form every D card took before the distinction
    /// existed (wall home, browse/search grids).
    var form: Form = .wall

    enum Form {
        case rail
        case wall
    }

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
    /// Ultra only: the TMDB vote average for the art's
    /// bottom-right badge, read SYNCHRONOUSLY from the
    /// TMDBClient cache (v2.0.21) — a value a previous
    /// fetchInfo already resolved, or nil. The v2.0.19 card
    /// fetched it per card in a .task: one 2-call TMDB chain
    /// (detail + images) per card across every rail, all
    /// riding the same JoeHTTP session the poster fallback
    /// ladder's posterPath lookup needs — the storm starved
    /// exactly the cards whose posters depended on that
    /// lookup, and they fossilised on the placeholder
    /// (owner report, 2026-11-17). A card now never touches
    /// the network for its badge; the badge simply appears
    /// on cards whose rating is already known (the hero's
    /// film, anything opened in detail).
    private var imdbRating: Double? {
        TMDBClient.cachedRating(tmdbId: tmdbId, type: tmdbType)
    }

    // Design .card .art border-radius: A 2px, D 18px, F 10px.
    // rCard − artInset reproduces D (18−0) and F (22−12) exactly,
    // but for A it yields 0 (10−10) while the approved drawing
    // specifies 2 — hence the billboard floor of 2.
    // v2.0.22 (Ultra fidelity): Ultra's drawing (the Phim4K
    // home/grid caps) rounds its posters at ~24 — the Ultra
    // token's rCard (10) is shared with the detail poster's
    // chrome, so the value is applied HERE, in the Ultra card
    // branch's own radius, not by moving the token.
    private var artRadius: CGFloat {
        if theme.id == .ultra { return 24 }
        return max(theme.rCard - theme.artInset, theme.id == .billboard ? 2 : 0)
    }

    var body: some View {
        if theme.id == .posterWall {
            if form == .rail {
                railBody
            } else {
                wallBody
            }
        } else if theme.id == .ultra {
            ultraBody
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
            // Design .card .art background: rgba(0,0,0,.35) in all
            // three drawings; design-D's .pcard .art instead
            // rests on the theme surface (#1A1A1A — the wall
            // render's placeholder tile). Placeholder glyph
            // .ph span: 64px in the theme's meta colour at
            // opacity .55 (both card forms agree).
            if theme.id == .posterWall && form == .wall {
                theme.surface2
            } else if theme.id == .ultra {
                Color(red: 0.149, green: 0.149, blue: 0.169)   // #26262B
            } else {
                Color.black.opacity(0.35)
            }
            JoeRemoteImage(url: posterURL, targetPixels: 720, fit: true,
                           slotClass: .portrait,
                           fallbackProvider: tmdbFallback) {
                if theme.id == .ultra {
                    // The Sony Ultra placeholder: the red
                    // wordmark on the grey art slot.
                    Text("JOE TV")
                        .font(.system(size: 30, weight: .heavy))
                        .tracking(3)
                        .foregroundStyle(Color(red: 0.878, green: 0.169, blue: 0.227))
                } else {
                    Image(systemName: "film")
                        .font(.system(size: 64))
                        .foregroundStyle(theme.meta.opacity(0.55))
                }
            }
        }
        .frame(width: theme.cardArtW, height: theme.cardArtH)
        .overlay(alignment: .topLeading) {
            if theme.id == .ultra {
                // Ultra: runtime badge, red fill (Sony #D81F36).
                if !timeBadge.isEmpty {
                    Text(timeBadge)
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(Color(red: 0.847, green: 0.122, blue: 0.212)))
                        .padding(10)
                }
            } else if !quality.isEmpty {
                Text(quality)
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(theme.badgeText)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(theme.badgeBg))
                    .padding(10)
            }
        }
        .overlay(alignment: .topTrailing) {
            if theme.id == .ultra, !quality.isEmpty {
                Text(quality)
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(theme.badgeText)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(theme.badgeBg))
                    .padding(10)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if theme.id == .ultra {
                // Ultra: year badge, purple fill (Sony #7B1FA2).
                if !yearBadge.isEmpty {
                    Text(yearBadge)
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(Color(red: 0.482, green: 0.122, blue: 0.635)))
                        .padding(.leading, 10)
                        .padding(.bottom, progress != nil ? 16 : 10)
                }
            } else if let badge {
                Text(badge)
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(theme.id == .sourceBoard ? theme.focus : .white)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(theme.badgeBg))
                    .padding(.leading, 10)
                    .padding(.bottom, progress != nil ? 16 : 10)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if theme.id == .ultra, let imdbRating {
                // Ultra: IMDb badge, yellow fill (Sony #F5C518).
                Text(String(format: "IMDb %.1f", imdbRating))
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(Color(red: 0.961, green: 0.773, blue: 0.094)))
                    .padding(.trailing, 10)
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

    /// Ultra's card (v2.0.19, the Sony/Phim4K form): the bare
    /// full-bleed art with its four corner badges, title and
    /// meta below on the page background — no painted face.
    /// The focus ring rides the art (inset, the theme's cyan).
    /// v2.0.22 (Ultra fidelity, caps p4k-1/p4k-2): a resting
    /// Ultra poster carries NO outline — the 1.5 pt white-14%
    /// resting stroke is removed (colour/width are values in
    /// the always-installed overlay, the wallBody pattern) —
    /// and the focused ring is the drawing's thick cyan band
    /// (6, measured on the caps) rather than the shared token
    /// width the buttons and chips keep.
    private var ultraBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            art
                .overlay(RoundedRectangle(cornerRadius: artRadius)
                    .strokeBorder(isFocused ? theme.focus : .clear,
                                  lineWidth: isFocused ? 6 : 0))
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
                    .padding(.top, 5)
            }
            if let subline {
                Text(subline)
                    .font(.system(size: 21))
                    .foregroundStyle(JoeTheme.accentRed)
                    .lineLimit(1)
                    .padding(.top, 3)
            }
        }
        .frame(width: theme.cardWidth, alignment: .leading)
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
                    .padding(.top, 5)
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

    /// Design D's wall card (.pcard in design-D's drawings):
    /// the bare art on the screen background — the card paints
    /// NO surface and carries NO whole-card ring. The focus
    /// ring belongs to the ART alone: box-shadow 0 0 0 6px
    /// #FFD60A, an OUTSET band around the art (one of the
    /// design system's two outset rings; the field's is the
    /// other), painted here with joeOutsetStrokeBorder over
    /// the clipped art. Title (27 semibold, margin-top 14)
    /// and meta (25, margin-top 5) sit BELOW the art, outside
    /// the ring; the focused title takes the focus colour.
    /// (The v2.0.3 whole-card ring — and the foundation paint
    /// under the text, a system-platter defence from before
    /// .joeCardButton disabled that effect centrally — both
    /// contradicted the drawing: the owner's photo showed the
    /// frame hanging past the text block, its corner floating
    /// in empty space below the title.)
    private var wallBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            art
                .overlay(RoundedRectangle(cornerRadius: artRadius)
                    .joeOutsetStrokeBorder(isFocused ? theme.focus : .clear,
                                           lineWidth: isFocused ? theme.ringWidth : 0))
            Text(title)
                .font(.system(size: theme.cardTitleSize, weight: .semibold))
                .foregroundStyle(isFocused ? theme.focusTitle : theme.text)
                .lineLimit(1)
                .padding(.top, 14)
            if !meta.isEmpty {
                Text(meta)
                    .font(.system(size: theme.cardMetaSize))
                    .foregroundStyle(theme.meta)
                    .lineLimit(1)
                    .padding(.top, 5)
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
    }

    /// Design D's rail card (.card in design-D's stylesheet):
    /// the painted face — art full-bleed across the top,
    /// title/meta INSIDE the face below the art, the focus
    /// ring an INSET band around the whole card, resting
    /// stroke 1.5. The face's text sizes are the drawing's
    /// own .card values (title 25px margin-top 12, meta 23px
    /// margin-top 5, bottom padding 14) — NOT the theme
    /// tokens, which carry the .pcard sizes (27/25). The
    /// horizontal padding rides theme.artInset (0 under D,
    /// the drawing's padding 0 0 14px).
    private var railBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            art
            // v2.0.31 (L1): the text stack is inset by the
            // ring's own width. Pre-fix the texts sat flush
            // at the card edge (artInset 0 under D) and the
            // FOCUSED title takes the ring's own colour
            // (#FFD60A on #FFD60A), so the band's inner edge
            // ran through the first glyphs — the owner's
            // "viền … cắt chữ" on the device photo, which
            // survived the v2.0.29 draw-order change because
            // that change only moved the ring UNDER the
            // content (see the overlay note below). The
            // inset is a constant (theme.ringWidth), never
            // focus-conditional, so the resting card's text
            // clears the resting stroke by the same margin.
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(isFocused ? theme.focusTitle : theme.text)
                    .lineLimit(1)
                    .padding(.top, 12)
                if !meta.isEmpty {
                    Text(meta)
                        .font(.system(size: 23))
                        .foregroundStyle(theme.meta)
                        .lineLimit(1)
                        .padding(.top, 5)
                }
                if let subline {
                    Text(subline)
                        .font(.system(size: 21))
                        .foregroundStyle(JoeTheme.accentRed)
                        .lineLimit(1)
                        .padding(.top, 3)
                }
            }
            .padding(.horizontal, theme.ringWidth)
        }
        .padding(.horizontal, theme.artInset)
        .padding(.top, theme.artInset)
        .padding(.bottom, 14)
        .frame(width: theme.cardWidth, alignment: .leading)
        // v2.0.29 (item 5): the ring used to be an .overlay
        // — the TOP layer — so its 6 pt inset band painted
        // OVER the first and last glyphs of the title/meta
        // (flush with the card edge at artInset 0): the
        // owner's "viền của poster nó cắt chữ". The
        // drawing's inset box-shadow paints above the
        // face's fill but UNDER its content, so the ring
        // now rides the background's own shape: same
        // stroke, same values (focus colour / resting
        // stroke, ringWidth / 1.5), painted between the
        // fill and the text instead of over it.
        //
        // v2.0.31 (L1): the owner's 2.0.29 device photo
        // proved that shape still wrong — with the ring in
        // the background, the opaque full-width art paints
        // OVER the ring's top and side segments beside the
        // poster, so on device the band survived only
        // beside the title plate ("viền màu vàng nó không
        // bao hết cái poster"). The RESTING stroke keeps
        // the v2.0.29 background placement (the resting
        // card is pixel-identical), but the FOCUSED band
        // now ALSO rides an overlay on the same shape:
        // over the art's edge, around the whole card —
        // poster + plate — exactly the wrap the owner
        // asked for. It cannot cut the text any more: the
        // text stack above is inset by the ring's width.
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: theme.rCard)
                    .fill(theme.surfaceGradient)
                RoundedRectangle(cornerRadius: theme.rCard)
                    .strokeBorder(isFocused ? theme.focus : theme.stroke,
                                  lineWidth: isFocused ? theme.ringWidth : 1.5)
            })
        .overlay(
            RoundedRectangle(cornerRadius: theme.rCard)
                .strokeBorder(theme.focus,
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
            // v2.0.8 (Phase 4c): a focused card's outset
            // elements must never be clipped by the rail
            // container — Apple's own samples disable scroll
            // clipping on shelves for exactly this reason.
            .scrollClipDisabled()
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
