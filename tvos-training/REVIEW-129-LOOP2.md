# REVIEW-129-LOOP2 — Independent Swift Review, FIX-129 Gate Loop 2

- Started: 2026-11-20T21:50:09Z
- Reviewer: subagent LOOP2 (interleavings / lifecycle / second-order effects)
- Read-only: no Swift files edited.

## Progress log
- 2026-11-20T21:50:09Z — START: gate anchors verified byte-identical to LOOP1 (see Anchors section). Reading FIX-129 report + LOOP1 report + device log.

## Gate anchors (measured by LOOP2)
- TeamNameNorm.swift md5 8aa68a4cca08e136340d44565b80ee2b — MATCHES expected 8aa68a4cca08e136340d44565b80ee2b
- ContentView.swift md5 e662ddc81dd293246bcb44171e29e132 — MATCHES expected e662ddc81dd293246bcb44171e29e132
- PlayerView.swift md5 b59dfaef565042ee7f42f0309347a4f4 — MATCHES expected b59dfaef565042ee7f42f0309347a4f4

(Sections below filled as review proceeds.)
- 2026-11-20T21:51Z — READ: FIX-129-REPORT.md + REVIEW-129-LOOP1.md (CLEAN, 3 MINORs noted; LOOP1 UNVERIFIED list: compile/CI, fresh-playlist counts/censuses, DaBanhTV compile, errorLog timing — none assumed in this loop). Next: read PlayerView/ContentView full interleaving surfaces + device log Castilla segment.
- 2026-11-20T21:53Z — READ: PlayerView.swift full (ResolveHub, MatchPlaySession, SourcePrewarmStore, classifier), ContentView.swift launch/task + route/EN/24-7 paths, NuvioAddon.session, MatchViews board warm, PlaylistStore refresh/sources. Key traces forming on prewarm contention + provenDead readers. Next: TeamNameNorm/Crests/MatchStateStore for alias second-order (psg/newcastle/lyon) + grep line numbers for Castilla log.
- 2026-11-20T21:56Z — TRACES DONE: prewarm contention, provenDead reader graph (incl. Nuvio + 24/7 paths), Castilla line-by-line replay, alias probes for psg/newcastle/lyon run on the corpus harness myself (canon + crest_url identity), log-contract enumeration. Two MINOR findings (shared-store preemption of launch warm; player-dead re-entry boundaries + one overclaiming code comment). Writing verdict.

---

# VERDICT: CLEAN

No MAJOR findings. Two MINOR findings — both bounded, neither delays or
breaks the tap path, neither re-opens the Castilla fault. Details with
file:line evidence below.

---

## Findings

### MINOR-1 (Item B — shared pre-warm store preemption can silently drop launch warming; benefit-loss only, self-recovering)
SourcePrewarmStore is one shared queue and EVERY warm() call rebuilds
`pending` wholesale (PlayerView.swift, SourcePrewarmStore.warm:
`pending = ordered.filter { states[ch.url] == nil … }`), and the player's
close path cancels the store globally (PlayerView.swift:261
`session.endPrewarming()` → :1487-1488 → SourcePrewarmStore.cancelPending,
which clears pending and cancels the driver). FIX-129's launch warm
(ContentView.swift:214-220) is one more caller of that same store, so two
races now exist that did not before:
- (a) Tap-within-the-same-second race: the launch block runs after
  `await store.start()` inside the root `.task` (ContentView.swift:189-221).
  If the owner opens a board first, MatchBoardView's `.task` warm
  (MatchViews.swift:1008-1012) queues that fixture's full ladder; when the
  launch block then fires its single warm(heads) call, the pending queue is
  rebuilt to just the ≤3 featured heads and the board fixture's
  not-yet-started tail rungs are dropped (in-flight ≤2 are never
  preempted). They are re-queued only when the player's first ready calls
  beginPrewarming(after:) (PlayerView.swift:1476-1483).
- (b) First-close race: if the owner opens and closes a player while
  launch warm is still queued/running, endPrewarming → cancelPending
  clears the launch heads that had not started and cancels the driver;
  the launch `.task` never re-queues, so the other featured heads lose
  launch warming for the rest of the run (until their own board opens).
