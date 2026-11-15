# Joe TV tvOS — DESIGN SPEC v1.9 (Team 3, 2026-11-15)

The contract for the v1.9 UI rebuild. Team 1 builds against this file;
Team 4 validates against §8 item by item. Every value is exact; where a
value is a decision rather than a measurement, the reason is stated.
Evidence base: REWORK-LOOP.md (device photo of v1.8 + Auditors A/B/C),
the current source (JoeTVApp / JoeTheme / JoePhimHome / JoeMovieDetail /
JoeTVSection, read 2026-11-15), DESIGN-NOTES.md (TV360 reference), and
Apple's tvOS Human Interface Guidelines as cited in §2.

---

## 1. Identity in one paragraph

Joe TV on Apple TV is a **poster library on pure black, lit by violet**.
Black foundation (no gradient, no hue), violet accent and violet focus,
red reserved for LIVE and watch-progress, the real JOE TV wordmark image
in the top bar, four top pills. It must be unmistakable against Đá Banh
TV (teal gradient, cyan/teal accent, crest hero) at a 2-second glance —
see the differentiator table in §3.4.

## 2. Platform grounding (Apple sources)

- **Safe area** — Apple HIG, *Layout* (tvOS): "Inset primary content
  60 points from the top and bottom of the screen, and 80 points from
  the sides." This spec's margins are exactly those numbers.
- **Focus** — Apple HIG, *Designing for tvOS* and *Focus and selection*:
  every screen has a default focused element; focus movement is
  predictable and spatial; focus is never trapped; returning to a
  screen restores the previous focus (focus memory). §5 encodes these
  as rules F5–F7.
- **Type floors** — tvOS text styles bottom out at 23 pt and the body
  style is 29 pt; secondary summaries of the HIG converge on: body
  ≥ 29 pt, secondary ≥ 25 pt, nothing readable below 23 pt. This spec
  adopts those floors (§6). LABEL: adopted from HIG-derived secondary
  sources; the live Apple page could not be re-fetched during this
  pass (see honesty note in the delivery report).
- **Canvas** — tvOS layout is authored in points on a 1920×1080
  logical canvas; Apple TV 4K renders it at @2x. All values below are
  points.

## 3. Colour system

### 3.1 Tokens (the ONLY colours Team 1 may use)

| Token | Value | Use |
|---|---|---|
| `bg` | `#000000` — `Color.black`, SOLID | Every full-screen background (root, detail layers). No gradient, no opacity variant. |
| `surface` | white @ 0.07 over `bg` | Card / tile / field fill (unfocused, unselected) |
| `surfaceStroke` | white @ 0.10, 2 pt | Unfocused card/tile outline |
| `accentViolet` | `(0.62, 0.45, 1.00)` `#9E73FF` | Selected pill/chip fill, focused fill for pills/chips/buttons, primary buttons |
| `focusViolet` | `(0.72, 0.58, 1.00)` `#B894FF` | THE focus outline colour, focused card title |
| `accentRed` | `(1.00, 0.27, 0.23)` `#FF453B` | LIVE dot, Continue-Watching progress bar, wordmark-dot fallback. Nothing else. |
| `textPrimary` | white @ 1.00 | Titles, body, labels |
| `textSecondary` | white @ 0.70 | Meta lines, values, hints |
| `textFaint` | white @ 0.40 | Version string ONLY |
| `warning` | `Color.orange` | Status / partial-failure lines |
| `okGreen` | `(0.19, 0.82, 0.35)` `#30D158` | Diagnostics pass dot ONLY |

### 3.2 Background rule (Auditor A's fix, made absolute)

`JoeTheme.background` becomes `Color.black.ignoresSafeArea()` — one
solid colour, defined once, used by the root and both detail layers.
No full-screen gradient may exist anywhere in the target. A hue-free
background cannot be amplified into a colour by any display chain;
the worst case is grey, never blue. (The retired blue-biased hex
family `#0B0B0D / #1B1B20` must not reappear — B > R in every stop was
the defect.)

