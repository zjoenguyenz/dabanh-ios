# JoeTV tvOS 2.0.29 — CLUSTER B report (players: items 2 + 3)

Files owned and edited: `JoeTV/JoePlayerView.swift`, `JoeTV/JoeKSPlayerView.swift` only.
Presnap compared against: `~/workspace/dabanh-ios/backup-v2029-presnap/` (full diff of both
files reviewed before writing this report; every hunk is one of the changes listed below).
No compiler on this VM — CI is the first compile, owner retest is the device gate.

Engine routing, verified from code (the task brief asked): **every torrent candidate is
`.ffmpeg`** — `TorrentClient.playCandidates` stamps `engine: .ffmpeg` on the lead candidate
and on every resolved rest candidate (TorrentClient.swift, `playCandidates`). There is **no
AVPlayer torrent path** in the current code: the AVPlayer host serves provider candidates
only (PlayCandidate's default engine), plus the Phim detail's proxied provider entries
(JoeMovieDetail.swift, `PlayCandidate(url: local, label: entry.title)` — still a provider
stream through JoeProxy, engine `.avPlayer`). The two hosts below are the only player hosts
in the app (grep-verified: no other `AVPlayerViewController` / `KSPlayerLayer` construction
exists in `JoeTV/`).

---

## Item 2 — Overlays must hide WITH the bar

### Root cause (code-proven)

The lingering text is the shell's **`statusCapsule`**. It was rendered **unconditionally**
whenever the phase was `.playing` — no visibility state of any kind — and its text source
`PlayDirector.notice` is **never cleared anywhere in the codebase** (grep-verified: no
`notice = nil` exists). `itemReady` sets `notice = "Tiếp tục từ …"` on every candidate, so
from the first resume onward the capsule permanently showed the resume line (notice takes
precedence over the label in the capsule's own if/else); on a session with no resume it
permanently showed `currentLabel`. The bars themselves hid correctly (KS: fix-5 timer;
AVPlayer: AVKit, with the Title View bound by fix 9 — the owner confirmed title+bar hide on
normal films in 2.0.28), leaving the capsule behind alone. That is exactly his two findings:
torrent — bar hides, text stays; normal film — bar+title hide, resume line stays (incl. the
Ultra "small text in the corner" and the SourceBoard "tiếp tục từ 42" cases: the capsule is
bottom-left in every theme; the player hosts contain no theme branches at all).

### Overlay inventory (every element rendered during playback in both hosts)

| # | Element (owner's words) | View that renders it | File:line (pre-fix) | Old binding | New binding |
|---|---|---|---|---|---|
| 1 | Resume line "Tiếp tục từ …" / "coi từ phút X"; also failover + switch notices | SwiftUI `statusCapsule`, `Text(director.notice)` branch | JoePlayerView.swift:1260 (`statusCapsule`), text set at :578 (`itemReady`) | None — always rendered in `.playing`; `notice` never cleared | `.opacity(director.transportBarVisible ? 1 : 0)` at the call site (JoePlayerView.swift:1062–1063), driven by the live host (rows 6/9) |
| 2 | Source name ("RD Plus") + quality badge text ("4K DV" / HDR) | SwiftUI `statusCapsule`, `Text(director.currentLabel)` branch — the candidate's label. For torrent candidates this is `TorStream.name`, a **multi-line** addon string whose lines carry the debrid/source brand and the quality tokens; there is **no separate badge view** in either host (full-read verified) | JoePlayerView.swift:1271–1272 (pre-fix numbering) | None — always rendered in `.playing` when no notice was set | Same capsule binding as row 1 |
| 3 | Film title (+ poster) — AVPlayer path | AVKit **Title View**, fed by `externalMetadata` (`.commonIdentifierTitle` + artwork) in `refreshChrome` | JoePlayerView.swift, `PlayerController.Coordinator` | Fix 9 (2.0.28): delegate sets `transportBarIncludesTitleView = visible` — already bound, owner-confirmed working on normal films; **unchanged** | Unchanged; the same delegate callback now ALSO reports the announced state into the director for row 1/2 (JoePlayerView.swift:1583) |
| 4 | Film title — KS (torrent) path | **Does not exist.** Full read of JoeKSPlayerView.swift: the host renders no title/poster overlay (only bar labels, picker title, subtitles). The title-like line the owner sees on torrent playback is the first line of the capsule's multi-line label (row 2) | — | — | Covered by row 2's binding |
| 5 | KS transport bar itself (play/pause, seek, time labels, buffering spinner, track + Đổi nguồn buttons) | UIKit `controlsView` / `transportBar` in `KSPlayerHostViewController` | JoeKSPlayerView.swift, `buildControls` | It IS the bar: `controlsVisible` + 4 s idle timer (fix 5) | Unchanged mechanism; it now also reports its state to the director (row 6) |
| 6 | (state, not an element) KS bar visibility → capsule | `showControls()` / `hideControlsIfIdle()` / `didUpdateFocus` / picker show path | JoeKSPlayerView.swift:776 / :821 / :855 / :1266 | The capsule never heard about any of it | Each transition calls `director?.setTransportBarVisible(...)`: show :785, hide :845, focus-resurrect :860, picker-open :1276 |
| 7 | Subtitles (KS path) | Subtitle render pair (`subtitleImageView`/`subtitleLabel`) | JoeKSPlayerView.swift, `buildSubtitleViewsIfNeeded` | Content, not chrome — already lifts clear when the bar is up (`layoutSubtitleViews`) | **Untouched** — subtitles are the film, not an overlay in the owner's list |
| 8 | KS track/source picker panel | UIKit `pickerView` in `controlsView` | JoeKSPlayerView.swift | Replaces the bar while open; hide timer invalidated | Unchanged presentation; opening now also reports chrome-visible (:1276) so the capsule stays with summoned chrome |
| 9 | (state) AVPlayer bar visibility → capsule | Coordinator delegate `playerViewController(_:willTransitionToVisibilityOfTransportBar:with:)` + `attach()` | JoePlayerView.swift:1568 (callback), :1528 (attach) | Drove only the Title View (fix 9) | Callback also reports `setTransportBarVisible(visible)` (:1583); `attach()` reports `true` for a freshly attached controller (:1547), so an engine swap mid-session (torrent substitution rung) can't leave the capsule stuck in the previous host's hidden state |
| 10 | AVPlayer info tab + transport menu | `JoePlayerInfoViewController` / `transportBarCustomMenuItems` | JoePlayerView.swift | User-summoned only, never an always-on overlay | Not an overlay — untouched except the menu's Đổi nguồn entry (item 3) |
| 11 | Up Next countdown card (shell) | SwiftUI `upNextCard` | JoePlayerView.swift | Its own focusable card in the last 10 s | **Deliberately untouched** — interactive card, not in the owner's list; he accepted Up Next as-is this round |
| 12 | "Đang tải…" resolving slate | SwiftUI, `.resolving` phase only | JoePlayerView.swift | Phase-bound, not shown during playback | Untouched |

Shared state (new, JoePlayerView.swift:119–128): `@Published private(set) var
transportBarVisible = true` + `setTransportBarVisible(_:)` on PlayDirector — one flag, both
hosts report into it, the capsule binds to it. **No new timer anywhere**; the capsule has no
timing logic of its own, per the owner's rule.

Behaviour notes: while paused, the KS bar never hides (standing contract) so the capsule
stays — correct, it follows the bar. A failover/switch recreates the host (`.id(attemptID)`),
whose bar starts visible, so the capsule reappears with the new attempt's bar and shows the
new candidate's label/notice.

### Billboard single source: bar never hides + pause does not respond — UNVERIFIED

What is code-proven:

- The player code contains **no theme branch** (neither host reads `joeTheme`; only the
  shell's slate/Up Next do). "Billboard" cannot be the variable — the SOURCE is. All torrent
  candidates take the KS host, so this is a KS-host case.
- The hide decision and the pause decision both key off the engine's playing-state reports
  for that one file: `hideControlsIfIdle()` requires `layer.player.isPlaying`;
  `togglePlayPause()` branches on `layer.state.isPlaying` (false → it calls `play()`).
- **Provable aggravator, fixed:** the pre-fix `hideControlsIfIdle()` returned on a veto
  **without re-arming the hide timer**, and nothing else re-arms it except a press or a
  focus move. One veto at the single fire instant permanently retired hiding for the whole
  session. Fix (JoeKSPlayerView.swift:821–845): a not-playing veto now re-arms the 4 s timer
  and retries next cycle; the paused contract is unchanged (never hides while not playing —
  it just keeps checking instead of giving up after one check).

Best code-based hypothesis for the source itself — **UNVERIFIED**: that file keeps the
KSPlayer engine out of its playing state while frames render (e.g. state stuck at
`.buffering` for that container/link). That one state explains all three observations at
once: `isPlaying` false at every hide check (bar never hides — and pre-fix, the first veto
alone sufficed), `togglePlayPause` always taking the `play()` branch (pause "does not
respond"), and no watchdog rescue (the freeze watchdog only judges after the host's
`playing` flag is set by `.bufferFinished`, and the first-frame watchdog is cancelled at
`.readyToPlay`). Which file/link does this, and whether the engine truly sits in
`.buffering`, **cannot be determined from code** — it needs a diagnostic build logging
`layer.state` / `player.isPlaying` at each hide veto and at each pause press for that
source. No pause-side code was changed: any change there would be guessing at engine-state
semantics. If the retest still shows the stuck bar on that source, the diagnostic log is
the next step, not another blind fix.

---

## Item 3 — Đổi nguồn must open a chooser

### Design

- **Where the list comes from:** `PlayDirector.sourceChoices` (new, JoePlayerView.swift:781–801)
  — the session's **current** candidate ladder (`candidates`), each row = ladder index +
  the candidate's own `label` (the same text the capsule shows; empty label → "Nguồn N")
  + `isCurrent`. Read live at every menu/picker opening, so after a failover hop replaces
  the ladder, the next opening shows the new list with the new current marked.
- **How the switch works:** new `PlayDirector.userSwitchSource(to:)` (JoePlayerView.swift:815–830).
  Guards: `.playing`, index inside the ladder, not the current index. It sets
  `candidateIndex` and calls the standing `beginCandidate()` — the same re-arm the failover
  ladder and the old blind advance used. **Position is kept by the standing itemReady
  resume rule**: `beginCandidate` resets `seekApplied`, and `itemReady` seeks the new
  candidate to `max(resumeMs, lastPosMs)` (lastPosMs kept current by `tick()` on both
  engines). No new seek machinery.
- **Auto failover is exactly as-is:** `itemFailed` and its refresh → hop → substitution
  rungs are untouched. The old `userSwitchSource()` (advance-to-next) remains on the
  director but is **no longer wired to any chrome** — both call sites now open the chooser.
  One behaviour consequence, stated plainly: pressing Đổi nguồn at the ladder's last
  candidate no longer triggers the failover rungs by itself, because the chooser lists the
  current ladder only (per the task's definition of the list); dead-source failover still
  reaches those rungs automatically.

### KS host (follows the existing subtitle/audio picker pattern)

- `switchSourceButtonTapped` (JoeKSPlayerView.swift:1171) now: `showControls()` +
  `openPicker(kind: .sources)` (was: direct `director?.userSwitchSource()`).
- `PickerKind` gains `.sources` (:190); chooser state `pickerSourceLabels` /
  `pickerSourceIndex` (:204–205), cached at opening and cleared in `closePicker` (:1359–1360),
  exactly like the track rows.
- `openPicker` routes `.sources` to the new `openSourceChooser()` (:1243) **before** the
  track pickers' `ready + layer` guard — the chooser's rows come from the director, not the
  engine, so it opens whenever the session is live. It sets the panel title "Chọn nguồn",
  one `addPickerButton` per choice (tag = ladder index, checked = current), then the shared
  tail `showPickerPanel()` (:1266) — extracted from `openPicker`'s existing tail,
  byte-identical in effect (panel replaces bar, hide timer invalidated, focus update).
- Focus landing: `preferredFocusEnvironments` (:253–267) returns the **current source's
  row** while the source chooser is open; track pickers keep their first-row landing.
- Pick: `pickerButtonTapped` `.sources` case (:1332–1345) — close the panel first (the
  switch recreates the host via `.id(attemptID)`, so no track refresh applies), then
  `director?.userSwitchSource(to: index)`; picking the current row is the director's no-op.
- Row titles are the candidate label **flattened to one line** (`flattenedSourceLabel`,
  :1138): Torrentio/MF stream names are multi-line (source line, quality line); rows join
  the lines with " · " instead of truncating. Display-only.

### AVPlayer host (follows the existing transport-menu pattern)

- `refreshTransportMenu` (JoePlayerView.swift:1663–1698): the single "Đổi nguồn" UIAction
  is replaced by a **submenu** `UIMenu(title: "Đổi nguồn", …)` whose children are one
  UIAction per `director.sourceChoices` row — title = flattened label, `state = .on` on the
  current candidate (the check mark), handler = `userSwitchSource(to: choice.index)`.
  The menu is rebuilt per item (`refreshChrome`) and after a favourite toggle, as before,
  so the check mark is never stale. Favourite / Tập tiếp theo entries unchanged.

---

## Every change, by file:line (post-edit numbering)

**JoeTV/JoePlayerView.swift**
- :119–128 — `transportBarVisible` published flag + `setTransportBarVisible(_:)` on PlayDirector (item 2).
- :781–801 — `SourceChoice` struct + `sourceChoices` (item 3).
- :815–830 — `userSwitchSource(to:)` (item 3).
- :1049–1063 — comment + `.opacity(director.transportBarVisible ? 1 : 0)` on the `statusCapsule` call site (item 2).
- :1540–1549 — `attach()` reports bar-visible for a fresh controller (item 2).
- :1576–1585 — fix-9 delegate callback also reports the announced visibility to the director (item 2).
- :1593–1600 — Coordinator `flattenedSourceLabel` helper (item 3).
- :1663–1698 — transport menu: Đổi nguồn UIAction → candidate-list submenu (item 3).

**JoeTV/JoeKSPlayerView.swift**
- :190 — `PickerKind` gains `.sources`; :197–205 — `pickerSourceLabels` / `pickerSourceIndex` (item 3).
- :253–267 — `preferredFocusEnvironments`: source chooser lands on the current row (item 3).
- :785 — `showControls()` reports bar-visible (item 2).
- :821–848 — `hideControlsIfIdle()`: guard split; not-playing veto re-arms the idle timer (Billboard aggravator); actual hide reports bar-hidden (item 2).
- :858–860 — `didUpdateFocus` focus-resurrect path reports bar-visible (item 2).
- :1138–1149 — `flattenedSourceLabel` helper (item 3).
- :1171–1185 — `switchSourceButtonTapped` opens the chooser (item 3).
- :1187–1231 — `openPicker` routes `.sources` out before the engine guard; track cases clear chooser state; tail extracted to `showPickerPanel()` (item 3).
- :1243–1259 — `openSourceChooser()` (item 3).
- :1266–1280 — `showPickerPanel()` (extracted tail) + reports chrome-visible (items 2+3).
- :1332–1345 — `pickerButtonTapped` `.sources` case (item 3).
- :1359–1360 — `closePicker` clears chooser state (item 3).

Nothing else in either file was changed (full presnap diff reviewed). No other file was
edited by this cluster.

---

## Honesty declaration

- **Claims:** the capsule was the only always-on text overlay over KS playback and was
  unbound on both paths; `notice` is never cleared; torrent candidates are all `.ffmpeg`;
  the KS host has no title view; the hide-veto never re-armed. The chooser lists the live
  ladder and switches through the standing `beginCandidate` + itemReady resume machinery.
- **Evidence:** full reads of both owned files; greps for `notice = nil` (none),
  `userSwitchSource` callers (exactly the two changed sites), other player hosts (none);
  `TorrentClient.playCandidates` engine stamps; full presnap diff of both files after
  editing (only the listed hunks); brace/paren balance check on both files (0/0).
- **Unverified, labelled:** (1) NO local compiler — Swift syntax is by construction and
  precedent (all new call shapes mirror existing compiled code in the same files); CI is
  the first compile. (2) The AVPlayer capsule piggybacks the fix-9 delegate callback —
  the owner confirmed that callback's Title View effect on device in 2.0.28, but the
  capsule's own hide/show on device is a retest item. (3) Whether AVKit presents a nested
  UIMenu inside `transportBarCustomMenuItems` as a true submenu on tvOS 27 cannot be
  verified from this VM — it is standard UIKit menu composition and compiles by the same
  API the existing menu uses, but the device retest is the proof; if AVKit flattens or
  drops nested menus, the fallback is flat per-source actions in the same menu (a
  JoePlayerView-only change). (4) The Billboard single-source root cause is UNVERIFIED
  (engine-state hypothesis above); only the code-provable no-rearm aggravator was fixed.
  (5) The owner's "4K DV/HDR badge" as a *separate* element: no such view exists in either
  host — the quality tokens ride inside the capsule's label text, which is now bound. If a
  standalone badge remains on his TV after this fix, the remaining candidate is the TV's
  own display-mode banner (rendered by the television when AVDisplayManager switches
  modes — not app-rendered and not bindable by app code); that distinction is only
  provable on his screen.
