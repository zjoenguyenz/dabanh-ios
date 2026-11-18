# V2029 — Cluster C: Continue Watching identity (progress must follow TITLE+EPISODE, not source)

Owner defect (item 6, 2.0.28 device test, tvOS 27.2.1; record `~/memory/2026-11-18.md` line 1073):
"Đang xem dở không lưu khi ĐỔI NGUỒN giữa các tập (mọi theme đều bị): tập 1 lấy nguồn KKPhim thì lưu; tập 2 KK không có nguồn nên nhảy sang Torrent → app không nhận ra là cùng một phim → không lưu đã coi tập 2." Owner's ruling: tiến độ phải khóa theo PHIM/TẬP, không theo nguồn.

Files owned this cluster: `JoeTV/WatchStore.swift` (edited), `JoeTV/JoeStores.swift` (read; contains PhimStore/TorHomeStore — no WatchStore usage, no change needed, untouched).

---

## 1. Keying map — how Continue Watching entries were keyed before the fix

### 1.1 The key formats (WatchStore.swift, header doc + key builders)

| Path | Key | Builder |
|---|---|---|
| KKPhim progress | `kk\|<slug>\|<episode name>` | `WatchStore.kkProgressKey` via `Providers.progressKey` (Providers.swift:60-67) |
| Film4K progress | `f4k\|<slug>\|<episode name>` | same dispatch |
| VSMOV progress | `vs\|<slug>\|<episode name>` | same dispatch |
| Tủ Phim progress | `tp\|<slug>\|<episode name>` | same dispatch |
| Torrent progress | `tor\|<stream id>` — movie: the meta id; series episode: `imdbId:season:episode` | `WatchStore.torProgressKey(streamId:)` |

The provider slug is provider-local (the same series has a different slug on KK vs F4K vs VS vs TP), the provider episode name is that provider's raw episode string, and the torrent stream id lives in the IMDb/Stremio namespace. **No field of any key is shared between the provider family and the torrent family.**

### 1.2 Save call sites (the only ones — grep of the whole `JoeTV/` tree)

- `JoePlayerView.swift:615` — `PlayDirector.tick()` → `store.saveProgress(e)` where `e = identity.entry`. This is the single save path for BOTH player engines (AVPlayer + KSPlayer funnel through the director; JoeKSPlayerView.swift has no save call site).
- The identity the director saves under is whatever `PlayIdentity` the session was built with (JoePlayerView.swift:88-91, `progressKey = entry.key`).

Session factories that build that identity:

- **Provider path** — `JoeMovieDetail.makeDirector` (JoeMovieDetail.swift:2465-2479): `entry.key = Providers.progressKey(provider, slug: m.slug, epName: epName)`, kind = provider kind, slug/source stamped. Resume read at line 2479: `watch.progressFor(key: entry.key)?.pos ?? 0` — exact-key only.
- **Torrent path** — `JoeTorrent.makePlayDirector` (JoeTorrent.swift:1289-1310; key built at :1298): `entry.key = WatchStore.torProgressKey(streamId: sid)` with `sid = video?.id ?? meta.id`, kind = `torrent`, metaId/metaType/streamId/metaBase stamped, **slug/source left empty**. Resume read at line 1310: exact-key only.
- **Sports/events path** — `JoeTVSection.playEvent` (JoeTVSection.swift:891-897): key `mf-event|<id>`, kind torrent (excluded from the fix's matching — see §2.4).

### 1.3 The two in-player identity breaks

1. **The detail's Torrent entry (the owner's exact route).** Every Phim detail renders a "Torrent" source chip (JoeMovieDetail.swift:1180-1259, `openTorrentDetail()`): it opens the torrent detail (`nav.tor = TorRoute(meta:…, base: Cinemeta)`) keyed by the resolved IMDb id. Playing episode 2 there runs a **torrent session** (§1.2) — its progress lands under `tor|<imdb>:1:2`, kind `torrent`.
2. **The failover hop.** When a provider ladder dies mid-session, `PlayDirector.failoverStep` (JoePlayerView.swift:460-463) replaces the session identity wholesale: `identity = winner.identity`, where the hop identity is a NEW provider entry keyed `Providers.progressKey(alt.code, slug: alt.slug, epName: newEp)` (JoeMovieDetail.swift:2582-2595). From that tick on, progress saves under the new provider's key/slug; the origin provider's entry is orphaned. (The torrent *substitution rung* is the one path that already kept identity — JoePlayerView.swift:187-196 documents it — but it only fires after ladder + hop both exhaust inside one session; it is not the route the owner took.)

