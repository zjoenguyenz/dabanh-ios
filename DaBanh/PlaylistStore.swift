import Combine
import Foundation

/// Playlist loading, mirroring the Android app's behaviour:
/// - On launch: show the disk cache immediately (if present and > 100
///   bytes), then fetch the remote playlist.
/// - A successful fetch replaces the list AND rewrites the cache.
/// - A failed fetch keeps the current list; with nothing loaded yet it
///   surfaces a retry message instead.
/// - Auto-refresh: every 15 minutes — a foreground timer plus a
///   refresh-on-foreground when the data is older than 15 minutes
///   (the Android app does the staleness check in onResume).
/// - First load only: open on the Hot tab when it has a live match,
///   else the highest-priority league with a live match right now;
///   fall back to Ngoại Hạng Anh (Android setData).
///
/// Two sources are fetched on every refresh, GitHub first (owner's
/// rule, 2026-11-13 — all of his apps read from his own GitHub):
/// - Primary: the mirror in the owner's GitHub repo, whose workflow
///   auto-scans and republishes the whole list (origin leagues +
///   scraped extras + the 🔥 Hot group) every 30 minutes and keeps
///   the last good file if the origin dies.
/// - Fallback: the origin site (thtt.pages.dev), used only when
///   GitHub cannot be reached at all. It has no 🔥 Hot group, so the
///   Hot tab then keeps whatever it already had.
// MARK: - Diagnostic log

/// The diagnostic log (LOG RETRIEVAL LAW, owner 2026-11-18).
/// Đá Banh iOS had NO log at all until 1.24 — no logger, no
/// file, no export — the same gap the owner found on the tvOS
/// app; this is the iOS side's build-out. Design rules
/// (IOS-STUDY-NOTE-124 §3): write-only — a serial file queue
/// with no published state, so logging can never invalidate a
/// view or perturb the render path it observes; capped at
/// ~512 KB with a tail-keeping rotation; secrets redacted —
/// call sites log titles, hosts and counts, never full stream
/// URLs (signed URLs carry credentials in their query), and
/// `redacted(_:)` strips query + fragment from any URL that
/// does get logged.
enum DiagLog {

    private static let queue = DispatchQueue(label: "dabanh.diaglog")
    private static let maxBytes = 512 * 1024

