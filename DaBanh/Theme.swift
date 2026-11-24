import SwiftUI
import UIKit

/// Selectable app themes (theme-mu, 2026-11-22), mirroring the
/// tvOS TVTheme pattern: the classic theme is the app's
/// established look and stays the default; the Manchester
/// United theme is an added, switchable skin. THEME ONLY —
/// no behaviour changes with the theme; every playback path
/// (ResolveHub, race, stall watchdog, failover) is untouched.
///
/// The classic palette (BoardPalette in MatchViews.swift) is
/// NOT edited and NOT routed through this file: the MU theme
/// is a PARALLEL token set (MUTokens) read only by the MU
/// surfaces, exactly as the leader's deviation table rules.
enum AppThemeID: String, CaseIterable {
    case classic
    case muWally
    case united

    /// Whether the theme wears the MU surfaces (the MU home,
    /// detail and player chrome). Both MU-family themes do —
    /// they differ ONLY in palette (see MURawPalette): the
    /// drawing-true MU and the preserved 1.7.2 "MU Wally".
    var isMU: Bool { self != .classic }
    var isWally: Bool { self == .muWally }
    /// The picker's display name for this theme.
    var pickerName: String {
        switch self {
        case .classic: return "Cổ điển"
        case .muWally: return "MU Wally"
        case .united: return "Manchester United"
        }
    }
    /// The header pill's short name (the design's pill shows
    /// the current theme's name).
    var pillName: String {
        switch self {
        case .classic: return "Cổ điển"
        case .muWally: return "MU Wally"
        case .united: return "MU"
        }
    }
}

/// One MU palette as raw hex + alpha pairs, so the SwiftUI
/// tokens (MUTokens) and the UIKit chrome (MUUIColor in
/// MUPlayerChrome.swift) render from ONE table and can never
/// drift apart. Two palettes exist (FIX-MU-5, item G): the
/// approved design's (`.drawing` — the spec's exact hex) and
/// "MU Wally" (`.wally` — the tvOS 1.7.2 MU look, extracted
/// from dabanh-tvos TVTheme.swift / TVMatchViews.swift /
/// TVPlayerView.swift at the 1.7.2 state; every differing
/// value's source is listed in theme-mu/FIX-MU-5-REPORT.md).
struct MURawPalette {
    let bg: UInt32, card: UInt32, red: UInt32, hotRed: UInt32
    let gold: UInt32, cream: UInt32, scoreBright: UInt32
    let secondary: UInt32
    let border: UInt32, borderAlpha: Double
    let selectedFill: UInt32
    let featuredBase: UInt32, featuredBorder: UInt32
    let featuredSeparator: UInt32, featuredSeparatorAlpha: Double
    let featuredGradientTop: UInt32, featuredGradientBottom: UInt32
    let panelAlt: UInt32
    /// The CTA gradient's trailing stop (its leading stop is
    /// always `red`).
    let ctaEnd: UInt32

    /// The approved design's palette (delivery-united-phone
    /// spec, IDENTITY / VISUAL SYSTEM) — the values MUTokens
    /// carried as constants before the palette switch.
    static let drawing = MURawPalette(
        bg: 0x0B0E13, card: 0x171B22, red: 0xDA291C, hotRed: 0xE10600,
        gold: 0xC9A86A, cream: 0xF2E6C8, scoreBright: 0xFFF4E7,
        secondary: 0xA9ADB7,
        border: 0x30343D, borderAlpha: 1.0,
        selectedFill: 0x3A211F,
        featuredBase: 0x261A1C, featuredBorder: 0x804336,
        featuredSeparator: 0xC9A86A, featuredSeparatorAlpha: 0.15,
        featuredGradientTop: 0x361B1B, featuredGradientBottom: 0x171B22,
        panelAlt: 0x20252E,
        ctaEnd: 0xE10600)

