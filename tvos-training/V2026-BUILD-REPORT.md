# JoeTV 2.0.26/39 — BUILD REPORT (checkpoint 2 of 3, continuous 13-idea run)

Date: 2026-11-18. Scope: ideas **4, 5, 7, 10** from
`tvos-training/IDEAS-20261118.md`. Checkpoint 1 (2.0.25, ideas 1+2+3+6) was
pushed as commit `854c087ee5bfc79407b2f09bf6ca4267e9d915c2`; this checkpoint
builds on it without waiting for the owner's test verdict (his instruction —
defects from his 2.0.25 test fold into the next package and are flagged there).
Package 3 (2.0.27: ideas 13, 17, 20, 21, 23) follows immediately.

Presnap: `backup-v2026-presnap/`. Version pairs bumped for the JoeTV target
only, read back: 2.0.26 / 39. Two NEW files registered in project.yml's JoeTV
sources: `JoeTV/JoeFollowStore.swift`, `JoeTV/JoeChannelFavourites.swift`.
Plus one coordinator micro-edit: `PlayCandidate` gained `dv`/`hdr`/`fps`
fields (JoePlayerView.swift) as the idea-10 data seam. Static verification
only — no Swift toolchain on this VM; CI is the compile gate.

## Idea 4 — Favourite TV channels + custom order (`JoeTV/JoeTVSection.swift`, new `JoeTV/JoeChannelFavourites.swift`)
New `ChannelFavouritesStore` (ordered keys `group|title`, UserDefaults JSON,
fail-soft; vanished channels are hidden, never deleted). The TV section gains
a synthetic "⭐ Yêu thích" chip in the existing synthetic-chip pattern: its
grid lists favourited channels in stored order, with an honest empty note.
Long-press (contextMenu) on a channel tile toggles the favourite. Live Events
was fenced off: it is a playlist group rendered by the shared group code, and
none of its behaviour (chip, hero, grid, play) changed — the only shared-code
touches are the generic favourite menu on tiles and a chip selected-state
guard. One internal truthfulness fix: a tile's LIVE badge now reads the
channel's own group instead of the effective group (identical on the group
grid; correct on the mixed-group favourites grid).

## Idea 5 — Trending rail (`JoeTV/JoePhimHome.swift`)
"🔥 Đang thịnh hành" rail inserted beside the "Mới cập nhật" rails, rendered
through the existing movieRail. Source: `TMDBClient.trendingWeek()` (the Top
Shelf's existing call). Matching to playable titles only: first a tmdbId map
over every PhimStore list; then a bounded fallback — at most 8 unmatched
titles searched across providers (tmdbId match wins, else normalized-title
match). Rail capped at 20, TMDB order preserved, unmatched titles dropped
silently — no dead cards.
Labelled limitation: theme D's poster wall reads `joeRailSpecs` directly
(from JoeBrowse.swift), so the Trending (and Following) rails appear in the
A/F/Ultra rail homes but not on the D wall in this checkpoint.

## Idea 7 — Follow & remind cluster
- **Data layer** (new `JoeTV/JoeFollowStore.swift`): `FollowStore`
  (baseline/latest episode counts; checks only ever raise `latest`),
  `MatchReminderStore` (local notifications via UNUserNotificationCenter at
  kickoff − 15 min, identifier per match; revalidate moves a reminder when a
  kickoff moves > 60 s, drops past ones, and NEVER deletes on absence),
  `PinnedTeamsStore`. All UserDefaults-persisted, fail-soft. No background
  work, no timers, no date claims anywhere.
- **7a badge** (`JoeTV/JoeMovieDetail.swift`, `JoeTV/JoePhimHome.swift`,
  `JoeTV/JoeTVApp.swift`): a "Theo dõi / Đang theo dõi" toggle beside the
  favourite control in all four detail anatomies, shown only for series
  (>1 playable episode by the episode UI's own playability test). The Phim
  home gains a "📌 Đang theo dõi" rail whose cards carry a "Tập mới" badge
  derived ONLY from the episode-count comparison; opening a followed card
  marks it seen. On app open (a JoeRootView `.task`, LaunchGate untouched),
  followed titles are re-checked via `Providers.detail` concurrently.
- **7b reminders + 7c pinned teams** (`JoeTV/JoeTVSection.swift`): long-press
  on a Thể Thao Torrent fixture offers "Nhắc trước 15 phút" / "Huỷ nhắc"
  (only when a kickoff exists and is in the future) and per-side
  "Ghim đội" items parsed from the fixture title; pinned teams' fixtures
  stable-partition to the front of the sports grid. Live Events untouched.
  Kickoff source, labelled: fixtures are `TorMeta` (no kickoff field), so
  kickoffs are derived from fixture titles via the target's own
  `KickoffParser` — the same function that fills `Channel.kickoff`. A
  fixture whose name carries no "HH:MM DD/MM" stamp offers pinning but no
  reminder. App-open revalidation re-fetches via
  `TorrentClient.fetchSportsEvents()` (the tab's own call).

## Idea 10 — Display-mode matching, torrent path (`JoeTV/TorrentClient.swift`, `JoeTV/JoeKSPlayerView.swift`, `JoeTV/JoePlayerView.swift`)
TorStream now carries `dv`/`hdr`/`fps`, stamped at construction from the
SAME `RankFeat` parse the ranking uses (fps added to that parse: explicit
"…fps" tokens and bare 59.94/29.97/23.976 rates; ranking never reads fps, so
pool order/scores cannot change). `playCandidates` stamps the features onto
each PlayCandidate (the coordinator-added fields). The KSPlayer host sets
`preferredDisplayCriteria` when a candidate starts — DV → .dolbyVision,
HDR → .hdr10, else .sdr; rate = parsed fps or 23.976 — and clears it on
teardown. It is a preference the system honours subject to the user's Match
Content settings (Apple's intended behaviour; commented as such). The
AVPlayer path is untouched (the system matches it already).

## Honest limits
- No compile possible on this VM; verification = full re-reads, delimiter
  balance vs the presnap, and a cross-file symbol audit (all store APIs,
  KickoffParser, trendingWeek, candidate stamps verified present with the
  specced names).
- Reminder reliability is bounded by tvOS local notifications and by the
  fixture titles actually carrying kickoff stamps; both bounds are stated
  above, not hidden.

## Delivery
Code commit on `main`: **66dde2f1489cc77dfa85586daa4da97d6d6fd206**
(10 paths: project.yml + JoeFollowStore, JoeChannelFavourites, JoeTVSection,
JoePhimHome, JoeMovieDetail, JoeTVApp, JoeKSPlayerView, TorrentClient,
JoePlayerView.) Parent: dispatch "Build JoeTV IPA" on main at this SHA for
the owner's test install. The run continues into package 3 (2.0.27)
immediately.
