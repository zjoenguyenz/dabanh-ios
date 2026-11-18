# JoeTV 2.0.27/40 — BUILD REPORT (checkpoint 3 of 3, continuous 13-idea run)

Date: 2026-11-18. Scope: ideas **13, 17, 20, 21, 23** from
`tvos-training/IDEAS-20261118.md`, plus idea 1's actor shelf row, which was
deliberately withheld from checkpoint 1 (it would have been a dead tap
until the actor pages in this package existed). With this push, **all 13
approved ideas are implemented**: checkpoint 1 = 2.0.25/38 (ideas 1, 2, 3,
6; commit `854c087ee5bfc79407b2f09bf6ca4267e9d915c2`), checkpoint 2 =
2.0.26/39 (ideas 4, 5, 7, 10; commit `66dde2f1489cc77dfa85586daa4da97d6d6fd206`),
checkpoint 3 = this build.

Presnap: `backup-v2027-presnap/`. Version pairs bumped for the JoeTV target
only, read back: 2.0.27 / 40. One NEW file registered in project.yml's JoeTV
sources: `JoeTV/JoeActorPage.swift`. Static verification only — no Swift
toolchain on this VM; CI is the compile gate.

## Idea 13 — System player knows what it's playing (`JoeTV/JoePlayerView.swift`)
AVPlayer path only (the KSPlayer path keeps its own settled chrome).
PlayDirector gained `userSwitchSource()` (advances through the EXISTING
failover machinery — next ladder rung, else failoverStep — without
recording a failure), `toggleFavourite()`, and `skipToNextEpisode()`
(itemEnded's progress bookkeeping + the standing advance path). The player
controller's Coordinator now, per item: sets `externalMetadata` (title incl.
episode label immediately; poster artwork fetched async, applied only if
the item is still current), installs a "Joe TV" `transportBarCustomMenuItems`
menu (Đổi nguồn / Yêu thích / Tập tiếp theo — the last only when a next
episode exists; rebuilt per item and after a favourite toggle), and feeds a
`customInfoViewControllers` info tab (title, episode, current source).
**Labelled deviation (deliberate, correctness):** the favourite toggle keys
to the detail screens' own derivation (`WatchStore.movieFavKey` /
`torFavKey`), NOT the director entry's key — in both director factories the
entry key is the PROGRESS key, so a literal implementation would have
created an orphan favourite invisible to every detail screen and rail.