    /// The "MU Wally" palette: the shipped tvOS 1.7.2 MU look
    /// (dabanh-tvos tree, 1.7.2 state). Only the slots the TV
    /// look defines differently carry different values; the
    /// rest match the drawing palette because the TV theme
    /// itself uses the same hex there.
    static let wally = MURawPalette(
        bg: 0x0B0E13, card: 0x171B22, red: 0xDA291C, hotRed: 0xE10600,
        gold: 0xC9A86A, cream: 0xF2E6C8, scoreBright: 0xEEF4FC,
        secondary: 0x9AA0A8,
        border: 0xFFFFFF, borderAlpha: 0.14,
        selectedFill: 0x4A1A1A,
        featuredBase: 0x171B22, featuredBorder: 0xC9A86A,
        featuredSeparator: 0xFFFFFF, featuredSeparatorAlpha: 0.12,
        featuredGradientTop: 0x4A1A1A, featuredGradientBottom: 0x0B0E13,
        panelAlt: 0x171B22,
        ctaEnd: 0xDA291C)

    /// The palette the MU surfaces paint with NOW: Wally only
    /// while the stored theme is MU Wally; the drawing palette
    /// for the drawing MU (and, vacuously, under classic —
    /// classic never reads these tokens). Read from the same
    /// UserDefaults key ThemeStore persists, so every surface
    /// (SwiftUI bodies, the once-built UIKit chrome) agrees.
    static var current: MURawPalette {
        UserDefaults.standard.string(forKey: "dabanh-theme") == AppThemeID.muWally.rawValue
            ? .wally : .drawing
    }
}

/// The Manchester United token set — read ONLY by MU
/// surfaces; classic never sees it. Values are computed from
/// MURawPalette.current (FIX-MU-5, item G): the two MU-family
/// themes share every layout and differ only in this table.
/// Tokens the tvOS look does not define (pressed fill, sheet
/// furniture, theme border) are palette-invariant constants
/// below, identical under both MU themes.
enum MUTokens {
    static var bg: Color { boardColor(MURawPalette.current.bg) }
    static var card: Color { boardColor(MURawPalette.current.card) }
    static var red: Color { boardColor(MURawPalette.current.red) }
    static var hotRed: Color { boardColor(MURawPalette.current.hotRed) }
    static var gold: Color { boardColor(MURawPalette.current.gold) }
    static var cream: Color { boardColor(MURawPalette.current.cream) }
    static var scoreBright: Color { boardColor(MURawPalette.current.scoreBright) }
    static var secondary: Color { boardColor(MURawPalette.current.secondary) }
    static var border: Color {
        boardColor(MURawPalette.current.border)
            .opacity(MURawPalette.current.borderAlpha)
    }
    static var selectedFill: Color { boardColor(MURawPalette.current.selectedFill) }
    static var featuredBase: Color { boardColor(MURawPalette.current.featuredBase) }
    static var featuredBorder: Color { boardColor(MURawPalette.current.featuredBorder) }
    static var panelAlt: Color { boardColor(MURawPalette.current.panelAlt) }
    /// Featured separators: drawing #C9A86A26 (gold at 15%) /
    /// Wally white at 12% (the TV eventsLine).
    static var featuredSeparator: Color {
        boardColor(MURawPalette.current.featuredSeparator)
            .opacity(MURawPalette.current.featuredSeparatorAlpha)
    }
    /// The featured card's art gradient (the spec's 8-digit
    /// hex carries the alpha: E8 → B3). Wally keeps the wash
    /// alphas; its stop COLOURS are the TV focused-face
    /// gradient's (tileFocusedBG → boardBG).
    static var featuredGradientTop: Color {
        boardColor(MURawPalette.current.featuredGradientTop).opacity(0xE8 / 255.0)
    }
    static var featuredGradientBottom: Color {
        boardColor(MURawPalette.current.featuredGradientBottom).opacity(0xB3 / 255.0)
    }
    /// The primary CTA's red gradient: the drawing runs
    /// United red into the reserved hot accent; the TV 1.7.2
    /// Watch button runs unitedRed → minuteRed (the same
    /// #DA291C twice — a flat red), which the Wally palette
    /// carries as its ctaEnd.
    static var ctaGradient: LinearGradient {
        let raw = MURawPalette.current
        return LinearGradient(
            colors: [boardColor(raw.red), boardColor(raw.ctaEnd)],
            startPoint: .leading, endPoint: .trailing)
    }

