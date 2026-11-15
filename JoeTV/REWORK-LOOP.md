# Joe TV tvOS — REWORK LOOP BOARD (leader-maintained, 2026-11-15)

Owner order (00:04 CST): UI is wholly broken; review the UI foundation first.
Four teams, ONE closed loop: Team 3 design-requirements analysis (Apple TV 4K)
→ Team 1 UI rebuild + Team 2 core check/fix → leader re-check loop until 100%
clean → ONE build → Team 4 product validation of the built IPA → only then
the owner tests. Nothing reaches the owner mid-loop.

## Device evidence (owner photo of v1.8, 23:58 CST 2026-11-14)
1. Whole screen renders BLUE (diagonal, bright bottom-right) although the
   shipped gradient was near-black.
2. Pale CYAN blob, larger than the pill, covers the focused TV pill, text
   washed out — although .focusEffectDisabled(true) is in the shipped code.
3. Phim home: "Đang tải thư viện phim…" spinner forever, ZERO rails.

## Auditor A findings (visual/focus) — CONFIRMED from code
- JoeTheme.background is the ONLY full-screen painter; its "black" stops are
  blue-biased (B ≈ 1.18× R/G; #1B1B20 itself has B=0x20 > R=G=0x1B), brightest
  bottom-right = the photo's pattern. FIX: solid Color.black (hue-free).
- The blob is NOT app-drawn (pill focus rendering = fill behind label + inner
  stroke + scale 1.06; no shadow; JoeFocusRing unused on pills). It is the
  system focus effect; the root-level .focusEffectDisabled(true) did NOT
  suppress it on the owner's tvOS (Liquid Glass). FIX: per-view modifier on
  every focusable; contingency = non-Button .focusable() chrome.
- JoeTheme.swift header comment (lines 3-11) is stale (retired indigo design).

## Auditor B findings (data/network) — CONFIRMED from code + VM measurement
- Launch = 24 concurrent jobs, up to 58 requests; 17 are KK jobs each with
  SEQUENTIAL 3-host failover × 25 s. NO overall deadline: `loading` clears
  only when the slowest job ends; the error+retry UI is unreachable until
  then. Worst case ~2-4 min of spinner on a hanging route.
- hasData = merged/kkNew only; empty-but-valid responses count as success,
  loadedAt stays unset → every return to the tab re-fires the full storm.
- PhimStore has NO disk cache; the TV section (TVStore) is cache-first,
  single friendly host (GitHub raw), visible failure status — the model to copy.
- All provider endpoints answer from the VM with parser-valid JSON
  (KK A/B, VS, F4K, TP all 200, ~0.7-1.6 s). KK host C (free2.phim4k.dev)
  returns the {"status":false} 404 stub for list calls from the VM — dead leg.
- Errors are discarded by try? everywhere — no failure can ever be diagnosed.
- UNVERIFIED: the ATV's actual Sing-box profile/routing (leading hypothesis
  for zero rails on device); tvOS connect-phase timeout behaviour.

## File ownership (no cross-editing)
- Team 1 (UI): JoeTVApp.swift, JoeTheme.swift, JoePhimHome.swift,
  JoeTVSection.swift, JoeMovieDetail.swift, JoeTorrent.swift (views),
  JoeSearch.swift, JoeSettings.swift, JoePlayerView.swift.
- Team 2 (core): JoeStores.swift, JoeHTTP.swift, KkClient.swift,
  VsClient.swift, F4kClient.swift, TpClient.swift, Providers.swift,
  JoeModels.swift, TMDBClient.swift, project.yml, NEW file SourceProbe.swift.
- Team 3 (design): writes ONLY DESIGN-SPEC-V19.md.
- Leader: pushes, builds, version bumps, this board.

## Store → view contract (both teams build to this exactly)
- PhimStore gains `@Published var loadTimedOut = false`: set true when a
  load has run 20 s with hasData still false; cleared when data lands or a
  new load starts. JoePhimHome shows the error+retry block when
  `phim.loadTimedOut || (!phim.loading && !phim.hasData)`.
- SourceProbe (Team 2) exposes per-provider probe results for Settings;
  Team 1 renders them in JoeSettings.swift via the agreed type:
  `SourceProbe.run() async -> [SourceProbe.Result]` with
  `Result { name: String; ok: Bool; millis: Int; note: String }`.

