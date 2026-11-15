# Joe TV tvOS — Latency Tuning + Prediction Round: Implementation Report

Implementer: tvOS implementer subagent, 2026-11-15. Desk work only —
no git push, no build dispatch (per brief).
Spec sources: `LATENCY-AUDIT.md` (every number below derives from it),
`REWORK-LOOP.md` (standing contracts — respected: no focus/UI changes
beyond the player watchdog; 20 s spinner ceiling untouched).

## Files touched (11 + project registration)

| File | Change |
|---|---|
| `JoeTV/SourceHealth.swift` | **NEW** — the predictor component (Task 5) |
| `project.yml` | JoeTV target sources: `JoeTV/SourceHealth.swift` registered (line 122, after `JoeTV/JoeHTTP.swift`). `remote-project.yml` is a stale v1.7 snapshot and was NOT touched |
| `JoeTV/VsClient.swift` | detail + resolve caps; both wired through `SourceHealth.run` |
| `JoeTV/F4kClient.swift` | detail cap; wired through `SourceHealth.run` |
| `JoeTV/KkClient.swift` | detail cap; `fetchJSON` gained an optional `health:` leg — only `detail()` passes it |
| `JoeTV/TpClient.swift` | detail/embed caps, split budgets; `resolveGold` + Gold paging wired; `getNoRedirect` takes a `timeout:` parameter |
| `JoeTV/CacheVideo.swift` | resolve cap 10; in-memory resolve memo (Task 4) |
| `JoeTV/TorrentClient.swift` | Torrentio streams cap 15; wired through `SourceHealth.run` |
| `JoeTV/Providers.swift` | `findAlternatives` 12 s overall deadline; consumer (b) ordering in `ladderFor` + alternatives |
| `JoeTV/JoePlayerView.swift` | NEW mid-play freeze watchdog (Task 2) |
| `JoeTV/JoeProxy.swift` | segment stream-through (Task 3); serve-wait 35 s → 90 s; playlist/segment health samples |

Untouched by design: `TMDBKey.swift` (empty placeholder), subtitles
timeout 18 s, RdClient 25 s requests, all list/search timeouts (12 s),
JoeHTTP's 25 s default for unwired calls, TMDB default.

## Task 1 — Tuned constants (before → after)

Every tuned value is a **cap**: SourceHealth's dynamic fuse may only
tighten within it, never exceed it.

| Constant | Before | After | Location (after) |
|---|---|---|---|
| VS resolve timeout | 25 s (JoeHTTP default) | **8 s** | `VsClient.swift:26` `resolveCap` |
| VS detail timeout | 25 s (JoeHTTP default) | **10 s** | `VsClient.swift:25` `detailCap` |
| F4K detail timeout | 25 s (JoeHTTP default) | **10 s** | `F4kClient.swift:49` `detailCap` |
| KK detail timeout | 25 s (`fetchJSON` default) | **10 s** | `KkClient.swift:45` `detailCap` |
| TP detail budget | 20 s single, shared with the CV probe | **10 s API + separate 10 s CV probe** | `TpClient.swift:59` `detailCap`; probe draws on `CacheVideo.swift:32` `resolveCap` — never shared |
| TP embed timeout | 20 s (`getNoRedirect`) | **8 s** | `TpClient.swift:62` `embedCap` |
| CacheVideo resolve | 15 s | **10 s** | `CacheVideo.swift:32` `resolveCap` |
| Torrentio fetch | 35 s | **15 s** | `TorrentClient.swift:282` `streamsCap` |
| `Providers.findAlternatives` | unbounded (≤6 searches × 12 s ≈ 72 s worst) | **12 s overall deadline** | `Providers.swift` `findAlternatives` |
| JoeProxy serve-wait | 35 s | **90 s** | `JoeProxy.swift:241` (now guards the playlist path; segments stream) |
| Pre-ready stall watchdog | 20 s | **20 s — kept** | `JoePlayerView.swift:445` |

`findAlternatives` deadline mechanics: the sequential search runs in
an unstructured `Task` publishing into a lock-guarded box; the caller
polls at 100 ms and returns partial results at 12 s, then cancels.
A deadline-cut result is NOT written to the session altCache —
providers never reached are "unsearched", not "not carried". A
completed search caches exactly as before.