    static var fileURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dabanh-diag.log")
    }

    /// A fresh formatter per call: ISO8601DateFormatter is not
    /// concurrency-safe to share, and log volume is low.
    /// FIX-148: fractional seconds — DIAG-147's enter event
    /// lasts ≈0.50 s with ≈0.23 s legs, so second-granularity
    /// stamps made inter-line timing underivable; every line
    /// now carries milliseconds (same ISO8601 shape, extended).
    private static func timestamp() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }

    static func log(_ category: String, _ message: String) {
        let line = "\(timestamp()) [\(category)] \(message)\n"
        queue.async { append(line) }
    }

    /// The launch header every sent log is read against:
    /// app version + build + OS version.
    static func boot() {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        log("app", "launch Da Banh iOS \(version) (\(build)) "
            + "on iOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
        startWatchdog()
    }

    // MARK: Main-actor stall watchdog (Đ-3, 1.26)

    /// Lock-guarded watchdog state shared between the main-actor
    /// heartbeat and the background checker. `@unchecked Sendable`
    /// is honest here: every access is serialized by the lock.
    private final class WatchdogState: @unchecked Sendable {
        let lock = NSLock()
        var started = false
        var lastBeat = Date()
        /// The last on-time beat of the stall currently open, if any.
        var stallSince: Date?
    }

    private static let watchdog = WatchdogState()

    /// Watches for main-actor stalls (Đ-3): the 53-second black
    /// window of 2026-11-20 left no trace in this log because
    /// nothing recorded whether the main actor was alive through
    /// it. A main-actor heartbeat stamps the time every 2 s; a
    /// detached checker compares it against the wall clock once
    /// a second. A heartbeat more than 3 s late opens a stall —
    /// one log line per stall — and the first on-time beat after
    /// it closes the stall with its total duration. Started from
    /// boot() so both apps get it from the one existing launch
    /// hook; idempotent, fire-and-forget, never blocks launch.
    private static func startWatchdog() {
        let shouldStart: Bool = watchdog.lock.withLock {
            guard !watchdog.started else { return false }
            watchdog.started = true
            watchdog.lastBeat = Date()
            return true
        }
        guard shouldStart else { return }

        Task { @MainActor in
            while !Task.isCancelled {
                watchdog.lock.withLock {
                    watchdog.lastBeat = Date()
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }

        Task.detached {
            var lastCheck = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                let now = Date()
                // If the checker itself slept far past its 1 s
                // cadence, the whole process was suspended
                // (backgrounded): re-baseline instead of logging
                // the suspension gap as a stall.
                if now.timeIntervalSince(lastCheck) > 5 {
                    watchdog.lock.withLock {
                        watchdog.lastBeat = now
                        watchdog.stallSince = nil
                    }
                    lastCheck = now
                    continue
                }
                lastCheck = now
                let (beat, stallSince) = watchdog.lock.withLock {
                    (watchdog.lastBeat, watchdog.stallSince)
                }
                let late = now.timeIntervalSince(beat)
                if let since = stallSince {
                    if late <= 3 {
                        watchdog.lock.withLock {
                            watchdog.stallSince = nil
                        }
                        log("app", "main stall recovered: "
                            + String(format: "%.1f", now.timeIntervalSince(since))
                            + "s total")
                    }
                } else if late > 3 {
                    watchdog.lock.withLock {
                        watchdog.stallSince = beat
                    }
                    log("app", "main stall: heartbeat late by "
                        + String(format: "%.1f", late) + "s")
                }
            }
        }
    }

    /// The in-app preview's log text (the share sheet sends
    /// the file itself, so EXPORT always carries the full
    /// text — only this preview is tailed; the two paths
    /// share nothing but the file). FIX-144 (DB-33 /
    /// FL-490): the viewer renders this string in ONE
    /// SwiftUI Text, and the whole file (345 KB at the
    /// owner's size — some 2,951 lines, ≈38,000 pt of view
    /// height) exceeds a single view's backing-store limit
    /// by ~7–14×, so the Text rasterised to nothing and
    /// the sheet showed an empty body while the exported
    /// file was complete (DIAG-144 Leg B). The preview now
    /// returns only the last ~32 KB, cut at a line
    /// boundary (the rotateIfNeeded pattern) — the "tail"
    /// the viewer's own doc comment always promised
    /// (ContentView.swift, DiagLogView). A file at or
    /// under the cap returns whole, exactly as before.
    static func snapshot() -> String {
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL) else { return "" }
            let tail = data.suffix(32 * 1024)
            var start = tail.startIndex
            if tail.count < data.count,
               let newline = tail.firstIndex(of: UInt8(ascii: "\n")),
               newline < tail.endIndex - 1 {
                start = tail.index(after: newline)
            }
            return String(decoding: tail[start...], as: UTF8.self)
        }
    }

    static func clear() {
        queue.async {
            try? FileManager.default.removeItem(at: fileURL)
            append("\(timestamp()) [app] log cleared\n")
        }
    }

    /// A URL with query + fragment stripped — safe to log.
    static func redacted(_ url: URL) -> String {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url.absoluteString }
        comps.query = nil
        comps.fragment = nil
        return comps.string ?? url.absoluteString
    }

    private static func append(_ line: String) {
        let data = Data(line.utf8)
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            if (try? handle.seekToEnd()) != nil {
                try? handle.write(contentsOf: data)
            }
        } else {
            try? data.write(to: fileURL, options: .atomic)
        }
        rotateIfNeeded()
    }

    /// Keep the newest half once the cap is passed, starting
    /// the kept tail at a line boundary.
    private static func rotateIfNeeded() {
        guard let size = (try? FileManager.default
                .attributesOfItem(atPath: fileURL.path)[.size]) as? Int,
              size > maxBytes,
              let data = try? Data(contentsOf: fileURL) else { return }
        let tail = data.suffix(maxBytes / 2)
        var start = tail.startIndex
        if let newline = tail.firstIndex(of: UInt8(ascii: "\n")),
           newline < tail.endIndex - 1 {
            start = tail.index(after: newline)
        }
        try? Data(tail[start...]).write(to: fileURL, options: .atomic)
    }
}

@MainActor
final class PlaylistStore: ObservableObject {

    /// Origin site — since 2026-11-13 only the fallback, used when
    /// the GitHub mirror cannot be reached at all.
    static let playlistURL = URL(string: "https://thtt.pages.dev/tttt.m3u")!
    /// The PRIMARY source (owner's own GitHub repo): a scheduled
    /// workflow auto-scans and republishes the full playlist there
    /// every 30 minutes, and a failed scan never overwrites the last
    /// good file — so this link is both fresher and harder to kill
    /// than the origin.
    static let backupPlaylistURL = URL(string: "https://raw.githubusercontent.com/zjoenguyenz/dabanh-playlist/main/tttt.m3u")!
    /// group-title the mirror's scraper gives its hot rail.
    static let hotGroupName = "🔥 Hot"
    /// selectedLeague value meaning "the Hot tab" (league rawValues
    /// are 1, 2, 3, 4 and 9, so 0 is free).
    static let hotTabValue = 0
    /// selectedLeague value meaning "the Trực tiếp (live) tab" — every
    /// match in its live window right now, across all leagues and the
    /// Hot group. Added at the owner's request (2026-11-13): browsing
    /// league by league gave him no way to see at a glance what is
    /// live. The iOS UI does not render this tab yet; the tvOS UI does.
    static let liveTabValue = -1
    private static let autoRefreshInterval: TimeInterval = 15 * 60
    /// A mirror whose Updated stamp is older than this is treated as
    /// stale even when reachable (its workflow republishes every
    /// 30 minutes when healthy).
    private static let mirrorStaleThreshold: TimeInterval = 45 * 60

    @Published private(set) var channels: [Channel] = []
    @Published private(set) var hotChannels: [Channel] = []

