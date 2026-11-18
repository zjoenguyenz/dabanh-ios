# V2029 — Cluster E: wall home audit bits (item 5) + torrent-screen theme design audit (item 9)

**Files owned / edited:** `JoeTV/JoeTorrent.swift` (3 fixes, item 9).
`JoeTV/JoeBrowse.swift` — **audited, NOT edited**: no item-5 clipping site
exists in it (proof below); the item-5 defect site is in `JoeTV/JoeTheme.swift`
(another cluster's file), reported with exact file:line in §1.
**Presnap:** working tree was byte-identical to `backup-v2029-presnap/` for
both owned files before editing (verified by `diff`; the final
presnap-vs-current diff for JoeTorrent.swift contains ONLY the three fixes
in §3, and JoeBrowse.swift is unchanged).
**Standards used:** themes2 drawings (design-A/D/F stylesheets + detail.html),
`JoeTV/DESIGN-SPEC-V19.md` §7.4/§7.6 (the torrent surfaces' governing spec),
`JoeTV/APPLE-CONFORMANCE.md` (tvOS 26/27 posture), test record
`~/memory/2026-11-18.md` "Test 2.0.28". The owner's photo of the item-9
defect has NOT arrived — see the honesty section.

---

## 1. Item 5 — poster frame cuts text on the poster-wall theme (reported in the TVB section)

Owner's words (test record, 2026-11-18 13:48–13:58 CST): "viền poster
CẮT CHỮ — Giống như trước giờ mình bị lỗi" (the poster's frame cuts the
text — the same fault as before).

### 1.1 Finding — the site is `PosterCard.railBody`, JoeTheme.swift:933–964 (NOT JoeBrowse.swift, NOT JoeMovieDetail.swift)

Design D carries two card forms (JoeTheme.swift PosterCard doc, and
design-D's stylesheet): horizontal rails render `.card` (painted face, title/
meta INSIDE the face), vertical walls/grids render `.pcard` (bare art, title
BELOW the art). The TVB tab's home is built almost entirely of rails
(JoeTVB.swift `card(_:focusID:form:)` at :693–703, called with `form: .rail`
for every rail section at :628/:650), so the cards the owner was looking at
in the TVB section are rail-form cards.

`railBody` (JoeTheme.swift:933–964):

- The face's horizontal padding rides `theme.artInset`, which is **0 under
  posterWall** (JoeTheme.swift:956) — so the title (25 pt, :936–940) and the
  meta line (23 pt, :942–948) start flush at the card's left edge, x = 0,
  exactly as design-D's `.card` draws them (`padding: 0 0 14px`, title flush).
- The focus/rest ring is an **`.overlay` INSET `strokeBorder` around the
  whole card** (JoeTheme.swift:961–963): resting 1.5 pt `theme.stroke`,
  focused **`theme.ringWidth` = 6 pt** `theme.focus` (#FFD60A under D).
  An inset strokeBorder paints its band INSIDE the bounds, i.e. over
  x ∈ [0, 6] — **on top of the first glyph of the title and meta lines**
  (and symmetrically over the last glyph/ellipsis at the right edge).
- In the drawing this cannot happen: design-D's `.card.focused` ring is a
  CSS `box-shadow: inset 0 0 0 6px #FFD60A`, and a CSS inset shadow paints
  above the element's background but **below its content** — the glyphs
  paint over the ring. SwiftUI's `.overlay` paints above ALL content. Same
  values, different paint order: that is the whole defect.
- Why only theme D: the other themes never use `railBody` (the `form`
  value is read only under posterWall), and their face form (`faceBody`)
  insets its text by `artInset` 10 (A) / 12 (F) — more than their 4 pt
  ring — so their glyphs clear the band. D is the only theme whose drawn
  text is flush (artInset 0) AND whose ring is 6 pt.
- Why it reads as "the old fault recurring": it is the same family the
  v2.0.5 note in JoeTheme.swift records for the wall form ("an inside
  strokeBorder ring ate the first glyphs of Poster Wall card titles").
  The wall form was cured by moving its ring OUTSET around the art; the
  rail form kept an inset whole-card ring over flush text.

**Every surface that inherits the defect** (all call `PosterCard(form: .rail)`
under posterWall): JoeTVB.swift:628, :650 (TVB rails + actor rail — the
reported surface); JoeBrowse.swift:998 (wall category sections), :1023 (wall
Continue Watching), :1053 (wall Favourites), :1104 (wall Following);
JoePhimHome.swift:1369, :1404, :1453; JoeMovieDetail.swift:1634 (franchise
strip). One fix in `railBody` cures all of them.

**Suggested fix for the owning cluster (NOT applied — not my file):** paint
the ring between the face fill and the content, as the CSS shadow sits —
e.g. move the strokeBorder onto the background face shape (an overlay on
the `RoundedRectangle` fill itself, under the VStack), keeping every value
(rCard, 1.5 resting stroke, 6 pt focused ring, colours) byte-identical.
Do NOT inset the text instead: the drawing's text is flush, so padding the
text would deviate from the drawing to hide a paint-order fault.

### 1.2 Cleared sites inside my own files (checked, no fault, no change)

| Site | Why it cannot cut text |
|---|---|
| Wall grid cards, JoeBrowse.swift `JoeBrowseView` grid (:548–567) and `JoeWallHomeView` wall grid (:777–793) | Use `PosterCard` default form `.wall` → `wallBody` (JoeTheme.swift:894+): ring is an OUTSET band around the ART only (joeOutsetStrokeBorder), title sits 14 pt below the art — 8 pt clear of the 6 pt band. Grid edge clearance is 8 pt horizontal under D (JoeBrowse.swift:567, :793) ≥ the 6 pt band, and vertical padding 8 (:561) / stack spacing 36 covers the band at the frame edges. |
| TVB genre grid (JoeTVB.swift:677, `form: .wall`) + TVB search grid | Same `.wall` anatomy and the same 8 pt clearances as the JoeBrowse grids. |
| D detail poster, JoeMovieDetail.swift `posterArt` :1438–1445 | Bare art with a 2 pt OUTSET stroke (theme.stroke); the title is a separate element 24 pt below the poster (wallDetail :672–678). The ring touches no text. (The D detail's missing-buttons fault is item 4, another cluster — not this item.) |
| Poster art itself (JoeTheme.swift `art`, JoeImagePipeline `JoeRemoteImage` fit:true) | Posters are `scaledToFit` into exact 2:3 frames — the whole poster, including its own printed lettering, is always visible; nothing crops it. |

**Item-5 action taken in my files: none — there is nothing in JoeBrowse.swift
or JoeTorrent.swift that produces this fault.** The fix belongs to the
JoeTheme.swift owner at JoeTheme.swift:961–963 (ring paint order in
`railBody`, :933–966).

---

## 2. Item 9 — torrent-screen theme design audit

### 2.0 Which standard governs the torrent surfaces

There is **no torrent-specific drawing** in themes2 (design-A..F draw
home/grid/detail/search/settings for the Phim surfaces). The torrent
surfaces' governing contract is DESIGN-SPEC-V19 §7.6: *"Home mirrors Phim
chrome: header + search button, catalogue and genre rails reuse §7.2
cards. Search results: LazyVGrid, 6 columns… Detail mirrors §7.4 metrics
for its header block; stream rows: height 64, label 29… outline-only
focus."* On top of that, each theme's tokens/drawings govern the shared
components the torrent surfaces reuse (PosterCard, chips, .btn chrome),
and the Ultra torrent detail's composition standard is the owner-approved
Sony/Phim4K form already mirrored from JoeMovieDetail. tvOS 27 posture
(APPLE-CONFORMANCE.md §1–§2 + V2028-FIX-REPORT P3): the app is built
against the tvOS 27 SDK; Liquid Glass is focus-driven for standard
components; this app's chrome is hand-built to the approved drawings and
suppresses the system treatment centrally (custom `JoeCardButtonStyle` +
`focusEffectDisabled`, JoeTheme.swift) — **glass adoption is an
appearance change = owner decision (proposal P3), not an audit fix.**

### 2.1 Drawing/spec-vs-app table

| # | Detail | Drawing / spec value | App value (before) | File:line | Action |
|---|---|---|---|---|---|
| T1 | Torrent home rails card form (D) | design-D home: rails are `.card` (painted face); every other rail call site in the app passes `form: .rail` | `form: .rail` already passed at all three rail sites (CW :224, favourites :264, catalogue/genre :431) | JoeTorrent.swift:218–224, 260–264, 427–431 | ✅ Checked — conformant, no change. (First-pass suspicion of a `.wall` default here was disproven by direct grep/read.) |
| T2 | Torrent search grid | §7.6: 6 columns, row gap 40; D wall ring outset 6 pt needs edge clearance past it | 6 flexible columns, spacing 28, row spacing 40; `.padding(.horizontal, posterWall ? 8 : 0)` | JoeTorrent.swift:445–469 | ✅ Conformant, no change. |
| T3 | Detail header block (§7.4 metrics via §7.6) | Poster 240×360; title 64; meta 29; overview 29, ≤5 lines | Poster 240×360; title 64 heavy, lineLimit 3; year 29; desc 29, lineSpacing 8, lineLimit 5, maxWidth 1050 | JoeTorrent.swift:733–800 (hero) | ✅ Conformant, no change. |
| T4 | Detail poster frame | §7.4: r16 hairline frame. (themes2 Phim details elaborate per theme: A/F painted frame, D outset 2 pt stroke.) | Bare art, INSET strokeBorder white 0.14 / 2 pt, radius theme.rCard, no painted frame in any theme | JoeTorrent.swift:754–763 | UNVERIFIED — deliberate recorded construction ("the torrent surfaces carry no drawing of their own", comment at the site). Per-theme frame parity with JoeMovieDetail.posterArt is a composition change; needs the owner's photo / decision. No change. |
| T5 | Favourite button chrome | themes2 `.btn`: 29 pt semibold (600), padding 17×36, surface fill, resting inset stroke 1.5 theme.stroke, focused ring ringWidth theme.focus (= JoeSecondaryLabel, JoeTheme.swift) | 29 pt **medium**, padding **16**×36, surface2 fill, JoeFocusRing overlay (**no resting stroke**) | JoeTorrent.swift:821–826 (presnap) | **FIXED** — see §3, change 1 (JoeTorrent.swift:820–837 after edit). |
| T6 | Episode-row selected state | `.chip.sel` in every themes2 sheet + JoeMovieDetail epChip (JoeMovieDetail.swift:1936–1957, "UI-6 defect D-4" note): SOLID accent fill, onAccent text, semibold | Accent at **30% opacity** fill, resting `theme.text` colour, bold | JoeTorrent.swift:898–907 (presnap) | **FIXED** — see §3, change 2 (JoeTorrent.swift:904–939 after edit). Row anatomy (25 pt full-width rounded rect) untouched. |
| T7 | Episode-row focus ring on selected+D | Owner's D ruling (JoeChipLabel / epChip): selected+focused under posterWall wears an OPAQUE WHITE frame (accent == focus == #FFD60A in D) | JoeFocusRing — always theme.focus, so on the (new) solid D fill the ring would be invisible | JoeTorrent.swift:907 (presnap) | **FIXED** as part of change 2 — ring now mirrors epChip's exact rule incl. the white branch and the 1.5 resting stroke for unselected rows. |
| T8 | Cast row construction | JoeMovieDetail castRow/castCell (the row this row mirrors): cells 120 wide, circle 110, name 23 semibold lineLimit 2, character 23 lineLimit **2**, heading 34 bold | Identical except character lineLimit **1** | JoeTorrent.swift:1195 (presnap) vs JoeMovieDetail.swift:1590–1598 | **FIXED** — see §3, change 3 (JoeTorrent.swift:1234 after edit). |
| T9 | Cast row focus | Focus behaviour is another cluster's item (per assignment). Overlap flagged, not fixed: torrent cast cells carry NO `.focused` binding at all, while JoeMovieDetail castCell binds `.focused($focusedCast, equals: member.id)` (JoeMovieDetail.swift:1610). BOTH rows' circles carry only the constant white-0.14/1.2 stroke — neither paints a focus ring. This matches the test record (Billboard torrent detail: cast names in full, no focus; JoeTorrent.swift:1181–1260 torCastRow). | JoeTorrent.swift:1181–1260 | FLAGGED for the cast-focus cluster — the visual fix must land on both rows together; no change here. |
| T10 | "Chưa có nguồn phát" on Billboard torrent detail (test record item d) | — (functional state, not a drawing value) | streams.isEmpty copy at JoeTorrent.swift:943 (presnap) — the empty-state line, shown when the pooled fetch returns nothing; not a design deviation | JoeTorrent.swift streamSection | Noted — data/functional state, outside this design audit; no change. |
| T11 | Detail composition per theme | themes2 details differ per theme (A backdrop band, D centred, F source-first) for PHIM details; §7.6 requires only §7.4 header metrics for torrent | One standard hero composition for A/D/F; Ultra has its own composition (ultraBody + frosted Chọn Server panel, JoeTorrent.swift:653–731) | JoeTorrent.swift:580–731 | UNVERIFIED — no torrent detail drawing exists to deviate from; §7.6 is satisfied (T3). Whether the owner's photo shows this gap cannot be known without the photo. No change. |
| T12 | Ultra torrent backdrop full-bleed | Owner verdict 2.0.22/2.0.23: backdrops must bleed edge-to-edge | `ultraTorBackdrop` carries `.ignoresSafeArea()` (the v2.0.23 fix; owner confirmed the torrent theme fixed in 2.0.23) | JoeTorrent.swift ultraTorBackdrop | ✅ Conformant (previously fixed), no change. |
| T13 | Ultra panel stream rows | Sony/Ultra form: spec + language lines under the label, parsed only from the stream's own tokens | Present (ultraSpec, theme.id == .ultra branch) | JoeTorrent.swift streamRow | ✅ Conformant, no change. |
| T14 | Stream rows | §7.6: height 64, label 29, outline-only focus (the one sanctioned variant) | Label 29 ✓; focus = JoeFocusRing outline-only, fill never changes on focus ✓; height is content-driven (>64) because each row also carries the release-title line (25 pt) — data the owner picks sources by | JoeTorrent.swift streamRow | Deviation from the §7.6 height noted; action UNVERIFIED/no change — removing the title line would delete owner-facing source data (a redesign), and §7.6 predates the pooled Torrentio+MediaFusion rows. Not changed. |
| T15 | Home header | §7.6 "mirrors Phim chrome" (Phim slim header = 44 heavy, JoePhimHome.swift:1157) | Title 56 heavy + 25 subtitle (JoeTorrent.swift:149–158) — but 56 heavy is also the TV section's and Settings' section-title size (JoeTVSection.swift:167, JoeSettings.swift:72), so house practice is mixed | JoeTorrent.swift:152 | UNVERIFIED — no single governing value; not changed without the owner's photo. |
| T16 | tvOS 27 / Liquid Glass posture | APPLE-CONFORMANCE: system glass focus treatment must not layer over the app's drawn focus; glass chrome adoption = owner decision P3 | Every torrent focusable uses the central `.joeCardButton()` (custom style + focusEffectDisabled); the search field uses `.joeFieldChrome` (system treatment disabled centrally, drawn outset ring is the sole treatment). No standard TabView/material chrome exists on these surfaces to auto-adopt glass | JoeTorrent.swift throughout (searchRow :160–196, rails, detail) | ✅ Conformant with the app's established tvOS 27 posture. No change — adopting glass would override the approved drawings and is the owner's P3 call, already on record in the V2028 report. |
| T17 | ViSub status capsule (beside favourite) | App-internal element (cf. JoeMovieDetail providerChip: 25 semibold, H14 V7, surface2) | 25 regular, H14 V7, white-0.10 fill | JoeTorrent.swift hero / ultraPanel | Minor mirror drift noted; not a drawing value, not changed. |

---

## 3. Every change made (all in JoeTV/JoeTorrent.swift; verified by presnap diff — no other line differs)

1. **Favourite button chrome → .btn values** (after-edit :820–837):
   font 29 medium → **semibold**; vertical padding 16 → **17**; overlay
   `JoeFocusRing(Capsule())` → explicit `Capsule().strokeBorder` mirroring
   JoeSecondaryLabel (resting 1.5 theme.stroke; focused theme.focus at
   theme.ringWidth, keyed on the button's own `focusedRow == "fav"`
   binding — the epChip pattern of reading the detail's FocusState).
   Fill (surface2), horizontal padding (36) and the heart-state text
   colour are unchanged.
2. **Episode-row selected state → the drawings' selected treatment**
   (after-edit :904–939): fill accent.opacity(0.30) → **solid theme.accent**;
   text theme.text → **selected ? theme.onAccent : theme.text**; weight
   selected bold → **semibold**; overlay JoeFocusRing → explicit
   strokeBorder mirroring JoeMovieDetail epChip's rule verbatim in
   structure (focused: posterWall+selected ? white : theme.focus;
   resting: selected ? clear : theme.stroke 1.5; width ringWidth when
   focused), keyed on a new `rowFocused` value read from the existing
   `focusedRow` FocusState. Row size/padding/radius/layout unchanged.
3. **Cast character lineLimit 1 → 2** (after-edit :1224–1234), matching
   the mirrored Phim cast cell (JoeMovieDetail.swift:1596).

JoeBrowse.swift: **no changes** (see §1.2).

Syntax: no local compiler exists; the edited file was checked by full
presnap diff (only the three hunks above) and brace/paren/bracket balance
(0/0/0). All APIs used are already used elsewhere in the target
(strokeBorder ternaries identical in shape to JoeMovieDetail epChip /
JoeTheme JoeChipLabel); deployment target 17.0 respected. CI is the first
real compile, as with every cluster.

---

## 4. Honesty section

**Claims (evidence-backed):**
- Item 5's clipping mechanism is proven from code + drawing: JoeTheme.swift
  railBody :933–966 paints a 6 pt inset overlay ring over text that the
  drawing places flush (artInset 0 under D), while the drawing's CSS inset
  shadow paints under the text. The TVB surface the owner reported renders
  this form (JoeTVB.swift:628/:650 via :693–703).
- No clipping site exists in JoeBrowse.swift: its wall surfaces use the
  `.wall` form whose ring is outset around the art with 14 pt of clearance
  to the title, and its grid clearances (8 pt) exceed the 6 pt band
  (JoeBrowse.swift:561–567, :793). JoeBrowse.swift is byte-identical to
  the presnap.
- The three item-9 fixes are value-exact against their standards
  (themes2 `.btn` / `.chip.sel`, JoeMovieDetail epChip :1936–1957,
  castCell :1590–1598) and are the ONLY diffs in JoeTorrent.swift vs the
  presnap.

**Evidence:** presnap-vs-current `diff` of both owned files (JoeTorrent:
exactly the 3 hunks in §3; JoeBrowse: empty); grep-verified call sites and
line numbers throughout; themes2 design-D/A/F stylesheets and detail.html
read directly; DESIGN-SPEC-V19 §7.4/§7.6 read directly.

**Unverified — explicitly needs the owner's photo (item 9):**
- WHAT the owner actually saw on the torrent screens is unknown: his photo
  has not arrived. None of the three fixes is claimed to be "the" defect
  he photographed; they are the only deviations provable from the
  drawings/spec without it. Rows T4, T11, T14, T15 are the candidate
  larger gaps (single non-themed detail composition for A/D/F; §7.4-era
  poster frame; stream-row height; 56 pt home header) — all deliberately
  left unchanged because each fix would be a composition decision, not a
  value correction.
- Whether the item-5 ring-over-glyph is exactly what the owner saw in the
  TVB section (vs. e.g. a device-photo artefact) can only be confirmed on
  device after the JoeTheme fix; the mechanism itself is proven in code.
- Liquid Glass adoption (P3) remains an open owner decision from the
  V2028 round — this audit neither applies nor recommends it; the torrent
  surfaces currently follow the app's approved-drawing posture on
  tvOS 27 (T16).
- The Billboard torrent-detail symptoms in the test record (cast without
  focus — flagged at T9 for the cast-focus cluster; "chưa có nguồn phát"
  — T10, a data state) are not design-audit fixes and were not touched.
