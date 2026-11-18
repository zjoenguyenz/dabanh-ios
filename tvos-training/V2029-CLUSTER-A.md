# JoeTV tvOS 2.0.29 — CLUSTER A report (detail pages, cast, actor page, recommendation identity)

Worker scope: `JoeTV/JoeMovieDetail.swift`, `JoeTV/JoeActorPage.swift`, `JoeTV/JoeTVB.swift`
only. Two sub-items' faulty sites sit in files outside this cluster; per the dispatch
rules those were NOT edited — the exact sites are reported below for the owning cluster.
All line numbers are the post-edit tree unless marked "(pre-fix)".

---

## Item 1a — Cast row has NO visible focus on detail pages

**Root cause (code-proven).** The app's one button construction, `.joeCardButton()`
(JoeTheme.swift:467), installs a custom `ButtonStyle` that returns the label untouched
PLUS `.focusEffectDisabled()` — the system focus treatment is suppressed centrally, by
design. Every focusable surface survives that only because its LABEL reads its own focus
from `@Environment(\.isFocused)` and paints a value-only ring (PosterCard, JoeChipLabel,
JoePrimaryLabel, JoeSecondaryLabel — JoeTheme.swift). The cast cell never did:
`castCell` (JoeMovieDetail.swift, pre-fix :1567) built its label as a bare
`VStack` — photo circle with a STATIC `Color.white.opacity(0.14)` / 1.2 stroke, name in
static `theme.text`. No `isFocused` read anywhere in the cell. A focused cast cell was
therefore pixel-identical to an unfocused one, in every theme that renders `castRow`
(Ultra, D/wall, F/Nguồn) — exactly the owner's "chọn được nhưng không có focus".
Design A (Billboard) was the exception that proves the mechanism: its `actorsLine` names
ride `JoeActorNameLabel` (JoeMovieDetail.swift:1159), which DOES read `isFocused` — and
the owner confirmed Billboard's normal-film cast focus works (white vs grey text).

**Fix (JoeMovieDetail.swift).** `castCell` (:1590) now renders a new label view,
`JoeCastCellLabel` (:1619), built exactly on the PosterCard pattern: it reads
`\.isFocused`; focused, the photo's always-installed circle stroke takes
`theme.focus` at `theme.ringWidth` and the name takes `theme.focusTitle`; at rest every
value is byte-identical to the pre-fix label (110 pt circle, white .10 fill,
white .14 / 1.2 resting stroke, 23 pt name/character, 120 width). The cell carries no
selected fill, so the posterWall white-ring exception for yellow-filled items does not
apply — the yellow ring on a dark, unfilled cell is visible. The now-dead `castInitial`
helper was removed (its only call sites moved into the label).

**Torrent cast — SAME disease, NOT my file (report, not edited).**
`JoeTorrentDetail.torCastRow`, **JoeTorrent.swift:1181** (cells at :1181–:1241): the
cells are `Button` + `.joeCardButton()` with NO `.focused(...)` binding and a label with
no `isFocused` read and no `JoeFocusRing` — the identical invisible-focus construction.
This is the owner's "Billboard torrent / torrent nói chung: diễn viên hiện, không focus".
Prescribed fix for the torrent cluster: mirror the `JoeCastCellLabel` treatment (or add
`.overlay(JoeFocusRing(shape: Circle()))` on the photo + a `.focused($focusedRow, …)`
binding). The row's call sites already wrap it in `.focusSection()` (JoeTorrent.swift:589,
:711), so only the cell visual is missing there.

**Per-theme verification (code).** Ultra — castRow inside header section, cells now paint
focus ✓. D/wall — same cells ✓ (plus §1b section fix). F/Nguồn — same cells ✓ (plus §1b).
A/Billboard — actorsLine already correct, untouched ✓. Torrent (all themes) — site
reported above, unedited.

---

## Item 1b — Focus/navigation unstable on pages with a cast row

**Root causes (code-proven parts).**

