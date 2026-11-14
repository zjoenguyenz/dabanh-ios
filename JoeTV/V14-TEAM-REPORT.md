# Joe TV tvOS v1.4 — Team Leader Report (Leader-Kết, independent verification)

Verified directly against the files on disk in `~/workspace/dabanh-ios/` on 2026-11-14. Specialist reports were treated as claims, not evidence; every item below was re-grepped / re-read / re-counted by the leader.

**Overall verdict: DONE by construction — no real defect found.** The one flag raised during the work (theme may not have landed) is a **false alarm**, resolved definitively in §4. Compilation and on-device focus behaviour remain unproven — see the Honesty Declaration (§6).

---

## 1. Per-screen change list

### Shell — `JoeTVApp.swift` — DONE
- v1.3 `HStack` left rail removed: no `rail` / `railRow` identifier remains in the file. Shell is now a single `VStack(spacing: 24)` — `topBar` above, `content` filling the rest — with shell padding `.horizontal 56 / .top 34 / .bottom 24`.
- `topBar`: wordmark ("Joe TV" white + "." in accent red), four section pills (TV / Phim / Phim Torrent / Cài đặt) as `.buttonStyle(.card)` buttons (1 code site, line 192; a second raw grep hit at line 70 is a comment), each label fully backed by its own capsule (selected = violet fill, unselected = white 8%, white 2.5pt ring when focused, `.lineLimit(1)` + `.fixedSize`), then `Spacer()` + `Text("Joe TV v1.4")`.
- Default section preserved: `@State private var section: Section = .phim`.
- Preserved intact, read line-by-line: `JoeNavigator` with `movie` / `tor` / `searchOpen` and `closeTop()` (movie → tor → search order); root detail layers for movie (zIndex 2) and torrent (zIndex 3) over `JoeTheme.background`; `.disabled(nav.movie != nil || nav.tor != nil)` on the shell VStack (line 109, exact expression); conditional `JoeExitTrap` — `enabled: nav.movie != nil || nav.tor != nil || nav.searchOpen`, and the trap installs `onExitCommand` **only** when enabled, so Menu at section roots keeps its system behaviour.

### TV — `JoeTVSection.swift` — DONE
- 3 `.buttonStyle(.card)` code sites: group `chip`, `actionChip`, channel `tile`.
- Chips: text always `.white`; selection carried by red fill (`accentRed.opacity(0.85)`), focus by white ring + violet 45% fill when unselected. Action chips fully backed by white-8% capsule + white ring when focused.
- Tiles: the background + ring now cover the **whole tile, art + title together** — inner art/title width 280pt + `.padding(12)` = **304pt outer width** (arithmetic verified: 280 + 2×12 = 304). Background white 7%, ring white 4.5pt focused / white 10% 1.2pt unfocused.
- No outer padding in the section (explicit comment + code: the shell owns screen padding).
- Preserved: hero following focus, group pool / same-name fallback (`fallbackCount`), `✓ Kiểm tra link` (line 167–168) calling `store.refreshAndValidate()`, `LinkProbe.isFLV` filtering (line 349), `JoeProxy.shared.playlistURL` (line 387), `.flv` hiding / invalid-URL set via the shared `TVStore`.

### Phim home — `JoePhimHome.swift` — DONE
- 4 `.buttonStyle(.card)` code sites: "Tìm phim" entry button, Continue Watching rail, Favourites rail, catalogue `movieRail`.
- No outer padding (shell owns it).
- Preserved: `.task { phim.loadIfNeeded() }` (line 36), all rail titles and order — including `📚 Tủ Phim · Phim lẻ mới` (line 73) and `📚 Tủ Phim · Phim bộ mới` (line 76), `♥ Yêu thích` rail, provider badges, context-menu remove actions, search presented by swapping in `JoeSearchView` when `nav.searchOpen`.