    /// The live-state layer (1.21, spec §1): ESPN > FotMob >
    /// Flashscore > LiveScore matched states behind the boards.
    /// Owned here so its lifecycle follows the playlist's; its
    /// changes are forwarded into this store's objectWillChange,
    /// so every view observing the playlist re-renders when a
    /// state lands (the poll is 60 s while anything is live).
    let liveStates = MatchStateStore()
    private var stateForwarding: AnyCancellable?

    // MARK: FIX-141 entries memo

    /// Content fingerprint of one input channel for the
    /// `entries(for:)` memo key. Every stored field except `id`
    /// is hashed: FixtureGrouping reads title / url / kickoff
    /// (pair identity, legacy identity, live merge), the group
    /// representative that FixtureEntry carries renders from
    /// logo / group / leagueRank, and the state binding +
    /// competition attach read title / kickoff / leagueRank.
    /// `id` is excluded deliberately — it is a fresh UUID per
    /// parse, so an identity- or equality-based key (Channel's
    /// Equatable includes `id`) would miss on every playlist
    /// refresh even when nothing the computation reads changed.
    private struct EntriesChannelFingerprint: Hashable {
        let title: String
        let logo: String
        let group: String
        let url: String
        let kickoff: Date?
        let leagueRank: Int
        let referrer: String
        let userAgent: String

        init(_ channel: Channel) {
            title = channel.title
            logo = channel.logo
            group = channel.group
            url = channel.url
            kickoff = channel.kickoff
            leagueRank = channel.leagueRank
            referrer = channel.referrer
            userAgent = channel.userAgent
        }
    }

    /// Everything `entries(for:)` depends on, in one key: the
    /// input channels' contents (in order — grouping preserves
    /// first-occurrence order, so order is part of the input)
    /// and `liveStates.revision`, the store's version counter
    /// for state content. Every mutation of the store's states
    /// is paired with a revision bump (the guarded refresh
    /// publish, the empty-snapshot clear, the detail upgrades —
    /// after FIX-141 exactly one bump per cycle / per on-demand
    /// call), so a changed state can never hide behind an equal
    /// key. Wall-clock dependence is NOT in the key; it is the
    /// entry's `validUntil` below.
    private struct EntriesMemoKey: Hashable {
        let revision: Int
        let channels: [EntriesChannelFingerprint]
    }

    private struct EntriesMemoEntry {
        let key: EntriesMemoKey
        let entries: [FixtureEntry]
        /// The first instant at which the stored result may stop
        /// being what a fresh computation would return (see
        /// `nextEntriesFlip(after:channels:)`). A hit requires
        /// now < validUntil.
        let validUntil: Date
    }

    /// FIFO memo for `entries(for:)`, oldest first, capped at 8
    /// (the live call shapes are few: the full list, the Hot
    /// list, per-league lists, the live list).
    private var entriesMemo: [EntriesMemoEntry] = []
    private static let entriesMemoCap = 8

    /// The earliest future instant at which the wall clock can
    /// change an `entries(for:)` result for these channels.
    ///
    /// The computation's ONLY clock dependence is
    /// FixtureGrouping.group's live merge, gated by
    /// `isLive(kickoff:now:)` — the window kickoff −10 min …
    /// +125 min, the same constants as LeagueClassifier's
    /// bucket 0 (`bucket(of:now:)`: sinceKick >= -10*60 &&
    /// sinceKick <= 125*60). A fixture's bucket / live-merge
    /// membership can therefore flip only at kickoff−600 s
    /// (enters the window) or kickoff+7500 s (leaves it). The
    /// live merge reads the EARLIEST stamp of each same-pair
    /// cluster, and that earliest stamp is itself one of the
    /// input kickoffs — so the minimum flip instant over ALL
    /// input kickoffs is at or before every flip that could
    /// change the grouping: expiring there is exact in the safe
    /// direction (a memo may die early on a bystander channel's
    /// flip; it can never be served after a real flip).
    /// The leaving edge uses >= so a memo computed exactly at
    /// kickoff+7500 s still expires at that instant; a hit
    /// requires now < validUntil, so at the edge itself the
    /// caller recomputes (and gets the same, still-live result).
    /// Channels with no kickoff never flip. No future flip at
    /// all → .distantFuture (the key's revision / contents are
    /// then the only things that can change the result).
    private static func nextEntriesFlip(after now: Date,
                                        channels: [Channel]) -> Date {
        var earliest = Date.distantFuture
        for channel in channels {
            guard let kickoff = channel.kickoff else { continue }
            let enters = kickoff.addingTimeInterval(-10 * 60)
            if enters > now, enters < earliest { earliest = enters }
            let leaves = kickoff.addingTimeInterval(125 * 60)
            if leaves >= now, leaves < earliest { earliest = leaves }
        }
        return earliest
    }

