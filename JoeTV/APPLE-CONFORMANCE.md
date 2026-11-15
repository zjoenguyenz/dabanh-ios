# APPLE-CONFORMANCE.md — Team 4 (Apple-platform conformance + product validation)

Phase 1 deliverable: firmware/hardware research, source-delivery conformance
audit against Apple's standards, required build-plan changes, and the Phase 2
post-build validation gates. Written 2026-11-15. **No app code or project.yml
was edited by Team 4** — findings and required changes are for the leader and
the owning teams. Sources are cited inline; Apple-official sources are marked
★, community/field sources are marked ○ and weighted accordingly.

Inputs: REWORK-LOOP.md (leader's board, incl. Auditors A/B/C findings);
JoeProxy.swift, JoePlayerView.swift, JoeHTTP.swift, Providers.swift,
TorrentClient.swift (headers), project.yml (JoeTV target) — all read in full
or in the relevant part; web research listed in §8.

---

## 1. Device & firmware facts (with sources)

### 1.1 Apple TV 4K generations

| Gen | Year | Chip | RAM | Notes |
|---|---|---|---|---|
| 1st (A1842) | 2017 | A10X Fusion | 3 GB | HDR10/Dolby Vision; HDMI 2.0a |
| 2nd (A2169) | 2021 | A12 Bionic | 3 GB | High-frame-rate HDR; HDMI 2.1; Wi-Fi 6 |
| 3rd (A2737/A2843) | 2022 | A15 Bionic | 4 GB | Adds HDR10+; fanless |
| 4th (A3593) | 2026-11-13 | A19 | 8 GB | Adds **AV1 hardware decode**, Wi-Fi 7 |

Sources: ○ FlatpanelsHD generation comparison
(https://www.flatpanelshd.com/news.php?subaction=showfull&id=1793342606);
○ MatterHome generation guide, "Sources: Apple specifications … and Apple's
tvOS release list" (https://matterhome.io/guides/apple-tv-4k-new-vs-old);
○ MacRumors buyer's guide (https://www.macrumors.com/guide/apple-tv-generations-compared).

Codec relevance to this app: **every** Apple TV 4K decodes H.264 and HEVC in
hardware; AV1 exists only on the 4th gen. None of the app's sources use AV1,
so codec hardware is not a constraint anywhere in the fleet. The binding
codec constraint is a *format* rule, not a hardware one — see §4 (Apple's HLS
spec: HEVC must be carried in fMP4, never in MPEG-TS).

### 1.2 The tvOS line the owner is actually on

- tvOS 26 (Sept 2025) introduced the Liquid Glass design system. Per the
  tvOS 26 release notes as summarised in field research, the design updates
  "are not carried forward to Apple TV 4K (1st generation) and older
  models" — Liquid Glass renders only on 2nd gen and later.
  ○ https://github.com/hipstercat/kinopub-apple-client/blob/HEAD/docs/archive/research-2026-07/02-liquid-glass.md
- tvOS 27 was released 2026-09-14; the current release is **tvOS 27.2.1
  (2026-11-13), available for Apple TV 4K 2nd generation and later**. The
  1st generation is capped at tvOS 26.6.x.
  ★ Apple security content of tvOS 27.2.1: https://support.apple.com/en-us/149721
  ○ https://www.macrumors.com/2026/11/13/apple-releases-tvos-27-2-1/
  ○ https://en.wikipedia.org/wiki/TvOS
- **Owner's box (inference, high confidence):** his iPhone runs iOS 27.2 and
  his TV visibly renders Liquid Glass (his photos + his words). Liquid Glass
  ⇒ Apple TV 4K **2nd generation or later**, running **tvOS 26.x or 27.x**
  (most likely 27.2.x). His exact model and tvOS build are **UNVERIFIED**
  — readable in Settings → System → About on the device; Phase 2 should
  record them from the owner's device before device-gate sign-off.
- **Deployment-target implication:** our minOS is tvOS 17.0
  (project.yml: `deploymentTarget.tvOS: "17.0"`). That is *not* what
  determines the behaviour at issue. Focus/glass rendering follows the
  **runtime OS** and the **SDK the binary was linked against**, not the
  deployment target. Keeping 17.0 costs nothing and excludes nobody;
  raising it would fix nothing. See required change B-3 (§6).

### 1.3 The SDK the app is actually built with

The house CI pattern (`.github/workflows/build-dabanh.yml`, read in full)
is `runs-on: macos-latest` + `setup-xcode` with `xcode-version:
latest-stable`. In November 2026 "latest stable" is the Xcode 27 line
(Xcode 27 shipped 2026-09-14 alongside tvOS 27). The JoeTV workflow file
itself is **not present in this local checkout** (only build-dabanh.yml
is), so the JoeTV job's exact steps are **UNVERIFIED from here** — but
every JoeTV run was dispatched from a workflow the leader controls, and
if it mirrors the house pattern (its runs print an `xcodebuild -version`
"Show toolchain" step), **v1.8 was linked against the tvOS 27 SDK**.
Phase 2 gate P-0 (§7) requires reading that step's output from the build
run before any focus verdict is finalised. Confidence: high, pending P-0.

Why the SDK matters — Apple's own documentation for
`UIDesignRequiresCompatibility` states: *"The system ignores this key when
you build for iOS 27 or later, iPadOS 27 or later, Mac Catalyst 27 or
later, macOS 27 or later, or tvOS 27 or later."*
★ https://developer.apple.com/documentation/bundleresources/information-property-list/uidesignrequirescompatibility
(quoted via ○ https://muhittincamdali.github.io/glassready/documents/opt-out.html
and ○ https://github.com/patrickserrano/lacquer/blob/HEAD/profiles/ios/skills/swiftui-liquid-glass/SKILL.md).
**Consequence: there is no Info.plist escape hatch from Liquid Glass on
the current toolchain. Do not add the key; it would be false comfort.**

---

## 2. Auditor A's open question: why didn't root-level `.focusEffectDisabled(true)` suppress the glow?

What the code does (verified): exactly one compiled
`.focusEffectDisabled(true)`, at JoeTVApp.swift:159, on the root view;
pills are `.buttonStyle(.plain)` with a self-drawn violet fill; Auditor A
proved no app code can draw the pale blob. What the device shows: a pale
cyan blob, larger than the pill, over the focused pill, text washed out.

Evidence assembled:

1. **tvOS 26 changed what "focused" looks like, system-wide.** Apple's
   HIG position (via field research): on tvOS, Liquid Glass is
   *focus-driven* — "Certain interface elements, like image views and
   buttons, adopt Liquid Glass when they gain focus," and "Glass never
   replaces focus indication — scale and inversion still need to be
   handled explicitly."
   ○ https://github.com/hipstercat/kinopub-apple-client/blob/HEAD/docs/archive/research-2026-07/02-liquid-glass.md
2. **The halo is a known tvOS 26 phenomenon on other apps.** Plex users
   reported a new "white glowing halo" around focused items immediately
   after the tvOS 26.0 update, "part of a new system-wide focus effect
   introduced in tvOS 26," on an app that never opted in; a later tvOS
   26.0 build adjusted the behaviour. That is the same visual signature
   as the owner's photo (pale, oversized, text-washing).
   ○ https://forums.plex.tv/t/white-halo-around-focused-items-in-plex-after-tvos-26-0-update/922317
3. **Root-level application is the configuration that fails in the
   field; per-view application (or owning the style) is what works.** A
   shipped tvOS app's fix commit records: they used ".plain +
   focusEffectDisabled" and still got the system's white focus plate
   layered over their card; the fix that produced exactly ONE focus
   indicator was a **custom ButtonStyle that owns the entire focus
   visual** — "the system never layers its own white focus plate over
   our card."
   ○ https://github.com/brandomoore/Plozz/commit/25a134986f242f5737adeb7724534c537afd703d
   Apple's own focus guidance pattern likewise shows
   `.focusEffectDisabled()` applied **directly on the focusable view**
   (the Button), paired with `.focused(...)`.
   ○ https://blakecrosley.com/blog/tvos-focus-engine-swiftui

**Team 4 verdict (confidence-labelled):**
- **HIGH confidence:** the blob is the tvOS 26/27 glass focus treatment.
  It is a different rendering path from the pre-26 focus effect, it
  attaches to the focused UIKit focus item (the Button), and on the
  current SDK there is no plist opt-out (§1.3). An app linked against
  the tvOS 27 SDK gets this treatment by default.
- **MEDIUM-HIGH confidence:** the root-only environment application did
  not reach the button's focus rendering in this hierarchy (custom
  focus hub, `.onMoveCommand` traps, `@FocusState`-driven overlays sit
  between the root modifier and the focus item). The field-proven
  reliable suppressions are (i) `.focusEffectDisabled(true)` applied
  **on each focusable view itself**, and (ii) stronger, a custom
  `ButtonStyle`/non-Button `.focusable()` chrome that owns the focus
  visual outright — which is exactly Team 1's assigned direction
  (board: per-view modifier on every focusable; contingency =
  non-Button `.focusable()` chrome). Team 4 endorses going straight to
  per-view application everywhere, with the custom-style/focusable
  treatment for the top-bar pills and poster cards, the two surfaces
  in the owner's photos.
- **UNVERIFIED:** the precise internal reason the environment value did
  not suppress the effect on the owner's exact tvOS build. Settling it
  would need either an Apple DTS answer or a controlled A/B build on
  the owner's box — neither is available to this team, and neither is
  needed: the fix does not depend on which internal mechanism failed.

---

## 3. Responsiveness & exit behaviour — the Apple standard (NEW: owner evidence 2026-11-15 00:09)

**Owner evidence:** v1.8 *freezes* his Apple TV; escaping to Home took
many Menu presses. Measured against Apple's platform contract, this is
the most serious defect class in the app — more serious than the visual
ones — because it breaks the one promise tvOS makes to the user: *you
can always leave.*

### 3.1 What Apple guarantees — and what it does not

- The system guarantees an exit **only if the app lets the press
  through.** Apple's WWDC session on tvOS UIKit states the mechanism
  plainly: for the app to resign to Home, the Menu press's
  `pressesEnded` event must travel **all the way up the responder chain
  to UIApplication**; if anything consumes it on the way, the app will
  not resign — and "if your application can't be exited by pressing the
  Menu button, you might fail App Review," because reviewers check
  exactly this.
  ★ Apple WWDC 2016 session 210, "Mastering UIKit on tvOS"
  (transcript: https://nonstrict.eu/wwdcindex/wwdc2016/210/)
- The HIG rule built on that mechanism: **Menu always navigates back**
  — dismiss the current screen, close the overlay, go up one level;
  **at the top level it returns to the Apple TV Home screen; never
  override this expectation**, and don't draw your own back button
  instead.
  ★ Apple HIG, tvOS "Remote and interaction" / "Focus and selection"
  (https://developer.apple.com/design/human-interface-guidelines/focus-and-selection),
  as summarised in ○ https://lobehub.com/skills/dirnbauer-webconsulting-skills-tvos-design
  (REMOTE-02) and ○ https://2023.redalemeden.com/blog/2015/tvos-hig-tldr/

### 3.2 What the app can intercept (and therefore owns)

- SwiftUI command modifiers resolve from the **focused view upward**:
  the nearest ancestor with a matching handler captures the command.
  `.onExitCommand` is SwiftUI's Menu-press capture; `.onMoveCommand`
  likewise captures directional presses for its view.
  ○ https://mackuba.eu/notes/wwdc19/integrating-swiftui/
  ○ https://blakecrosley.com/blog/tvos-focus-engine-swiftui
- **Consequence for a root-level handler:** an `.onExitCommand` (or an
  exit-trap view) installed at the root captures **every** Menu press
  in the app, in every state. From that moment the *app* — not the
  system — is solely responsible for reproducing the exit contract,
  including the root state, where the only correct behaviour is to
  **not consume the press at all**. A root handler that "handles" Menu
  at the root (dismissing nothing, re-asserting state, or triggering a
  focus change) has, by construction, disabled the system's exit.
- **`.onMoveCommand` consumes what it doesn't release.** Field
  evidence, device-confirmed by another tvOS team: "`.onMoveCommand`
  swallows unhandled directions — it does not fall through to the
  system focus engine"; the only way focus travels onward is for the
  handler to explicitly release/reassign focus. A trap with any
  unhandled or empty-target direction is an input dead-end.
  ○ https://github.com/scunio/chunky/blob/HEAD/docs/tvOS-design-patterns.md
  This is the same shape as board findings C-1/C-2 (traps consuming
  moves whose targets are empty).

### 3.3 The responsiveness standard

Apple's contract is not only about Menu. An app must:

- **R-1.** Keep the main thread free. No semaphore waits, sleeps, or
  synchronous network/disk work on the main thread or in code the main
  actor can reach synchronously — a blocked main thread cannot process
  the Menu press, the swipe, or the focus update, which *is* a freeze
  from the user's seat, whatever the CPU is doing elsewhere.
- **R-2.** Reach a settled, interactive state promptly after launch:
  exactly one focused element, focus engine idle, input live. Loading
  continues *behind* an already-responsive UI — never instead of it.
- **R-3.** Guarantee the focus update cycle terminates: no
  `@FocusState` write cycles, no `onChange` loops that re-request
  focus, no two traps handing focus to each other indefinitely. A
  focus loop starves the run loop that must deliver the Menu press.
- **R-4.** Honour Menu semantics at every depth: one press = one level
  back; at the root, one press = the press reaches the system and the
  app resigns to Home. No state in the app may require two presses for
  one level, and no handler may swallow a press silently.
- **R-5.** Never let data work impersonate an exit failure: while any
  load is in flight, Menu and swipes are processed within a frame
  budget. If input visibly lags behind a load, the load is on the
  wrong thread/actor — full stop.
- **R-6.** Degrade, never trap: every non-root screen must have a
  Menu-reachable way back that works in its *failure* states too
  (empty data, failed load, zero results) — the states where the user
  most wants to leave are exactly the states custom routing tends to
  forget (board C-1 is the standing example).

**Current-code suspects, stated as standards to check against (the
fixes belong to Teams 1/2; Team 4 sets the gate):** the root exit-trap
pattern (JoeNavigator/JoeExitTrap lineage — every Menu press in the app
is app-owned); move traps whose targets can be empty (C-1, C-2);
`JoeProxy.playlistURL` waiting on a semaphore for up to 3 s on a path
the MainActor play director can reach (JoeProxy.swift, board C-16) —
an R-1 violation by construction, whatever its average case; and the
24-job launch storm (Auditor B) competing with first focus and first
input — an R-2/R-5 risk even though the jobs are async.

---

## 4. Source-delivery conformance audit

Apple's yardstick is its HLS authoring specification for Apple devices
(★ https://developer.apple.com/streaming/hls-authoring-specification-for-apple-devices.html).
The rules cited below: **1.1** video must be H.264/AVC, HEVC/H.265,
Dolby Vision, or AV1; **1.2** H.264 containers must be fMP4 or MPEG-TS;
**1.5** HEVC containers **must be fMP4** (HEVC in MPEG-TS is
non-conformant and AVPlayer will not play it); **4.2** supported
caption formats are CEA-608, CEA-708, WebVTT, and IMSC1 (text profile);
**10.4** recommended MIME types — MPEG-TS `video/mp2t`, fMP4 init/segment
`video/mp4`, WebVTT `text/vtt` (or `text/plain`).

### (a) KKPhim — direct HLS to AVPlayer — **FITS**

HTTPS playlist/segment URLs handed straight to `AVURLAsset` with the
candidate's own headers via `AVURLAssetHTTPHeaderFieldsKey` — the
sanctioned AVFoundation mechanism for header-carrying assets, and the
only one AVPlayer offers (there is no custom data-source API; that
absence is precisely why path (b) exists). Conditions, both verifiable
in Phase 2: the KK CDN's H.264-in-TS is conformant (rule 1.2); **if any
KK title is ever served as HEVC-in-TS it cannot play** (rule 1.5) —
that would be a per-title failure, not an app defect, and the app's
failover ladder (PlayDirector) already treats it as a dead candidate
and moves on, which is the correct posture.

### (b) VSMOV / Film4K / Tủ Phim (+ CacheVideo) — JoeProxy loopback rewrite — **FITS WITH CONDITIONS**

The architecture is sound and, on this platform, unavoidable: the
segments are not playable as served (PNG prefix in front of the real
payload — TS sync at +499 for VSMOV, ~+637 for Tủ Phim Gold, +67 in
front of fMP4 for Film4K), AVPlayer cannot resync the way Media3 can,
and AVPlayer exposes no byte-level interception point. A loopback HTTP
proxy that rewrites the playlist (variants, segments, `EXT-X-MEDIA`,
`EXT-X-KEY`, `EXT-X-MAP` URIs — JoeProxy.swift does all of these) and
cleans each segment before AVPlayer sees it is the recognised Apple-
platform pattern for this problem. Both payload families are natively
playable once cleaned: MPEG-TS (rule 1.2) and fMP4 (rules 1.2/1.5).
Subtitles ride the providers' own HLS playlists as WebVTT renditions —
an Apple-supported format (rule 4.2) — and the proxy strips them to the
`WEBVTT` magic before serving. Conditions:

- **P-ATS (REQUIRED).** JoeTV's Info properties contain **no
  `NSAppTransportSecurity` at all** (project.yml, JoeTV target —
  verified). The loopback leg is cleartext HTTP, and the documented,
  narrow, review-safe key for exactly this is
  `NSAllowsLocalNetworking: true`. Field experience is split on
  whether a bare 127.0.0.1 load happens to pass without it
  (URLSession data tasks are lenient; other loaders are where it
  bites — ○ https://github.com/opendocument-app/OpenDocument.ios/pull/125),
  which is precisely the problem: as shipped, the app's central
  playback path rests on undocumented tolerance that an OS update can
  tighten. Add the key; do **not** add `NSAllowsArbitraryLoads`.
- **P-BIND (REQUIRED).** `NWListener(using: .tcp, on: .any)` listens on
  **all interfaces** — the proxy is reachable from the whole LAN,
  unauthenticated, holding per-stream provider headers in its routes.
  Apple's least-privilege expectation for a loopback service is to
  bind loopback only (e.g. `NWParameters.requiredInterfaceType =
  .loopback`, or an equivalent endpoint constraint). This also keeps
  the service entirely outside Local Network privacy scope, so no
  `NSLocalNetworkUsageDescription` is needed — one more reason the
  current all-interfaces bind is the wrong shape.
- **P-MIME (REQUIRED).** For a cleaned segment the proxy serves the
  **upstream** `Content-Type` (`http.mimeType ?? guessType`). A
  PNG-disguised segment can legitimately arrive labelled `image/png`;
  after stripping, the bytes are TS/fMP4/VTT wearing a PNG label,
  against rule 10.4's recommended types. The strip already *detects*
  the payload family (TS sync / `ftyp` / `WEBVTT`) — serve the type of
  the detected payload (`video/mp2t`, `video/mp4`, `text/vtt`).
- **P-LIFE (REQUIRED, with board C-16).** Routes are never evicted;
  over a long session the route table (and its stored headers) grows
  without bound. Evict on item end / session change.
- **Noted, not blocking:** the proxy answers every request with a
  full-body 200 and `Connection: close`, and buffers each segment
  whole via `dataTask`. HLS fetches are whole-object GETs, so this is
  within the model; it costs first-byte latency, not correctness. If
  AVPlayer ever issues a `Range` request the proxy ignores it —
  acceptable for HLS playlists/segments, recorded here as a known
  limitation. The up-to-3 s semaphore wait in `playlistURL` is **not**
  acceptable — see R-1/§3.3; it must leave every MainActor-reachable
  path (owner: Team 2, with C-16).

### (c) Torrentio / Real-Debrid — direct HTTPS to AVPlayer — **FITS WITH ONE CONDITION**

Add-on resolution is HTTPS (Torrentio, Cinemeta, Real-Debrid API —
TorrentClient.swift), and stream URLs are played directly with
`behaviorHints.proxyHeaders` applied as asset headers — the same
sanctioned mechanism as (a). **Condition (container rule): AVPlayer
plays MP4/MOV/fMP4/TS — it does not play MKV or AVI.** A torrent
candidate whose payload is an .mkv will fail at the player no matter
how healthy the link is. In the code Team 4 read, stream candidates
are built from URLs without a visible container filter
(JoeTorrent.swift candidate construction); Team 4 did **not** read
TorrentClient's full selection logic, so this is a **required check
for Team 2**, not a proven defect: non-AVPlayer containers must be
excluded or marked unplayable at selection time, so the owner is never
offered a stream the platform cannot render.

### (d) Player chrome & platform citizenship — **FITS**

Playback uses `AVPlayerViewController` with default controls
(JoePlayerView.swift) — Apple's own transport UI, native subtitle/
audio selection, and on tvOS 26/27 the native glass transport bar. The
app adds only a passive status capsule and a Menu-to-dismiss handler
in the player (one press = one level: correct §3 semantics). Nothing
custom fights the platform. JoeTV declares **no** `UIBackgroundModes`
(correct — a foreground video app), no entitlements, and the TV
section reuses the same AVPlayerViewController family (TVPlayerView).
The one platform-citizenship debt is the proxy's network posture in
(b) — P-BIND/P-ATS close it.

---

## 5. Standards checklist (the app must satisfy all of these)

**Focus & appearance**
- S-1. Background carries no hue: solid black or strictly R=G=B stops
  (Auditor A). On a platform whose rendering amplifies the only hue
  present, "almost black" is a colour.
- S-2. No system focus treatment is left to chance: every focusable
  view carries its own suppression (`.focusEffectDisabled(true)`
  per-view) and the app draws every focus visual itself (owner law:
  violet outline/fill on the element's own shape; no white/pale wash;
  `.buttonStyle(.card)` banned).
- S-3. Chrome the owner photographs (top-bar pills, poster cards)
  uses the strongest form: a custom `ButtonStyle` that owns the focus
  visual, or non-Button `.focusable()` views — the two field-proven
  ways to guarantee exactly one focus indicator (§2).
- S-4. Focus identities are unique per rendered element (board C-3)
  and every focus route terminates at a real element in every data
  state, including empty and failed (C-1, C-2, C-17).

**Responsiveness & exit (§3)**
- S-5. R-1…R-6 hold: no main-thread blocking waits anywhere in the
  launch/first-focus/play paths; launch settles to one focus with the
  engine idle; focus cycles terminate; Menu = one level per press and
  an un-consumed press at the root; input stays live during loads;
  failure states are as escapable as success states.

**Delivery & playback (§4)**
- S-6. Every playable candidate is an Apple-playable HLS or
  progressive asset: H.264 in TS or fMP4; HEVC only in fMP4; no
  MKV/AVI candidates offered as playable.
- S-7. The loopback proxy is loopback-only, ATS-declared
  (`NSAllowsLocalNetworking`), serves detected-payload MIME types,
  and evicts routes.
- S-8. Subtitles are WebVTT (or in-band CEA-608/708) renditions inside
  the HLS playlists — the only subtitle shapes AVPlayer renders.
- S-9. Playback chrome is `AVPlayerViewController`; custom UI around
  it is passive (status text) and never intercepts transport input.

**Build & package**
- S-10. No `NSAllowsArbitraryLoads`; no `UIDesignRequiresCompatibility`
  (ignored on the current SDK — §1.3); deployment target stays
  tvOS 17.0; the build's Xcode/SDK version is recorded with every
  delivery because behaviour depends on it.

---

## 6. Required build-plan changes (for the leader)

- **B-1 (project.yml, JoeTV info properties — Team 2 owns the file):**
  add
  `NSAppTransportSecurity: { NSAllowsLocalNetworking: true }`.
  Nothing else in the ATS dict. This is the only plist change
  conformance requires.
- **B-2 (explicit non-change):** do NOT add
  `UIDesignRequiresCompatibility` — ignored when built for tvOS 27
  (§1.3), and its presence would mislead every future reader.
- **B-3 (explicit non-change):** keep `deploymentTarget.tvOS: "17.0"`.
  No conformance reason to raise it; the behaviour at issue follows
  runtime OS + linked SDK, not the floor.
- **B-4 (JoeProxy.swift — Team 2 owns the file, with board C-16):**
  loopback-only listener bind (P-BIND); detected-payload Content-Type
  (P-MIME); route eviction (P-LIFE); remove the semaphore wait from
  every MainActor-reachable path (R-1).
- **B-5 (TorrentClient/stream selection — Team 2):** settle the §4(c)
  container question in code: MKV/AVI candidates excluded or marked
  unplayable at selection time.
- **B-6 (process):** every delivery report must state the Xcode
  version from the build run's toolchain step. Phase 2 opens the run
  log (gate P-0) — if the JoeTV workflow does not print it, add the
  same "Show toolchain" step the Đá Banh workflow already has.
- No entitlement, capability, or signing-pipeline changes are
  required by conformance. The unsigned-build → owner-signs flow is
  untouched by everything above.

---

## 7. Phase 2 — post-build IPA validation checklist (ALL gates must pass; any FAIL = do not deliver)

**P-0. Provenance.** Read the build run: commit SHA matches the
leader's declared source state; "Show toolchain" step's Xcode version
recorded; artifact SHA-256 matches the run page digest.

**P-A. Package gates** (unzip the IPA, read the .app):
- A-1 Bundle id `com.luun.nguyen.joetv`; version/build equal the
  project.yml JoeTV values for this delivery.
- A-2 MinimumOSVersion 17.0; `CFBundleIconName` = AppIcon; Assets.car
  present and contains both AppIcon and LogoWordmark.
- A-3 Info.plist contains `NSAllowsLocalNetworking` = true (B-1) and
  contains **neither** `NSAllowsArbitraryLoads` **nor**
  `UIDesignRequiresCompatibility` (B-2).
- A-4 The bundled TMDB key is present in the compiled binary
  (count-only check; the value is never printed) — the v1.8
  build-time injection must not regress.
- A-5 In-app version footer equals the plist version.

**P-B. Source-state gates** (the exact source the IPA was built from):
- B-1 `JoeTheme.background` is hue-free (S-1).
- B-2 Every focusable site in Team 1's inventory carries per-view
  `.focusEffectDisabled(true)`; pills/cards use the S-3 treatment;
  `.buttonStyle(.card)` appears nowhere in target sources.
  **AMENDMENT 2026-11-15 (WAIVED-BY-CONVERGENCE, Team 4 gate):**
  the `.card` ban is superseded for the top-bar section pills ONLY
  (JoeTVApp `sectionPill`): the Team 7 differential convicted the
  custom `.focusable()` pill construction as part of the freeze
  mechanism, and the convergence spec (Team 7 item 2) mandates real
  Buttons with `.buttonStyle(.card)` — the construction proven on
  the owner's box by Đá Banh TV — with per-view
  `.focusEffectDisabled(true)` retained on the Button itself. The
  ban stands everywhere else in the target.
  **AMENDMENT 2026-11-15 #2 (1.9.2, Team 4 re-gate — F9 DEVIATION,
  leader-ruled, gate-accepted):** the waiver is EXTENDED to every
  focusable control in the target. Spec F9 (DESIGN-SPEC-V19 §5)
  prescribes converting an artifact-showing Button class to the F2
  focusable-view pattern; the leader RULED AGAINST the literal F9
  route on device evidence — in the shipped 1.9.1 the `.card` pills
  rendered clean on the owner's box while every `.plain` control
  blobbed (owner photos 1/2/4), and Đá Banh TV (owner-verified on
  the same box) uses `.card` for every focusable control. 1.9.2
  therefore converts ALL focusable controls to real Buttons with
  `.buttonStyle(.card)` + per-view `.focusEffectDisabled(true)` +
  the app-drawn F3 treatments; NO Button was converted to a
  focusable view, and `.buttonStyle(.plain)` survives nowhere on a
  focusable control (one comment mention only). The deviation from
  F9's literal text is deliberate and recorded here; F9's operative
  rule — no third attempt with modifiers alone on the `.plain`
  construction — is honoured by changing the construction, not the
  modifiers. The `.card` ban is retired in full.
- B-3 No exit handler outside the G-EXIT inventory (below) exists,
  and none can consume a Menu press at the Phim root (S-5/R-4);
  every `.onMoveCommand`/`.onExitCommand` in the target has an
  explicit route or release for every direction/state, including
  empty-data states (C-1, C-2, C-17 patterns re-grepped, not assumed).
- B-4 Proxy code shows loopback-only bind, detected-payload MIME,
  route eviction (B-4); torrent selection shows the container rule
  (B-5).

**P-C. Responsiveness & exit gates (from the 2026-11-15 freeze
evidence — §3).** These are hard gates, equal in rank to playback:
- **G-EXIT-1 — Launch focus sequence terminates.** Audit the launch
  path of the built source: cold launch ends with exactly one focused
  element and no continuing focus writes (no `@FocusState` cycles, no
  `onChange`/`focusNonce` loops that can re-fire without user input).
- **G-EXIT-2 — Exit only at the Phim root (REDEFINED 2026-11-15,
  1.9.2, by the owner's explicit order).** The pre-1.9.2 wording
  ("Menu at root exits immediately", root = any top-level state) is
  RETIRED. The owner's semantics, mirroring the Android app: Back
  walks INSIDE the app, one level per press, and exits only from
  the Phim root. The gate artefact is the handler INVENTORY, not an
  ancestry argument (the ancestry argument failed on device twice:
  v1.1 NavigationStack, 1.9.1 wrapper handlers). The target must
  contain EXACTLY these 7 runtime `.onExitCommand` sites, each
  unconditional and on the OWNING view's root:
  (1) JoePlayerView — `{ dismiss() }`;
  (2) JoeSearch — `{ nav.searchOpen = false }`;
  (3) JoeMovieDetail — `{ nav.movie = nil }`;
  (4) JoeTorrentDetail (in JoeTorrent.swift) — `{ nav.tor = nil }`;
  (5) JoeTVSection — `{ nav.section = .phim }`;
  (6) JoeTorrentHome (in JoeTorrent.swift) — `{ nav.section = .phim }`;
  (7) JoeSettingsView — `{ nav.section = .phim }`.
  NOTHING on JoePhimHome, the shell (JoeRootView), or the app root;
  comment mentions do not count. Supporting structure the gate
  verifies with it: `section` is `@Published` on JoeNavigator and
  JoeRootView observes it; the detail layers are root-ZStack
  SIBLINGS of the section container (never descendants of section
  views), so exactly-one-consumer-per-press holds structurally; at
  the Phim root no handler is in any possible focus ancestry, so
  the press provably falls through to the system. The device
  observation (Phim-root press → Home; section/detail presses walk
  inward) is a DEVICE gate (P-E), not desk-passable.
- **G-EXIT-3 — One press per level, everywhere.** For each presented
  layer (player, search, movie detail, torrent detail) and each
  non-Phim section (TV, Torrent, Settings): Menu performs exactly
  that one inward step (close the layer / return to the Phim
  section); pressing Menu repeatedly walks to the Phim root and
  then out to Home, with no press swallowed in any layer, section,
  or failure state of either.
- **G-EXIT-4 — No main-thread blocking waits in the launch path.**
  Grep the built source for semaphore waits, `Thread.sleep`,
  synchronous `URLSession` usage, and `.wait(` on every path
  reachable from app launch to first settled focus, and on the play
  path: **zero hits allowed.** (This gate exists because the current
  code has one: JoeProxy's 3 s wait — it must be gone, not merely
  shortened.)
  **AMENDMENT 2026-11-15 (Team 4 gate, waiver 2):** the parenthetical
  above is stale. Measured fact: JoeProxy's single DispatchSemaphore
  (JoeProxy.swift:206/241) is a 90 s-bounded wait on the proxy's own
  queue — off the main thread, playback-only, unreachable from
  launch — and was eliminated as a freeze factor by Team 6's census.
  The gate's operative rule is unchanged for MAIN-THREAD blocking
  waits (zero allowed on the launch path); the JoeProxy semaphore is
  recorded as a known, bounded, off-main exception, not a violation.
- **G-EXIT-5 — Input stays live during load.** The Phim launch load
  (post-Auditor-B shape: deadline, phased jobs, cache-first) runs
  fully async; no store or view blocks the main actor while it runs;
  the error/retry surface is reachable by remote in the total-failure
  state (the C-1 hole, re-checked against the new routing).

**P-D. Source-path gates** (desk-checkable halves; playback itself is
P-E): KK candidates are direct HTTPS with asset headers; VS/F4K/TP/
CacheVideo candidates route through the proxy with their headers;
torrent candidates are HTTPS and container-filtered; each provider's
failure surfaces as a visible state, never an endless spinner
(Auditor B's deadline + `loadTimedOut` contract from the board).

**P-E. Device gates — stated, not desk-passed.** Team 4 cannot
execute on the owner's Apple TV. The following remain **UNVERIFIED
until observed on the device**, and the leader's delivery report must
carry them as such (the owner is the only device witness; his photo/
report is the evidence): focus glow absent on pills and cards;
background reads black; Menu at the Phim root exits in one press,
and Menu inside the TV/Torrent/Settings sections and the two
detail layers walks one level inward instead of exiting (G-EXIT-2,
redefined); each source
(KK, VS, F4K, TP, CacheVideo, Torrentio/RD) actually plays; subtitles
render. **No desk evidence upgrades these to "proven."**

**P-F. Regression sweep.** Every Auditor A/B/C finding (incl. C-1…
C-17 and U-1) and every Team 3 design-spec item is marked, in the
Phase 2 report, as FIXED-AND-VERIFIED (with the evidence) or
WAIVED-BY-LEADER (with the reason). Silence about a finding = FAIL.

---

## 8. Sources

★ Apple-official:
- HLS authoring specification for Apple devices —
  https://developer.apple.com/streaming/hls-authoring-specification-for-apple-devices.html
- Security content of tvOS 27.2.1 — https://support.apple.com/en-us/149721
- `UIDesignRequiresCompatibility` documentation (quoted text) —
  https://developer.apple.com/documentation/bundleresources/information-property-list/uidesignrequirescompatibility
- HIG, Focus and selection —
  https://developer.apple.com/design/human-interface-guidelines/focus-and-selection
- WWDC 2016 session 210, "Mastering UIKit on tvOS" (Menu/responder-chain
  mechanics; transcript mirror) — https://nonstrict.eu/wwdcindex/wwdc2016/210/

○ Community / field (weighted as such):
- FlatpanelsHD, Apple TV 4K generations compared —
  https://www.flatpanelshd.com/news.php?subaction=showfull&id=1793342606
- MatterHome, Apple TV 4K generations —
  https://matterhome.io/guides/apple-tv-4k-new-vs-old
- MacRumors, tvOS 27.2.1 release —
  https://www.macrumors.com/2026/11/13/apple-releases-tvos-27-2-1/
- tvOS version history — https://en.wikipedia.org/wiki/TvOS
- KinoPub Liquid Glass research (HIG focus-driven glass; 1st-gen
  exclusion) —
  https://github.com/hipstercat/kinopub-apple-client/blob/HEAD/docs/archive/research-2026-07/02-liquid-glass.md
- Plex forum, tvOS 26 white-halo reports —
  https://forums.plex.tv/t/white-halo-around-focused-items-in-plex-after-tvos-26-0-update/922317
- Plozz fix commit (per-view/custom-style focus suppression) —
  https://github.com/brandomoore/Plozz/commit/25a134986f242f5737adeb7724534c537afd703d
- Blake Crosley, tvOS Focus Engine patterns —
  https://blakecrosley.com/blog/tvos-focus-engine-swiftui
- Chunky tvOS design patterns (.onMoveCommand consumption) —
  https://github.com/scunio/chunky/blob/HEAD/docs/tvOS-design-patterns.md
- OpenDocument.iOS PR (ATS/loopback loader behaviour) —
  https://github.com/opendocument-app/OpenDocument.ios/pull/125
- glassready opt-out notes (Apple doc quotation) —
  https://muhittincamdali.github.io/glassready/documents/opt-out.html

---

## Honesty declaration

- **Claims:** §1.1/§1.2 hardware and version facts rest on the cited
  Apple support page plus three independent secondary sources that
  agree with each other. §4's per-path verdicts rest on Team 4's own
  full reads of JoeProxy.swift, JoePlayerView.swift, JoeHTTP.swift,
  Providers.swift and the JoeTV block of project.yml, measured against
  Apple's published HLS authoring rules (1.1/1.2/1.5/4.2/10.4). §3's
  exit standard rests on Apple's HIG rule and Apple's own WWDC
  session mechanics. The JoeTV Info-properties ATS absence (P-ATS)
  and the all-interfaces listener bind (P-BIND) and the upstream-MIME
  pass-through (P-MIME) are read directly from the shipped code.
- **Evidence:** file/line-level code reads as cited; every web claim
  carries its URL in §8; Apple-official and community sources are
  marked and weighted separately throughout.
- **Unverified, labelled:** (i) the owner's exact ATV model and tvOS
  build (inference: 2nd gen+, tvOS 26/27 — §1.2); (ii) the JoeTV CI
  workflow's Xcode version — the workflow file is absent from this
  local checkout; gate P-0 exists to settle it from the run log;
  (iii) the internal mechanism by which root-level
  `.focusEffectDisabled` failed on the owner's build (§2 — the fix
  does not depend on it); (iv) whether TorrentClient's full selection
  logic already filters containers (§4c — framed as a required check,
  not a defect); (v) whether any provider currently serves HEVC-in-TS
  or HTTP (non-TLS) media URLs at runtime — the clients contain no
  `http://` literals, but stream URLs are runtime data; per-title
  failures of that shape would present as dead candidates and are a
  Phase 2/device observation item; (vi) all P-E device gates, by
  design. Team 4 edited no app code and no project.yml in this phase.
