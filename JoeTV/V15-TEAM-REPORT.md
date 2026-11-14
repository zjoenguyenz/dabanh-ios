# Joe TV tvOS v1.5 — Team Leader Report (Leader-Hợp)

Date: 2026-11-14. Team: Focus-Systems Engineer (JoeTVApp, JoeTVSection, JoeSearch, JoeSettings) · TV360-Standard Visual Designer (JoeTheme, JoePhimHome, JoeTorrent, JoeMovieDetail) · Preservation Checker (read-only, all 21 files + project.yml). Integration, traversal matrix and this declaration: Leader-Hợp. No builds, no pushes, no browser — the parent runs exactly one build.

## Why v1.5 is built differently

Three owner rejections (v1.1/v1.3/v1.4) shared one root: focus behaviour was left to the tvOS focus engine's geometry and to system focus styling. v1.5 removes both dependencies:

1. **Explicit routing.** A focus hub in `JoeNavigator` (`JoeFocusTarget { pills, sectionTop }`, `focusTarget`, `focusNonce`, `requestFocus(_:)`) plus conditional move traps (`JoeMoveTrap`, same shape as the proven `JoeExitTrap`) and per-element `.onMoveCommand` arithmetic handlers. Every boundary in the matrix below names its mechanism. Traps are enabled only while focus sits on a boundary element, and while enabled all four directions have defined outcomes.
2. **No system focus styling.** Every button is `.buttonStyle(.plain)` — the system draws no focus effect at all. `.buttonStyle(.card)` count in code: **0** (independently grep-verified by leader and checker). Focus is self-drawn, violet only.

## Per-screen changes

