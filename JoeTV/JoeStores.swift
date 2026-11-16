import SwiftUI

/// Section data stores, owned once by the app shell. In v1.1 the
/// Phim and Torrent homes kept their rails in view @State, so
/// every section switch destroyed them and the owner watched a
/// full reload spinner each time he came back. The stores load
/// once, keep the data across switches, and only re-fetch when
/// the snapshot is older than 15 minutes (silently, behind the
/// cached rails).

@MainActor
final class PhimStore: ObservableObject {
    static let genreSpec: [(slug: String, title: String)] = [("hanh-dong","💥 Hành Động"),("kinh-di","👻 Kinh Dị"),("hai-huoc","😂 Hài Hước"),("vien-tuong","🚀 Viễn Tưởng"),("tinh-cam","❤️ Tình Cảm"),("hinh-su","🕵️ Hình Sự"),("phieu-luu","🧭 Phiêu Lưu"),("co-trang","🏯 Cổ Trang")]
    static let countrySpec: [(slug: String, title: String)] = [("han-quoc","🇰🇷 Hàn Quốc"),("trung-quoc","🇨🇳 Trung Quốc"),("au-my","🌎 Âu Mỹ")]

    @Published var merged: [Movie] = []
    @Published var kkNew: [Movie] = []
    @Published var kkSeries: [Movie] = []
    @Published var kkMovies: [Movie] = []
    @Published var kkAnime: [Movie] = []
    @Published var f4kNew: [Movie] = []
    @Published var f4kMovies: [Movie] = []
    @Published var vsNew: [Movie] = []
    @Published var vsSeries: [Movie] = []
    @Published var tpNew: [Movie] = []
    @Published var tpMovies: [Movie] = []
    @Published var tpSeries: [Movie] = []
    @Published var chieuRap: [Movie] = []
    @Published var genreLists: [String: [Movie]] = [:]
    @Published var countryLists: [String: [Movie]] = [:]
    /// Dedicated Vietnam block (owner order 2026-11-14): one
    /// 48-item country fetch, split by the KK items' `type`
    /// field — the owner never has to search for Vietnamese films.
    @Published var vietnamAll: [Movie] = []
    var vietnamSeries: [Movie] { vietnamAll.filter { $0.type == "series" } }
    var vietnamSingle: [Movie] { vietnamAll.filter { $0.type == "single" } }
    @Published var loading = false
    /// Board contract (rework v1.9): true once a load has run
    /// 20 s with hasData still false, so the view can show its
    /// error+retry surface while slow jobs are still in flight.
    /// Cleared when a load starts and when data lands.
    @Published var loadTimedOut = false
    /// Last error per provider code (kk / f4k / vsmov / tp) from
    /// the most recent load — the diagnostics surface. An entry
    /// clears when one of that provider's rails lands. Pre-v1.9
    /// every error was discarded by try?, so no on-device
    /// failure could ever be diagnosed.
    @Published var providerErrors: [String: String] = [:]

    private var loadedAt: Date?
    private var loadTask: Task<Void, Never>?
    private var loadGeneration = 0

    var hasData: Bool { !merged.isEmpty || !kkNew.isEmpty }

    /// True when NO catalogue rail has anything — the C-8
    /// condition the load-state surfaces (G3/G5) gate on.
    /// Shared by the rail home and the poster wall so the two
    /// can never disagree (UI-6 defect D-20 parity).
    var catalogueIsEmpty: Bool {
        merged.isEmpty && chieuRap.isEmpty && vietnamAll.isEmpty
            && kkNew.isEmpty && kkSeries.isEmpty && kkMovies.isEmpty
            && kkAnime.isEmpty && f4kNew.isEmpty && f4kMovies.isEmpty
            && vsNew.isEmpty && vsSeries.isEmpty
            && tpMovies.isEmpty && tpSeries.isEmpty
            && genreLists.values.allSatisfy { $0.isEmpty }
            && countryLists.values.allSatisfy { $0.isEmpty }
    }

