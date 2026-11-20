# REVIEW-129-LOOP3 — Independent Swift Review, LOOP 3 (final)

- Started: 2026-11-20T21:54:26Z
- Reviewer: subagent LOOP3 (read-only; no Swift edits)
- Gate anchors expected:
  - TeamNameNorm.swift 8aa68a4cca08e136340d44565b80ee2b
  - ContentView.swift e662ddc81dd293246bcb44171e29e132
  - PlayerView.swift b59dfaef565042ee7f42f0309347a4f4

## Progress log
- [2026-11-20T21:54:26Z] Anchors verified byte-identical (md5sum matches all three). Proceeding to full inventory + adversarial close-out.

- [2026-11-20T21:56Z] Inventory done: only TeamNameNorm/ContentView/PlayerView newer than 1.28 delivery (21:31:07Z); project.yml at 21:24Z (1.28 bump, pre-fix), DaBanhTV own files untouched (Nov 13/18), no entitlements change. Next: adversarial alias probes via corpus harness + playback code traces.
- [2026-11-20T22:00Z] Alias probes done (17 probes run myself via harness: all distinct-club pairs split on both keys; women/youth variants split on groupKey; 3 same-club controls merge). Playback traces done (sole-source settle, shared-URL false-death, relaunch persistence). Writing verdict.

---

# VERDICT: CLEAN

No MAJOR findings. Two MINOR findings — one is the confirmation (not
re-litigation) of LOOP2 MINOR-2's boundary plus the report's one
understated declared limit; the other is a no-producer women's group-key
observation that predates FIX-129's mechanism. Neither blocks the gate.
**The 3-round gate is satisfied on these bytes** (LOOP1 CLEAN, LOOP2
CLEAN, LOOP3 CLEAN, all on byte-identical code — anchors re-measured
below).

---

## Findings

### MINOR-1 (LOOP2 MINOR-2 boundary CONFIRMED exactly as described, no wider; FIX-129-REPORT's declared residual is understated against it)
Per the brief I did not re-litigate LOOP2 MINOR-2; I re-derived its
reader graph from the current code and confirm it is EXACTLY as LOOP2
described and no wider:
- Writers: MatchPlaySession.markPlayerDead (PlayerView.swift:1512-1516,
  insert-guarded, feeds hub) and ResolveHub.noteResolved's formUnion
  (:2284). Readers of hub provenDead: exactly one chain —
  ResolveHub.isProvenDead (:2040-2041) ← MatchPlaySession.isKnownDead
  (:1467-1469) ← publishHeadNow only (:1440-1441, head + substitute
  scan). Session-local playerDeadURLs is read only by the merge guard
  (:1568, verified at that line in the current bytes) and the settle
  filter/union (:1677/:1679 region; read by me at :1675-1680 in LOOP1
  numbering — current read: noteResolved call filters
  `!deadURLs.contains && !playerDeadURLs.contains` and unions the dead
  set). My grep over PlayerView.swift for isKnownDead/isProvenDead/
  notePlayerDead returns no other call site. No additional reader, no
  additional resurface path exists beyond LOOP2's enumeration.