### 3.3 Text-on-colour rules

- White text on `accentViolet` fills (pills/chips/buttons) — never
  dark text on violet, never violet text on white.
- No text may sit on a fill lighter than `accentViolet`. There is no
  light surface anywhere in the app.
- `accentRed` is a signal, not a decoration: if it appears, it means
  LIVE or progress. Provider badges stay monochrome (black @ 0.65
  capsule, white text).

### 3.4 Distinctness vs Đá Banh TV (owner law — measured from its source)

| Axis | Joe TV (this spec) | Đá Banh TV (current source) |
|---|---|---|
| Background | Solid `#000000` | Teal gradient `(0.02,0.22,0.19) → (0.00,0.05,0.06)` |
| Accent | Violet `#9E73FF` | Cyan `(0.00,0.90,1.00)` + teal fill `(0.05,0.36,0.30)` |
| Focus | Violet outline `#B894FF` | Teal fill |
| Hero element | Poster rails + image wordmark | Team-crest match hero |
| Content shape | 2:3 poster cards | Landscape match cards |

Any one axis differing could be an accident; all five differing is
the requirement. Team 4 checks the table, not an impression.

## 4. Layout grid

- **Margins**: content box = 80 pt left/right, 60 pt top/bottom from
  the physical screen edge (HIG §2). Implementation: the background
  ignores the safe area; the content container respects the safe area
  and adds NO further horizontal padding. (Replaces the current
  manual 56/34/24 padding — total inset must equal 80/60, not stack.)
- **Spacing tokens**: 8 / 16 / 24 / 32 / 40 / 48. Only these values
  for stack spacing and padding, except component internals listed
  in §7.
- **Vertical rhythm**: top bar → 32 → content. Rail-to-rail gap 40.
  Rail title → cards 16. Settings section gap 40.

## 5. Focus architecture — ONE standard

The v1.7/v1.8 lesson is written into rules, not comments: the system
must never draw focus for this app, and every focus visual is drawn
by the app in exactly one way per component class.

- **F1 — Suppression is per-view, never inherited-only.**
  Every focusable view carries `.focusEffectDisabled(true)` on
  ITSELF. Buttons additionally carry `.buttonStyle(.plain)`. The
  root-level application stays as a backstop but is never the only
  one. (Auditor A: coverage was complete in v1.8 and the blob still
  appeared; inheritance is therefore not a mechanism we rely on.)
- **F2 — Top-bar pills are NOT Buttons.** The pill row is rebuilt as
  `.focusable()` views with a select gesture, bound to the same
  `@FocusState` and the same pill move trap. Rationale: the system
  blob appeared on a pill in two consecutive shipped builds; pills
  are simple chrome; the hub contract (focus ≠ selection; select
  press switches section) is view-agnostic and is preserved
  verbatim. A focusable view has no button focus treatment to
  suppress, so the defect class is eliminated, not mitigated.
  All OTHER controls remain Buttons under F1 — with the standing
  conversion rule F9.
- **F3 — The app-drawn treatment, per class** (focused state only;
  unfocused = §3 tokens, no outline beyond `surfaceStroke`):

  | Class | Fill change | Outline | Scale | Other |
  |---|---|---|---|---|
  | Pill (selected or not) | → `accentViolet` | 4 pt `focusViolet`, capsule | 1.06 | Label → white, semibold |
  | Poster card | none | 4 pt `focusViolet`, r16 rect on the card's own shape | 1.05 | Title → `focusViolet`, semibold |
  | Chip / text button | → `accentViolet` | 4 pt `focusViolet` on its shape (`JoeFocusRing`) | 1.05 | — |
  | Primary button (Play, Retry, Kiểm tra) | already `accentViolet` | 4 pt `focusViolet` capsule | 1.05 | — |
  | Text / secure field | none | 4 pt `focusViolet`, r14 rect | 1.00 | — |
  | TV channel tile | none | 4 pt `focusViolet`, r16 rect | 1.05 | Name → `focusViolet` |
  | Episode / server chip | → `accentViolet` | 4 pt `focusViolet`, r12 rect | 1.05 | — |

  No class may add a shadow, glow, halo, blur, or brightness wash on
  focus. The existing black drop shadow on PosterCard is REMOVED —
  scale + outline is the whole treatment, identical in spirit across
  classes so the eye learns one language.
