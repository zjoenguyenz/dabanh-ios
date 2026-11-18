# JoeTV 2.0.27 — CI run #54 compile fix (Team FIX3)

**Fix commit: `6ed60e8150d36d4450692996879dfdbd2a7e9aa7`** (main, on top of 505e135c)
Version unchanged: **2.0.27 / 40** — this is a compile fix of the same build, not a new version.
Change surface: exactly 3 files (`JoeTV/JoeFollowStore.swift`, `JoeTV/JoeKSPlayerView.swift`, `JoeTV/JoePlayerView.swift`). Presnap: `~/workspace/dabanh-ios/backup-v2027-fix-presnap/`.
Method: every API error was verified against Apple's own documentation (DocC JSON at developer.apple.com) before the fix was written — the original faults all came from coding against iOS-shaped assumptions.

---

## 1. JoeFollowStore.swift:246–248 — UNNotificationContent title/body/sound unavailable in tvOS

**Verified tvOS surface:** Apple's documentation for `UNMutableNotificationContent.title` and `.sound` lists the Swift declaration for iOS, iPadOS, Mac Catalyst, macOS, visionOS and watchOS only — **tvOS is absent** (checked per-property; `body` is in the same group and was flagged by the compiler on line 247). In the tvOS Swift SDK all three properties are unavailable, so the content object for a presentable local notification cannot be built at all. There is no alternative tvOS API that presents such an alert.

**Fix (graceful degradation, labelled in code):** `MatchReminderStore.schedule(_:)` no longer requests authorization or builds content. It still (a) removes any stale pending request for the reminder's identifier and (b) keeps the fire-date guard, then deliberately no-ops, with a doc comment stating the tvOS reason and warning against restoring the iOS-shaped code. The reminder data itself is untouched: reminders are still stored, revalidated and cancelled exactly as before (`cancelReminder`'s `removePendingNotificationRequests` is a valid tvOS API and stays), and the in-app follow/reminder surfaces that read this store are unaffected. **Labelled gap: on tvOS the 15-minute pre-match system notification does not exist; the reminder is in-app only.** Nothing is faked.

## 2. JoeKSPlayerView.swift:287/289/290/379 — display criteria

**Verified tvOS surface:**
- There is **no `AVVideoDynamicRange` type** and no `videoDynamicRange:` initializer in the tvOS SDK. Apple's `AVDisplayCriteria` documentation (AVFoundation, tvOS 11.2+) lists exactly one initializer: `init(refreshRate: Float, formatDescription: CMFormatDescription)`. The dynamic range is carried inside the format description's colour extensions (ecosystem-confirmed: PQ transfer ⇒ HDR10/DV base layer, HLG ⇒ HLG).
- There is **no `preferredDisplayCriteria` property on UIViewController**. Apple's prescribed surface for non-AVPlayer playback (Tech Talk 503, "Introduction to AVDisplayManager") is the `AVDisplayManager` vended by the key window: `UIWindow.avDisplayManager` (UIKit doc symbol; the manager class is AVKit) and its `preferredDisplayCriteria` property (value type `AVFoundation.AVDisplayCriteria`, per AVKit's own docs).
- The initializer's `refreshRate` is `Float`, hence the Double→Float error on the old line 290.

**Fix:** `import AVKit` + `import CoreMedia` added. `start()` now builds the criteria via a new `makeDisplayCriteria(for:)` and stores it in `pendingDisplayCriteria`; a new `applyDisplayCriteria()` assigns it to `view.window?.avDisplayManager.preferredDisplayCriteria` — called from `start()` (covers re-starts while on screen) and retried from `viewDidAppear` (start runs before the host has a window). `teardown()` clears the manager's property and the pending value. `makeDisplayCriteria` builds a `CMFormatDescription` via `CMVideoFormatDescriptionCreate` (HEVC, nominal 3840×2160 — the name parse carries no codec/resolution; the mode decision rides on rate + colour extensions) with BT.2020 primaries/matrix + SMPTE ST 2084 PQ transfer for DV/HDR candidates and BT.709 for SDR, and wraps it in `AVDisplayCriteria(refreshRate: Float(candidate.fps ?? 23.976), formatDescription:)`. Fail-soft: any failure returns nil (no preference stated).
**Labelled gap (supported subset):** Dolby Vision is expressed as its PQ base layer — a bare format description cannot carry the DV configuration record (dvcC), so the system may match a DV candidate as HDR10 rather than DV. Frame-rate + HDR10/SDR matching are fully expressed.

## 3. JoePlayerView.swift:805/1420/1451/1461/1477 — main-actor isolation

`PlayDirector` is `@MainActor`; the referencing contexts were not:
- **805** (`director.$advanceTarget` / `advanceTarget`): `JoeDirectorBox` was a plain `ObservableObject`. **Fix:** the class is now `@MainActor` — its only use is as a `@StateObject` inside `JoePlayerView` (a View, main-actor context), so isolation matches its actual use; no behaviour change.
- **1420** (`director.sessionEntry`), **1451** (`director.currentLabel`), **1461** (`director.isFavourite`), **1477** (`director.hasNextEpisode`): `PlayerController.Coordinator.refreshChrome` / `refreshTransportMenu` were nonisolated. **Fix:** `@MainActor` on `refreshChrome`, `refreshTransportMenu`, and their caller `observe(_:player:)` (itself called only from `makeUIViewController`, a main-actor protocol entry point). No logic was changed — only isolation annotations (the file's diff is exactly 4 added lines).

Everything else in 2.0.25–2.0.27 is untouched; `project.yml` was not modified (no version bump, per instructions).

---

## Honesty declaration

- **Proven from primary sources:** the tvOS unavailability of the three notification properties and the exact `AVDisplayCriteria` initializer + `UIWindow.avDisplayManager` surface — read directly from Apple's documentation data (developer.apple.com DocC JSON) during this fix; the isolation error sites and their contexts — read from the code at HEAD 505e135c, whose line numbers match the CI log exactly.
- **Not proven here:** compilation itself — this VM has no Swift toolchain, so the fix is proven only when the re-dispatched CI run goes green. The edits follow the verified API declarations and in-project precedents and were re-read line by line, but a residual typo-level error cannot be excluded until CI confirms.
- **Behaviour deltas, stated plainly:** (1) tvOS match reminders are in-app only (no system notification) — a platform limit, not a choice; (2) DV display matching may land as HDR10 (PQ base layer) — the supported subset of the format-description mechanism; (3) all other behaviour is intended to be identical to the 2.0.27 code that failed to compile.
