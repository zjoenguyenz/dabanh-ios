# TEAM TVOS-HERO-FORENSICS — Report

**Date:** 2026-11-15 (America/Chicago) · **Scope:** tvOS Joe TV (`~/workspace/dabanh-ios/JoeTV/`), Phim-home hero / backdrop breakage reported by the owner ("hầu như hư hết") with four evidence photos (uploaded 2026-11-15 20:20 CST), plus the owner's 20:30 update that the breakage appears in **all three themes (A, D, F)**.
**Film in every photo:** "Yêu Là Tàn Nhẫn" / "Love Me to Hurt Me" (KKPhim, 2026, Thái Lan), slug `yeu-la-tan-nhan`.

**Build attribution caveat (read first):** the photos **cannot** establish whether the device ran v2.0.0 (13) or v2.0.1 (14), because the corner version label was hardcoded `Joe TV v2.0.0` in both builds (defect #4 below, fixed in this round). Photo→build attribution in §C is therefore geometric inference, labelled as such. Every defect below is attributed to v2.0.0 source, v2.0.1 source, or both, from the current source plus the v2.0.1 port report's diff description (no local git history).

---

## 0. Theme split (owner update, 20:30 CST)

The owner reports the breakage in all three themes. The forensics agree with him: **every proven mechanism lives in shared code**, not in any theme's layout.

**(i) Shared-layer defects — hit all themes:**

1. **Image selection** — the provider *list thumb* is the only pre-TMDB art source for both the home hero (theme A) and the detail band's stage 2 (all themes). For composite thumbs the art is wrong before any cropping question arises (§A).
2. **JoeImagePipeline has no retry** — one failed request = a permanently empty card/stage for that view's life. Rails and the band are shared components, so the misses appear in every theme (§D).
3. **The hero had no stand-in stage** — the v2.0.1 port gave the *detail band* a cached-poster first stage but left the *home hero* as a single layer whose URL is decoded nowhere else, so a failed hero load shows a void (§B, §C photo 4). The component (`JoeBandImage`) and the usage pattern are shared; only the omission was hero-specific.
4. **Hardcoded version label** — theme-independent chrome (top bar) plus the Settings footer (§E).

**(ii) Theme-specific residue:** **none found** for the hero/backdrop defect class. Notes: themes D/F have no home hero by design (`slimHeader`) — their exposure is the detail band + rails, both shared. Theme A's hero frame (668 pt) is taller than the detail band (430 pt), so the same slice logic crops a thinner window there — a parameter difference inside shared code, not a theme defect. Per-theme scrims/tokens differ but neither cause nor mask any defect found.

---

## A. Hero image selection (Phim home)

**Trace** (`JoePhimHome.swift`, pre-fix source):

- `heroMovie` = the first thumb-bearing movie across `railSpecs.flatMap { $0.movies }` (the merged "Tổng hợp" rail is first in `railSpecs`), falling back to the first movie overall.
- The hero painted **exactly one URL**: `featured.thumbURL ?? featured.posterURL` at bucket 1920.
- `heroDetail` (`.task(id: featured.id)` → `Providers.detail`) fed **only text** — synopsis, meta fallbacks, genres. **The home hero never consulted TMDB and never upgraded its art.** (The detail screen does both; the home hero did neither — the port's asymmetry.)
- Non-Billboard themes render no hero at all (`slimHeader`).

**This film's actual payload** (fetched live from `phimapi.com` this round; list and detail payloads carry *identical* image URLs):

| Field | Value |
|---|---|
| `thumb_url` | `https://phimimg.com/uploads/movies/20261115/yeu-la-tan-nhan-thumb.webp` |
| `poster_url` | `https://phimimg.com/uploads/movies/20261115/yeu-la-tan-nhan-poster.webp` |
| `tmdb` | `{id: "330168", type: "tv", season: 1}` |
| `imdb` | `{id: "tt47712459"}` |

**The images themselves** (downloaded and viewed this round):

- **Thumb: 780×438.** A single 16:9 **marketing composite**: the two actresses' faces on the left (~5–55% of width), dark red curtain, and the film's **"Love Me to Hurt Me" script logo baked into the right side** (~57–97% of width, ~42–75% of height).
- **Poster: 500×750** portrait — both actresses full-frame on red/pink, small logo at the bottom.

**Consequence:** the hero's only art source is a 780×438 logo-baked composite. Upscaled 2.46× into a 1920×668 frame it is soft to begin with, and *no* 2.87:1 window of it reads as a backdrop: a top window is a tight face close-up with a logo sliver; a centre window is cut faces plus the logo; a bottom window is the logo alone. **The defect is source selection, not cropping.** Cropping is only what made each build's failure look different (§C).

## B. Hero rendering

**v2.0.1 (current source, pre-fix):** `JoeBandImage(url: thumb ?? poster, targetPixels: 1920, anchor: 0.20, portraitMode: .blurField)` in a **1920×668** frame (aspect ≈ 2.87:1). For this thumb: cover-scale = 1920/780 = 2.46 → 1920×1078, vertical overflow 410 pt, top-anchored window at anchor 0.20 → **source rows 33–305** are shown.

**v2.0.0 (from the port report's diff description):** the hero painted through the old centred-fill path (`JoeRemoteImage` scaledToFill) → window = **source rows 104–372** (centred).

**Is the pre-port centred-fill path still reachable in v2.0.1 source?** No — not for any band/hero surface. The detail band (`JoeMovieDetail.swift:760–790`) is three `JoeBandImage` stages (poster treatment → thumb slice → TMDB slice, anchor 0.16, 430 pt tall); the home hero was the single `JoeBandImage` above. `JoeRemoteImage`'s fill mode survives only in non-band spots (the detail header's 2:3 poster frame, cast-photo circles), where fill is geometrically harmless. Themes D/F have no hero variant to reach it through, and the heroDetail/TMDB path paints nothing on the home hero (pre-fix it fed text only).

**Frame-height note:** the hero frame (668) is much taller than the detail band (430) the anchor was tuned on. The same anchor over the taller frame takes a *thinner relative slice* of the source (272 of 438 rows ≈ 62% at anchor 0.20 in hero geometry), which is why the hero's crop looks more aggressive than the band's for the same film.

## C. Photo → code-path mapping

One image explains photos 1–3; the fourth is the same image never arriving. There is **no** TMDB-upgrade race on the home hero (pre-fix, no TMDB path exists there) and no list-thumb→detail-thumb switch (list and detail payloads carry identical URLs for this film — verified in §A).

- **Photo 1** (`D890FBBA…`, logo art filling the hero): the **v2.0.0 centred fill** of the thumb, photographed from the TV's right side. Only the screen's right region is in frame — that region is the composite's logo (source x 57–97%); the faces (x 5–55%) and the text block fall left of the photo's frame. The lettering sits *vertically centred with curtain below it*, which matches the centred window (rows 104–372 contain the full logo band, rows ~185–330) and **not** the v2.0.1 slice window (rows 33–305 would cut the logo's lower flourish and park it at the hero's bottom edge). *Label: strong geometric inference.*
- **Photos 2 & 3** (`6E16FB6D…`, `B515B0EA…`, face close-up + logo sliver at the right edge): the **v2.0.1 top-anchored slice**. The standing actress's head is complete to the top of the frame — the slice window (from row 33) keeps it; the centred window (from row 104) would clip it. The lettering sliver at the right edge is the logo's upper portion (source rows 185–305) landing in the hero's lower-right, exactly where the slice window puts it. The "faces cut at the right edge" is the camera's crop, not the screen's. *Label: strong geometric inference.*
- **Photo 4** (`890174E1…`, wide shot, hero completely dark while title/meta/synopsis render): the hero's single image load **never painted a bitmap** on that pass. The text proves `heroDetail` landed; the art is a separate load with **no retry and no fallback**: `cachedImageAnySize` (v2.0.1) can only reuse a decode of the *same* URL, and nothing else in the app ever decodes the thumb URL (rail cards decode *posters* — a different URL), so one failed or stalled request = an empty hero for that view's entire life. Whether that instance was a hard failure or a still-in-flight load is **not determinable from the photo**; the code defect is proven either way. *Label: mechanism proven; instance cause unverifiable.*

**So the owner's "hầu như hư hết" spans both builds:** v2.0.0 showed the composite's logo window; v2.0.1 showed its face window. The port fixed the crop anchor; it did not fix the source. Both builds were broken for any film whose KK thumb is a composite — a common KK pattern for Thai/Asian series.

## D. Rail poster misses (photo 4: cards 3, 4, 6 empty; 1, 2, 5, 7 loaded)

**What cards load:** `PosterCard` (`JoeTheme.swift:332`) loads `posterURL` at bucket 720, `fit: true`, in a 2:3 frame; the placeholder is an "film" SF symbol on `Color.black.opacity(0.45)` — the blue-grey empty cards in the photo. Rails are `LazyHStack` (`JoeTheme.swift:487`): off-screen cards are destroyed and recreated, and recreation re-runs the load — the only "retry" that exists anywhere in the image path.

**Pipeline facts** (`JoeImagePipeline.swift`): dedicated `URLSession`, `httpMaximumConnectionsPerHost = 8`, `URLCache.shared` + `.returnCacheDataElseLoad`, ~120 MB decoded `NSCache`, buckets [240…1920], in-flight dedupe per (URL, bucket) — and **no retry anywhere**: any error, non-2xx, or decode failure returns `nil` and the view sits on its placeholder until it is recreated. On top of that, `JoeStores.applyRail` **prefetches every landed rail's poster URLs** (bucket 720, unbounded detached background tasks), so at home-screen entry hundreds of requests compete for the same 8 per-host connections as the visible cards and the hero.

**The URLs are not dead:** this round, the current merged rail's first seven poster URLs were fetched from the VM — **all HTTP 200** (35 KB–978 KB; the CDN ignores the bucket resize, so "720" posters can be ~1 MB downloads — slow and timeout-prone under contention).

**Reading of the pattern:** non-adjacent empties (3, 4, 6) among loaded neighbours on the *same host* fits **per-request failures/timeouts under contention**, not FIFO starvation (which would empty the tail) and not a host outage (neighbours loaded). The exact per-request error on the owner's device (timeout vs 429 vs reset) is **not observable from the VM** — labelled unverifiable; the mechanism class (transient failure fossilised by a no-retry pipeline) is proven by the code plus the live-URL check.

**Version attribution:** the pipeline dates from UI-5 (v2.0.0). v2.0.1 changed only the additive `cachedImageAnySize` read + `JoeBandImage` + the hero call site. **The defect exists in both builds; v2.0.1 neither caused it nor fixed it.** (`cachedImageAnySize` does help a card whose poster the prefetch already decoded — evidently not enough on the owner's pass.)

## E. Version label — FIXED in this round

- `JoeTVApp.swift:278` rendered hardcoded `Text("Joe TV v2.0.0")` — present in the v2.0.1 source, i.e. the label lied on the very build the owner was testing. **Fixed:** `JoeRootView.appVersion` now reads `CFBundleShortVersionString` from the bundle (stamped from `project.yml` at build time) and the corner label renders `Joe TV v\(Self.appVersion)`.
- **Second instance found and fixed:** the Settings footer (`JoeSettings.swift:121`) carried the same hardcoded string → now renders `Joe TV v\(JoeRootView.appVersion)`.
- Remaining "v2.0.x" strings in the codebase are comments/file headers, not rendered labels (grep-verified). The label can no longer drift from the shipped build.

## Hero fix — SHIPPED in this round (mechanism proven in §A–§C)

`JoePhimHome.swift` only; data layer and provider behaviour untouched; no focus-driven conditional structure (the layers are unconditional siblings keyed on content state — the detail band's own shipped discipline); scrims and text block untouched.

1. **Three-stage hero stack** replacing the single layer, each stage painting when its bitmap lands, higher covering lower:
   - **Stage 1 — poster blurred field** (stand-in): the bitmap the rail card already decoded, so the hero never sits black while a usable image is on the device (the Android FIX4 lesson the port applied to the detail band but not the hero — this closes photo 4's failure mode for the hero).
   - **Stage 2 — provider thumb slice** (the v2.0.1 art, kept as fallback; skipped when it is the same URL as the poster, which stage 1 already paints).
   - **Stage 3 — the film's TMDB w1280 backdrop** (primary art, per the owner's backdrop standard).
2. **Backdrop resolution in the hero task** (`.task(id: featured.id)`, after the existing detail fetch): `TMDBClient.fetchInfo(tmdbId:type:)` when the featured film carries a TMDB id (detail's movie first, list item behind it — KK parses the `tmdb` object in both), else `TMDBClient.searchBackdrop(name:origin:year:)` — the detail screen's exact pattern, fail-soft end to end.

**Labelled limits of the fix:** (a) TMDB's backdrop *composition* for this series (tv 330168) could not be verified from the VM — the bundled key in the local source is empty (the real key is injected from the Actions secret at build time) and TMDB's web page is JS-rendered. If TMDB's backdrop for a title is the same composite KK derived its thumb from, the gain for that title is resolution (1280 vs 780 wide) rather than composition; the structural defect — the hero had *no* backdrop source at all — is fixed regardless. (b) The edited Swift was not compiled locally (no Xcode on the VM): brace/paren balance checked, convergence greps re-run (below); the leader's CI build is the compile gate, and the owner's device remains the first real run.

## F. IMDb-identity audit — tvOS F4K/VS (report only, NOT fixed)

The Android FIX5 gap (F4K/VS records lacking identity → no Torrent chip, no US-theatrical torrent-first) **exists on tvOS too, in a softer shape**:

**Parser table** (source reads this round; `Movie` has `imdbId`/`tmdbId`/`tmdbType`/`tmdbSeason`, `JoeModels.swift:45–48`):

| Client | Parses `tmdb` | Parses `imdb` | Notes |
|---|---|---|---|
| KkClient | ✅ (id/type/season, list + detail) | ❌ | The payload's own `imdb {id}` (e.g. `tt47712459` for this film) is never read — `movie.imdbId` is always `""` from KK. |
| VsClient | ❌ | ❌ | Payloads are KK-shaped (its own comment says so); Android FIX5 live-measured a VS Die Hard detail carrying `tmdb {id "562"}` + `imdb {id "tt0095016"}` — tvOS leaves both on the floor. |
| F4kClient | ❌ | ❌ | `parseMovie` (F4kClient.swift:209–241) sets no identity fields; Android FIX5 live-measured F4K payloads carrying a flat `tmdbId` (Die Hard: 562) — tvOS doesn't read it. F4K also never sets `.thumb` (poster only, TMDB w500 URLs). |
| TpClient | — | ✅ (`TpClient.swift:137`) | The only client that populates `imdbId`. |

**Consumption** (`torrentFallbackCandidates`, `JoeMovieDetail.swift:1296–1333`): `imdbId` → else `tmdbId` → TMDB `external_ids` conversion; if `tmdbId` is also empty, a rescue leg hunts the KK alternative's detail and takes its `tmdbId` (works) and its `imdbId` (**dead leg** — always `""`, since KkClient never parses `imdb`).

**How the tvOS symptom differs from Android:** the detail's Torrent row/chip is gated **only** on `TorrentSettings.isConfigured` (`JoeMovieDetail.swift:469–472`, `653–654`), so the row *shows*; what silently fails is the rung itself (returns `[]` → no torrent streams, no substitution). `isUSTheatrical` (`:1141–1152`) is provider-independent (Âu Mỹ country bucket + `chieurap`/single-type): it **fires** for F4K US movies (country parsed, type `single`) and for VS (country + `chieurap` parsed) — the torrent-first probe runs, but its rung starves on identity unless the alt-KK rescue lands. **Films whose only copy is VS or F4K (no KK alternative) get no torrent identity at all.** KK-opened films work but pay an extra TMDB `external_ids` round trip because their own payload's IMDb id is never read.

**Verdict:** same gap class as Android FIX5, partially masked by the play-time rescue ladder. **Not fixed in this round** (per brief). Recommended fix (proposal P2 below): mirror Android FIX5's parser changes.

## Per-defect version attribution

| # | Defect | v2.0.0 | v2.0.1 | Status |
|---|---|---|---|---|
| 1 | Hero art = KK list thumb only (logo-baked composite as sole source) | ✅ centred fill | ✅ top slice | **Fixed this round** (TMDB stage 3 + resolution task) |
| 2 | Empty hero: single load, no retry, no stand-in stage | ✅ | ✅ | **Fixed this round** for the hero (poster-field stage 1); pipeline retry remains P1 |
| 3 | Rail poster misses: no-retry pipeline + unbounded prefetch contention | ✅ | ✅ | Open — proposal P1 |
| 4 | Hardcoded version label (top bar + Settings footer) | ✅ | ✅ | **Fixed this round** (§E) |
| 5 | F4K/VS identity gap → torrent rung starves | ✅ | ✅ | Open — reported (§F), proposal P2 |

## Proposals (NOT shipped)

- **P1 — pipeline resilience:** bounded retry inside `JoeImagePipeline.load` (e.g. 2 retries with backoff, on error/timeout/5xx/429 only) and a concurrency cap on `JoeStores.applyRail` prefetch (the `AsyncGate` pattern already used for API jobs). Addresses defect #3 at the shared layer, all themes.
- **P2 — identity parsing (mirror Android FIX5):** KkClient parse the payload `imdb` object; VsClient parse `tmdb` + `imdb`; F4kClient parse the flat `tmdbId`. Parser-only changes; no provider behaviour change.
- **P3 — observation for the owner:** if the TMDB slice still crops harder than he likes in the 668-tall hero (vs the 430 band), the anchor is a design parameter — not changed unilaterally here.

## Files changed in this round (NOT pushed — leader handles builds)

- `JoeTVApp.swift` — `JoeRootView.appVersion` (bundle version) + corner label uses it.
- `JoeSettings.swift` — footer label uses `JoeRootView.appVersion`.
- `JoePhimHome.swift` — `heroBackdropURL` state; three-stage hero stack; TMDB backdrop resolution in the hero task.
- This report. **Convergence greps re-run after the edits:** `.scaleEffect(` 0 hits, `.focusEffectDisabled(` 0 hits, `AsyncImage` 0 *code* hits (2 comment mentions in `JoeImagePipeline.swift`'s header, pre-existing). No `AsyncImage` introduced; no focus-driven conditional modifiers introduced.

## Honesty declaration

**Claims proven from primary evidence:** KK list/detail payload values and image URLs (fetched live); thumb/poster pixel dimensions and the thumb's composite layout (images downloaded and viewed); every code path cited (file + line reads of the current source); pipeline facts (no-retry, 8/host cap, unbounded prefetch); all seven current-rail poster URLs returning HTTP 200 from the VM; both hardcoded label locations and their fixes; the §F parser table (source reads); convergence-grep results after the edits.

**Inference, labelled:** photo→build attribution in §C (slice-window geometry vs the lettering/head placement in the photos — strong, but the hardcoded label makes it unprovable from the photos alone); the rail misses' mechanism class (per-request failure under contention — the non-adjacent pattern rules out starvation/outage, but the exact error on the owner's device is not observable from here).

**Unverified, labelled:** TMDB's backdrop composition for tv 330168 (no key available on the VM); the VS payload for *this* film (a guessed VS detail endpoint returned 404; VS payload shape rests on the client's own "KK-shaped" comment plus Android FIX5's live VS measurement for Die Hard); whether photo 4's hero load hard-failed or was still in flight; that the edited Swift compiles (no Xcode on the VM — the leader's CI build is the gate) and how the fix behaves on a real Apple TV (no device on this side; the owner's install is the first real run, as with v2.0.1).

---

## §V202-COMPLETE — P2 identity parity + P1 pipeline resilience (v2.0.2 / build 15)

**Date:** 2026-11-15 (America/Chicago) · **Team:** TVOS-V202-COMPLETE. **Scope:** close the two open proposals from the forensics round above (P2, P1), on top of the forensics fixes already in the tree (three-stage hero in `JoePhimHome.swift`; real version label in `JoeTVApp.swift` + `JoeSettings.swift` — presence re-verified this round: `JoeRootView.appVersion` at `JoeTVApp.swift:169`, labels at `JoeTVApp.swift:288` and `JoeSettings.swift:124`, `heroBackdropURL` in `JoePhimHome.swift`). Version bumped to **2.0.2 / build 15** (JoeTV target only). Code + staging only — no push, no build dispatch; the leader handles both.

### P2 — IMDb identity parity with Android FIX5 (defect #5)

Parser-only changes, mirroring §ANDROID-V23-FIX5's measured semantics. No new `Movie` fields — `imdbId` / `tmdbId` / `tmdbType` / `tmdbSeason` already exist (`JoeModels.swift:45–48`); the parsers simply stopped leaving them empty.

- **KkClient** (`parseMovie`): now reads the payload's `imdb` object — fills `imdbId` only when empty, value passed through `cleanField` (the house null discipline: a JSON null or the literal text `"null"` is missing data, never an identity — the Gold "tpv:null" lesson). Same tolerant shape as Android `KkApi.fillFacets`. The existing `tmdb` reads were also wrapped in `cleanField` (Android applies the same "null" guard there; tvOS previously relied on `JSON.str`'s NSNull guard alone). **Effect on the rescue ladder:** `torrentFallbackCandidates` (JoeMovieDetail.swift:1321) already reads `kd.movie.imdbId` from the alt-KK detail — that leg was dead only because the parser never populated the field; it is live now with **no ladder code change**. KK-opened films also skip the TMDB `external_ids` round trip they used to pay on every torrent rung.
- **VsClient** (`parseMovie`): now reads BOTH the `tmdb` object (id / type / season, the exact KkClient block) and the `imdb` object (same guarded fill). Android FIX5 live-measured the VS Die Hard detail carrying `tmdb {type:"movie", id:"562"}` + `imdb {id:"tt0095016"}`; tvOS previously dropped both, so a VS-only title had no torrent identity at all.
- **F4kClient** (`parseMovie`): now reads the flat `tmdbId` — `JSON.str` stringifies the JSON number, `cleanField` applies the null discipline, and `"0"` is rejected as the payload family's missing-value marker (same as year 0 in this parser). `tmdbType` derives from `mediaType` ("tv"→"tv", "movie"→"movie", else ""). A tolerant IMDb read (KK object shape, then a flat `imdbId` string) was added behind it — **defensive only**: live payloads measured this round carry no IMDb field (below).
- **Consumers:** the recovered/native identity feeds the same consumers Android's does — `torrentFallbackCandidates`' identity chain (own `imdbId` → own `tmdbId` → TMDB `external_ids`, with the alt-KK leg as the deeper rescue) and the detail screen's TMDB calls (`JoeMovieDetail.swift:141–160`, `JoePhimHome.swift:377` — an F4K/VS film's `tmdbId` now also reaches `fetchInfo` directly instead of depending on the backdrop name search). `isUSTheatrical` and every policy constant are **untouched** — the classifier was already provider-independent and firing (forensics §F); it now has identity to feed its probe.

**F4K payload evidence (fetched live from the VM this round, `film4k.net`):** `/api/title/die-hard` and `/api/watch/die-hard` movie objects carry `"tmdbId": 562` (JSON number) and **no `imdb` key at all** (full key list: _id, backdrop, createdAt, genres, hlsUrl, maxRes, mediaType, okruId, overview, poster, score, search, slug, title, tmdbId, tokens, updatedAt, viDub, viSubs, views, votes, year — also no `country` keys on the detail record, matching Android's measurement). `/api/home` list items and `/api/search/suggest` items carry **neither** `tmdbId` nor any imdb field — so list-parsed F4K movies stay identity-empty and the identity lands at detail parse, exactly as on Android.

### P1 — Image pipeline resilience (defect #3), `JoeImagePipeline.swift` only

- **Bounded retry in `load`:** the single attempt became a classified attempt loop. Each attempt's outcome is `.image` / `.permanent` / `.transient`: a thrown error or timeout, HTTP 429, HTTP 5xx, or an undecodable body (the truncated-transfer class) is transient; any other 4xx is permanent and stops at once (a 404-class failure is therefore never retried — inside the brief's "not more than once" bound, at zero). Transient failures retry up to 2 times with backoff (0.5 s, 1.5 s) — 3 attempts max. The whole sequence lives inside the ONE in-flight task, so the (URL, bucket) dedupe and the decoded-cache write are unchanged: every view awaiting the load receives the healed result instead of a fossilised placeholder. Worst case for a truly black-holing host grows from one 30 s timeout to ~92 s before nil — bounded, and only for loads nothing could have painted anyway; the observed defect class (transient failure under contention) heals on attempt 2 in ~1 s.
- **Prefetch concurrency cap:** `prefetch` no longer spawns one detached task per URL. URLs join a FIFO backlog (deduplicated against the decoded cache, the in-flight map, and the backlog itself; per-item bucket preserved) drained by a pump that keeps at most **3 prefetch loads** in the network at once — the session's per-host pool is 8, so visible loads keep the majority. All four prefetch callers (`JoeStores.applyRail`, `JoeBrowse` ×2, `JoeTVApp` root warm-up) ride this path, so the cap is pipeline-wide. Visible loads are structurally untouched: `image(for:)` never consults the backlog, starts or joins its own userInitiated load immediately, and a backlog entry for a URL a visible load already claimed is dropped when its turn comes. FIFO order preserves the rails-land-in-home-order warming property.
- **Preserved:** the pipeline's public API (`image(for:targetPixels:)`, `cachedImage(for:targetPixels:)`, `cachedImageAnySize(for:)`, `prefetch(_:targetPixels:)`, `bucket(forPixels:)`) is unchanged in signature and semantics; `cachedImageAnySize` — the peek the hero fix's stage 1 relies on — is byte-identical.

### Version bump

`project.yml`, JoeTV target only: `MARKETING_VERSION` "2.0.1"→"2.0.2", `CURRENT_PROJECT_VERSION` "14"→"15", and the generated info properties `CFBundleShortVersionString` "2.0.1"→"2.0.2", `CFBundleVersion` "14"→"15". Other targets untouched (DaBanh 1.5/6, DaBanhTV 1.3.2/14, TVApp 2.0/4 — grep-verified after the edit). With the forensics round's label fix, the corner label and Settings footer now render the real "Joe TV v2.0.2".

### JoeDetailCache compatibility — proof

P2 adds **no fields** to `Movie` or `Detail`: the four identity fields already existed in the struct and therefore in the synthesized `Codable` shape, so the on-disk JSON schema is byte-for-byte the same key set with the same types. Two independent guarantees cover existing cache files: (1) **schema** — even a hypothetical cross-version read would decode identically, since nothing was added, removed, or retyped (no optionality shim is needed because nothing changed); (2) **the envelope gate** — `JoeDetailCache.read` requires `env.v == appBuild`, and the build number moves 14→15 with this release, so build-14 cache files are a clean miss under 2.0.2 regardless. Within 2.0.2, cache and fresh fetch pass through the same parsers, so the fingerprint (which already includes `imdbId`/`tmdbId`/`tmdbType`/`tmdbSeason`, `JoeDetailCache.swift:116`) compares like with like. Behaviour change is limited to this: a film whose detail was cached by an older parser generation *within the same build* is not a case that can occur (the parser ships with the build the envelope is keyed to).

### Regression gates (run this round)

- **Convergence greps** over `JoeTV/*.swift`: `.scaleEffect(` → **0 hits**; `.focusEffectDisabled(` → **0 hits**; `AsyncImage` → 4 hits, **all in comments** (pipeline header/doc lines + one JoeMovieDetail doc line, all pre-existing) → **0 code hits**. ✓
- **Filter-predicate test** (`ui-redesign/filter-predicate-test.py`): **ALL CHECKS PASSED** (exit 0). ✓
- **Focus law:** this round's edits touch zero SwiftUI view code (three parsers + pipeline internals + project.yml); `@FocusState` / `.focused(` count in all four edited Swift files is 0, and no conditional structure of any kind was added to a view. The forensics round's hero fix was already gated the same way. ✓
- **Balance check:** brace/paren/bracket deltas are 0 in all four edited Swift files (crude truncation check; not a compile). ✓
- **Untouched per brief:** Android tree, hero-fix design (scrims/text/focus), theme layouts, provider playback resolvers, torrent policy constants, `isUSTheatrical`, SourceHealth, DetailCache code. ✓

### Push set

Staged at `~/workspace/dabanh-ios/push-paths-v202.bin` (NUL-delimited + trailing NUL, same format as push-paths-v201.bin — byte-compared tails): `project.yml`, `JoeTV/KkClient.swift`, `JoeTV/VsClient.swift`, `JoeTV/F4kClient.swift`, `JoeTV/JoeImagePipeline.swift`, `JoeTV/JoePhimHome.swift`, `JoeTV/JoeTVApp.swift`, `JoeTV/JoeSettings.swift`, `JoeTV/HERO-FORENSICS-REPORT.md`. **Not pushed; no build dispatched** — the leader handles both.

### Honesty declaration

**Claims proven from primary evidence:** the F4K payload shapes (live fetches this round — `/api/title/die-hard`, `/api/watch/die-hard`, `/api/home`, `/api/search/suggest` — full key lists inspected, quoted above); the Android FIX5 semantics (§ANDROID-V23-FIX5 read in full, plus the Android parser blocks read directly); every tvOS code path cited (file + line reads of the current source, before and after the edits); the ladder's alt-KK leg already reading `kd.movie.imdbId` (JoeMovieDetail.swift:1321 — the fix is in the parser, no ladder edit was needed or made); the DetailCache argument (envelope gate + unchanged Codable shape, both read from source); all gate results above (commands run this round, outputs observed); the version strings after the bump (grep over project.yml).

**Inference, labelled:** that VS tvOS payloads carry the same identity objects Android measured (the VS API is one service; tvOS VsClient's own header records KK-shaped payloads, and the new parse is tolerant — if a VS payload lacked the objects, the fields simply stay empty and behaviour is identical to today); that 3 prefetch workers + the retry policy will clear the owner's rail misses (the mechanism class was proven in §D; the exact on-device error mix is not observable from the VM).

**Unverified, labelled:** the edited Swift was **not compiled** — there is no Xcode/Swift toolchain on this VM (`which swift swiftc xcodebuild` returns nothing); brace balance and careful re-reads are the local ceiling, and the leader's CI build is the compile gate. On-device behaviour of P1/P2 (chip/rung liveness per provider, rail-poster recovery, hero on the real Apple TV) is unverifiable from here — the owner's install of the CI build is the first real run, as with every tvOS build. TMDB's backdrop composition for tv 330168 remains unverified for the same reason stated in the forensics round (no key on the VM).
