# TORRENT-PLAY-FIX — Joe TV tvOS v2.0.3: why [RD+] Torrentio streams hung on a black spinner, and the fix

Team TVOS-TORRENT-PLAY, 2026-11-15 (diagnosis + fix build, working tree only — NOT pushed; the leader runs push/CI/delivery).

## Honesty declaration

**Claims (each labelled proven / inferred):**

1. The torrent play path hands AVPlayer a Torrentio resolve URL whose target file is predominantly a Matroska file, and AVFoundation cannot demux Matroska — those items can never produce a frame. **Proven** at the code level (the engine is AVPlayer; the URL is the addon's own, unmodified) + **inferred** at the per-file level (the exact container of any one release cannot be read from Torrentio metadata — see §2; the inference rests on release-class evidence in the owner's own clips and on the working-vs-hanging pattern he reports).
2. The B-5 container filter that was supposed to keep MKV away from AVPlayer cannot see Torrentio's containers (no extension in the resolve URL, no extension in the release titles), so it passed the very files it existed to block. **Proven** from TorrentClient.swift + the titles visible in clip frame ed-03.
3. The player DOES have stall watchdogs (20 s pre-ready, 12 s mid-play freeze); they did not save the experience because the candidate walk was long, uncapped, repeated once by the refresh step, and every candidate's on-screen label is nearly identical — minutes of black screen read as one infinite spinner. **Proven** from JoePlayerView.swift + TorrentClient.playCandidates (pre-fix).
4. The fix (KSPlayer/FFmpeg engine for torrent candidates only, 12 s first-frame budget with a visible notice, candidate walk capped at 6, focus-ring bounds corrections, settings-field masked underlay). **Proven** as code in the working tree (diff described in §5); **unverified** on any device or compiler — see below.

**Evidence:** the owner's four clips (frames in `~/workspace/tv-build/verify-v230/clips/`, read directly: ed-01…ed-10, n03-*, n09-*, b2-*); full reads of JoeTorrent.swift, TorrentClient.swift, JoePlayerView.swift, JoeSettings.swift, JoeTheme.swift (PosterCard, JoeFocusRing); §TVOS-TORRENT-AUDIT in HERO-FORENSICS-REPORT.md (JoeProxy's exclusion from the torrent path; RD download-host shape); REWORK-LOOP.md (B-5's origin; the latency round's watchdog constants); KSPlayer 2.3.4's own sources read at the pinned tag (Package.swift, KSPlayerLayer.swift, KSOptions.swift, KSVideoPlayer.swift) via the vendor's GitHub.

**Unverified, labelled:**
- Swift was NOT compiled (no toolchain on this VM) and no Apple TV exists on this side. The CI build is the first compile; the owner's install is the first device run. Specific compile-surface risks are listed in §7.
- The Torrentio resolve-URL shape (`…/resolve/realdebrid/<token>/<hash>/<fileIdx>`, 302 → a `*.download.real-debrid.com` file URL) is reasoned from Torrentio/RD public behaviour and the audit's host evidence — the owner's token was NOT used anywhere in this round, and no live Torrentio/RD request was made.
- Whether any individual release the owner tapped was MKV vs MP4 is not directly observable from here; the container verdict (§2) is a class-level conclusion, not a per-file measurement.
- Item C's system-ring component (§6) is labelled inference from the clip frames; the app-side bounds defect it accompanies is proven in code.

---

## §1. The tap → resolve → play path, traced (behaviour = pre-fix; line numbers = current tree)