    init() {
        stateForwarding = liveStates.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    /// Unfiltered lists as parsed. The published lists above are these
    /// minus proven-dead links and minus .flv entries (AVPlayer cannot
    /// play FLV at all, so on Apple platforms they are dead weight;
    /// the Android app keeps them — ExoPlayer plays FLV fine).
    private var rawChannels: [Channel] = []
    private var rawHotChannels: [Channel] = []
    /// URLs proven unplayable FROM THIS DEVICE (see validateLinks).
    /// Persisted so a cold start opens already clean, and re-probed
    /// after every refresh so a revived link returns on its own.
    private var invalidURLs: Set<String> = []
    /// The mirror's EN block from the most recent successful mirror
    /// fetch (seeded from the mirror disk cache at launch). Kept
    /// separately so the EN merge below survives a mirror outage.
    private var lastMirrorEN: [Channel] = []
    private var validating = false
    /// Bumped when the crest map is swapped for a fresher remote copy,
    /// so crest-reading views re-render with the new badges.
    @Published private(set) var crestsRevision = 0
    @Published private(set) var isLoading = false
    /// True while a link-validation pass runs (automatic or manual);
    /// the "Kiểm tra link" button spins on it.
    @Published private(set) var isValidating = false
    @Published var statusMessage: String?
    @Published var selectedLeague: Int = League.england.rawValue

    private(set) var lastFetch: Date?
    private var loadedOnce = false
    private var didPickInitialTab = false
    private var fetching = false
    private var autoRefreshTask: Task<Void, Never>?

    private var cacheFileURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("playlist.m3u")
    }