- **Shell (JoeTVApp.swift):** hub added to JoeNavigator (movie/tor/searchOpen/closeTop verbatim); shell `.pills` consumer on `focusNonce`; top-bar `JoeMoveTrap` (enabled while a pill is focused) implements pill L/R arithmetically, UP as defined no-op, DOWN as `requestFocus(.sectionTop)`. Pills: `.plain`, no white stroke; selected = violet fill; focused = violet fill + lighter-violet outline + scale 1.06. Footer now "Joe TV v1.5". Detail layers, `.disabled`, JoeExitTrap untouched.
- **TV section (JoeTVSection.swift):** per-group horizontal rails DELETED. One `LazyVGrid` (6 × fixed 264pt) for the selected group inside the single vertical ScrollView; slim group header (name + count) above it. Tile = dark logo art button with the channel NAME as sibling text below (white; violet + semibold when focused); focused art = scale 1.06 + 3.5pt violet outline + shadow, background stays dark. Every tile carries an arithmetic `.onMoveCommand` (`moveInGrid`); every chip carries one too (`moveChip`). Entry via hub lands on the chips. Hero stabilised with `.animation(nil, value: heroChannel?.id)`; hero content otherwise identical. Preserved: store start/refresh lifecycle, `sources(for:)` fallback pool, `play()`, fallback counts, invalid-link + .flv filtering, "↻ Làm mới" / "✓ Kiểm tra link", fullScreenCover player, footer.
- **Phim home (JoePhimHome.swift):** header "Tìm phim" button owns a `@FocusState`, `.plain`, violet fill when focused; `.sectionTop` consumer lands there. A rail model enumerates all rails in display order; a conditional trap on the first rail forces UP → header, L/R arithmetic, DOWN → same-index (clamped) item in the next rail. All cards `.plain` (PosterCard self-draws violet focus via JoeTheme). Stores, routes, context menus untouched.
- **Search (JoeSearch.swift):** top row (field / Tìm / Quay lại) bound to one `@FocusState`; conditional trap forces L/R in visual order (skips Tìm while disabled), UP → pills, DOWN → first result. Results grid changed from `.adaptive` to a fixed 6-column grid so routing is exact arithmetic; per-result `.onMoveCommand` (first-row UP → field). `.sectionTop` consumer lands on the field. Search logic and Quay lại action untouched.
- **Torrent home (JoeTorrent.swift):** search row bound to `@FocusState` (field/Tìm/Xoá), `.plain`, violet focus; `.sectionTop` consumer lands on the field. Trap on the search row: UP → pills, L/R explicit, DOWN → first rail card. Trap on the first rail **in display order** (Continue-Watching entries → ♥ Yêu thích entries → first catalog rail): UP → search field, L/R arithmetic, DOWN → next rail same-index clamped. All cards `.plain`.
- **Torrent detail:** `.plain` everywhere; stream rows keep dark surface + violet outline on focus; episode chips scale on focus, selected fill kept; favourite button ring violet via theme. Stream loading, RD resolution, subtitle badge, playback untouched.
- **Movie detail (JoeMovieDetail.swift):** styling only — `.plain` on play/favourite/provider/episode controls; provider chips gained a focus state so a focused chip reads solid violet; selected episode chip keeps its violet 0.30 fill, focus adds scale + violet outline. All logic (load, keep-detail-on-switch, Xem ngay/Xem tiếp, resume marker, director ladder, defaultFocus) untouched.
- **Settings (JoeSettings.swift):** `.sectionTop` consumer lands on the first field ("addon"); conditional trap on field 1: UP → pills, DOWN → field 2, L/R defined no-ops. Field focus stroke changed white → lighter violet. Auto-save (4 × `.onChange { save() }` + silent save on disappear) verified byte-for-behaviour intact.
- **Theme (JoeTheme.swift):** new `focusViolet` (0.72, 0.58, 1.0); `JoeFocusRing` strokes violet; `PosterCard` focused = violet 3.5pt outline + scale 1.05 + violet title, dark fill kept. Background unchanged (near-black #04060D→#0B1120).
- **project.yml (leader):** JoeTV target only — MARKETING_VERSION 1.5, CURRENT_PROJECT_VERSION 6, CFBundleShortVersionString 1.5, CFBundleVersion 6. DaBanhTV 1.2.7 and TV 2.0 confirmed unchanged.

## Traversal matrix

Mechanism key: **HUB** = requestFocus + onChange(focusNonce) consumer · **TRAP** = conditional JoeMoveTrap · **ARITH** = per-element .onMoveCommand arithmetic · **GEO** = tvOS geometry (flagged) · **ACT** = button action / existing system behaviour.

| Screen | Boundary | Mechanism |
|---|---|---|
| Shell | Pills LEFT/RIGHT | TRAP (topBar, enabled while a pill is focused): CaseIterable arithmetic, no-op at ends |
| Shell | Pill UP | TRAP: defined no-op (top screen edge) |
| Shell | Pill DOWN → section top | TRAP → HUB `.sectionTop`; every section consumes (below) |
| Shell | Any section → pills | HUB `.pills`; shell consumer sets focus to current section's pill |
| TV | Entry (pill DOWN) | HUB consumer → focusedChip = effective group (lands on chips) |
| TV | Chips LEFT/RIGHT | ARITH over [visibleGroups…, refresh, validate]; action chips omitted while disabled during load/validate (focus cannot target a disabled button) |
| TV | Chips UP → pills | ARITH `.up` → HUB `.pills` |
| TV | Chips DOWN → grid | ARITH `.down` → focusedChannel = first channel of the group |
| TV | Grid LEFT/RIGHT | ARITH ±1, stopped at row edges (idx % 6) and array bounds |
| TV | Grid UP | ARITH −6; first row → focusedChip = effective group (chips) |
| TV | Grid DOWN | ARITH +6 if in bounds, else defined no-op |
| TV | Grid → player | ACT: select opens fullScreenCover TVPlayerView with fallback pool (unchanged) |
| Phim home | Entry | HUB consumer → header "Tìm phim" button |
| Phim home | Header UP → pills | TRAP (enabled while header focused) → HUB `.pills` |
| Phim home | Header DOWN → first rail | TRAP → first card of first rail |
| Phim home | Header LEFT/RIGHT | TRAP: defined no-ops (sole element of its row) |
| Phim home | First rail UP → header | TRAP (first rail = CW entries if non-empty, else first movie rail) |
| Phim home | First rail LEFT/RIGHT, DOWN | TRAP: arithmetic neighbours; DOWN = same index clamped in next rail |
| Phim home | Deeper rails (all directions) | **GEO — flagged** |
| Phim home | Card → detail | ACT: nav.movie root layer (unchanged) |
| Search | Entry | HUB consumer → query field |
| Search | Top row LEFT/RIGHT | TRAP: field ↔ Tìm ↔ Quay lại in visual order, skips Tìm while disabled |
| Search | Top row UP → pills | TRAP → HUB `.pills` (then pill L/R reaches Cài đặt — the v1.4 failure path) |
| Search | Top row DOWN → results | TRAP → first result id; no results = defined no-op |
| Search | Results LEFT/RIGHT/UP/DOWN | ARITH on fixed 6-column grid; first-row UP → field |
| Search | Exit | ACT: Quay lại closes search; Menu closes via root exit trap (both unchanged) |
| Torrent home | Entry | HUB consumer → search field |
| Torrent home | Search row UP → pills | TRAP → HUB `.pills` |
| Torrent home | Search row LEFT/RIGHT, DOWN | TRAP: explicit steps in visual order; DOWN → first card of first rail |
| Torrent home | First rail UP → search row | TRAP → search field (first rail = first in display order: CW → ♥ → catalog) |
| Torrent home | First rail LEFT/RIGHT, DOWN | TRAP: arithmetic; DOWN = next rail same index clamped |
| Torrent home | Deeper rails | **GEO — flagged** (in search mode the results grid is the single rail and is trap-covered) |
| Torrent home | Card → detail | ACT: nav.tor root layer (unchanged) |
| Settings | Entry | HUB consumer → first field "addon" |
| Settings | Field 1 UP → pills | TRAP → HUB `.pills` |
| Settings | Field 1 DOWN → field 2 | TRAP → focusedField = "rd" |
| Settings | Field 1 LEFT/RIGHT | TRAP: defined no-ops (full-width rows) |
| Settings | Fields 2–4 UP/DOWN | **GEO — flagged** (single vertical stack of full-width rows; UP from field 2 lands on field 1, where the TRAP takes over) |
| Detail layers | Internal movement | **GEO — flagged** between .plain buttons/chips/rows; movie play button keeps defaultFocus |
| Detail layers | Exit | ACT/HUB-existing: Menu → root JoeExitTrap closes exactly one layer (unchanged, checker-verified) |
| Player | All | ACT: TVPlayerView / JoePlayerView system behaviour (untouched) |

No boundary is without a named mechanism. GEO rows are declared, not hidden.

## Focus-style spec

- Buttons: `.buttonStyle(.plain)` app-wide — the system draws no focus effect; `.card` = 0 in code.
- Focus colour: fills `accentViolet` #9E73FF; outlines `focusViolet` rgb(0.72, 0.58, 1.0), 2.5–3.5pt; scale 1.04–1.06 on focus.
- Pills: selected keeps violet fill; focus adds lighter-violet outline + scale. TV group chips: selected keeps red fill; focused unselected = violet fill; focused selected = red fill + violet outline + scale. Text on focused elements is always white on a violet/red/dark fill — never on a pale surface.
- PosterCard / torrent cards: dark surface, violet outline + scale when focused; title turns violet. TV tile: name below the art as sibling text (never inside the focusable surface), violet + semibold when its tile is focused.
- Disclosure: one focus-adjacent white remains — the torrent stream-row background brightens from white 0.06 to white 0.13 opacity on focus (checker item D-4). The row stays dark, its focus outline is violet; the fill is a dark-surface highlight, not a pale card. Static idle borders (white 0.10–0.15 opacity) on posters/tiles are unconditional decoration, not focus signals.

## Honesty declaration

**Claims.** (1) The hub contract is implemented exactly as specified and consumed symmetrically: shell `.pills` consumer + five `.sectionTop` consumers (TV, Search, Settings, Phim, Torrent). (2) The TV section's nested-rail layout is gone, replaced by a single 6-column grid with fully arithmetic focus. (3) `.buttonStyle(.card)` occurs 0 times in code; no white focus-dependent stroke exists in any file. (4) Every preserved feature on the mission list is present and wired. (5) All 21 Swift files are brace/paren/bracket balanced. (6) Version is 1.5 (6) in project.yml (JoeTV target, both settings and info properties) and the in-app footer reads "Joe TV v1.5".

**Evidence.** Leader's own greps and balance script over all 21 files (0 imbalances; hub symbols at JoeTVApp.swift:62–68, shell consumer :153, pill DOWN :251; consumers present in all five section files). Preservation Checker's independent PASS on all 14 checklist items with file:line evidence, including: JoeExitTrap/closeTop/detail layers intact (JoeTVApp.swift:134–163, 278–289); settings auto-save = 4 `.onChange` saves + onDisappear silent save (JoeSettings.swift:81–85); Tủ Phim rails "📚 Tủ Phim · Phim lẻ mới" / "📚 Tủ Phim · Phim bộ mới" fed by tpMovies/tpSeries (JoePhimHome.swift:80–84); torrent "♥ Yêu thích" rail (JoeTorrent.swift:182) and Vietnamese-subtitle badge logic (:378, :442–449, :638); TV fallback pool + link-check actions (JoeTVSection.swift:183–188, 445–460); untouched files separated by mtime (untouched batch 2026-11-14 20:43 UTC vs rework window 21:50–21:54 UTC). Both specialists' per-file reports with their own balance counts agree with the leader's recount.

**Unverified — only the owner's device / the parent's single build can prove these.**
1. **Compilation.** No build was run (budget rule) and this VM has no Swift toolchain. Balance counts and full re-reads are the only syntax assurance. The parent's build is the first compile gate.
2. **On-device focus behaviour of every trap/handler.** The routing is deterministic in code, but tvOS delivery of move commands to `.onMoveCommand` handlers — especially the scroll-reveal of programmatic focus jumps inside ScrollViews — is not provable from source.
3. **TextField move-command interception (weakest boundaries).** While a tvOS TextField holds focus, the text-input system may consume move commands before the traps see them. This caveat covers UP-escape from the Torrent search field (designer flag) and, by the same mechanism, the Phim search field. While the tvOS keyboard overlay is open after a select-press, move commands belong to the keyboard on all text-input screens (system behaviour).
4. **Hero ghost fix.** `.animation(nil, value: heroChannel?.id)` is in place; whether the compositing ghost is fully gone is a device observation.
5. **GEO boundaries** (declared in the matrix): Phim/Torrent deeper rails, Settings fields 2–4, detail-layer internal movement.
6. **JoeStores.swift mtime anomaly** (checker D-2): its mtime (20:50 UTC) is ~7 min newer than the rest of the untouched batch (20:43 UTC) but ~1 hour older than the rework window; its content checks all pass. Unexplained, not attributable to this team, disclosed for completeness.
7. The literal string "Joe TV v1.4" survives in two non-UI places: a doc comment in the untouched WatchStore.swift (referring to the Android app's versions) and the historical V14-TEAM-REPORT.md. No Swift UI code displays it (checker D-1).

**Residual risks.** Compile errors in the new trap/handler code (mitigated only by review); LazyVGrid/LazyHStack focus on not-yet-rendered cells during programmatic jumps; the two text-field boundaries above; the Torrent first-rail definition follows display order (CW before ♥), so when Continue-Watching is non-empty the ♥ rail's UP is served by the first-rail trap's DOWN symmetry plus geometry rather than its own trap — declared here rather than silently divergent from the brief's parenthetical.

## Files changed (9)

`JoeTV/JoeTVApp.swift` · `JoeTV/JoeTVSection.swift` · `JoeTV/JoeSearch.swift` · `JoeTV/JoeSettings.swift` · `JoeTV/JoeTheme.swift` · `JoeTV/JoePhimHome.swift` · `JoeTV/JoeTorrent.swift` · `JoeTV/JoeMovieDetail.swift` · `project.yml` (JoeTV target only). Plus this report. Verified unchanged: all other JoeTV sources, including JoeStores, JoeProxy, Providers, JoePlayerView, WatchStore, TorrentClient and all provider clients.