1. **The invisible cast focus itself (§1a).** When focus moved onto a cast cell there
   was no marker anywhere on screen — the owner's "lúc thì focus hiện ở nguồn phát + Xem
   ngay, lúc thì không hiện gì" is the expected reading of focus sitting invisibly on a
   cast cell. Fixed by §1a.
2. **The cast row stood in NO focus section in two of the four themes.** Every other
   block on the detail page declares `.focusSection()` (headers, source block, episode
   block — JoeMovieDetail.swift passim). But in `wallDetail` (D) the cast row sat
   between the header's section and `altChips`' section unsectioned, and in
   `boardDetail` (F) it sat between the source rows' section and the episode block's
   section unsectioned. (Ultra's cast row rides inside its header section, :605; A's
   actors line inside its header section, :468 — those two were already declared.)
   An unsectioned focusable region between two declared sections is exactly where the
   tvOS focus engine's section-to-section movement has no declared unit to land in.
3. **The cast row inserts into the hierarchy AFTER initial focus lands.** `tmdb` starts
   nil; the cast merges in a later staged `.task` publication (detailScroll's TMDB task),
   so `castRow` (and later the franchise strip) appears mid-session under a focus that
   has already settled, forcing the engine to re-resolve over a changed graph. This is
   structural to the staged loading design and is mitigated, not removed, by (1)+(2):
   with the row a declared section and its cells visibly focusable, a re-resolution now
   lands somewhere the owner can see and navigate from.

**Fix (JoeMovieDetail.swift).** `.focusSection()` added at the two unsectioned cast call
sites — D at :740 (inside `wallDetail`), F at :842 (inside `boardDetail`). Plus the
deterministic initial-focus write in §4 below, which removes the "sometimes Xem ngay,
sometimes nowhere" landing variance at page open. TVB pages are JoeMovieDetail pages
(TVB titles open through `JoeTVBView.open` → `MovieRoute` → the same detail), so the
TVB-worst case rides the same fixes; JoeTVBView's own rails/header were audited and are
already sectioned with visible-focus PosterCards — no change made there.

**UNVERIFIED (labelled).** That insertion-churn (3) alone ever dropped focus to a
specific wrong element cannot be proven from code; the device retest is the proof gate
for how much of the "chạy tùm lum" remains after (1)+(2)+§4. No further mechanism is
claimed.

---

## Item 1c — Actor page films not selectable (JoeActorPage.swift)

**Root causes (code-proven).**

1. **No initial-focus landing existed at all.** The page declared no `.defaultFocus`
   and never wrote any `@FocusState`. While `loaded == false` the ONLY focusable element
   on the page is the header's "⟵ Quay lại" button; when the filmography lands and the
   grid inserts beneath it, nothing steers focus to a film.
2. **The header stood in no focus section** while the film grid declares one
   (`cardGrid`, :239) — an unsectioned head over a sectioned body.
3. **The rows the owner sees can be the deliberately dead ones.** A credit that the
   at-load catalogue match missed renders under "Chưa có nguồn phát" as
   `unmatchedRow` — pre-fix a PLAIN `HStack`, not a Button, carrying no focus handling
   BY DESIGN (pre-fix JoeActorPage.swift:271 comment: "deliberately not a Button"). A
   credit lands there whenever the load-time match missed it — including titles a
   provider does carry but whose catalogue record wasn't in the PhimStore lists the
   matcher walks (or carried no TMDB id). To the owner that list IS "the actor's films",
   and none of them could be pressed: "không có nút bấm vào".

**Fixes (JoeActorPage.swift).**
- Header is its own `.focusSection()` (:135).
- `landInitialFocus()` (:490), called at the end of both `load()` branches (:421,
  :472) — the same write-at-load mechanism the detail's error branch already uses
  (`focusedRetry = true`): lands on the first playable card (PhimStore matches, then
  TVB matches, then .tvb mode's first snapshot card), falls back to the first unmatched
  row, and to Quay lại only when the page carries no film row at all. The matched
  cards themselves were already real Buttons opening the title's detail via
  `openMovie`/`openTVB` (the navigator's normal MovieRoute) — unchanged.
- `unmatchedRow` (:298) is now a Button (`.joeCardButton()`, bound to `cardFocus` as
  `"unmatched|" + credit.id`); its label is the pre-fix row pixel-identical at rest,
  plus a `JoeFocusRing` overlay (clear at rest) so focus is visible. Its press runs
  `resolveAndOpen` (:353): providers searched by the credit's title in
  `Providers.priority` order, accepting ONLY a result whose TMDB id equals the credit's
  own id (type must agree when both records state one) — the franchise strip's
  acceptance discipline (JoeMovieDetail.loadFranchise). No ID match → the press does
  nothing; the row never opens a lookalike.
- Follow-up copy note (not changed): the section heading still reads "Chưa có nguồn
  phát" although its rows now attempt an ID-locked resolution on press. Heading copy is
  a design/owner call; flagged here rather than silently rewritten.

---

## Item 4 — Detail pages missing controls

**Coordinator's hypothesis checked and REFUTED in its strong form.** There is no
separate info-only detail variant anywhere in the target: `multilineTextAlignment(.center)`
detail compositions exist only in JoeMovieDetail.swift, and design D renders ONE
`wallDetail` for movies and series alike (its header Group contains poster, title,
origin, meta, genres, synopsis AND the play/favourite/follow row, :649–:743 pre-fix).
The owner's photo matches that header block element-for-element, in order (poster →
title → English origin title → "2026 · FHD · Vietsub · 120 phút · Đang chiếu: Full" →
genre chips → synopsis). The TVB-section route into D is not another branch either:
`JoeTVBView.open` mints the same `MovieRoute` and the same JoeMovieDetail renders it.
What differs between the broken cases and the working ones is not the view — it is
whether the page ever gets a live focus.

**Root cause (code-proven chain).**
- The detail's only initial-landing declaration is `.defaultFocus($focusedPlay, true)`
  on detailScroll (JoeMovieDetail.swift:305) — an appearance-time claim on the play
  button, which does not exist while the placeholder stands.
- `playButton` is `.disabled(startEpisode(d) == nil || switching)`
  (JoeMovieDetail.swift, playButton). `startEpisode` is nil exactly when the loaded
  detail carries NO playable episode.
- A detail can legitimately carry none: TpClient appends a server only when its
  episodes are non-empty (TpClient.swift:240–243) and KkClient does the same
  (KkClient.swift:284). A movie whose provider detail returns no playable server —
  and TVB titles routed through Tủ Phim, whose TP detail is built the same way — loads
  with `servers` empty: synopsis and meta render (they come from the detail payload),
  the play button renders DISABLED (unfocusable), and there are no episode chips.
- With the declared landing pointing at a disabled button and the shell beneath the
  detail layer `.disabled` (JoeTVApp.swift:318), the page can end up with no focus the
  owner can see or move — and a tvOS ScrollView scrolls by following focus, so the page
  cannot scroll either: poster/title/meta/genres/synopsis on screen, everything below
  unreachable. That is the photo, and the F/Nguồn "khung thông tin che hết các nút"
  report (same shared machinery: `boardDetail`'s play button is the same `playButton`,
  the same `.defaultFocus`, the same `load()`). Series on the wall work because their
  play button is enabled and the landing resolves. TVB series on the wall break when
  their TP/KK detail lands with no playable server, same as movies.

**Fix (JoeMovieDetail.swift, shared by all four themes).** `landInitialFocus(on:)`
(:2056), called once at the first paint of a first-open load — from the cache paint
(:2155) and both network paints (:2172 and the no-cache paint below it) — and NEVER
from the provider-switch path, so a source switch never yanks focus off the tapped
chip. It writes `focusedPlay = true` when the play button can take focus
(`startEpisode(d) != nil`), else `focusedFav = true`: the favourite button is never
disabled, so every detail page now deterministically opens with a live, visible focus
from which the owner can scroll to the source chips, cast and episode blocks that the
compositions already render. No layout, value or composition changed in any theme;
nothing was added to or removed from any drawing.

**Per-theme verification (code).** D/wall — photo case covered: landing now resolves
(play or favourite) and the already-rendered controls below the header become
reachable by focus-following scroll ✓. F/Nguồn — same shared fix; its head, source
rows, episode block and cast were already rendered by `boardDetail` ✓. Ultra —
`ultraDetail` uses the same `playButton`/`load()` ✓. A/Billboard — same ✓. TVB via
wall — same detail, same fix ✓.

**UNVERIFIED (labelled).** Whether the owner's specific Phí Phông and TVB titles in
fact loaded with empty `servers` on device cannot be proven from this VM (it depends
on the live provider payloads at test time); the chain above is the only code path
found that produces the photographed state, and the fix makes the page live-focusable
and scrollable in BOTH the empty-servers case and the normal case. The F theme's exact
on-screen appearance ("panel covers the controls") was not photographed to this
worker; the fix rests on the shared-machinery identity, which is code-proven.

---

## Item 5 (my half) — Poster frame cuts text on the wall theme

**Finding: no edit made — the sites are outside this cluster, reported exactly.**

- In my files, the D detail poster is `posterArt` (JoeMovieDetail.swift:1431): the art
  is `scaledToFit` (JoeRemoteImage `fit: true` — the whole poster is always visible,
  never cropped) inside the exact 300×450 frame, clipped by
  `RoundedRectangle(cornerRadius: 18)` (:1456) with the 2 pt OUTSET stroke over it —
  the design-D drawing's own values (the drawing's detail poster carries radius 18 and
  the outset frame line). The only pixels that clip can ever take are the poster's
  extreme corner triangles. Changing the radius would deviate from the approved
  drawing, so it is NOT changed on a "cuts text" reading alone; if the owner means
  poster-corner credit text, that is a drawing-level decision for him, flagged here.
- The wall CARDS' text/ring geometry — the other surface the complaint can mean — lives
  in **JoeTheme.swift:894** (`PosterCard.wallBody`: art + outset focus ring, title/meta
  below the art), with its grid containers at **JoeBrowse.swift:542–580** (the wall
  browse grid; it already carries the D clearance padding, horizontal 8, past the 6 pt
  outset ring) and, in my own file, JoeTVB.swift's `genreSection` grid and
  `JoeTVBSearchView.resultsArea`, both of which already carry the same D clearance
  (horizontal 8 under posterWall) — audited, no change.
- **UNVERIFIED (labelled):** which surface the owner meant (detail poster vs wall
  cards) cannot be settled from the written reports alone; no code-provable
  text-clipping defect was found in my three files for this item.

---

## Item 7 (my half) — Wrong-title resolution in recommendation rails

**Primary faulty site — NOT my file (stopped, reported exactly).** The one rail whose
cards are resolved from a bare title string is the home Trending rail
("hàng phim đề cử" family): `JoePhimHome.loadTrending` resolves TMDB trending titles
into Movies in two rungs. Rung 1 is ID-locked (catalogue map by TMDB id). Rung 2,
**`trendingSearchMatch`, JoePhimHome.swift:791–814**, searches the providers by the
trending title's TITLE STRING and, behind the ID match, accepts at **:806–812** the
FIRST result whose normalized name OR origin name equals the trending title's
normalized name — with **no TMDB-id requirement, no year check, and no type check**.
TMDB's vi-VN translated titles are not unique identities (different films share a
translated title; a film and a same-named other work collide the same way), so the
card can bind a different film that merely shares the name — the card then shows that
film's list name ("Có máy thời gian") while its detail is the other film
("Step Into The Past"). The trending title cannot defend itself: `TrendingTitle`
(**JoeTopShelfWriter.swift:63–69**) carries tmdbId/type/title but NO year field, so
even a year gate is impossible at that site today.
Prescribed fix for the owning cluster: in rung 2 accept ONLY a TMDB-id match (drop
the byName acceptance, exactly the discipline loadFranchise already enforces), or —
if name acceptance must stay — add `year` to TrendingTitle (TMDBClient.trendingWeek,
JoeTopShelfWriter.swift:325) and gate byName on exact year + type equality. No edit
made here: both files are outside cluster A.

