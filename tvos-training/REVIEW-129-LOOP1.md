# REVIEW-129-LOOP1 — Đá Banh iOS FIX-129 (DB-09 aliases + Item B launch warm + Item C player-dead)

Reviewer: independent Swift review, LOOP 1 of the 3-consecutive-clean-rounds gate.
Scope read from CURRENT code only (read-only review; no Swift file edited):
TeamNameNorm.swift, ContentView.swift, PlayerView.swift, plus PlaylistStore.swift /
NuvioAddon.swift / MatchViews.swift call sites and project.yml target lists.
Fix report under review: tvos-training/FIX-129-REPORT.md.

## Progress log (supervision law)
- 2026-11-20T21:46Z — START: read FIX-129-REPORT.md + TeamNameNorm.swift in full. Next: ContentView/PlayerView changed regions.
- 2026-11-20T21:47Z — READ: ContentView launch .task block, PlayerView Item B (SourcePrewarmStore) + Item C (classifier, markPlayerDead, merge, ResolveHub) regions, project.yml targets. Next: harness reproduction of Item A claims.
- 2026-11-20T21:48Z — HARNESS REPRODUCED: run_checks.py on the frozen corpus (whole=103, unit fails 0, FotMob/ESPN collisions 0/0, groups 116) + my own convergence probes for all 12 new aliases + synthetic "Havre AC" Troyes test (1 group, 12→13 members, crest resolves). Next: Item B/C adversarial walks + Swift 6 / cross-target checks.
- 2026-11-20T21:49Z — WALKS DONE: classifier transient cases, KEPT-403 isolation, merge-bypass reachability, cross-fixture scope, once-per-URL guard, NSLock grep (0), brace balance (0/0/0). No blocker hit. Writing verdict.

---

# VERDICT: CLEAN

No MAJOR findings. Three MINOR findings (documentation errata + two bounded,
inert-or-declared edges) — none changes behaviour, none blocks the gate.
Details below; every claim carries the file:line I read it from.

---

## Findings

### MINOR-1 (documentation errata in FIX-129-REPORT.md — code is correct)
- The report (§C1 + change inventory) cites run()'s merge guard at
  PlayerView.swift:1558 and the MatchPlaySession change region as ending
  :1560. The actual guard is at **PlayerView.swift:1568**
  (`if self.playerDeadURLs.contains(ch.url) { continue }`), inside
  publish(final:)'s nested merge(). All other anchors I checked are exact:
  definitiveFailureReason :777, markPlayerDead :1512, player-dead log :1515,
  ResolveHub.notePlayerDead :2051, merge-exclusion settle lines :1677/:1679,
  prewarm warming :1918, prewarm ready :1966, launch-queued log
  ContentView.swift:219, alias entries TeamNameNorm.swift:589–600 with the
  evidence comment block opening at :532.
- §C1 calls the HTTP-status source "the item's ACCESS LOG
  (AVPlayerItemAccessLogEvent)". The code at PlayerView.swift:778 reads
  `playerItem?.errorLog()?.events` — AVPlayerItemErrorLogEvent, which is the
  event type that actually carries `errorStatusCode`. The code's API choice
  is the right one; only the report's naming is off. No code change wanted.

### MINOR-2 (Item C classifier — bounded edge, same-item only)
definitiveFailureReason (PlayerView.swift:777–800) scans the error log for
the newest event with `errorStatusCode != 0` and convicts on 403/404,
breaking on any other non-zero code (:779–785). Zero-coded events are
skipped, so in the narrow case where an item logged a 403 event earlier in
its own playback attempt and the terminal failure's own event carries 0
(network-class), the earlier 403 would convict. Bounded: same item, same
URL, same playback attempt — a 403 that URL served during that attempt is
still evidence about that URL — and noteFailure only runs when the item
failed overall (a 403 on one variant that another variant recovered from
never reaches the classifier, because the item never fails). Recorded, not
blocking; the opposite failure (log event late/missing → no conviction) is
fail-open and is declared in the report.

### MINOR-3 (Item C settle — inert inconsistency)
run()'s settle call (PlayerView.swift:1675–1680) filters playerDeadURLs out
of the cached `sources` but passes `verifiedURLs: Set(verified.map { $0.1.url })`
unfiltered (:1680), so a player-condemned URL that pre-flight had verified
can remain named in the entry's verified set. Inert: tapSeedOrder
(ResolveHub) consults verifiedURLs only for a pick already present in
entry.sources, and publishHeadNow filters through isKnownDead/provenDead
regardless of tier. No behavioural consequence found; recorded for the
record, no fix required for this gate.

---