- **F4 — Focus identity is unique per rail instance** (fixes C-3).
  Every focus binding key is `"<railKey>|<itemID>"`. Rail keys:
  `cw`, `fav`, `merged`, `chieuRap`, `vnAll`, `vnSeries`, `vnSingle`,
  `genre:<slug>`, `country:<slug>`, `kkNew`, `kkSeries`, `kkMovies`,
  `kkAnime`, `f4kNew`, `f4kMovies`, `vsNew`, `vsSeries`, `tpMovies`,
  `tpSeries`, `search`, `torCat:<id>`, `torGenre:<name>`,
  `torSearch`. Episode chips: `"<serverIndex>|<episodeName>"`.
  Consequence: the same movie in three rails is three focus targets;
  exactly one card on screen may show the F3 treatment at any time.
- **F5 — Movement rules** (the JoeNavigator hub contract is kept and
  restated as spec):
  1. Traps exist only on boundary elements; while a trap is enabled
     every direction has a defined outcome (forced target,
     arithmetic neighbour, or explicit no-op at a screen edge).
  2. Pills: LEFT/RIGHT arithmetic over the 4 sections; DOWN →
     hub `.sectionTop`; UP = no-op (top edge). Focus alone never
     changes the section.
  3. Each section's `.sectionTop` landing is fixed: Phim → the
     "Tìm phim" header button; TV → the effective group's chip;
     Torrent → its search button; Settings → the first field.
  4. Section UP-escape (from its top element) → hub `.pills`,
     landing on the CURRENT section's pill.
  5. Multi-row grids (search results, torrent search, TV grid)
     move GEOMETRICALLY inside the grid. A boundary trap may exist
     only for the grid's first row: UP from row 1 → the element
     above the grid; all other directions are the engine's. Routing
     a grid as a flat rail is a spec violation (fixes C-2).
  6. DOWN from a section header when the section has NO content
     lands on the error surface's Retry button when one is shown
     (fixes C-1); when neither content nor error exists yet
     (still loading), DOWN is a defined no-op.
- **F6 — Default focus & memory.** On first entry a section takes
  focus via the hub as in F5.3. Returning from a detail layer
  restores the exact card that opened it (focus memory). When an
  error surface appears it does NOT steal focus unless the section
  has no content, in which case Retry takes focus.
- **F7 — Minimum targets.** Chrome controls (pills, chips, buttons,
  fields) ≥ 56 pt tall. Cards ≥ 250 pt wide. Nothing focusable may
  be smaller.
- **F8 — Motion.** Focus changes animate scale/outline over 0.15 s
  ease-out, and nothing else. No cross-fades on focus change (the
  TV hero's animation-nil stabilisation stays).
- **F9 — Standing conversion rule.** If Team 4's device evidence
  shows a system-drawn artifact on any Button-based control class,
  that class converts to the F2 focusable-view pattern before the
  next build. No third attempt with modifiers alone.
  **DEVIATION RECORDED 2026-11-15 (1.9.2; leader ruling, Team 4
  re-gate accepted):** F9's literal F2 conversion was NOT followed.
  On device evidence the artifact class (`.plain` Buttons) was
  instead converted to real Buttons with `.buttonStyle(.card)` —
  the construction the shipped 1.9.1's pills and Đá Banh TV prove
  clean on the owner's box — keeping per-view
  `.focusEffectDisabled(true)` and the app-drawn F3 treatments. No
  Button became a focusable view. F9's operative intent (change the
  construction, never permute modifiers on a proven-bad one) is
  honoured; the full record is in APPLE-CONFORMANCE.md, P-B B-2
  amendment 2026-11-15 #2.