TP detail split detail: the API call gets its own 10 s cap; Gold
episode paging draws on the same detail-stage cap per page; the
CacheVideo probe inside `detail()` goes through `CacheVideo.resolve`,
which carries its own separate 10 s cap. `resolveGold`'s embed hop
runs at cap 8 with the status check (200 or 3xx, else throw) INSIDE
the measured closure, so a dead hash's fast 404 records as an
instant-fail sample, not a success. The same "parse inside the
closure" rule is applied to the VS embed parse (a 200 error page
records as instant-fail, per audit §3.1).

## Task 2 — Mid-play freeze watchdog (JoePlayerView.swift)

`PlayerController.Coordinator` gains a 1 s `Timer` on
`RunLoop.main` (.common mode), armed in `observe()` but judging only
after `.readyToPlay` — which also cancels the pre-ready watchdog, so
the two never overlap. State: `freezeReady` / `freezeEnded` /
`lastPositionSec` / `lastAdvanceAt`.

Fires `fireFail()` — the exact path `itemFailed` takes, so the
director's ladder advances (refresh → hop → torrent rung →
exhausted) — when the playhead has not advanced for **12 s** while
playback is supposed to be running. Guards, all required by the
brief:

- **User pause:** `timeControlStatus == .paused` holds the clock
  open and re-bases the position, so a resume always gets a fresh
  12 s. The scrub state sits in `.paused` too, so scrubbing can
  never trip it.
- **End of media:** the DidPlayToEndTime observer sets
  `freezeEnded`; within 1.5 s of the duration end the clock is
  also held open.
- **Seeks:** any playhead movement > 0.05 s in either direction
  counts as alive.
- `fireFail()` and `invalidate()` both cancel the timer.

12 s = two missed segments at the 6 s VS/TP/CV cadence (audit §6).
Constant this round — SourceHealth does not move it (consumer (c)).

## Task 3 — JoeProxy stream-through

`serve()` now splits by route type:

- **Playlists** keep store-and-forward (they must be rewritten
  whole before AVPlayer sees them), with the serve-wait raised to
  90 s. Unchanged otherwise: same rewrite, same MIME, same 502 on
  failure.
- **Segments stream.** A second URLSession (delegate-based, serial
  OperationQueue `joe.proxy.stream`) fetches the segment; a
  per-connection `StreamState` buffers upstream bytes only until
  the payload offset is *provably* the offset `stripDisguise`
  would choose (`streamOffset(forHead:)`):
  - non-PNG body → offset 0, decidable from the first 8 bytes;
  - PNG body → the first MPEG-TS sync triple is final the moment
    bytes i…i+376 are in hand and every earlier offset has been
    scanned and rejected — identical semantics to `stripDisguise`;
  - the ftyp / WebVTT fallbacks are only decided once the whole
    16 KB scan window has arrived, so precedence can never flip.
  The response head is then sent — `Content-Type` from
  `detectContentType` run on the STRIPPED payload start (Team 4
  conformance rule, unchanged), `Connection: close`, **no
  Content-Length** (unknowable while streaming; the body is
  close-delimited and framed by the final `isComplete` send) —
  followed by the buffered remainder and every later chunk as it
  arrives.

Outcome per route type:

| Route | Verdict | Why |
|---|---|---|
| VS segments (499 B PNG + MPEG-TS, streamvsmov) | **Streams** | TS triple confirmable within the first KB |
| TP Gold segments (~637 B PNG + MPEG-TS, blogcdn) | **Streams** | Same TS path |
| Film4K segments (67 B PNG + fMP4, 11–66 MB, tiktokcdn) | **Streams** | ftyp verdict deferred to the full 16 KB window, then streams — this is the route that removes the ≈11.5 s vs ≈5.1 s start gap |
| CacheVideo segments (plain TS, header-gated) | **Streams** | No disguise: offset 0 from byte 8; route headers carried as before |
| Subtitles, keys, any body that completes before the decision (< offset + 189 bytes) | Store-and-forward | Finished whole through the classic path (`stripDisguise` + `detectContentType` + Content-Length respond) — byte-identical to the pre-round proxy |
| Playlists | Store-and-forward (by design) | Must be rewritten whole; 90 s serve-wait now guards this path only |