    // Palette-invariant tokens (no tvOS counterpart — the
    // phone spec's values, identical under both MU themes).
    static let pressedFill = boardColor(0x60261F)
    static let themeBorder = boardColor(0x695336)
    static let sheetOverlay = boardColor(0x07090D)
    static let sheetBorder = boardColor(0x48413A)
    static let handle = boardColor(0x66636A)
}

// MARK: - Fonts

/// The MU type system: Barlow Condensed 800 for display,
/// Outfit 400/500/600/700 for body (design TYPE section).
///
/// Barlow Condensed is bundled (DaBanh/Fonts/
/// BarlowCondensed-ExtraBold.ttf, Vietnamese subset VERIFIED:
/// 0 missing in the Vietnamese base set, U+1EA0–1EF9 90/90).
///
/// ⚠️ OUTFIT BLOCKER (recorded in theme-mu/IMPL-REPORT.md):
/// Outfit's upstream character set contains NO Vietnamese
/// glyphs at all (no Ơ/Ư, no horn/hook/dot-below combiners —
/// verified against the google/fonts variable font's cmap
/// and the webfonts-helper statics). No Vietnamese-capable
/// Outfit TTF exists to bundle, and no substitute family may
/// be shipped silently — so `body` resolves through the
/// intended PostScript names when they are registered and
/// falls back to the system font at the same size/weight
/// until a Vietnamese-capable Outfit is sourced. Dropping
/// real Outfit TTFs into the bundle + UIAppFonts activates
/// them with no code change.
///
/// FIX-133 (2026-11-22, theme-mu/FONT-SUBSTITUTE-NOTE.md):
/// the owner chose Manrope as the sanctioned substitute —
/// the closest face to Outfit with FULL Vietnamese coverage
/// (measured: 0/104 missing, Outfit misses 92/104). Manrope
/// is bundled (DaBanh/Fonts/Manrope-*.ttf) and resolves ONLY
/// under the drawing United theme: `bodyPSName` returns the
/// Manrope names while the stored theme is `.united`, and
/// the Outfit names (→ the system fallback, exactly as
/// before) under MU Wally — Wally's typography is untouched,
/// and classic never reads MUFont at all.
enum MUFont {
    static let displayPSName = "BarlowCondensed-ExtraBold"

    enum BodyWeight {
        case regular, medium, semibold, bold
        var psName: String {
            switch self {
            case .regular: return "Outfit-Regular"
            case .medium: return "Outfit-Medium"
            case .semibold: return "Outfit-SemiBold"
            case .bold: return "Outfit-Bold"
            }
        }
        /// The sanctioned substitute's PostScript names
        /// (FIX-133 — verified against the bundled files'
        /// own name tables).
        var manropePSName: String {
            switch self {
            case .regular: return "Manrope-Regular"
            case .medium: return "Manrope-Medium"
            case .semibold: return "Manrope-SemiBold"
            case .bold: return "Manrope-Bold"
            }
        }
        var systemWeight: Font.Weight {
            switch self {
            case .regular: return .regular
            case .medium: return .medium
            case .semibold: return .semibold
            case .bold: return .bold
            }
        }
        var uiWeight: UIFont.Weight {
            switch self {
            case .regular: return .regular
            case .medium: return .medium
            case .semibold: return .semibold
            case .bold: return .bold
            }
        }
    }

    /// Display (Barlow Condensed 800). Tracking −.015em is
    /// applied by the caller via `muDisplayTracking(_:)`.
    static func display(_ size: CGFloat) -> Font {
        if UIFont(name: displayPSName, size: size) != nil {
            return .custom(displayPSName, size: size)
        }
        return .system(size: size, weight: .heavy)
    }

