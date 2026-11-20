# FIX-129 — Đá Banh iOS (DB-09 duplicate + DB-07 residuals B/C)

Repo: ~/workspace/dabanh-ios · Base head: 1a2d8f9 (1.28) · No push, no version bump (code + report only).

## Progress log (supervision law)
- 2026-11-20T21:39:59Z — START: report created; read TeamNameNorm.swift, 1.28 device log (dabanh-diag-8da7e8ba.log), playlist URLs found (PlaylistStore.swift:220/226). Next: read PlayerView/ContentView/MatchViews prewarm + ResolveHub + failure paths, harness.py, fetch fresh playlist.
- 2026-11-20T21:41Z — READ: PlayerView.swift full (ResolveHub, MatchPlaySession.run/publish, SourcePrewarmer/Store, SourcePreflight), ContentView preresolve sites (launch .task prefix(3), boardPanel.onAppear), harness.py pipeline. Next: fresh playlist fetch + havre census + MatchViews warm trigger + Castilla log lines.
- 2026-11-20T21:50Z — ITEM A detectors DONE: frozen corpus Troyes forms all converge (12 titles); fresh mirror (753 ch) + origin (527 ch) Troyes forms converge; probe proves canon('Havre AC')='havre' != 'le havre' (ac is filler) — DB-09 mechanism CONFIRMED, device title rotated out of both fresh files before fetch. DET2 found 11 more football split families in fresh playlist (Medellín/Santa Fe, Atl Bucaramanga, Atl San Luis, Dep La Coruña, Leeds, Tottenham, Ipswich, PSG, Newcastle, Olympique Lyon + rejected basketball/volleyball candidates). Next: one-club producer census per candidate stem.
- 2026-11-20T21:55Z — CENSUS DONE: all 12 candidate stems single-club (partners/opponents consistent across frozen+frozen feeds+fresh mirror+origin). 'havre' stem has 0 producers in files (title rotated out; evidence = owner screenshot + probe). B1 facts established (see report body). Next: add 12 whole-name aliases to TeamNameNorm.swift, re-run harness.
- 2026-11-20T22:00Z — ITEM A CODE DONE: +12 aliases in TeamNameNorm.swift (103 total, table fidelity identical, unit fails 0, FotMob/ESPN collisions 0). Frozen groups 116 (unchanged); synthetic 'Havre AC' channel joins the single Troyes group (12->13 members) with ESPN state bound + crest resolving. Fresh mirror groups 189->179, origin 127->120; every fixed family now 1 canon pair. Next: Item B (ContentView launch warm + SourcePrewarmStore start/ready logs), then Item C.
- 2026-11-20T22:04Z — ITEM B CODE DONE: ContentView .task launch-warms heads of the preresolve set (<=3, one warm() call); SourcePrewarmStore logs 'prewarm: warming' at start + 'prewarm: ready ... in Nms'; dead line byte-identical. Next: Item C wiring (VC classification -> session mark -> hub provenDead + merge exclusion).
- 2026-11-20T22:12Z — ITEMS B+C CODE DONE: all edits in PlayerView.swift + ContentView.swift; brace/paren balance 0 in all 3 touched files; no other noteFailure callers. Next: line anchors + full report body.

---

# ITEM A — Duplicate fixture split (DB-09 / FL-336)