**My files — audited, one hole tightened.**
- JoeMovieDetail franchise strip (`loadFranchise`): acceptance is already
  TMDB-id-only (`$0.tmdbId == partKey`, type must be movie-or-unstated) — identity
  locked ✓, no change.
- JoeTVB rails (all, incl. "⭐ Đề cử"): cards are `TVBTitle`s and a tap opens the
  title's OWN `routeTarget` (its snapshot record's provider + first slug) — identity
  locked at the tap ✓, no change. The TVB search grid is the same construction ✓.
- JoeActorPage catalogue matching (my §1c file): the map was keyed by the BARE TMDB
  id (`catalogueByTmdbId`, pre-fix), although TMDB's numeric ids are per-type
  namespaces — a movie and a TV title can share the number, so a credit could bind
  the same-numbered title of the other kind, and a typed record could shadow an
  untyped one under the bare key. Tightened: typed records are now keyed
  `"type|tmdbId"`, only typeless records ride the bare key, and the credit lookup
  tries the typed key first (JoeActorPage.swift:444–472 matching, :517 map). Recall
  is preserved case-for-case (typed↔typed, untyped via bare key); the cross-type
  binding is removed. The same bare-key pattern also exists in
  JoePhimHome.catalogueByTmdbId (JoePhimHome.swift:753) — outside this cluster,
  reported for the owner of that file.