1. **Tap.** `JoeTorrentDetail.play(_:)` (JoeTorrent.swift:970) builds a `PlayDirector` whose `resolveLadder` re-fetches the stream list and converts it via `TorrentClient.playCandidates(streams:preferred:)` (JoeTorrent.swift:993–1001). `hopIdentity` is nil; `fallbackCandidates` is nil — the torrent section's sessions have no hop and no rung behind the ladder.
2. **Conversion.** `TorrentClient.playCandidates` (TorrentClient.swift:400) puts the tapped stream first — `resolvePlayable` (TorrentClient.swift:365) returns its `url` verbatim when `TorStream.playable` is true — then appends every other `playable` stream in list order, uncapped. For an [RD+] entry the URL is the addon's own: with the owner's configuration the stream list comes from his Torrentio (bare-token config builds `https://torrentio.strem.fun/realdebrid=<token>` as the base — TorrentClient.swift, `TorrentSettings.effectiveBase`), and an [RD+] stream's `url` is Torrentio's resolve URL on `torrentio.strem.fun`, which redirects to the unrestrict­ed file on a `download-*.real-debrid.com` host. The URL is handed over **direct** — JoeProxy is not in this path (proven by the audit's trace of `asset(for:)` + JoeProxy's call sites; JoeProxy serves only the provider HLS legs).
3. **Playback.** `JoePlayerView` (JoePlayerView.swift, `.playing` branch) creates `PlayerController`, a `UIViewControllerRepresentable` whose `makeUIViewController` (line 521) builds a plain `AVURLAsset` (`asset(for:)`, line 533 — candidate URL + headers) inside an `AVPlayerViewController` and calls `play()`. **The engine for every candidate, torrent included, was AVPlayer.** There was no container inspection at hand-off time beyond the B-5 selection gate (§2), and no proxy, no transcode, no alternate engine anywhere in the app (the Settings header comment even records the standing assumption: "Playback is AVPlayer everywhere").

## §2. Container verdict