### 1.4 Read-back paths (why the torrent episode is invisible)

- **Phim home CW rail** (JoePhimHome.swift:1326-1329) and **Browse wall CW rail** (JoeBrowse.swift:649-652): `filterKinds(watch.progress(), [kindKK, kindF4K, kindVS, kindTP])` — kind `torrent` is filtered OUT. A torrent-only episode never appears on the Phim rails at all.
- **Torrent home CW rail** (JoeTorrent.swift:201-203): kind `torrent` only — the KK episode never appears there. Two rails, two halves of one series.
- **Provider detail resume** (JoeMovieDetail.swift): `startEpisode` (1705-1707), `playButton`'s `isResume` (1713-1714) and `epChip`'s `storedEp` (1922-1923) all use the predicate `$0.slug == slug && $0.source == provider`. A torrent entry has `slug == ""` and `source == ""` → never matches → no "Xem tiếp", no episode preselect, and `makeDirector`'s exact-key resume (§1.2) reads 0.

**Proof of the defect, from code:** ep 1 via KK saves `kk|<kk-slug>|Tập 1` (kind kk). Ep 2, KK empty, played via the detail's Torrent entry saves `tor|tt…:1:2` (kind torrent, slug ""). The two keys share no component; every read-back above addresses exactly one family. The app therefore treats ep 2 as a different item — precisely the owner's diagnosis.

---

## 2. New identity design (all inside WatchStore.swift)

The per-source key stays as the entry's **reopen identity** (rails reopen via slug/source or metaId/streamId — unchanged). On top of it, the store now computes a **canonical identity** from fields every entry already carries, and uses it for save-merging, resume lookup, title lookup and completion removal:

**Canonical identity = same film + same episode number (+ season compatibility).**