## Evidence read
- Owner screenshots 2026-11-20 15:36 CST: featured card "Troyes vs Havre AC" (KHÁC, "VS", Havre crest = placeholder) beside the bound Ligue 1 board "Troyes 2–1 Le Havre" (93', scorers + cards).
- Playlist URLs from code: `PlaylistStore.swift:220` origin `https://thtt.pages.dev/tttt.m3u`; `PlaylistStore.swift:226` mirror `https://raw.githubusercontent.com/zjoenguyenz/dabanh-playlist/main/tttt.m3u` (the app's primary — mirror first, origin is the stale-fallback).
- Fresh fetch 2026-11-20 ~21:40–21:47Z (device had refreshed 21:32:49Z, 577 channels): mirror = 753 channels (stamp 21/11 04:22 ICT), origin = 527 channels (stamp 21/11 04:37 ICT). Frozen corpus playlist = 474 channels.
- Card team names come from the RAW channel title (`FixtureEntry.teams` → `Crests.teams(ofCleanTitle:)`, MatchViews.swift:98ff), so a card reading "Havre AC" means a channel literally titled "… vs Havre AC" was in the device's playlist. That exact title is in NEITHER fresh file — it rotated out between the device refresh and the fetch. Declared plainly: the producer evidence for the bare stem is the owner's screenshot; everything below about the mechanism is probe-proven.

## A1 — "havre" census
- Frozen corpus (12 titles): Le Havre ×8 forms (incl. "Le Havre FC" ×2), "Havre Athletic Club" ×2, plus Troyes-side variants — ALL canonicalise to pair `le havre vs troyes`.
- Fresh mirror (20 titles): the same 12 + "Troyes Vs Le Havre Fc" ×3 + "Troyes Vs Havre Athletic Club" ×5 — all converge.
- Fresh origin (12 titles): same as frozen — all converge.
- Form probes (harness, pre-fix tables): `canon("Le Havre")="le havre"`, `canon("Havre Athletic Club")="le havre"`, `canon("Le Havre FC")="le havre"`, `canon("AC Le Havre")="le havre"` — but **`canon("Havre AC")="havre"` and `canon("Havre")="havre"`**. HYPOTHESIS CONFIRMED as mechanism: "ac" is a filler token (TeamNameNorm.swift fillerTokens), so "Havre AC" reduces to the bare stem "havre", which had no alias; groupKey splits (`havre vs troyes` ≠ `le havre vs troyes`), the state pairKey never matches, the crest candidate chain (which includes the canonical key) misses the static map's Le Havre entry → placeholder shield, and with no state, LeagueClassifier files the card under KHÁC. Every element of the screenshot is explained by this one stem.

## A2 — Both detectors, every split found tonight
- Detector 1 (name sweep, canonical pairKeys): frozen — 1 same-pair multi-group case (Heineken Las Vegas Grand Prix at two different kickoff dates = two distinct events, NOT a duplicate). Fresh — same class only (volleyball pairs on different days). No same-day name-sweep duplicates beyond Detector 2's finds.
- Detector 2 (kickoff-instant net, ±10 min, raw-token overlap, different group keys): frozen corpus candidates = the 6 known non-football/false-positive families (Olympiacos Teka handball vs football namesakes, JackJumpers translation/typo, Galatasaray football vs volleyball, two cross-fixture token shares) — no football split in the frozen corpus. Fresh playlists (mirror ∪ origin) — FOOTBALL splits, each same opponent + identical kickoff instant:
  1. "Dep.Independiente vs Ind. Santa Fe" vs full-name Medellín/Santa Fe listings (04:30 21/11) — BOTH sides stranded.
  2. "Atl. Bucaramanga" vs "Atletico Bucaramanga" (06:35 21/11, vs América de Cali).
  3. "Atl San Luis" vs "Atletico San Luis" (08:00 21/11, vs Puebla).
  4. "Dep La Coruna" vs "Deportivo A Coruña" (20:00 21/11, vs Alavés — that side already converged).
  5. "Leeds" vs "Leeds United" (22:00 21/11, Chelsea).
  6. "Tottenham" vs "Tottenham Hotspur" and 7. "Ipswich" vs "Ipswich Town" (22:00 21/11, same fixture).
  8. "PSG" vs "Paris Saint Germain" (23:15 21/11, Nice).
  9. "Newcastle" vs "Newcastle United" (00:30 22/11, Arsenal).
  10. "Olympique Lyon" vs "Lyon" (02:45 22/11, LOSC Lille).
  Plus the DB-09 family itself (Havre, item 0).
- REJECTED candidates (listed, deliberately NOT aliased): "FC Barcelona vs Crvena Zvezda Red Star" (🏀) vs "Barcelona Vs Crvena Zvezda" (⚽) — different sports/fixtures sharing an instant; "Melbourne Tigers" vs "Melbourne United" — different clubs (aliasing would be a false merge); volleyball women variants ("W" vs "Women" vs "Nữ …"), "Tasmania JackNgười Nhảy" (translated name) and "lllawarra" (typo) — non-football, no state feeds carry them, outside this fix's scope per the one-club-census standard (a typo stem is not a club spelling).

## A3 — Fix (TeamNameNorm level only)
12 whole-name aliases added at `TeamNameNorm.swift:589` ff. (block comment :532), no grouping-layer change, no suffix rule — a suffix rule for "ac" already exists implicitly (filler drop) and is exactly what stranded the stem; whole-name aliases are the established, census-gated instrument:
`havre→le havre`, `dep independiente→independiente medellin`, `ind santa fe→santa fe`, `atl bucaramanga→bucaramanga`, `atl san luis→atletico san luis`, `dep la coruna→deportivo a coruna`, `leeds→leeds united`, `tottenham→tottenham hotspur`, `ipswich→ipswich town`, `psg→paris saint germain`, `newcastle→newcastle united`, `olympique lyon→lyon`.
One-club producer census (frozen playlist + frozen feeds ESPN/FotMob/Flashscore/LiveScore raw names + both fresh playlists): every source stem is produced by exactly ONE club, partners consistent (table in working notes; e.g. "tottenham" producers = 3 listings, all vs Ipswich; "newcastle" = 2, all vs Arsenal; "havre" = 0 in files — rotated out, screenshot evidence, target "le havre" raw forms are all the one club incl. feed form "Le Havre AC"). "Newcastle Jets" verified untouched (`canon = "newcastle jets"`).

## A4 — Harness numbers (harness.py parses the Swift tables directly)
- Table fidelity: wholeNameAliases harness=103, line-range=103, identical=True (91 + 12 new). Unit battery: **fails 0**. Collisions: **FotMob 0 (770 id-keyed pairs), ESPN 0 (99)** — unchanged.
- Frozen corpus: groups 116 (115 pair + 1 legacy) before AND after — no regression, no new merge.
- Troyes proof: frozen Troyes = 1 group / 12 members, ESPN state bound (live). Appending a synthetic channel titled "Troyes vs Havre AC" at the same kickoff: **1 group / 13 members** (pre-fix it formed its own `havre vs troyes` group), state bound from the group rep, and `crest_url("Havre AC")` now resolves (was nil → placeholder).
- Fresh mirror: groups **189 → 179**; fresh origin: **127 → 120**. Every fixed family now occupies exactly **1** canonical pair group (Troyes: mirror 1 group / 20 members, origin 1 / 12). Duplicate groups for the 11 measured families: **2 → 1 each** (the interlocked Tottenham/Ipswich listings: 3 stems → 1 pair).

# ITEM B — Launch-time host warming

## B1 — Facts BEFORE the change (file:line, pre-fix numbering)
- Triggers: exactly two. (1) `MatchViews.swift:1000–1013` — MatchBoardView `.task`: board open warms the fixture's full ladder (in-player mode re-bases behind the playing row). (2) `PlayerView.swift` PlayerView `onReady` → `MatchPlaySession.beginPrewarming(after:)` — warms the ladder behind the playing rung once the first frame is up. The launch preresolve (`ContentView.swift:189–197` `.task`) and the board-open preresolve (FIX-128) run ResolveHub VERIFICATION only — no warming.
- What a warm is: `SourcePrewarmer.warm` (PlayerView.swift, private enum) — fetch top playlist (≤16 KB), if master descend to best-BANDWIDTH variant's media playlist (≤16 KB), fetch first segment head (≤256 KB). Death judged ONLY at the top playlist, on pre-flight's standard (404/410, or 200 non-playlist/takedown body); descent/segment failures never judge.
- Concurrency: `SourcePrewarmStore.runDriver` — max **2** concurrent warm tasks, shared queue; verdicts (warm/dead) remembered per app run; every `warm()` call rebuilds the pending queue in the newest priority order.
- Logging before: exactly ONE line type ("prewarm: source proven dead — the ladder will skip it: …"). Success and start were silent — the 1.28 device log contains **zero** "prewarm" lines across the whole file (grep count 0), so warming was unprovable from logs. Andorra evidence (1.28 log): pick 21:33:27Z adopted cached ladder instantly, `source #0 ready` 21:33:35Z = **8 s** on cold live2.zktsva.app; Cercle Brugge 21:35:47Z on the SAME host, warm from the Andorra play: ready the same second (**1 s**).

## B2 — Change (`ContentView.swift:197–224`)
In the root `.task`, immediately after the existing launch `ResolveHub.preresolve` call, the HEAD source of each fixture in the SAME set (featured rail prefix(3) — the exact preresolve set) is deep-warmed: `heads = featuredEntries.prefix(3).compactMap { store.sources(for: $0.channel).first }`, then ONE `SourcePrewarmStore.shared.warm(ladder: heads)` call. Bound: **≤3 head sources, one per fixture**, featured order, through the existing max-2-concurrent driver — no new mechanism, warm = the existing SourcePrewarmer descent. One call, not three, because the store rebuilds its pending queue per call (per-fixture calls would drop each other's unstarted heads). A later board-open warm re-prioritises as before — the board's fixture correctly outranks launch heads.

## B3 — New DiagLog lines (old formats byte-identical, incl. the proven-dead line)
- `prewarm: launch warm queued — N featured head source(s)` (ContentView.swift:219).
- `prewarm: warming '<title>' host=<host>` at each warm start (PlayerView.swift:1918, in runDriver's takeNext).
- `prewarm: ready '<title>' host=<host> in <ms>ms` at each non-dead completion (PlayerView.swift:1966).
The next device log can therefore prove: launch warm queued at launch, each head's host warmed + elapsed, before any pick.

# ITEM C — Player-definitive-death feedback

## C1 — Change (all in PlayerView.swift)
- Classification — `LivePlayerViewController.definitiveFailureReason(for:)` (:777): definitive = (a) HTTP **403/404** as the newest non-zero `errorStatusCode` in the item's **access log** (`AVPlayerItemAccessLogEvent` — AVPlayerItem.error does not carry HTTP status; the access log does), or (b) **TLS/certificate invalid**: NSURLErrorDomain codes −1200…−1206 through the underlying-error chain (depth 3), with the stable "…certificate…" localized text as fallback for AVFoundation-wrapped errors. Timeouts, stalls, 5xx, generic network errors → nil, mark nothing.
- Plumbing: VC stores its item (`playerItem`, :489/:516, cleared in teardown); `noteFailure` now takes the `Error?` (was the localized String; the DB-06 log line's format is byte-identical) and, on a definitive verdict, fires the new `onDefinitiveFail` BEFORE the existing advance (:727). `LivePlayerSurface` carries it (:399) into the VC (:464); PlayerView passes `{ session.markPlayerDead(channel, reason:) }` (:141–160).
- Mark — `MatchPlaySession.markPlayerDead(_:reason:)` (:1512): inserts into the session's `playerDeadURLs`, logs `player-dead: <host> — <reason>` (:1515, once per URL), and calls `ResolveHub.notePlayerDead(url:)` (:2051) → the hub's `provenDead` set (the same store publishHeadNow already consults via isKnownDead).
- Exclusion: run()'s `publish(final:)` merge **skips** any incoming channel whose URL is in `playerDeadURLs` (:1558) — neither in-place replacement nor append. The settle's `noteResolved` now passes `deadURLs.union(playerDeadURLs)` and filters player-dead URLs out of the cached ladder.

## C2 — Player 403 vs pre-flight kept-403 (explicit distinction)
Pre-flight's 403 answers a bare probe GET; on this household's network it can mean "tunnel off right now", so SourcePreflight KEEPS the source (demoted, playable) — that code is **untouched**. The player's 403 is observed on a source already published to the viewer (verified, or the instant head he picked), on the full playback request carrying the channel's own headers and repaired Referer — and 404 means the playlist is gone outright. The mark condemns **only that URL, only for this app run** (provenDead is in-memory), exactly the lifetime of every other verdict in ResolveHub. Scope was NOT narrowed: cert-invalid + 403 + 404 are all implemented, each on an evidence-grade signal (error domain/code or access-log status), never on localized-text guessing (the certificate text fallback fires only for the TLS family, whose text is the OS's own stable string).

## C3 — Castilla walkthrough (1.28 log → changed code)
Log (dabanh-diag-8da7e8ba.log): 21:35:19Z pick adopts in-flight session, instant head = the v1.livestreambong.tv URL; 21:35:20Z `source #0 failed … — The certificate for this server is invalid.` → advance → player waiting; **21:35:21Z `ladder first batch: 1 source(s) published`** — pre-flight's TLS failure had (after retries) resolved as kept, and publish's merge REPLACED rung #0 in place with the same dead URL; session settled → `no signal: ladder exhausted at #1`. Second pick 21:35:26Z: brand-new session, same head, ~4 s to no-signal.
With FIX-129: at 21:35:20Z noteFailure classifies the error (NSURLError underlying −1202 / "certificate" text) → `player-dead: v1.livestreambong.tv — TLS/certificate invalid` → session.playerDeadURLs + hub.provenDead, THEN advance. At 21:35:21Z the first batch's merge hits the playerDeadURLs guard and **skips the URL — the second publish no longer happens**; the session settles with the URL excluded from sources AND from the cache entry (noteResolved union). The second pick's session(for:) → publishHeadNow sees isKnownDead(head)=true → substitutes the first uncondemned rung (or publishes nothing if all are condemned) instead of re-trying the cert-dead host; the log gains the `player-dead:` line as proof.

# Declared limits / risks
- No Swift toolchain on this VM — CI is the compile gate. Brace/paren balance verified 0-diff in all 3 touched files; no other callers of the changed `noteFailure` exist; `LivePlayerSurface` has exactly one call site. Swift 6: the new closures follow the existing onReady pattern (SwiftUI main-actor context → @MainActor session); the VC classifier touches only value reads (error, access-log events).
- Item B "ready" semantics: ready = warm attempt completed without a definitive death (top playlist fetched; variant/segment descent is best-effort inside SourcePrewarmer and its transient failure also returns non-dead). The line proves the host was warmed to the existing deep-warm standard; it does not claim the segment fetch succeeded.
- Item C access-log timing: if the access-log error event lands after the failure callback, the HTTP branch can miss that one failure (the TLS branch is synchronous from the error itself). The mark then simply doesn't happen — fail-open to pre-FIX-129 behaviour, never a false condemnation.
- Item C residual: a cache entry written by ANOTHER fixture before a player-dead mark, sharing the same URL, can still hand that URL to a player once via the born-cached path (publishHeadNow filters only the head pick). The player fails it, marks (idempotent), advances. Cross-fixture URL sharing is rare (URLs are per-listing).
- Item A: the "Havre AC" title itself was never captured in a file (rotated out) — the fix rests on the screenshot + the probe-proven canonicalisation, declared in A1. Non-football splits were listed, not fixed (A2).
- provenDead remains per-app-run (in-memory) by design; cross-launch persistence already exists separately in PlaylistStore.invalidURLs and is untouched.

# Change inventory
1. `DaBanh/TeamNameNorm.swift` — +12 whole-name aliases + evidence comment block (:532–601). No pipeline change. (Compiles into both DaBanh + DaBanhTV targets; table-only change, public API untouched.)
2. `DaBanh/ContentView.swift` — launch head-warming block in root `.task` (:197–224). iOS target only.
3. `DaBanh/PlayerView.swift` — Item B: SourcePrewarmStore start/ready logging (:1898–1966 region). Item C: PlayerView onDefinitiveFail wiring (:141–160); LivePlayerSurface property + wiring (:399–410 region); LivePlayerViewController onDefinitiveFail + playerItem + noteFailure(Error?) + definitiveFailureReason (:464–810 region); MatchPlaySession playerDeadURLs + markPlayerDead + merge guard + noteResolved union (:1283–1560 region); ResolveHub.notePlayerDead (:2044–2053). iOS target only.
No version bump, no push (per brief).
- 2026-11-20T22:18Z — REPORT COMPLETE: all three items implemented + harness-verified (Item A) / code-walked (Items B, C). Ready for leader review.