## Idea 17 — Launch gate de-duplication (`JoeTV/Providers.swift`, `JoeTV/SourceProbe.swift`, `JoeTV/JoeTVApp.swift`)
Providers gained a session raw-response memo (key = provider + ListRequest,
TTL 120 s, lock-guarded): `fetchListRaw` reads/writes it; a new
`fetchListRawFresh` bypasses the read but still writes. SourceProbe now
probes through `Providers.newestFresh` — literally the home's own call —
while still measuring the REAL network every time, and its responses land in
the memo. Verified: all four PhimStore "newest" jobs flow through the single
`fetchListRaw` call site in `runPhase`, so gate phase 2 now reuses phase 1's
responses instead of refetching (JoeStores.swift needed no change). The gate
COMPLETES at the end of phase 2 — the shell is interactive there — and the
poster preload (same list, same 80 cap) continues as a detached background
task feeding the same image pipeline. Preserved: the 50 s hard cap, the
deep-link skip (which also skips the background preload), the visible bar's
existing scale and `finish()` contract (monotonic; jump-to-full at handover
is finish()'s long-standing behaviour), and the Settings diagnostics
surface. Labelled addition: the Settings tunnel-status `probeKK` moved onto
the same fresh Providers path to keep the file's "probe = real runtime
path" invariant.

## Idea 20 — Actor pages + idea 1's actor row (`JoeTV/TMDBClient.swift`, new `JoeTV/JoeActorPage.swift`, `JoeTV/JoeTVB.swift`, `JoeTV/JoeMovieDetail.swift`)
TMDBClient gained `TMDBCreditTitle`, `fetchPersonCredits` (combined
credits, popularity order, deduped, cached, fail-soft),
`fetchCollection`, and `TMDBInfo.collectionId/collectionName` (parsed from
the existing detail call — no extra round trip). `JoeActorPage` has two
modes: `.tvb(name)` — filmography = bundled snapshot titles whose cast
contains the name, opened via the TVB tab's own route; `.tmdb(personId)` —
TMDB credits matched to playable titles (PhimStore tmdbId map + TVB
snapshot), unmatched credits shown as plainly-labelled non-focusable rows
under "Chưa có nguồn phát" — never dead cards. The TVB tab gains the
"🎭 Diễn viên" rail (actors with ≥ 6 displayed titles, count desc, cap 20;
cards use the representative title's poster) tapping into the `.tvb` page.
In the detail, the TMDB photo cast row (Ultra + D themes) became focusable
buttons presenting the `.tmdb` page.
**Labelled limitation:** design A's `actorsLine` renders cast as one text
line — that is design A's approved presentation, so it stays non-focusable
rather than breaking design fidelity; A-theme users reach actor pages via
the TVB rail and the other themes' cast rows.

## Idea 21 — Franchise strip (`JoeTV/JoeMovieDetail.swift`)
When the loaded TMDBInfo carries a collection, the detail's end gains a
"🎞️ Thuộc bộ phim: <name>" rail: each part is searched across providers and
accepted ONLY on a TMDB-id match (cap 8); matched parts open as fresh
details. The current title's own part is excluded (already on screen).
Unmatched parts drop silently. Coordinator fix during integration: the
worker's first pass coded against a guessed collection-object shape; it was
aligned to the client's actual `[TMDBCreditTitle]` contract +
`TMDBInfo.collectionName` before this push.

## Idea 23 — Warm VSMOV / Tủ Phim resolved media (`JoeTV/JoeMovieDetail.swift`, `JoeTV/JoeProxy.swift`)
The shared warming system (2.0.25) now covers VS/TP: at detail dwell AND in
the onPlayingStarted next-episode warm, when the session provider is VS or
TP and the ladder's first entry is a proxy entry, the entry is converted
through `JoeProxy.playlistURL` exactly as the play path does and warmed via
`StreamWarmer.warmUpcoming`. Film4K is EXCLUDED (rotating tokens) and KK's
non-proxy warm is byte-for-byte unchanged.
**Coordinator fix (load-bearing):** JoeProxy minted a fresh UUID token per
`playlistURL` call, so a dwell-minted proxy URL could never string-match
the tap-minted candidate in `StreamWarmer.take()` — the warm would have run
but always missed. `JoeProxy.register` now derives the token
deterministically (SHA-256 of upstream + sorted headers + kind, CryptoKit)
with LRU-tail refresh on re-registration; the same upstream+headers now
yield the identical loopback URL at dwell and at tap, so the take hits.
Segment ("s") routes get the same determinism harmlessly (identical
upstream = identical route).

## Honest limits
- No compile possible on this VM; verification = full re-reads, delimiter
  balance vs the presnap, and a cross-file symbol audit (all new APIs
  verified present with the contracted names/shapes across
  TMDBClient/JoeActorPage/JoeMovieDetail/JoePlayerView/Providers).
- Idea 13's favourite label and Tập tiếp theo presence refresh per item
  (and after a toggle), not continuously.
- Idea 17's memo is launch-scoped in effect: any fetch > 120 s after the
  probe misses the memo and goes to the network, as designed.

## Delivery
Code commit on `main`: **9ff781de10c14962ceef808621a248023789609d**
(10 paths: project.yml + JoeActorPage, JoePlayerView, JoeProxy, Providers,
SourceProbe, TMDBClient, JoeTVApp, JoeTVB, JoeMovieDetail.) Parent: dispatch
"Build JoeTV IPA" on main at this SHA for the owner's test install. This
completes the 13-idea run: 2.0.25/38 → 2.0.26/39 → 2.0.27/40.