    /// The body face's PostScript name for the ACTIVE theme
    /// (FIX-133): Manrope under the drawing United theme
    /// only; the Outfit names everywhere else, so MU Wally
    /// keeps resolving to the system fallback exactly as it
    /// did before Manrope was bundled. Read from the same
    /// UserDefaults key ThemeStore persists — the same read
    /// MURawPalette.current makes, so fonts and colours can
    /// never disagree about which MU theme is up.
    static func bodyPSName(_ weight: BodyWeight) -> String {
        UserDefaults.standard.string(forKey: "dabanh-theme") == AppThemeID.united.rawValue
            ? weight.manropePSName : weight.psName
    }

    static func body(_ size: CGFloat, _ weight: BodyWeight = .regular) -> Font {
        let name = bodyPSName(weight)
        if UIFont(name: name, size: size) != nil {
            return .custom(name, size: size)
        }
        return .system(size: size, weight: weight.systemWeight)
    }

    // UIKit twins (the MU player chrome is UIKit).

    static func uiDisplay(_ size: CGFloat) -> UIFont {
        UIFont(name: displayPSName, size: size)
            ?? .systemFont(ofSize: size, weight: .heavy)
    }

    static func uiBody(_ size: CGFloat, _ weight: BodyWeight = .regular) -> UIFont {
        UIFont(name: bodyPSName(weight), size: size)
            ?? .systemFont(ofSize: size, weight: weight.uiWeight)
    }
}

extension View {
    /// The design's display tracking: −.015em on Barlow text.
    func muDisplayTracking(_ size: CGFloat) -> some View {
        tracking(-0.015 * size)
    }
}

// MARK: - Pressed state (FIX-MU-3, finding 1)

/// Carries a button's pressed flag into its label subtree:
/// `MUPressButtonStyle` injects it, label backgrounds read
/// it (via `MUPressedBackground`, or directly in a view used
/// as label content) to swap their fill to the design's
/// pressed fill while the press lasts.
private struct MUPressedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var muIsPressed: Bool {
        get { self[MUPressedKey.self] }
        set { self[MUPressedKey.self] = newValue }
    }
}

/// The MU button style (spec COMMON / deviation G-4):
/// pressed = fill #60261F (via the injected environment —
/// the label's own background paints it) + scale .98.
/// Replaces `.plain` on every MU SwiftUI button surface.
struct MUPressButtonStyle: ButtonStyle {
    /// FIX-MU-5 (#30): the press scale is motion — with
    /// Reduce Motion on, the press applies no scale at all
    /// (the pressed-fill swap is not motion and stays).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .environment(\.muIsPressed, configuration.isPressed)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1.0)
    }
}

/// A shape fill that swaps to `MUTokens.pressedFill` while
/// the enclosing MU button is pressed — the background
/// half of the pressed state, for labels whose normal fill
/// is a flat colour or the CTA gradient.
struct MUPressedBackground<S: Shape>: View {
    @Environment(\.muIsPressed) private var isPressed
    private let shape: S
    private let normal: AnyShapeStyle

    init(_ shape: S, _ normal: some ShapeStyle) {
        self.shape = shape
        self.normal = AnyShapeStyle(normal)
    }

    var body: some View {
        shape.fill(isPressed ? AnyShapeStyle(MUTokens.pressedFill) : normal)
    }
}

// MARK: - Store

/// The theme selection, persisted in UserDefaults under
/// `dabanh-theme` (values classic/united) and nowhere else —
/// the tvOS store's shape. Unknown stored values fall back
/// to the classic theme, which is also the default.
@MainActor
final class ThemeStore: ObservableObject {
    @Published private(set) var themeID: AppThemeID
    /// The MU wallpaper choice (FIX-MU-5, item A — the Hình
    /// nền settings page): the picked image's URL string,
    /// persisted in UserDefaults under `dabanh-mu-wallpaper`;
    /// nil = "Tự động" (the list's first image). Published so
    /// the MU home and the MU detail hero re-read
    /// MUWallpapers.heroImage() the moment it changes.
    @Published private(set) var wallpaperChoice: String?

    var isMU: Bool { themeID.isMU }

    init() {
        if let raw = UserDefaults.standard.string(forKey: "dabanh-theme"),
           let stored = AppThemeID(rawValue: raw) {
            themeID = stored
        } else {
            themeID = .classic
        }
        wallpaperChoice = UserDefaults.standard.string(forKey: "dabanh-mu-wallpaper")
    }

