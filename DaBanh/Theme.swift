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
    case united

    var isMU: Bool { self == .united }
    /// The picker's display name for this theme.
    var pickerName: String {
        switch self {
        case .classic: return "Cổ điển"
        case .united: return "Manchester United"
        }
    }
    /// The header pill's short name (the design's pill shows
    /// the current theme's name).
    var pillName: String {
        switch self {
        case .classic: return "Cổ điển"
        case .united: return "MU"
        }
    }
}

/// The Manchester United token set — the approved design's
/// exact hex (delivery-united-phone-spec, IDENTITY / VISUAL
/// SYSTEM). Read ONLY by MU surfaces; classic never sees it.
enum MUTokens {
    static let bg = boardColor(0x0B0E13)
    static let card = boardColor(0x171B22)
    static let red = boardColor(0xDA291C)
    static let hotRed = boardColor(0xE10600)
    static let gold = boardColor(0xC9A86A)
    static let cream = boardColor(0xF2E6C8)
    static let scoreBright = boardColor(0xFFF4E7)
    static let secondary = boardColor(0xA9ADB7)
    static let border = boardColor(0x30343D)
    static let selectedFill = boardColor(0x3A211F)
    static let pressedFill = boardColor(0x60261F)
    static let featuredBase = boardColor(0x261A1C)
    static let featuredBorder = boardColor(0x804336)
    static let panelAlt = boardColor(0x20252E)
    static let themeBorder = boardColor(0x695336)
    static let sheetOverlay = boardColor(0x07090D)
    static let sheetBorder = boardColor(0x48413A)
    static let handle = boardColor(0x66636A)
    /// Featured separators #C9A86A26 (gold at 15%).
    static let featuredSeparator = boardColor(0xC9A86A).opacity(0.15)

    /// The featured card's art gradient: #361B1BE8 →
    /// #171B22B3 (the spec's 8-digit hex carries the alpha).
    static let featuredGradientTop = boardColor(0x361B1B).opacity(0xE8 / 255.0)
    static let featuredGradientBottom = boardColor(0x171B22).opacity(0xB3 / 255.0)

    /// The primary CTA's red gradient (design: United red
    /// running into the reserved hot accent).
    static let ctaGradient = LinearGradient(
        colors: [red, hotRed], startPoint: .leading, endPoint: .trailing)
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

    static func body(_ size: CGFloat, _ weight: BodyWeight = .regular) -> Font {
        if UIFont(name: weight.psName, size: size) != nil {
            return .custom(weight.psName, size: size)
        }
        return .system(size: size, weight: weight.systemWeight)
    }

    // UIKit twins (the MU player chrome is UIKit).

    static func uiDisplay(_ size: CGFloat) -> UIFont {
        UIFont(name: displayPSName, size: size)
            ?? .systemFont(ofSize: size, weight: .heavy)
    }

    static func uiBody(_ size: CGFloat, _ weight: BodyWeight = .regular) -> UIFont {
        UIFont(name: weight.psName, size: size)
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
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .environment(\.muIsPressed, configuration.isPressed)
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
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

    var isMU: Bool { themeID.isMU }

    init() {
        if let raw = UserDefaults.standard.string(forKey: "dabanh-theme"),
           let stored = AppThemeID(rawValue: raw) {
            themeID = stored
        } else {
            themeID = .classic
        }
    }

    func select(_ id: AppThemeID) {
        themeID = id
        UserDefaults.standard.set(id.rawValue, forKey: "dabanh-theme")
        DiagLog.log("theme", "selected \(id.rawValue)")
    }
}

// MARK: - Theme picker sheet

/// The compact theme picker (spec §06 sheet + SETTINGS theme
/// tiles): a sheet over a dim overlay, top radius 24, padding
/// 20, title 26/800, the two theme tiles side by side; the
/// selected tile wears the design's selected state (fill
/// #3A211F, 1 pt gold border, gold check). Selecting a tile
/// applies it at once and dismisses. The sheet is new UI in
/// BOTH themes (the classic app had no settings surface), so
/// it paints in the design's sheet language either way.
struct ThemePickerView: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Giao diện")
                        .font(MUFont.display(26))
                        .muDisplayTracking(26)
                        .foregroundStyle(MUTokens.cream)
                    Text("Chọn giao diện cho ứng dụng. Thay đổi áp dụng ngay.")
                        .font(MUFont.body(12))
                        .foregroundStyle(MUTokens.secondary)
                }
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

            HStack(spacing: 10) {
                tile(.classic, subtitle: "Giao diện gốc của Đá Banh")
                tile(.united, subtitle: "Đỏ United · Đen · Vàng kim")
            }

            Text("Manchester United là giao diện thêm vào — mọi tính năng phát hình giữ nguyên ở cả hai giao diện.")
                .font(MUFont.body(10))
                .foregroundStyle(MUTokens.secondary)
                .lineSpacing(4)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MUTokens.card.ignoresSafeArea())
        .preferredColorScheme(.dark)
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
    /// theme's own tokens (a navy skeleton for classic, a
    /// maroon/gold composition for United).
    @ViewBuilder
    private func preview(_ id: AppThemeID) -> some View {
        if id.isMU {
            ZStack {
                MUTokens.featuredBase
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 4).fill(MUTokens.gold)
                        .frame(width: 26, height: 14)
                    RoundedRectangle(cornerRadius: 4).fill(MUTokens.red)
                        .frame(width: 26, height: 14)
                    RoundedRectangle(cornerRadius: 4).fill(MUTokens.cream)
                        .frame(width: 26, height: 14)
                }
            }
        } else {
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
        }
    }
}