## 6. Type scale

System font (SF), weights ≥ medium everywhere — no light/thin.

| Role | Size / weight | Colour |
|---|---|---|
| Detail title | 64 heavy, ≤ 2 lines | `textPrimary` |
| Screen title (Phim header, TV hero channel) | 56 heavy | `textPrimary` |
| Rail / settings-section title | 34 bold | `textPrimary` |
| Button & pill label | 29 semibold | `textPrimary` |
| Body / overview / field text | 29 regular–medium | `textPrimary` |
| Card title | 25 semibold (focused: `focusViolet`) | `textPrimary` |
| Secondary (meta, values, hints, status cause) | 25 medium | `textSecondary` |
| Floor — badge text, card meta, version | 23 (heavy for badges) | badge: white; version: `textFaint` |

Hard floor: **no text below 23 pt anywhere in the target**, no
exceptions (the current 15–21 pt footnote/meta/badge sizes are spec
violations). Overview line spacing 8.

## 7. Components

### 7.1 Top bar (all sections)
Height 76. Left→right: logo image (height 54, master aspect ≈
184 wide; text fallback unchanged) → 20 gap → four pills → spacer →
version text (23 pt, `textFaint`, format `Joe TV v<version>`).
Pill: icon 26 + gap 10 + label 29; padding H28 V14; inter-pill
gap 20. Total row must fit the 1760 pt content width with the
version visible — it does at these values (≈ 1 480 pt worst case).

### 7.2 Poster card & rails (Phim, Torrent catalogues)
Art 240×360 (2:3), corner radius 16, clipped. Cell padding 12 →
cell width 264. Below art: gap 10 → title 25 (1 line) → gap 4 →
meta 23 (`textSecondary`, 1 line). Continue-Watching cards add the
subline ("Còn …") as a second 23 pt line under meta.
Badge: top-left, inset 10, 23 pt heavy white on black @ 0.65
capsule, padding H12 V6.
Progress bar: height 6, `accentRed` on white @ 0.25, at the art's
bottom edge, CW cards only.
Rail: title 34 bold; horizontal `LazyHStack` spacing 28; scroll
area vertical padding 16 (headroom so a 1.05-scaled focused card
is never clipped).

### 7.3 Phim home
Header: screen title 56 + subtitle 25 (`textSecondary`) left;
"Tìm phim" button right (chip treatment F3, label 29, icon 24,
padding H26 V14). Rails in the current order (CW, Favourites,
merged, chiếu rạp, Việt Nam ×3, genres, countries, per-provider).
States per §8.

### 7.4 Movie detail
Backdrop strip (owner-approved in the v1.8 mock — dimensions are
frozen): full content width 1760 × height 540, corner radius 18,
stroke white @ 0.14 at 2 pt; KK landscape thumb instantly, TMDB
w1280 backdrop fading over it (0.3 s opacity — the fade the code
comment already promises). Below, gap 32: poster 240×360 r16 left;
right column: title 64, meta row 29, overview 29 (≤ 5 lines),
Play (primary button: capsule, label 29 bold + `play.fill` 26,
padding H36 V16) and Favourite (same chrome, `surface` fill).
Cast row: 120-wide cells, circular 110 art, name 23 below.
Alt-source chips and server/episode groups: chip label 25,
padding H20 V12, radius 12, gap 16; group label 25 semibold
`textSecondary`. Episode focus keys per F4.

### 7.5 TV section
Hero height 220: logo art 340×204 r22 (surface fill, white @ 0.14
2 pt stroke, logo padded 28); group label 25 semibold, tracking 4,
`textSecondary`; channel title 56 heavy ≤ 2 lines; fallback-count
capsule 25 on white @ 0.10.
Group chips: label 29 medium, padding H24 V12, gap 16, F3 chip
treatment; selected chip = `accentViolet` fill.
Grid: 6 columns, gaps 24/24. Tile 273×150 r16 `surface` fill:
channel logo centred (max 180×90); channel name 25 beneath the
logo inside the tile's lower band, centred, 1 line. Tiles in a
LIVE EVENTS group carry the LIVE badge: top-right, red dot 12 +
"LIVE" 23 heavy white on black @ 0.65 capsule, padding H10 V4.
Status line (store.statusMessage): 25 `warning`, above the grid —
this pattern is the model for the whole app (§8 G4).