    private var mirrorCacheFileURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("mirror.m3u")
    }

    private var invalidFileURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("invalid-urls.json")
    }

    private func loadInvalidSet() {
        guard let data = try? Data(contentsOf: invalidFileURL),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return }
        invalidURLs = Set(list)
    }

    private func saveInvalidSet() {
        let list = Array(invalidURLs)
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: invalidFileURL, options: .atomic)
        }
    }

    // FIX-141: per-URL probe stamps for the incremental
    // whole-list validation (see validateLinks): when each
    // URL was last probed, persisted across launches so a
    // validation pass only re-probes what is DUE. Same
    // Caches + atomic-write pattern as invalid-urls.json;
    // any decode failure (missing, corrupt, version ≠ 1)
    // yields an empty map — every URL simply reads as due.
    private var linkProbeStamps: [String: Date] = [:]
    private var linkProbeStampsLoaded = false

    /// A probe verdict is trusted for 30 min — the mirror's
    /// republication cadence: inside one playlist generation
    /// a URL's answer from this device is still the answer;
    /// past it, the ladder may have rotated and the URL is
    /// due again.
    private static let linkProbeTTL: TimeInterval = 30 * 60

    private var linkProbeStampsFileURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("link-probe-stamps.json")
    }

    private struct LinkProbeStampsPayload: Codable {
        var version: Int
        var stamps: [String: TimeInterval]
    }

    private func loadLinkProbeStampsIfNeeded() {
        guard !linkProbeStampsLoaded else { return }
        linkProbeStampsLoaded = true
        guard let data = try? Data(contentsOf: linkProbeStampsFileURL),
              let payload = try? JSONDecoder().decode(
                LinkProbeStampsPayload.self, from: data),
              payload.version == 1 else { return }
        linkProbeStamps = payload.stamps.mapValues {
            Date(timeIntervalSince1970: $0)
        }
    }

    private func saveLinkProbeStamps() {
        let payload = LinkProbeStampsPayload(
            version: 1,
            stamps: linkProbeStamps.mapValues { $0.timeIntervalSince1970 })
        if let data = try? JSONEncoder().encode(payload) {
            try? data.write(to: linkProbeStampsFileURL, options: .atomic)
        }
    }

    var isStale: Bool {
        guard let lastFetch else { return true }
        return Date().timeIntervalSince(lastFetch) > Self.autoRefreshInterval
    }

    func channels(in league: League) -> [Channel] {
        channels.filter { $0.leagueRank == league.rawValue }
    }

    /// Every channel whose match is in its live window right now
    /// (classifier bucket 0), merged from the league lists and the Hot
    /// group, deduplicated by URL, in the standard live-first order.
    /// English-commentary channels are confined to the BLV Anh tab and
    /// are excluded here even if a playlist entry ever carries a
    /// kickoff stamp (owner's order, 2026-11-19).
    var liveChannels: [Channel] {
        let now = Date()
        var seen = Set<String>()
        var live: [Channel] = []
        for channel in channels + hotChannels {
            guard effectiveBucket(of: channel, now: now) == 0,
                  !LeagueClassifier.isEN(channel) else { continue }
            if seen.insert(channel.url).inserted {
                live.append(channel)
            }
        }
        return LeagueClassifier.sorted(live)
    }

    // MARK: - Live states + board model (1.21)

    /// The matched state bound to a channel's fixture, if any.
    func state(for channel: Channel) -> MatchState? {
        liveStates.state(for: channel)
    }

    /// The bucket a channel effectively sits in: the matched
    /// state wins over the wall-clock window (spec §1.4 — an FT
    /// fixture leaves the live lists at the next poll).
    func effectiveBucket(of channel: Channel, now: Date = Date()) -> Int {
        LeagueClassifier.bucket(of: channel, now: now, state: liveStates.state(for: channel))
    }

    /// Fixture entries with their matched state and competition
    /// attached — the board model every 1.21 list renders from.
    ///
    /// FIX-141: memoised. The baseline recomputed this from
    /// scratch on every view render — ≥3–4 full passes per
    /// publish, each with a per-entry state lookup
    /// (DIAG-140-SMOOTH §3.2). A memo hit returns the previously
    /// computed array itself; a miss runs the exact baseline
    /// computation and stores its result under a content key
    /// (channels' contents + states revision — see
    /// EntriesMemoKey) with a wall-clock validity bound (see
    /// `nextEntriesFlip`). Key construction is one O(n) hash
    /// pass over the input, against the baseline's full
    /// grouping + per-entry lookups.
    func entries(for channels: [Channel]) -> [FixtureEntry] {
        let now = Date()
        let key = EntriesMemoKey(
            revision: liveStates.revision,
            channels: channels.map(EntriesChannelFingerprint.init))
        if let hit = entriesMemo.first(where: {
            $0.key == key && now < $0.validUntil
        }) {
            return hit.entries
        }
        let computed = FixtureEntry.group(channels).map { entry in
            var entry = entry
            entry.state = liveStates.state(for: entry.channel)
            entry.competition = LeagueClassifier.competition(
                for: entry.channel, state: entry.state)
            return entry
        }
        entriesMemo.removeAll { $0.key == key }
        entriesMemo.append(EntriesMemoEntry(
            key: key,
            entries: computed,
            validUntil: Self.nextEntriesFlip(after: now, channels: channels)))
        while entriesMemo.count > Self.entriesMemoCap {
            entriesMemo.removeFirst()
        }
        return computed
    }

    /// Every fixture entry of the main list (Hot listings ride the
    /// same parse), for the cups tab: the entries whose
    /// competition is a European cup (S1/S2-identified only).
    var cupEntries: [FixtureEntry] {
        entries(for: channels).filter { $0.competition?.isCup == true }
    }

    /// The player's ladder rotated to a board-chosen row (spec
    /// §2.3a): the chosen source first, the rest of the fixture's
    /// ladder behind it in its usual order.
    func rotatedSources(for entry: FixtureEntry, chosen: Channel) -> [Channel] {
        let ladder = sources(for: entry.channel)
        return [chosen] + ladder.filter { $0.url != chosen.url }
    }

    // MARK: - Lifecycle

    /// Called once from the root view's .task: cache first, remote second,
    /// then the 15-minute auto-refresh loop for as long as the app lives.
    func start() async {
        DiagLog.boot()
        loadCache()
        liveStates.start()
        await refresh()
        // Crest coverage updates ride the same GitHub mirror as the
        // playlist: fetch once per launch, swap in if fresher.
        Task {
            if await Crests.refreshRemote() { crestsRevision += 1 }
        }
        guard autoRefreshTask == nil else { return }
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.autoRefreshInterval))
                guard let self else { return }
                if self.isStale { await self.refresh() }
            }
        }
    }

    /// Android onResume rule: coming back to the app with a list older
    /// than 15 minutes triggers a refresh.
    func refreshIfStale() async {
        if loadedOnce && isStale { await refresh() }
    }

    // MARK: - Loading

    private func loadCache() {
        loadInvalidSet()
        // GitHub-first, same order as the live fetch: the mirror cache
        // is the main list (leagues + Hot + extras in one file).
        if let text = readCache(mirrorCacheFileURL) {
            let parsed = M3UParser.parse(text)
            if !parsed.isEmpty {
                noteMirrorEN(parsed)
                setData(parsed)
                setHot(parsed)
                return
            }
        }
        if let text = readCache(cacheFileURL) {
            let parsed = M3UParser.parse(text)
            if !parsed.isEmpty { setData(parsed) }
        }
    }

    private func readCache(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url), data.count > 100 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func refresh() async {
        if fetching { return } // one fetch at a time, like Android
        fetching = true
        isLoading = true
        defer {
            fetching = false
            isLoading = false
        }
        do {
            // GitHub mirror first (the primary since 2026-11-13): one
            // file carries the leagues, the extras and the Hot group.
            let (data, parsed, text) = try await fetchPlaylist(from: Self.backupPlaylistURL)
            noteMirrorEN(parsed)
            // Freshness gate (root cause measured 2026-11-13): a
            // REACHABLE mirror can still be hours stale — its stamp
            // read 03:08 VN while the origin already carried 06:37 —
            // and stale means screens full of long-expired signed
            // links. When the stamp is older than the threshold,
            // prefer a fresher origin for the main list; Hot still
            // comes from the mirror (the origin has no Hot group).
            if let stamp = UpdatedStamp.parse(text),
               Date().timeIntervalSince(stamp) > Self.mirrorStaleThreshold,
               let (odata, oparsed, _) = try? await fetchPlaylist(from: Self.playlistURL) {
                try? odata.write(to: cacheFileURL, options: .atomic)
                setData(mergingEN(oparsed))
                setHot(parsed)
                statusMessage = "Gương đang chậm — đã dùng nguồn gốc mới hơn."
                DiagLog.log("playlist",
                            "mirror stale — origin list preferred, mirror Hot kept")
            } else {
                try? data.write(to: mirrorCacheFileURL, options: .atomic)
                setData(parsed)
                setHot(parsed)
            }
        } catch {
            // GitHub unreachable: fall back to the origin site before
            // giving up, and say so on screen when it saves us. The
            // origin has no Hot group, so the Hot tab keeps its list.
            do {
                let (data, parsed, _) = try await fetchPlaylist(from: Self.playlistURL)
                try? data.write(to: cacheFileURL, options: .atomic)
                setData(mergingEN(parsed))
                statusMessage = "Đang dùng nguồn dự phòng."
                DiagLog.log("playlist", "mirror unreachable — origin fallback used")
            } catch {
                DiagLog.log("playlist",
                            "refresh failed on both sources (loadedOnce=\(loadedOnce))")
                if !loadedOnce {
                    statusMessage = "Không tải được danh sách kênh. Kiểm tra mạng rồi thử lại."
                } else {
                    statusMessage = "Chưa làm mới được — đang dùng danh sách cũ."
                }
            }
        }
        DiagLog.log("playlist",
                    "refresh done: \(channels.count) channels, "
                    + "\(hotChannels.count) hot, \(liveChannels.count) live")
        pickInitialTabIfNeeded()
        // The state layer rides the playlist refresh (spec §1.6):
        // a full sweep here, the store's own loop polls live.
        Task { await liveStates.refreshNow() }
    }

    /// One playlist fetch + validation: the text must decode and parse
    /// to at least one channel, otherwise the source counts as failed
    /// (an error page or an empty file must never replace a good list).
    private func fetchPlaylist(from url: URL) async throws -> (Data, [Channel], String) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        // Same user agent the Android app sends; some CDNs expect it.
        request.setValue("Mozilla/5.0 (Linux; Android 14; TV)", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let text = String(data: data, encoding: .utf8) else {
            throw URLError(.cannotDecodeContentData)
        }
        let parsed = M3UParser.parse(text)
        if parsed.isEmpty { throw URLError(.zeroByteResource) }
        return (data, parsed, text)
    }

    private func setData(_ parsed: [Channel]) {
        rawChannels = parsed
        publishFiltered()
        lastFetch = Date()
        loadedOnce = true
        statusMessage = nil
    }

    /// Remember the newest EN block the mirror has served. An empty
    /// extraction never overwrites a good one (a bad mirror publish
    /// must not be able to erase the block everywhere at once).
    private func noteMirrorEN(_ parsed: [Channel]) {
        let en = parsed.filter { LeagueClassifier.isEN($0) }
        if !en.isEmpty { lastMirrorEN = en }
    }

    /// EN merge rule (owner's ecosystem ruling, 2026-11-15): the
    /// English-commentary block ALWAYS comes from the mirror,
    /// whichever source wins the main list. Before this rule, a stale
    /// mirror sent the main list to the origin — which carries no EN
    /// group — and the BLV Anh tab vanished until the mirror caught
    /// up. Measured flicker window: the origin's stamp ticks every
    /// 15–90 minutes while the mirror syncs every 15, so the tab
    /// blinked in and out. The web app carries the same rule (v6.2).
    private func mergingEN(_ main: [Channel]) -> [Channel] {
        if lastMirrorEN.isEmpty { return main }
        let have = Set(main.map { $0.url })
        let extra = lastMirrorEN.filter { !have.contains($0.url) }
        return extra.isEmpty ? main : main + extra
    }

    /// The Hot tab's list: the mirror's "🔥 Hot" group only, put
    /// through the same live-first sorting as every other list.
    private func setHot(_ parsed: [Channel]) {
        rawHotChannels = parsed.filter { $0.group == Self.hotGroupName }
        publishFiltered()
    }

    /// The single gate every display list flows through: raw entries
    /// minus proven-dead links minus .flv (unplayable on AVPlayer).
    private func publishFiltered() {
        channels = LeagueClassifier.sorted(rawChannels.filter(isDisplayable))
        hotChannels = LeagueClassifier.sorted(rawHotChannels.filter(isDisplayable))
        // Cadence hint for the state loop + the on-demand FotMob
        // incidents for live fixtures ESPN missed (capped inside).
        let now = Date()
        let liveOnes = (channels + hotChannels).filter {
            LeagueClassifier.bucket(of: $0, now: now) == 0
        }
        liveStates.liveHint = !liveOnes.isEmpty || liveStates.hasLiveState
        if !liveOnes.isEmpty {
            Task { await liveStates.upgradeDetails(for: liveOnes) }
        }
    }

    private func isDisplayable(_ ch: Channel) -> Bool {
        if invalidURLs.contains(ch.url) { return false }
        return !Self.isFLV(ch.url)
    }

    /// Pure helper — also called from the non-isolated LinkProbe, so
    /// it must not inherit the store's MainActor isolation (build
    /// error in runs #45/#46, 2026-11-13).
    nonisolated static func isFLV(_ url: String) -> Bool {
        let path = url.split(separator: "?").first.map(String.init) ?? url
        return path.lowercased().hasSuffix(".flv")
    }

    /// The player's fallback ladder for a tapped channel: the
    /// members of the tapped channel's fixture, tapped one first,
    /// capped at 8. The fixture comes from FixtureGrouping — the
    /// same grouping the cards on both platforms render — so the
    /// ladder covers exactly the sources the card grouped, no more
    /// (the old fixtureKey ladder also swept in same-teams listings
    /// from other dates) and no less (reversed or filler-prefixed
    /// listings of the same match are members now, not strangers).
    func sources(for ch: Channel) -> [Channel] {
        // EN backup channels are standalone 24/7 channels, not fixtures:
        // their ladder is the tapped channel alone. (fixtureKey drops
        // trailing numerals, which would otherwise pair ESPN with
        // ESPN 2 and FOX Sports with Fox Sports 1 as "fallbacks".)
        if LeagueClassifier.isEN(ch) { return [ch] }
        let groups = FixtureGrouping.group(channels + hotChannels)
        guard let members = groups.first(where: { g in
            g.members.contains { $0.url == ch.url }
        })?.members else { return [ch] }
        var seen = Set<String>()
        var out: [Channel] = []
        for candidate in [ch] + members {
            if seen.insert(candidate.url).inserted {
                out.append(candidate)
                if out.count >= 8 { break }
            }
        }
        return out.isEmpty ? [ch] : out
    }

    /// First load only: land on the Hot tab when it has a live match,
    /// else the highest-priority league with a live match right now;
    /// fall back to Ngoại Hạng Anh. Runs at the end of the first
    /// refresh so the Hot list is already known when deciding.
    private func pickInitialTabIfNeeded() {
        guard !didPickInitialTab, loadedOnce else { return }
        didPickInitialTab = true
        // Both platforms open on the Trực tiếp tab whenever anything
        // is live (owner's request, 2026-11-13) — that is what he
        // turns the TV on for, and iOS gained the same live chip in
        // 1.7 to stay in sync with the TV versions.
        if !liveChannels.isEmpty {
            selectedLeague = Self.liveTabValue
            return
        }
        let now = Date()
        if hotChannels.contains(where: { LeagueClassifier.bucket(of: $0, now: now) == 0 }) {
            selectedLeague = Self.hotTabValue
            return
        }
        var pick = League.england.rawValue
        for league in League.allCases {
            let hasLive = channels.contains {
                $0.leagueRank == league.rawValue && LeagueClassifier.bucket(of: $0, now: now) == 0
            }
            if hasLive { pick = league.rawValue; break }
        }
        selectedLeague = pick
    }

    // MARK: - Link validation (owner's request, 2026-11-13)

    /// The device's own vantage point is the only one that shares the
    /// owner's network and tunnel, so the app itself re-checks the
    /// list and hides the links that are definitively unplayable
    /// HERE, so dead links never reach the match screens. The mirror
    /// repo runs the vantage-independent half of the same job
    /// (404s + filler).
    ///
    /// FIX-141 (DIAG-140-SMOOTH §5 direction 5): validation is OFF
    /// the browsing path — the scheduled after-every-load pass is
    /// deleted (scheduleValidation and its start()/refresh() call
    /// sites are gone), and the pass that remains is INCREMENTAL:
    /// it probes only the URLs whose persisted probe stamp is
    /// missing or older than the 30 min TTL (see linkProbeStamps),
    /// so a repeat check minutes after the last one is nearly
    /// free instead of another ~460-probe, minutes-long drain.

    /// The "Kiểm tra link" button: force-fetch the newest playlist,
    /// then run ONE incremental validation pass over the URLs
    /// that are due. (FIX-141: the old shape ran the pass twice —
    /// refresh's own scheduled pass, waited out, then a
    /// from-scratch reset pass that cleared the hidden set first.)
    func refreshAndValidate() async {
        await refresh()
        await validateLinks()
        let hidden = invalidURLs.count
        DiagLog.log("links", "manual link check: \(hidden) dead links hidden")
        statusMessage = hidden > 0
            ? "Đã kiểm tra xong: ẩn \(hidden) link chết."
            : "Đã kiểm tra xong: không có link chết."
    }

    private func validateLinks() async {
        if validating { return }
        validating = true
        isValidating = true
        defer {
            validating = false
            isValidating = false
        }
        loadLinkProbeStampsIfNeeded()
        let now = Date()
        var seen = Set<String>()
        var pool: [Channel] = []
        for ch in rawChannels + rawHotChannels where seen.insert(ch.url).inserted {
            if !Self.isFLV(ch.url) { pool.append(ch) }
        }
        // FIX-141: only DUE channels are probed — no stamp yet,
        // or a stamp older than the 30 min TTL. Fresh channels
        // keep the verdict (and the hidden-set membership) their
        // last probe earned.
        let due = pool.filter { ch in
            guard let stamp = linkProbeStamps[ch.url] else { return true }
            return now.timeIntervalSince(stamp) > Self.linkProbeTTL
        }
        // FIX-141: the pass is observable (the old ambient pass
        // wrote no log lines at all — DIAG-140-SMOOTH §2.4).
        DiagLog.log("links",
                    "link validation: start — pool \(pool.count), "
                    + "\(due.count) due, \(pool.count - due.count) fresh")
        let started = Date()
        // Live-window and always-on channels first — they are what
        // the home screen leads with; the rest follow in a second wave.
        let liveWave = due.filter { isLiveScope($0, now: now) }
        let restWave = due.filter { !isLiveScope($0, now: now) }
        let live = await probeWave(liveWave, now: now)
        let rest = await probeWave(restWave, now: now)
        let seconds = Date().timeIntervalSince(started)
        DiagLog.log("links",
                    String(format: "link validation: done in %.1fs — "
                           + "%d valid, %d invalid, %d hidden total",
                           seconds, live.valid + rest.valid,
                           live.invalid + rest.invalid, invalidURLs.count))
    }

    /// "Should be serving right now": inside the live window, or a
    /// channel with no kickoff at all (24/7 streams).
    private func isLiveScope(_ ch: Channel, now: Date) -> Bool {
        ch.kickoff == nil || LeagueClassifier.bucket(of: ch, now: now) == 0
    }

    /// Probes one wave and merges its verdicts into the hidden
    /// set. FIX-141: every probed URL — valid or invalid — is
    /// stamped with the pass's `now` and the stamps file is
    /// saved, so the next pass inside the TTL skips it; the
    /// wave's own valid/invalid counts go back to the caller
    /// for the completion log line.
    private func probeWave(_ wave: [Channel], now: Date) async -> (valid: Int, invalid: Int) {
        if wave.isEmpty { return (0, 0) }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        let session = URLSession(configuration: config)
        var validNow: Set<String> = []
        var invalidNow: Set<String> = []
        let chunkSize = 20
        var idx = 0
        while idx < wave.count {
            let chunk = Array(wave[idx..<min(idx + chunkSize, wave.count)])
            let results = await withTaskGroup(of: (String, Bool).self) { group in
                for ch in chunk {
                    let scope = isLiveScope(ch, now: now)
                    group.addTask {
                        (ch.url, await LinkProbe.isValid(ch, mustBeServing: scope, session: session))
                    }
                }
                var acc: [(String, Bool)] = []
                for await r in group { acc.append(r) }
                return acc
            }
            for (url, ok) in results {
                if ok { validNow.insert(url) } else { invalidNow.insert(url) }
                linkProbeStamps[url] = now // FIX-141: probed is probed, either way
            }
            idx += chunkSize
        }
        saveLinkProbeStamps() // FIX-141
        let before = invalidURLs
        invalidURLs.subtract(validNow)
        invalidURLs.formUnion(invalidNow)
        if invalidURLs != before {
            saveInvalidSet()
            publishFiltered()
        }
        return (validNow.count, invalidNow.count)
    }
}

