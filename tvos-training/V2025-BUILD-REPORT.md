# JoeTV 2.0.25/38 — BUILD REPORT (checkpoint 1 of 3, continuous 13-idea run)

Date: 2026-11-18. Scope of this checkpoint: ideas **1, 2, 3, 6** from
`tvos-training/IDEAS-20261118.md`. Packages 2 (2.0.26: ideas 4, 5, 7, 10) and 3
(2.0.27: ideas 13, 17, 20, 21, 23) are **queued, not built** — the run continues
into them without waiting for the owner's test verdict on this checkpoint; any
defect his test surfaces folds into the next package and is flagged there.

Presnap: `backup-v2025-presnap/` (whole JoeTV tree + project.yml, taken before
any edit). Version pairs bumped for the JoeTV target only (settings +
info.properties), read back after editing: 2.0.25 / 38. No other target touched.
Static verification only — this VM has no Swift toolchain; the CI build the
parent dispatches is the compile gate.

## Idea 1 — TVB rich shelves (`JoeTV/JoeTVB.swift`)
Implemented: new rails on the TVB home, all flowing through the existing
RailSpec/railSections/card/open machinery —
- Decade shelves (📺 Thập niên 80/90/2000/2010/2020): grouped by title year,
  emitted only when a decade holds ≥ 6 displayed titles, popularity order.
- "✅ Trọn bộ": `status == "Ended"` and best provider completeness ≥ 0.95
  (new `TVBTitle.bestCompleteness`), cap 40.
- "🏆 Hay nhất": voteCount ≥ 5 only; order by
  `voteAverage * min(voteCount,50)/50` (new `TVBTitle.weightedVoteScore`),
  tie-break voteCount then popularity, cap 30.
- "🎞️ Nhiều phần": `seasons.count > 1`, cap 30.
Per the interim-build rule, the **actor shelf row is NOT in this build** — it
ships in 2.0.27 together with the actor pages (idea 20), so no dead tap exists.
Existing 5 pipeline rails, 7 genre shelves, search and open() unchanged.

## Idea 2 — Voice search (`JoeTV/JoeSearch.swift`)
Implemented: a mic button ("Nói", `mic.fill`) in the search field row using the
house `JoeSecondaryLabel` + `.joeCardButton()` construction. It presents a
full-screen sheet with ONE genuine system `TextField` ("Nói tên phim…") — on
tvOS a focused system field is what enables Siri Remote dictation; no
speech-framework code was added. Focus landing uses stacked constructions
(`.defaultFocus` + a 250 ms re-assert task that never steals focus back).
Submit (return key or "Tìm") writes the draft into the SAME `query` state the
custom keyboard edits, so the existing type-ahead/runSearch path runs
unchanged; cancel (Huỷ or Menu) discards the draft.
Labelled deviation: submitting an EMPTY draft is treated as cancel (it does
not clear the current query) — deliberate, commented in code.

## Idea 3 — Tap-to-play speed pack
- **3(a) Parallel ladder** (`JoeTV/Providers.swift`): `appendResolved` now
  resolves a pass's servers concurrently via a task group and reassembles
  entries in exact server order (index-sorted). The two-pass SourceHealth
  latch discipline is preserved verbatim (latched pass only when the
  unlatched pass is empty). No public signature changed. PerfLog marks
  `ladder.begin` / `ladder.done` added in `ladderFor`.
- **3(b) No re-fetch of the just-loaded torrent list** (`JoeTV/JoeTorrent.swift`):
  the session's first `resolveLadder` call for the origin identity reuses the
  detail's already-displayed pooled list exactly once — guarded by an
  unconsumed first-call box + origin `progressKey` match + non-empty seed.
  Failover refresh / retry / other identities fetch fresh as before. Pool
  ranking and merging code untouched.
- **3(c) Logo split from backdrop** (`JoeTV/TMDBClient.swift`,
  `JoeTV/JoeMovieDetail.swift`, `JoeTV/JoePhimHome.swift`): `fetchInfo` no
  longer awaits `fetchLogo` (returns with `logoURL == ""`; `fetchLogo`
  unchanged, own cache). Both consumers now fetch the logo in parallel:
  the movie detail via a dedicated `.task` publishing into a `tmdbLogoURL`
  state; the Phim home hero via an `async let` alongside its other fetches,
  applied after the backdrop. PerfLog: `warm.hit` / `warm.miss` marks added
  in `StreamWarmer.take()` (idea 3's measurement condition).

## Idea 6 — Up Next (`JoeTV/JoePlayerView.swift`, `JoeTV/JoeStreamWarmer.swift`,
## `JoeTV/JoeMovieDetail.swift`, `JoeTV/JoeTorrent.swift`)
Core (JoePlayerView): PlayDirector gains the Up Next contract —
`nextEpisodeFactory`, `nextEpisodeTitle`, `onPlayingStarted` (fired exactly
once from the shared itemReady core), `@Published upNextSecondsLeft`,
`advanceTarget`, `advanceNow()`, `cancelAdvance()`. On a CLEAN end only
(errors never reach itemEnded), a 10 s countdown publishes; at zero the
factory's director is published as `advanceTarget`. A generation counter +
cancellation checks guarantee a cancelled countdown can never publish a
target. JoePlayerView keeps its public init; internally a `JoeDirectorBox`
swaps the session director in place (`.id` on the session view), so the next
episode plays without leaving the player; the new director starts through the
same `.onAppear { start() }` path. Countdown card: next-episode title,
"Tập tiếp theo sau Xs", a focusable "Phát ngay" button (house slate-button
construction), "Nhấn Menu để hủy" hint; Menu during a countdown cancels it
instead of dismissing. Sessions with no factory behave exactly as before.
Warmer: `StreamWarmer.warmUpcoming(url:headers:)` added as the named entry
of the shared warming system (forwards to `warm`; single-entry discipline
unchanged) — ideas 3+6 use it now, idea 23's layer joins it in 2.0.27.
Wiring (provider path, JoeMovieDetail): episode taps wire the factory only
when a playable next episode exists (same server's list first, then episode
N+1 anywhere in the detail); the factory rebuilds with the SAME provider code
and SAME torrentFirst flag captured at tap time — a pinned source stays the
lead source. `onPlayingStarted` pre-resolves N+1 for all providers and, for
KK only, builds N+1's ladder and warms its first entry. Movies wire nothing.
Wiring (torrent path, JoeTorrent): series sessions wire a recursive factory
through the same director builder; preparation (pooled streams + best-VI
subtitle) runs from `onPlayingStarted` and the factory awaits/reuses it; the
next session's first ladder call reuses the prepared list under the same
3(b) guard. With no tapped row for N+1, the pool's own top-ranked stream
leads — deliberately no invented cross-family match.

## Honest limits
- No compile was possible on this VM; verification was full re-reads of every
  edited region, delimiter-balance checks, a cross-file symbol audit (every
  new member referenced exists with the specced name/type), and diff review
  against the presnap. The CI build is the first real compile.
- The dictation sheet's focus landing and the Up Next handover are
  source-verified only; both want the owner's on-device pass (voice search
  dictation itself is the one test the owner runs personally).

## Delivery
Code commit on `main`: **854c087ee5bfc79407b2f09bf6ca4267e9d915c2**
(push-files, 10 paths: project.yml + JoeTVB, JoeSearch, Providers, TMDBClient,
JoePhimHome, JoeTorrent, JoePlayerView, JoeStreamWarmer, JoeMovieDetail.)
Parent: dispatch "Build JoeTV IPA" on main at this SHA for the owner's test
install. The run continues into package 2 (2.0.26) immediately.