    /// G4's failed-provider display names, from providerErrors
    /// (an entry exists exactly while that provider's latest
    /// load failed; it clears when one of its rails lands).
    /// Shared by the rail home and the poster wall (D-20).
    var failedProviderNames: [String] {
        guard !loading, hasData else { return [] }
        return ["kk", "f4k", "vsmov", "tp"]
            .filter { providerErrors[$0] != nil }
            .map { code in
                switch code {
                case "kk": return "KKPhim"
                case "f4k": return "Film4K"
                case "vsmov": return "VSMOV"
                case "tp": return "Tủ Phim"
                default: return code
                }
            }
    }

    func loadIfNeeded() {
        if loading { return }
        if let loadedAt, hasData,
           Date().timeIntervalSince(loadedAt) < 900 { return }
        loadTask = Task { await load() }
    }

    /// One rail job: a stable cache key, the provider it belongs
    /// to (for error attribution), and the request to fetch.
    private struct Job {
        let key: String
        let provider: String
        let request: Providers.ListRequest
    }

    /// Launch order IS priority order: the four "newest" rails
    /// and the Vietnam block first (they head the home), the
    /// rest behind them under the concurrency gate.
    private static var jobs: [Job] {
        var list: [Job] = [
            Job(key: "kkNew", provider: Providers.KK, request: .newest(page: 1)),
            Job(key: "f4kNew", provider: Providers.F4K, request: .newest(page: 1)),
            Job(key: "vsNew", provider: Providers.VS, request: .newest(page: 1)),
            Job(key: "tpNew", provider: Providers.TP, request: .newest(page: 1)),
            Job(key: "vietnam", provider: Providers.KK,
                request: .country(slug: "viet-nam", page: 1, limit: 48)),
            Job(key: "kkSeries", provider: Providers.KK, request: .byType(type: "phim-bo", page: 1)),
            Job(key: "kkMovies", provider: Providers.KK, request: .byType(type: "phim-le", page: 1)),
            Job(key: "kkAnime", provider: Providers.KK, request: .byType(type: "hoat-hinh", page: 1)),
            Job(key: "f4kMovies", provider: Providers.F4K, request: .byType(type: "phim-le", page: 1)),
            Job(key: "vsSeries", provider: Providers.VS, request: .byType(type: "phim-bo", page: 1)),
            Job(key: "tpMovies", provider: Providers.TP, request: .byType(type: "phim-le", page: 1)),
            Job(key: "tpSeries", provider: Providers.TP, request: .byType(type: "phim-bo", page: 1)),
            Job(key: "chieuRap", provider: Providers.KK, request: .byType(type: "phim-chieu-rap", page: 1)),
        ]
        for spec in genreSpec {
            list.append(Job(key: "genre:" + spec.slug, provider: Providers.KK,
                            request: .genre(slug: spec.slug, page: 1)))
        }
        for spec in countrySpec {
            list.append(Job(key: "country:" + spec.slug, provider: Providers.KK,
                            request: .country(slug: spec.slug, page: 1, limit: nil)))
        }
        return list
    }

