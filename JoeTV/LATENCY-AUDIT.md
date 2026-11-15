# LATENCY AUDIT — Joe TV source switching (tvOS + Android)

**Team:** Latency Measurement Team · **Date:** 2026-11-15 · **Status:** measurements complete, recommendations derived — no app code was edited.

**Owner's order being served:** source switching must happen *in time* — never wait
until a failure is displayed — and every wait budget must be tuned from real
measured numbers: the exact time for one movie to obtain a playable source.
These numbers also become the **cold-start priors** for the ordered on-device
prediction layer (per-source rolling stats → ladder ordering + per-source fuses).

**Method (harness-matches-runtime):** every request below follows the apps' own
code paths — endpoints, hosts, flavours, headers and resolution chains were read
out of the tvOS clients (`KkClient`, `VsClient`, `F4kClient`, `TpClient`,
`CacheVideo`, `TorrentClient`, `TMDBClient`, `JoeHTTP`, `Providers`,
`JoeProxy`, `JoePlayerView`) and the Android clients (`KkApi`, `VsApi`, `F4kApi`,
`TpApi`, `CacheVideo`, `TorrentApi`, `TmdbApi`, `TvData`, `PlayerActivity`,
`SourceConfig`) before a single request was sent. Timings are curl
DNS/connect/TLS/TTFB/total from this VM, sequential, ordinary rates
(126 requests total over ~1 hour — no load testing).

**Sampling window:** 2026-11-15 ≈07:00–08:00 UTC (01:00–02:00 America/Chicago /
14:00–15:00 Vietnam). Two rounds ≈50 minutes apart for the drift check.

> **VANTAGE WARNING — read before quoting any number.** The apps play through
> the owner's tunnel (Sony keeper / Apple Sing-box); this VM measures from a US
> datacentre egress. Two consequences, both verified in the data: (1) KK's
> segment CDN refuses this vantage outright (see KK), so KK's on-device
> time-to-playable is **not** in this report — it is a Sony measurement item;
> (2) a uniform +~1 s drift hit *every* host in round 2 (the VM's shared egress
> path), proving a large shared-path component exists in all numbers. Treat
> absolute values as priors with wide error bars; treat the *structure*
> (which stage is slow, which host hangs) as the durable result.

Legend: **[M]** measured · **[D]** derived from code constants · **[U]** unmeasured.

---

## 1. Numbers per source

All times in seconds, `total` request time unless marked TTFB. Round-1 values
(the round-2 path drift is analysed in §5).

### 1.1 KKPhim (KK)

API hosts: A `phimapi.com` (`/v1/api/…` flavour), B `free.cryboiz.workers.dev`
(bare flavour). tvOS races A+B in parallel; Android walks up to 4 hosts
*sequentially* (A, B, C `free2.phim4k.dev/api`, D `mephim.ddns.net`).