## Standing owner laws (all teams)
- NO white/pale focus styling anywhere; focus is app-drawn only (violet
  outline/fill on the element's own shape). .buttonStyle(.card) is BANNED.
- Background: hue-free black. Real JOE TV logo in the top bar.
- The two Apple TV apps (Joe TV vs Đá Banh TV) must look clearly different.
- Anything Muse can fill in, the owner never types (TMDB key is bundled
  via build-time secret — already working, do not regress it).
- A movie app whose links don't play is not a movie app: loading must
  always resolve to content, a visible error, or a cached library —
  never an endless spinner.

## Auditor C findings (full A-Z sweep) — CONFIRMED from code
- C-1 HIGH: the v1.8 Phim retry button is UNREACHABLE by remote in the
  total-failure state (header trap DOWN targets phimRails.first — empty —
  and the trap consumes the move). The fix shipped last night has a hole.
- C-2 HIGH: Torrent search results are a multi-row grid routed as a flat
  rail — DOWN is swallowed, vertical browsing of results is broken.
- C-3: duplicate focus identities — same movie in several rails shares
  movie.id, so multiple cards light up as "focused" at once; same class
  in detail episode chips (ep.name repeats per server) and torrent rails.
- C-4: Torrent home has NO loading indicator, NO error state, NO retry.
- C-5: TorHomeStore genre rails all-or-nothing, sequential, and a failed
  refresh WIPES previously good rails.
- C-6: Tủ Phim favourites keyed "kk|…" in WatchStore (collision with KK).
- C-7: TorrentClient genre URL unencoded ("Science Fiction" has a space).
- C-8: Phim error block can render under healthy rails (hasData too narrow).
- C-9: detail provider-switch failure leaves a silent hybrid page.
- C-10/C-11: torrent search + torrent detail failures are silent, no retry.
- C-12: stale comments (JoeTheme header, TMDBClient header, detail/search).
- C-13: Settings TMDB field doesn't reflect the bundled key (copy defect).
- C-15: unsynchronised static mutable state (KkClient.activeHost,
  Providers.altCache) written from concurrent tasks.
- C-16: JoeProxy routes never evicted; playlistURL can block up to 3 s.
- C-17: TV-section focus edges (empty-group entry, DOWN clearing focus).
- U-1: neither player has a stall watchdog (black screen can sit forever).
- Verified good: .card is gone from code; versions consistent; icon/logo/
  TMDBKey wiring correct; TVStore is the model citizen; PlayDirector and
  detail load-failure states terminate properly; JSON-null law is real code.

## Ownership update (supersedes the list above where they differ)
- Team 1 (UI): + JoePlayerView.swift (incl. U-1 stall watchdog).
- Team 2 (core): + WatchStore.swift, TorrentClient.swift, JoeProxy.swift.

## ★ NEW DEVICE EVIDENCE — SEVERITY 1 (owner, 2026-11-15 00:08 CST)
"v1.8 làm chính Apple TV freeze. Bấm rất nhiều lần mới thoát được về home."
The app doesn't just spin — it makes the whole Apple TV feel frozen and
fights the user's exit (many Menu presses needed to reach Home).
NEW STANDING REQUIREMENT for every team: the app must NEVER impede exit
or saturate the main thread/focus engine. Prime suspects to prove or clear:
(a) the exit/Menu handling (JoeExitTrap / onExitCommand) consuming Menu
presses at root; (b) a launch focus loop (hub nonce + traps re-assigning
focus cyclically); (c) main-actor blocking (JoeProxy semaphore wait,
parsing/publishing churn); (d) infinite view invalidation. Menu at root =
the app exits immediately, no trap, no dialog. Every focus request must
be idempotent and terminating.

## Team 3 — DESIGN-SPEC-V19.md DELIVERED (2026-11-15 ~00:10 CST)
Binding decisions: solid Color.black, gradients banned target-wide (pixel
test: no pixel with B-R > 2); top-bar pills = .focusable() views (F2);
focus IDs namespaced per rail instance (F4); grids move geometrically,
only a grid's first row may carry a boundary trap (F5.5); error Retry is
the hub DOWN target when a section is empty (F5.6); 20 s ceiling on any
blocking spinner (G1); margins 80/60 (HIG safe area); type floor 23 pt
(current 15-21 pt meta/badge/footnote text = violations); poster card
240x360; detail backdrop strip frozen 1760x540 r18; 25 pass/fail
acceptance items for Team 4 with method tags [CODE]/[SHOT]/[TIME]/[NAV].
Labelled unverified: HIG type floors from secondary summaries (Apple's
pages didn't yield extractable text this pass); F2's tap-on-focusable
behaviour to be proven by Team 1 in the build, F9 is the fallback.

## Team 4 — APPLE-CONFORMANCE.md PHASE 1 DELIVERED (2026-11-15 ~00:12 CST)
- Owner's box (inference, high confidence): Apple TV 4K 2nd gen+ on
  tvOS 26/27 (likely 27.2.x). Focus/glass behaviour follows runtime OS +
  linked SDK, NOT the deployment target. CI (macos-latest) = Xcode 27 /
  tvOS 27 SDK line; UIDesignRequiresCompatibility is IGNORED on tvOS 27
  SDK — do NOT add it (B-2). Keep minOS 17.0 (B-3).
- Blob mechanism (HIGH confidence): the tvOS 26/27 Liquid Glass focus
  treatment attaching to focused Buttons — a different path from the
  pre-26 focus effect. Field fixes that worked: per-view modifier +
  custom ButtonStyle / non-Button .focusable() chrome. Team 1's F1/F2
  direction is confirmed.
- Exit standard: Menu exit requires pressesEnded to reach UIApplication;
  a ROOT-LEVEL .onExitCommand captures every Menu press in the app —
  at root the only correct behaviour is to NOT consume it. .onMoveCommand
  likewise consumes directions it doesn't release (C-1/C-2 shape).
- Source verdicts: KK direct HLS FITS (HEVC-in-TS titles unplayable by
  rule — ladder handles). JoeProxy paths FIT WITH CONDITIONS: add
  NSAllowsLocalNetworking (B-1, project.yml — Team 2); bind the proxy
  LOOPBACK-ONLY (it currently listens on ALL interfaces = unauthenticated
  LAN relay — security defect); serve detected-payload MIME types;
  route eviction; semaphore wait REMOVED (hard gate G-EXIT-4).
  Torrentio/RD FITS WITH ONE CHECK: AVPlayer cannot play MKV/AVI —
  Team 2 must settle whether selection filters/marks containers (B-5).
- Phase 2 gates P-0..P-F defined in APPLE-CONFORMANCE.md §7, incl.
  P-C exit/responsiveness hard gates and P-E device gates that must
  NEVER be desk-passed (leader reports them as unverified until the
  owner observes them on his box).

## Team 2 (core) — DELIVERED (2026-11-15 ~00:17 CST)
All 14 backlog + 3 freeze-proofing + 5 Team 4 items implemented in the
working tree. Headlines: loadTimedOut watchdog per contract; 12 s list
budgets; KK hosts RACED (first shape-valid wins), host C DROPPED on live
evidence (all variants return the status:false stub); phased launch under
a 4-permit AsyncGate (~12 connections max, was 24 jobs/58 requests);
PhimRailCache disk cache (raw JSON per rail, hydrate → publish → refresh);
loadedAt on ANY rail; providerErrors published per provider; SourceProbe
probes through the real client calls; TorHomeStore genre rails progressive
+ never wiped; WatchStore tp| favourites; genre qenc; NSLock on the two
statics; JoeProxy: loopback-only bind, detected-payload MIME, 512-route
cap, readySem DELETED (playlistURL never waits; one bounded 35 s wait
remains confined to the proxy's own queue — flagged for Team 4);
torrent container rule added (mkv/avi/... marked unplayable at selection;
unknown stays playable); ATS NSAllowsLocalNetworking in the JoeTV target
ONLY (team caught its own wrong-target edit and fixed it). UNVERIFIED:
no Swift compiler on the VM — CI build is the first real compile.

## Team 1 (UI) — DELIVERED (2026-11-15 ~00:22 CST)
Severity-1: exit path proven clean in root state (JoeExitTrap installs NO
.onExitCommand when disabled) + ONE REAL BUG found & fixed: the searchOpen
state leak — search opened in Phim, UP to pills, switch section → trap
stayed armed on an invisible layer and ate the next Menu press (a concrete
"Menu does nothing" mechanism). Fixed via .onChange(of: section) clearing
nav.searchOpen. Launch focus write-graph is a DAG (no cycle). No blocking
calls in view files. Team 1's JoeProxy-semaphore flag is RESOLVED by
Team 2's deletion of readySem.
Phase 1+2 done: solid black; per-view focusEffectDisabled everywhere +
F2 focusable pills (hub contract intact); C-1 retry reachable (DOWN routes
to Retry when empty; display per loadTimedOut contract); C-2 search grid
arithmetic moves; C-3 F4 namespaced focus IDs; C-4 torrent home states;
C-8 catalogueEmpty gating + providerErrors cause lines; C-9 switch-failure
revert + notice; C-10/C-11 torrent search/detail failure surfaces; C-13
TMDB status line; C-17 TV focus edges; U-1 20 s player stall watchdog;
spec alignment (80/60 margins, 23 pt floor — zero sub-23 fonts remain,
240x360 cards, LIVE badge the only sanctioned red).
FLAGGED FOR TEAM 4 RULINGS: (a) Torrent .sectionTop lands on the search
FIELD (established) vs spec F5.3's "search button" wording; (b) player
exhausted slate = "Thử lại"+"Quay lại" (no untried source exists) vs
spec's "Thử nguồn khác"; (c) 20 s/watchdog vs spec's 30 s slate clock on
multi-source ladders; (d) all-empty-after-success shows G3 not G5;
(e) TV tile name moved INSIDE the tile per spec §7.5 (supersedes v1.5);
(f) TV tiles still key focus on unscoped channel.id (shared code) —
residual C-3 class; (g) TVPlayerView Menu handling never audited
(shared DaBanhTV file, outside Team 1 ownership).
Leader spot-checks: changed files all inside team ownership; contracts
resolve both sides (loadTimedOut, providerErrors, SourceProbe);
readySem = 0; ATS present once; focusEffectDisabled across all view files.

## Team 4 PRE-BUILD SOURCE GATE — VERDICT: FAIL (2026-11-15 ~00:28 CST)
Everything passed EXCEPT two blocking items, both in the state/deadline
layer. The gate worked as designed: no build until these close.
- BLOCK-1: Torrent home has no 20 s deadline and its error surface is
  UNREACHABLE in the dead-route case: discoverCatalogs never returns
  empty (Cinemeta fallbacks) → hasData always true → error can never
  fire; worst case ~100 s of bare header. Fix: TorHomeStore loadTimedOut
  watchdog (Phim-identical); surface keyed on RAILS not hasData;
  loadedAt only when ≥1 rail landed; Retry must force a real reload.
- BLOCK-2: Phim all-empty-after-success renders G3+Retry; spec says G5
  ("Thư viện chưa có dữ liệu.", no Retry). Predicate per Team 4: spinner
  while loading && !loadTimedOut; G3 when loadTimedOut OR load ended
  with providerErrors non-empty; G5 when load ended empty, providerErrors
  empty, no timeout. Ruling (d) SPEC-WINS.
- PASSED: P-B (hue-free, focus inventory, .card=0, proxy/torrent code),
  P-C G-EXIT-1..5 (focus DAG, root Menu path clean incl. searchOpen fix,
  one-press-per-level, semaphore confinement real, C-1 retry reachable),
  all A/B/C regressions FIXED-VERIFIED incl. disk-cache corruption
  safety; seams; project.yml. Rulings: (a)(b) CODE-WINS (spec text
  corrected), (c)(e) ACCEPTABLE, (f) non-issue (Channel.id = UUID per
  instance), (g) TVPlayerView Menu OK; its missing stall watchdog is a
  recorded residual (shared code, separate decision).
- Minors folded into the fix round: accentViolet.opacity(0.45) fills →
  spec token; .green → okGreen (3 sites); gate both homes' error
  surfaces on "a load has been attempted" (kills the cold-entry flash);
  JoeStores parse-actor comment accuracy.

## FIX ROUND — BOTH SIDES DELIVERED (2026-11-15 ~00:32 CST)
Core fixer (JoeStores.swift only): TorHomeStore loadTimedOut watchdog
(trip predicate !hasAnyRail — catalogue or genre rail with metas);
loadedAt stamped ONLY at rail-landing sites (old hasData stamp deleted);
reload() added (bypasses freshness guard; respects the in-flight guard —
flagged for the re-gate to rule); parse-actor comments corrected.
UI fixer: BLOCK-2 predicate implemented verbatim (spinner / G3 / new G5
"Thư viện chưa có dữ liệu." 29 pt, no Retry; G5 DOWN = defined no-op,
stated in a comment); BLOCK-1 view side keyed on rails (torCatalogueEmpty),
Retry → store.reload(), timeout-aware copy, "Chưa có danh mục nào."
reserved for the honestly-empty state (currently unreachable given the
Cinemeta fallbacks — reasoning in the file); minors done (surface/okGreen
tokens — JoeTheme gained the two token definitions; attempted gates on
both homes). Disclosed interpretation: Phim spinner keeps its
catalogueEmpty gate (spec §8/G4 justification) — re-gate to judge.
Disclosed residual (not fixed): with EXACTLY ONE owner rail (CW/fav)
while the catalogue fails, the first-rail trap eats DOWN and the G3
Retry is unreachable by remote (≥2 owner rails: reachable geometrically;
zero rails: reachable per C-1). Re-gate must rule: blocking or recorded.

## Team 4 RE-GATE — VERDICT: FAIL, ONE blocking item (2026-11-15 ~00:34 CST)
Scopes 1 (BLOCK-1), 2 (BLOCK-2), 4 (minors), 5 (compile-risk) all PASS,
verified by Team 4's own reads. Rulings: reload() in-flight-guard
semantics ACCEPTABLE; Phim spinner catalogueEmpty gate ACCEPTABLE;
G5 DOWN no-op ACCEPTABLE; torrent G5 folding ACCEPTABLE.
BLOCKING — Scope 3 (the disclosed one-owner-rail residual is REAL in
both homes): with exactly one owner rail (CW/fav) + dead catalogue, the
first-rail trap eats DOWN and the G3 Retry is unreachable. Required end
state (Team 4, precise): in handleFirstRailMove .down — count>1 → next
rail (unchanged); else if the error surface is visible → focus the
Retry (retryFocused / torRetryFocused); else defined no-op. Return
trips already exist. Fix dispatched to the UI fixer.
Leader folded in Team 4's non-blocking observation (same C-5 class,
one guard): TorHomeStore's catalogue loop assigned rails[key] = metas
even when empty, able to overwrite a good rail on refresh — now must
preserve the previous rail on empty results, matching the genre path.

## FINAL FIXES DELIVERED (2026-11-15 ~00:36 CST)
Scope-3 trap fix (UI fixer): both handleFirstRailMove .down branches now
implement Team 4's end state verbatim (count>1 → next rail; else
error-visible → focus Retry; else defined no-op); round trips traced
closed in both homes. Catalogue preserve guard (core fixer): TorHomeStore
catalogue loop assigns only on non-empty success; both loadedAt stamps
verified unmoved. Leader will refresh two stale doc comments
("(no-op when there is no next rail)") before push — comment-only.
Awaiting Team 4 final micro re-check.

## OWNER DIRECTIVE — SELF-SUBSTITUTING SOURCES (2026-11-15 ~00:40 CST)
Anh's ruling, verbatim sense: the problem is not whether a link is dead;
when a link dies the app must FIND A REPLACEMENT. A proper app is always
ready. In the Phim section, if a title's links are missing/stalled/dead,
the app flexibly pulls the TORRENT link for the SAME title as the
substitute — identity is by the movie's ID. The app must query the other
source itself and produce the replacement link immediately.
Design (leader): the substitution rung joins PlayDirector's ladder as
the FINAL automatic rung. Chain: Phim detail already carries the TMDB
id → TMDB external_ids gives the IMDB id → Torrentio streams keyed by
that IMDB id (series: imdb_id:S:E from the selected episode) → existing
container rule filters unplayables → Real-Debrid unrestrict → same
player. Triggers: (a) every Phim provider fails to resolve/play a title;
(b) mid-play stall via the existing 20 s watchdog exhausting the Phim
rungs. Only if the torrent rung also fails does the exhausted slate
appear. Matching is by ID ONLY — never by title text.
Status: v1.9 push was DECLINED by anh at the approval card (he saw the
build going to the dabanh repo and stopped it to give this directive
first). Nothing pushed, nothing built. Awaiting his call: fold the
substitution rung into this loop before the one build, or build v1.9
as-is and do the rung next.

## SUBSTITUTION RUNG — anh approved folding it into this loop (00:41 CST)
Leader seam survey (code-read): Movie.tmdbId exists, populated by
KkClient from KK's tmdb object; TMDBClient.fetch uses it for enrichment
only (no external_ids call yet — imdbId lookup must be added).
TorrentClient.fetchStreams(addonBase:type:id:) already implements the
Torrentio stream call and the configured base already embeds his
Real-Debrid/TorBox config. PlayDirector is built by
JoeMovieDetail.makeDirector with resolveLadder + ONE hopIdentity; the
rung will be an additive final fallback closure on the director,
invoked only after ladder + hop are exhausted (covers both triggers:
initial resolve failure and the mid-play stall watchdog, which already
advances the same ladder). Identity: tmdbId from the current detail,
else from the KK alternative's detail (the hop's findAlternatives
already locates it); no tmdbId anywhere → rung honestly inert.
Series episode id = imdbId:season:episode (episodeNumber exists;
season parsed from the episode name when present, else 1).