/// One-link probe. Definitive failure = HTTP 404/410, or HTTP 200 with
/// a body that is not a stream (empty, or an .m3u8 without #EXTM3U).
/// Other HTTP statuses keep the link (403 may be the tunnel being off
/// right now; 5xx is transient). A network-level failure (connect,
/// timeout) counts only when the channel should be serving right now —
/// a room for a future match may simply not exist yet.
private enum LinkProbe {

    static func isValid(_ ch: Channel, mustBeServing: Bool, session: URLSession) async -> Bool {
        guard let url = URL(string: ch.url) else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.setValue(
            ch.userAgent.isEmpty ? "Mozilla/5.0 (Linux; Android 14; TV)" : ch.userAgent,
            forHTTPHeaderField: "User-Agent")
        if !ch.referrer.isEmpty {
            request.setValue(ch.referrer, forHTTPHeaderField: "Referer")
        }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            if status == 404 || status == 410 { return false }
            guard status == 200 else { return true }
            var buffer = Data()
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count > 4096 { break }
            }
            if buffer.isEmpty { return false }
            if PlaylistStore.isFLV(ch.url) { return true }
            let path = ch.url.split(separator: "?").first.map(String.init) ?? ch.url
            if path.lowercased().hasSuffix(".m3u8") {
                return String(decoding: buffer.prefix(1024), as: UTF8.self).contains("#EXTM3U")
            }
            return true
        } catch {
            return !mustBeServing
        }
    }
}

/// The playlist files carry their generation time as a first
/// pseudo-entry ("Updated DD/MM HH:MM", Vietnam time). Parsed with
/// the same calendar rules as kickoffs (StampYear); a stamp slightly
/// in the future (clock skew) reads as fresh, no stamp reads as
/// unknown. Internal (not private) only so the unit tests can call
/// it with a fixed `now`.
enum UpdatedStamp {

    private static let regex = try! NSRegularExpression(
        pattern: #"Updated\s+(\d{1,2})/(\d{1,2})\s+(\d{1,2}):(\d{2})"#)

    static func parse(_ text: String, now: Date = Date()) -> Date? {
        let head = String(text.prefix(512))
        let range = NSRange(head.startIndex..., in: head)
        guard let m = regex.firstMatch(in: head, range: range) else { return nil }
        func intAt(_ i: Int) -> Int? {
            guard let r = Range(m.range(at: i), in: head) else { return nil }
            return Int(head[r])
        }
        guard let day = intAt(1), let month = intAt(2),
              let hour = intAt(3), let minute = intAt(4) else { return nil }
        return StampYear.resolve(month: month, day: day, hour: hour, minute: minute, now: now)
    }
}