- The resurface is therefore bounded exactly as LOOP2 stated: a
  player-condemned KEPT-class (403) URL can be re-published ONCE as a
  kept-TAIL rung by a fresh session's run() or an EN re-entry (neither
  consults provenDead); it can never return as an instant head
  (publishHeadNow filters it); cert/404 cannot resurface on live
  fixtures (pre-flight independently convicts them there). The
  call-site comment at PlayerView.swift:155-159 ("no later merge,
  publish or tap hands it to a player again") still overclaims against
  this boundary — errata, as LOOP2 recorded. The markPlayerDead doc
  (:1508-1511) claims only publishHeadNow filtering and is accurate.
- Consequence for the report: FIX-129-REPORT.md's declared Item C
  residual ("a cache entry written by ANOTHER fixture before a
  player-dead mark… via the born-cached path") is UNDERSTATED — the
  actual boundary also includes fresh-session and EN re-entry (see
  Declared limits §5.4). Behaviour is bounded and self-healing in all
  three shapes; this is a documentation finding, not a code finding.

### MINOR-2 (women's group-key asymmetry on the new stems — pre-existing pipeline property, NO producer in the frozen corpus, canonical/state binding unaffected)
My own probes (below, P9 family): in groupKey mode the women marker is
retained, so a whole-name alias fires only on the bare stem — the two
spellings of the same WOMEN's club split at group level:
group("Lyon Women")="lyon women" vs group("Olympique Lyon
Women")="olympique lyon women"; group("Leeds Women")="leeds women" vs
group("Leeds United Women")="leeds united women"; group("Psg
Women")="psg women" vs group("Paris Saint-Germain Women")="paris
saint germain women"; group("Newcastle Women")="newcastle women" vs
group("Newcastle United Women")="newcastle united women". Canonical
keys converge for every one of these pairs ("lyon", "leeds united",
"paris saint germain", "newcastle united"), so state binding and crest
identity are unaffected; only channel GROUPING would split if both
spellings were ever listed for the same women's fixture. This is not
introduced by FIX-129: it is the standing behaviour of all 103
whole-name aliases (the alias lookup is exact-stem in both modes; the
women strip is canonical-only by design, LOOP1 §1). Producer census:
the frozen playlist contains NO women's listing for any of the 12 new
stems (grep: only men's Nice vs Paris Saint Germain and LOSC Lille vs
Lyon listings), and the frozen feeds carry none either. Recorded as a
watch item for the day a women's listing in both spellings appears;
not a defect in this fix.

---

## 1. Complete change inventory — VERIFIED complete
Method: full-tree mtime scan against the 1.28 delivery instant
(2026-11-20T21:31:07Z, deliveries/DaBanh-ipa-run80-v128.ipa), plus
FIX-129 marker grep, plus my own read of every touched region.
- Files modified after the delivery instant, excluding tvos-training/
  (reports + corpus data) and deliveries/: EXACTLY THREE —
  DaBanh/TeamNameNorm.swift (21:43:19Z), DaBanh/ContentView.swift
  (21:43:38Z), DaBanh/PlayerView.swift (21:44:48Z). No other code file
  in the tree moved in the fix window (next-newest DaBanh file:
  MatchStateStore.swift 18:38Z, Crests.swift 18:23Z — both pre-delivery).
- project.yml mtime 21:24:09Z — BEFORE the delivery; that is the 1.28
  version bump, not a FIX-129 change. Its DaBanh target still reads
  1.28/29 in both pairs (settings :63-64, info.properties :70-71) —
  no version bump, as the report states.
- DaBanhTV's own files untouched: DaBanhTV/*.swift mtimes Nov 13/18,
  DaBanhTVTopShelf/* Nov 16. The only cross-target surface is
  TeamNameNorm.swift (table-only, Foundation-only, public API
  unchanged — LOOP1 §5, re-confirmed by my harness run below).
- FIX-129 markers bound the surface: 14 in PlayerView.swift, 1 in
  ContentView.swift (:197), 1 in TeamNameNorm.swift (:532). Every
  marker sits inside the regions the report's inventory lists
  (aliases :532-601; launch warm ContentView :197-224; prewarm logging
  PlayerView :1898-1966 region; Item C wiring/classifier/mark/merge/
  settle/hub :141-160, :399-466, :727-800, :1512-1516, :1568,
  settle, :2051-2052). The report's inventory is COMPLETE — no
  unlisted change found, no changed file outside the three named.

## 2. Adversarial alias probes — ALL PASS (run by me through corpus127/harness.py, which parses the current Swift tables)
Distinct clubs — must split on BOTH keys; all split:
- P1 "Paris FC" (canon/group "paris") vs "Psg" ("paris saint
  germain"); P1b vs "Paris Saint-Germain" — SPLIT both keys.
- P2 "Newcastle Jets" ("newcastle jets") vs "Newcastle" ("newcastle
  united"); P2b vs "Newcastle United" — SPLIT both keys.
- P3 bare "Independiente" (Argentine shape, "independiente") vs
  "Dep.Independiente" ("independiente medellin") — SPLIT; the alias
  fires only on the exact "dep independiente" stem.
- P3b "Independiente Santa Fe" ("santa fe") vs "Independiente
  Medellin" ("independiente medellin") — SPLIT (shared "Independiente"
  prefix does not merge two different Colombian clubs).
- P4 "Dep La Coruna" ("deportivo a coruna") vs "Deportivo Cali"
  ("deportivo cali"); P4b vs "Deportivo Alaves" ("deportivo alaves")
  — SPLIT (the Deportivo-prefix trap does not fire).
- P12 "Ind. Santa Fe" ("santa fe") vs "Union Santa Fe" ("union
  santa fe") — SPLIT (shared city token does not merge).
Women/youth variants of the new stems — must split on groupKey
(canonical convergence is the designed women/age discipline):
- P5 "Leeds United Women" vs "Leeds": group "leeds united women" ≠
  "leeds united" — GROUP-SPLIT (canon both "leeds united", by design).
- P6 "Tottenham Hotspur Women" vs "Tottenham": group split, canon
  both "tottenham hotspur" — GROUP-SPLIT.
- P7 "Le Havre U17" vs "Havre AC": both keys split ("le havre u17"
  vs "le havre") — SPLIT.
- P8 "Newcastle United U21" vs "Newcastle": both keys split —
  SPLIT.
- P9 "Olympique Lyon Women" vs "Lyon": group "olympique lyon women"
  ≠ "lyon" — GROUP-SPLIT (see MINOR-2 for the intra-women spelling
  asymmetry this probe exposed).
Same-club controls — must merge on both keys; all merge:
- P10 "Ipswich" = "Ipswich Town" ("ipswich town"); P10b "Atl San
  Luis" = "Atletico San Luis"; P11 "Atl. Bucaramanga" = "Atletico
  Bucaramanga" ("bucaramanga").
Battery re-run by me at close-out: wholeNameAliases 103/103
identical, unit fails 0, frozen groups 116, FotMob collisions 0
(770), ESPN collisions 0 (99), live football 11/11 bound with score
and both crests — identical to LOOP1/LOOP2.

## 3. Adversarial playback probes — traced in current code
(a) Sole-source fixture, only source player-condemned — SETTLES, no
loop. Trace: the surface's definitive failure fires onDefinitiveFail
BEFORE advance (PlayerView.swift :152-160 wiring; LOOP1-verified
ordering in noteFailure) → markPlayerDead (:1512-1516) inserts the
URL into the session's playerDeadURLs + hub provenDead → advance()
(:337-364) steps index past the sole rung (current == nil). While
run() is still resolving the body sits in the waiting branch; every
subsequent publish goes through merge() — the head was published, so
headPublished is set and the direct-assignment branch is unreachable
(LOOP1's argument, re-read by me at :1540-1600) — and merge() skips
the condemned URL (:1568). run() is a single task-group pass gated
by finalPublished; at settle, noteResolved writes the cache entry
with the URL filtered out. isResolving flips false once, so
settledExhausted (!isResolving && index >= sources.count, :120-122)
becomes true and the body renders the noSignal slate ("MẤT TÍN
HIỆU", :366-380) — a terminal view with no player surface and no
onFail source, so nothing can re-fire advance or re-publish. The
session cannot loop.
(b) URL condemned in fixture A, same URL string legitimate for
fixture B (shared-CDN / 24-7 shape) — ACCEPTABLE, self-correcting;
NOT a false permanent death. My explicit verdict: provenDead is
keyed by URL string alone (Set<String>, :2036), hub-wide, so B's
publishHeadNow DOES filter the URL as head (isKnownDead :1467-1469
→ substitute rung, or nothing if it is B's only rung — the player
waits). But the condemnation gates ONLY the instant head: run()'s
own publications never consult provenDead — publish(final:)'s merge
guard checks only the SESSION-LOCAL playerDeadURLs (empty for B),
and the direct-assignment branch checks nothing — so B's pre-flight
re-verifies the actual URL and, if it serves (verified) or is kept
(403), publish lands it on B's ladder and the player plays it. The
code's own publishHeadNow doc states this design (:1420-1431: "the
session's own verification still re-checks every rung behind, so a
revived source returns through run()'s publications"). Worst case
for B is losing the instant-head fast path for one open — the
conservative direction. The only way B truly loses the URL is if
pre-flight independently convicts it for B too (404/410, TLS while
mustBeServing), in which case the URL is genuinely failing B's probe
as well. Acceptable as designed.
(c) Launch warm + immediate force-quit + relaunch — NO wrong verdict
can cross launches via FIX-129. Confirmed from code: provenDead is
`private var provenDead: Set<String> = []` (:2036) on the in-memory
ResolveHub singleton (static let shared, private init, :2013-2014);
grep over PlayerView.swift returns ZERO UserDefaults / FileManager
/ write( hits — the player-dead path (markPlayerDead →
notePlayerDead, insert-only :2051-2052) persists nothing. The
persisted invalid-urls.json is a different, pre-existing store owned
by PlaylistStore (load :308-312, save :314, written only at :698
and :752 — the LinkProbe sweep paths); no FIX-129 code calls into
it, and no player verdict ever enters it. On relaunch: provenDead
empty, cache/inFlight empty, launch warm re-queues from the fresh
featured set — the only cross-launch memory is the playlist layer's
own probe verdicts, exactly as in 1.28 and untouched by this fix.

## 4. Delivery readiness — VERIFIED
- project.yml: untouched in the fix window (mtime 21:24Z, pre-fix);
  DaBanh remains 1.28/29 in both version pairs — no bump smuggled in.
- Entitlements: project.yml references only JoeTV/JoeTVTopShelf
  entitlement paths (:221-222, :253-254); no entitlements file exists
  for the DaBanh targets and none was created or modified.
- DaBanhTV target's own files: untouched (mtimes Nov 13-18, §1).
- Logging surface: exactly FOUR new DiagLog lines exist —
  "prewarm: launch warm queued" (ContentView.swift:219),
  "prewarm: warming" (PlayerView.swift:1918), "prewarm: ready"
  (PlayerView.swift:1966), "player-dead:" (PlayerView.swift:1515) —
  matching LOOP2's enumeration; the pre-existing proven-dead prewarm
  line (:1952) is unchanged. No other new user-visible surface: the
  fix adds no UI text (the noSignal slate and all player strings
  predate it).
- No debug leakage: grep for print( / NSLog / debugPrint / dump(
  over all three touched files returns ZERO hits.

## 5. Declared limits in FIX-129-REPORT.md — re-stated and graded
1. "No Swift toolchain on this VM — CI is the compile gate" —
   (i) CONFIRMED ACCURATE. True of this review too; all LOOP3
   claims are static reads or harness probes.
2. Item B "ready" semantics (ready = warm attempt completed without
   definitive death; descent/segment best-effort) — (i) CONFIRMED
   ACCURATE, matches SourcePrewarmer's contract as read.
3. Item C access-log timing (a late error-log event can miss that
   one failure; fail-open, never a false condemnation) — (i)
   CONFIRMED ACCURATE (classifier reads the item's error log at
   failure time; LOOP1 §3 walked the same code).
4. Item C residual (born-cached cross-fixture hand-off) — (ii)
   UNDERSTATED. The real boundary (LOOP2 MINOR-2, re-confirmed in
   MINOR-1 above) is wider: fresh-session run() re-publication and
   EN re-entry also resurface a kept-403 URL once as a tail rung.
   Bounded, head-safe, self-healing — but the report's paragraph
   names only the born-cached shape.
5. Item A evidence limit ("Havre AC" title never captured in a file;
   fix rests on the screenshot + probe-proven canonicalisation) —
   (i) CONFIRMED ACCURATE. The fresh playlist files were not
   persisted; the frozen corpus holds no "Havre AC" producer; the
   mechanism and the fix are probe-proven (LOOP1 Troyes 12→13,
   re-run battery §2).
6. "provenDead remains per-app-run (in-memory) by design;
   cross-launch persistence exists separately in
   PlaylistStore.invalidURLs and is untouched" — (i) CONFIRMED
   ACCURATE, verified independently in §3(c).

---

## Verified vs UNVERIFIED
VERIFIED by my own reading/probes: gate anchors (below); complete
mtime inventory (exactly 3 code files in the window; project.yml,
entitlements, DaBanhTV files untouched); 17 adversarial alias probes
+ full battery re-run (103 aliases, unit 0, collisions 0/0, groups
116, live 11/11 bound); LOOP2 MINOR-2 reader graph re-derived with
no wider boundary; sole-source settle trace to the noSignal slate;
shared-URL false-death trace (head-only gate, run() self-corrects);
provenDead in-memory-only + invalid-urls.json non-interplay; exactly
4 new DiagLog lines; zero print/NSLog/debugPrint in the touched
files; declared limits graded (5 confirmed, 1 understated).
UNVERIFIED: (a) compilation — no Swift toolchain on this VM; CI is
the gate (unchanged from LOOP1/LOOP2); (b) the fix agent's
fresh-playlist group counts (mirror 189→179, origin 127→120) and
fresh censuses — files not persisted, remain the fix agent's
numbers; (c) DaBanhTV compilation with the new table (table-only,
Foundation-only — CI's to prove); (d) on-device errorLog() timing
and warm behaviour under real suspension (fail-open / declared
semantics by design).

## md5 anchors (measured by LOOP3 at open and re-stated at close — byte-identical to the gate anchors and to LOOP1/LOOP2)
- DaBanh/TeamNameNorm.swift: 8aa68a4cca08e136340d44565b80ee2b
- DaBanh/ContentView.swift: e662ddc81dd293246bcb44171e29e132
- DaBanh/PlayerView.swift: b59dfaef565042ee7f42f0309347a4f4

REVIEW-129-LOOP3: CLEAN (2 MINOR, 0 MAJOR). The 3-consecutive-clean-rounds gate for FIX-129 is SATISFIED on these bytes.