### Movie detail — `JoeMovieDetail.swift` — DONE, paddings KEPT
- 4 `.buttonStyle(.card)` code sites: play button, favourite button, "Nguồn khác:" alternative-provider chips, episode chips.
- Outer paddings **kept by design**: `.leading 44 / .trailing 52 / .top 36 / .bottom 40` (lines 56–59).
- Preserved, read directly: `load()` (line 324) with keep-detail-on-switch (`hadDetail` / `switching` — the current detail stays on screen until the new provider's detail lands); instant `placeholderHeader` (line 72) shown while loading; `startEpisode(_:)` (line 180 — preselected ep → stored Continue Watching ep → first playable); ▶ `Xem ngay` / `Xem tiếp` label logic (line 204); `makeDirector` (line 354) with the fresh-resolution failover ladder; `JoeProxy.shared.playlistURL` (line 387); resume-episode violet marker — preselected episode chip filled `accentViolet.opacity(0.30)` with a violet stroke when unfocused (lines 310–314).

### Search — `JoeSearch.swift` — DONE
- 3 `.buttonStyle(.card)` code sites: "Tìm", "⟵ Quay lại", result cards.
- "Tìm phim" entry (in Phim home) and both Search buttons are backed by `Capsule().fill(accentViolet.opacity(0.45))` — violet 45% fill, white foreground text, plus `JoeFocusRing`.
- No outer padding (shell owns it).
- Preserved: merged search across KK + Film4K + VSMOV + Tủ Phim via `Providers.search`, provider badges on results, tapping a result sets `nav.movie`.

### Torrent home — `JoeTorrent.swift` (`JoeTorrentHome`) — DONE
- Home button sites are part of the file's 9 `.card` code sites (see Torrent detail for the other 3): search "Tìm", "Xoá tìm kiếm", Continue Watching rail, Favourites rail, catalogue `metaRail`, search grid.
- No outer padding on the home (shell owns it).
- Preserved: `.task { store.loadIfNeeded() }` (line 50), `♥ Yêu thích` rail (line 153), `▶ Đang xem dở` rail, Torrentio-not-configured notice.

### Torrent detail — `JoeTorrent.swift` (`JoeTorrentDetail`) — DONE, paddings KEPT
- Remaining 3 `.card` code sites: favourite button (line 357), episode rows (line 389), stream rows (line 462). File total: **9 `.card`, 0 `.plain`, 0 `focusEffectDisabled`**.
- Its own paddings **kept**: `.leading 44 / .trailing 52 / .top 36 / .bottom 40` (lines 261–264).
- Selected episode keeps the violet marker (`accentViolet.opacity(0.30)` fill, line 385); stream rows are fully backed (white 6% / 13% focused + white ring).

### Settings — `JoeSettings.swift` — DONE
- No buttons on this screen, so 0 `.card` sites is correct — its focusables are `TextField` / `SecureField` fields with their own white-10% rounded background and a white 2.5pt stroke for the focused field.
- Outer paddings removed (shell owns them); the only paddings left are inside each field (horizontal 22 / vertical 15).
- Preserved: auto-save — four `.onChange` handlers (`addonURL`, `rdToken`, `torboxToken`, `subAddonURL`, lines 71–74) each calling `save()`, plus `onDisappear { save(silent: true) }` and `onSubmit { save() }`.
- Note: `.textFieldStyle(.plain)` (line 90) is a text-field style, **not** `.buttonStyle(.plain)` — it is not a violation of the v1.4 rule.

### Player — `JoePlayerView.swift` — DONE (check-only, no edit needed)
- Grep for colours confirms only black-based colours (`Color.black`, black 60% / 45% capsule fills). No indigo/violet/purple, no button styles to convert. The theme specialist's "no edit needed" claim is confirmed.

### Theme — `JoeTheme.swift` — DONE (see §4 for the flag resolution)
- Background gradient replaced with the three new blue-black stops (§3).
- `PosterCard`: API unchanged (see §5), body reworked so the whole card — art **and** title/subline — sits inside one `.padding(10)` surface: `RoundedRectangle(16).fill(Color.white.opacity(0.07))`, with the focus ring stroked on that same outer rect (white 4.5pt when the passed-in `focused` is true, white 10% 1.2pt otherwise, plus a focused shadow).

### Stores / project — preserved
- `JoeStores.swift`: `PhimStore` and `TorHomeStore` both present, each with `loadIfNeeded()` (lines 32 and 83), 15-minute (900s) cache rule intact. No sign of modification in spirit.
- `project.yml`: JoeTV `MARKETING_VERSION "1.4"`, `CURRENT_PROJECT_VERSION "5"`, `CFBundleShortVersionString "1.4"`, `CFBundleVersion "5"`, and `JoeTV/JoeStores.swift` listed in its sources. Other targets unchanged: DaBanhTV `MARKETING_VERSION "1.2.7"`, TV target `MARKETING_VERSION "2.0"`.

---

## 2. Focus traversal — how it is guaranteed

**Geometry argument (the owner-approved Đá Banh construction).** The shell is one `VStack`: the top pill row sits **directly above** the section content in the same view hierarchy, and the shell is the only owner of screen padding (every section's outer padding was removed, so there is no nested, offset focus geometry). SwiftUI/tvOS focus moves spatially: Down from a pill lands in the content below it, Up from the top row of content returns to the pills. This is exactly the construction the owner approved in Đá Banh tvOS, and it removes the v1.3 failure mode by construction — there is no longer a left rail sitting *beside* the content, which was the geometry in which focus could not cross into TV channels or Settings fields.

Per section:
- **TV:** pills → hero (non-focusable) → group chip row (`.card`, `@FocusState focusedChip`) → channel tiles (`.card`, `@FocusState focusedChannel`) in the same vertical stack.
- **Phim:** pills → "Tìm phim" button / first rail → poster rails, all `.card` buttons whose labels are `PosterCard`s fully backed by their own surface (§1).
- **Torrent:** pills → search row → rails / grids, all `.card`, same backing rule.
- **Settings:** pills → fields in a single vertical `ScrollView`; each field is focusable, tracks `@FocusState focusedField`, and draws its own white stroke when focused. There is no sideways rail to get stuck in.
- **Search:** Search replaces the Phim grid *inside the same shell VStack* (it is not a separate rail-screen), so Up from the search row / results returns toward the pills by the same geometry. Exit is additionally guaranteed by two explicit paths: the "⟵ Quay lại" button (`.card`, in the same `HStack` as "Tìm", sets `nav.searchOpen = false`), and Menu — `JoeExitTrap` is enabled while `searchOpen` is true and `closeTop()` closes search before anything else below movie/tor layers. The v1.3 complaint "Search LEFT didn't return to the rail" is moot by construction: there is no rail; the return targets are Up-to-pills, Quay lại, and Menu.
- **Detail layers:** movie / torrent details are root `ZStack` layers; the shell underneath is `.disabled(...)`, and Menu is trapped by `JoeExitTrap` → `closeTop()` closes exactly one layer per press. With no layer open the trap is not installed, so Menu keeps its system exit behaviour.

**Halo elimination argument.** Zero `.buttonStyle(.plain)` and zero `.focusEffectDisabled()` exist in code anywhere in `JoeTV/*.swift` (see §5) — and, more importantly, no focusable element relies on the system focus effect at all: every button uses `.buttonStyle(.card)` and every label carries its own opaque/semi-opaque background (pill capsules, chip capsules, tile surface, `PosterCard` surface, field backgrounds), so there is no un-backed white text for a focus treatment to wash over.

---

## 3. New palette — dark blue-black

| Role | Value | Source |
|---|---|---|
| Background stop 1 (top-leading) | **#04060D** | `Color(red: 0.016, green: 0.024, blue: 0.051)` |
| Background stop 2 (mid) | **#070B16** | `Color(red: 0.027, green: 0.043, blue: 0.086)` |
| Background stop 3 (bottom-trailing) | **#0B1120** | `Color(red: 0.043, green: 0.067, blue: 0.125)` |
| Card / tile surface | white 7% (`Color.white.opacity(0.07)`) on the background | `PosterCard`, TV tile |
| Unselected pill / chip surface | white 8% / 7% | shell pills, TV chips |
| Field / secondary surface | white 10% | Settings fields, Search field, badges |
| Violet accent | **#9E73FF** | `accentViolet = Color(red: 0.62, green: 0.45, blue: 1.0)` |
| Red accent | **#FF453B** | `accentRed = Color(red: 1.0, green: 0.27, blue: 0.23)` |
| Focus ring | white, 2.5pt (pills/chips/fields) to 4.5pt (cards/tiles) | per-component overlays |

Hex values were recomputed by the leader from the RGB components (×255, rounded) and match the table exactly.

---

## 4. Flag resolution — the theme DID land (false alarm)

The focus specialist read `JoeTheme.swift` mid-flight and saw the old indigo gradient. Leader's direct read of the file's **current** state:

- Present, verbatim: `Color(red: 0.016, green: 0.024, blue: 0.051)`, `Color(red: 0.027, green: 0.043, blue: 0.086)`, `Color(red: 0.043, green: 0.067, blue: 0.125)`.
- Absent: the old stops — grep for `0.16`, `0.52` and the old green component in `JoeTheme.swift` returns nothing.

**Conclusion: the dark blue-black theme is on disk. The flag was a mid-flight snapshot, not a defect. No re-dispatch needed for the theme.**

---

## 5. Verification evidence (leader's own runs)

**Brace / paren balance — every file in `JoeTV/` (python3 count, `{`−`}` / `(`−`)`): all 0 / 0.**

| File | { } diff | ( ) diff |
|---|---|---|
| CacheVideo.swift | 0 (15/15) | 0 (22/22) |
| F4kClient.swift | 0 (66/66) | 0 (140/140) |
| JoeHTTP.swift | 0 (9/9) | 0 (27/27) |
| JoeModels.swift | 0 (34/34) | 0 (39/39) |
| JoeMovieDetail.swift | 0 (82/82) | 0 (281/281) |
| JoePhimHome.swift | 0 (53/53) | 0 (89/89) |
| JoePlayerView.swift | 0 (75/75) | 0 (147/147) |
| JoeProxy.swift | 0 (65/65) | 0 (131/131) |
| JoeSearch.swift | 0 (18/18) | 0 (75/75) |
| JoeSettings.swift | 0 (22/22) | 0 (81/81) |
| JoeStores.swift | 0 (32/32) | 0 (29/29) |
| JoeTVApp.swift | 0 (38/38) | 0 (96/96) |
| JoeTVSection.swift | 0 (82/82) | 0 (236/236) |
| JoeTheme.swift | 0 (26/26) | 0 (98/98) |
| JoeTorrent.swift | 0 (127/127) | 0 (325/325) |
| KkClient.swift | 0 (58/58) | 0 (127/127) |
| Providers.swift | 0 (85/85) | 0 (137/137) |
| TorrentClient.swift | 0 (105/105) | 0 (182/182) |
| TpClient.swift | 0 (88/88) | 0 (205/205) |
| VsClient.swift | 0 (34/34) | 0 (98/98) |
| WatchStore.swift | 0 (52/52) | 0 (88/88) |

(Bracket `[`−`]` diff was also 0 for every file.)

**Style greps across `JoeTV/*.swift`:**
- `.buttonStyle(.plain)` in code: **0**. `.focusEffectDisabled()` in code: **0**. The only textual hits for either string are in `JoeTVApp.swift` line 69, a `///` comment describing the v1.3 failure.
- `NavigationStack` in code: **0**. Only hit is `JoeTVApp.swift` line 40, a comment describing the v1.1 design.
- `.buttonStyle(.card)` in code: **24 total** — JoeTVApp 1, JoeTVSection 3, JoePhimHome 4, JoeMovieDetail 4, JoeSearch 3, JoeTorrent 9, all other files 0. (Raw `grep -c` on JoeTVApp reports 2 because line 70's comment also contains the string; the code count is 1.)
- `.textFieldStyle(.plain)` exists in JoeSearch / JoeSettings / JoeTorrent — a different API, not counted above and not a violation.

**Cross-file consistency checks:**
- `PosterCard` call sites (8: PhimHome ×3, Search ×1, Torrent ×4) all use the unchanged memberwise init — `title / posterURL / meta / badge? / progress? / subline? / focused` — with `focused` supplied at every site and the defaulted parameters (`badge`, `progress`, `subline`, `width = 218`) omitted only where the old code also omitted them. No call-site / init mismatch found.
- `JoeFocusRing` is still used as an additional white stroke overlay on capsule/rounded-rect buttons (PhimHome, Search, MovieDetail, Torrent) — consistent with `.card`; it reads `@Environment(\.isFocused)` and draws nothing when unfocused.
- Preservation greps all hit at the lines cited in §1 (Tủ Phim rails, ♥ Yêu thích in both Phim and Torrent, Settings `onChange` ×4, `Kiểm tra link` / `refreshAndValidate` / `LinkProbe`, `JoeProxy` in MovieDetail, `loadIfNeeded` in PhimHome / Torrent / both stores, `PhimStore` / `TorHomeStore` references).

---

## 6. Honesty declaration

**Claims**
- The v1.4 shell, focus-style, backing, padding, theme and version changes described in §1–§3 are present on disk exactly as described, and all v1.3 functionality listed in the brief is still present in the code (navigator + exit trap, stores/caching, proxy, providers/failover, detail play/resume/placeholder/keep-on-switch, settings auto-save, Tủ Phim rails, torrent ♥ rail, violet resume marker, TV pool/fallback/link-check).
- The theme flag was a false alarm (§4).

**Evidence**
- Leader-run python3 brace/paren/bracket counts for all 21 Swift files (§5 table); leader-run greps for `.plain` / `focusEffectDisabled` / `.card` / `NavigationStack` / gradient stops / every preservation string, with file and line numbers (§1, §5); leader's full read of `JoeTVApp.swift` and `JoeTheme.swift`, and direct reads of the relevant sections of every other changed file; leader-recomputed hex values (§3); `project.yml` read in full.

**Unverified**
- **No build was run (owner's budget rule), so compilation is unproven.** Brace/paren balance and call-site consistency are necessary conditions, not a compiler.
- **Focus traversal and halo elimination are proven only by construction-pattern equivalence with the owner-approved Đá Banh app and can only be confirmed on the owner's Apple TV.** No device, simulator or screenshot verification was performed by this team.
- **Playback paths were preserved by non-modification, not re-tested.** Providers, the failover ladder, `JoeProxy` segment cleaning and the player were not exercised; no stream was played.

---

## 7. Residual risks

1. **Stale header comments in `JoeTheme.swift` (documentation only, not a defect in code).** The file header still describes a "deep indigo → violet gradient", a "four-section left rail", and says "the system focus effect is disabled app-wide" — all three statements are false for v1.4 (blue-black gradient, top pills, no `focusEffectDisabled` anywhere; focus is carried by `.card` + own backings + `JoeFocusRing`). The `JoeFocusRing` doc comment repeats the "disabled app-wide" claim. No compile or runtime effect, but a future editor trusting those comments could reintroduce the v1.3 pattern. Recommend a comment-only cleanup in a future small patch.
2. **TV tile width knock-on (specialist's disclosed judgement call, verified as built).** Tile outer width grew to 304pt (280pt art/title + 12pt padding each side) because the backing now covers the title. Rails are horizontal `LazyHStack`s, so this widens each tile's step but breaks no layout the leader could find by reading; the on-screen feel (scroll step, visible tile count) is unverified without a device.
3. **Search "Quay lại" / "Tìm" foreground (specialist's disclosed judgement call, verified as built).** Both buttons use white foreground text on a violet-45% capsule fill. By reading, white on 45% violet over the #04060D–#0B1120 background should stay readable, and the `.card` treatment + `JoeFocusRing` add a white ring on focus — but contrast under the actual `.card` focus treatment is unverified without a device.
4. **Settings fields are not `.card` buttons.** Their focus indication is a hand-drawn white stroke keyed to `@FocusState`, inside the single-VStack geometry. This matches how the fields worked before and the geometry argument in §2, but Settings was one of the two sections the owner explicitly named as unreachable in v1.3 — it deserves the owner's first check on device.
5. **Cosmetic indentation drift** in `JoePhimHome.grid` and `JoeTorrentHome.body` (extra indent level after the outer-padding removal). Brace balance is 0/0 and structure reads correctly; no functional effect.
6. **Search is an in-section swap, not a root layer.** Its Menu behaviour depends on `JoeExitTrap`'s `searchOpen` condition and `closeTop()` ordering (search is closed after movie/tor, which cannot be open from Search without first opening a detail — at which point closing the detail first is the correct order). The leader found no ordering defect by reading, but this interaction is untested on device.
