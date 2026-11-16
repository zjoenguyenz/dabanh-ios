# FRAME-HUNT REPORT — Joe TV tvOS "theme frame" (blue→magenta rim)

Team FRAME-HUNT · 2026-11-15 (owner escalation 22:13 CST: *"Lỗi theme ko fai do os đâu"*)

## VERDICT — convicted, app-side, one mechanism

**Joe TV's root background layer never paints the screen's rim.** In
`JoeRootView` the background is a bare `theme.bg` colour layer with **no
`.ignoresSafeArea()`** (`JoeTV/JoeTVApp.swift:185`, repeated for the two
detail layers at `:199` and `:217`). On tvOS a SwiftUI root background
that does not opt out of the safe area is laid out inside the tvOS safe
area — the overscan inset of **80 pt on the sides, 60 pt top/bottom**
(Apple HIG, Layout). The content therefore sits inset (correct, by
design), but so does the background paint (the defect): the rim outside
the safe area is left unpainted by the app, and the system composites
what sits behind the app window — on this box, the owner's tvOS
wallpaper, a blue→pink/purple gradient — producing exactly the
photographed bright gradient band around all four edges with the
content inset inside it.

The app does not draw the band. The app **fails to cover** the band.
That is why the owner's ruling is right in the way that matters: the
defect is the app's missing paint, not an OS malfunction — Đá Banh TV
on the same box, same OS, same wallpaper shows no band, because its
root background is built differently (see the A/B diff, §2).

The earlier forensics conclusion ("the app draws no frame") read the
background's **value** (flat `#0A0A0A` / black — true) but never its
**extent** (safe-area-bound — the miss), and never diffed the root
against the sibling apps in this repo.

## 1. The Joe TV root path (evidence)

