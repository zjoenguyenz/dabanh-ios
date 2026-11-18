# JoeTV tvOS 2.0.28 / build 41 — FIX4 report

Fix round from the owner's own on-device test of 2.0.27 (2026-11-18 voice
session). His findings are primary evidence; this round fixes exactly those
faults, plus the owner-ordered whole-app tvOS 27 audit that rides along.
Presnap: `~/workspace/dabanh-ios/backup-v2028-presnap/` (full `JoeTV/` +
`project.yml`, taken before any edit). Version: both JoeTV pairs in
project.yml bumped 2.0.27/40 → **2.0.28/41** (settings pair + info.properties
pair; Đá Banh targets untouched; local project.yml verified byte-identical
to remote HEAD before the bump). CI is the compile gate — the parent
dispatches it; this report's code claims are code-verified only (see the
honesty declaration).

## Device facts + owner ruling (top, per instruction)

- His Apple TV: **A2843, 128 GB** (Apple TV 4K 3rd gen, A15), tested
  2.0.27 on **tvOS 18.6 [22M84]**, output 2160p UHD 60 Hz Dolby Vision,
  LAN 192.168.68.50, name "Living Room". (Owner's About-screen photo,
  2026-11-18 — primary evidence.)
- **Owner ruling 2026-11-18 12:25 CST:** do NOT contort fixes to 18.6 —
  build to the design of the best/newest versions ("từ 26 tới 27 chẳng
  hạn hoặc là từ 27 luôn cũng được"). He is updating the A2843 to
  **tvOS 27.2.1** himself. This round is therefore designed/fixed against
  the **tvOS 27 baseline**; the deployment target stays 17.0 for install
  compatibility; where behaviour differs 27 vs 18.6, the 27 behaviour is
  the one that must be right.
- A15 + 128 GB: ample headroom; no performance-driven design change.

## Passed on device in 2.0.27 — untouched this round

Trending rail, TVB decade shelves, the speed pack (fast open; KK link
survived seek-to-end; fast seeks don't break links), favourite-channel
pinning, and Up Next auto-advance itself (it reached episode 3 — only its
card timing was wrong, fix 6).

---

## Fix 1 — Display matching (idea 10) did nothing on device

**Owner evidence:** two torrent films (incl. "Odyssey"), 19–35 s of
playback, no Dolby Vision/HDR badge, no picture-mode change.

**Audit of the FIX3 implementation** (`JoeKSPlayerView.swift`): the
mechanism is Apple's prescribed one (Tech Talk 503, re-verified this round
against Apple's session text): an `AVDisplayCriteria` (refresh rate +
`CMVideoFormatDescription` carrying the colour extensions) assigned to
`preferredDisplayCriteria` on the `AVDisplayManager` vended by the key
`UIWindow`; the mode switch keys off the preference standing when
playback starts, and is honoured subject to the user's Match Content
settings. Candidate stamps were NOT the problem: both torrent session
paths (Torrent tab and the Phim detail's torrent rung) build candidates
through `TorrentClient.playCandidates`, which stamps dv/hdr/fps.

**Two concrete defects found in the code:**

1. **Teardown race (the provable killer).** Hosts are recreated per
   attempt (`.id(director.attemptID)`). The old `teardown()` cleared
   `window.avDisplayManager.preferredDisplayCriteria = nil`
   UNCONDITIONALLY. SwiftUI's dismantle of an old attempt's host can land
   AFTER the replacement host's `viewDidAppear` applied its own criteria
   to the same window's manager — the stale teardown then nilled the LIVE
   attempt's preference, and nothing ever re-applied it. Any session that
   churned an attempt before settling (routine with torrent ladders) had
   matching silently dead.
2. **No re-assertion at playback start.** The criteria were applied only
   in `start()` (no window yet — a no-op) and `viewDidAppear`. Anything
   that reset the manager during the cover transition or engine spin-up
   left the preference gone for the whole attempt.

**Fix (JoeKSPlayerView.swift):**
- `teardown()` now clears the manager ONLY while it still holds THIS
  host's exact criteria object (identity comparison against
  `pendingDisplayCriteria`).
- The `KSPlayerLayerDelegate` `.readyToPlay` handler re-asserts
  `applyDisplayCriteria()` per attempt — the choreography point where
  frames actually begin, which no stale teardown can overtake.

**Honest limits (not hidden):** the criteria's format description is
synthetic (built from name-parsed flags); a bare format description
cannot carry the Dolby Vision configuration record, so a DV candidate
may match as HDR10 — the supported subset, as labelled since FIX3. The
mechanism is also gated by the Apple TV's own Match Content settings
(Settings → Video and Audio → Match Content): with matching off at the
system level, no app-side code can switch the mode, by Apple's design.
If the owner's retest on tvOS 27 still shows no switch, the next step is
a diagnostic build reading `isDisplayCriteriaMatchingEnabled` /
`isDisplayModeSwitchInProgress` — not another blind change. **Status:
code-verified; the owner's retest on tvOS 27 is the proof gate.**

## Fix 2 — Voice search unusable as tested

**Owner evidence:** held the Siri Remote mic → SYSTEM Siri, never the
app's dictation sheet.

**Root cause (code-proven):** the search screen has no live text field
at all (v2.0.17 replaced it with the letter strip + a query display), so
holding the mic there can only summon Siri — the sheet
(`JoeVoiceSearchSheet`, JoeSearch.swift) is the only dictation surface.
Inside the sheet, the field-focus construction stacked `.defaultFocus`
plus a delayed `.task` claim **guarded on `focus == nil`** ("so it can
never steal focus back from the buttons"). But the cover's initial focus
landing DOES take — on the Tìm/Huỷ buttons, which live in their own
`.focusSection()`. Focus was therefore never nil, the guarded claim never
fired, the field stayed unfocused, and a mic hold inside the sheet went
to Siri too. The "🎤 Nói" affordance itself (query row, beside Quay lại,
in the row's focus section) was reachable and is unchanged.

**Fix (JoeSearch.swift):** the one-time claim now fires at open unless
the field already holds focus (`if focus != .field`), 300 ms after
appearance; it runs exactly once, so it can never steal focus back from
a user who has since navigated to the buttons. The sheet's explanation
line now names Vietnamese explicitly: "Giữ nút micro trên remote rồi đọc
tên phim **bằng tiếng Việt** — chữ hiện trong ô, bấm Tìm để tìm như gõ
thường."

**Platform limit, stated plainly (verified against Apple documentation
this round):** tvOS offers NO per-field dictation-language API.
`textInputContextIdentifier` only restores the last-used keyboard for an
input context; it cannot set a language. Dictation language follows the
Apple TV's Siri Language (Settings → General → Siri → Language). If
Vietnamese speech is misread as another language, the remedy is that
device setting — Tiếng Việt — not an app setting; this round does not
fake a control the platform doesn't provide. Usage rule the owner needs:
open "🎤 Nói" first (so the field holds focus), THEN hold the mic.
**Status: code-verified; owner retest is the proof gate** (I cannot
perform a voice test).

## Fix 3 — Cast names missing on the detail page

**Owner evidence, refined on tvOS 27.2.1 (2026-11-18 12:45–12:46 CST):**
the fault has THREE faces, all confirmed live. (a) In one theme the
detail showed no cast names at all. (b) On the film "Phượng Khởi Vi
Nguyệt" the detail DOES show a cast section with actor names — but not
one actor is tappable/focusable; pressing does nothing, so the actor
page is unreachable from there. (c) Films reached through the TORRENT
path show no cast information at all on their detail surface — and the
owner's reasoning is right: torrent films are mostly US movies, the
easiest TMDB case there is.

**Theme map (code-proven in JoeMovieDetail.swift):** the cast data is
the TMDB cast. **Ultra** and **D** render the shared focusable photo
`castRow` (cells present `JoeActorPage`) ✓. **Design A** is face (b):
its cast element is `actorsLine` — literally ONE SwiftUI `Text` view,
`Text("Diễn viên: " + tmdb.cast.prefix(6).map { $0.name }.joined(separator: ", "))`.
A plain `Text` is not a `Button`: it is not focusable on tvOS, carries
no action, and takes no press — that is exactly why the owner could see
the names on "Phượng Khởi Vi Nguyệt" and press on them to no effect
(the file's own comment had defended the line as "the A render's own
presentation"). **Design F** (sourceBoard) is face (a): NO cast at
all — removed under UI-6 defect D-17; the comment sat at the empty
slot.

**Fix (JoeMovieDetail.swift):**
- **A:** the line keeps its slot, prefix, 24 pt size, meta colour and
  top margin; the names are now Buttons in the line's own clothes
  (separators as plain text between them), each presenting the actor
  page via the same `actorRoute = .tmdb(...)` the cast cells use. Focus
  paints the name alone (new `JoeActorNameLabel`: quiet plate + semibold
  when focused — the house value-only focus convention for text,
  JoeChipLabel's family). At rest the line renders as the drawing's
  line.
- **F — labelled DEVIATION from D-17:** the shared focusable `castRow`
  is restored at exactly the slot D-17 emptied, with D's own top margin
  (26). The F drawing gains this one row because the owner ordered cast
  reachable in every theme; nothing else in the board changes.

**Face (c) — where the torrent path loses the cast: it never fetches
it.** The torrent detail (`JoeTorrentDetail`, JoeTorrent.swift)
contained no TMDB call of any kind. Its model `TorMeta`
(`TorrentClient.parseMetas`) reads only id/type/name/poster/background/
year/description from the addon payload, and its `id` is the
**Cinemeta/IMDb id** — the Stremio protocol id the streams are indexed
by. The codebase even documents the gap at the hero ("TorMeta carries
no TMDB identity … so there is no TMDB fallback leg here"). The Phim
detail's cast is keyed to a **TMDB id** (`TMDBClient.fetchCast(tmdbId:
type:)`, fed by the provider payload's TMDB id or the strict title+year
`searchIdentity`) — and no bridge from the torrent meta's IMDb id to a
TMDB id existed, so no cast could ever load on this path.

**Fix (face c — TMDBClient.swift + JoeTorrent.swift):**
- New `TMDBClient.findByImdb(_:type:)`: TMDB's `/find` with
  `external_source=imdb_id` resolves the meta's own IMDb id directly to
  the TMDB id + kind (the caller's type picks the preferred results
  array; the other is tried second).
- `JoeTorrentDetail.loadCast()` runs beside — never in front of — the
  videos/streams loads: IMDb find first; the existing strict
  `searchIdentity` (exact normalised title + exact year) as fallback
  for metas whose id is not an IMDb id; then `fetchCast`. Fail-soft:
  any miss leaves the detail exactly as it was.
- The row (`torCastRow`) mirrors the Phim detail's `castRow`
  construction — circular photo, name, character, `.joeCardButton()` —
  each cell a focusable button presenting `JoeActorPage` via the same
  `JoeActorRoute.tmdb` cover. It sits after the hero in the standard
  body (every non-Ultra theme) and inside the Ultra panel, each in its
  own focus section, and renders only when a cast actually loaded.

**Confirmation (every cast surface in the app, re-censused this
round):** after this fix, EVERY cast entry in EVERY theme that renders
cast is a focusable button navigating to the actor page — Ultra:
`castRow` photo cells (Buttons, pre-existing); D: `castRow` photo cells
(Buttons, pre-existing); A: the line's name Buttons (added here);
F: `castRow` photo cells (restored here); the torrent detail (all
themes): the new TMDB-bridged cast row (added here). No detail surface
is left without a cast path, and no cast entry remains a plain `Text`.
For completeness, the TVB tab's own "🎭 Diễn viên" actor rail was also
checked: its cards were already Buttons presenting `JoeActorPage` in
.tvb mode (JoeTVB.swift `actorCard`) — not part of the fault.

**Status: code-verified; CI + owner retest are the gates.**

## Fix 4 — No source-switch in the torrent player

**Root cause:** idea 13's transport menu exists only on the AVPlayer
path; the KSPlayer host's bar carried play/pause, seek, Phụ đề and Âm
thanh — no source control — while `PlayDirector.userSwitchSource()`
(the exact machinery the AVPlayer menu drives, position kept via the
standing itemReady resume rule) sat unused by this path.

**Fix (JoeKSPlayerView.swift):** a visible, focusable **"Đổi nguồn"**
button joins the bar's right-hand cluster (same `styleTransportButton`
dress as Phụ đề/Âm thanh, laid out left of them in `layoutControls`,
with the cluster math walking past whichever track buttons are visible).
Its handler wakes the bar, then calls `director?.userSwitchSource()` —
the same ladder advance / failover rungs as the AVPlayer path, no forked
machinery. Shown unconditionally, for parity with the AVPlayer menu.
**Status: code-verified.**

## Fix 5 — KSPlayer control bar never auto-hides

**Root cause (code-proven, three interlocking parts):**
`hideControlsIfIdle()` required `!focusInControls`; `showControls()`
deliberately moves focus INTO the bar (the v2.0.17 fix), so
`focusInControls` was permanently true while the bar was up; and
`didUpdateFocus` outright CANCELLED the hide timer
(`hideTimer?.invalidate()`) the moment focus entered the controls. The
bar could never hide — exactly the owner's finding.

**Fix (JoeKSPlayerView.swift):** idleness is now measured by the timer
alone. The `!focusInControls` veto is removed from
`hideControlsIfIdle()`; a focus move inside the bar now RE-ARMS the 4 s
idle timer (activity) instead of cancelling it. When the timer fires —
still guarded by: bar visible, no picker open, engine actually playing —
the bar hides and focus returns to the root through the existing
`setRootAcceptsFocus(true)` → `preferredFocusEnvironments` path, so the
remote is never stranded (the concern the old guard was written for).
The paused-state contract is unchanged: the bar never hides while
paused. Any remote press re-shows the bar via the existing press
handlers. **Status: code-verified; owner retest is the proof gate.**

## Fix 6 — Up Next card timing

**Root cause:** the countdown started only in
`PlayDirector.itemEnded()` — the card could only ever appear at/after
the end. (The advance itself passed on device: it reached episode 3.)

**Fix (JoePlayerView.swift):** the trigger moves into
`PlayDirector.tick(positionMs:durationMs:)` — both engines tick ≈ every
5 s (AV periodic observer; KS delegate throttled to 5 s). The first tick
inside the last 10 s starts the countdown at the ACTUAL seconds
remaining (rounded up, so the factory fires at — never before — the
item's end) via a new `startUpNextCountdown(initialSeconds:)` (the old
no-arg form delegates with 10). A per-item `upNextArmed` latch means a
Menu-cancel inside the window cannot be re-armed by the next tick, and
`itemEnded()` keeps the at-end fallback start ONLY when the tick
trigger never fired (very short items, coarse ticks) and never restarts
a running or cancelled countdown. The trigger runs before tick's save
rule on purpose (its last-30 s branch returns early). **Status:
code-verified.**

## Fix 7 — "Đang theo dõi" rail not findable

**Root cause (code-proven):** FollowStore is sound (toggle persists,
`@Published followed`, markSeen). The A/F/Ultra rail home appends the
"📌 Đang theo dõi" rail from `followStore.followed` ✓ — but design D's
`JoeWallHomeView` builds its shelves from the raw `joeRailSpecs(...)`
list plus its own owner shelves (Continue Watching, Favourites), and no
Following shelf existed there at all. An owner on D who pressed Theo
dõi found the rail nowhere.

**Fix (JoeBrowse.swift):** `JoeWallHomeView` now observes
`FollowStore.shared` (the same observation JoePhimHome carries) and
gains a third owner shelf, `followWallRail`, placed beside Continue
Watching / Favourites in BOTH wall modes (home mode; and the
"Tất cả phim" panel mode under the same `!filter.filtersActive` gate
the other owner shelves use) — the wall's own grouping for owner data,
above the catalogue, so the rail is findable rather than buried at the
bottom of the wall. Cards mirror the wall's construction exactly
(`Rail` + `PosterCard`, `form: .rail`, provider badge, focus id
`fol|<id>`); the meta line carries the same episode text the A/F rail's
`followedMovies` mapping builds ("Tập mới · N tập" when new episodes
exist); a tap calls `FollowStore.markSeen` (the A/F rule) and opens the
title's detail via the wall's `MovieRoute`. The shelf exists only while
at least one title is followed. **Status: code-verified.**

## Fix 8 — Film4K into the TVB chain (owner-approved 2026-11-18)

**Chain:** Tủ Phim → KKPhim → VSMOV → Film4K. TVB titles open a normal
detail (JoeTVB.open → MovieRoute); the chain work happens in that
detail's alternatives search. The F4K leg existed there but its
acceptance was `sameFilm` — exact normalized title + year — which TVB
titles listed on Film4K under divergent names fail (hunt: 15/60 sampled
titles held by Film4K, all playable).

**Two starvation points found and fixed:**
1. **Caller side:** `TpClient.parseMovie` read `imdbId` and
   `tmdbSeason` but never `tmdbId` — a Tủ Phim detail (the TVB tab's
   home provider) carried NO TMDB id, so nothing could feed an
   id-based leg. It now reads the id tolerantly in both payload shapes
   (flat `tmdbId`, Film4K's shape; KK-style `tmdb` object), with the
   family's 0-is-missing rule. KK details already carried the id.
2. **Callee side:** Film4K's SEARCH payload (`/api/search/suggest`,
   light items) carries no tmdbId at all — the id lives only on its
   DETAIL payload (`/api/title`, measured in F4kClient). So
   `Providers.searchSlug`'s new Film4K leg accepts: (a) on id directly
   if a result ever carries one; (b) on `sameFilm` exactly as before;
   (c) failing both, by **detail verification** — the search's top 3
   candidates are fetched by detail and the first whose detail carries
   the caller's TMDB id is accepted. Bounded (≤3 fetches per search
   pass, inside findAlternatives' existing 12 s envelope), Film4K-leg
   only; every other provider's proven name-based acceptance is
   untouched. The id now flows: detail load, the progressive
   alternatives/identity pass, the failover hop, and the torrent
   fallback's internal search all pass `tmdbId` into `findAlternatives`
   (4 call sites in JoeMovieDetail.swift).

**Labelled notes:**
- **Order:** the app's shared failover priority is `[KK, F4K, VS, TP]`,
  so for a TVB title the effective hop order is TP → KK → **F4K** → VS —
  Film4K sits second, not last as in the approved chain listing. This
  round does NOT reorder the global priority: it governs every film's
  failover and source-chip order, and changing it inside a fix round
  would be an unapproved policy change. Owner decision requested (see
  proposals): keep the shared order, or add a TVB-scoped ordering.
- **Coverage ceiling:** titles carried ONLY by Film4K still cannot
  appear in the TVB tab — the tab's catalogue is the bundled snapshot.
  Surfacing them needs a snapshot rebuild (offline pipeline), listed as
  a proposal, not built here.
- Whether Tủ Phim's live payload actually carries the id in one of the
  two read shapes cannot be verified from this VM; if it carries
  neither, TP-opened titles still starve the leg (KK-opened ones feed
  it today). First device round will show it in practice (the Film4K
  chip appearing on TVB details).

**Status: code-verified; CI + owner retest are the gates.**

---

## Fix 9 — Film title must hide WITH the transport bar (owner addition, 2026-11-18 12:40 CST)

**Owner evidence (post-update test on tvOS 27.2.1):** when watching a
film, after the transport bar auto-hides, the FILM TITLE stays on
screen. His ruling: the title hides TOGETHER with the bar and only
reappears when he presses the remote to bring the bar back. No separate
title timer.

**Which element carried the title (identified by full reads + Apple
documentation):** the only element in the player stack carrying the
film's title AND its poster together is **AVKit's Title View**, fed by
idea 13's `externalMetadata` (`.commonIdentifierTitle` = film title +
episode label, plus poster artwork) set in `JoePlayerView.refreshChrome`.
(The shared SwiftUI `statusCapsule` carries only the candidate's source
label — text, no poster; it is not the element. The exhausted slate's
title kicker is not a during-playback overlay.)

**The binding (JoePlayerView.swift):** the `PlayerController.Coordinator`
is now the `AVPlayerViewController`'s delegate
(`NSObject, AVPlayerViewControllerDelegate`; `attach()` sets
`controller.delegate = self` and `controller.transportBarIncludesTitleView = true`),
and the delegate callback
`playerViewController(_:willTransitionToVisibilityOfTransportBar:with:)`
sets `playerViewController.transportBarIncludesTitleView = visible` —
AVKit's documented "responding to transport bar changes" surface
(WWDC21 session 10191: the Title View is displayed just above the
transport bar; suppress it via `transportBarIncludesTitleView = false`).
The Title View's inclusion now follows the bar's announced visibility
state exactly, so the two cannot drift apart.

**KSPlayer path:** the KS host renders NO title/poster overlay at all
(verified by full read of JoeKSPlayerView.swift — only time labels, the
picker title and the subtitle render pair; no title view exists), so
nothing can linger there and there was nothing to bind.

**Honest limit:** whether toggling `transportBarIncludesTitleView`
mid-transition removes an already-presented Title View on tvOS 27
cannot be verified from this VM; the owner's retest is the proof gate.

**Status: code-verified; CI + owner retest are the gates.**

---

## Whole-app tvOS 27 audit (owner order 2026-11-18 12:26–12:27 CST)

Scope: the ENTIRE JoeTV app — all legacy code, not only the
2.0.25–2.0.27 additions. Method: subsystem-by-subsystem pass over the
target (source reads + targeted greps this round; web verification of
the changed tvOS surfaces — AVDisplayManager choreography per Tech Talk
503, dictation-language surface per Apple documentation). Deployment
target stays 17.0; nothing in the app depends on behaviour removed
between 18.6 and 27 (grep-verified: no `NavigationView`, no
`UIApplication.shared.windows`/`keyWindow`, no `UIScreen.main` size
reads, no single-parameter `onChange`, no `#available` forks in the
target).

| Subsystem | Verdict | Notes |
|---|---|---|
| Launch gate (JoeTVApp, SourceProbe) | already-27-clean | Pure SwiftUI + UserDefaults; the idea-17 gate is data-driven, no version-gated API. |
| Browse / detail (JoePhimHome, JoeBrowse, JoeMovieDetail, themes) | optimised-in-this-round (fixes 3, 7) | Otherwise clean. The hand-built theme chrome intentionally does NOT adopt Liquid Glass: the approved drawings govern appearance, and the app uses no standard TabView/material chrome that would auto-adopt it. Glass adoption is an appearance change = owner decision (proposal P3). |
| Player — AVPlayer path (JoePlayerView, AVPlayerViewController) | optimised-in-this-round (fixes 6, 9) | System transport + AVKit's automatic display matching are the platform-preferred forms on 27. AVKit 26 interstitial/chapter APIs: not applicable to this app's playback. |
| Player — KSPlayer path (JoeKSPlayerView) | optimised-in-this-round (fixes 1, 4, 5) | Display criteria now follow the documented 27-era choreography. Engine pin is old — see proposal P1. |
| Sports (JoeTVSection, Nuvio) | already-27-clean | URLSession + AVPlayer only; `onChange` uses the modern two-parameter form; scenePhase handling current. |
| TVB (JoeTVB + snapshot) | optimised-in-this-round (fix 8) | Snapshot model is offline data, OS-version-independent. Film4K-only titles = proposal P4. |
| Search (JoeSearch) | optimised-in-this-round (fix 2) | Netflix-style type-ahead is current-form SwiftUI. Dictation language is a platform limit (fix 2); a framework-level alternative is proposal P2. |
| Tunnel / proxy (JoeProxy, sing-box config) | already-27-clean | NWListener/Network-framework surface is stable across 18→27; the tunnel itself is configuration data, not API surface. Nothing to re-optimise. |
| Stores (WatchStore, FollowStore, JoeStores, TorrentSettings) | already-27-clean | UserDefaults + JSON documents; no deprecated persistence API. @Observable migration = proposal P5 (mechanical, no user-visible benefit alone). |
| Focus system (app-wide) | already-27-clean | Custom button styles + focus sections throughout; tvOS 26/27 focus-engine changes are additive and nothing here relies on removed behaviour. |

**Adopted in this round beyond the 8 fixes:** fix 9 (owner addition,
12:40 CST) and the HTTP connection-pool consolidation below (owner
approved as a build item, 12:43 CST). Beyond those, the audit found no
other clear-win 26/27 form worth churn in a fix round; inventing extra
changes would violate the round's scope. The fixes themselves are the
27-alignment (fix 1's choreography, fix 2's platform-truth labelling).

### HTTP connection-pool consolidation (owner-approved build item, 2026-11-18 12:43 CST)

**Before (session census, this round):** JoeHTTP cached one URLSession
PER TIMEOUT VALUE (classes seen: 12/18/25 s and the 25 s default), so
the same provider host was pooled once per timeout class — a connection
warmed by a 12 s search leg could not be reused by the 25 s detail leg
behind it. JoeImagePipeline ran its own session (8/host,
`returnCacheDataElseLoad` against the shared URLCache, 30/60 s
timeouts, prefetch worker cap 3). The player artwork fetch used
`URLSession.shared` (unbounded, outside any pool). TorrentClient's
RedirectProbe ran its own ephemeral session + delegate (8 s budgets,
redirect capture). TpClient ran its own no-redirect session + delegate.
JoeProxy ran two `.default` sessions (one-shot + streaming delegate).
StreamWarmer warms via AVFoundation (no URLSession — nothing to
consolidate). TMDBClient, subtitle fetch and SourceHealth already rode
JoeHTTP.

**After (JoeHTTP.swift):** ONE shared session for the whole data
family — `httpMaximumConnectionsPerHost = 6` (the house's deliberate
value, kept), `waitsForConnectivity = true`, session-level envelopes of
30 s (request) / 60 s (resource) as backstops only. The Team 6
total-duration guarantee — the reason the per-timeout sessions existed —
is preserved exactly, enforced per call instead of per session: each
`fetch()` races the shared-session task against the call's own deadline
(`withThrowingTaskGroup`; first finisher decides — the data, the fetch's
own error, or the deadline's `URLError.timedOut`, the same error the old
resource timeout produced; the loser is cancelled and drained so its
error can never escape over the winner's result). Caller cancellation
still cancels the fetch (findAlternatives' 12 s envelope depends on
it). The call's timeout is also applied to the request centrally in
`fetch()` — `data(for:)` callers did not all set it; the per-timeout
session config used to supply it silently. The player artwork fetch
moved from `URLSession.shared` onto `JoeHTTP.getData(..., timeout: 15)`,
fail-soft exactly as before. No request content, ordering, or
pooled-stream ranking changed anywhere.

**Kept separate, with reasons (owner constraint: consolidate the
transport, not the semantics):**
- **JoeImagePipeline** — a different traffic class and profile: folding
  600-poster shelf floods into the data pool would let image bursts
  contend with provider legs, and its config-level
  `returnCacheDataElseLoad` would risk serving stale provider JSON if
  data fetches inherited it.
- **RedirectProbe** — redirect-capture delegate + ephemeral profile;
  its whole job is watching the redirect the shared session follows
  silently.
- **TpClient.noRedirectSession** — session-level redirect refusal; the
  shared session cannot express it per-task without restructuring the
  Tủ Phim resolver.
- **JoeProxy** — the loopback proxy with its own header/streaming
  behaviour; excluded by the owner's constraint (a).

### Proposals for later (NOT built — owner decides)

- **P1 — KSPlayer engine bump.** The FFmpeg engine is pinned at
  KSPlayer 2.3.4 (2023-era); upstream has newer releases. Expected
  benefit: codec/format currency and engine bug fixes. Risk: playback
  regression surface is the whole torrent path — this must ride its own
  round with the Sony-style device trial protocol, never a fix round.
- **P2 — In-app speech recognition for voice search.** tvOS 26's Speech
  framework (SpeechAnalyzer / SpeechTranscriber) supports an explicit
  `vi-VN` locale, which would free voice search from the device's Siri
  Language setting (fix 2's platform limit). Research-first: on-device
  model availability and tvOS support must be verified before any build.
- **P3 — Liquid Glass chrome evaluation.** tvOS 26's design language
  auto-adopts only for standard components; this app's chrome is
  hand-built to the owner's approved drawings. Any glass adoption
  changes the approved look — owner's call, with faithful renders first
  (design-fidelity law).
- **P4 — TVB snapshot rebuild including Film4K-only titles.** Would let
  the tab surface titles the current snapshot doesn't carry (fix 8's
  ceiling). Offline pipeline work + a hosting/refresh decision.
- **P5 — @Observable migration.** 6 ObservableObject files; a mechanical
  refactor with no user-visible benefit on its own. Do it only
  opportunistically when a future round already touches those files.
- **P6 — TVB chain order.** Decide whether Film4K stays second in the
  shared failover order for TVB titles (current, this round) or a
  TVB-scoped order (TP → KK → VS → F4K, as approved in the chain
  listing) is wanted; the latter needs a TVB marker carried into the
  detail, which doesn't exist today.

---

## Files changed

- `JoeTV/JoeKSPlayerView.swift` — fixes 1, 4, 5.
- `JoeTV/JoePlayerView.swift` — fixes 6, 9; artwork fetch onto the
  shared pool (HTTP consolidation).
- `JoeTV/JoeSearch.swift` — fix 2.
- `JoeTV/JoeMovieDetail.swift` — fixes 3 (faces a, b), 8 (tmdbId at 4
  call sites).
- `JoeTV/JoeTorrent.swift` — fix 3 face (c): cast fetch + row in the
  torrent detail (both compositions).
- `JoeTV/TMDBClient.swift` — fix 3 face (c): `findByImdb` helper.
- `JoeTV/JoeHTTP.swift` — HTTP connection-pool consolidation.
- `JoeTV/JoeBrowse.swift` — fix 7.
- `JoeTV/Providers.swift` — fix 8 (findAlternatives / findSlug /
  searchSlug).
- `JoeTV/TpClient.swift` — fix 8 (tmdbId parse).
- `JoeTV/JoeTVB.swift` — fix 8 (chain note at the open site; no logic).
- `project.yml` — JoeTV version pairs only: 2.0.28 / 41.
- This report.

## Honesty declaration

- **Claims:** the 9 fixes (fix 3 in its three faces) and the HTTP
  consolidation are implemented as described, at the sites named; the
  audit verdicts reflect the greps and reads listed.
- **Evidence:** full FIX4 diff reviewed against the presnap
  (`backup-v2028-presnap/`) before pushing — the first push at commit
  `d9c1eed1` (fixes 1–8 + version), the follow-up push carrying fixes 9,
  3-face-(c) and the consolidation; Apple mechanism claims verified
  against Apple's own documentation this round (Tech Talk 503;
  Siri/dictation language documentation; WWDC21 session 10191 for the
  Title View binding).
- **Unverified, labelled:** there is NO Swift toolchain on this VM —
  nothing here is compile-verified until CI runs (parent dispatches),
  and nothing is device-verified until the owner retests on tvOS 27.
  Fixes 1, 2 and 5 in particular can only be proven on the device.
  Fix 8's Tủ Phim-payload id shape and the Film4K detail-verification
  hit rate are unverifiable from this VM. Fix 9's mid-transition Title
  View removal on tvOS 27 is unverifiable from this VM (stated in
  fix 9). Fix 3 face (c)'s live hit rate depends on torrent metas
  actually carrying IMDb ids, as the Stremio protocol specifies —
  unverifiable from this VM. The display-matching mechanism's
  remaining variables (synthetic format description without a DV
  configuration record; the owner's Match Content settings) are stated
  in fix 1, not buried. The HTTP consolidation's deadline race is a
  design-level preservation of the Team 6 bound; its behaviour under
  real slow-drip peers is only provable on device/network.