### 7.6 Torrent home & detail
Home mirrors Phim chrome: header + search button, catalogue and
genre rails reuse §7.2 cards. Search results: `LazyVGrid`,
6 columns (6×264 + 5×28 = 1724 ≤ 1760), row gap 40, geometric
movement per F5.5.
Detail mirrors §7.4 metrics for its header block; stream rows:
height 64, label 29. Stream rows are the single sanctioned F3
variant: outline-only (4 pt `focusViolet`, r12, scale 1.02, no
fill change) — a full-width `accentViolet` fill would be too loud,
and any pale fill is banned, so the outline carries focus alone.

### 7.7 Search (Phim)
Query field: height 72, text 29, r14, `surface` fill, F3 field
treatment. Provider chips as §7.5 chips. Results grid as §7.6.
States per §8 (searching / no-results / failure are three DIFFERENT
surfaces — fixes C-10's movie-search sibling).

### 7.8 Settings
Single scrolling list, one focus flow top→bottom (every control
reachable by DOWN alone). Section titles 34 bold. Row: label 29,
value 29 `textSecondary`; field height 68, r14, `surface`,
padding H24; row vertical padding 18; divider white @ 0.08.
TMDB row (fixes C-13): when the field is empty and the bundled key
is active, a status line under the field reads
"TMDB: đang dùng key tích hợp sẵn ✓" (25, `okGreen` dot 12 +
`textSecondary` text); the hint "Tuỳ chọn…" is removed — with the
bundled key the feature is ON, and the UI must say so.
Torrentio / Real-Debrid / TorBox / OpenSubtitles rows keep their
fields (owner-entered on device; nothing to pre-fill — Auditor C
verified no build-side source exists for these).

### 7.9 Settings source diagnostics (board contract)
Block title "Kiểm tra nguồn phim" (34 bold) + description 25
`textSecondary`: "Đo từng nguồn phim ngay trên máy này."
Button "Kiểm tra ngay" (primary-button chrome §7.4).
While running: spinner (white tint) + "Đang kiểm tra…" 29, button
disabled; results replace the button area IN PLACE (no navigation,
focus stays on the button).
Result rows (from `SourceProbe.run() -> [SourceProbe.Result]`,
`{name, ok, millis, note}`): height 60, spacing 8 —
status dot 16 (`okGreen` / `accentRed`) → name 29 → spacer →
millis "850 ms" 25 `textSecondary` → note 25 (`warning` when
`ok == false`, else `textSecondary`), 1 line, truncated tail.
One row per provider: KKPhim, VSMOV, Film4K, Tủ Phim. A probe that
itself throws renders as a failed row with the error as its note —
the block never shows its own spinner forever: running state ends
when the slowest single probe ends (Team 2 bounds each probe).

### 7.10 Player chrome (states only; internals are Team 1's U-1 fix)
Loading slate: black, spinner white, title bottom-left 29 white
(TV360 language per DESIGN-NOTES). Stall/error slate per §8.

## 8. State design — every screen, no exceptions

Global rules:
- **G1.** No blocking spinner may persist beyond **20 s** without
  content or an error surface appearing (store contract:
  `loadTimedOut`). Spinner style: white tint, label 29.
- **G2.** Cache-first wherever the store has a cache (TV today;
  Phim once Team 2 lands B-fix 5): cached content IS the loading
  state. A refresh may never remove rendered content.
- **G3.** Error surface (zero-content failure), one shape app-wide:
  `exclamationmark.triangle` 44 pt `warning` → message 29 white →
  cause 25 `textSecondary` (the real captured error — Auditor B:
  errors are stored, never discarded) → Retry primary button.
  Reachability: the section's hub DOWN target when no content
  exists (F5.6) and default focus when it appears (F6).
- **G4.** Partial failure: content renders; ONE status line at the
  very bottom of the scroll, 25 `warning`, non-focusable:
  "Chưa tải được: <tên nguồn>" listing the failed providers. The
  G3 surface is FORBIDDEN when any rail has data (fixes C-8).
- **G5.** Empty-after-success is its own surface: 29 `textSecondary`
  message, no spinner, no Retry (nothing failed).

Per screen:

| Screen | Loading | Partial | Empty | Error |
|---|---|---|---|---|
| Phim home | Cached rails instantly (G2); cold: spinner + label, ≤ 20 s (G1) | Rails that landed + G4 line | All providers returned empty → G5 "Thư viện chưa có dữ liệu." | Zero rails after deadline → G3, Retry = `phim.retry()` |
| TV section | Cached grid instantly; cold: hero-area spinner ≤ 20 s | Cached grid + statusMessage line (existing pattern) | "Chưa có kênh nào." (existing) | statusMessage + Làm mới chip (existing pattern, kept) |
| Torrent home | Spinner + "Đang tải danh mục…" ≤ 20 s (NEW — fixes C-4) | Catalogues that landed publish per-catalogue; genre rails publish per-rail (core C-5) + G4 line | G5 "Chưa có danh mục nào." | G3 with Retry (NEW) |
| Phim search | Spinner in results area ≤ 20 s | n/a | "Không tìm thấy phim nào." (distinct from failure) | G3-shaped block in results area + Retry (fixes C-10 sibling) |
| Movie detail | Backdrop placeholder + spinner ≤ 20 s | Detail without TMDB enrichment renders silently whole (enrichment is additive, never blocking) | n/a | Existing `loadFailed` state, restyled to G3 shape + Retry |
| Detail provider switch | Chips disabled during switch | — | — | Switch failure REVERTS to the previous provider and shows a 25 `warning` line at the detail top: "Không tải được nguồn X — vẫn dùng nguồn Y" (fixes C-9; silent hybrid pages are banned) |
| Torrent detail | Spinner ≤ 20 s | Meta without videos: notice line + Retry in place | "Chưa có nguồn phát." (existing copy, kept) | Videos/streams fetch failure → notice + Retry button in place (fixes C-11); "no streams exist" and "fetch failed" are different copy |
| Torrent search | Button label → "Đang tìm…" + spinner | Results publish per catalogue | "Không tìm thấy kết quả nào." | Failure line + Retry; searching with zero catalogues loaded says so explicitly (fixes C-10) |
| Player | Slate §7.10; first frame expected ≤ 15 s | — | — | No frame at 30 s → error slate: message 29 + cause 25 + buttons "Thử nguồn khác" (only when a fallback source exists) and "Quay lại"; focus lands on the first button (fixes U-1's silent black screen) |
| Settings diagnostics | §7.9 running state | Rows render as each probe returns | n/a | Per-row failure (§7.9); the block itself never errors silently |

## 9. Regression guards (do not break while rebuilding)

- The JoeNavigator hub + JoeMoveTrap architecture stays; §5
  restates it, it does not replace it.
- TMDB bundled-key flow stays (Settings key wins, bundled is the
  fallback); §7.8 only fixes its presentation.
- `.buttonStyle(.card)` stays banned; every Button is `.plain`.
- TVStore's cache-first + statusMessage behaviour is the reference
  implementation for G2/G4 — copy its shape, don't redesign it.
- Version/footer strings remain the leader's build-time concern;
  the top bar keeps the version text (§7.1).

## 10. Acceptance criteria — Team 4 pass/fail checklist

Method key: [CODE] = source audit/grep · [SHOT] = device screenshot
measurement · [TIME] = timed device test · [NAV] = remote walk.

**Colour**
1. [CODE] `JoeTheme.background` is a solid `Color.black`; no
   full-screen gradient exists in the target. [SHOT] Background
   pixels sampled at all four corners of the Phim home = RGB(0,0,0).
2. [SHOT] No background pixel anywhere has B − R > 2 (the v1.8
   defect signature).
3. [CODE] Every colour used in JoeTV views is a §3.1 token or a
   §3-sanctioned opacity of white/black. No new hex values.
4. [SHOT] Side-by-side with Đá Banh TV home: §3.4 table holds on
   all five axes.

**Focus**
5. [CODE] `.focusEffectDisabled(true)` appears on every focusable
   view (count of modifier sites ≥ count of `.focused(` sites);
   pills contain no `Button`.
6. [SHOT] Focused pill: violet fill + violet outline, white label
   fully legible; NO pale/white/cyan halo anywhere on screen.
7. [SHOT] Focused poster card: 4 pt violet outline + title turned
   violet; exactly ONE card on screen shows focus treatment while
   the same movie appears in ≥ 2 rails (F4).
8. [NAV] From cold start: pills → DOWN → section top → DOWN →
   first card → RIGHT ×3 → DOWN → next rail same column. No press
   is swallowed; no press jumps diagonally.
9. [NAV] With networking dead: Phim error surface's Retry is
   reachable from the pills in ≤ 2 DOWN presses and activates a
   new load (C-1 test).
10. [NAV] Torrent search results: DOWN moves down a ROW of the
    grid from any cell (C-2 test).
11. [NAV] Open a movie from rail 3, press Menu: focus returns to
    that exact card (F6 memory).
12. [CODE] No focus-only shadow/glow/blur exists in any view
    (grep `shadow` in focused contexts = 0).

**Type & layout**
13. [CODE] No `.font(.system(size: N))` or text style with N < 23
    in JoeTV views; no weight below `.medium` on text.
14. [SHOT] Content left edge at x = 160 px (@2x) on Phim home,
    TV section, Settings (80 pt margin); top bar top at 120 px.
15. [SHOT] Poster art measures 480×720 px (@2x) = 240×360 pt;
    rail gap 56 px; focused card never clipped by the rail.
16. [SHOT] Detail backdrop strip spans the full content width
    (3520 px @2x) × 1080 px high, radius visible, TMDB image
    present when a key is active.

**States & timing**
17. [TIME] Healthy network, cold start: first Phim rail visible
    ≤ 8 s; with cache: rails visible immediately on relaunch.
18. [TIME] Network dead, cold start: G3 error surface (with a
    real cause line) visible ≤ 20 s after the Phim tab opens —
    never a spinner past 20 s, on Phim AND Torrent home.
19. [TIME] One provider dead (others healthy): its rails absent,
    all other rails render, G4 bottom line names the dead provider;
    NO full-screen error (C-8 test).
20. [NAV] Settings → Kiểm tra ngay: four result rows render in
    place with dot + name + ms + note; focus never leaves the
    button; a dead provider shows a red row with its error as note.
21. [TIME] Play a dead stream: error slate with reachable buttons
    by 30 s; the app never sits on silent black past 30 s (U-1).
22. [NAV] Detail: switch to a provider whose fetch fails → page
    reverts, warning line names both providers (C-9 test).

**Guards**
23. [CODE] `grep -r "buttonStyle(.card)" JoeTV/*.swift` = 0;
    every `Button` is `.buttonStyle(.plain)`.
24. [NAV] Fresh install: open a KK detail — TMDB backdrop + cast
    appear with NO key typed (bundled-key regression), and
    Settings shows the §7.8 integrated-key status line.
25. [CODE] Focus keys in rails/episodes match the F4 format
    (`<railKey>|<itemID>`, `<serverIndex>|<episodeName>`).

A build is deliverable to the owner only when every item passes.
Any [SHOT]/[NAV]/[TIME] failure returns the app to the loop with
the item number as the defect ID.