Preserved invariants: prefix-stripping correctness (equivalence
argued above and in the `streamOffset` doc comment),
detected-payload MIME, loopback-only bind (untouched),
512-route FIFO cap (untouched), no semaphore waits on any caller
path (the one remaining semaphore is confined to the proxy's own
queue on the playlist path, as before). Upstream refused (non-2xx)
before byte one → 502, exactly as the old path. A mid-stream
upstream error after bytes flowed closes the connection; AVPlayer
surfaces a truncated segment and the director's ladder owns the
next step. Non-obvious mechanics, documented in code: stream-state
registration is enqueued on the same serial queue the delegate
callbacks arrive on, before `resume()`, so no callback can precede
its state.

## Task 4 — CacheVideo double-resolve eliminated

`CacheVideo.resolve` now memoises successful results **in memory
only** (never persisted): key `"{imdbId}|{season}|{episode}"`,
10-minute TTL, flush-all past 64 entries. The TP detail probe
(S{season}E1 / movie) and the ladder's resolve of the same key now
share one resolver call. Rationale (in code): resolver URLs are
stable CDN addresses — unlike Film4K's per-call tokens, which are
never memoised.

## Task 5 — SourceHealth, the predictor

New file `JoeTV/SourceHealth.swift`. Keys `"provider|stage|host"`,
stage ∈ {detail, resolve, playlist, segment}.

- **Host granularity** (`hostKey(for:)`): streamvsmov → full
  subdomain; blogcdn.site / tiktokcdn.com / kvp726.com → family
  domain; phimapi.com and free.cryboiz.workers.dev → whole host
  (workers.dev is a shared public suffix); everything else → last
  two DNS labels.
- **Latency:** EWMA, 600 s half-life, effective weight capped at
  20, time-decayed between samples.
- **Latch:** ≥2 consecutive **timeouts** → demoted 15 min
  (900 s). An expired latch reads false (re-probe state); the next
  recorded call decides — success or instant-fail clears, timeout
  re-latches (the counter is never reset by expiry). Non-timeout
  failures never latch; they record as instant-fail samples with
  their measured latency.
- **Cold-start priors** (exact, weight = 3 pseudo-samples):
  `vsmov|detail|vsmov.com` 1.26; `vsmov|resolve|v8…` 1.20;
  `vsmov|resolve|v9…` 1.20; `vsmov|playlist|v8…` 1.21;
  `vsmov|playlist|v9…` 1.21; `vsmov|segment|p25.streamvsmov.com`
  1.20; `f4k|detail|film4k.net` 1.16; `f4k|playlist|film4k.net`
  1.19; `f4k|segment|tiktokcdn.com` 1.76; `tp|detail|phimsrv.com`
  1.44; `tp|resolve|phimsrv.com` 1.33; `tp|playlist|blogcdn.site`
  1.84; `tp|segment|blogcdn.site` 2.68; `tp|resolve|q-1208.fun`
  3.57 (CacheVideo); `torrent|resolve|strem.fun` 1.0;
  `kk|detail|phimapi.com` 0.90; `kk|detail|free.cryboiz.workers.dev`
  1.58. **KK playlist/segment get NO prior** (VM geo-wall artefact
  must not convict KK on-device). Unprobed streamvsmov subdomains
  start unknown — the cap applies.
- **Recording wrapper** `SourceHealth.run`: computes the fuse,
  times the operation, records. CancellationError /
  URLError.cancelled are rethrown **unrecorded** (a race loser is
  not evidence); URLError.timedOut → `.timeout`; any other error
  → `.instantFail`.

### Consumer wiring

- **(a) Dynamic fuses** — `fuse = min(max(max(3×EWMA, EWMA + 4),
  6), cap)`; no data → cap. Wired at: VS detail + resolve (parse
  inside the closure), F4K detail, KK detail (per-host legs of
  the race, shape check inside the closure), TP detail + Gold
  paging + `resolveGold` embed hop (status check inside), the CV
  probe inside TP detail (via `CacheVideo.resolve`), CacheVideo
  resolve, Torrentio `fetchStreams`. JoeProxy records playlist
  samples (full fetch duration) and segment samples (time to
  first byte) for the hosts that actually flow through it
  (streamvsmov → VS; blogcdn/cachevideo → TP; tiktokcdn/film4k →
  F4K; anything else unattributed). KK never flows through the
  proxy and has no playlist/segment wiring — its candidates play
  direct; that is a coverage fact, not an omission.
