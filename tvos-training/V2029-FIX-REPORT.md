# JoeTV tvOS 2.0.29/42 — FIX REPORT (owner test of 2.0.28/41, tvOS 27.2.1, Apple TV 4K A2843)

Owner approved this round 2026-11-18 ("Làm ngay"). Findings source: `~/memory/2026-11-18.md`,
"Test 2.0.28" sections. Five parallel clusters (A–E) + coordinator consolidation.
Per-cluster reports: `V2029-CLUSTER-A.md` … `V2029-CLUSTER-E.md` in this folder.
Presnap of every edited file: `~/workspace/dabanh-ios/backup-v2029-presnap/`
(full `JoeTV/` + `project.yml`, taken before any edit; local `project.yml` was verified
byte-identical to remote HEAD — blob `44ed5fed…` — before editing).

**Version:** JoeTV target only, BOTH pairs in `project.yml` — settings
MARKETING_VERSION/CURRENT_PROJECT_VERSION and info.properties
CFBundleShortVersionString/CFBundleVersion: 2.0.28/41 → **2.0.29/42**. Other targets untouched.

**Commits (repo `zjoenguyenz/dabanh-ios`, branch main):**
1. `297ab303cb978a4d4e757db62b6a2808d608f6d8` — items 1, 4 (+ item 6/7 call sites in those files): JoeMovieDetail.swift, JoeActorPage.swift
2. `dd2e360a6877158f80582476d93e9ba47a88399f` — items 2, 3 (+ item 6 director removals): JoePlayerView.swift, JoeKSPlayerView.swift
3. `b44e1c08da8de584d956e4f818731b7c6122fa77` — item 6: WatchStore.swift
4. `2a35029d89af0231cd2a8850027e7f37a4e5d5f0` — items 5, 8, 9, 7 (+ torrent halves of 1/6): JoeTheme.swift, JoeSearch.swift, JoeTorrent.swift, JoePhimHome.swift
5. `859ba08a2704ee14e5195440953b034123e8f975` — version bump: project.yml
6. This report — committed separately immediately after the code commits.

CI is dispatched by the parent agent after this push. **Nothing in this round is
compile-verified yet (no local Swift toolchain — CI is the first compile) and nothing is
device-verified until the owner retests.**

---

## Item 1 — Cast / focus system

Owner's words: "không có cái tô đậm hay cái đánh dấu gì hết… nói chung là không có focus";
focus "chạy tùm lum" on pages with cast (TVB worst); actor-page films cannot be selected.