    func select(_ id: AppThemeID) {
        themeID = id
        UserDefaults.standard.set(id.rawValue, forKey: "dabanh-theme")
        DiagLog.log("theme", "selected \(id.rawValue)")
    }

    func selectWallpaper(_ urlString: String?) {
        wallpaperChoice = urlString
        if let urlString {
            UserDefaults.standard.set(urlString, forKey: "dabanh-mu-wallpaper")
        } else {
            UserDefaults.standard.removeObject(forKey: "dabanh-mu-wallpaper")
        }
        DiagLog.log("theme", "wallpaper \(urlString == nil ? "auto" : "picked")")
    }

    /// Đặt lại tùy chọn (FIX-MU-5, item A): theme back to
    /// classic, the wallpaper choice cleared, and the three
    /// playback preference keys removed (their defaults —
    /// auto quality, Vietnamese, auto-backup ON — apply).
    func resetPreferences() {
        select(.classic)
        selectWallpaper(nil)
        for key in [MUPlaybackPrefs.qualityKey, MUPlaybackPrefs.langKey,
                    MUPlaybackPrefs.autoBackupKey] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        DiagLog.log("theme", "preferences reset to defaults")
    }
}

/// The Phát lại preferences (FIX-MU-5, item A): plain
/// UserDefaults reads at the use sites — the settings page
/// writes the keys, the player / detail read them through
/// here so the key strings exist exactly once.
enum MUPlaybackPrefs {
    static let qualityKey = "dabanh-playback-quality"
    static let langKey = "dabanh-playback-lang"
    static let autoBackupKey = "dabanh-playback-autobackup"

    /// "auto" / "1080" / "720" (default "auto").
    static var quality: String {
        UserDefaults.standard.string(forKey: qualityKey) ?? "auto"
    }
    /// The MU player's starting rendition cap, in the SAME
    /// bit-rate values the in-player quality sheet applies
    /// (muQualityTapped): 1080p = 6 Mbps, 720p = 2.2 Mbps,
    /// Tự động = no cap (0).
    static var qualityCap: Double {
        switch quality {
        case "1080": return 6_000_000
        case "720": return 2_200_000
        default: return 0
        }
    }
    /// "vi" / "en" (default "vi") — the commentary language
    /// the MU detail's DEFAULT selection prefers.
    static var lang: String {
        UserDefaults.standard.string(forKey: langKey) ?? "vi"
    }
    /// Tự động chuyển nguồn dự phòng (default ON): gates the
    /// player's AUTO failover paths only — see advance() and
    /// publishHeadNow() in PlayerView.swift.
    static var autoBackup: Bool {
        UserDefaults.standard.object(forKey: autoBackupKey) as? Bool ?? true
    }
}

// MARK: - Settings sheet (FIX-MU-5, item A)