Bounding: warm() itself is synchronous queue bookkeeping on the main
actor — it never awaits network work, so neither race can delay a tap,
a resolve, or playback; the only loss is part of Item B's warming
benefit in the first seconds, and (a) self-heals at first ready. The
queue-rebuild and global-cancel semantics are pre-existing store
behaviour (not introduced by FIX-129); FIX-129 adds the new caller that
makes the interaction reachable. Recorded, not blocking.

### MINOR-2 (Item C — player-dead condemnation is not applied on every re-entry path; tail-only resurface, self-healing, one code comment overclaims)
Every reader of the condemnation, traced: session-local
`playerDeadURLs` is read only by the merge guard (PlayerView.swift:1568)
and the settle filter/union (:1677/:1679) of the SAME session;
hub `provenDead` is read only by MatchPlaySession.isKnownDead (:1467-1468),
which is called only by publishHeadNow (:1440-1441). Consequences:
- Fresh VN session, new key (host cover-swap swapToVNRow,
  ContentView.swift:131-139, rotates the ladder → new ResolveHub key):
  run()'s publications do not consult provenDead. A condemned URL whose
  failure class pre-flight KEEPS — the 403 case (SourcePreflight returns
  .kept for a repair-surviving 403, PlayerView.swift:1103-1121 region) —
  can be re-published as a kept-tail rung of the new session and handed
  to the player once, where it re-fails and re-marks (per-session insert
  guard :1513, so the player-dead line fires once per session). It can
  never return as the instant head (publishHeadNow filters it), and the
  cert/404 classes do not resurface on a live-window fixture because
  pre-flight independently convicts them there (404/410 → .dead;
  TLS transient → .dead when mustBeServing — call sites :1129/:1135,
  test defined :1227-1229).
- EN (Nuvio) path: contrary to a possible first reading, EN sessions DO
  pass through MatchPlaySession and PlayerView — the mark fires and feeds
  the hub exactly as for VN (PlayerView.swift:152-160 applies to the
  playEN route too, ContentView.swift routeContent). But re-entry is not
  filtered: NuvioAddonStore.session(for:) (NuvioAddon.swift:829-868)
  never consults ResolveHub/provenDead, its own ladders cache (:777,
  written at fetch time :862, 60 s/30 s TTL) is never filtered by any
  dead set, and it calls session.begin(ladder:) directly — no
  publishHeadNow. A player-condemned EN URL can therefore re-enter the
  same way as above (kept tail / sole rung, 403 class), re-fail, re-mark.
  The FIX-129 report does not declare this boundary (its declared
  residual covers only the born-cached VN path).
- Playlist 24/7 EN channels (ContentView.swift:~1149-1160 direct play):
  these DO go through ResolveHub.session(for:) with a single-source
  ladder (PlaylistStore.sources(for:) returns [ch] for isEN channels),
  so the head is filtered — publishHeadNow publishes nothing — but run()
  can still re-publish the sole rung as kept tail in the 403 case.
  Sole-source: no alternative exists to substitute, and cert/404 are
  fully excluded here because mustBeServing is true when kickoff == nil.
- In-session explicit pick: switchToVN (PlayerView.swift:296-313) will
  retry a condemned rung once when the owner explicitly picks its row —
  consistent with the standing warmed-dead doctrine (advance() comment:
  only automatic advance skips; an explicit board pick always tries).
  Not counted against the fix.
- The PlayerView call-site comment (PlayerView.swift:155-159) states the
  mark means "no later merge, publish or tap hands it to a player
  again" — that overclaims against the fresh-session/EN re-entry above.
  The markPlayerDead doc (:1508-1511) claims only publishHeadNow
  filtering, which is accurate.
What IS fully closed (verified, §3 below): same-session merge, this
session's settle/cache write, born-cached and seeded replay from a
post-mark settle (entry sources exclude the URL), and the head of every
later VN tap. The residual is tail-only, one extra failover stop at
worst, and self-healing. Recorded, not blocking.

---

## Focus verification