## Checklist verification (primary code evidence)

### 1. Alias safety (Item A) — VERIFIED, harness numbers REPRODUCED by me
- The 12 entries are whole-name aliases only, at TeamNameNorm.swift:589–600,
  applied by exact-stem dictionary lookup in pipeline step 8
  (TeamNameNorm.swift:723–725). No pipeline, filler, token-alias or suffix
  rule changed; "ac" remains a filler token (fillerTokens, TeamNameNorm.swift
  filler set) — which is exactly the DB-09 mechanism: "Havre AC" → stem
  "havre" → new alias → "le havre".
- I re-derived canonical() AND groupKey() for both sides of every fixed pair
  through the corpus harness (which parses the Swift tables directly).
  All converge, canonical and grouping keys alike:
  Havre AC / Havre / Havre Athletic Club = Le Havre ("le havre");
  Dep.Independiente = Independiente Medellin; Ind. Santa Fe /
  Independiente Santa Fe = Santa Fe; Atl. Bucaramanga = Atletico
  Bucaramanga ("bucaramanga"); Atl San Luis = Atletico San Luis;
  Dep La Coruna = Deportivo A Coruna; Leeds = Leeds United;
  Tottenham = Tottenham Hotspur; Ipswich = Ipswich Town; PSG = Paris
  Saint Germain; Newcastle = Newcastle United; Olympique Lyon = Lyon.
- Dangerous-stem spot checks (my own probes): "newcastle jets" stays
  distinct from "newcastle united"; "paris" (Paris FC) stays distinct from
  "paris saint germain"; bare "independiente" (Argentine club shape) stays
  distinct from "independiente medellin" — the alias fires only on the exact
  stem "dep independiente"; "leeds rhinos" ≠ "leeds united";
  "sheffield united" ≠ "sheffield wednesday"; "atletico madrid" ≠
  "atletico"; "deportivo cali" ≠ "deportivo a coruna"; "chievo verona" ≠
  "verona"; Melbourne United / Melbourne Tigers remain two distinct stems
  (deliberately NOT aliased, as the report states); football and basketball
  "Barcelona" share the stem "barcelona" exactly as before this fix (no new
  alias touches it — the rejected candidate was correctly left alone, sport
  separation lives outside TeamNameNorm, unchanged).
- Women/age discipline intact for the new stems (my probes): canonical
  strips the women marker then aliases ("Leeds United Women" →
  "leeds united"), grouping key keeps it ("leeds united women"); age tags
  re-attach after aliasing ("Le Havre U17" → "le havre u17").
- Harness claims REPRODUCED by running corpus127/run_checks.py myself
  against the current Swift tables: table fidelity wholeNameAliases
  harness=103, line-range=103, identical; **unit fails 0; FotMob
  collisions 0 (770 id-keyed pairs); ESPN collisions 0 (99); frozen groups
  116 (115 pair + 1 legacy)** — all unchanged from pre-fix, as claimed.
- Troyes proof REPRODUCED my way: frozen corpus = 1 group / 12 members for
  "le havre vs troyes"; appending a synthetic channel titled "Troyes vs
  Havre AC" at the same kickoff yields **1 group / 13 members** (total
  groups stay 116) and crest_url("Havre AC") now resolves to the same badge
  as "Le Havre" (was the placeholder path pre-fix).
- The fix agent's fresh-playlist numbers (mirror 189→179, origin 127→120)
  are NOT reproduced — the fresh files were not persisted to the workspace;
  they remain the fix agent's numbers (see UNVERIFIED). The "havre" producer
  evidence is the owner's screenshot, as the report itself declares; the
  mechanism is probe-proven above.

### 2. Item B — launch host warming — VERIFIED
- Same set, exactly: ContentView.swift:191–193 preresolves
  `featuredEntries.prefix(3)` ladders; :214–215 builds heads from the SAME
  `featuredEntries.prefix(3)`, one `.first` per fixture, inside the SAME
  synchronous MainActor.run block (no suspension between the two
  evaluations, so the computed featuredEntries cannot change in between).
  Bound is real: ≤3 heads. Exactly ONE warm() call: ContentView.swift:220
  `SourcePrewarmStore.shared.warm(ladder: heads)`. The queued log line is
  at :219 with the actual head count.
- Cannot delay/block the first pick: warm() only rebuilds the pending
  queue and starts the existing driver Task (SourcePrewarmStore,
  PlayerView.swift warm/startDriverIfNeeded); all fetching happens in the
  driver's task group through the nonisolated SourcePrewarmer. The launch
  block itself does no awaiting network work, and no fixture can be tapped
  before store.start() completes (the board is empty until then).
