# JoeTV tvOS 2.0.24 — Round Report (Team ATV, 2026-11-18)

**Code commit: `426fb081f7439de3c54b523ee9608b18082b0a50`** (branch main,
repo zjoenguyenz/dabanh-ios). Base: 2.0.23/36 (commit `337feea`,
owner-verified PASS). Version bumped to **2.0.24 / 37** in BOTH
project.yml pairs (settings MARKETING_VERSION/CURRENT_PROJECT_VERSION
and info.properties CFBundleShortVersionString/CFBundleVersion).
Presnap: `~/workspace/dabanh-ios/backup-v2024-presnap/JoeTV/`.
Scope: JoeTV target only — 6 files edited, 1 file added, project.yml.
Nothing else in the shared repo was touched.

## What shipped

### A. Start-speed, designed the tvOS way (Sony D1 + D2 equivalents)

**The platform study changed the shape, as ordered.** Sony's D2 is
Media3's `DefaultPreloadManager` (a manager sharing the player's
components preloads the first ~5 s of the likely-next item). The tvOS
study (Apple's AVFoundation playback guidance + KSPlayer 2.3.4 docs)
found no preload manager on this platform; the native
prepare-in-advance shape is: create the `AVURLAsset` early, load its
keys asynchronously (`asset.load(.isPlayable)` — for HLS this pulls
the master + variant playlists), and assign an `AVPlayerItem` with a
~5 s `preferredForwardBufferDuration` to a paused `AVPlayer`, which
then loads its item toward that buffer target. The port implements
exactly that shape; no Android code was transplanted.

- **D1 (subtitle parallelisation)** — The tvOS codebase has exactly
  ONE app-level serial subtitle leg: `JoeTorrentDetail.loadStreams`
  awaited the pooled stream fetch and THEN awaited the subtitle
  fetch (18 s budget) before clearing its loading state. It now
  fires both concurrently (`async let`) and joins them — the section
  waits for max, not sum. The subtitle CHOICE (`bestVietnamese` over
  the same fetch) is unchanged. Honest scoping: the KK/provider path
  has NO side-loaded subtitle fetch (KK subtitles are embedded in
  the HLS and chosen in-player), so there is nothing to parallelise
  there; the torrent substitution rung and the torrent-first probe
  fetch no subtitles either.
- **D2 (detail-dwell prefetch)** — New `JoeStreamWarmer.swift`: a
  lock-guarded singleton holding ONE warmed entry {url, headers,
  AVPlayer}. The existing dwell hook in `JoeMovieDetail`
  (`dwellPreResolve`, 1.5 s after paint, restarting on
  episode-focus change) already pre-resolved the focused episode's
  URL; for **KK only** it now also builds the episode ladder (cheap
  on the memo hit the pre-resolve just landed) and warms its first
  non-proxy entry. `PlayerController.makeUIViewController` adopts
  the warmed player whole when the tap's first candidate matches
  (exact URL + headers, age ≤ 600 s — the resolve memo's TTL, so a
  stale warm is refused and the cold build runs byte-identically).
  Asset construction is shared: `PlayCandidate.makeAsset()` is the
  exact construction the cold path used, so warm and cold open the
  stream identically.
  - **Coordinator fix the warm required**: a warmed item may
    already be `.readyToPlay` when the KVO observation is installed
    (`.new` never fires for a past transition) — without handling,
    the resume seek would be lost and the U-1 20 s watchdog would
    kill a healthy item. The ready branch is now a shared
    `handleReady()` called from both the KVO handler and a
    post-observe status check. Cold items are `.unknown` at observe
    time, so the cold path is unchanged.
  - **Honest bounds**: AVFoundation exposes no API guaranteeing an
    exact warmed byte count — the HLS stack decides how much of the
    5 s forward buffer to fill while paused. What is warmed is the
    asset's keys, both playlists, and the initial segments the stack
    pulls toward that target. The warm covers only the dwell-named
    item (KK's first ladder entry); VS/F4K/TP keep URL-level
    pre-resolve only (their URLs are tap-minted), exactly as Sony
    excluded its non-KK providers. In-memory only; nothing is
    persisted; stream URLs are still resolved fresh at tap time —
    the warmer merely recognises the tap's own fresh URL.

### B. Nuvio sports (Sony 2.3.37 semantics, Swift shape)

- **Separate stored bases, MF base never repointed** —
  `TorrentSettings` gains `sports_url` / `sports2_url` slots
  (defaults `https://nuviosports.xyz` /
  `https://stremverse1.alwaysdata.net`; a stored value wins; a
  stored value that fails http/https validation makes the slot
  nil, the mfBase honesty rule) and `sportsAvailable`
  (= sportsBase != nil || mfBase != nil). The pooled MOVIE path is
  byte-identical.
- **Chain**: `TorrentClient.fetchSportsEvents()` — Nuvio scoped →
  MediaFusion (existing fetch, now stamping serving bases) →
  StremVerse scoped; first non-empty wins. Scoped fetch =
  manifest → declared live catalogs (type events/tv) ∩ allowlist
  in allowlist order → concurrent fetch, merged in allowlist
  order, deduped by id, each meta stamped with its serving base
  and inheriting its catalog's live type when untyped (Sony's
  stampLiveType rule). Allowlist (Sony order): live, football,
  basketball, hockey, motorsport, mma, baseball, tennis, rugby,
  american_football, cricket, golf, darts, college, other,
  networks, upcoming — all `*_replays*` shelves excluded.
  StremVerse allowlist = `stremverse_live_events` only.
- **Pagination — measured, not guessed.** Live probe from the VM
  (2026-11-18 ~00:50–01:00 CST) against the real instance: all 17
  allowlisted catalogs are declared; football fully paged = 265
  metas, upcoming = 397 (both grew since PL-CHECK's 261/361);
  Sony-order deduped merge ≈ 735. **PL fixtures sit at merged idx
  279 (Newcastle vs Arsenal) and 291 (Liverpool vs Man Utd)**;
  Sky Sports Premier League channel at merged idx 102 (football
  page 1); CNN at idx 52. Implementation: football + upcoming are
  fetched through every page (Stremio `skip=`, 100/page, ≤5 pages,
  12 s/page, fail-soft per page); all other catalogs page 1 only.
  **Merge cap = 400** — Sony's 260 was calibrated to page-1
  fetches and provably cuts both PL fixtures under full
  pagination (0/2 within 260); 400 is the smallest round cap
  carrying tonight's measured live+football core (351 unique)
  with headroom. The tab's old local `prefix(60)` is gone; the
  cap lives in the fetch.
- **Streams**: sports metas resolve from their OWN serving base
  via new `fetchStreamsLive` — the existing fetchStreams parse
  with gateway tag `"LIVE"` and SourceHealth provider key
  `"live"` (fetchStreams gained a defaulted `provider:`
  parameter), so MF's ⚡️ cache grammar never mislabels a direct
  live row as awaiting debrid (the Sony rule). The tab's play path
  ranks with the shared `rankPool` before candidate conversion —
  click-and-play preserved, best-first. The player's source line
  names the serving source by host (Nuvio / StremVerse /
  MediaFusion). Live streams play direct, no tunnel — unchanged.
- **Tab surface**: chip gate `mfBase != nil` → `sportsAvailable`
  (both render sites); hero kicker "THỂ THAO TORRENT ·
  MEDIAFUSION" → "THỂ THAO TORRENT"; the two empty-state texts are
  source-neutral now. Settings gains one field beside the MF
  field — "Thể Thao Torrent — nguồn chính (Nuvio)" (Sony parity),
  wired through state/onChange/save like the MF field.

### Protected / untouched (verified by diff against the presnap)

2.0.23's theme, LaunchGate and home; Live Events; the pooled movie
path (`fetchPooledStreams` and the movie legs byte-identical);
default tracks (subtitle VI else EN, audio EN) + manual override;
the US-theatrical Auto gate and torrent-first race; manual source
pin = hard constraint; the fresh-URL rule (warmth comes only from
the current session's fresh ladder); stall policy and failover
semantics (the coordinator change adds an already-ready entry
point to the SAME ready handling, nothing else).

## Change surface per file

| File | Change |
|---|---|
| `JoeTV/TorrentClient.swift` | TorrentSettings sports slots + `sportsAvailable`; `TorMeta.servingBase`; fetchStreams `provider:` param; MF sports fetch stamps servingBase; new Nuvio/StremVerse section (allowlists, `fetchSportsEvents`, `fetchLiveScoped`, `fetchSportsCatalog`, `fetchStreamsLive`) |
| `JoeTV/JoeStreamWarmer.swift` | NEW — dwell media warmer (AVURLAsset + async key load + paused AVPlayer, 5 s forward buffer, 600 s freshness bound) |
| `JoeTV/JoePlayerView.swift` | `PlayCandidate.makeAsset()` shared construction; PlayerController warm take-over; Coordinator `handleReady()` + already-ready check |
| `JoeTV/JoeMovieDetail.swift` | `dwellPreResolve` KK-only ladder build + `StreamWarmer.warm` |
| `JoeTV/JoeTorrent.swift` | D1: `loadStreams` subtitle fetch concurrent with pooled stream fetch |
| `JoeTV/JoeTVSection.swift` | Chip gate → sportsAvailable; `loadSportsEvents` → chain fetch (local prefix(60) dropped); hero kicker; source-neutral empty states; `playEvent` serving-base + live fetch + rankPool + source name |
| `JoeTV/JoeSettings.swift` | Sports (Nuvio) field: state, UI, onChange, save |
| `project.yml` | JoeStreamWarmer.swift added to JoeTV sources; BOTH version pairs → 2.0.24 / 37 |

## SECONDARY — Sony 2.3.37 pagination answer (report only)

**Sony 2.3.37 would NOT surface page-2 PL fixture tiles.** Its
`fetchCatalog` (`TorrentApi.java:479` in
`~/workspace/tv-build/tvphim-src/`) fetches one plain URL
`/catalog/{type}/{id}.json`, and a grep for `skip=` across the whole
Java tree returns nothing — the Sony sports fetch is page-1-only
end to end (`fetchLiveScoped` → `fetchCatalog`). Its upcoming rail
therefore holds only upcoming's page 1 (idx 0–99); the PL fixtures
at upcoming idx 141–208 and football idx 175–201 are never fetched.
The dedicated PL CHANNELS do surface on Sony — they sit on
football's page 1 (idx 16/51/52) — consistent with Team B's
on-device sweep finding Sky Sports Premier League in the 2.3.37
grid. No Sony changes were made or are requested by this finding.

## Honesty declaration

- **Claims**: all code changes above are in commit `426fb08…` and
  were diffed against the pre-edit presnap; the change surface is
  exactly the 8 paths pushed. The pagination numbers (football 265,
  upcoming 397, merge ≈ 735, PL fixtures at merged idx 279/291,
  cap analysis) come from live probes run from this VM against the
  production Nuvio instance on 2026-11-18 ~00:50–01:00 CST.
- **Evidence**: presnap diff (`diff -rq` — exactly the 7 JoeTV
  files), per-file brace-balance check (all balanced), targeted
  re-reads of every new block, codebase precedents for the task
  group tuple pattern (JoeStores.swift:793).
- **Unverified, labelled**: (1) There is no Swift toolchain on this
  VM — compilation is proven only by CI, which the parent
  dispatches next; the code was written against in-project
  precedents and re-read line by line, but a compile error remains
  possible until the run is green. (2) The warmer's real-world
  start-time gain is NOT measured — it needs the owner's device
  (no tvOS device access from here); the mechanism is Apple's
  documented prepare-in-advance shape, and its honest bounds are
  stated in the code and above. (3) Nuvio match-window fixture
  flow (a live PL match's own stream list) remains unproven for
  the same reason it was unproven in PL-CHECK — no PL match was
  live at probe time; the settling check is Saturday 2026-11-21,
  Newcastle vs Arsenal 11:30 CST. (4) MF-as-sports-fallback was
  not force-tested (Nuvio answers first by design); the leg is
  the pre-existing 2.0.16 fetch plus serving-base stamps.