- **(b) Ordering** — `Providers.ladderFor` iterates
  `orderServers(code:servers:)`: a stable partition moving
  servers whose resolution path is latched after unlatched ones,
  reading the SAME latch keys the resolvers record under (VS
  embed → (vsmov, resolve, embed host); TP `cv:` → (tp, resolve,
  CacheVideo resolver); TP `tpv:` → (vsmov, resolve, page URL);
  TP `tp:` → (tp, resolve, phimsrv host); direct m3u8 →
  (provider, playlist, host)). Untouched when nothing is
  latched. `findAlternatives` results pass through
  `orderedAlternatives` on both the cache-hit and fresh paths:
  priority order, except providers with any live latch
  (`SourceHealth.providerDemoted`) sort after healthy ones.
- **(c) Watchdogs** — both stay constant (20 s pre-ready, 12 s
  mid-play). The predictor never touches them.
- **Path baseline** — pooled EWMA over all recorded calls, cold
  prior 1.51 (≈ mean of the seeded priors). The latch threshold
  rises 2 → 3 only when the live baseline exceeds 2 × 1.51 AND
  ≥2 keys show a timeout within the last 300 s. Nothing else
  reads the baseline. Deliberately minimal, as briefed.
- **Persistence** — one JSON snapshot under UserDefaults key
  `source_health_v1`; load-once, priors seeded only for keys the
  device has no state for; saves throttled to ≥2 s except latch
  changes force one; cap 128 keys, least-recently-seen eviction
  with live latches evicted last. No network calls, no UI. All
  state NSLock-guarded.

## Discrepancies vs the audit's citations (followed the code)

- VS detail/resolve and F4K/KK detail had no literal timeout in
  their own files — they inherited JoeHTTP's 25 s default (KK via
  `fetchJSON`'s default parameter). The audit's "25 s" is that
  default; the tuned values now live as named caps in each client.
- TP detail was a single 20 s budget shared by the API call and
  the CV probe; it is now split exactly as briefed.
- The proxy's upstream request timeout stays 30 s — the brief
  changed only the serve-wait (35 s → 90 s), which now guards
  playlists only.
- KK list/search calls are deliberately NOT predictor-wired (they
  keep the plain 12 s list path); only the detail race is. The
  brief's constant list names detail fetches; list behaviour is
  unchanged.

## Honesty declaration

**Claims** — the constants above are changed at the cited
locations; SourceHealth exists with the stated semantics and is
registered in `project.yml`; the three consumers are wired at the
cited call sites; the freeze watchdog routes through `fireFail()`;
the proxy streams segment routes per the table above; the CV
double-resolve is memoised away.

**Evidence** — desk verification only: every edited hunk re-read
in full after editing; brace/paren/bracket balance = 0 on all 10
edited Swift files; grep inventory of every remaining timeout
literal in `JoeTV/*.swift` reconciled against this report (each is
either tuned above, deliberately kept and named, or JoeHTTP's
default for unwired calls); `project.yml` registration confirmed
by grep.

**Unverified — labelled:**
- **Compiler verification is OUTSTANDING for CI.** There is no
  Swift toolchain on this VM (`swiftc`/`swift`/`xcrun` all
  absent — checked). Nothing here has been compiled.
- AVPlayer's acceptance of close-delimited (no Content-Length)
  segment responses is standard HTTP/1.1 behaviour but has NOT
  been exercised on a device in this app.
- Streamed sends are fire-and-forget (`NWConnection.send` with
  ignored completion): if AVPlayer reads slower than upstream
  delivers, in-flight buffering is bounded by URLSession/NW
  internals, not by this code. Worst case is comparable to the
  old path (which held whole segments in memory), but the exact
  behaviour is UNVERIFIED on device.
- The freeze watchdog's scrub guard rests on AVPlayer semantics
  (scrubbing presents as `timeControlStatus == .paused`) —
  labelled inference, not device-measured.
- All predictor behaviour (EWMA/latch/fuse dynamics) is
  desk-reasoned from the audit's model; no on-device sample has
  been recorded yet. The P-E device gates remain the owner's
  first real run, as with every tvOS build in this project.