---

## Honesty declaration

- **Claims:** §1a's invisible-focus mechanism and its fix; §1b causes (1) and (2) and
  the focusSection fixes; §1c causes (1)–(3) and its fixes; §4's disabled-play /
  no-landing / no-scroll chain and the shared landing fix; §7's rung-2 acceptance flaw
  (reported, unedited) and the actor-page key tightening — all as described, at the
  sites named.
- **Evidence:** full reads of JoeMovieDetail.swift, JoeActorPage.swift, JoeTVB.swift,
  JoeTheme.swift (button construction + labels), JoeTorrent.swift (torCastRow),
  JoePhimHome.swift (trending resolution), JoeTVApp.swift (detail layering), the
  owner's item-4 photo (read directly: wallDetail's header block, element-for-element),
  TpClient.swift:240–243 / KkClient.swift:284 (server-append rule), and a post-edit
  diff of both edited files against `backup-v2029-presnap/` (reviewed in full;
  brace/paren/bracket balance 0 in all three owned files; JoeTVB.swift untouched).
- **UNVERIFIED, labelled:** there is NO Swift toolchain on this VM — nothing here is
  compile-verified until CI runs, and nothing is device-verified until the owner
  retests on tvOS 27.2.1. §1b's insertion-churn contribution is structural reasoning,
  labelled in place. §4's empty-servers state for the owner's specific titles depends
  on live provider payloads and is labelled in place; the F theme's exact photographed
  appearance was not available to this worker. §5's target surface is ambiguous in the
  written reports and is labelled in place. §7's specific "Có máy thời gian" /
  "Step Into The Past" pairing cannot be reproduced from code alone; the acceptance
  flaw that permits the class is code-proven at the cited lines.
- **Out-of-scope sites handed off:** JoeTorrent.swift:1181 (torrent cast focus visual,
  §1a); JoePhimHome.swift:791–814 + JoeTopShelfWriter.swift:63–69 (trending rung-2
  identity, §7); JoePhimHome.swift:753 (bare-id catalogue map, §7 note);
  JoeTheme.swift:894 (wall card geometry, §5 note).
