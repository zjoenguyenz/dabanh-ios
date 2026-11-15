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