| Step | n | median | max | Notes |
|---|---|---|---|---|
| List A | 2 (2 rounds) | 0.94 / 2.19 | — | round drift, §5 |
| List B | 2 | 2.37 / 2.30 | — | B is consistently ~2× A |
| Detail A | 5 | **0.90** | 0.91 | tight distribution |
| Detail B | 1 | 1.58 | 1.58 | + its HLS endpoint below |
| Detail B → HLS endpoint (`sf.phim4k.space`) | 1 | 3.01 | 3.01 | returns the variant playlist; segments still on kvp726 |
| Playlist A (`a.kvp726.com/index.m3u8`) | 5 | — | — | **404 from VM in 1.05–1.58** (geo-wall class, §3) |
| Segments (`a.kvp726.com`) | — | — | — | **unreachable from VM** [U] |
| Host C list/detail (Android only) | 2 | 0.96 / 0.78 | — | answers only the `{"status":false}` stub → fast-fail waste |
| Host D bare path (Android only) | 1 | 1.49 | — | HTML page, not the API flavour (app uses per-host paths; D's flavour not exercised) |

**Healthy envelope:** API part ≈ **0.9 s** (A) / ≈1.6–4.6 s (B path).
**Time-to-playable: UNMEASURED from this vantage** — playlist+segment legs are
tunnel-only. On-device item O-1.

### 1.2 VSMOV (VS)

Chain the app runs: detail → embed page GET (`v{1,6,8,9}.streamvsmov.com/video/…`)
→ parse `baseUrl`+`videoHash` → `master.m3u8` (a media playlist directly) →
segments (`p25.streamvsmov.com`, PNG-disguised, 6.0 s segments).

| Step | n | median | max | Notes |
|---|---|---|---|---|
| Detail | 7 | **1.26** | 1.87 | |
| Embed page, healthy hosts (v8, v9) | 4 | **1.20** | 1.26 | |
| Embed page, hosts v1 / v6 | 3 attempts | **HANG** | >45 | TLS completes (~0.26 s), then **zero bytes ever** — §3 |
| Playlist | 4 | **1.21** | 1.31 | 53–93 KB media playlists |
| Segment 1 TTFB | 4 | **1.20** | 1.91 | sizes 0.96–4.64 MB |
| Segment 1 total | 4 | 2.78 | 4.01 | |

**Healthy time-to-playable** (detail + embed + playlist + segment TTFB)
≈ **4.9 s median, ≈6.4 s at the slow end of the healthy samples.**
On tvOS the JoeProxy store-and-forwards each segment (responds only after the
full upstream download — `JoeProxy.serve`), so the tvOS figure replaces
segment TTFB with segment *total*: ≈ **6.5 s median** [D from code + M parts].

### 1.3 Film4K (F4K)

Chain: detail (movies carry `movie.hlsUrl`; series carry episode `sources[]`)
→ master playlist (on `film4k.net`) → variant playlist → segments on rotating
TikTok CDN hosts (`p16/p19-ad-site-sign-sg.tiktokcdn.com`), 20–27 s segments.

| Step | n | median | max | Notes |
|---|---|---|---|---|
| Detail | 5 | **1.16** | 1.41 | |
| Master playlist | 5 | **0.96** | 1.03 | |
| Variant playlist | 5 | **1.19** | 1.41 | 23–88 KB |
| Segment 1 TTFB | 5 | **1.76** | 2.18 | |
| Segment 1 total | 5 | **8.15** | **24.99** | segments are **11–66 MB each** |

**Healthy time-to-playable ≈ 5.1 s median to first media byte** (direct/Android
shape). **tvOS proxied shape ≈ 11.5 s median, 28.7 s worst sample** — the proxy
must swallow a whole 11–66 MB segment before AVPlayer sees byte 1 [D+M].
This is the single largest tvOS-specific start-up cost found.

### 1.4 Tủ Phim (TP) — Gold server

Chain: detail API → **CacheVideo probe inside `detail()`** whenever the title
carries an imdbId → per-server resolution at ladder time (Gold embed hop;
the CacheVideo server, when attached, resolves *again* at ladder time) →
playlist → segments. Gold playlists/segments live on per-title rotating
`*.blogcdn.site` subdomains (observed: lotus, woman, ant, mama), 6.0 s segments.

| Step | n | median | max | Notes |
|---|---|---|---|---|
| Detail API | 6 | **1.44** | 1.54 | excludes the CV probe below |
| CV probe inside detail (imdbId titles) | (see §1.5) | **+3.57** | +5.40 | sequential, inside the detail call's shadow |
| Gold embed hop (200 + XOR decode) | 4 | **1.33** | 1.68 | all 4 sampled Gold episodes took the XOR path |
| Gold playlist | 4 | **1.84** | 1.98 | 66–99 KB |
| Segment 1 TTFB | 4 | **2.68** | **6.00** | widest healthy spread of any source |
| Segment 1 total | 4 | 4.78 | 7.07 | 0.73–3.37 MB |

1 of 5 sampled TP titles had **no Gold server at all** in its detail (the
ladder then contributes nothing from TP for that title).

**Healthy time-to-playable:** Gold only ≈ **7.3 s median** to first byte
(≈9.4 s tvOS proxied). With the in-detail CV probe (imdbId titles):
≈ **10.9 s** (≈13.0 proxied). Worst observed composition (tp3, CV attached and
resolved again at ladder time): **≈17.6 s** to first byte. The CacheVideo
double-resolution (once in detail, once at ladder) is the slowest *healthy*
path in the whole system.

### 1.5 CacheVideo (CV)

Resolver `motchillv.q-1208.fun` (Stremio protocol, keyed by imdbId);
playlists on `cachevideo.com`, segments on `cdn.cachevideo.com`
(Referer/UA-gated — measured with the app's exact headers).

| Step | n | median | max | Notes |
|---|---|---|---|---|
| Resolve call | 6 | **3.57** | 5.40 | slowest single API call in the system; range 2.0–5.4 |
| Carried the title | 1 of 5 titles | — | — | a subset catalogue, as documented in code |
| Playlist (when carried) | 1 | 1.76 | — | |
| Segment 1 (when carried) | 1 | TTFB 1.83 / total 2.98 | — | 3.40 MB, 10.4 s segment |

**Time-to-playable as the playing source ≈ 7.2 s** (resolve + playlist + seg
TTFB), *after* a TP detail has already discovered it.

### 1.6 Torrentio (substitution rung's list step)

Plain base `torrentio.strem.fun`, **no debrid token** (none was available to
this team and none was sought — RD/TorBox resolve timing is **[U]** by rule).

| Step | n | median | max |
|---|---|---|---|
| Stream list, movie | 2 | 0.98 | 1.00 |
| Stream list, series episode | 1 | 0.91 | 0.91 |
| Stream list, other ids | 1 | 1.17 | 1.17 |

Fast and consistent. The rung's remaining legs — **RD resolve and the RD CDN's
playlist/segment start — are UNMEASURED** (token-gated). The leader's on-device
Sony observation (2026-11-15, tunnel off, KK dead → torrent substituted and
playing in ≈20 s end-to-end) bounds the whole rung on-device and is consistent
with the desk numbers once the Phim-side failure cascade is added.

### 1.7 TMDB (chain glue)

The real keyed calls are **[U]** — the key is a secret held in CI and was not
sought. Keyless probes of the same endpoints (HTTP 401, n=3) measure the
network path only: **0.89–1.03 s, median 0.91**. A keyed `external_ids` call
(the rung's TMDB leg) will cost path + server time; budget it at the probe
value as a floor. On-device item O-4.

### 1.8 Cross-provider alternative search (the hop's cost)

`findAlternatives` (tvOS) / the Android hop walk the other providers'
**search APIs sequentially**, up to 2 searches per provider (Vietnamese name,
then origin name). Measured single searches (n=1 each): F4K suggest **0.91** ·
VS tim-kiem **1.37** · TP search **1.46** · KK search A **1.92** (KK search on
host B fast-404s at 0.80 and is rejected by the race's shape check).

**Hop composition [D from M parts]:** typical ≈ **2.7–5.7 s** of searches
(one clean search per provider) + alternative detail (1.0–1.5) + alternative
ladder resolutions (VS +1.2 embed; TP +1.3 embed and possibly +2.0–5.4 CV) →
**a successful hop lands a playable substitute ≈6–13 s after it starts**,
before that substitute's own playlist/segment legs (≈+3–5 s typical).

---

## 2. Healthy-start envelopes (summary)

Time from *detail fetch starts* to *first media byte*, healthy source,
VM vantage, round-1 medians (tvOS proxied variant in brackets where the
JoeProxy store-and-forward changes the shape):

| Source | Envelope | Composition |
|---|---|---|
| KK | **unknown on-device** (API leg 0.9) | tunnel-only below the API |
| VS | **≈4.9 s** [tvOS ≈6.5] | 1.26 + 1.20 + 1.21 + 1.20 |
| F4K | **≈5.1 s** [tvOS ≈11.5, worst 28.7] | 1.16 + 0.96 + 1.19 + 1.76 (seg TTFB) |
| TP Gold | **≈7.3 s** [tvOS ≈9.4] | 1.44 + 1.33 + 1.84 + 2.68 |
| TP Gold + CV probe in detail | **≈10.9 s** [tvOS ≈13.0] | + 3.57 |
| TP worst healthy (CV attached, resolved twice) | **≈17.6 s** | tp3 composition |
| CacheVideo (as player) | **≈7.2 s** | 3.57 + 1.76 + 1.83 |
| Torrent rung (partial) | ≈0.9 (TMDB path) + ≈1.0 (list) + **[U] RD** | |

Slow-end (max-of-samples) healthy envelopes run ≈1.3–1.6× the medians for
VS/F4K/TP-API stages; TP segment TTFB is the exception (max 6.0 = 2.2× median).

---

## 3. Failure-declare latency — how fast the stack KNOWS

### 3.1 Measured at the HTTP layer [M]

| Failure class | Declare time | Evidence |
|---|---|---|
| Detail/search API 404 (all providers) | **0.78–1.24 s** | dead-slug probes on KK A/B, VS, F4K, TP |
| TP embed, dead hash | **1.20 s** (404) | |
| Playlist 404 (kvp726 geo-wall class) | **1.05–1.58 s** | 5/5 KK playlists from VM |
| Segment 404 | **1.44–2.15 s** | bogus segments on kvp726 (1.77), streamvsmov (1.83), blogcdn (2.15), cachevideo (1.44) |
| VS dead embed (HTTP 200 error page, parse-fail) | **1.97 s** | bogus video id on v8 |
| KK host C stub (`{"status":false}`) | **0.78–0.96 s** | fast-fail; pure waste when reached |
| **HANG: `v1`/`v6.streamvsmov.com` embed** | **no answer ≥45 s** | TLS done ≈0.26 s, then zero bytes, 3/3 attempts across ≈50 min |

**The pattern:** every *answering* failure declares in ≈0.8–2.2 s. The only
slow failure in the entire system is the **silent hang** — and against a hang,
the declare time is whatever timeout constant the client happens to carry.
That is precisely the class the owner's "switch in time" order targets.

### 3.2 Derived from code constants [D]

| Hang location | tvOS declare | Android declare |
|---|---|---|
| VS embed resolution | **25 s** (JoeHTTP default on `getText`) | **20 s** (read timeout) |
| TP Gold embed (`getNoRedirect`) | **20 s** | 20 s (read) |
| CacheVideo resolve | **15 s** | 20 s (read) |
| Torrentio list | **35 s** | 30 s (read) |
| Detail call, KK/VS/F4K | 25 s (KK races both hosts in parallel → bounded by the race) | 12 s connect + 20 s read **per host, sequential** → KK worst ≈ 4 hosts × 32 s ≈ **128 s** |
| List/search call | 12 s | 12 + 20 s per host attempt |
| Playlist/segment fetch inside player | AVPlayer-internal (opaque) + 20 s pre-ready watchdog (start only) | ExoPlayer + RetryPolicy (below) |
| JoeProxy upstream fetch (tvOS) | 30 s request timeout; **35 s** serve-wait cap per segment | — |

**tvOS mid-play silent stall — UNBOUNDED GAP [D]:** the 20 s watchdog is
cancelled the moment the item readies, and `tick()` only writes progress.
A stream that stalls silently *mid-play* has **no app-level fuse on tvOS**
until AVPlayer itself errors (opaque, unmeasured). Android has both fuses:
buffering >12 s and frozen playhead >15 s (2 s tick), first stall = one silent
reconnect, second = advance. Android's worst mid-play declare ≈ 12 + reconnect
+ 12 ≈ **25–30 s** before the ladder moves.

**Android RetryPolicy [D from code]:** in-source retries = 1 minimum;
403/404/410 → **no retry** (the ladder moves immediately — correct against the
measured 1.4–2.2 s segment-404 declare); other errors retry with
min(1 s × errorCount, 3 s) delays, giving up after errorCount > 3.

### 3.3 Worst-case tap → playable (possibly substituted), today [D]

| Scenario | tvOS | Android |
|---|---|---|
| First source healthy | ≈5–13 s (§2) | ≈5–11 s (no proxy store-and-forward) |
| First source **hangs** at resolution (VS v1/v6 class) | ≈1.3 detail + **25** resolve + ≈5 substitute chain ≈ **32 s** | ≈1.4 + **20** + ≈5 ≈ **27 s** |
| All Phim sources dead (fast 404s) → torrent rung | ≈15–25 s + RD [U] legs | **≈20 s observed on the Sony** (leader's device test) |
| KK call with all API hosts hanging | 25 s (parallel race) | **≈128 s** (sequential) |

---

## 4. Current constants inventory (from code)

**tvOS** — `JoeHTTP` default request timeout 25 s; list/search 12 s
(KK/VS/F4K/TP); TP detail 20 s; TP embed no-redirect 20 s; CacheVideo resolve
15 s; Torrentio `fetchStreams` 35 s, subtitles 18 s; TMDB default 25 s.
Player: U-1 stall watchdog **20 s** (pre-ready only — cancelled at
readyToPlay; **no mid-play position watchdog**). JoeProxy: upstream timeout
30 s, serve-wait **35 s** (proxy queue only; `playlistURL` never waits since
v1.9). Home load deadline 20 s. KK: 2-host parallel race, shape-validated.

**Android** — provider API `httpGet` connect 12 s / read 20 s everywhere
(KK/VS/F4K/TP/TMDB); `fetchBytes` connect 10 s / read 30 s; TorrentApi
`fetchStreams` 15 s / 30 s; RdApi 12 s / 20 s per request (multi-request
resolve — total [U]). PlayerActivity: `STALL_LIMIT_MS` **12 000**,
`POSITION_STALL_MS` **15 000**, watchdog tick 2 000 ms, `MAX_TRIES` 6,
`LAST_RESORT_RETRY_MS` 25 000, RetryPolicy as §3.2. KK: up to **4 hosts
sequentially** (SourceConfig defaults; the remote cfg that could override
them returned 404 from the VM during this audit, so defaults govern).

---

## 5. VARIANCE STRUCTURE — for the prediction layer

### 5.1 What latency clusters by

Three levels, in descending order of shared variance:

1. **The shared path (device WAN / tunnel / egress) — the dominant common
   factor.** Between round 1 and round 2 (≈50 min), *every* unrelated host
   slowed by a near-uniform +1.0–1.25 s (KK list A 0.94→2.19, VS list
   1.39→2.40, TP list 1.47→2.52, F4K home 1.38→2.37, Torrentio 1.00→2.59),
   while the VM's local DNS/connect stayed ≈0. The providers did not all
   degrade together — the *path* did. On-device, the Sing-box/keeper tunnel
   will play this role: expect all sources to breathe together with tunnel
   conditions, and expect any per-source stat to be polluted by it unless
   the predictor also keeps a global path baseline to subtract.
2. **The provider platform.** Healthy API medians are provider-shaped and
   stable within a round: KK-A ≈0.9, F4K ≈1.16, VS ≈1.26, TP ≈1.44 — and
   the CacheVideo resolver is a platform outlier at 2.0–5.4 s. KK host B is
   a within-provider platform effect: ≈2× host A on every call shape.
3. **The individual CDN host — where the catastrophic variance lives.**
   - `streamvsmov.com` subdomains are **categorical**: v8/v9 answered every
     embed in ≈1.1–1.3 s; **v1 and v6 black-holed every attempt** (TLS up,
     zero bytes, ≥45 s). Nothing in between was ever observed.
   - `*.blogcdn.site` rotates per title (lotus/woman/ant/mama/…): segment
     TTFB spread 2.47–6.00 s across subdomains — same provider, 2.4× spread.
   - `tiktokcdn.com` `p16`/`p19` hosts: segment TTFB 1.03–2.18 s —
     comparatively uniform; their variance is in *throughput* on huge
     segments (totals 6.0–25.0 s), not first byte.
   - `a.kvp726.com` from this vantage: 100% 404 — a vantage effect, expected
     to invert on-device (tunnel). A predictor trained on VM data would
     learn exactly the wrong lesson here; priors for kvp726 must be weak.

### 5.2 Stability across the sampling window

- Within round 1 (≈35 min), healthy hosts were **consistent** (repeat calls
  within ±≈0.3 s of their medians; KK-A detail spread was only 0.73–0.91
  across 5 different titles).
- Across rounds, the shared-path drift (+~1 s, §5.1.1) moved everything
  together; the CacheVideo resolver moved *against* the trend (4.99→2.01 s),
  showing it carries large variance of its own on top of the path.
- **Bimodality is the system's signature.** Sources are either at their
  healthy median or entirely absent (404 geo-wall / TLS-then-silence hang).
  No source was observed in a degraded middle state (e.g. 5–10 s responses)
  at any point. A predictor therefore gains little from fine-grained latency
  regression on the failure side — the valuable signal is *which mode* a
  host is in.
- Time-of-day: only one window was sampled (01:00–02:00 CST / 14:00–15:00
  VN); the within-window drift is the only temporal evidence. No day/night
  claim is made. [U]

### 5.3 Do failures cluster, or are they independent per request?

**Failures cluster — by host, and they persist.** v1.streamvsmov hung on
2/2 attempts ≈45 min apart; v6 hung on its only attempt; v8/v9 succeeded
4/4; kvp726 404'd 6/6 from this vantage. A per-request independence model
would be flatly wrong: one hang from a host predicts the next hang from the
same host far better than the base rate does. Failures also cluster by
*class*: the hang class lives at the resolution stage (embed pages), while
answering failures (404s) are fast everywhere — a host that answers at all
answers quickly, including its refusals.

One correlation warning [inference, labelled]: TP-Gold and VS segment URLs
share the same `…/file/<b64>/tiktok/<uuid>/file-tiktok_N.png` scheme — the
Gold layer and VSMOV appear fed from the same file-store system, so a
VS→TP-Gold hop may not be as independent as the provider list suggests.
(The sampled files themselves were different objects; this is a scheme-level
observation, not a proven shared backend.)

### 5.4 Recommended predictor granularity and stat shape [derived]

- **Granularity: per (provider × stage × host)**, with host keyed at the
  level where behaviour actually splits:
  - `streamvsmov.com` → **per subdomain** (v8 ≠ v1 categorically);
  - `blogcdn.site`, `tiktokcdn.com`, `kvp726.com` → per registrable domain
    (subdomains rotate per title / per release and behaved as one family);
  - KK → per API host (A ≠ B ≠ C); other APIs are single-host per provider.
  - Stages kept as **separate stats** (API / resolve / playlist / segment
    TTFB): stage distributions differ more than provider distributions do
    (TP: API 1.44 vs segment TTFB 2.68 median, 6.0 max).
  - Plus **one global path baseline** (EWMA over all recent requests) so a
    tunnel-wide slow-down is not misread as every source dying at once.
- **Latency stat: EWMA with a half-life of ≈10 minutes.** Justification:
  healthy medians were stable over ≈35 min but the shared path moved
  measurably within ≈50 min; a much longer memory would chase stale
  conditions, a much shorter one would chase noise (per-call jitter ±0.3 s).
- **Failure stat: a latch, not a rate.** ≥2 consecutive timeouts (or
  timeout + 5xx) on a host → demote that host for a **15-minute window**,
  then re-probe with a single request. Justification: failures are sticky
  stretches (§5.3) and bimodal (§5.2) — the predictor's job is mode
  detection ("this host is in its dead mode") with a re-probe timer, not
  probability estimation. The fuse (timeout) per host should be set from
  the latency EWMA: fuse ≈ max(3 × EWMA, EWMA + 4 s), floored at 6 s —
  every healthy stage in this audit completes within 3× its median except
  TP segment TTFB (2.2×) and the CV resolver (1.5×), so a 3× fuse never
  fires on a healthy source in-sample, while a hang is declared in
  ≈4–8 s instead of 20–35 s.
- **Cold-start priors:** the §1 medians, with **low prior weight
  (≈ n = 3 equivalent)** so on-device evidence dominates within a few
  plays — mandatory given the vantage warning (kvp726's prior must not be
  allowed to convict it on-device). streamvsmov subdomains start
  *unknown*, not healthy: first use of an unprobed subdomain should race
  or be fused at the global 8 s resolve fuse (§6) until it earns a stat.

---

## 6. RECOMMENDED CONSTANTS (each with its derivation)

Derivation rule used throughout: a fuse should sit at ≈3–6× the slowest
*healthy* observation of the stage it guards — high enough to never fire on
a healthy source, low enough that the hang class costs seconds, not tens of
seconds. Healthy maxima below are from §1 (round-1; round-2's path inflation
is inside the 3–6× headroom by construction).

### tvOS

| Constant | Now | Recommended | Derivation |
|---|---|---|---|
| VS `resolveStream` timeout | 25 s (JoeHTTP default) | **8 s** | healthy embed max 1.26 → 6× headroom; cuts the v1/v6 hang declare 25→8 s |
| TP Gold embed (`getNoRedirect`) | 20 s | **8 s** | healthy max 1.68 → ~5× |
| CacheVideo resolve | 15 s | **10 s** | healthy range 2.0–5.4 (widest legit spread) → ~1.9× max; 8 s would clip real successes |
| Torrentio `fetchStreams` | 35 s | **15 s** | healthy max 1.17; public service with load spikes → keep generous 13× median |
| Detail timeout (KK/VS/F4K) | 25 s | **10 s** | healthy max 1.87 → >5×; cuts hang cost inside refresh/hop |
| TP detail | 20 s | **split: API 10 s + CV probe 10 s** (keep 20 s total only if the split is invasive) | API max 1.54; probe max 5.40 — each stage gets its own honest fuse |
| List/search | 12 s | **keep** | healthy ≤2.5 even path-inflated |
| `findAlternatives` overall | unbounded (≤6 searches × 12 s) | **12 s deadline** | measured typical 2.7–5.7 s of searches |
| Pre-ready stall watchdog | 20 s | **keep** | slowest healthy proxied envelope ≈13 s (TP+CV); 20 s is the right outer bound *after* resolution fuses shrink |
| **Mid-play freeze watchdog** | **none** | **add: 12 s** of no position advance while playing → failover | Android parity is 15 s; 12 s = 2 missed segments at the 6 s cadence of VS/TP/CV |
| JoeProxy serve-wait (segments) | 35 s | **90 s stopgap + stream-through as the real fix** | F4K segments reach 66 MB; below ≈15 Mbps the store-and-forward cannot finish in 35 s → guaranteed 502 on healthy-but-slow links |

### Android

| Constant | Now | Recommended | Derivation |
|---|---|---|---|
| Resolve-class read timeouts (VsApi embed, TpApi embed, CacheVideo) | 20 s | **8 s** (CV 10 s) | same healthy maxima as tvOS |
| Detail/API read timeout | 20 s | **12 s** | healthy max 1.87; the KK exception is structural (next row) |
| KK host chain | 4 hosts sequential (≤128 s worst) | **drop host C** (stub-only, 0.78–0.96 s of pure waste when reached) **+ 15 s total cap across hosts** (or adopt tvOS's parallel race) | C can never succeed (live-verified stub); sequential hang cascade is the worst derived number in the system |
| `STALL_LIMIT_MS` | 12 s | **keep** | ≈4× the worst healthy segment TTFB (TP 2.68 median / 6.0 max is playlist-stage, not segment-fetch); two-stall rule retained |
| `POSITION_STALL_MS` | 15 s | **keep** | 2.5 segments at 6 s cadence |
| `LAST_RESORT_RETRY_MS` | 25 s | **keep** | background retry, not on the user's critical path |
| RetryPolicy (404-class no-retry) | as-is | **keep** | measured segment-404 declare is 1.4–2.2 s at HTTP level; in-source retry would only delay the ladder |

### Expected effect [D]

| Scenario | Before | After tuning |
|---|---|---|
| tvOS, VS title on a hanging embed host | ≈32 s to substitute | ≈1.3 + 8 + ≈5 ≈ **14–15 s** |
| Android, same | ≈27 s | ≈1.4 + 8 + ≈5 ≈ **14 s** |
| Android, KK call, hosts hanging | up to ≈128 s | **≤15 s** (cap) |
| tvOS, mid-play silent stall | **unbounded** | **12 s** declare → ladder |
| Healthy starts | unchanged | unchanged (no fuse sits inside any healthy envelope) |

A single global stall number is **not** the honest answer for the
*resolution* stage — the stages' healthy maxima differ by 4× (embed 1.26 s
vs CV resolve 5.40 s), so per-stage fuses (above) are justified. For the
*playback* stage, one global value per platform **is** honest: segment
TTFB clusters at 1.0–2.8 s across all sources, and Android's existing
12 s/15 s pair already sits at the right multiple.

---

## 7. Numbers only the device can confirm (hand-off list)

- **O-1 · KK full chain through the tunnel** (Sony + Apple TV): playlist and
  segment TTFB/total on `a.kvp726.com` from a Vietnam-exit vantage. The
  entire KK envelope below the API is open.
- **O-2 · streamvsmov v1/v6 through the owner's tunnel:** do they hang there
  too, or is the black-hole a US-vantage/geo effect like kvp726's 404s?
  Decides whether the 8 s resolve fuse is a daily tool or a rare guard.
- **O-3 · AVPlayer time-to-first-frame per source on the Apple TV**,
  especially F4K through the store-and-forward proxy (11–66 MB segments)
  and TP with the CV probe in the detail path.
- **O-4 · TMDB keyed-call latency** (`external_ids`, detail) on-device —
  the rung's first leg. VM floor (401 path probe): ≈0.9 s.
- **O-5 · RD resolve + RD CDN start latency** with the owner's token
  (token-gated; never measurable from this VM). The Sony's ≈20 s
  end-to-end substitution observation bounds the sum.
- **O-6 · ExoPlayer time-to-first-frame per source on the Sony**, and the
  real-world frequency of the KK sequential-host cascade (does phimapi
  ever hang, or only fail fast?).
- **O-7 · Mid-play stall behaviour of AVPlayer** on a silently hanging
  segment (how long until AVPlayer errors on its own) — sizes the true
  exposure behind the recommended 12 s freeze watchdog.

---

## Honesty declaration

- **Claims:** every number in §1–§3.1 was produced by a request this team
  sent during the audit window, following the apps' own endpoints/headers/
  chains; §2 envelopes are arithmetic sums of those measured steps (the
  exact steps summed are named per source); §3.2/§3.3/§4/§6 are derived
  from code constants read in the two repos plus the measured parts, and
  are labelled [D]; §5's structure claims rest on the two-round,
  126-request dataset described.
- **Evidence:** raw per-request records (label, URL, HTTP code, DNS /
  connect / TLS / TTFB / total / bytes, timestamp) retained in the team's
  working files; response bodies for every catalogue, detail, embed and
  playlist step retained alongside; the v1/v6 hang localisation (TLS
  complete ≈0.26 s, TTFB = 0 at 30 s and 45 s caps, 3 attempts) is in the
  raw records; code citations for every constant are in §4's source files.
- **Unverified, labelled:** KK below the API from any vantage (§1.1) [U];
  RD/TorBox resolution and RD CDN playback (§1.6) [U] — no token was
  available and none was sought; TMDB keyed calls (§1.7) [U] — keyless 401
  probes measure the network path only; the leader's ≈20 s Sony
  substitution figure is a reported on-device observation, not this team's
  measurement; Android host D's API flavour was not exercised (bare-path
  probe returned the web page); the TP-Gold/VS shared-file-store remark in
  §5.3 is a scheme-level inference, not a proven backend identity;
  time-of-day effects rest on a single ≈1-hour window; all absolute
  latencies carry the VM-vantage warning in the header — the on-device
  predictor must be free to overrule every prior herein, which is why
  §5.4 assigns them low weight.