### 1. Launch warming vs user behaviour — VERIFIED (with MINOR-1)
- Contention on the 2-concurrency budget: one driver, `active < 2`
  loops (runDriver, PlayerView.swift:~1940-1975 region), one ephemeral
  URLSession per driver run — distinct from pre-flight's per-run session
  (MatchPlaySession.run) and from the player's AVPlayer. No shared
  session, no shared lock; ResolveHub, MatchPlaySession and
  SourcePrewarmStore are all @MainActor and every network call is in a
  nonisolated enum (SourcePrewarmer/SourcePreflight) reached by awaits,
  so the only main-actor work on the tap path is synchronous queue/log
  bookkeeping. No priority inversion found: a later warm() call's
  pending rebuild is picked up by the running driver at its next
  completion, in-flight warms (≤2) are never preempted, and the tap
  path (ResolveHub.session → publishHeadNow) never waits on the
  pre-warm store — it only READS isDead verdicts (isKnownDead :1467-1469).
  Worst case for a board warm's START is the remainder of ≤2 in-flight
  launch warms (each bounded by SourcePrewarmer's 4 s-capped fetches);
  playback itself is never gated on any warm. Bandwidth is bounded:
  ≤3 launch heads × (16 KB + 16 KB + 256 KB) worst case.
- Backgrounded mid-launch-warm: nothing in the store or ContentView
  cancels or re-queues warming on scenePhase changes (ContentView
  .onChange(of: scenePhase) only refreshes playlist/Nuvio). Suspension
  can at worst fail an in-flight fetch transiently, which SourcePrewarmer
  reports as non-dead → the URL is marked .warm without a completed
  descent — the report's declared "ready" semantics; no false death is
  possible from this path (death is judged only on a 404/410 or a
  non-playlist 200 body actually received). A cancelled driver resets
  .warming states to nil in its defer, so nothing is left half-marked.
- Playlist refresh replacing the set: PlaylistStore.refresh()
  (PlaylistStore.swift:448ff) touches neither ResolveHub nor
  SourcePrewarmStore. Warm tasks from the old set finish harmlessly
  (verdicts keyed by URL; a rotated signed URL's verdict is simply
  never read again), ResolveHub entries keep their URL-list keys, and
  the launch set itself was computed after the first refresh inside
  start(). Later auto-refreshes do not re-run the launch warm (the root
  .task runs once) — post-refresh fixtures are covered by the board-open
  warm + board-open preresolve exactly as in 1.28. No stale-ladder
  replay hazard found: ResolveHub.key(for:) is the ordered URL list,
  so a refreshed ladder is a different key and resolves fresh.

### 2. Player-dead lifecycle — VERIFIED (with MINOR-2)
Reader graph (grep over DaBanh/*.swift, all hits read): writers —
markPlayerDead (PlayerView.swift:1512-1516, insert-guarded, hub feed),
noteResolved formUnion (:2284), notePlayerDead (:2051-2052). Readers —
merge guard :1568, settle :1677/:1679, isKnownDead :1467-1468 ←
publishHeadNow :1440-1441 only. Across an in-place switch (same session:
set persists, explicit pick retries once by doctrine), a cover-swap
(new session: head filtered, tail resurface per MINOR-2), a board
re-open (post-mark settle → fresh-cache born-cached and stale seeded
replays both exclude the URL, because noteResolved filtered the entry's
sources; the seeded session's own revalidation merge is also guarded
because it is the same session object the player marks), and a playlist
refresh (provenDead is in-memory and untouched by refresh; the playlist
layer's separate invalidURLs set is a different, pre-existing store,
unmodified). EN/24-7 scope: see MINOR-2 — marking is in-scope and
works on those paths; re-entry filtering there is an undeclared
boundary, bounded as described.

### 3. Castilla sequence replay (1.28 log lines 285-307) against the NEW code — VERIFIED in substance
- L285-287 (21:35:16Z board open, 2 sources; board-open preresolve
  creates the session; log's "new session" is that preresolve session):
  unchanged paths (ContentView boardPanel.onAppear preresolve;
  MatchBoardView .task warm). New code adds nothing here.
- L288-293 (21:35:19Z pick adopts in-flight, instant head =
  v1.livestreambong.tv, route, try #0, open resolving=true): unchanged;
  publishHeadNow at adoption — head not known dead yet, publishes as
  before.
- L294 (21:35:20Z cert failure): noteFailure (PlayerView.swift:727-742)
  logs the identical "source #0 failed" line, then
  definitiveFailureReason (:777-800) convicts — TLS branch via the
  underlying-error chain (NSURLErrorDomain −1200…−1206, depth 3) and
  independently via the "certificate" localized-text fallback — then
  onDefinitiveFail fires BEFORE fireFailOnce/advance:
  markPlayerDead logs "player-dead: v1.livestreambong.tv —
  TLS/certificate invalid", inserts session playerDeadURLs + hub
  provenDead. Walkthrough C3's ordering claim matches the code exactly.
- L295-296 (advance, player waiting at #1): unchanged branches.
- L297 (21:35:21Z first batch, 1 source): with the new code publish()
  still runs and the "ladder first batch" line still fires (its guard
  counts the already-published head), but merge() skips the condemned
  URL (:1568) — the in-place republication that killed the 1.28 session
  no longer happens. The walkthrough's phrase "the second publish no
  longer happens" is loose wording for this (a publish occurs; the dead
  URL is not re-merged) — substance correct, not a finding.
- L298 (no signal at #1 in 1.28): under the new code this line fires
  only if the fixture's other source also fails to publish; the
  condemned URL itself can no longer be the rung that exhausts the
  ladder. At settle, noteResolved receives sources filtered by
  playerDeadURLs and deadURLs ∪ playerDeadURLs (:1675-1680) — the
  cache entry cannot inherit the URL. (Precision note: the session's
  LIVE ladder still contains the already-published head rung — the
  prefix never moves, merge comment :1560-1567 — the walkthrough's
  "excluded from sources" is exact for the cache entry, not for the
  live ladder the player has already advanced past. No behavioural
  consequence.)
- L300-307 (second pick 21:35:24-26Z, "new session" at :303, ~4 s to
  no-signal at the same head): the log's own "new session" line shows
  this topology takes the fresh-session branch, so publishHeadNow IS
  the operative mechanism the walkthrough names: isKnownDead(head) is
  now true via provenDead → the first uncondemned rung publishes
  instead (or nothing, if all condemned), and the cert-dead host is
  not re-tried as head. Had the topology instead hit the fresh-cache
  branch, the born-cached ladder already excludes the URL — same
  outcome. Walkthrough C3: confirmed.

### 4. Alias second-order effects (psg / newcastle / olympique lyon) — VERIFIED with my own harness probes
I ran the corpus harness (which parses the Swift tables) myself:
- canon("Psg") = canon("Paris Saint-Germain") = canon("Paris Saint
  Germain") = "paris saint germain"; canon("Paris FC") = "paris" —
  distinct. crest_url("Psg") and crest_url("Paris Saint-Germain")
  return the IDENTICAL badge URL. Concrete fixture (Nice vs PSG,
  23:15 21/11): grouping pair, state pairKey (MatchStateStore binds via
  MatchMatching.pairKey → TeamNameNorm.pairKey, MatchStateStore.swift
  :248-262, state(for:) :1262) and crest candidate chain (Crests.swift
  candidateKeys :279-287 appends groupKey + canonicalKey; learned
  registry keyed by canonicalKey :131-134) all land on the one club.
- canon("Newcastle") = canon("Newcastle United") = "newcastle united";
  canon("Newcastle Jets") = "newcastle jets" — distinct (exact-stem
  lookup, TeamNameNorm.swift:599). crest_url identical for both
  Newcastle spellings. Fixture vs Arsenal: same convergence through
  grouping → state → crest.
- canon("Olympique Lyon") = canon("Lyon") = "lyon" (:600);
  crest_url identical for both spellings. Fixture vs LOSC Lille: same
  convergence. (The pre-existing token alias "lyonnes"→"lyon" at :151
  predates FIX-129 and is untouched.)
- DaBanhTV: project.yml's DaBanhTV target compiles TeamNameNorm.swift
  and Crests.swift (project.yml:84-85) and NOT ContentView/PlayerView;
  FixtureGrouping lives in Crests.swift and keys through
  TeamNameNorm.groupKey (:495-502), the same pipeline LOOP1 reproduced
  converging on both keys for all 12 aliases. There is no TV-only
  spelling table to diverge, and the dangerous stems above stay
  distinct under groupKey as under canonicalKey — no TV regression
  path found. TV compilation itself remains CI's to prove (LOOP1
  UNVERIFIED (c), not assumed here).

### 5. Log contract — VERIFIED
Complete list of NEW DiagLog lines in FIX-129 (enumerated from the
code; grep "prewarm:" / "player-dead:" over DaBanh/*.swift returns
exactly these plus the pre-existing dead line):
- "prewarm: launch warm queued — N featured head source(s)"
  (ContentView.swift:219) — once per app launch (root .task).
- "prewarm: warming '<title>' host=<host>" (PlayerView.swift:1918,
  in runDriver's takeNext) — once per warm ATTEMPT of a URL: a URL in
  state .warm/.dead is filtered out of every later warm() call, so in
  normal flow this is once per URL per run; a second firing requires a
  driver cancellation resetting .warming → nil (player close), i.e. a
  genuinely new attempt. Not per-frame, not per-refresh (PlaylistStore
  refresh never calls warm()).
- "prewarm: ready '<title>' host=<host> in <ms>ms"
  (PlayerView.swift:1966) — once per completed, non-cancelled warm
  attempt, the counterpart of the start line; same once-per-URL-per-run
  bound and the same cancellation caveat. "Ready" carries the report's
  declared semantics (attempt completed without definitive death).
- "player-dead: <host> — <reason>" (PlayerView.swift:1515) — once per
  URL per session (insert guard :1513), plus the VC's firedFail guard
  bounds it to one failure per surface; across sessions it can fire
  again only when a player actually fails that URL again (cf. MINOR-2).
- The pre-existing "prewarm: source proven dead" line (:1952) is
  byte-identical to its pre-1.29 form (LOOP1 verified against the 1.28
  record; the 1.28 device log contains zero "prewarm" and zero
  "player-dead" lines — grep counts 0/0, re-verified by me), and the
  "source #N failed" line in noteFailure (:731-734) matches the 1.28
  log's format verbatim (log line 294). No other DiagLog call sites
  were added or reworded in the FIX-129 change regions. Volume is
  bounded and episode-shaped throughout — no spam path found.

---

## Verified vs UNVERIFIED
VERIFIED by my own reading/probes: gate anchors (below); prewarm
driver/store mechanics, all warm() call sites (ContentView:220,
MatchViews:1008/1012, PlayerView:1480), cancelPending's only caller
chain, scenePhase and refresh non-interference; the complete
provenDead/playerDeadURLs reader-writer graph (grep + read) across
session switches, cover-swap, board re-open, refresh, EN (Nuvio) and
24/7 paths; Castilla replay line-by-line (log lines 285-307) against
noteFailure/classifier/markPlayerDead/merge/settle/publishHeadNow in
the current code; canon + crest_url identity for psg/newcastle/
olympique lyon (+ Paris FC / Newcastle Jets separation) via the corpus
harness run by me; DaBanhTV target source list and the shared
groupKey path; the 4 new DiagLog lines, their fire-once bounds, and
0/0 prewarm/player-dead counts in the 1.28 log.
UNVERIFIED: (a) compilation — no Swift toolchain on this VM; CI is the
gate (same as LOOP1; not assumed anywhere above — every claim is a
static read or a harness probe); (b) LOOP1's UNVERIFIED items remain
unverified here by design: the fix agent's fresh-playlist group counts
and censuses, DaBanhTV compilation, on-device errorLog() timing
(fail-open by design); (c) on-device warm behaviour under real
background suspension (reasoned from code only — no background-task
machinery exists in the store to observe); (d) whether the second
Castilla source would have published under the new code — the 1.28 log
does not record its pre-flight outcome, and the walkthrough's outcome
does not depend on it.

## md5 anchors (measured by LOOP2, byte-identical to LOOP1)
- DaBanh/TeamNameNorm.swift: 8aa68a4cca08e136340d44565b80ee2b
- DaBanh/ContentView.swift: e662ddc81dd293246bcb44171e29e132
- DaBanh/PlayerView.swift: b59dfaef565042ee7f42f0309347a4f4

REVIEW-129-LOOP2: CLEAN (2 MINOR, 0 MAJOR).
- 2026-11-20T21:59Z — DONE: verdict written (CLEAN, 2 MINOR, 0 MAJOR); anchors re-measured byte-identical at close. No Swift file edited.