**1a — Cast focus invisible (root cause code-proven).** `.joeCardButton()` (JoeTheme.swift:467)
suppresses the system focus effect centrally; every working surface's label reads
`\.isFocused` and paints its own ring — `castCell` never did (static stroke/text), so a
focused cast cell was pixel-identical to an unfocused one in Ultra/D/F. (Billboard worked
because `JoeActorNameLabel` does read focus — matching the owner's report.)
- Fix: new `JoeCastCellLabel` (JoeMovieDetail.swift:1619) on the PosterCard pattern —
  focused photo takes `theme.focus` at `theme.ringWidth`, name takes `theme.focusTitle`;
  every resting value byte-identical.
- Torrent half (coordinator, mirroring A): `torCastRow` (JoeTorrent.swift) had the identical
  construction; its cells now use the new `JoeTorCastCellLabel` (JoeTorrent.swift:1220),
  same treatment, resting values byte-identical.

**1b — Focus instability.** Two proven contributors: the invisible cast focus itself
("focus nowhere" = focus sitting invisibly on a cast cell), and the cast row standing in
**no `.focusSection()`** in D (JoeMovieDetail.swift:740) and F (:842) while every other
block declares one — both now sectioned. Plus the deterministic landing write of item 4.
Late cast insertion churn (cast merges in a staged `.task` after focus settles) is labelled
UNVERIFIED as a residual — mitigated by the section + visible cells, not provably eliminated.

**1c — Actor page (JoeActorPage.swift).** The page declared no focus landing at all (only
Quay lại focusable while loading; nothing steered focus to the films when the grid
inserted), its header was unsectioned, and credits that missed the load-time catalogue
match rendered as deliberately non-button plain rows — the list the owner couldn't press.
Fixes: header `.focusSection()` (:135); `landInitialFocus()` written at load (:490);
unmatched rows are now real buttons whose press resolves **ID-locked only**
(`resolveAndOpen` :353 — TMDB id must equal the credit's own id; a lookalike never opens).

## Item 2 — Player overlays hide with the bar (JoePlayerView.swift, JoeKSPlayerView.swift)

Root cause (code-proven): the shared SwiftUI `statusCapsule` rendered **unconditionally**
in `.playing`, and `PlayDirector.notice` was **never cleared anywhere** — so from the first
resume onward the capsule permanently showed the resume line; with no resume it permanently
showed `currentLabel`. For torrent candidates that label is the multi-line `TorStream.name`,
which carries BOTH the source name ("RD Plus") and the quality tokens ("4K DV") — there is
no separate badge view in either host. The bars hid correctly; the capsule stayed. All
torrent candidates are `.ffmpeg` (KS host); there is no AVPlayer torrent path.
- Fix: capsule opacity bound to the new shared state `PlayDirector.transportBarVisible`
  (JoePlayerView.swift:119; binding at :1062–1063), reported by both hosts (KS:
  show :785 / hide :845 / focus-resurrect :860 / picker-open :1276; AVPlayer: the fix-9
  delegate callback :1583 + `attach()` :1547). No new timers. When the bar hides, title
  line, source name, badge text and resume line hide with it; they return only with the bar.
- **Billboard single-source case (bar never hides + pause dead): UNVERIFIED.** The player
  code contains no theme branch, so "Billboard" is not the variable — the source is (a KS
  case). One code-provable aggravator was fixed: the hide timer previously retired
  permanently after a single not-playing veto; it now re-arms and retries
  (JoeKSPlayerView.swift:821–848). Best hypothesis (labelled): that file keeps the engine
  out of its playing state (e.g. stuck `.buffering`), which explains all three symptoms at
  once. Confirming it needs a diagnostic build logging `layer.state` at each veto/pause
  press — recommended as the next step if the retest still shows it; no pause-side code
  was changed on a guess.

## Item 3 — Đổi nguồn opens a chooser (manual selection is a hard owner constraint)

- New `PlayDirector.sourceChoices` (JoePlayerView.swift:781–801) — the session's live
  candidate ladder, read at every opening (post-hop ladders show correctly, current row
  marked) — and `userSwitchSource(to:)` (:815–830), switching through the standing
  `beginCandidate()` + itemReady resume rule, so **playback position is kept**.
- KS host: Đổi nguồn opens the "Chọn nguồn" list in the existing picker panel
  (`openSourceChooser`, JoeKSPlayerView.swift:1243; focus lands on the current source's
  row; multi-line stream names flattened with " · " for rows).
- AVPlayer host: the transport-menu Đổi nguồn entry is now a candidate submenu with the
  current source checked (JoePlayerView.swift:1663–1698). **UNVERIFIED:** whether AVKit
  renders a nested UIMenu inside `transportBarCustomMenuItems` as a true submenu on
  tvOS 27 cannot be verified from this VM; if it flattens/drops it, the fallback is flat
  per-source actions in the same menu (JoePlayerView-only change).
- Auto failover on a dead source is untouched. Stated plainly: Đổi nguồn at the ladder's
  last candidate no longer triggers the failover rungs by itself — the chooser lists the
  current ladder, per the item's definition; dead-source failover still reaches those
  rungs automatically.

## Item 4 — Detail pages missing controls

The "separate info-only variant" hypothesis was **refuted by code**: one `wallDetail`
serves movies and series; the owner's "Phí Phông" photo matches its header block
element-for-element. Real chain (code-proven): the play button is disabled when the loaded
detail carries no playable episode (TpClient.swift:240–243 / KkClient.swift:284 append a
server only when episodes are non-empty), and the page's only landing,
`.defaultFocus($focusedPlay)` (JoeMovieDetail.swift:305), then resolves to nothing — no
live focus, and a tvOS ScrollView scrolls by following focus, so the page freezes on its
header. The same shared machinery explains F/Nguồn and TVB-on-wall.
- Fix: `landInitialFocus(on:)` (JoeMovieDetail.swift:2060), written once at first paint
  (call sites :2159, :2176 and the no-cache paint) — Xem ngay when playable, otherwise the
  never-disabled Yêu thích — and never on provider switches, so a source switch never
  yanks focus. No layout or drawing value changed in any theme.
- UNVERIFIED: whether the owner's specific titles in fact loaded with empty `servers`
  depends on live provider payloads at test time; the chain above is the only code path
  found that produces the photographed state, and the page is now live-focusable and
  scrollable in both the empty-servers and normal cases.

## Item 5 — Poster frame cuts text on the wall theme (JoeTheme.swift)

Site (code + drawing proven): `PosterCard.railBody` — under posterWall the rail-form card's
text sits flush at the card edge (`.padding(.horizontal, theme.artInset)`, artInset = 0)
and the focus ring was an inset `strokeBorder` **overlay**, painting 6 pt of #FFD60A over
the first/last glyphs. The drawing's inset box-shadow paints above the fill but UNDER the
content. The TVB section (the reported surface) is built almost entirely of rail-form cards.
- Fix (JoeTheme.swift, railBody): the stroke moved onto the background face shape (ZStack:
  fill + same stroke), so it paints between fill and content — same values (rCard, resting
  1.5 `theme.stroke`, focused `theme.ringWidth`/`theme.focus`), no text padding added (the
  drawing's text is flush; padding it would deviate to hide a paint-order fault). One fix
  cures every rail-form surface (TVB rails, wall CW/Favourites/Following, Phim rails,
  franchise strip). `faceBody` (other themes pad text by artInset 10–16, clear of their
  4 pt ring — checked, clean) and `wallBody` (outset ring around the art only) are
  byte-identical to the presnap.

## Item 6 — Continue Watching keys by title+episode (WatchStore.swift + call sites)

Root cause (code-proven): provider keys `<prefix>|<slug>|<episode name>` vs torrent keys
`tor|<stream id>` share no component; the detail's Torrent chip opens a session the Phim
CW rails filter out (kind `torrent`), and the in-player failover hop re-keyed progress
wholesale — so ep 2 via Torrent was a different item from ep 1 via KKPhim.
- Fix (WatchStore.swift): the store computes a **canonical identity** — same film (shared
  IMDb/TMDB id, else normalized-title equality with the gated year tolerance of
  `Providers.sameFilm`) + episode number + season veto (`canonicalMatch` :209,
  `sameFilm` :193). `saveProgress` folds a save into its canonical twin (the provider
  reopen identity survives; the twin donates the identity fields it lacks); `reload()`
  coalesces twins already on disk (`coalesceProgress` :472) — **the owner's current list
  is repaired in place, no migration** (two new Entry fields imdbId/tmdbId decode
  tolerantly). New lookups: `progressFor(matching:)` :267, `progressForTitle(...)` :282,
  `removeProgress(matching:)` :349. Sports/live rows are never canonical-matched;
  favorites untouched.
- Call sites (coordinator, per cluster C §4.2/§4.3): JoeMovieDetail.swift:2582 (factory
  resume), :1758 / :1768 / :1978 (detail resume reads → `progressForTitle`), id stamps at
  makeDirector (:2580s) and hopIdentity (:2692s); JoeTorrent.swift:1374 (torrent factory
  resume); JoePlayerView.swift — the three finish removals (tick, itemEnded,
  skipToNextEpisode) → `removeProgress(matching:)`.
- Named limitation: a series found cold in the Torrent tab (Cinemeta's English title vs
  the provider's Vietnamese title) merges only if the provider entry carries a stamped
  IMDb/TMDB id — the stamps are now written, but KK payloads often lack the id.

## Item 7 — Wrong-title resolution ("Có máy thời gian" opened "Step Into The Past")

Faulty site (code-proven): the home trending rail's rung 2, `trendingSearchMatch`
(JoePhimHome.swift), accepted the first name-equal search result with **no TMDB-id, year
or type check** — a translated title is not an identity. Also the rung-1 catalogue map was
keyed by bare TMDB id although TMDB ids are per-type namespaces.
- Fix (JoePhimHome.swift): rung 2 accepts **only** a TMDB-id match with type agreement
  (:816) — an unmatched title drops off the rail rather than opening a lookalike (the
  franchise strip's ID-or-nothing discipline); the catalogue map is keyed `type|tmdbId`
  with typeless fallback, lookup typed-first (:768). Cluster A additionally tightened the
  actor-page catalogue map the same way (JoeActorPage.swift:517) and audited the franchise
  strip and all TVB rails as already ID-locked.

## Item 8 — Voice search removed (JoeSearch.swift)

Owner decision 2026-11-18 (Siri hijack). Removed entirely: the "Nói" button, the
`.fullScreenCover` voice sheet, `JoeVoiceSearchSheet`, `voiceOpen`/`voiceDraft` state,
`openVoiceSearch()`/`submitVoiceSearch()`, `JoeSearchKeyFocus.case voice`
(JoeSearch.swift 934 → 767 lines). Typed Netflix-style search is byte-for-byte untouched
per diff; a tree-wide grep confirms zero remaining voice symbols; project.yml carries no
speech/mic usage keys. JoeTVB.swift's own search never used the voice path (checked,
unedited). No Speech-framework substitute was added, per the decision.

## Item 9 — Torrent-screen theme design audit (JoeTorrent.swift)

Method: drawing/spec value vs app value, per detail. There is **no torrent-specific
drawing** in themes2; the governing contract is DESIGN-SPEC-V19 §7.4/§7.6 plus each
theme's shared-component values. The owner's photo of this defect **has not arrived** —
the three fixes below are the only deviations provable without it; none is claimed to be
the photographed defect.

| # | Detail | Drawing / spec value | App value (before) | File:line | Action |
|---|---|---|---|---|---|
| T1 | Torrent home rail card form (D) | design-D rails are `.card`; all app rail sites pass `form: .rail` | conformant | JoeTorrent.swift:218–224, 260–264, 427–431 | ✅ no change |
| T2 | Torrent search grid | §7.6: 6 columns, row gap 40; D outset ring needs edge clearance | 6 cols, row spacing 40, horizontal padding 8 under posterWall | JoeTorrent.swift:445–469 | ✅ no change |
| T3 | Detail header block | §7.4 via §7.6: poster 240×360; title 64; meta 29; overview 29 ≤5 lines | identical | JoeTorrent.swift:733–800 | ✅ no change |
| T4 | Detail poster frame | §7.4 r16 hairline; themes2 Phim details elaborate per theme | bare art, inset white 0.14/2 pt, no painted frame in any theme | JoeTorrent.swift:754–763 | UNVERIFIED — deliberate recorded construction; per-theme frame parity is a composition change, needs owner's photo/decision |
| T5 | Favourite button chrome | themes2 `.btn`: 29 semibold, padding 17×36, resting inset stroke 1.5, focused ring ringWidth (= JoeSecondaryLabel) | 29 **medium**, padding **16**×36, JoeFocusRing overlay (**no resting stroke**) | JoeTorrent.swift:821–826 (presnap) | **FIXED** (:820–837) |
| T6 | Episode-row selected state | `.chip.sel`: SOLID accent fill, onAccent text, semibold | accent at 30% opacity, resting text colour, bold | JoeTorrent.swift:898–907 (presnap) | **FIXED** (:904–939) |
| T7 | Episode-row ring, selected+D | owner's D ruling: selected+focused under posterWall wears opaque white frame (accent == focus in D) | JoeFocusRing always theme.focus — invisible on the solid D fill | JoeTorrent.swift:907 (presnap) | **FIXED** with T6 (mirrors epChip's rule incl. white branch) |
| T8 | Cast character wrap | mirrored Phim cast cell: lineLimit **2** | lineLimit **1** | JoeTorrent.swift:1195 (presnap) | **FIXED** (lineLimit 2; now in JoeTorCastCellLabel) |
| T9 | Cast row focus | — (item 1's territory) | no `.focused` binding, constant stroke only | JoeTorrent.swift torCastRow | **FIXED under item 1** (JoeTorCastCellLabel) |
| T10 | "Chưa có nguồn phát" on Billboard torrent detail | — (functional state) | empty-state line when the pooled fetch returns nothing | JoeTorrent.swift streamSection | noted — data state, not a design deviation |
| T11 | Detail composition per theme | themes2 details differ per theme for PHIM; §7.6 requires only §7.4 metrics for torrent | one standard hero for A/D/F; Ultra has its own composition | JoeTorrent.swift:580–731 | UNVERIFIED — §7.6 satisfied; whether the photo shows this gap needs the photo |
| T12 | Ultra backdrop full-bleed | owner verdict 2.0.22/23: edge-to-edge | `.ignoresSafeArea()` present (owner-confirmed fixed in 2.0.23) | JoeTorrent.swift ultraTorBackdrop | ✅ no change |
| T13 | Ultra panel stream rows | spec + language lines under the label | present | JoeTorrent.swift streamRow | ✅ no change |
| T14 | Stream rows | §7.6: height 64, label 29, outline-only focus | label 29 ✓, outline-only focus ✓; height content-driven (>64) due to the release-title line the owner picks by | JoeTorrent.swift streamRow | deviation noted, UNVERIFIED/no change — removing the title line would delete owner-facing source data |
| T15 | Home header | §7.6 "mirrors Phim chrome" (Phim slim header 44 heavy) | 56 heavy + 25 subtitle — also the TV section's and Settings' size, house practice mixed | JoeTorrent.swift:152 | UNVERIFIED — no single governing value; not changed without the photo |
| T16 | tvOS 27 / Liquid Glass posture | APPLE-CONFORMANCE: no system glass over drawn focus; glass adoption = owner decision P3 | all torrent focusables use the central `.joeCardButton()`; no standard glass chrome on these surfaces | JoeTorrent.swift throughout | ✅ conformant with the app's established posture; P3 remains the owner's open decision |
| T17 | ViSub status capsule | app-internal (cf. providerChip 25 semibold) | 25 regular, white-0.10 fill | JoeTorrent.swift hero | minor mirror drift noted; not a drawing value, not changed |

---

## Honesty declaration

**Claims (code-evidence):** item 1a's invisible-focus mechanism and its fix on both cast
rows; item 1b's two proven contributors; item 1c's three causes; item 2's capsule
mechanism (unconditional render + never-cleared notice; badge/source text ride the
capsule's label); item 3's chooser wiring through the standing resume machinery; item 4's
disabled-play / no-landing / no-scroll chain; item 5's paint-order mechanism (code +
design-D stylesheet); item 6's key-family split and the canonical-identity repair; item 7's
rung-2 acceptance flaw; item 8's complete removal (grep-verified); item 9's three
value-exact fixes. Every changed file was diffed against the presnap by its cluster and
re-checked by the coordinator; the changed-file set is exactly the 10 files in the commits
above (JoeTVB.swift, JoeBrowse.swift, JoeStores.swift audited, untouched).

**Evidence:** the five cluster reports (full file reads, greps, presnap diffs, delimiter
balance 0/0/0 on every edited file); the owner's item-4 photo read directly (wallDetail
header, element-for-element); TpClient.swift:240–243 / KkClient.swift:284 server-append
rule; TorrentClient engine stamps (all torrent candidates `.ffmpeg`).

**UNVERIFIED, labelled:** (1) No local compiler exists — CI is the first compile; all new
Swift mirrors existing compiled shapes in the same files, but syntax/API slips are only
excluded by CI. (2) Nothing is device-verified; the owner's retest on tvOS 27.2.1 is the
proof gate for every item. (3) Item 2's Billboard single-source root cause (engine-state
hypothesis; only the no-rearm aggravator was fixed) and the AVKit nested-submenu rendering
(item 3). (4) Item 4's empty-servers state for the owner's specific titles (depends on live
provider payloads). (5) Item 1b's insertion-churn residual. (6) Item 9 rows T4/T11/T14/T15
and the identity of the photographed defect — the owner's photo is still outstanding.
(7) Item 6's cold-Torrent-tab title-mismatch case (named limitation above). (8) If a
standalone "4K DV" element remains on the owner's TV after item 2's fix, the remaining
candidate is the television's own display-mode banner (TV-rendered on AVDisplayManager
mode switch, not app-rendered) — distinguishable only on his screen.