`JoeTV/JoeTVApp.swift` — `@main JoeTVApp` (lines 10–40) is a plain
`WindowGroup { JoeRootView() … }`; no scene background, no
`UIWindow`/`UIHostingController` code anywhere in the target (grep:
the only `backgroundColor` writes in the target are the KSPlayer
UIView's own black, `JoeKSPlayerView.swift:88,98`, inside the player).

`JoeRootView.body` (JoeTVApp.swift:183–217):

```swift
ZStack {
    theme.bg                                   // :185 — bare, no .ignoresSafeArea()
    VStack(spacing: 32) { topBar; content }    // content respects the safe area (§4/HIG — correct)
    if let route = nav.movie {
        ZStack { theme.bg; JoeMovieDetail(route: route) }   // :199 — same bare layer
    }
    if let route = nav.tor {
        ZStack { theme.bg; JoeTorrentDetail(route: route) } // :217 — same bare layer
    }
}
```

Full-target grep for `ignoresSafeArea` in `JoeTV/*.swift` returns
**only** the player: `JoePlayerView.swift:295, 313, 324, 329, 509`.
No `safeAreaInset`, no `containerBackground`, no scene-level
background anywhere in the target.

Every screen the owner photographed with the band hangs under this
one root layer:

- **Home (Phim/TV/Torrent sections)** — sections paint no full-screen
  background of their own (grep: the only `.background(theme.bg)`
  sites are a top-bar label, `JoeTVApp.swift:439`, and a card body,
  `JoeTheme.swift:466`); they inherit the root layer.
- **Settings** — `JoeSettings.swift:49–50`: the body is a bare
  `ScrollView`; the file contains no background at all. Same rim,
  same cause — matching the owner's Settings photo.
- **Search / Browse layers** (`JoePhimHome.swift:68ff`) — same root.

## 2. A/B diff — the working apps in this same repo

| | Đá Banh TV (no band) | TV app (no band) | Joe TV (band) |
|---|---|---|---|
| App struct | `DaBanhTV/DaBanhTVApp.swift:7–15` | `TVApp/TVApp.swift:9` | `JoeTV/JoeTVApp.swift:10` |
| Root view | `TVContentView` | `TVHomeView` | `JoeRootView` |
| Root background | `LinearGradient` (deep teal), `TVContentView.swift:150–157` | `LinearGradient` (indigo), `TVHomeView.swift:122–128` | flat `theme.bg` colour, `JoeTVApp.swift:185` |
| **`.ignoresSafeArea()` on the root background** | **YES — `TVContentView.swift:156`** | **YES — `TVHomeView.swift:128`** | **NONE — anywhere in the root path** |
| Content inset | manual padding 60/40/28 (`TVContentView.swift:104–106`) | own layout | tvOS safe area, no added padding (JoeTVApp.swift §4 comment) |

This answers the counter-check directly: Đá Banh TV does not merely
*hide* a rim behind a bright background — its background is
explicitly extended edge-to-edge with `.ignoresSafeArea()`, so no
rim exists. Joe TV is the only one of the three targets whose root
background stops at the safe area.

**In-app counter-proof:** the one Joe TV screen that *does* ignore
the safe area — the player, `JoePlayerView.swift:295`
(`Color.black.ignoresSafeArea()`) — is the one screen with no rim.

## 3. Nothing in the app can paint blue→magenta (elimination)

- **Colour inventory** (`JoeTheme.swift`, read in full): the three
  shipped themes (code defines exactly three `JoeThemeID`s —
  billboard / posterWall / sourceBoard) have flat `bg` values:
  `#0A0A0A` (Billboard), black (Poster Wall), black (Source Board).
  Accents are crimson `#B3122E/#D9232E`, yellow `#FFD60A`, greens
  `#0D5C4D/#0E7A64`, focus cyan `#00E5FF` (Source Board only). No
  blue→magenta or blue→pink gradient exists in any token.
- **Every gradient in the target** (grep `Gradient`): the card-face
  `surfaceGradient` (`JoeTheme.swift:64–67` — greys / white-opacity,
  card-sized), hero scrims (`JoePhimHome.swift:274, 281` — black
  fades inside the 668 pt hero), detail backdrop fade
  (`JoeMovieDetail.swift:775` — `theme.bg` fades inside the 430 pt
  band, `JoeMovieDetail.swift:759–786`). All are interior, all are
  black/grey. None touches a screen edge; none is blue or magenta.
- **Strokes/borders** (grep): all are focus rings / card outlines,
  ≤6 pt, white/yellow/cyan/clear. None can form a 60–80 pt rim.
- **Assets**: `JoeTV/Assets.xcassets` contains only the app icon
  (layered brand assets) and the `LogoWordmark` imageset. No
  background image, no colour set.
- **Plist / project**: `project.yml` generates `InfoJoeTV.plist`
  from bundle keys only; `UILaunchScreen: {}` (empty — system
  default) for every target; no background colour, no launch image,
  no appearance override. (For the record: a blue→purple gradient
  *does* exist in this repo — `TVApp/TVHomeView.swift:124–126` —
  but that is the separate TV-app target; `project.yml` source
  lists show it is not compiled into Joe TV, and it carries
  `.ignoresSafeArea()` besides.)
- **Detail-screen "clean capture" reconciled**: the detail backdrop
  band is itself an in-safe-area construct (430 pt tall,
  `.frame(maxWidth: .infinity)`, `JoeMovieDetail.swift:783`), so the
  detail screen underfills the rim exactly like home/Settings. The
  one clean detail image in evidence (`~/workspace/user/files/
  68252369-…jpg`) is a capture of the app's own surface, where an
  unpainted rim renders black — it proves the app paints no band
  *inside its surface*, and cannot show what the panel composites
  around that surface. *(Inference, labelled: the capture's
  provenance is "direct capture" per the forensics file; the
  camera photos are the ground truth for the panel.)*

## 4. Photo comparison (mandate item 3)

- The owner's two new Home-screen photos
  (`FB36743D-…jpg`, `98B47FB9-…jpg`, 22:12 CST) show the tvOS
  wallpaper itself: a soft gradient wash — saturated blue across
  the top and left, washing through violet to pink/purple toward
  the bottom and right — visible across the *whole* Home screen
  behind the icons, not just at the edges.
- The app photos (e.g. `D9C3DC6F-…jpg`, Settings, 21:22 CST) show
  the rim as bright saturated blue on top/right/bottom with
  magenta appearing toward the lower-left in the wider shots —
  the same palette, in the same arrangement, at exactly the
  safe-area margins, around a dark, inset app surface. The rim's
  colour *varies around the perimeter* the way the wallpaper does;
  no app-drawn frame would need to.
- Conclusion: the band is the wallpaper showing through the
  unpainted rim. The app-side failure (missing edge-to-edge paint)
  is the defect; the wallpaper merely supplies the colour.

## 5. Platform grounding

- **tvOS safe area** — Apple Human Interface Guidelines, *Layout*:
  "Adhere to the screen's safe area. Inset primary content 60
  points from the top and bottom of the screen, and 80 points
  from the sides… overscan…" — content inset is mandatory; it is
  an inset for *content*, not for backgrounds.
  (https://appguidelines.com/human-interface-guidelines/version/28/layout/,
  mirroring https://developer.apple.com/design/human-interface-guidelines/layout)
- **Backgrounds go edge-to-edge** — same HIG page: "Extend content
  to fill the screen or window. Make sure backgrounds and
  full-screen artwork extend to the edges of the display." Joe TV
  follows the first rule and breaks the second; both sibling apps
  follow both.
- **SwiftUI mechanics** — by default a SwiftUI view, including a
  root background layer, is laid out within the safe area;
  `.ignoresSafeArea()` on the background layer only is the
  standard, documented way to extend paint to the edges while
  content keeps the inset (the construction both sibling apps use).
- **Wallpaper compositing** — that tvOS composites the system
  wallpaper behind regions an app's window leaves unpainted is
  stated here as **inference**: no Apple document retrieved in
  this pass says it in those words. It is, however, the only
  mechanism consistent with all primary evidence: the rim's
  colours match the wallpaper photo-for-photo, its width matches
  the safe-area margins, it appears on every screen sharing the
  one underfilled root layer, it is absent from the one screen
  that ignores the safe area (the player), and it is absent from
  both sibling apps whose roots ignore the safe area.

## 6. Affected scope

- **Screens**: everything under `JoeRootView` — TV, Phim (home,
  search, browse), Torrent home, Settings, and both detail layers
  (movie `:199`, torrent `:217`).
- **Themes**: all three shipped themes (Billboard, Poster Wall,
  Source Board) — they share the single root layer, so the rim is
  theme-independent. (The mandate said six themes; the code ships
  three `ThemeTokens`. All are affected identically.)
- **Not affected**: playback (`JoePlayerView` already ignores the
  safe area at `:295` and throughout) and any full-screen cover.

## 7. Minimal fix (PROPOSED DIFF ONLY — not applied)

Extend the three background layers to the edges; touch nothing
else. The content `VStack` keeps respecting the safe area exactly
as today (§4/HIG geometry is unchanged — only the paint reaches
the rim).

```diff
--- a/JoeTV/JoeTVApp.swift
+++ b/JoeTV/JoeTVApp.swift
@@ JoeRootView.body
         ZStack {
-            theme.bg
+            theme.bg.ignoresSafeArea()
             VStack(spacing: 32) {
                 topBar
                 content
                     .frame(maxWidth: .infinity, maxHeight: .infinity)
             }
             .disabled(nav.movie != nil || nav.tor != nil)
             if let route = nav.movie {
                 ZStack {
-                    theme.bg
+                    theme.bg.ignoresSafeArea()
                     JoeMovieDetail(route: route)
                 }
                 …
             if let route = nav.tor {
                 ZStack {
-                    theme.bg
+                    theme.bg.ignoresSafeArea()
                     JoeTorrentDetail(route: route)
                 }
                 …
```

Do **not** put `.ignoresSafeArea()` on the whole `ZStack` or on
`JoeRootView` itself — that would push the content into the
overscan zone the safe area exists to protect. Background layer
only: the exact construction at `TVContentView.swift:156` and
`TVHomeView.swift:128`.

**Post-fix check** (device, camera — a surface capture cannot
judge this defect): home + Settings + one detail on each theme —
rim gone, content inset unchanged (80/60), player unchanged.

## 8. Honesty declaration

- **Claims**: the convicted mechanism (§Verdict) rests on code
  read directly this pass plus the A/B diff against both sibling
  targets in the same repo.
- **Evidence**: file:line citations throughout; grep inventories
  (`Gradient`, `ignoresSafeArea`, `safeAreaInset`,
  `containerBackground`, `.border`, `stroke`, colour literals,
  `UIWindow`) run over all 29 Swift files in `JoeTV/`; the
  owner's camera photos listed in §4.
- **Unverified / labelled**: the wallpaper-compositing step is
  inference (§5), as is the explanation of the clean detail
  capture (§3). No device run was made by this team; the post-fix
  camera check in §7 is the confirming test. Nothing was pushed;
  `project.yml` untouched; no version numbers changed; the fix
  above is a proposal in this report only.
- **Files read in full**: `JoeTV/JoeTheme.swift`,
  `JoeTV/JoeTVApp.swift`, `DaBanhTV/DaBanhTVApp.swift`.
  **Read in part / grepped**: `JoeTV/JoeSettings.swift`,
  `JoeTV/JoePhimHome.swift`, `JoeTV/JoeMovieDetail.swift`,
  `JoeTV/JoeTorrent.swift`, `JoeTV/JoePlayerView.swift`,
  `JoeTV/JoeKSPlayerView.swift`, `DaBanhTV/TVContentView.swift`,
  `TVApp/TVApp.swift`, `TVApp/TVHomeView.swift`, `project.yml`
  (JoeTV target + plist properties), `JoeTV/Assets.xcassets`
  (inventory), plus target-wide greps over the remaining JoeTV
  sources.