## OWNER EXTENSION — the ladder applies to ALL platforms (00:43 CST)
Anh: "Các nấc nguồn sẽ áp dụng toàn bộ cho các hệ máy môi trường như
tv sony và bản cập nhật cho cả tvbox." So the substitution ladder
(incl. the torrent rung) is a cross-platform standard: (1) tvOS —
in flight now; (2) Sony Android Joe TV — same rung ported to the Java
app, leader device-verifies on the Sony himself; (3) dad's TV box —
same Android APK as an update kit for anh to install when he has the
box in hand; NO remote work on the box at dad's house, ever (standing
rule). Order: tvOS rung passes Team 4 → port to Android → Sony verify
→ APK + box kit delivery.

## SONY SESSION LIVE + ANDROID PORT STARTED (2026-11-15 ~00:49 CST)
Anh reopened the Sony and re-prioritised: Sony-direct work FIRST; TV
stays AWAKE through the whole workflow; sleep only when everything is
certainly done (his restated rule). Leader connected via the relay:
BRAVIA 4K AE2, Android 14, Awake, com.gathin.tvapp running — identity
verified. (His photo: Wireless debugging still Enabled, Living Room
TV, 192.168.68.72 — the pinned 5555 channel answered.)
tvOS rung: IMPLEMENTED (director failoverStep third step: refresh →
hop → torrent rung → exhausted; retry re-runs it; shared TorrentClient
builder now serves both play paths; identity via detail imdbId (TP) or
tmdbId → KK-alt hunt → TMDB external_ids; season = name-parse ??
tmdbSeason ?? 1). Going to Team 4 gate in parallel (desk work).
Android survey DELIVERED (full seam map in the surveyor's report):
PlayerActivity failover chain is richer than tvOS (tries → refresh →
hop → last-resort); rung hooks as a new step at the 3 decline sites;
identity fields exist unevenly (KK=tmdbId, TP=imdbId+tmdbSeason,
VS/F4K=none → derive via KK alternative or stay inert); TmdbApi needs
external_ids added; NO container rule on Android (URL-presence only,
MKV plays); torrent orchestration is UI-welded → auto-pick loop must
be written; torrent win must force buildFactories(true)/directNet.
LEADER DECISION (CW identity, Android): follow the ANDROID hop
convention — the CW entry migrates to the winning torrent identity
(tor| key, KIND_TOR), exactly as provider hops already behave on this
app; tvOS keeps its own ruling (platforms keep their own convention).

## Team 4 GATE on the tvOS substitution rung — PASS (2026-11-15 ~00:50 CST)
All six scopes verified in code: trigger only at true exhaustion from
all three paths incl. the stall watchdog; latches, re-arms on retry;
nil-fallback sessions + pre-rung Phim behaviour unchanged; shared
builder equivalence structural (no local git to byte-diff — labelled);
identity ID-only end to end; container rule + single-RD bound; CW
identity preserved. tvOS v1.9 is now FULLY gated and ready to push +
build. P-E device gates remain unverified by design.

## OWNER DIRECTIVE — MEASURED LATENCY TUNING (2026-11-15 ~00:52 CST)
Anh: dispatch a team to audit the LATENCY of every source so switching
happens in time — never wait until the failure shows on screen. All
tuning from REAL NUMBERS: the exact wait budget for "one movie gets a
playable source". A measurement team is dispatched (VM-side, following
the apps' exact request paths) to produce per-source numbers: detail
API latency, playlist TTFB, first-segment TTFB, est. time-to-playable,
failure-declare latency per failure class, and chain-step timings
(findAlternatives, Torrentio fetch, TMDB external_ids). Output =
recommended watchdog/timeout constants per platform (tvOS 20 s stall
watchdog + request budgets; Android 12 s/15 s stall limits), set at
the healthy-start envelope (~p90 + margin), per source where variance
justifies it. Tuning lands BEFORE the tvOS build and as a constants
pass on Android before the leader's on-Sony verification.

## OWNER DIRECTIVE — INTELLIGENT PREDICTION LAYER (2026-11-15 ~00:53 CST)
Anh: "Phải đưa hệ thống thông minh vào dự đoán nó để nó hoạt động
chính xác" — static tuned constants are not enough; the app must
PREDICT per-source behaviour so switching is accurate. Leader design:
an on-device per-source health model (persisted rolling stats:
time-to-playable EWMA, failure rate by class, last-seen timestamps,
with time decay). It drives three things: (1) ladder ORDER by
predicted time-to-playable; (2) predicted-dead sources get a short
fuse instead of the full wait; (3) the stall watchdog becomes
per-source (its own predicted envelope + margin). Cold start priors =
the latency team's measured numbers; the model then adapts to the
owner's real network (tunnel/ISP), which no VM measurement can see.
This is statistics learned on-device, not guesswork. Sequencing:
measurement team (running, asked to also report variance structure)
→ predictor design → implement on both platforms through the same
gates → tvOS build stays ONE build, after the predictor passes;
Android predictor pass lands before the leader's final on-Sony
verification build.

## LATENCY AUDIT — DELIVERED 2026-11-15 01:07 CST (LATENCY-AUDIT.md, 126 timed requests)
- Answering failures declare in 0.8–2.2 s everywhere. The only slow failure is the SILENT HANG: v1/v6.streamvsmov.com black-hole VS embed fetches (TLS ok, 0 bytes ≥45 s, 3/3 over ~50 min); v8/v9 answer ~1.1–1.3 s. Client timeout constants ARE the switch speed.
- Healthy time-to-playable (VM medians): VS ≈4.9 s (tvOS 6.5 via proxy) · F4K ≈5.1 direct but tvOS ≈11.5 med / 28.7 worst (proxy store-and-forwards 11–66 MB segments) · TP Gold ≈7.3 (+3.6 when CV probe fires; CV resolves TWICE — waste; CV median 3.57, ~1/5 titles) · Torrentio list ≈1.0 · KK below API UNMEASURED from VM (kvp726 geo-wall 404s; API leg 0.90 med host A) · TMDB keyed + RD UNMEASURED by rule.
- GAPS: tvOS mid-play silent stall UNBOUNDED (watchdog cancels at readyToPlay) — parity gap vs Android · Android KK worst ≈128 s (4 hosts × 32 s sequential) · tvOS VS hang case ≈32 s to substitute → ≈14–15 s tuned.
- TUNING (per-stage fuses ≈3–6× slowest healthy stage): tvOS VS resolve 25→8 · TP embed 20→8 · CV 15→10 · Torrentio 35→15 · detail 25→10 · TP detail split 10+10 · findAlternatives 12 s deadline · pre-ready watchdog 20 keep · ADD 12 s mid-play freeze watchdog · proxy serve-wait 35→90 stopgap, stream-through = real fix. Android resolve reads 20→8 (CV 10) · API read 20→12 · DROP KK host C (stub-only) + 15 s total KK chain cap · STALL/POSITION/LAST_RESORT/RetryPolicy keep.
- PREDICTOR SPEC (from variance structure): stats per (provider × stage × host); streamvsmov at subdomain, blogcdn/tiktokcdn/kvp726 at domain, KK per API host; latency EWMA half-life ≈10 min; failure LATCH ≥2 consecutive timeouts → demote 15 min → single re-probe; fuse = clamp(max(3×EWMA, EWMA+4 s), floor 6 s, cap = tuned constant); priors = audit medians at low weight n≈3 (KK stream stages get NO prior — VM 404 artefact must not convict); + pooled path baseline so tunnel-wide slowness isn't misread as mass death (latch needs 3 when baseline degraded >2×). Failures cluster by host and persist; bimodality is the signature (healthy-or-absent, no middle state).
- On-device hand-off O-1..O-7 stays open for the Sony verification of the predictor build (KK chain via tunnel, TTFF per source, TMDB keyed, RD legs, v1/v6 via tunnel).
- DISPATCHED 01:1x CST: tvOS implementer (constants + mid-play watchdog + proxy stream-through attempt w/ fallback + CV dedupe + predictor) and Android implementer (constants + KK host C drop/cap + CV dedupe + predictor + build, no install). Team 4 gates both before push/build/install.

## TUNING + PREDICTOR IMPLEMENTATION — BOTH TREES DONE 2026-11-15 ~01:20 CST
- Android v2.2 (code 4) BUILT (tvphim-v220.apk, dex 0a148779…): constants applied, KK stub host free2.phim4k.dev REMOVED from defaults AND filtered in kkHosts() (prefs/remote cfg cannot resurrect), KK chain 15 s total budget, CV memo (process-lifetime), SourceHealth predictor (own prefs tvphim_health) wired into fuses + ladder/hop/torrent ordering with the Torrentio latch exception; leader ACCEPTED the implementer's flags (F4K terminal fallback cap stays 20 s on device evidence — fuse governs ≈6 s; Torrentio cap 30 s with fuse governing; TMDB instrumented only; RdApi untouched). NOT installed — gate first.
- tvOS desk implementation DONE (PREDICTOR-IMPL-TVOS.md): all constants as caps; NEW 12 s mid-play freeze watchdog via itemFailed; JoeProxy STREAM-THROUGH for all segment types (VS/TP/F4K/CV stream; playlists store-and-forward, serve-wait 90 s); CV memo; SourceHealth.swift registered in project.yml; findAlternatives 12 s deadline (partial results NOT cached). Compiler verification outstanding by construction (no Swift toolchain on VM — CI is first compile).
- NEXT: Team 4 gate over both trees → tvOS push (with local-vs-remote divergence check: the Đá Banh chat pushed EN-merge commit 70c08cd to dabanh-ios main in parallel) + build run #12 → IPA dissection → Android install + Sony verification.

## TEAM 4 GATE — LATENCY TUNING + PREDICTOR ROUND (both platforms) — 2026-11-15 ~01:4x CST

Gate method: code-reading of both trees + independent re-measurement of all build evidence by the gate itself. No app code edited by the gate.

### tvOS scopes (tree ~/workspace/dabanh-ios/JoeTV/)
1. **Constants — PASS.** VS resolve cap 8 / detail 10 (VsClient.swift:25-26); KK detail 10 inside the per-host race (KkClient.swift:45); F4K detail 10 (F4kClient.swift:49); TP detail 10 + embed 8 (TpClient.swift:59,62), CV probe on its OWN budget via CacheVideo.resolve cap 10 (CacheVideo.swift:32); Torrentio streams cap 15 (TorrentClient.swift:282); JoeProxy serve-wait 90 on the playlist path only (JoeProxy.swift:241); list/search 12 unchanged in all four clients; pre-ready watchdog 20 unchanged. Gate's own stale-literal sweep of all tuned files: no surviving 25/35/20 timeout literal in any tuned class (surviving 25 s values are JoeHTTP defaults for deliberately unwired calls — TMDB fetch/imdbId, TorrentClient manifest/catalog/meta — plus subtitles 18 and RdClient 25; none is a tuned class).
2. **Mid-play freeze watchdog — PASS.** JoePlayerView.swift Coordinator: freezeTimer arms only at .readyToPlay, which also cancels the pre-ready watchdog (never overlap); paused guard (timeControlStatus == .paused covers user pause + scrub) holds the clock open and re-bases position each tick, so resume gets a fresh 12 s; end guards (DidPlayToEndTime + pos ≥ dur−1.5 s) hold open; movement >0.05 s either direction counts as alive; fire routes fireFail() → director.itemFailed() → the full ladder (refresh → hop → torrent rung → exhausted). Recorded residual (intended behaviour, not a defect): a player stalled in .waitingToPlayAtSpecifiedRate with a frozen playhead fires at 12 s — that is the failover the watchdog exists for.
3. **JoeProxy stream-through — PASS.** Offset proof verified line-by-line against stripDisguise: non-PNG decidable from the first 8 bytes (offset 0); PNG requires the TS sync triple final before any byte is served; ftyp/WebVTT verdicts deferred until the full 16 KB window is in hand so precedence cannot flip; streamDecide holds the head until off+189 bytes so detectContentType sees the same window as the whole-body path; MIME comes from detectContentType on the STRIPPED payload; non-2xx before the first byte → streamRefused → 502 (mid-stream error after bytes = connection close, documented); loopback bind (requiredInterfaceType = .loopback) intact; 512-route FIFO cap in register(); the only semaphore is confined to servePlaylist on the proxy's own queue (playlistURL never waits); playlists still whole-body rewritten.
4. **CacheVideo memo — PASS.** CacheVideo.swift:47-72: memoSet called only on found streams (successes only; Direct preferred, fallback recorded only if a stream URL exists); key "imdbId|season|episode"; TTL 600 s; flush-all above 64 entries; in-memory statics only — no stream URL is persisted anywhere.
5. **SourceHealth (tvOS) — PASS.** Half-life 600 s, weight cap 20, prior weight 3, latch window 900 s; latch on ≥2 consecutive TIMEOUTS only (success and instant-fail reset the counter and clear the latch; latch expiry does not reset the counter, so the next timeout re-latches and the next answering outcome clears); cancellation (CancellationError / URLError.cancelled) rethrown UNRECORDED; fuse = clamp(max(3×EWMA, EWMA+4 s), floor 6 s, cap) at every wired call site (VS detail+resolve, F4K detail, KK detail per-host, TP detail + Gold paging + resolveGold, CV resolve, Torrentio fetchStreams; JoeProxy records playlist/segment samples); priors are EXACTLY the 17 audit medians and there is NO KK playlist/segment prior; ordering consumers (orderServers in ladderFor, orderedAlternatives in findAlternatives) apply the stable partition on BOTH cache-hit and fresh paths, demoted last; path-baseline rule present in full (pooled baseline EWMA > 2×1.51 s AND ≥2 keys with consecutive timeouts seen within 300 s → latch threshold 3); persistence bounded (UserDefaults source_health_v1, 128-key cap, latches evicted last + LRU, saves throttled ≥2 s except latch changes); no network or UI calls in the file.
6. **findAlternatives 12 s deadline — PASS.** Providers.swift: AltSearchBox (NSLock) + unstructured task publishing progress; caller polls at 100 ms to the 12 s deadline and returns partial results; deadline-cut results are NOT cached as "not carried" (altCacheSet only on completion); search.cancel() on cut (cooperative; in-flight URLSession calls run to their own timeouts — bounded, no leak).
7. **Regression sweep — PASS WITH ONE MINOR DEFECT.** TMDBKey.swift untouched, still the empty placeholder (value = ""). project.yml:122 registers JoeTV/SourceHealth.swift; JoeTV settings stamp MARKETING_VERSION "1.9" (project.yml:151) / CURRENT_PROJECT_VERSION "10" (:152) / CFBundleShortVersionString "1.9" (:158). SourceHealth/freeze references appear ONLY in the ten expected files (the seven clients + Providers + JoeProxy + JoePlayerView + SourceHealth itself) — no focus/UI file was touched beyond JoePlayerView's watchdog. Brace/paren/bracket balance 0 on all ten edited Swift files (gate re-measured with string literals and comments stripped).
   - **DEFECT (minor, pre-build):** project.yml:159 — the JoeTV Info-properties literal CFBundleVersion reads "9" while CURRENT_PROJECT_VERSION (project.yml:152) is "10". What's wrong: the two stamps disagree, so which build number ships depends on XcodeGen's merge behaviour. What correct looks like: the literal reads "10", matching CURRENT_PROJECT_VERSION — or the leader confirms the override from the built IPA at the P-0 plistlib inspection (bundle com.luun.nguyen.joetv must read 1.9 (10)) before anything is delivered. One-line fix; does not need a re-gate because the IPA inspection re-verifies the stamp from the binary.

### Android scopes (tree ~/workspace/tv-build/tvphim-src/, APK tvphim-v220.apk)
8. **Constants — PASS.** Resolve-class read cap 8 s (VsApi.java:161 httpGetH cap 8000; TpApi.java:383 Gold embed read = fuseMs cap 8000, connect 10000 at :378); CV resolve cap 10 s (CacheVideo.java:90, httpGetH 10000/10000); API reads cap 12 s (VsApi list/detail 12000/12000; TpApi list/detail/search/Gold paging 12000/12000; F4kApi home/search/detail-first-leg 12000/12000); KK chain: CHAIN_BUDGET_MS 15_000 (KkApi.java:136) — the fetchJson loop stamps the deadline at entry, latch-sorts host order, clamps each attempt to min(12000, remaining) and abandons remaining hosts when <1500 ms remain. PlayerActivity watchdogs provably unmoved: STALL_LIMIT_MS 12_000 (:74), POSITION_STALL_MS 15_000 (:75), LAST_RESORT_RETRY_MS 25_000 (:76), MAX_TRIES 6 (:78); RetryPolicy body intact (:202-215 — 403/404/410 → C.TIME_UNSET no-retry, errorCount > 3 gives up, delay min(1000×count, 3000), minimum retry count 1). TvData.fetchBytes untouched (connect 10000 / read 30000). Leader-accepted exceptions stand as flagged by the implementer: F4K terminal fallback pair 12000/20000 (v1.6.4 device evidence; the fuse governs ≈6 s in practice), Torrentio cap 30000 with the fuse governing, TMDB instrumented only at cap 15000, RdApi untouched.
9. **KK stub host — PASS.** SourceConfig.java DEFAULT_KK (~:51) = phimapi.com, free.cryboiz.workers.dev, mephim.ddns.net — free2.phim4k.dev absent; kkHosts() (~:75) filters any entry containing "free2.phim4k.dev" from defaults, prefs cache and remote cfg alike, so neither a stale cache nor a remote config can resurrect it. Dex cross-check: the string occurs exactly once in classes.dex — the filter literal.
10. **Predictor parity — PASS WITH RECORDED DEVIATIONS (none blocking).** SourceHealth.java (521 lines) read in full: key shape provider|stage|host with the spec's host-granularity rules; HALF_LIFE 600_000; LATCH 900_000; FLOOR 6_000; MAX_KEYS 128; latch on ≥2 consecutive timeouts only; fast-fail never latches (recordFastFail delegates to the success/sample path); expired latch → single re-probe at floor fuse with the latch re-armed one window inside fuseMs; fuse formula identical; NO KK playlist/segment prior; own prefs file tvphim_health; TimingFactory player sampling with subtitles excluded and the timeout/fast-fail split on SocketTimeoutException vs InvalidResponseCodeException. Consumers all wired and read by the gate: TvData.httpGetH (read timeout = fuseMs(cap), outcomes recorded, failure surfaces exactly as httpGet's exception); TP Gold embed hop manual fuse; TorrentApi.fetchStreams (:321) WITH the Torrentio exception — a latched Torrentio is still fetched exactly once at the floor fuse, never skipped; Providers.demoteLatched (:332) applied to every ladderFor result; PlayerActivity wiring (curHealthProvider init :451, TimingFactory wrap :507, applyPlaylistFuse :650 with cap 10_000, buildTries latch partition :561+, hop-walk reorder :777, torrent-ladder partition in buildTorrentLadder); MainActivity SourceHealth.init (:140). Watchdogs unmoved (scope 8). Deviations from the tvOS formulation, recorded and ruled acceptable by the gate — every one is behaviourally conservative (equal or harder to convict a host, or an immaterial constant): (i) path-baseline prior 1300 ms vs tvOS 1510 ms and the threshold-3 rule is baseline-only (tvOS adds a ≥2-keys-within-300 s condition) — Android applies the SAFER threshold slightly more readily; (ii) VS priors generalised to any streamvsmov host and the torrent prior to any resolve-stage host (tvOS seeds only measured hosts) — priors are weight-≈3 starting points only; (iii) MAX_WEIGHT 24 vs 20; (iv) eviction is plain LRU without the latches-evicted-last rule (bites only beyond 128 distinct keys); (v) recordTimeout does not blend a burned-fuse EWMA sample — demotion is carried by the latch instead, same outcome; (vi) the implementer report's "recordFastFail elapsed ≈ 0" wording is inaccurate — the code passes the real elapsed time, which matches tvOS behaviour; the code is right, the report sentence is wrong.
11. **Rung integrity — PASS.** Diffed against the v2.1 implementer description point by point: tryTorrentSubstitution (PlayerActivity.java:818) keeps its guard and one-shot xpTorUsed; effectiveBase null-check still BEFORE beginFailoverStep; identity chain unchanged (xpImdbId → xpTmdbId → KK-alternative derivation → TmdbApi.fetchImdbId); series id imdbId:season:episode with the S-marker season parse; the three decline sites are exactly as v2.1 (advanceLadder else-branch :700-703 refresh→hop→rung chain; refresh callback :750 hop→rung; hop callback :798 rung; plus the rung's own decline :895); buildTorrentLadder keeps addon order, direct-URL entries up to MAX_TRIES, per-URL Referer/UA extraction, RD fallback bounded to 3 attempts over the ORIGINAL list order, no container filtering, TorBox-only configs decline honestly; applyTorrentStep (:986+) still forces the direct route (curDirectNet = true + buildFactories(true)), attaches the Vietnamese subtitle before startChannel, and migrates CW to WatchStore.torProgressKey(streamId) / KIND_TOR with metaId/metaType/streamId set; maybeShowKkTunnelHint still suppressed when xpTorApplied (:1112). The ONLY differences from v2.1 are the sanctioned predictor/fuse wiring: the latch partition inside buildTorrentLadder, curHealthProvider/setSessionProvider attribution in applyTorrentStep/applyFailoverStep, and the hop-walk latch reorder.
12. **Build evidence — PASS, independently re-measured by the gate.** tvphim-v220.apk md5 1e7d03566e3e664ad037e41b22fe9e99; classes.dex v220 0a1487797444d148227773e6bb9184ba ≠ v210 0bf47125c26fa4950462df20c5d8c799 (the predictor round is really in the binary); binary AndroidManifest.xml parsed directly by the gate: package com.gathin.tvapp, versionName "2.2", versionCode 4; dex symbols present: SourceHealth ×6, TimingFactory, applyPlaylistFuse, demoteLatched, fetchImdbId, tryTorrentSubstitution ×3, CHAIN_BUDGET_MS, tvphim_health; rollback APKs untouched — v210 md5 717156765c187ccfebfe69891ab014fb, v200 md5 c00e50ea554b4ff59b6f864af19db318 (exact match to the required values).

### VERDICTS
- **tvOS: READY FOR BUILD** — one pre-build condition: fix project.yml:159 CFBundleVersion literal "9" → "10" (one line), or hold the P-0 IPA inspection as the deciding check that the shipped stamp reads 1.9 (10). First compile happens in CI by construction (no Swift toolchain on the VM). All P-E device gates remain UNVERIFIED (see honesty declaration) — the owner's install is the first device run.
- **Android: READY FOR INSTALL + Sony verification.** v220 may be installed over v210 with the v210 APK as rollback. The on-device hand-off items (audit O-1..O-7: KK chain timing via the tunnel, per-source TTFF, latch demotion of a black-holing VS mirror, fuse behaviour under a dead KK host A) are device checks for the install session, not desk gates.

### HONESTY DECLARATION (Team 4)
- **Claims:** scopes 1–12 as marked above; one minor defect (project.yml:159); six recorded Android parity deviations, none blocking.
- **Evidence:** every PASS cites file:line read by the gate in the current trees; scope 12 hashes, the binary-manifest parse and the dex symbol sweep were re-measured by the gate itself in this session, not copied from implementer reports.
- **Unverified, labelled:** ALL P-E device gates remain UNVERIFIED — freeze-watchdog behaviour on real AVPlayer, stream-through playback of real VS/F4K/Gold/CV segments on the Apple TV, latch/fuse behaviour on live hosts, tvOS compile (CI is the first compile), Android v220 on-device behaviour (install + Sony session still owed), and the audit's on-device hand-off O-1..O-7. Nothing in this report desk-passes a device item.

## ANDROID v2.2 — INSTALLED + DEVICE-VERIFIED ON SONY 2026-11-15 ~01:50 CST (leader, own screencaps: ~/workspace/tv-build/verify-v220/)
- Install over v2.1, data preserved; dumpsys confirms versionName 2.2 / versionCode 4. Home renders (806/829 kênh, 23 link chết ẩn); Phim "Đang xem dở" intact (his 3 entries + Don Glees test entry).
- KK regression PASS: Don Glees plays via KK through the tunnel, RESUMED at the saved 1:05 position (CW position survived the upgrade), frames advance, subtitles render.
- RUNG RE-TEST PASS (predictor build): tunnel OFF → Psycho-Pass KK dead → torrent rung fired ("· Torrent") → candidate 1 was a dead debrid file (removal-notice video) → app auto-advanced ("Đang chuyển nguồn khác..." → "· nguồn 2") → candidate 2 plays the real film (ocean opening, "Off the coast of Kanagawa, Japan."). The intra-rung candidate walk is now device-proven too.
- Tunnel restored ON (● Bật) and verified by screencap. TV left AWAKE on the app home for the main chat's Đá Banh v2.14 install; NOT slept (work remains tonight).
- O-1/O-6: functional pass; precise TTFF not separable through the adb relay's own latency — labelled, not claimed.
- Navigation note for future sessions: the Settings page has NO rail — rail-coordinate taps land on settings fields (one tap opened the TorBox field's keyboard; no text was sent, field value untouched, mask length unchanged). Leave Settings via BACK only.

## ADVISORY 2026-11-15 (oversight team, via manager chat) — TUNNEL-STATE LABEL FOR SOURCEHEALTH — ACCEPTED FOR v2.3, v2.2 STANDS
- Claim verified from primary evidence by the leader: Android SourceHealth key = provider|stage|host (SourceHealth.java:252-253) — NO tunnel-state dimension. The advisory is factually correct about v2.2.
- Impact assessment (leader): bounded and self-healing. Wrong-mode failures for KK (tunnel OFF) are fast geo-404s = instant-fail samples, which by design NEVER latch; EWMA half-life ≈10 min washes mode contamination out after ~30 min of correct-mode use; the pooled path-baseline guard covers tunnel-wide slowness. The failure mode is temporary mis-ordering, not wrongful conviction.
- Decision: fix rides v2.3 together with the dead-link reporter module (add the app's own tunnel toggle state to the stats key — observable on Android because the app owns the toggle; on tvOS the app has no tunnel visibility, so the key stays mode-less there and the asymmetry is documented). Rebuilding v2.2 tonight for this was rejected: the Sony is handed over to the Đá Banh v2.14 install and the refinement is self-healing — not worth the morning deadline.
- Also noted from the same advisory for the NEXT round (not this one): Joe TV cfg.json recovery — extract the baked-in config, commit it back to data-582047 with a per-field diff. No push tonight (sleep push-freeze law).

## PUSH DISCIPLINE — TONIGHT (manager directive 2026-11-15 ~01:41 CST, after a push card woke the owner)
- Every GitHub push raises an Allow card on the owner's phone. Until morning: this side makes NO further pushes — the single batched push (d808749, 31 paths, ~01:31 CST) was the one and only. If anything unforeseen ever forced a push, message the manager FIRST so it combines into one joint round. Web-UI build dispatches and adb installs are unaffected and continue normally.

## BUILD RUN #12 — FAILED AT COMPILE 2026-11-15 01:31 CST (run 43690292086, commit d808749)
- NOT an XcodeGen failure: the project generated (main was healed) and Swift compilation of the JoeTV batch began. "Build (unsigned)" step failed, exit 65, 3 failed build commands (batch SwiftCompile + SwiftDriver + target compile — likely one root cause). NO artifact produced.
- Toolchain recorded (gate B-6): Xcode 26.6 (17F113), Apple Swift 6.3.3 — note: NOT the Xcode 27 line the conformance doc inferred; no plan item depended on it (UIDesignRequiresCompatibility was never added).
- The tail-100 log carried NO diagnostics (errors sit above the tail window). Browser tasked to extract every "error:" line from the full step log. Next: desk-fix the root cause, Team 4 spot re-check, then ONE coordinated push via the manager (push-freeze law) + re-dispatch.

## RUN #12 COMPILE FIX — PREPARED 2026-11-15 ~01:52 CST (pending Team 4 spot re-check + one coordinated push)
- Root causes (from the full step log, extracted via browser): (A) JoeProxy.swift streamRefused/streamAppend/streamComplete declared `fileprivate` while their parameter type StreamState is `private` (nested in JoeProxy) — 3 errors, one root. (B) SourceHealth.swift evictLocked subscripted the dictionary `snap.keys[a]` with a sort ELEMENT instead of using the element's value/key — 1 error.
- Fix (local tree, exactly 5 lines, diffed against remote): JoeProxy lines 328/337/391 fileprivate→private (matches the already-clean private streamDecide; all callers are the nested StreamDelegate inside JoeProxy's lexical scope + internal calls). SourceHealth: comparator uses a.value/b.value; eviction writes snap.keys[k.key] = nil. Semantics unchanged.
- Also in the log: one WARNING (not an error) — JoePlayerView.swift:502 main-actor-isolated tick() called from a nonisolated context (Swift 5 language mode → warning only). Noted, not touched in this fix.
- Remaining steps: Team 4 spot re-check (incl. sibling sweep for both defect classes across JoeTV/*.swift) → ONE push coordinated via the manager → re-dispatch build via web UI → IPA dissection.

## TEAM 4 SPOT RE-CHECK OF THE RUN-#12 FIX — PASS / READY (2026-11-15 ~01:47 CST)
- Item 1 (JoeProxy access fix) PASS: diff vs remote exactly 3 lines; all callers inside JoeProxy's lexical scope (nested StreamDelegate :286/:296/:303); streamDecide precedent confirmed in code.
- Item 2 (SourceHealth eviction fix) PASS: diff exactly 2 lines; comparator semantics (non-latched first by lastSeen asc, latched last) and exact-excess removal verified against the gated design.
- Item 3 (sibling sweep, both defect classes, whole JoeTV tree) PASS: the only other fileprivate (JoeProxy:499 recordProxySample) exposes only internal types — CLEAR; every .sorted/dictionary-subscript candidate site read in context — all CLEAR. No second instance of either class.
- Honesty label carried by the gate itself: static re-check only; full compile remains CI's verdict on the next run.
- Status: fix push awaits the manager's combined-slot decision (requested 01:48 CST). On push: re-dispatch build via web UI immediately.

## FIX PUSHED + BUILD RE-DISPATCHED (2026-11-15 ~01:48 CST)
- Manager decided: push tonight as the single combined round. They independently diffed from remote before pushing (2 files / 5 lines, matching Team 4) and the push landed: commit 4c2ec99 on main.
- Build re-dispatched via the cloud browser (web UI, no push involved) against 4c2ec99. On success: IPA ritual + Team 4 dissection (P-0…P-F) → deliver; on failure: extract error lines and loop again.

## RUN #13 — FAILED, NEXT LAYER (2026-11-15 01:48-01:59 CST, run 43691616575, commit 4c2ec99)
- Run #12's 4 errors GONE (fix verified by CI). New: 2 errors, one root — KkClient.swift:83, fetchJSON's closure params `path`/`shape` captured by group.addTask without @escaping (predictor-round host-race code; first compile keeps peeling layers because the batch compiler surfaces errors progressively).
- Fix applied locally: @escaping on both params (KkClient.swift:72-73; diff vs remote = exactly those 2 lines). Leader sweep of the same class tree-wide: only SourceProbe.probe's `fetch` and SourceHealth.run's `op` are non-escaping closure params — both read in full, both only awaited in place → CLEAR. Team 4 spot re-check #2 running.
- Leader's standing note to the manager: cannot promise the next run is the last layer; each layer so far is small and single-rooted. tvOS may miss the morning slot; Android v2.2 is complete and unaffected.

## TEAM 4 SPOT RE-CHECK #2 — PASS / READY (2026-11-15 ~02:02 CST)
- KkClient fix = exactly 2 lines (@escaping ×2), callers (6 inline-literal sites) unaffected; sweep of the defect class across all 25 files: 4 non-@escaping closure params total, all CLEAR with code evidence (SourceHealth.run op, SourceProbe.probe fetch — awaited in place; JoePlayerView init's two Optional-wrapped closures — implicitly escaping, legally stored). All 25 files diffed vs remote: only KkClient diverges, by exactly the fix.
- Push slot requested from the manager (3rd push of the night, each one coordinated). Next: push → build #14.

## LAYER-2 FIX PUSH — APPROVAL CARD EXPIRED, PARKED FOR MORNING (2026-11-15 ~02:49 CST)
- The manager diffed the fix (exactly the 2 @escaping lines, matching Team 4) and attempted the combined push; the approval card expired after 30 min untouched (owner fully asleep) and the system recorded NOT EXECUTED. Verified from remote afterwards: main does NOT contain the KkClient fix; the local file is intact and ready.
- Per the closed-loop contingency: NO retry tonight (each retry = another 30-min hanging card). Morning state for the report: KkClient fix READY + gate-passed, awaiting the owner's one-tap approval → push → build #14 → IPA dissection → delivery. tvOS v1.9 therefore does NOT make the morning delivery slot; Android v2.2 stands complete.

## DAD-KIT REFRESHED LOCALLY (2026-11-15 ~02:52 CST) — NOT uploaded tonight
- ~/workspace/tv-build/dad-kit-2026-11-15/ = copy of the 2026-11-14 kit with tvphim-v200.apk replaced by the device-verified tvphim-v220.apk (md5 1e7d03566e3e664ad037e41b22fe9e99, matches the gate + Sony install). README updated: Joe TV row + install step 4b + checksum line now name v220 with the new md5, plus a v2.2 delta note (predictor, torrent substitution rung, KK stub removal, Gold-path fixes; Sony verification 2026-11-15). Zero stale v195/v200 references remain.
- The kit's Đá Banh APK is still v2.11 — v2.14 belongs to the Đá Banh chat's line; flagged to the manager, not swapped by this side.
- Upload/delivery waits for the morning (he installs when he holds the box; no remote work on dad's box, ever).

## DAD-KIT COMPLETED BY THE MANAGER (2026-11-15 ~02:50 CST)
- The manager swapped the kit's Đá Banh APK to v2.14 (installed + verified on the Sony tonight by their side, md5 af1a81c6…) replacing v2.11, and updated the README in all 3 places (description table, install step, checksum line) — no stale references. Kit dad-kit-2026-11-15 is now consistent: Joe TV v2.2 + Đá Banh v2.14. Upload/link delivery stays for the morning, when he holds the box.

## LAYER-2 FIX PUSHED — BUILD #14 NEXT (2026-11-15 ~09:40 CST)
- Owner awake and approved the one-tap push: KkClient fix is on main as commit dac0958; manager verified remotely that KkClient.swift matches the gate-passed copy (md5 9258f204913df3fdb62844f6188cf8c0).
- Build #14 (Build JoeTV IPA) to be dispatched via web UI now. On artifact: IPA ritual + Team 4 dissection (P-0…P-F), P-E gates labelled UNVERIFIED (no Apple TV on this side), then report to the manager for the final JoeTV.md + SUMMARY.md.

## TEAM 4 IPA DISSECTION — CLEARED FOR DELIVERY (2026-11-15 ~09:55 CST)
- Gate zero PASS (IPA sha256 1238016e… recomputed). P-A ALL PASS: bundle/version 1.9 (10) from the shipped plist (closes the project.yml stamp defect), minOS 17.0, ATS only NSAllowsLocalNetworking, TMDB key present in the executable (match count 1, value never reproduced), icons incl. LogoWordmark in Assets.car. P-B/P-C/P-D/P-F PASS (incl. G-EXIT-4 nuance documented: the single remaining DispatchSemaphore is confined to servePlaylist on the proxy's own queue — never a UI path). Binary markers ALL FOUND: source_health_v1, SourceHealth symbols wired into TorrentClient.fetchStreams, "Nguồn thay thế: Torrent" notice, StreamState/StreamDelegate metadata (stream-through shipped).
- P-0 correction: the binary's own stamps read Xcode 26.6 (17F113) / tvOS 26.5 SDK — APPLE-CONFORMANCE §1.3's Xcode 27 inference was wrong; no gate depended on it.
- P-E device gates (10 items) UNVERIFIED — carried into the delivery message verbatim in substance.
- DELIVERED 2026-11-15 ~09:56 CST: attachment + Muse file link (expires 2026-11-17 09:56 CST). The v1.9 closed loop is COMPLETE on the desk side; the owner's install is the first device run.

## ★ v1.9 DEVICE FAILURE — OWNER'S FIRST RUN (2026-11-15 ~11:08 CST)
- Owner installed run #14 and opened the app: Phim home sits on "Đang tải thư viện phim..." and FREEZES there (his photo: spinner + the four-provider subtitle, Phim pill focused). Same symptom class as v1.8 (Phim home stuck on spinner; v1.8 also froze the box). The desk loop (source gates + IPA dissection) did NOT catch it — every P-E item was labelled UNVERIFIED and this is the one that mattered most. Leader's failure, recorded plainly: static conformance was verified; runtime behaviour of the first-launch load path was never exercised anywhere.
- Owner's order: follow yesterday's law; identify the missing team and add SPECIALIST teams for this field.
- Response structure: NEW Team 5 (tvOS runtime forensics — trace the first-launch Phim load chain end-to-end, find the blocking mechanism with file:line evidence) + NEW Team 6 (concurrency & timeout-completeness — census of EVERY async wait reachable from launch with its real enforcement bound; adversarial focus on structured-concurrency joins that outlive their fuses and on black-hole-class servers). Then: fix round → Team 4 re-gate INCLUDING the wait-census as a gate artifact → build → dissect → deliver. No build reaches the owner until the freeze mechanism is identified and closed.
- Discriminating questions put to the owner (only he can observe): does the remote still move focus / is the spinner animating (UI alive = load hung; nothing responds = main-thread block); does the TV tab load; how long did he wait.

## OWNER'S DISCRIMINATING OBSERVATION (2026-11-15 ~11:11 CST)
- Owner's words: "Freeze toàn bộ. Remote ko tác dụng ngoài việc hold back để close app thôi" — the freeze is TOTAL: no focus movement, no remote response at all; only holding Back/Menu to force-close works.
- Diagnostic consequence: a hung async load with a live UI is RULED OUT as the primary mechanism. The main thread/main actor is blocked, deadlocked, or spinning shortly after the first frame (the spinner rendered). Both expert teams were re-briefed mid-run to prioritise synchronous blocking primitives, lock/queue deadlocks, main-actor blocking I/O, and SwiftUI update loops on the launch path, and to explicitly kill the candidates this evidence eliminates.
- Owner's verdict (2026-11-15 ~11:12 CST): "Cùng tình trạng ngày hôm qua" — v1.9's freeze is the SAME condition as v1.8's. Leader's structural admission, recorded: the v1.9 loop never root-caused v1.8's freeze mechanism; it rebuilt around the symptom (spinner ceilings, timeout constants, focus rules) and verified those statically. A mechanism that was never identified can survive a rebuild — and did. The current forensic round therefore starts from the mechanism, and no successor build may be claimed on surface conformance again.

## TEAM 6 CENSUS — COMPLETE (2026-11-15 ~11:14 CST): THE AMPLIFIER IS PROVEN, THE TRIGGER IS NOT IN THE CODE
- Full-target sweep verdict: NO mechanism in the app's own code, async or sync, reachable from launch can block the main thread indefinitely. Exactly ONE DispatchSemaphore exists (JoeProxy servePlaylist, off-main, 90 s cap, playback-only, unreachable from launch) — ELIMINATED. Zero DispatchQueue.sync / DispatchGroup.wait / NSCondition / Thread.sleep / RunLoop spins. All locks brief; all sync file reads small/local.
- PROVEN structural defect (the necessary amplifier): PhimStore is @MainActor; load(), all 24 task-group children (whose synchronous segments — parse, cache save, applyRail, mergeDedupe — inherit the main actor), the 20 s watchdog (an unstructured Task created INSIDE load(), hence main-actor-isolated; its loadTimedOut publication must win a slot on the very executor it monitors), and the view state ALL share one executor. Any stall of that executor, from any cause, yields exactly the observed joint symptom: frozen UI + spinner forever + no error surface, ever. "A ceiling checked by a tenant of the hung executor is not a ceiling."
- Systemic enforcement hole: JoeHTTP's only timeout is URLRequest.timeoutInterval (= timeoutIntervalForRequest, an idle timer reset per packet); timeoutIntervalForResource is set NOWHERE (session default 7 days) — a slow-drip peer is unbounded everywhere. PhimStore.load() has NO overall deadline (A1 UNBOUNDED as a load, though eliminated as the freeze cause). KK race join-after-cancel (A4), SourceHealth.run budget-not-a-deadline (A8), AsyncGate no acquire deadline (A3) — all NOMINAL with named holes. The one true deadline pattern in the codebase is findAlternatives' box (A10, BOUNDED).
- TRIGGER: NOT identified from source — labelled hypothesis only: the 24-job first-launch burst through URLSession.shared into the owner's Sing-box packet tunnel (platform-level stall). Needs the on-device signpost instrumentation of fix B.
- Fix shapes adopted for the fix round: A executor separation (load machinery off @MainActor; publish per rail via MainActor.run) · B independent watchdog clock + signpost timestamps · C hard 25 s overall deadline for load() via the A10 box pattern · D timeoutIntervalForResource in a dedicated JoeHTTP session config · E KK race → box pattern · F deadline race inside SourceHealth.run · G AsyncGate acquire deadline · H TVStore/TorHomeStore bounds.
- Team 5 (runtime forensics) still running; leader cross-check when it lands.

## TEAM 5 FORENSICS — COMPLETE + LEADER CROSS-CHECK (2026-11-15 ~11:17 CST)
- Team 5 independently confirms Team 6: the first-launch chain (JoeTVApp init → JoePhimHome .task → PhimStore.loadIfNeeded → load(): watchdog → hydrate → 24-job group behind AsyncGate(4) → per-provider fetchListRaw → JoeHTTP/URLSession.shared) is suspending/bounded throughout; publishing is INCREMENTAL (applyRail per landed job); SourceHealth and JoeProxy are NOT in the list path; TVStore is view-gated out of launch. Killed with file:line evidence: hung-load-with-live-UI, watchdog logic bug, VS black-hole on the home path, JoeProxy semaphore, TVStore storm, sync parse/IO tails.
- Team 5 ranked candidates: #1 SHELL/FOCUS machinery on the owner's tvOS — the custom focus hub (.focusable() pills + @FocusState + focus-state-dependent move/exit traps) cycling during the initial focus settle; argued by elimination + cross-version commonality (load logic fully rewritten v1.8→v1.9, freeze unchanged; shell lineage untouched since v1.5) — LABELLED INFERENCE: the cycle could not be constructed from source (all requestFocus callers are input-driven). #2 the ATV's Sing-box TUN path making every request outlive its budget (explains zero rails, NOT the dead remote/watchdog alone). #3 store wedge = #2's consequence, demoted.
- LEADER SYNTHESIS: both teams converge — (a) the same-executor watchdog placement is a PROVEN defect that guarantees the joint symptom under any main-actor stall; (b) the trigger is not provable from the desk. Two cheap device observations discriminate #1 vs #2 almost completely and are put to the owner as one batch: (A) does Đá Banh TV 1.3.2 (delivered this morning, same shell lineage) run or freeze on the same box? (B) with the ATV's Sing-box/VPN profile off (or on a different network), does Joe TV 1.9 still freeze instantly?
- Fix programme (starts on the agreed structural items regardless of the discriminator outcome): executor separation for the load machinery; independent watchdog clock + signpost instrumentation; hard overall load deadline (A10 box pattern) + AsyncGate deadline + KK race → box pattern + SourceHealth.run internal deadline; JoeHTTP timeoutIntervalForResource; shell/focus simplification toward stock behaviour (scope set by the discriminator result); staged launch burst.

## DISCRIMINATOR A — ANSWERED BY THE OWNER (2026-11-15 ~11:22 CST): ĐÁ BANH TV RUNS FINE
- Owner's words: "Đá banh tv chạy ổn định rất tốt" — Đá Banh TV 1.3.2 runs stably, very well, on the SAME Apple TV, same network, same Sing-box tunnel.
- Consequences: (1) The device, its tvOS build, and the tunnel/network path are exonerated as SUFFICIENT causes — Team 5's candidate #2 is demoted hard (Đá Banh TV fetches and streams over the same path without issue). (2) Candidate #1 survives only in its NARROW form: not the shared shell lineage in general (Đá Banh TV shares the geometry lineage and is fine), but Joe-TV-SPECIFIC deltas — its focus-hub details (move/exit traps installed conditionally on focus state), its PhimStore launch machinery (24-job group + AsyncGate + main-actor watchdog), JoeProxy listener warm-start at init, PhimRailCache hydrate. (3) Discriminator B (network swap) is stood down — A already covers its discriminating power for the network hypothesis; do not spend the owner's effort twice.
- Next step: Team 7 DIFFERENTIAL forensics — enumerate every launch-path and focus/shell difference between Joe TV (freezes) and Đá Banh TV (proven on this box), judge each delta against the total-freeze symptom, rank, and propose the minimal convergence toward the proven shell where a delta has no need to exist.

## OWNER'S TUNNEL EXPERIMENT + TEAM 7 DIFFERENTIAL — MECHANISM CONVICTED (2026-11-15 ~11:25 CST)
- Owner ran discriminator B anyway, richer than asked: TUNNEL ON → total freeze at the spinner. TUNNEL OFF → the Phim home LOADED AND RENDERED (his photo: merged KK rail with posters + "Phim chiếu rạp" rail, black background, v1.9 footer) → then CRASHED by itself. Reopen → movies still there (cache) but TOTAL FREEZE again. Next launch after force-close → fades to a black screen and CRASHES back to tvOS Home by itself.
- Diagnostic weight: with the tunnel off, data flows and renders — the network path AND the load pipeline are exonerated for good. The freeze/crash occurs WITH content on screen, i.e. in the shell/focus layer, and varies freeze↔crash between launches — consistent with a launch-time structural churn storm (hang when it saturates, system kill/crash when it doesn't survive the settle).
- TEAM 7 DIFFERENTIAL (independent, landed the same hour): the convicted mechanism is D4 — JoeMoveTrap/JoeExitTrap are view modifiers whose BODY switches structure (content vs content.onMoveCommand) based on `enabled`, and every `enabled` input is a @FocusState value the focus engine itself writes. Launch path instances: the shell topBar trap (subtree = the pills) + THREE traps on the Phim home ScrollView (subtree = the whole ScrollView). Feedback path is mechanical: initial focus lands → @FocusState flips → trap installs/uninstalls → subtree identity changes → teardown+rebuild → focus re-resolves → can re-toggle. Đá Banh TV has ZERO onMoveCommand and zero conditional modifiers. Ranked: D4 #1 (CAN), D6+D5 focus-rendering/hub cluster #2 (CAN), D8 launch fan-out #3 (contributor). Eliminated: proxy warm-start, store-init work, SourceHealth (refuted as a launch delta outright), TVStore, locks.
- Honesty label carried: the feedback loop's existence is proven from source; its non-convergence on tvOS 26/27 is inference — but it is now the only candidate that fits ALL device observations (both versions, tunnel on/off, freeze and crash variants, Đá Banh TV healthy).
- FIX ROUND OPENED with Team 7's convergence as spec: (1) traps always installed, state checked inside the handler — structural switching abolished, boundary routing preserved; (2) pills back to real Buttons (middle path: Button + per-view focusEffectDisabled + app-drawn label, keeping the look on stock structure); (3) no programmatic focus writes on the launch path; (4) root-level focusEffectDisabled dropped; (5) load staging (4 newest first, rest after first paint) + sync tails off the main actor + hard overall deadline + independent watchdog clock + signposts; (6) proxy warm-start removed from init. New Team 4 gate item: NO @FocusState-driven conditional view modifier anywhere in the target.

## TEAM 8 CONVERGENCE IMPLEMENTATION — COMPLETE, LOCAL TREE ONLY (2026-11-15)
- Implemented per the Team 7 spec in 11 files: JoeTVApp, JoePhimHome, JoeTorrent, JoeSearch, JoeSettings, JoeTVSection, JoeStores, KkClient, SourceHealth, JoeHTTP, TorrentClient. NOT pushed, NO build dispatched — CI is the first compile.
- TRAPS: every conditional trap struct is DELETED (JoeMoveTrap ×3 copies, JoeExitTrap, JoeSearchMoveTrap, JoeSettingsMoveTrap). Zero ViewModifier structs remain in the target (grep proof in the Team 8 report). Routing preserved by construction: container-level boundary routing (pills, Phim header/Retry, Torrent search row/Retries, Settings first field, TV chips, Search top row) is reproduced by GEOMETRIC focus movement (the Đá Banh TV construction); the exact arithmetic routing (Phim/Torrent first rails) survives as ALWAYS-installed per-card .onMoveCommand on the first rail's cards only, attachment driven by catalogue data (firstRailScope / firstTorScope), never by focus state. Kept per-element handlers (pre-existing shapes): JoeSearch resultMove, Torrent searchResultMove, TV moveInGrid.
- EXIT (deviation, flagged): the literal "always-installed root onExitCommand that no-ops at root" contradicts the G-EXIT proof (an installed handler IS an interception). Implemented instead: unconditional .onExitCommand on the layers themselves — movie layer and tor layer in JoeRootView, search root in JoeSearchView; at root NO exit handler exists anywhere, so Menu exits on the first press; with a layer open, the focused layer's handler is the nearest ancestor and closes exactly that layer. JoePlayerView's own handler still wins during playback.
- PILLS: Button + .buttonStyle(.card), selection in the action, no @FocusState on the row, no .onTapGesture; app-drawn look via a PillLabel reading @Environment(\.isFocused) + .focusEffectDisabled(true) on the Button itself. Device-unverified rendering interplay (.card style vs custom label) — P-E item for the re-gate.
- HUB: JoeNavigator focus hub (focusTarget/focusNonce/requestFocus/JoeFocusTarget) deleted; all six .onChange(of: focusNonce) consumers deleted (shell, Phim, Torrent, Search, Settings, TV section). Root .focusEffectDisabled(true) deleted. JoeProxy.shared.start() removed from init (lazy start at first play tap).
- LOAD (PhimStore): staged (4 newest jobs, then the remaining 20 after phase 1 drains — flagged interpretation of "after the first publish"); fetch+cache-save+parse run in a DETACHED worker (nonisolated runPhase), only @Published application on the main actor via a findAlternatives-style poll loop over a lock-guarded box; hard 25 s overall deadline (partial rails kept, loading always clears); AsyncGate.acquire(deadline:) fails parked waiters at the deadline; watchdog on an INDEPENDENT detached clock + LoadWatchdogBox, signposts persisted to UserDefaults "joetv.signposts" (armed / sleep done / publication attempted / publication landed / first rail landed / phase2 started / deadline hit / load completed). KK fetchJSON → KkRaceBox (winner returns without awaiting losers). SourceHealth.run enforces its budget internally (RunRaceBox race; op param now @escaping; all 9 call sites trailing closures). JoeHTTP: dedicated cached sessions with timeoutIntervalForResource == the call's timeout; TorrentClient.request rides JoeHTTP.data(for:timeout: 25). Remaining URLSession.shared uses in the target: NONE (comments only); TpClient's NoRedirect session and JoeProxy's own sessions are separate by design.
- FLAGGED follow-ups (not changed, spec-sized diff): TorHomeStore still has the same main-actor watchdog shape as old PhimStore (its load is sequential and view-gated off the launch path; Team 6 H item) — same treatment recommended next round. mergeDedupe still runs on the main actor inside applyRail (bounded, ≤~200 titles; spec 5b named save+parseList as the tails to move). JoeNavigator.closeTop() is now uncalled (retained deliberately; the layer handlers inline its per-layer closes).
- Verification (static only): grep proof — no ViewModifier struct, no `if enabled`, no `.modifier(` trap application, no hub symbols in code (comments/records only); brace-balance scan (state-tracking, interpolation-aware) passes on all 11 files. HONESTY: nothing compiled here; behaviour claims for geometric routing are layout arguments, not device evidence; first compile is CI build #15, first runtime evidence is the owner's box.

## LEADER VERIFICATION OF TEAM 8 + RE-GATE OPENED (2026-11-15 ~11:42 CST)
- Leader's own greps on the edited tree CONFIRM Team 8's D4 proof: zero ViewModifier structs (one comment mention), zero `.modifier(`, zero `if enabled`, zero trap-struct references outside comments, URLSession.shared and hub symbols (focusNonce/requestFocus/JoeFocusTarget) survive ONLY in comments. JoeHTTP session cache is NSLock-guarded; AsyncGate is now a private actor with exactly one call site; JoeHTTP.data(for:timeout:) returns (Data, URLResponse) so TorrentClient's status logic is preserved.
- KNOWN GAP found by the leader: the signpost log (JoeStores.swift, UserDefaults "joetv.signposts") has NO UI surface — nothing in JoeSettings reads it, so on the owner's box it would be unreadable. Required fix-up before push: a read-only diagnostics block in Settings showing recent signpost entries (persists across launches, so a stall attributes itself on the NEXT launch's Settings screen, photographable by the owner).
- Team 4 re-gate dispatched against the edited tree with the two flagged deviations (geometric routing instead of always-installed container handlers; exit handlers on the layers instead of the root) as explicit audit items, plus the new gate: no @FocusState-driven conditional view modifier anywhere in the target.

## TEAM 4 FINAL VALIDATION GATE — CONVERGENCE BUILD (2026-11-15): PASS, NO FAIL ITEMS
Gate run against the local edited tree (11 files, mtimes 17:32–17:37 confirm exactly Team 8's list: JoeTVApp, JoePhimHome, JoeTorrent, JoeSearch, JoeSettings, JoeTVSection, JoeStores, KkClient, SourceHealth, JoeHTTP, TorrentClient). Nothing edited, nothing pushed by Team 4.

1. **D4 ABOLITION — PASS.** Independent greps: zero `ViewModifier` structs in code (1 comment hit, JoeTVApp.swift:320), zero `.modifier(`, zero `if enabled`, trap names and hub symbols (focusNonce/requestFocus/JoeFocusTarget) and `URLSession.shared` survive ONLY in comments. Semantic sweep: no view's structure or modifier set changes in response to focus or navigation state anywhere in the target (appearance-value branches inside stable views — PillLabel, header/Retry/chip/tile focus treatments — are rendering inputs, not structure; JoeTVSection's hero is a content swap with no focusables inside, the proven Đá Banh pattern; the shell `.disabled(nav…)` is an always-applied modifier carrying a Bool). The one data-conditional attachment class — per-card `.onMoveCommand` on first-rail cards — verified: (a) attachment keys (firstRailScope JoePhimHome.swift:~426, firstTorScope JoeTorrent.swift:~490, fav-rail CW-emptiness conditions) are pure functions of WatchStore/catalogue state, never read any @FocusState; the handlers read focus only at press time; (b) mirror EXACTNESS verified against body order, scope strings and focus-key formats in all states — CW/fav present/absent, error+Retry (Scope-3 DOWN case present in both homes), empty catalogue (nil scope, no cards), Torrent search mode (browse rails don't render, grid keeps its own per-element handler).
2. **DEVIATION A (geometric routing) — PASS WITH FLAGS R1–R3** (landing-target risks, all device-checkable, no press swallowed anywhere, every element reachable): R1 — DOWN from right-aligned controls (Phim "Tìm phim" button, Torrent Tìm/Xoá, Search "Quay lại") lands geometrically on the NEAREST focusable below, plausibly a mid-rail card, not the first card the deleted arithmetic targeted. R2 — Retry UP with a CW/favourites rail on screen (both homes' error states) lands on the last entry card above, not the header/search-field the deleted handlers forced; with no rail present the claimed Retry UP → header/field holds. R3 — UP from Phim header / Torrent search row lands on the nearest pill by x-position, not necessarily the section's own pill. All other audited cases equivalent as layout arguments: pill LEFT/RIGHT (visual order), pill DOWN (section top element), header DOWN in error state (Retry is the only focusable below), first-rail UP (arithmetic handler kept verbatim), Settings single column (first field UP → pills, DOWN walks fields), TV chips incl. disabled action chips (`.disabled(store.isLoading || store.isValidating)` present, JoeTVSection.swift — engine skips), Search top row (Tìm `.disabled(searching || query.isEmpty)` present, JoeSearch.swift:58). Minor comment/code mismatch (non-blocking): JoeTorrent's convergence comment claims the engine skips the Tìm button "while it is disabled mid-search", but that button carries NO `.disabled` (JoeTorrent.swift:165-184) and its runSearch has no re-entry guard — it stays focusable/rerunnable mid-search; behaviour ≈ the old walk, comment overstates. Fix-up may add `.disabled(searching)` or correct the comment.
3. **DEVIATION B / G-EXIT BY CONSTRUCTION — PASS.** Root state: zero `.onExitCommand` in the JoeRootView tree (grep + full read). Movie layer handler JoeTVApp.swift:168, tor layer :177 — unconditional, attached to the layers themselves. Search root handler JoeSearch.swift:168 closes search only. Player handlers (JoePlayerView.swift:309; shared TVPlayerView.swift:49) are nearest ancestors of the focused subtree during playback; detail/search handlers sit in sibling branches, never ancestors of the player's focus — exactly one handler can fire per Menu press, one layer per press, by tree structure.
4. **PILLS — PASS (construction).** JoeTVApp.swift:260-268: real Button, selection in the action, `.buttonStyle(.card)`, unconditional `.focusEffectDisabled(true)` on the Button; PillLabel reads `@Environment(\.isFocused)` (:289); NO @FocusState anywhere in JoeRootView (grep hits are comments). Compile-risk low (.card is the same-repo Đá Banh construction; isFocused env key is tvOS 14+). Whether isFocused actually reaches the label under .card + focusEffectDisabled on the owner's tvOS — i.e. whether the focused pill lights up with the app-drawn violet treatment — is a NEW P-E item (below), labelled, not blocking.
5. **CONCURRENCY — PASS (one warning-class note).** (a) AsyncGate (JoeStores.swift, private actor): exactly-once resumption HOLDS — every resume path (release / expireWaiter / cancelWaiter) removes the waiter from the actor-serialised array BEFORE resuming; pre-park cancellation resumes without queueing; the deadline warden no-ops if the waiter already left. No double-resume path exists. (b) PhimLoadBox / LoadWatchdogBox / KkRaceBox / RunRaceBox: all NSLock-guarded, no await inside any lock, first-writer/winner semantics as reported; tripIfNoData signposts AFTER unlocking (no nested-lock deadlock). (c) Detached worker + poll loop: runPhase is `nonisolated static`, children touch only Providers/PhimRailCache/box/gate; @Published writes occur only on the main actor (load/applyResults/applyRail + the watchdog's MainActor.run hop). NOTE: `[Job]` (non-Sendable private struct) and box Result tuples are captured by @Sendable closures — warnings under the project's SWIFT_VERSION 5.9 (project.yml:9), errors only under a future Swift 6 mode bump; CI should compile. (d) SourceHealth.run op is @escaping (SourceHealth.swift:230); 9/9 call sites verified as trailing closures (CacheVideo:84, F4kClient:123, KkClient:103, TorrentClient:286, TpClient:124/188/301, VsClient:70/120). (e) JoeHTTP: NSLock-guarded per-timeout session cache; timeoutIntervalForResource == timeout set (JoeHTTP.swift:34) with timeoutIntervalForRequest. (f) Staging: phase 1 = jobs.prefix(4) (kkNew/f4kNew/vsNew/tpNew); phase 2 starts only after runPhase(phase 1) fully drains; 25 s hard deadline in the poll loop; `defer { loading = false }` clears loading on EVERY exit (finished/superseded/cancelled/deadline); final drain preserves in-time results.
6. **BEHAVIOUR PRESERVATION — PASS.** JoeTheme.swift, Providers.swift, JoeProxy.swift, WatchStore.swift all UNEDITED this round (mtimes 06:31/07:16/07:45/06:14 vs the round's 17:3x batch). SourceHealth's edit is confined to run() enforcement + RunRaceBox: fuse math verified intact (halfLife 600, latchWindow 900, fuseFloor 6, formula max(3·ewma, ewma+4) clamped [floor, cap]). Predictor caps verified at the tuned values (KK list 12 / detail 10, VS resolve 8, TP embed 8, CV resolve 10, Torrentio streams 15, details 10). JoeProxy lazy start intact (playlistURL calls start(), JoeProxy.swift:126); the init warm-start removal is entirely in JoeTVApp.init (no proxy call). CW/favourites view logic and all five Settings fields + save paths present and unchanged in shape.
7. **KNOWN GAP — CONFIRMED.** Zero references to "signpost"/"joetv.signposts" outside JoeStores.swift; JoeSettings.swift read in full — its diagnostics block is SourceProbe only. Write-site coverage is COMPLETE (10 LoadSignpost.log sites): load started, watchdog armed (LoadWatchdogBox.arm), watchdog sleep done (tripIfNoData), publication attempted, publication landed, first rail landed (cache path AND applyResults), phase2 started, deadline hit, load completed. The log is written correctly and is unreadable on the owner's box until the planned Settings fix-up lands.
8. **BRACE/PAREN BALANCE — PASS.** Independent comment/string/interpolation-aware scanner (handles //, nested /* */, escapes, \( interpolation as code, #"…"# raw strings, multiline strings) run on all 11 edited files: ALL BALANCED. Scanner validated by a planted-imbalance negative test (detected) and a raw-string regex case (balanced); 3 unedited files also scanned clean.
9. **APPLE-CONFORMANCE SPOT RE-CHECK — PASS WITH TWO RECORDED WAIVERS.** minOS: project.yml deploymentTarget tvOS 17.0, untouched; ATS: JoeTV Info properties carry ONLY NSAllowsLocalNetworking (no NSAllowsArbitraryLoads, no UIDesignRequiresCompatibility); project.yml/plists are not among the 11 files. WAIVER 1 — gate B-2's ".buttonStyle(.card) appears nowhere" is DIRECTLY SUPERSEDED by the convergence spec (Team 7 item 2: pills back to Button + .card, the proven Đá Banh construction): recorded WAIVED-BY-CONVERGENCE; leader should update APPLE-CONFORMANCE B-2 before the post-build gate so build #15 isn't failed on a sanctioned change. WAIVER 2 — G-EXIT-4: launch path carries zero semaphores/sleeps/sync waits (target-wide grep); the single JoeProxy semaphore (JoeProxy.swift:206/241, 90 s, off-main queue, playback-only) is pre-existing, unchanged this round, and Team 6-eliminated; the doc's "3 s wait" parenthetical is stale against the current 90 s code — leader to update or waive. G-EXIT-1/2/3/5 desk halves are satisfied by items 1/3/5 evidence (zero programmatic focus writes remain on the launch path; all six hub consumers deleted). P-E UNVERIFIED for the delivery note: (i) the freeze itself — app launches, Phim home settles, remote live; (ii) NEW: pill label rendering under .card + focusEffectDisabled (focused pill shows the app-drawn violet treatment); (iii) geometric landings R1–R3; (iv) Menu at root exits in one press; Menu walks layers one press each; (v) focus glow absent on pills/cards; background reads black; (vi) every source plays (KK, VS, F4K, TP, CacheVideo, Torrentio/RD); subtitles render; (vii) G-EXIT-5 device half — error surface reachable by remote in total-failure state; (viii) after the fix-up, the signpost diagnostics block readable in Settings.

OVERALL: **PASS — cleared for the signpost-UI fix-up, then push + build #15.** No FAIL items; no code correction is required from this gate. Carried forward: flags R1–R3 + pill rendering (P-E), the two conformance waivers (leader doc updates), the Torrent Tìm comment mismatch (optional fix-up), and Team 8's already-flagged TorHomeStore watchdog follow-up (next round, off the launch path).

### Honesty declaration (Team 4)
- Claims: every verdict above rests on files read in full this session (JoeTVApp, JoePhimHome, JoeTorrent, JoeSearch, JoeSettings, JoeTVSection, JoeStores, JoeHTTP, KkClient) or targeted reads/greps (SourceHealth run/RunRaceBox/fuse constants, TorrentClient request path, JoePlayerView exit context, project.yml, APPLE-CONFORMANCE §7), plus the independent greps and the balance scan whose outputs are quoted.
- Evidence: grep outputs, file:line citations, file mtimes (edited-set membership), scanner output incl. its negative test.
- Unverified, labelled: nothing was compiled (no Swift toolchain here — CI build #15 is the first compile; the Swift-5.9-mode warning analysis in item 5c is a language-mode argument, not a compiler result); all geometric-routing verdicts are layout arguments, not device evidence; whether the pre-existing catalogueEmpty predicate (JoePhimHome — omits vietnamSeries/vietnamSingle) predates this round could not be diff-verified (no git in this tree) and is noted only as an out-of-scope observation, unchanged-behaviour presumed; P-E items remain UNVERIFIED by definition.

## TEAM 4 RE-GATE: PASS — NO FAIL ITEMS (2026-11-15 ~11:46 CST) → FIX-UP ROUND OPEN
- All 9 gate items PASS. D4 abolition independently re-verified; AsyncGate exactly-once resumption holds line-by-line; G-EXIT holds by construction (zero exit handlers at root; one layer per Menu press by tree structure); behaviour preservation confirmed (Providers/JoeProxy/WatchStore/JoeTheme unedited; predictor constants intact). Signpost gap CONFIRMED (log written at 10 sites, no UI surface).
- Flags carried to delivery as P-E items: R1–R3 geometric landing differences (DOWN from right-aligned controls lands on nearest focusable, not the deleted arithmetic's exact target; Retry UP with a CW/fav rail present lands on the last entry card; UP from headers lands on the nearest pill by x) — nothing swallowed, everything reachable. Pill label rendering under .card + focusEffectDisabled is a new P-E item.
- Leader doc actions DONE: APPLE-CONFORMANCE B-2 amended (WAIVED-BY-CONVERGENCE for the section pills only) and G-EXIT-4 amended (the "3 s wait" parenthetical corrected: JoeProxy's semaphore is 90 s, off-main, playback-only, Team 6-eliminated — recorded as a bounded exception).
- Fix-up round dispatched: (1) read-only signpost diagnostics block in JoeSettings; (2) JoeTorrent Tìm button gains .disabled(searching); (3) version bump to 1.9.1 (11) — project.yml JoeTV block (4 fields) + the hardcoded footer in JoeTVApp.swift:208. Then: leader spot-verify → push (11 files + project.yml + the two docs) → build #15 → Team 4 IPA dissection → deliver with the P-E list labelled UNVERIFIED.