- Torrentio/RD direct files for the release classes in the owner's clips — `REMUX.Bluray…AVC.TrueHD`, `BluRay x265`, `2160p HEVC HDR x265`, `BDRemux`, `BluRay … TrueHD5.1.x264` (frames ed-02, ed-03, n03-01) — are Matroska files in effectively every case; WEB-DL/WEBRip releases split between MKV and MP4. AVFoundation's demuxer set is ISO-BMFF (MP4/M4V/MOV), MPEG-TS and HLS — **there is no Matroska demuxer in AVPlayer**, so an MKV URL can never reach first frame: the item fails (`Cannot Open`-class) or lingers unready, and no picture is possible, full stop. The same file plays on the Sony because ExoPlayer demuxes MKV natively.
- **Why the existing guard didn't guard.** `TorStream.playable` (pre-fix TorrentClient.swift:109) folded in `containerPlayable` (B-5), which reads the container from (a) the URL's extension — Torrentio resolve URLs have **no extension** — or (b) a `.mkv`-style token in the release title — Torrentio titles carry the release name **without** the file extension (visible verbatim in the owner's frames: "The.Invite.2026.REMUX.Bluray.1080p.AVC.TrueHD5.1-DreamHD…"). Both probes miss, `containerPlayable` defaults to true, and the row is even badged "PHÁT NGAY". The filter only ever caught streams from addons that volunteer an extension.
- **The "sometimes it plays" pattern** follows immediately: the entries that played for the owner are the minority whose underlying file is actually MP4 (some WEB releases). Badge colour (yellow TORRENT vs the green PHÁT NGAY capsule) never discriminated anything — both classes contain both containers. Colour was never the variable; the file's real container was, and Torrentio metadata does not state it.

## §3. Stall handling — what existed, and why it read as an infinite spinner

The player was not watchdog-free (JoePlayerView.swift, `PlayerController.Coordinator`):
- **U-1 pre-ready watchdog:** 20 s — an item whose status stays `.unknown` is fed into `director.itemFailed()`.
- **Mid-play freeze watchdog:** 1 s ticker; 12 s without playhead advance (post-ready, not user-paused) → same failure path.

Against THIS failure mode they were structurally outmatched:
1. **Every candidate fails the same way.** MKV items either fail fast (→ next candidate) or burn the full 20 s (unready). Either way the screen stays black with the AVPlayerViewController spinner.
2. **The walk was uncapped and long.** A popular title returns 15–35 [RD+] entries; `playCandidates` returned all of them.
3. **The labels are indistinguishable.** `PlayCandidate.label` is the stream's `name` — for Torrentio that is "[RD+] Torrentio ⏎ <quality>" for nearly every row, so candidate changes are invisible on the status capsule (the clips show one unchanging label for 24–30 s).
4. **Exhaustion doubles the walk first.** After the last candidate, `failoverStep()` refreshes once and re-walks the same list before the exhausted slate can appear (torrent sessions have no hop/rung to shorten this).
5. Net worst case before any slate or message: on the order of **2 × 25 × up to 20 s ≈ many minutes** of black screen. In any 30 s clip: a spinner that never resolves — exactly what the owner filmed. There was also no "source N of M" progress and no reason shown; the capsule only ever names the current candidate.

So the gap was not a missing timer; it was a timer calibrated for 2–4-candidate provider ladders, applied to a 25-deep list of files the engine mostly cannot open, with no visible accounting.

## §4. Routing sanity

Per §TVOS-TORRENT-AUDIT (HERO-FORENSICS-REPORT.md): the Sing-box profile (v14, device-verified 2026-11-15) routes `real-debrid.com` (suffix — covers `download-*.real-debrid.com`), `torrentio.strem.fun`'s host family and the other torrent hosts **direct**, ahead of the tunnel rule, with `final: direct` as backstop. The URL the player receives is therefore reachable in principle on the owner's box: Torrentio resolve → 302 → RD download host, both legs direct. Nothing in this fix changes routing, and no profile change is needed. (The v15 draft from the audit round remains a byte-identical spare; it is not part of this fix.)

## §5. What changed (v2.0.3, build 16)

### A. Torrent files actually play — KSPlayer (FFmpeg) for the torrent path only
- **Engine choice.** VLCKit vs KSPlayer: VLCKit ships via CocoaPods / a vendored binary and has no maintained SPM product — this repo builds with XcodeGen + SPM on GitHub Actions, so VLCKit means adding a CocoaPods stage or a hand-vendored XCFramework to CI. KSPlayer is SPM-native, tvOS-first-class (tvOS 13+), FFmpeg-based (demuxes MKV/AVI/TS…, HDR10/HLG passthrough), and is the player other Stremio-class tvOS apps ship. **KSPlayer 2.3.4, pinned `exact:`** (the last 2.x tag; its package has a single product, "KSPlayer", and carries its own FFmpegKit + DisplayCriteria dependencies — all verified against the tag's Package.swift). License note for the record: KSPlayer's free distribution is GPL (the repo is public and personal-use; a paid LGPL edition exists if that ever matters).
- **Wiring** (`project.yml`): top-level `packages:` entry; the JoeTV target gains `- package: KSPlayer` and the new source `JoeTV/JoeKSPlayerView.swift`. No other target depends on the package; no other target compiles the changed player files (JoePlayerView.swift / TorrentClient.swift / JoeTorrent.swift are JoeTV-target-only — verified in project.yml).
- **Dispatch** (`JoePlayerView.swift`): `PlayCandidate` gains `engine` (`.avPlayer` default — every provider ladder is untouched). The `.playing` branch routes `.ffmpeg` candidates to the new `JoeKSPlayerController` and everything else to the existing AVPlayer controller; the shell, status capsule and director contract are shared, and the Phim substitution rung inherits the fix automatically because its candidates come from the same conversion.
- **Conversion** (`TorrentClient.swift`): `playCandidates` tags every candidate `.ffmpeg`. `TorStream.playable` now means "carries a direct URL" (the FFmpeg engine opens all containers), so MKV entries are no longer mislabelled — and no longer filtered OUT of the candidate list either. The B-5 predicate (`containerPlayable` + the container sets) is retained as the documented AVPlayer boundary; RdClient's hash-resolution file pick drops its B-5-era "largest AVPlayer-native file" preference (it could select a small .mp4 sample over the .mkv feature) and now picks the addon's fileIdx or the largest file.
- **The KS controller** (`JoeKSPlayerView.swift`, new): a `UIViewControllerRepresentable` + host view controller mirroring the AV coordinator's contract — KSPlayerLayer created with `KSOptions.firstPlayerType = KSMEPlayer.self` set at creation (the FFmpeg engine, deterministically; torrent candidates are the only KSPlayerLayers the app creates), the candidate's headers applied via `options.appendHeader` and the house user agent as the default UA (same discipline as `asset(for:)`). Delegate events drive the director: ready → the resume rule via the new engine-agnostic `PlayDirector.itemReady(durationMs:seek:)` (the AVPlayer `itemReady(player:)` now delegates to it — identical rule, identical seek tolerances); time callbacks → `director.tick` throttled to the AV path's ~5 s cadence; finish → `itemEnded` / failure. Transport: KSPlayerLayer's own remote-command registration (play/pause, ±15 s, position) plus host-controller clicks — Select toggles play/pause, Left/Right seek ∓30 s; Menu is never swallowed. **Known scope cut, stated plainly:** no touch-surface scrub bar / system transport chrome on this engine (AVPlayerViewController provides that only for AVPlayer); the AVPlayer path keeps it in full.
- **Resume/progress parity:** Continue Watching ticks, the >20 s / last-30 s resume rule and the finished rule all run through the same PlayDirector, so torrent CW entries behave exactly as before — now for files that can actually play.

### B. Stall budget for the torrent path (Android parity)
- **First frame: 12 s** (Android STALL) from attempt start in the KS controller; on expiry the attempt fails with the visible capsule notice **"Nguồn này không phát được — đang chuyển nguồn khác…"** and the director advances to the next stream in the owner's list order.
- **Mid-play freeze: 12 s** without playhead advance (Android POSITION_STALL), judged by a 1 s ticker with the same guards as the AV freeze watch (user-pause holds the clock open; the file's end belongs to the finish delegate).
- **The walk is capped at 6 candidates** (Android MAX_TRIES) in `playCandidates` — lead (tapped) + next five in list order — so the worst case to the exhausted slate is bounded (~6 attempts, most failing fast) instead of the old open-ended walk. No silent infinite loading remains in the torrent path: every attempt either plays, fails fast on an engine error, or is cut at 12 s with a message.

### C. Focus ring bounds
- **Proven app-side defect (theme D / Poster Wall):** `PosterCard.wallBody` drew its ring over the **art only**, while the focusable card is art + title block — the app ring and the card's bounds disagreed by construction. The ring now overlays the **whole card** (JoeTheme.swift, wallBody) with the same shape (rCard), colour and width values.
- **Torrent stream rows** (JoeTorrent.swift, streamRow): the hand-rolled overlay (a private ternary copy keyed off the parent's FocusState) is replaced by the shared `JoeFocusRing` primitive — the same rField shape as the row's fill, drawn inside the row's bounds, environment-driven like every other control in the app.
- **Labelled inference (not claimed as fixed by code):** the clips also show a second, outset outline around focused rows/cards — that is the tvOS system focus ring, which sits outside the view's bounds by design and which the app cannot reposition without the banned focus-effect surgery (the standing construction law: no focus-effect disabling anywhere in this target). With the app-side bounds corrected, the app's own ring coincides with the item's painted edge in all three themes; the device check (§8) is where the owner confirms the combined look.

### D. Settings token fields (JoeSettings.swift)
- The secure branch of `field(...)` now wraps the SecureField in a `ZStack` with an always-installed bullet row painted **from the stored string itself** (one "•" per stored character, capped at 40, hit-testing off, same font/colour the field chrome applies). tvOS's lazy secure-text redraw — the cause of the dots vanishing during focus moves/scrolls — can now only ever reveal the same dots underneath, so a saved RD/TorBox/TMDB value reads as saved in every state. The value is never rendered in clear text anywhere; nothing is logged.

### Version
- `project.yml`, JoeTV target only: MARKETING_VERSION / CFBundleShortVersionString **2.0.3**, CURRENT_PROJECT_VERSION / CFBundleVersion **16** (next after 2.0.2 / 15, the same way v2.0.2 was stamped). Hero/image pipeline (P1/P2) and the theme system are untouched.

## §6. Convergence greps (post-change, JoeTV/*.swift)

Code occurrences (comment/record mentions excluded — the only hits anywhere are the pre-existing historical comments, unchanged by this round):

| Pattern | Result |
|---|---|
| AsyncImage (code) | 0 |
| focusEffectDisabled (code) | 0 |
| scaleEffect (code) | 0 |
| JoeMoveTrap (code) | 0 |
| onChange(of: …focus…) | 0 |
| Conditional view insertion/removal driven by focus in changed files | 0 — item D's underlay is always installed; item C is overlay-only value changes |

Brace/paren/bracket balance: 0 net on all six edited Swift files (JoeKSPlayerView, JoePlayerView, TorrentClient, JoeTorrent, JoeTheme, JoeSettings).

## §7. Compile-surface risks for the CI build (first compile)

1. `KSPlayerLayerDelegate` is `@MainActor` in 2.3.4; conformance sits on a `UIViewController` subclass — the shape KSPlayer's own Demo uses — but this is the single most likely first-compile friction point.
2. `KSMEPlayer` is referenced as a public, app-settable type in KSPlayer's own docs (`KSOptions.firstPlayerType = KSMEPlayer.self`); if the symbol is not public in 2.3.4, the fallback is `KSOptions.secondPlayerType`-only configuration (the layer auto-swaps engines on error) — a two-line change in JoeKSPlayerView.
3. XcodeGen `exact:` pin for the package + `- package: KSPlayer` target dependency — standard XcodeGen package syntax; FFmpegKit resolves transitively from KSPlayer's own manifest (from: 6.1.3).
4. KSPlayer 2.3.4 is Swift 5.9-tools / StrictConcurrency-experimental; the app target is SWIFT_VERSION 5.9 — no language-mode change was made.

## §8. Leader device-check script (exact)

Install v2.0.3 (16) on the Apple TV, tunnel profile as-is (v14), then:

1. **The headline case.** Phim Torrent → open **The Invite** → tap the FIRST [RD+] entry (the 2160p WEBRip / top row). Expect: picture within ~12 s. If that file is dead, expect the capsule **"Nguồn này không phát được — đang chuyển nguồn khác…"** and the next source to start — never a black spinner past ~12 s on any single source.
2. **The 4K HDR case.** Back → **Spider-Man: Brand New Day** → tap the **[RD+] Torrentio 4k HDR10+** entry. Expect picture (HDR badge on the TV is a bonus confirmation). Repeat with a 1080p BluRay x265 entry — the class that always hung before.
3. **Series case.** Any series → pick an episode → tap its first [RD+] stream → picture or the visible advance above.
4. **Failover honesty.** If a title offers a "file removed"-class dead entry, the app must advance on its own; after at most 6 attempts it must land on the exhausted slate with Thử lại / Quay lại — photograph any slate reached.
5. **Resume.** Play any torrent title past 1 minute, Menu out, reopen it from Continue Watching → expect the "Tiếp tục từ …" capsule and the position restored.
6. **Transport.** During torrent playback: remote Play/Pause button toggles; Select click toggles; Left/Right clicks jump ∓30 s; Menu exits to the detail. (No scrub bar on this engine — known, see §5A.)
7. **Focus ring.** In the torrent stream list and the poster grids, move focus slowly: the app ring must sit ON the row/card edge (all three themes — check Tường Poster especially, where the ring previously stopped at the art). Photograph one focused row + one focused card per theme if it still looks doubled/loose.
8. **Settings fields.** Cài đặt → look at Token Real-Debrid / Token TorBox: dots visible; move focus up/down the page and scroll — the dots must never disappear. (Values stay masked; do not photograph the fields while editing.)
9. **Regression sweep (provider paths untouched).** One KKPhim title and one VSMOV title from the Phim tab play with the usual player UI (scrub bar present); Đá Banh-side nothing changes (separate app).

## §9. Files changed (the leader's push set)

- `project.yml` — KSPlayer package (exact 2.3.4), JoeTV target dependency + new source, version 2.0.3 (16).
- `JoeTV/JoeKSPlayerView.swift` — NEW: the FFmpeg-engine player controller (item A + B).
- `JoeTV/JoePlayerView.swift` — PlayCandidate.engine; engine dispatch in the playing branch; engine-agnostic itemReady (AVPlayer behaviour identical).
- `JoeTV/TorrentClient.swift` — playable semantics; playCandidates .ffmpeg + cap 6; RdClient file-pick preference retired.
- `JoeTV/JoeTorrent.swift` — stream-row ring via the shared JoeFocusRing (item C).
- `JoeTV/JoeTheme.swift` — PosterCard theme-D ring bounds = whole card (item C).
- `JoeTV/JoeSettings.swift` — secure-field masked underlay (item D).
- `JoeTV/TORRENT-PLAY-FIX-REPORT.md` — this report.

Nothing pushed; no device contacted; the owner's tokens were not used anywhere in this round.