- *Same film* (`sameFilm`, WatchStore.swift:193) mirrors the app's existing cross-provider film discipline (`Providers.sameFilm` / `Providers.filmKey`): a shared IMDb id (stamped `imdbId`, or the torrent `metaId` itself when it is a `tt…` id) or a shared TMDB id decides outright; otherwise `Providers.normalizeTitle` equality on the title, with years equal / either empty / ±1 (the same gated tolerance the failover hop uses).
- *Episode number* (`episodeNumber(of:)`, :143): provider side = `Providers.episodeNumber(ep)` — the same function the hop matches episodes with; torrent side = the episode component of the stream id `imdbId:season:episode` (the video label is deliberately NOT parsed: it embeds the episode's name, whose digits would corrupt the last-integer-run rule). Movies / "Full" = −1 on both sides.
- *Season* (`seasonNumber(of:)`, :159): stream-id middle component vs `Providers.seasonNumber(ep)`; a mismatch vetoes the match, an absent season (the KK norm) does not.

### 2.1 Save-side merge (`saveProgress`, :309)

A save now folds into every stored entry that is its same-key entry OR its canonical twin (`canonicalMatch`, :209), via `mergedEntry` (:232):

- Progress fields (pos/dur/ts) always come from the incoming save.
- **Surviving reopen identity:** if either side is a provider entry, the PROVIDER side's key/kind/slug/source/ep survive — those are what the Phim CW rails render and the provider details address. The other side donates every identity field the survivor lacks (metaId/metaType/streamId/metaBase/background/desc/imdbId/tmdbId/poster/year), so the merged row can still reopen through the torrent side too (the torrent CW rail builds its route from metaId/streamId/metaBase, which the merged provider row now carries).
- Provider↔provider (a hop) and torrent↔torrent: the incoming side's identity survives, exactly the pre-fix behaviour for those pairs.
- Cap (40), ts ordering, persist discipline: unchanged.

### 2.2 New store lookups (used by the coordinator edits in §4)

- `progressFor(matching:)` (:267) — exact key first (unchanged semantics), then the canonical twin. For the two session factories' resume reads.
- `progressForTitle(slug:provider:title:year:)` (:282) — the historic slug+source predicate first (byte-identical semantics: latest entry for the title on that provider, any episode), then a canonical film match (latest entry for the same film from ANY family, any episode — the same shape the historic predicate returns). For the detail pages' "Xem tiếp" / preselect reads.
- `removeProgress(matching:)` (:349) — removes the exact-key entry AND any canonical twin, so the finish rule (last-30 s / item ended / skip-to-next) clears the merged row whichever key it survives under. The per-card long-press removal keeps using `removeProgress(key:)` with the row's own key — unchanged.

### 2.3 Entry fields added

`Entry.imdbId` / `Entry.tmdbId` (WatchStore.swift:84-85), additive with tolerant decode (:556, :581-582 — `decodeIfPresent` + default ""), synthesized encoding picks them up automatically. No call site stamps them yet (see optional edits §4.3); the torrent side needs no stamp because its `metaId` already IS the IMDb id.

### 2.4 Exclusions

Sports/live rows (`key` prefix `mf-event|`, or `metaType` `events`/`tv`) and title-less entries are never canonical-matched (`canonicalEligible`, :181) — an event can never merge into a film's row. Favorites are untouched: keys, toggle, rails and the player's favourite-key derivation all behave exactly as before.

---

## 3. Migration story for existing entries

**No file migration, no format change.** `watch-state.json` decodes exactly as before (the two new fields default to "" on old files; every old field is read by the same tolerant reader).

The owner's CURRENT Continue Watching list is repaired in place by `coalesceProgress()` (:472), run once at the end of every successful `reload()`: progress entries are folded newest-first; any canonical twin pair already on disk (e.g. the KK row and the torrent row for the same series episode) collapses into one merged row under the provider identity, newest progress winning, identity fields unioned. It persists only when a pair actually collapsed and is idempotent. The next cross-source save of any episode also merges on contact (§2.1), so even a pair the coalesce somehow left behind heals at the next play.

What is NOT migrated: favorites (out of scope by design — they were never split by this defect's mechanism in a way the owner reported, and their keys are untouched), and entries whose titles differ across catalogues with no shared id (see §5 limitations).

---

## 4. Changes

### 4.1 Made by this cluster — `JoeTV/WatchStore.swift` only

| Line(s) | Change |
|---|---|
| 25-41 | Header doc: canonical-identity paragraph added (keys doc otherwise unchanged). |
| 84-85 (+ comment) | `Entry.imdbId`, `Entry.tmdbId` added. |
| 133-296 | New MARK section: `episodeNumber(of:)`, `seasonNumber(of:)`, `imdbId(of:)`, `canonicalEligible`, `sameFilm`, `canonicalMatch`, `mergedEntry`, `progressFor(matching:)`, `progressForTitle(slug:provider:title:year:)`. |
| 309-336 | `saveProgress` folds canonical twins before inserting (cap/sort/persist unchanged). |
| 349-358 | `removeProgress(matching:)` added (`removeProgress(key:)` untouched). |
| 461, 472-486 | `reload()` calls `coalesceProgress()`; coalesce implementation. |
| 556, 581-582 | Tolerant decode for `imdbId` / `tmdbId`. |

`JoeTV/JoeStores.swift`: no change (verified: no WatchStore reference in the file).

### 4.2 REQUIRED coordinator edits in other clusters' files

Line numbers are from the working tree as read this session; anchor on the quoted code if lines drift. All are one-for-one replacements; each compiles against the new WatchStore API above.

**E1 — JoeMovieDetail.swift:2479** (makeDirector resume read)
```swift
// old
        let resume = watch.progressFor(key: entry.key)?.pos ?? 0
// new
        let resume = watch.progressFor(matching: entry)?.pos ?? 0
```

**E2 — JoeTorrent.swift:1310** (makePlayDirector resume read)
```swift
// old
        let resume = watch.progressFor(key: entry.key)?.pos ?? 0
// new
        let resume = watch.progressFor(matching: entry)?.pos ?? 0
```

**E3 — JoeMovieDetail.swift:1705-1707** (startEpisode)
```swift
// old
        if let e = watch.progress().first(where: {
            $0.slug == slug && $0.source == provider }), exists(e.ep) {
// new
        if let e = watch.progressForTitle(slug: slug, provider: provider,
                                          title: d.movie.name,
                                          year: d.movie.year), exists(e.ep) {
```

**E4 — JoeMovieDetail.swift:1713-1714** (playButton isResume)
```swift
// old
        let isResume = !route.preselectEp.isEmpty
            || watch.progress().contains { $0.slug == slug && $0.source == provider }
// new
        let isResume = !route.preselectEp.isEmpty
            || watch.progressForTitle(slug: slug, provider: provider,
                                      title: d.movie.name,
                                      year: d.movie.year) != nil
```

**E5 — JoeMovieDetail.swift:1922-1923** (epChip storedEp)
```swift
// old
        let storedEp = watch.progress().first(where: {
            $0.slug == slug && $0.source == provider })?.ep
// new
        let storedEp = watch.progressForTitle(slug: slug, provider: provider,
                                              title: d.movie.name,
                                              year: d.movie.year)?.ep
```

**E6 — JoePlayerView.swift:608** (tick, last-30 s finish branch)
```swift
// old
            store.removeProgress(key: identity.progressKey)
// new
            store.removeProgress(matching: identity.entry)
```

**E7 — JoePlayerView.swift:627** (itemEnded)
```swift
// old
        store.removeProgress(key: identity.progressKey)
// new
        store.removeProgress(matching: identity.entry)
```

**E8 — JoePlayerView.swift:783** (skipToNextEpisode)
```swift
// old
        store.removeProgress(key: identity.progressKey)
// new
        store.removeProgress(matching: identity.entry)
```

Why E6-E8 are needed: without them, finishing an episode in a torrent session whose row survives under the provider key (post-merge) would call `removeProgress(key: "tor|…")`, miss the merged row, and leave a finished episode sitting in Continue Watching. With them, removal is by the same canonical identity as saving.

Without E1-E5, the store-side merge (§2.1) and load coalesce (§3) still fix the duplicate-row half of the defect and every case where a provider entry for the episode exists — but a torrent-ONLY episode would still not resume from the provider detail. E1-E5 are what close the owner's exact sequence end-to-end.

### 4.3 OPTIONAL strengthening edits (not required for the owner's reproduced path)

Stamp the stable ids on provider entries so a later Torrent-TAB play of the same series (Cinemeta's English title, which the title match cannot bridge to the Vietnamese provider title) still matches by IMDb id:

**O1 — JoeMovieDetail.swift, in makeDirector, after `entry.source = provider` (~line 2478):**
```swift
        entry.imdbId = m.imdbId
        entry.tmdbId = m.tmdbId
```
(`m` is `detail.movie`, already bound at the factory head. `Movie.imdbId` is populated on Tủ Phim details today and empty on many KK payloads — the stamp is a no-op where the payload lacks the id, and `Providers.resolveIdentity` remains the deep fallback the substitution rung already uses.)

**O2 — JoeMovieDetail.swift, in the hopIdentity closure, after `e2.source = alt.code` (~line 2595):**
```swift
                    e2.imdbId = d.movie.imdbId
                    e2.tmdbId = d.movie.tmdbId
```

---

## 5. Behaviour preserved / limitations

Preserved:
- Movies keep working: a movie is episode −1 on both families, so KK-movie ↔ torrent-movie saves merge the same way; single-family movie behaviour is byte-identical (no twin → old code path).
- Removal/completion rules unchanged: last-30 s drop, itemEnded drop, skip-to-next drop, per-card long-press delete, Settings clear-all — same callers, same thresholds; only the three director removals widen to the canonical twin (E6-E8).
- Favorites, TopShelf (kind-based, JoeTopShelfWriter.swift:205), rail caps, the 40-entry cap: untouched.
- The ADDENDUM RULE (no stored stream URLs) is untouched; merged rows store identity fields only.

Limitations (honest):
- Title bridging depends on the two families carrying the same title text. The owner's route guarantees it: the detail's Torrent entry builds its meta from the provider detail itself (`meta.name = d.movie.name`, `meta.year = d.movie.year`, JoeMovieDetail.swift:1252-1257). A series found cold in the Torrent tab carries Cinemeta's (usually English) title vs the provider's Vietnamese title — those two rows merge only if the provider entry carries a stamped IMDb/TMDB id (optional edits §4.3, and KK payloads often lack the id) or the titles happen to match after normalization.
- Season is only a veto, never part of the key (provider episode names are season-free, so the provider side cannot state one). Two seasons of one series whose provider episode names are both bare "Tập N" and whose titles/years are identical would canonical-match across seasons if one season was played per family — the same ambiguity the existing hop matching (`Providers.episodeNumber` only) already accepts.
- A provider movie whose single episode name parses to a number (e.g. "1") will not merge with its torrent twin (torrent movie = −1). No regression — they simply stay two rows, as today.

---

## 6. Honesty section

**Claims**
1. Pre-fix, provider and torrent progress keys share no component, and every read-back addresses one family only — so a cross-source episode change necessarily splits Continue Watching. (§1)
2. The fix derives identity from title + episode number in the store, merges saves and stored twins, and keeps the provider reopen identity on merged rows. (§2, §3)
3. With coordinator edits E1-E8 applied, resume/removal work across the KK→Torrent episode change in both directions. Without them, the fix is partial in the ways §4.2 names.

**Evidence**
- All file:line citations above were read directly from the working tree this session (WatchStore.swift in full; JoeMovieDetail.swift §§ play/makeDirector/hop/torrent-chip; JoePlayerView.swift §§ identity/failover/tick/itemEnded/skip; JoeTorrent.swift makePlayDirector + rails; JoePhimHome/JoeBrowse/JoeTVSection/JoeTopShelfWriter grep + targeted reads).
- Save-API census: `grep -rn "saveProgress|progressFor|ProgressKey|removeProgress" JoeTV/` — one save call site (JoePlayerView.swift:615), two factory resume reads, three director removals, three detail predicates, three rail long-press removals. No other callers exist.
- Post-edit structural check on WatchStore.swift: braces/parens balanced (0/0), all new symbols present, decode section verified on disk (584 lines).

**Unverified**
- NO local compiler exists in this environment (per task rules): the Swift was written and re-read carefully but CI is the first compile. Risk points a compiler would catch instantly: none known — the new code uses only Foundation + existing app symbols (`Providers.normalizeTitle/yearOf/episodeNumber/seasonNumber`, all verified present with matching signatures).
- Not device-tested (no device in this cluster's scope): the merge/coalesce logic is argued from code, not observed on the Apple TV.
- Whether the owner's ep-2 play went through the detail's Torrent chip (§1.3.1) vs the Torrent tab is inferred from his words ("nó nhảy qua nguồn của phim Torrent") plus the chip being the only in-detail torrent route; the fix covers both routes except the cold-Torrent-tab title-mismatch case named in §5.
- Line numbers in §4.2 are as-read this session; other clusters are editing JoePlayerView.swift / JoeMovieDetail.swift / JoeTorrent.swift concurrently, so the coordinator should anchor on the quoted code, not the numbers alone.