/// The full Settings sheet (spec §SETTINGS / SHEETS): a
/// four-page sheet — Menu / Giao diện / Hình nền / Phát
/// lại — over a dim overlay, top radius 24 (set at the
/// ContentView presentation sites), padding 20, title
/// 26/800, close 44, and the sheetBorder stroke around the
/// container (#180). It replaces the 1.31 theme picker,
/// which was the Giao diện page alone (audit #171/#185).
/// The sheet is new UI in BOTH themes (the classic app had
/// no settings surface), so it paints in the design's sheet
/// language either way; selecting a theme tile applies it
/// at once and dismisses, as the picker did.
struct MUSettingsView: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.dismiss) private var dismiss

    private enum Page {
        case menu, themes, wallpaper, playback
    }
    @State private var page: Page = .menu
    /// Đặt lại tùy chọn's two-tap arm (#177): the first tap
    /// arms the row, the second applies; changing page
    /// disarms (see the onChange below).
    @State private var resetArmed = false
    /// The Phát lại page's working copies (the keys are the
    /// source of truth — MUPlaybackPrefs reads them; these
    /// exist so the rows re-render on tap).
    @State private var quality = MUPlaybackPrefs.quality
    @State private var lang = MUPlaybackPrefs.lang
    @State private var autoBackup = MUPlaybackPrefs.autoBackup
    @State private var wallpaperURLs: [URL] = MUWallpapers.urls

    private var pageTitle: String {
        switch page {
        case .menu: return "Cài đặt"
        case .themes: return "Giao diện"
        case .wallpaper: return "Hình nền"
        case .playback: return "Phát lại"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                Text(pageTitle)
                    .font(MUFont.display(26))
                    .muDisplayTracking(26)
                    .foregroundStyle(MUTokens.cream)
                Spacer(minLength: 8)
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(MUTokens.cream)
                        .frame(width: 44, height: 44)
                        .background(MUPressedBackground(Circle(), MUTokens.card))
                        .overlay(Circle().stroke(MUTokens.border, lineWidth: 1))
                }
                .buttonStyle(MUPressButtonStyle())
                .accessibilityLabel("Đóng")
            }

            ScrollView(showsIndicators: false) {
                switch page {
                case .menu: menuPage
                case .themes: themesPage
                case .wallpaper: wallpaperPage
                case .playback: playbackPage
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MUTokens.card.ignoresSafeArea())
        // #180: the sheet container's border — sheetBorder
        // 1 pt, drawn inside a rounded rect matching the
        // presentation's 24 radius.
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(MUTokens.sheetBorder, lineWidth: 1)
        )
        .preferredColorScheme(.dark)
        .onChange(of: page) { _, _ in resetArmed = false }
        .task {
            if await MUWallpapers.refreshRemote() {
                wallpaperURLs = MUWallpapers.urls
            }
        }
    }

    // MARK: Menu page

    private var menuPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            menuRow("Giao diện") { page = .themes }
            menuDivider
            menuRow("Hình nền") { page = .wallpaper }
            menuDivider
            menuRow("Phát lại") { page = .playback }
            menuDivider
            resetRow
            menuDivider
            versionRow
        }
    }

    /// The running build's own stamp, read from the bundle
    /// at render time (VERSION-IN-SETTINGS LAW, owner order
    /// 2026-11-24): every build shows its full version +
    /// build number in Settings, e.g. "1.40 (41)", so the
    /// owner can tell at a glance which build is installed.
    /// Never hardcode the numbers here — they come from the
    /// Info.plist the build itself was stamped with.
    private var versionRow: some View {
        HStack(spacing: 8) {
            Text("Phiên bản")
                .font(MUFont.body(13))
                .foregroundStyle(MUTokens.cream)
            Spacer(minLength: 8)
            Text(Self.appVersionText)
                .font(MUFont.body(13))
                .foregroundStyle(MUTokens.secondary)
        }
        .frame(minHeight: 52)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Phiên bản \(Self.appVersionText)")
    }

    private static var appVersionText: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    private var menuDivider: some View {
        Rectangle().fill(MUTokens.border).frame(height: 1)
    }

    /// One settings menu row (spec: min-height 52, font 13,
    /// chevron).
    private func menuRow(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(label)
                    .font(MUFont.body(13))
                    .foregroundStyle(MUTokens.cream)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(MUTokens.secondary)
            }
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(MUPressButtonStyle())
    }

    /// Đặt lại tùy chọn (#177): two taps — the first arms
    /// (the row renames itself and takes the maroon fill),
    /// the second applies the reset and returns to the menu.
    private var resetRow: some View {
        Button {
            if resetArmed {
                themeStore.resetPreferences()
                quality = MUPlaybackPrefs.quality
                lang = MUPlaybackPrefs.lang
                autoBackup = MUPlaybackPrefs.autoBackup
                resetArmed = false
                page = .menu
            } else {
                resetArmed = true
            }
        } label: {
            HStack(spacing: 8) {
                Text(resetArmed ? "Xác nhận đặt lại tùy chọn" : "Đặt lại tùy chọn")
                    .font(MUFont.body(13))
                    .foregroundStyle(resetArmed ? MUTokens.gold : MUTokens.cream)
                Spacer(minLength: 8)
                Image(systemName: resetArmed ? "exclamationmark.triangle" : "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(resetArmed ? MUTokens.gold : MUTokens.secondary)
            }
            .padding(.horizontal, resetArmed ? 10 : 0)
            .frame(minHeight: 52)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(resetArmed ? MUTokens.selectedFill : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(MUPressButtonStyle())
    }

    /// The back-to-menu row heading each sub-page.
    private var backRow: some View {
        Button {
            page = .menu
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                Text("Cài đặt")
                    .font(MUFont.body(13, .medium))
            }
            .foregroundStyle(MUTokens.gold)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(MUPressButtonStyle())
    }

    // MARK: Giao diện page (the theme tiles)

    private var themesPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            backRow
            Text("Chọn giao diện cho ứng dụng. Thay đổi áp dụng ngay.")
                .font(MUFont.body(12))
                .foregroundStyle(MUTokens.secondary)
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 10),
                          GridItem(.flexible(), spacing: 10)],
                spacing: 10
            ) {
                tile(.classic, subtitle: "Giao diện gốc của Đá Banh")
                tile(.muWally, subtitle: "Bản MU tự dựng của Wally")
                tile(.united, subtitle: "Đỏ United · Đen · Vàng kim")
            }
            Text("Các giao diện Manchester United là giao diện thêm vào — mọi tính năng phát hình giữ nguyên ở mọi giao diện.")
                .font(MUFont.body(10))
                .foregroundStyle(MUTokens.secondary)
                .lineSpacing(4)
        }
    }

    // MARK: Hình nền page (#175)

    private var wallpaperPage: some View {
        VStack(alignment: .leading, spacing: 8) {
            backRow
            optionRow("Tự động", selected: themeStore.wallpaperChoice == nil) {
                themeStore.selectWallpaper(nil)
            }
            if wallpaperURLs.isEmpty {
                Text("Đang tải danh sách hình nền…")
                    .font(MUFont.body(12))
                    .foregroundStyle(MUTokens.secondary)
                    .padding(.top, 8)
            } else {
                ForEach(Array(wallpaperURLs.enumerated()), id: \.element) { index, url in
                    wallpaperRow(url, index: index)
                }
            }
        }
    }

    /// One wallpaper option: the design's thumbnail (height
    /// 64, radius 9, cover) in a #185 option row — selected
    /// takes gold text + maroon fill.
    private func wallpaperRow(_ url: URL, index: Int) -> some View {
        let selected = themeStore.wallpaperChoice == url.absoluteString
        return Button {
            themeStore.selectWallpaper(url.absoluteString)
        } label: {
            HStack(spacing: 10) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        MUTokens.bg
                    }
                }
                .frame(width: 96, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                Text("Hình nền \(index + 1)")
                    .font(MUFont.body(13))
                    .foregroundStyle(selected ? MUTokens.gold : MUTokens.cream)
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(MUTokens.gold)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minHeight: 52)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(selected ? MUTokens.selectedFill : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(MUPressButtonStyle())
    }

    // MARK: Phát lại page (#176)

    private var playbackPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            backRow
            settingsGroupTitle("Chất lượng mặc định")
            VStack(spacing: 4) {
                optionRow("Tự động", selected: quality == "auto") { setQuality("auto") }
                optionRow("1080p", selected: quality == "1080") { setQuality("1080") }
                optionRow("720p", selected: quality == "720") { setQuality("720") }
            }
            settingsGroupTitle("Ngôn ngữ bình luận ưu tiên")
            VStack(spacing: 4) {
                optionRow("Tiếng Việt", selected: lang == "vi") { setLang("vi") }
                optionRow("Tiếng Anh", selected: lang == "en") { setLang("en") }
            }
            settingsGroupTitle("Tự động chuyển nguồn dự phòng")
            HStack(spacing: 8) {
                Text("Tự chuyển nguồn khi nguồn đang phát lỗi")
                    .font(MUFont.body(13))
                    .foregroundStyle(MUTokens.cream)
                Spacer(minLength: 8)
                Toggle("", isOn: $autoBackup)
                    .labelsHidden()
                    .tint(MUTokens.red)
                    .onChange(of: autoBackup) { _, newValue in
                        UserDefaults.standard.set(newValue, forKey: MUPlaybackPrefs.autoBackupKey)
                        DiagLog.log("theme", "playback auto-backup \(newValue ? "on" : "off")")
                    }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 52)
        }
    }

    private func settingsGroupTitle(_ text: String) -> some View {
        Text(text)
            .font(MUFont.body(13, .medium))
            .foregroundStyle(MUTokens.cream)
            .padding(.top, 16)
            .padding(.bottom, 8)
    }

    private func setQuality(_ value: String) {
        quality = value
        UserDefaults.standard.set(value, forKey: MUPlaybackPrefs.qualityKey)
        DiagLog.log("theme", "playback quality default \(value)")
    }

    private func setLang(_ value: String) {
        lang = value
        UserDefaults.standard.set(value, forKey: MUPlaybackPrefs.langKey)
        DiagLog.log("theme", "playback language preference \(value)")
    }

    /// One settings option row (#185): min-height 52, font
    /// 13; selected = gold text + maroon fill + horizontal
    /// padding 10, radius 10.
    private func optionRow(_ label: String, selected: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(label)
                    .font(MUFont.body(13))
                    .foregroundStyle(selected ? MUTokens.gold : MUTokens.cream)
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(MUTokens.gold)
                }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 52)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(selected ? MUTokens.selectedFill : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(MUPressButtonStyle())
    }

    /// One theme tile (spec: 2-column, radius 14, padding 12,
    /// min height 92): a small preview block in the theme's
    /// own colours, then its name; the selected tile gets the
    /// maroon fill, the gold border and the gold check.
    private func tile(_ id: AppThemeID, subtitle: String) -> some View {
        let selected = themeStore.themeID == id
        return Button {
            themeStore.select(id)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                preview(id)
                    .frame(height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .overlay(alignment: .topTrailing) {
                        if selected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(MUTokens.gold)
                                .padding(6)
                        }
                    }
                Text(id.pickerName)
                    .font(MUFont.body(13, .semibold))
                    .foregroundStyle(MUTokens.cream)
                    .multilineTextAlignment(.leading)
                Text(subtitle)
                    .font(MUFont.body(10))
                    .foregroundStyle(MUTokens.secondary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
            .background(
                MUPressedBackground(
                    RoundedRectangle(cornerRadius: 14),
                    selected ? MUTokens.selectedFill : MUTokens.bg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(selected ? MUTokens.gold : MUTokens.border,
                            lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(MUPressButtonStyle())
    }

    /// The tile's preview block, painted in the CANDIDATE
    /// theme's own tokens (a navy skeleton for classic; a
    /// maroon/gold composition per MU palette — each MU tile
    /// renders from its OWN raw palette, so the two MU tiles
    /// stay distinguishable whichever theme is active).
    @ViewBuilder
    private func preview(_ id: AppThemeID) -> some View {
        switch id {
        case .classic:
            ZStack {
                BoardPalette.bg
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 4).fill(BoardPalette.tileBG)
                        .frame(width: 26, height: 14)
                    RoundedRectangle(cornerRadius: 4).fill(accentGreen)
                        .frame(width: 26, height: 14)
                    RoundedRectangle(cornerRadius: 4).fill(BoardPalette.sky)
                        .frame(width: 26, height: 14)
                }
            }
        case .muWally:
            swatchComposition(.wally)
        case .united:
            swatchComposition(.drawing)
        }
    }

    private func swatchComposition(_ raw: MURawPalette) -> some View {
        ZStack {
            boardColor(raw.featuredBase)
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 4).fill(boardColor(raw.gold))
                    .frame(width: 26, height: 14)
                RoundedRectangle(cornerRadius: 4).fill(boardColor(raw.red))
                    .frame(width: 26, height: 14)
                RoundedRectangle(cornerRadius: 4).fill(boardColor(raw.cream))
                    .frame(width: 26, height: 14)
            }
        }
    }
}
