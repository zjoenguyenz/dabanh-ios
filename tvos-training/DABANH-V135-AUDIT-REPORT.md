# Đá Banh TV — tvOS 27 audit + v1.3.5 report (Team DB27, 2026-11-18)

Owner's order: check whether Đá Banh TV (tvOS, v1.3.4, owner-verified
2026-11-17) needs updating for his move to **tvOS 27.2.1** on the
Apple TV 4K gen 3 (**A2843**, A15, 128 GB); if an update makes it
stronger or better optimised, do it. Device facts are from the
owner's own About-screen photo (tvOS 18.6 → 27.2.1).

Presnap: `~/workspace/dabanh-ios/backup-dabanhtv-v135-presnap/`
(target sources + shared engine files + project.yml, taken before
any edit).

Push commit (code + report): `b9bfe60ef968127b9ce29c85302be8864e5d947a`
on `main` (this line added by a docs-only follow-up commit).

## Per-area verdicts

### Focus — NO CHANGE (already current)
The app uses no deprecated focus API. Every button wears the
house construction built for the OS-rendered focus doctrine
(custom `TVCardButtonStyle` returning the label untouched +
`.focusEffectDisabled()`, labels owning their ring via
`tvCardBackground`/`TVPillFace`), and focus state runs through
`@FocusState` with the modern two-parameter `onChange` form.
tvOS 26's focus-engine work is system-side; nothing in this
target needs to move.

### Playback (AVKit) — NO CHANGE (deliberate)
`TVPlayerView` uses `AVPlayerViewController` + `AVURLAsset`
header-fields exactly as current AVKit intends; nothing in that
surface was deprecated or replaced across 18.6 → 27 for this
usage, and the same-fixture fallback ladder is app logic, not OS
surface. The file is also SHARED with the JoeTV and TV targets
and a second team was editing the JoeTV player area
concurrently — touching it from this pass risked another app's
regression for zero OS gain. Left untouched on purpose.

### Networking / playlist sync — NO CHANGE
Fetch, mirror-fallback, staleness gate and link validation all
run on the async `URLSession` APIs (`data(for:)`, task groups)
that remain the current form in the tvOS 27 SDK. No
completion-handler or delegate-era code exists in the target.

### Background behaviour — NO CHANGE
Refresh is a foreground 15-minute task loop plus a
refresh-on-foreground staleness check via `scenePhase` — the
pattern tvOS supports reliably for this app class. No background
task machinery was added (it would be garnish the system may
never run, and the playlist is never more than one foreground
launch away from fresh).

### Top Shelf — NO CHANGE
The extension uses the documented `TVTopShelfCarouselContent`
shape (`.actions` style, `setImageURL(_:for:)` with both screen
scales) — verified against Apple's TVServices docs when built
(v1.3.3); that API surface is unchanged in tvOS 26/27.

### Deployment target — NO CHANGE (not this pass's call)
`project.yml` sets tvOS 17.0 globally for every target,
including JoeTV. Raising it is a repo-wide decision, not a
Đá Banh-only one, and nothing in this app needs a >17 API.
Noted for the owner/parent; not changed.

### Image loading — CHANGED (the one material optimisation)
`TVCrestImage` and `TVChannelLogo` were bare `AsyncImage`.
AsyncImage keeps no decoded-image memory cache, and this app's
hero re-renders its crest art on **every focus move**, with rails
re-creating cards on scroll — so the same TheSportsDB crests
were re-fetched and re-decoded all session, showing as
placeholder flicker on the hero. tvOS 26/27 changed nothing in
AsyncImage to fix this. v1.3.5 adds `TVImageCache` in
`TVMatchViews.swift` (DaBanhTV-only file): decoded images held
in an `NSCache`, fetches through a dedicated `URLSession` with
a real `URLCache` (32 MB memory / 128 MB disk). A crest now
downloads at most once per launch, usually once ever. Rendering
is byte-for-behaviour identical: same soccer-ball placeholder
while loading, same `scaledToFit` image when loaded.

### Version label — CHANGED (correctness)
The in-app footer read "Đá Banh TV v1.3.1" — stale since the
1.3.2 build. Updated to v1.3.5 with this bump.

## What shipped as v1.3.5
- `DaBanhTV/TVMatchViews.swift` — TVImageCache + TVCachedImage;
  both AsyncImage call sites swapped.
- `DaBanhTV/TVContentView.swift` — footer label → v1.3.5.
- `project.yml` — DaBanhTV pairs ONLY: settings
  MARKETING_VERSION/CURRENT_PROJECT_VERSION and info.properties
  CFBundleShortVersionString/CFBundleVersion, 1.3.4/16 →
  **1.3.5/17**, read back after editing. JoeTV pairs (2.0.27/40)
  and every other target untouched — the project.yml diff vs
  presnap is exactly those four lines.

## Honesty declaration
- Claims: the audit above was read from the target's actual
  sources (all 9 source files + TopShelf provider + project.yml)
  and the tvOS 26 release-notes surface; every "no change"
  verdict names why.
- NOT verified: compilation — there is no Swift toolchain on
  this VM; the DaBanhTV CI build is the compile gate, and the
  IPA must be dissected (InfoTV.plist must read 1.3.5/17) before
  delivery, per house law. On-device behaviour of the image
  cache is likewise unproven until the owner runs the build.
- Concurrency: project.yml was re-read immediately before
  editing; only the DaBanhTV version lines were modified.