    /// v1.9 (rework): cache-first, deadline-bounded, storm-free.
    /// v1.8 published progressively (kept) but fired all 24 jobs
    /// at once — up to 58 requests with KK's sequential failover —
    /// with NO deadline, no cache and every error discarded; on
    /// the owner's TV that froze the whole device (his report:
    /// many Menu presses to escape).
    ///
    /// CONVERGENCE (Team 6 A1/D + Team 8, 2026-11-15): the v1.9
    /// shape still ran every job's synchronous tail (cache save,
    /// JSON parse, rail application) ON this main actor — the
    /// task-group children inherited the actor — so the load,
    /// the 20 s watchdog (an unstructured task created inside
    /// load(), hence also main-actor-isolated: its publication
    /// had to win a slot on the very executor it monitored) and
    /// the view state all shared one executor, and any stall
    /// presented as the joint symptom the owner hit: frozen UI,
    /// spinner forever, no error surface. Now:
    ///   1. the disk cache renders first (decoded OFF-actor),
    ///   2. the watchdog runs on an INDEPENDENT clock (a
    ///      detached task + a lock-guarded box) — its trip
    ///      never needs this actor to be free, and the
    ///      attempted/landed signposts attribute any delay,
    ///   3. the refresh is STAGED: the four "newest" jobs run
    ///      first; the remaining twenty start on phase 1's
    ///      FIRST publish or after a 3 s fuse, whichever comes
    ///      first (1.9.2, Team 9 item 2 — pre-fix phase 2 waited
    ///      for phase 1 to drain completely, so one black-holing
    ///      KK list call held all twenty jobs hostage behind its
    ///      full timeout),
    ///   4. fetch + cache-write + parse run in a DETACHED
    ///      worker (non-isolated context); results cross back
    ///      through a lock-guarded box and only the @Published
    ///      application happens here, in a findAlternatives-
    ///      style poll loop,
    ///   5. a HARD 25 s overall deadline (the same box
    ///      pattern) stops the awaiting, keeps partial rails
    ///      and always clears `loading`.
    private func load() async {
        loading = true
        loadTimedOut = false
        loadGeneration += 1
        let generation = loadGeneration
        defer { loading = false }

        let jobs = Self.jobs
        let startedAt = Date()
        let deadline = startedAt.addingTimeInterval(25)
        LoadSignpost.log("load started gen=\(generation)")

        // 1) Independent deadline watchdog (board contract),
        // armed before any work so the 20 s is measured from
        // the load's start. The clock task is DETACHED: it
        // does not inherit this actor. When it trips, the
        // publication hop to the main actor is attempted from
        // off-actor and signposted on both sides of the hop.
        let watchdogBox = LoadWatchdogBox(generation: generation)
        watchdogBox.arm()
        Task.detached { [weak self, watchdogBox] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard watchdogBox.tripIfNoData() else { return }
            LoadSignpost.log("publication attempted gen=\(generation)")
            await MainActor.run { [weak self] in
                guard let self, self.loadGeneration == generation else { return }
                self.loadTimedOut = true
                LoadSignpost.log("publication landed gen=\(generation)")
            }
        }

        // 2) Cache first (the TVStore pattern). PhimRailCache is
        // non-isolated, so awaiting it suspends this actor
        // instead of blocking it; only parsed rails cross back.
        let cached = await PhimRailCache.hydrate(
            jobs.map { (key: $0.key, provider: $0.provider, request: $0.request) })
        for (key, movies) in cached {
            applyRail(key, movies)
        }
        if !cached.isEmpty, watchdogBox.markHasData() {
            LoadSignpost.log("first rail landed gen=\(generation) (cache)")
        }

        // 3) Staged refresh behind the cache, in the detached
        // worker: phase 1 is the four "newest" jobs (the jobs
        // list is priority-ordered, so they are its head);
        // phase 2 — the remaining twenty — starts on phase 1's
        // FIRST publish or after a 3 s fuse, whichever comes
        // first (1.9.2, Team 9 item 2), then runs concurrently
        // with whatever is left of phase 1 behind the same
        // gate. The box is finished only when BOTH phases have
        // drained.
        let gate = AsyncGate(permits: 4)
        let box = PhimLoadBox()
        let phase1 = Array(jobs.prefix(4))
        let phase2 = Array(jobs.dropFirst(4))
        let worker = Task.detached {
            let phase1Task = Task {
                await Self.runPhase(phase1, gate: gate, deadline: deadline, box: box)
                box.markPhase1Done()
            }
            let fuseStart = Date()
            while box.publishedCount == 0 && !box.phase1Done
                    && Date().timeIntervalSince(fuseStart) < 3 {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            LoadSignpost.log("phase2 started gen=\(generation)")
            await Self.runPhase(phase2, gate: gate, deadline: deadline, box: box)
            if Task.isCancelled { phase1Task.cancel() }
            await phase1Task.value
            box.finish()
        }

        // 4) Consume results until the worker finishes, this
        // load is superseded, the task is cancelled, or the
        // hard 25 s deadline passes — whichever comes first.
        while true {
            applyResults(box.drain(), watchdogBox: watchdogBox, generation: generation)
            if box.isFinished { break }
            if loadGeneration != generation || Task.isCancelled { break }
            if Date() >= deadline {
                LoadSignpost.log("deadline hit gen=\(generation)")
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        applyResults(box.drain(), watchdogBox: watchdogBox, generation: generation)
        if !box.isFinished { worker.cancel() }
        LoadSignpost.log("load completed gen=\(generation)")
    }

    /// Apply one drained batch of worker results on this
    /// actor — the ONLY part of the refresh that runs here.
    /// Partial-success semantics preserved from v1.9: ANY
    /// landed rail stamps the load and clears that provider's
    /// error (v1.8 stamped only a hasData success, so a
    /// partial load re-fired the whole storm on every visit).
    /// A skipped job (gate deadline) publishes movies == nil
    /// AND error == nil and is ignored: it is not evidence
    /// about the provider.
    private func applyResults(_ results: [PhimLoadBox.Result],
                              watchdogBox: LoadWatchdogBox, generation: Int) {
        for result in results {
            if let movies = result.movies {
                applyRail(result.key, movies)
                if !movies.isEmpty {
                    loadedAt = Date()
                    loadTimedOut = false
                    providerErrors[result.provider] = nil
                    if watchdogBox.markHasData() {
                        LoadSignpost.log("first rail landed gen=\(generation)")
                    }
                }
            } else if let error = result.error {
                providerErrors[result.provider] = error
            }
        }
    }

    /// One refresh phase, run ENTIRELY off the main actor
    /// (nonisolated; the worker task is detached): gate,
    /// fetch, cache-write and parse all happen in the
    /// children's generic-executor context, and only the
    /// small parsed rails cross back through the box.
    nonisolated private static func runPhase(_ phaseJobs: [Job], gate: AsyncGate,
                                             deadline: Date, box: PhimLoadBox) async {
        await withTaskGroup(of: Void.self) { group in
            for job in phaseJobs {
                group.addTask {
                    guard await gate.acquire(deadline: deadline) else {
                        // Could not start inside the load's
                        // overall deadline: report a skip
                        // (no movies, no error).
                        box.publish((key: job.key, provider: job.provider,
                                     movies: nil, error: nil))
                        return
                    }
                    let result: PhimLoadBox.Result
                    do {
                        let root = try await Providers.fetchListRaw(job.provider, job.request)
                        PhimRailCache.save(key: job.key, root: root)
                        result = (key: job.key, provider: job.provider,
                                  movies: Providers.parseList(job.provider, job.request, root),
                                  error: nil)
                    } catch {
                        result = (key: job.key, provider: job.provider,
                                  movies: nil, error: error.localizedDescription)
                    }
                    await gate.release()
                    box.publish(result)
                }
            }
        }
    }

    private func applyRail(_ key: String, _ movies: [Movie]) {
        // UI-5 image pipeline: warm this rail's posters as it lands.
        // Rails land in home order (phase 1 first), so the next rail
        // is always warming while the owner reads the current one —
        // and on a cache-first launch the hydrated rails warm the
        // decoded cache before the owner scrolls anywhere.
        JoeImagePipeline.shared.prefetch(movies.compactMap { $0.posterURL },
                                         targetPixels: 720)
        switch key {
        case "kkNew": kkNew = movies; refreshMerged()
        case "f4kNew": f4kNew = movies; refreshMerged()
        case "vsNew": vsNew = movies; refreshMerged()
        case "tpNew": tpNew = movies; refreshMerged()
        case "kkSeries": kkSeries = movies
        case "kkMovies": kkMovies = movies
        case "kkAnime": kkAnime = movies
        case "f4kMovies": f4kMovies = movies
        case "vsSeries": vsSeries = movies
        case "tpMovies": tpMovies = movies
        case "tpSeries": tpSeries = movies
        case "chieuRap": chieuRap = movies
        case "vietnam": vietnamAll = movies
        default:
            if key.hasPrefix("genre:") {
                genreLists[String(key.dropFirst(6))] = movies
            } else if key.hasPrefix("country:") {
                countryLists[String(key.dropFirst(8))] = movies
            }
        }
    }

    private func refreshMerged() {
        merged = Providers.mergeDedupe([kkNew, f4kNew, vsNew, tpNew])
    }

    /// Manual retry for the home's error state (a failed load
    /// leaves loadedAt nil, so loadIfNeeded runs again).
    func retry() { loadIfNeeded() }
}

/// Counting semaphore bounding the Phim launch burst: at most
/// `permits` provider jobs are in flight at once, so app start
/// can never flood the network stack (owner device evidence:
/// v1.8's unbounded 24-job burst froze the whole TV).
/// Cancellation-safe: a waiter whose task is cancelled is
/// removed and resumed, so a cancelled load can never wedge
/// the gate (and with it the task group) shut.
///
/// CONVERGENCE (Team 6 census A11, 2026-11-15): acquire now
/// takes the load's overall DEADLINE. Pre-fix a parked waiter
/// could wait forever — nothing resumed it except a release
/// or its own task's cancellation — so a wedged gate held the
/// whole load open with it. A waiter still parked at the
/// deadline is resumed with false by its own warden task and
/// its job reports a skip instead of starting late. Every
/// resume path removes the waiter BEFORE resuming, so each
/// continuation is resumed exactly once.
private actor AsyncGate {
    private var permits: Int
    private var waiters: [(UUID, CheckedContinuation<Bool, Never>)] = []

    init(permits: Int) { self.permits = permits }

    /// True when a permit was granted; false when the
    /// deadline passed (or the task was cancelled) first.
    func acquire(deadline: Date) async -> Bool {
        if permits > 0 {
            permits -= 1
            return true
        }
        if Date() >= deadline { return false }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation {
                (cont: CheckedContinuation<Bool, Never>) in
                // Already cancelled before parking: never queue
                // (the onCancel may already have run and found
                // no waiter to remove).
                if Task.isCancelled {
                    cont.resume(returning: false)
                } else {
                    waiters.append((id, cont))
                    // Deadline warden: if this waiter is still
                    // parked when the deadline passes, fail it.
                    // (If release() grants it first, the warden
                    // finds no waiter and does nothing.)
                    Task.detached { [self] in
                        let remaining = deadline.timeIntervalSinceNow
                        if remaining > 0 {
                            try? await Task.sleep(
                                nanoseconds: UInt64(remaining * 1_000_000_000))
                        }
                        await self.expireWaiter(id)
                    }
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func expireWaiter(_ id: UUID) {
        if let i = waiters.firstIndex(where: { $0.0 == id }) {
            waiters.remove(at: i).1.resume(returning: false)
        }
    }

    private func cancelWaiter(_ id: UUID) {
        if let i = waiters.firstIndex(where: { $0.0 == id }) {
            waiters.remove(at: i).1.resume(returning: false)
        }
    }

    func release() {
        if waiters.isEmpty {
            permits += 1
        } else {
            waiters.removeFirst().1.resume(returning: true)
        }
    }
}

/// Persisted signpost log for the Phim load path (convergence
/// spec 5d): timestamped one-line events in UserDefaults under
/// "joetv.signposts", newest last, capped at 200 entries. If a
/// stall ever recurs, the tail of this log attributes it —
/// watchdog armed / sleep done / publication attempted vs
/// landed separates "the clock never fired" from "the main
/// actor never took the hop".
enum LoadSignpost {
    private static let lock = NSLock()
    private static let key = "joetv.signposts"

    /// Read-only snapshot for the Settings diagnostics
    /// surface: the stored entries, oldest→newest as stored.
    /// Never writes.
    static func entries() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func log(_ event: String) {
        lock.lock()
        defer { lock.unlock() }
        let stamp = ISO8601DateFormatter().string(from: Date())
        var entries = UserDefaults.standard.stringArray(forKey: key) ?? []
        entries.append(stamp + " " + event)
        if entries.count > 200 {
            entries.removeFirst(entries.count - 200)
        }
        UserDefaults.standard.set(entries, forKey: key)
    }
}

/// Lock-guarded state shared between PhimStore and its
/// INDEPENDENT watchdog clock (convergence spec 5d): the clock
/// task is detached, so the "has any data landed" fact and the
/// trip decision live here — never on the main actor the
/// watchdog exists to monitor.
private final class LoadWatchdogBox: @unchecked Sendable {
    let generation: Int
    private let lock = NSLock()
    private var hasDataFlag = false
    private var tripped = false

    init(generation: Int) { self.generation = generation }

    func arm() {
        LoadSignpost.log("watchdog armed gen=\(generation)")
    }

    /// Mark that data has landed (cache or network). Returns
    /// true only for the FIRST mark, so the caller can
    /// signpost the first-rail landing exactly once.
    @discardableResult
    func markHasData() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if hasDataFlag { return false }
        hasDataFlag = true
        return true
    }

    /// Called by the independent clock when its 20 s sleep
    /// ends: trips (returns true) iff no data has landed and
    /// it has not tripped before.
    func tripIfNoData() -> Bool {
        lock.lock()
        let shouldTrip = !hasDataFlag && !tripped
        if shouldTrip { tripped = true }
        let hadData = hasDataFlag
        lock.unlock()
        LoadSignpost.log("watchdog sleep done gen=\(generation) hasData=\(hadData)")
        return shouldTrip
    }
}

/// Lock-guarded result box between the detached load worker
/// and the store's consumer loop (the findAlternatives
/// pattern): the worker publishes parsed rails; the consumer
/// drains them on the main actor. The worker is never awaited
/// by the consumer, so a stuck job cannot hold the load open
/// past its deadline.
private final class PhimLoadBox: @unchecked Sendable {
    typealias Result = (key: String, provider: String, movies: [Movie]?, error: String?)

    private let lock = NSLock()
    private var pending: [Result] = []
    private var finishedFlag = false
    private var publishedTotal = 0
    private var phase1DoneFlag = false

    func publish(_ result: Result) {
        lock.lock()
        pending.append(result)
        publishedTotal += 1
        lock.unlock()
    }

    /// Total results published so far (drained or not) — the
    /// phase-2 trigger reads it (1.9.2, Team 9 item 2).
    var publishedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return publishedTotal
    }

    func markPhase1Done() {
        lock.lock()
        phase1DoneFlag = true
        lock.unlock()
    }

    var phase1Done: Bool {
        lock.lock()
        defer { lock.unlock() }
        return phase1DoneFlag
    }

    func drain() -> [Result] {
        lock.lock()
        defer { lock.unlock() }
        let out = pending
        pending = []
        return out
    }

    func finish() {
        lock.lock()
        finishedFlag = true
        lock.unlock()
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finishedFlag
    }
}

/// Disk cache of the Phim rails' last-good RAW provider
/// responses — the TVStore pattern (cache-first, refresh
/// behind), one small file per rail job in the caches
/// directory (~13–34 KB each, measured). Deliberately
/// NON-isolated: hydrate's file IO and JSON decoding run on
/// the generic executor and cross back across an await;
/// save is reached from the load's child tasks and its
/// payloads are small, so the load path never meaningfully
/// blocks the main thread.
///
/// v2.0.8 (Phase 7c): the cache is now BOUNDED — a 16 MB
/// total cap pruned oldest-first on every write (the
/// JoeDetailCache.prune pattern, restricted to this cache's
/// own "phim-rail-*.json" files: they live in the shared
/// caches directory, so nothing else is counted or
/// deleted), and a 7-day TTL: a file older than the TTL is
/// a miss on hydrate and is deleted when met. The TTL
/// governs the on-disk artefact only; the in-session reuse
/// window stays PhimStore.loadIfNeeded's 900 s.
private enum PhimRailCache {
    private static let capBytes = 16 * 1024 * 1024
    private static let ttl: TimeInterval = 7 * 24 * 3600

    static func fileURL(for key: String) -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let safe = key.replacingOccurrences(of: ":", with: "-")
        return dir.appendingPathComponent("phim-rail-\(safe).json")
    }

    static func save(key: String, root: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: root)
        else { return }
        try? data.write(to: fileURL(for: key), options: .atomic)
        prune()
    }

    /// Oldest-first prune to the size cap, on every write
    /// (mirrors JoeDetailCache.prune).
    private static func prune() {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        guard let files = try? FileManager.default
            .contentsOfDirectory(at: dir, includingPropertiesForKeys:
                [.fileSizeKey, .contentModificationDateKey])
        else { return }
        var entries: [(url: URL, size: Int, mtime: Date)] = []
        var total = 0
        for f in files where f.lastPathComponent.hasPrefix("phim-rail-")
            && f.pathExtension == "json" {
            let values = try? f.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = values?.fileSize ?? 0
            entries.append((f, size, values?.contentModificationDate ?? .distantPast))
            total += size
        }
        if total <= capBytes { return }
        for entry in entries.sorted(by: { $0.mtime < $1.mtime }) {
            if total <= capBytes { break }
            if (try? FileManager.default.removeItem(at: entry.url)) != nil {
                total -= entry.size
            }
        }
    }

    /// Read + decode + parse every cached rail, in job order.
    /// Rails whose cache is missing, corrupt, older than the
    /// TTL or parses empty are simply absent from the result.
    static func hydrate(
        _ jobs: [(key: String, provider: String, request: Providers.ListRequest)]
    ) async -> [(String, [Movie])] {
        var out: [(String, [Movie])] = []
        for job in jobs {
            let url = fileURL(for: job.key)
            // TTL gate (v2.0.8): an expired file is a miss
            // and is deleted, never parsed.
            if let mtime = (try? url.resourceValues(
                    forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate,
               Date().timeIntervalSince(mtime) > ttl {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            guard let data = try? Data(contentsOf: url),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let movies = Providers.parseList(job.provider, job.request, root)
            if !movies.isEmpty { out.append((job.key, movies)) }
        }
        return out
    }
}

struct TorGenreRail {
    var type: String
    var genre: String
    var title: String
    var metas: [TorMeta] = []
}

@MainActor
final class TorHomeStore: ObservableObject {
    static let genreSpec: [(type: String, genre: String, title: String)] = [("movie","Action","💥 Hành Động"),("movie","Horror","👻 Kinh Dị"),("movie","Comedy","😂 Hài Hước"),("movie","Science Fiction","🚀 Viễn Tưởng"),("movie","Thriller","😱 Giật Gân"),("movie","Drama","🎭 Chính Kịch"),("series","Drama","🎭 Chính Kịch"),("series","Comedy","😂 Hài Hước"),("series","Crime","🕵️ Tội Phạm"),("series","Science Fiction","🚀 Viễn Tưởng")]

    @Published var catalogs: [TorCatalog] = []
    @Published var rails: [String: [TorMeta]] = [:]
    @Published var genreRails: [TorGenreRail] = []
    @Published var loading = false
    /// Board contract (rework v1.9, Team 4 BLOCK-1): true once
    /// a load has run 20 s with NO rail landed, so the view can
    /// show its error+retry surface while slow fetches are
    /// still in flight. Cleared when a load starts and the
    /// moment any rail lands. Keyed on rails, never hasData:
    /// discoverCatalogs never returns empty (Cinemeta
    /// fallbacks), so hasData is true even when every rail
    /// fetch behind it is dead.
    @Published var loadTimedOut = false

    private var loadedAt: Date?
    private var loadGeneration = 0

    var hasData: Bool { !catalogs.isEmpty }

    /// True once any rail with actual content has landed —
    /// the honest "the home has something to show" signal.
    /// (hasData only means catalogues were discovered, which
    /// the Cinemeta fallbacks make unconditional.)
    var hasAnyRail: Bool {
        rails.values.contains { !$0.isEmpty }
            || genreRails.contains { !$0.metas.isEmpty }
    }

    func loadIfNeeded() {
        if loading { return }
        if let loadedAt, hasData,
           Date().timeIntervalSince(loadedAt) < 900 { return }
        Task { await load() }
    }

    /// Forced reload for the error surface's Retry: bypasses
    /// the loadedAt freshness guard entirely — with the old
    /// unconditional stamp (see load()), that guard no-opped
    /// for 15 minutes after a dead-route load and Retry could
    /// never recover. A load already in flight IS the fresh
    /// attempt, so it is left to finish: it either lands a
    /// rail (clearing the error state) or ends, freeing the
    /// next Retry.
    func reload() {
        if loading { return }
        Task { await load() }
    }

    private func load() async {
        loading = true
        loadTimedOut = false
        loadGeneration += 1
        let generation = loadGeneration
        // Generation-guarded (1.9.2): the 15 s hard deadline
        // below can clear `loading` while this load is still in
        // flight, which makes a concurrent Retry load possible;
        // a stale load's defer must not then clear the NEW
        // load's flag when it finally returns.
        defer {
            if loadGeneration == generation { loading = false }
        }

        // Deadline watchdog (board contract, BLOCK-1), started
        // before any work so the 20 s is measured from the
        // load's start. Semantics mirror PhimStore's watchdog,
        // except the trip condition is "no rail has landed" —
        // Tor's hasData cannot be used here (see loadTimedOut).
        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard let self, !Task.isCancelled else { return }
            if self.loadGeneration == generation && !self.hasAnyRail {
                self.loadTimedOut = true
            }
        }
        defer { watchdog.cancel() }

        // Hard deadline (1.9.2, Team 9 item 6): at ~15 s the
        // load STOPS presenting as in-flight — `loading` clears
        // (so the error surface's Retry is live from that
        // moment, instead of no-opping against a load that
        // could grind on for ~100 s of sequential timeouts)
        // and, when no rail has landed, the timeout surface
        // shows. Fetches still in flight are NOT cancelled:
        // late results still apply when they land, exactly as
        // the catalogue loop below has always applied them.
        let hardDeadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, !Task.isCancelled else { return }
            if self.loadGeneration == generation {
                self.loading = false
                if !self.hasAnyRail { self.loadTimedOut = true }
            }
        }
        defer { hardDeadline.cancel() }

        let base = TorrentSettings.effectiveBase ?? TorrentSettings.cinemeta
        let cats = await TorrentClient.discoverCatalogs(addonBase: base)
        if !cats.isEmpty { catalogs = cats }
        // Catalogue fetches run CONCURRENTLY and publish per
        // landing (1.9.2, Team 9 item 6 — mirroring the genre
        // path below and PhimStore's shape). The pre-fix
        // SEQUENTIAL loop stacked the discovery timeouts end
        // to end (≈100 s worst case on a dead route).
        await withTaskGroup(of: (String, [TorMeta]?).self) { group in
            for cat in catalogs {
                group.addTask {
                    (cat.id + "|" + cat.type,
                     try? await TorrentClient.fetchCatalog(cat))
                }
            }
            for await (key, metas) in group {
                // Preserve-on-empty (C-5 class, matching the
                // genre path below): an empty-but-successful
                // fetch must not overwrite a rail a previous
                // load already landed — only a non-empty result
                // replaces the rail (and stamps the load).
                if let metas, !metas.isEmpty {
                    rails[key] = metas
                    // A rail actually landed: stamp the load
                    // and clear any deadline state at once.
                    loadedAt = Date()
                    loadTimedOut = false
                }
            }
        }
        // Genre rails (C-5): fetched CONCURRENTLY and published
        // PER RAIL as each lands, merged over the previously
        // good rails in spec order — a failed or empty fetch
        // keeps the old rail. The pre-v1.9 code fetched
        // sequentially into a local array, published once at the
        // end, and overwrote genreRails unconditionally, so one
        // network blip during a refresh wiped every genre rail
        // the owner had, and the block could take 10 × 25 s of
        // sequential timeouts to appear at all.
        await withTaskGroup(of: TorGenreRail?.self) { group in
            for spec in Self.genreSpec {
                group.addTask {
                    if let metas = try? await TorrentClient.fetchGenreCatalog(type: spec.type, genre: spec.genre),
                       !metas.isEmpty {
                        return TorGenreRail(type: spec.type, genre: spec.genre, title: spec.title, metas: metas)
                    }
                    return nil
                }
            }
            for await rail in group {
                guard let rail else { continue }
                var byKey: [String: TorGenreRail] = [:]
                for r in genreRails { byKey[r.type + "|" + r.genre] = r }
                byKey[rail.type + "|" + rail.genre] = rail
                genreRails = Self.genreSpec.compactMap {
                    byKey[$0.type + "|" + $0.genre]
                }
                // Group children only return a rail for a
                // non-empty fetch, so this IS a landed rail:
                // stamp the load and clear deadline state.
                loadedAt = Date()
                loadTimedOut = false
            }
        }
        // No closing stamp here (BLOCK-1): the pre-fix code
        // stamped loadedAt whenever hasData — but the
        // fallback catalogue list makes hasData true even
        // when every rail fetch died, which then made
        // loadIfNeeded no-op for 15 minutes and stranded the
        // error surface's Retry. loadedAt is now stamped ONLY
        // at the two landing sites above, so a load in which
        // nothing landed leaves it nil and the next entry (or
        // reload()) fetches again.
    }
}