- Driver semantics unchanged apart from triggers + logging: max 2
  concurrent (runDriver's `active < 2` loops), per-call queue rebuild and
  board-open re-prioritisation are the pre-existing store behaviour (the
  other warm call sites — MatchViews.swift:1012 board open, session
  beginPrewarming — are untouched). New state is one local dictionary
  `startedAt` (PlayerView.swift:~1899) written in takeNext() and read once
  per completion for the ready line's elapsed ms.
- Log lines, read from code: "prewarm: warming '<title>' host=<host>"
  (PlayerView.swift:1918, via diagSourceTag), "prewarm: ready '<title>'
  host=<host> in <ms>ms" (:1966), "prewarm: launch warm queued — N featured
  head source(s)" (ContentView.swift:219). The pre-existing dead line at
  PlayerView.swift:1952 is byte-identical to its pre-1.29 form as quoted in
  FIX-128-REPORT.md:112 / REVIEW-128-LOOP1.md:48 ("prewarm: source proven
  dead — the ladder will skip it: …"). The 1.28 device log
  (dabanh-diag-8da7e8ba.log) contains zero "prewarm" lines (grep count 0,
  verified by me) — consistent with the report's B1 claim that start/ready
  were silent before this fix.

### 3. Item C — player-definitive-death feedback — VERIFIED
Classifier (LivePlayerViewController.definitiveFailureReason,
PlayerView.swift:777–800), walked case by case:
- Timeout (NSURLError -1001), DNS failure (-1003), connection lost (-1005),
  HTTP 500: none is in the TLS range, a 500 newest error event breaks the
  HTTP scan without convicting, and none of their localized texts contains
  "certificate" → nil, nothing marked. ✓
- TLS family: NSURLErrorDomain codes -1200…-1206 searched through the
  underlying-error chain to depth 3 (:787–794), plus the "certificate"
  localized-text fallback (:796–799) — a cert error reported only via
  localizedDescription text convicts, as the brief requires. The Castilla
  error from the 1.28 log ("The certificate for this server is invalid.")
  convicts on both paths.
- HTTP branch fail-open: missing/empty error log, or a newest non-zero
  code that is not 403/404, falls through to the TLS checks and then nil —
  a late/missing access-log event means NO conviction, never a false one
  (the report's declared limit; my MINOR-2 records the mirror edge).
- Pre-flight KEPT-403 untouched: SourcePreflight.verify
  (PlayerView.swift:1103–1121) still returns .kept for a 403 surviving
  Referer repair; nothing in the pre-flight path reads or writes
  provenDead/playerDeadURLs. The player classifier is a separate code path
  reached only from noteFailure. ✓
- Plumbing signatures match at every joint (read, not assumed):
  PlayerView passes onDefinitiveFail at :152–160 →
  LivePlayerSurface property :399–410, forwarded in makeUIViewController →
  VC property :466, fired in noteFailure BEFORE fireFailOnce (:738–741;
  noteFailure's only callers are :698 and :709, both passing Error?,
  matching the changed signature) → session.markPlayerDead(channel,
  reason:) :159 → MatchPlaySession.markPlayerDead(_:reason:) :1512 →
  ResolveHub.notePlayerDead(url:) :2051. LivePlayerSurface has exactly one
  call site (PlayerView.swift:141). playerItem is stored at viewDidLoad
  (:516 region) and cleared in teardown.
- Once per URL per session: markPlayerDead guards on
  `playerDeadURLs.insert(ch.url).inserted` (:1513) — the log line
  "player-dead: <host> — <reason>" (:1515) and the hub feed happen only on
  first insert; the VC's own firedFail guard additionally bounds it to one
  failure per surface.
- Same store, both consumers: the merge skip reads the session's
  playerDeadURLs (:1568, inside publish(final:)'s merge — which serves
  BOTH the verified batch and the kept tail); the settle filters sources
  and unions the dead set at :1677–1679; publishHeadNow's filter
  (isKnownDead, :1467–1470) reads ResolveHub.provenDead, the very set
  notePlayerDead inserts into (:2051–2053) and noteResolved formUnions
  into (:2284). One store, no parallel bookkeeping.
- Merge-bypass check (the direct-assignment branch): publish(final:) assigns
  `self.sources = ordered` directly, bypassing merge(), only when neither
  `published` nor `headPublished` is set. That branch is unreachable with a
  non-empty playerDeadURLs: a player surface for a session exists only
  after that session's sources became non-empty, which happens only via
  publishHeadNow / adoptSeed (both set headPublished), a prior publish
  (sets published), or a born-complete cached/seeded session (which never
  runs run()). Nuvio sessions (NuvioAddon.swift:829) also enter through
  begin(ladder:) → the same publish paths. The Castilla shape — instant
  head published (headPublished=true), cert death marked, first batch
  merging behind — goes through merge() and the dead URL is skipped, as
  the report's C3 walkthrough claims.
- Cross-fixture scope: notePlayerDead feeds the hub-wide, per-app-run
  provenDead — the SAME store and lifetime pre-flight verdicts already fed
  via noteResolved pre-1.29. A condemned URL is filtered for other fixtures
  only where those fixtures' ladders carry the identical URL, exactly the
  pre-existing provenDead scope; nothing broader was introduced. The
  born-cached residual (a fresh cache entry written before the mark can
  hand the URL to a player once) is declared in the report and is
  self-healing (that play fails, marks, advances). Accepted as declared.

### 4. Swift 6 — VERIFIED by inspection (compile itself UNVERIFIED, no toolchain)
- No NSLock anywhere in the three changed files (grep: 0 hits for
  NSLock/lock()/unlock()).
- No new shared-state races found: ResolveHub and MatchPlaySession are
  @MainActor and every new call into them follows the existing
  onReady→beginPrewarming pattern; the error-log read happens in
  noteFailure, whose two call sites both run on the main queue (KVO hop to
  main, observer queue .main); SourcePrewarmStore's startedAt is a
  runDriver-local captured only by its nested takeNext() and the driver
  loop — the task-group children touch only the nonisolated
  SourcePrewarmer.
- Brace/paren/bracket balance is 0/0/0 in all three files (crude count).
  Callers/callees signatures cross-checked in §3 above and §2
  (PlaylistStore.sources(for:) at PlaylistStore.swift:605;
  SourcePrewarmStore.warm(ladder:) defaults at its existing declaration).
  Anything beyond this static read is UNVERIFIED — CI remains the compile
  gate, as the brief states.

### 5. Cross-target — VERIFIED
- TeamNameNorm.swift imports Foundation only (:1) and the FIX-129 change
  is table-only (12 dictionary entries + comments); its public API
  (norm/groupKey/canonicalKey/pairKey/hasWomenMarker/strippingAgeTag/
  droppingStateSuffix) is unchanged. No iOS-only API crept in.
- project.yml: DaBanhTV target sources include DaBanh/TeamNameNorm.swift
  (:85) and DaBanh/Crests.swift (:84), and do NOT include ContentView.swift
  or PlayerView.swift — Items B and C are iOS-target-only, as claimed.
- Crests.swift and MatchStateStore.swift were not touched in the FIX-129
  window (mtimes 2026-11-20 18:23Z / 18:38Z vs the fix files' 21:43–21:44Z);
  their public APIs are therefore unchanged by construction.

---

## Verified vs UNVERIFIED
VERIFIED by my own reading/reproduction: all 12 alias convergences (both
keys, both sides); dangerous-stem separations; frozen-corpus harness
numbers (103 / unit 0 / collisions 0+0 / groups 116); synthetic Havre AC
group merge (12→13) + crest resolution; Item B set identity, ≤3 bound,
single warm() call, log-line strings, dead-line byte identity against the
1.28-era record, zero prewarm lines in the 1.28 device log; Item C
classifier walks (timeout/DNS/connection-lost/500/kept-403/missing-log/
cert-text), plumbing signatures, once-per-URL guard, merge + settle +
publishHeadNow sharing the one provenDead store, merge-bypass
unreachability argument; no NSLock; Foundation-only shared file; target
lists; Crests/MatchStateStore untouched.
UNVERIFIED: (a) compilation — no Swift toolchain on this VM; CI is the
gate; (b) the fix agent's fresh-playlist group counts (mirror 189→179,
origin 127→120) and its fresh-playlist one-club censuses — the fresh files
are not in the workspace, so those remain the fix agent's numbers, declared
as such; the frozen-corpus evidence above independently covers the
mechanism and the Troyes fix; (c) DaBanhTV target compilation with the new
table (table-only, Foundation-only — risk minimal, still CI's to prove);
(d) on-device behaviour of errorLog() timing (fail-open by design).

## md5 anchors (code as it stands at this verdict — must stay byte-identical across loops 2–3)
- DaBanh/TeamNameNorm.swift: 8aa68a4cca08e136340d44565b80ee2b
- DaBanh/ContentView.swift: e662ddc81dd293246bcb44171e29e132
- DaBanh/PlayerView.swift: b59dfaef565042ee7f42f0309347a4f4

REVIEW-129-LOOP1: CLEAN (3 MINOR, 0 MAJOR).
