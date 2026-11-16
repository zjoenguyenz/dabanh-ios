# Joe TV tvOS v2.0.1 (14) — port of the Sony-proven Android v2.3 change set

Team TVOS-V201-PORT. Method: the four Android sections
(§ANDROID-V23-BACKDROP-FIX, §ANDROID-V23-BACKDROP-FIX2,
§ANDROID-V23-SEARCH-SPEED, §ANDROID-V23-FIX4 in
`~/workspace/tv-build/V23-REPORT.md`) were read first; each
item below was then AUDITED in the tvOS code — where the
behaviour already existed it is proven and untouched, where
the defect class existed it is fixed the tvOS-native way.
No Java was transliterated; no theme was copy-pasted across
platforms. Version is 2.0.1 / build 14 in project.yml
(CFBundleShortVersionString / CFBundleVersion set literally
in the JoeTV target's info properties, house rule).

**Navigation chrome: UNCHANGED — the app keeps its current
left rail.** Design decision B1 (design topbar vs left rail)
is still the owner's to make; nothing in this port rebuilds
navigation.

## Item-by-item audit

### 1. Detail payload disk cache — ABSENT → built
No detail cache existed: every open fetched, and a slow KK
round held the whole page behind the placeholder header.
Built `JoeDetailCache` (new file, registered in
project.yml): one JSON file per film in
`Caches/detailcache/`, key MD5 of `provider|slug`, envelope
{v: app build, t: saved-at, d: Detail} — version mismatch is
a miss, TTL 24 h, prune oldest-first to ~8 MB on write,
fail-soft throughout (the Android DetailCache semantics,
expressed with Codable + CryptoKit). Movie / Episode /
Server / Detail gained synthesized `Codable` (additive).
`JoeMovieDetail.load()` integration is FIRST-OPEN ONLY, to
keep the C-9 switch/revert logic byte-identical: a hit
paints the full detail immediately, the fresh fetch runs as
a background refresh, repaint happens only when
`JoeDetailCache.fingerprint` differs (movie fields, content,
metaLine, categories, server names, episode NAMES — stream
URLs excluded, the Android samePayload rule), and a failed
refresh keeps the cache-filled screen with no error surface
(alternatives still run). Nothing stale can reach the
player: the play ladder re-fetches the detail fresh at tap
time (standing rule), so the cache only ever paints.

### 2. Backdrop pipeline — PARTIAL → completed
Already present: full-resolution decode (the pipeline's
ImageIO thumbnail decode at the requested bucket; the band
requests 1920 — the Android half-res decode defect never
existed here) and the TMDB w1280 URL (TMDBClient).
Defects found and fixed:
- **Centred crop cut faces** (Android defect D2, present
  verbatim): the band painted the 16:9 thumb / TMDB frame
  with the pipeline's centred fill inside the 430-tall
  4.47:1 band, keeping only the centre slice. New
  `JoeBandImage` (JoeImagePipeline.swift): landscape art is
  a **top-anchored slice** — cover-scaled, window starting
  at the anchor fraction of the overflow (0.16 detail band,
  0.20 hero — the Android sliceForBand anchors).
- **Portrait-only art had no band at all**: F4K / TP
  payloads never set `Movie.thumb` (grep: only KkClient and
  VsClient write `.thumb`), so those films' bands waited on
  TMDB or stayed hidden. `JoeBandImage` .treatment mode:
  blurred darkened full-bleed field + the WHOLE poster fit
  to exactly the band height, under the fade (the Android
  FIX2 composite z-order) — nothing cropped, nothing
  stretched.
- **Fade stops now the design's literal stops.** The band
  previously used the UI-3 scrim-floor approximation
  (clear @0.35 / 0.55 @0.60 / bg @1). It now renders
  design-A/detail.html `.fade` verbatim —
  `linear-gradient(0deg,#0A0A0A 5%,rgba(10,10,10,.25) 60%,rgba(10,10,10,.45))`,
  read top→bottom as theme.bg @0.45 / @0.25 @0.40 / solid
  @0.95 / solid @1 (verified against the render file this
  round; theme A's bg IS #0A0A0A) — the same stops the
  Android build ships.
- The home hero (JoePhimHome) had the same centred-fill
  class: it now paints through JoeBandImage (anchor 0.20;
  a poster-only feature gets the blurred field, no copy —
  the hero's text block owns its foreground). Its scrims
  are untouched.

### 3. Instant first paint of the band — ABSENT → built
The band waited for the thumb / TMDB network images; the
placeholder header had no band at all. Now: (a) the
pipeline gained `cachedImageAnySize` — a synchronous
decoded-cache read at any bucket (the Android FIX4 peek);
the tapped card has already decoded the poster, so the
band's poster-treatment stage paints on the view's first
render, and the layer's own full-size load upgrades the
bitmap exactly once; (b) the Billboard placeholder header
carries the same band + −168 overlap composition as the
loaded detail (fed from the route's poster), so the page
does not change shape when the detail lands. Stage
discipline is structural: poster treatment (bottom) →
thumb slice → TMDB slice (top) — a later stage can only
cover, never be covered by, an earlier one, and nothing
paints over the TMDB final.

### 4. TMDB decoupled — PRESENT, one serialisation removed
The enrichment already ran in its own `.task` and the
detail never waited on it. But backdrop + overview only
published after the CREDITS call also returned (one fused
`TMDBClient.fetch`). Split into `fetchInfo` (detail call:
backdrop + overview) and `fetchCast` (credits); the view's
TMDB task publishes stage 1, then merges the cast. Added
`TMDBClient.searchBackdrop` (Android parity): when the
payload carries no TMDB id, or the record has no backdrop,
a /search/multi hunt (origin name first, Vietnamese
fallback; backdrop required; normalized-title match
against either name; year must match when both are known)
supplies the w1280 backdrop. TMDBKey.swift untouched —
bundled value still EMPTY, key still injected from the
Actions secret.

### 5. Search robustness — PARTIAL → completed
Already present: the three honest surfaces (searching /
all-providers-failed with Retry / true no-match) and —
by absence of any cache — a failed round could never be
replayed as a zero. Absent and now built (with item 6, one
engine): **progressive per-provider merge + render** (the
pre-fix round awaited all four branches before rendering
anything) and **per-branch + first-paint timing logs**
(JOESEARCH lines in the house signpost log, LoadSignpost —
the tvOS equivalent of the Android logcat tag). The FIX2
bookkeeping rule is enforced by the new snapshot cache:
only rounds with zero failed branches are snapshotted; an
all-failed round sets the failure surface and is never
cached, so a re-press re-queries.

### 6. Search speed — ABSENT → built
New engine in JoeSearch.swift + `JoeSearchSession`
(lock-guarded session state, the Providers.altCache
pattern — the view is recreated per open, the memory is
not):
- **Local-first title pool** (cap 6000, first copy wins,
  precomputed normalized keys): fed at every press from
  everything already downloaded (PhimStore's merged rails,
  type lists, chiếu rạp, Vietnam block, genre + country
  lists) and from each branch's results as they land.
  Local hits render synchronously at the press.
- **Exact-match tier**: normalized name/origin EQUAL to
  the query fronts the grid in arrival order; all other
  cards keep pool order and never move within their tier.
  The server pool renders grouped in the shipped provider
  priority order (KK, F4K, VS, TP — the v2.0.0 grid order
  is preserved; progressive landings append per group).
- **Session snapshot cache**: 12-entry LRU keyed by the
  executed name; a clean round replays with zero network.
- **Not gated on dataset load**: already true and kept —
  the local pass reads whatever the store holds at press
  time (possibly nothing) and the branches carry the
  round. (Divergence from Android, labelled: no
  re-execution when the dataset lands mid-round; the next
  press sees the fuller pool.)
- **Soft deadline 2.5 s**: `searching` (the visible
  settle) flips off at 2.5 s or the last branch, whichever
  first; branches keep merging until the **15 s hard
  budget**, where stragglers are cut and counted failed.
  An empty grid with branches still out keeps the
  "Đang tìm…" surface — never the no-match line.

### 7. Alternatives in every theme — NO DEFECT FOUND
The Android FIX4 bug (a merge post guarded by a view
reference one theme never creates) has no tvOS equivalent:
`alternatives` is a single @State on JoeMovieDetail,
populated unconditionally in load()'s success path, and
all three renderers iterate the same state — A's
`sourceChips`, D's `altChips`, F's `sourceRows` each render
Tự động + current + one entry per alternative (+ the
Torrent status element). No per-theme guard exists that
could discard the merge. No change made.

### 8. Verify, don't regress — one premise corrected
- **Source-priority policy: PRESENT, verified in code.**
  `autoSource` defaults to Tự động (per-session, never
  persisted); Tự động leads in all three themes; tapping a
  specific source pins it; `play()` probes the torrent rung
  FIRST for Auto + US-theatrical (`isUSTheatrical`: Âu Mỹ
  bucket + chieurap flag or single-class type;
  high-quality releases only); the failover hop iterates
  alternatives in priority order. Untouched by this port.
  Note: the tvOS provider priority is KK > F4K > VS > TP
  (Providers.swift, shipped and device-proven since
  v1.9.2) — it differs from the Android order in the task
  brief (KK → VS → F4K → TP); that is pre-existing data-
  layer behaviour, out of this port's scope, NOT changed.
- **Facets re-apply at render: HOLDS.** JoeBrowseFilter is
  a pure function over PhimStore data; facet changes never
  touch the network. JoeBrowse.swift is untouched and the
  pre-build predicate test still passes (see Verification).
- **"Unified search screen (name may be empty + six
  facets)": NOT PRESENT on tvOS — flagged, not silently
  rebuilt.** In v2.0.0 the name search (JoeSearchView: name
  required, Tìm disabled for an empty field) and the facet
  browse (JoeBrowseView: six facets, no name field) are
  two separate layers, as shipped and reviewed. Items 5/6
  were therefore ported into the name search (the tvOS
  surface the Android BrowseActivity search half
  corresponds to), and the facet half's render-time
  behaviour is verified above. Merging the two layers into
  one screen is a UX/navigation rebuild outside this
  port's item set and hard rules; it is the leader's /
  owner's call, recorded here rather than improvised.

## Files changed
- `project.yml` — JoeTV 2.0.0 (13) → 2.0.1 (14) (settings +
  literal info properties); JoeDetailCache.swift added to
  the JoeTV sources.
- `JoeTV/JoeDetailCache.swift` — NEW (item 1).
- `JoeTV/JoeModels.swift` — Codable on Movie / Episode /
  Server / Detail (additive).
- `JoeTV/JoeImagePipeline.swift` — `cachedImageAnySize`;
  new `JoeBandImage` (items 2, 3). No existing method's
  behaviour changed.
- `JoeTV/JoeMovieDetail.swift` — band refactor (stages,
  design fade, bandVisible), Billboard placeholder band,
  load() cache flow, two-stage TMDB task (items 1–4).
- `JoeTV/TMDBClient.swift` — fetch split into fetchInfo /
  fetchCast; searchBackdrop added (item 4). `fetch` had
  exactly one caller (the detail task), now updated.
- `JoeTV/JoePhimHome.swift` — hero paints via JoeBandImage
  (item 2). One call site; scrims untouched.
- `JoeTV/JoeSearch.swift` — the item 5/6 engine: local
  pool, progressive merge, exact tier, snapshot cache,
  soft/hard settles, JOESEARCH signposts, JoeSearchSession.
  Body structure, focus architecture (defaultFocus,
  resultMove, traps-free convergence shape), the three
  surfaces and the D-19 heading are preserved.
- `JoeTV/V201-PORT-REPORT.md` — this report.

Push set for the leader: `push-paths-v201.bin`
(NUL-delimited, trailing NUL — the house convention).

## Verification performed (this machine)
- Convergence greps over JoeTV/*.swift: `.scaleEffect(`,
  `.focusEffectDisabled(`, `AsyncImage` — ZERO code hits
  before and after (the only matches are four pre-existing
  comment mentions, unchanged). No focus-driven conditional
  modifiers or key traps were added; every new view is
  structure-stable (band layers are unconditional siblings
  whose CONTENT depends on load state, never on focus).
- `ui-redesign/filter-predicate-test.py`: **ALL CHECKS
  PASSED** (facet predicates untouched).
- Stale-reference sweep: no remaining references to
  `hasBackdrop`, `TMDBClient.fetch(`, or the old band call.
- Brace / paren / bracket balance neutral in every changed
  file; every changed region re-read in full after editing.
- TMDBKey.swift untouched; bundled key value still EMPTY.
- PhimStore environment injection for the search view
  confirmed (JoeTVApp injects it at the root; the search
  view's only call site is inside JoePhimHome).

## Honesty declaration
**Claims:** each item verdict above is tied to code read
this round (file + function named) or to a command run
this round (greps, the predicate test, the design render's
CSS). The item-8 correction is stated against the shipped
v2.0.0 sources, not against the brief's premise.
**Evidence:** the Android report sections cited; tvOS
sources as read this round; design-A/detail.html line 78
(the .fade stops) and line 76 (430px band).
**Unverified — labelled:**
- **No compile was possible on this VM** (no Swift /
  Xcode / XcodeGen toolchain exists here). The code was
  written against the codebase's own idioms and re-read
  line by line, but the first real type-check is the
  leader's Actions build. Expect the usual chance of a
  small compile fix round.
- **Everything device-facing is unverified**: band
  rendering and stage timing, cache paint/refresh feel
  (including whether a changed-payload repaint mid-read is
  noticeable), search timings, and focus behaviour around
  the progressively merging grid all await the owner's
  Apple TV — the standing tvOS caveat applies in full.
- The TMDB title-search acceptance rules are the Android
  rules re-expressed; whether TMDB's /search/multi returns
  the same shapes for the owner's catalogue can only be
  proven on device (the signpost + the band's behaviour
  will show it).
- JoeBandImage's blurred field uses a fixed 28 pt blur +
  35% darken for the Android boxBlur treatment; the exact
  on-screen match to the Sony's rendering is a device
  judgement, not a claim.
