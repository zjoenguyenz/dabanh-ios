# V2029 — Cluster D: Remove voice search (item 8)

**Owner decision (2026-11-18):** remove voice search from Joe TV tvOS entirely —
"nên bỏ phần giọng nói đi tại vì nó toàn bị Siri can thiệp thôi". Tested on 2.0.28:
the in-app 🎤 Nói sheet + Siri Remote dictation path never worked (system Siri
intervened). No Speech-framework substitute was added (explicitly forbidden).

**File edited (only file):** `JoeTV/JoeSearch.swift`
**Reference:** all line numbers below are in the presnap
(`backup-v2029-presnap/JoeTV/JoeSearch.swift`, 934 lines). The working tree was
byte-identical to the presnap before editing (verified by `diff`). After the
edit the file is 767 lines (−167 net).

## What was removed

| # | Symbol / construct | Presnap location | Notes |
|---|---|---|---|
| 1 | `@State private var voiceOpen` | JoeSearch.swift:66 | Sheet presentation state |
| 2 | `@State private var voiceDraft` | JoeSearch.swift:67 | Sheet-local draft text |
| 3 | Voice state comment block (v2.0.25 Idea 2) | JoeSearch.swift:59–65 | Removed with 1–2 |
| 4 | `.fullScreenCover(isPresented: $voiceOpen) { JoeVoiceSearchSheet(...) }` + its explanatory comment | JoeSearch.swift:180–190 | Presentation wiring; the body's `.onExitCommand` and `.defaultFocus($keyFocus, .key("a"))` are untouched |
| 5 | "Nói" button — `Button { openVoiceSearch() }` with `JoeSecondaryLabel(title: "Nói", systemImage: "mic.fill")`, `.joeCardButton()`, `.focused($keyFocus, equals: .voice)` + its comment | JoeSearch.swift:231–241 | The 🎤/"Nói" affordance in the query row. The query display and the "⟵ Quay lại" button beside it are untouched |
| 6 | `openVoiceSearch()` (+ doc comment) | JoeSearch.swift:406–413 | Under `// MARK: - Voice side door` (mark itself at :404, also removed) |
| 7 | `submitVoiceSearch()` (+ doc comment) | JoeSearch.swift:415–440 | The sheet's submit path into `query` |
| 8 | `JoeSearchKeyFocus.case voice` | JoeSearch.swift:748 | Focus id for the Nói button; enum doc comment (:741–742) updated to drop the `.voice` sentence |
| 9 | `private struct JoeVoiceSearchSheet` (+ its full doc comment, incl. the nested `Field` enum, its system `TextField`, Tìm/Huỷ buttons, `.defaultFocus`/`.task` focus-claim) | JoeSearch.swift:830–923 | The entire in-app voice sheet — the only system TextField / dictation surface on the search layer |

Two comment-only touch-ups, no code change:
- `fieldRow` doc comment (presnap :210–211): dropped "+ Nói (v2.0.25, the voice
  side door)" so the comment matches the row that remains.
- `JoeSearchKeyFocus` doc comment (presnap :741–742): dropped the sentence
  about `.voice`.

## What remains of search — typed search untouched

Verified by a full `diff -u` of presnap vs edited file: **every changed hunk is
one of the removals above.** No other line in the file differs. Specifically
intact, byte-for-byte:

- `JoeSearchView` body: query display row (now display + Quay lại only),
  `JoeLetterStrip` placement, status surfaces (Đang tìm… / failure / no-match),
  results heading, `resultsArea` (source-board rails + 6-column grid),
  `.onChange(of: query)` → `scheduleTypeAhead()`, `.onExitCommand`,
  `.defaultFocus($keyFocus, .key("a"))`.
- The search round: `scheduleTypeAhead()` (~300 ms debounce), `resetSearch()`,
  `runSearch()` (local-first, provider fan-out, soft/hard settles, snapshot
  rule), `hardSettle`, `logFirstPaint`, `storeMovies`, `mergePool`,
  `renderPool` — all unchanged.
- `JoeSearchSession` (local pool + snapshots) — unchanged.
- `JoeLetterStrip`, `JoeKeyCap` — unchanged.
- `JoeSearchKeyFocus` now has exactly two cases: `.key(String)`, `.back` —
  the two cases the letter strip, both search views' Quay lại buttons, and
  `.defaultFocus` actually use.

## Voice affordances in OTHER files — none found

Grepped the whole `JoeTV/` tree (all `*.swift`) for: `voice` (case-insensitive),
`JoeVoiceSearchSheet`, `voiceOpen`, `voiceDraft`, `openVoiceSearch`,
`submitVoiceSearch`, `.voice`, `mic.fill`, `Nói`, `Tìm bằng giọng nói`, `🎤`,
`Speech`, `dictat`, `Siri`. Before the edit, **every hit was inside
JoeSearch.swift**; after the edit there are **zero hits in the whole tree**.

- **`JoeTV/JoeTVB.swift` — checked explicitly, clean, NOT edited.** Its own
  in-tab search (`JoeTVBSearchView`, JoeTVB.swift:752+) has a query row with
  only the query display + "⟵ Quay lại" button (`.focused($keyFocus, equals:
  .back)`) and the shared `JoeLetterStrip`. It never had a Nói button, never
  presented `JoeVoiceSearchSheet`, and never used `.voice` — so removing the
  enum case cannot break it. It shares only `JoeSearchKeyFocus` and
  `JoeLetterStrip`, both preserved.
- `project.yml`: no `NSSpeechRecognitionUsageDescription` /
  `NSMicrophoneUsageDescription` keys exist — nothing to clean there (and it
  is outside this cluster's file ownership anyway).
- The `mic` substring hits elsewhere (e.g. "dynamic" in client files) are
  false positives, not affordances.

## Post-edit checks performed

- `grep` for every removed symbol across the whole `JoeTV/` tree: **NONE** —
  no dangling references.
- `grep` for `voice|Voice|Nói|mic.fill|JoeVoice|dictat|Siri|Speech` in the
  edited JoeSearch.swift: **NONE**.
- Brace/paren/bracket balance in the edited file: `{`112/112, `(`321/321,
  `[`46/46 — balanced.
- Presnap directory untouched (read-only use; md5 of presnap JoeSearch.swift
  unchanged: `3bb3c5d7e95a05da19f1a7b2ffb97834`).
- No other file was edited.

## Honesty section

- **Claims:** voice search is fully removed from JoeSearch.swift (button,
  sheet, wiring, state, helpers, focus id); typed Netflix-style search is
  behaviourally untouched; no voice affordance exists anywhere else in the
  tree.
- **Evidence:** full presnap↔edited `diff -u` (only the hunks listed above);
  tree-wide greps returning zero hits for all removed symbols and voice terms;
  delimiter-balance counts; presnap md5.
- **Unverified / limits:** there is **no local Swift compiler** on this
  machine (checked: no `swiftc`), so the file has NOT been compiled here —
  CI is the first compile, exactly as the task stated. The compile-safety
  argument is static only: removals were whole declarations/whole modifier
  chains, the diff shows no partial constructs left behind, delimiters
  balance, and no remaining code referenced any removed symbol (the sheet's
  submit was the only caller path into the removed helpers, and `.voice` had
  exactly one use — the removed button). `JoeTVBSearchView`'s continued
  compilation rests on the grep evidence that it uses only `.key`/`.back`.
- No Speech-framework replacement was added, per the owner's decision.
