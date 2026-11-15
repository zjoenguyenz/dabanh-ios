import Foundation

/// SourceHealth — the on-device prediction layer (owner order
/// 2026-11-15: static tuned constants are not enough; the app
/// must PREDICT per-source behaviour so switching is accurate).
/// Design and numbers: LATENCY-AUDIT.md §5 (variance structure)
/// and §6 (recommended constants), measured 2026-11-15.
///
/// WHAT THE MEASUREMENTS SAID (the shape of this component):
///   • Latency clusters by (provider × stage × host). Stages
///     differ more than providers do, and the catastrophic
///     variance lives at the individual CDN host:
///     streamvsmov subdomains are CATEGORICAL (v8/v9 answer in
///     ≈1.2 s; v1/v6 black-hole — TLS up, zero bytes, ≥45 s).
///   • Failures are BIMODAL and STICKY: a host is at its
///     healthy median or entirely absent, and a hang predicts
///     the next hang from the same host. So the failure stat
///     is a LATCH (mode detection), not a rate.
///   • Every host also breathes with the shared path (tunnel /
///     WAN): one pooled baseline is kept so a tunnel-wide
///     slow-down is not misread as every source dying at once.
///
/// WHAT IT KEEPS, per (provider × stage × host) key:
///   • a latency EWMA with a ≈10-minute half-life;
///   • a consecutive-timeout counter feeding the latch:
///     ≥2 consecutive timeouts (3 while the path baseline is
///     degraded — see latchThresholdLocked) demote the key for
///     15 minutes; the next call after the window is a single
///     re-probe — an answering outcome (success OR a fast
///     failure like a 404: the host is alive, just refusing)
///     clears the latch, a timeout re-latches it.
///
/// HOST GRANULARITY (audit §5.4): streamvsmov at SUBDOMAIN
/// level; blogcdn.site / tiktokcdn.com / kvp726.com at domain
/// level (subdomains rotate per title); KK per API host;
/// everything else at registrable-domain level.
///
/// CONSUMERS (wired in the clients / Providers / JoeProxy):
///   (a) Stage fuses are dynamic: fuse =
///       clamp(max(3×EWMA, EWMA + 4 s), floor 6 s, cap) where
///       cap is the tuned constant from the audit for that
///       stage. The dynamic value may only TIGHTEN within the
///       cap, never exceed it; a key with no data uses the cap.
///   (b) Ladder / candidate ordering: keys currently latched
///       sort AFTER unlatched ones (Providers.ladderFor server
///       order, Providers.findAlternatives provider order).
///   (c) The player watchdogs (20 s pre-ready, 12 s mid-play)
///       stay CONSTANT this round — the predictor does not
///       move them.
///
/// COLD START: the audit medians are seeded as priors at LOW
/// weight (n = 3 pseudo-samples), so a handful of real plays
/// on the owner's own network overrules them — mandatory,
/// because the audit ran from a VM vantage the apps never
/// see. KK's playlist/segment stages deliberately get NO
/// prior: from the VM those hosts only ever showed the
/// geo-wall 404 artefact, and that artefact must not convict
/// KK on-device.
///
/// Persistence: one JSON snapshot in UserDefaults, capped at
/// 128 keys with least-recently-seen eviction. This type makes
/// no network calls of its own and has no UI.
enum SourceHealth {
    enum Stage: String {
        case detail, resolve, playlist, segment
        /// Catalogue (list/search) calls — added in 1.9.2
        /// (Team 9 item 2): pre-fix, list calls had NO health
        /// memory at all, so a dead provider's 17 launch jobs
        /// re-burned their full 12 s caps on every load. The
        /// list stage gives them the same fuse + latch
        /// machinery as every other stage (cap 12 at the call
        /// sites — the clients' existing listTimeout).
        case list
    }

    enum Outcome {
        case success
        /// The call burned its whole fuse without an answer —
        /// the hang class, the only slow failure in the system.
        case timeout
        /// The host ANSWERED with a failure (404/5xx/parse):
        /// fast evidence the host is alive (audit §5.3).
        case instantFail
    }

    /// Provider key for the torrent side's Torrentio list call.
    /// The torrent family has no Providers code (it is not a
    /// Phim provider); its stats live under this key.
    static let torrentProvider = "torrent"

    // MARK: - Tuning constants (audit §5.4 / §6)

    /// EWMA half-life: healthy medians were stable over
    /// ≈35 min but the shared path moved within ≈50 min.
    private static let halfLife: TimeInterval = 600
    /// Demotion window after a latch, before the re-probe.
    private static let latchWindow: TimeInterval = 900
    /// Fuse floor: no stage fuse ever drops below 6 s.
    private static let fuseFloor: TimeInterval = 6
    /// Prior weight: audit medians count as ≈3 samples.
    private static let priorWeight: Double = 3
    /// EWMA effective-weight cap, so a long session cannot
    /// make the stat sluggish against fresh evidence.
    private static let weightCap: Double = 20
    private static let maxKeys = 128
    private static let defaultsKey = "source_health_v1"
    /// The pooled baseline's cold prior: the mean of the
    /// seeded priors below (≈1.51 s). The latch threshold
    /// rises only when the LIVE baseline exceeds 2× this.
    private static let baselinePrior: Double = 1.51

    /// Cold-start priors, keyed "provider|stage|hostKey" —
    /// the LATENCY-AUDIT §1 medians (round 1, VM vantage).
    /// Provider codes are the Providers constants' values
    /// ("kk" / "f4k" / "vsmov" / "tp"); host keys follow
    /// hostKey(for:) below, so a prior only ever lands on the
    /// exact key the runtime will look up.
    private static let priors: [String: Double] = [
        // VSMOV (§1.2): detail on the API host; playlist and
        // segment on the streamvsmov family; the resolve prior
        // only on the subdomains MEASURED healthy (v8/v9) —
        // unprobed subdomains start unknown, at the cap.
        "vsmov|detail|vsmov.com": 1.26,
        "vsmov|resolve|v8.streamvsmov.com": 1.20,
        "vsmov|resolve|v9.streamvsmov.com": 1.20,
        "vsmov|playlist|v8.streamvsmov.com": 1.21,
        "vsmov|playlist|v9.streamvsmov.com": 1.21,
        "vsmov|segment|p25.streamvsmov.com": 1.20,
        // Film4K (§1.3): the ≈5.1 s full chain spread across
        // its stage boundaries (detail / playlists on
        // film4k.net / segments on the TikTok CDN).
        "f4k|detail|film4k.net": 1.16,
        "f4k|playlist|film4k.net": 1.19,
        "f4k|segment|tiktokcdn.com": 1.76,
        // Tủ Phim (§1.4): the ≈7.3 s Gold chain.
        "tp|detail|phimsrv.com": 1.44,
        "tp|resolve|phimsrv.com": 1.33,
        "tp|playlist|blogcdn.site": 1.84,
        "tp|segment|blogcdn.site": 2.68,
        // CacheVideo resolver (§1.5), recorded under TP — the
        // provider whose details carry it.
        "tp|resolve|q-1208.fun": 3.57,
        // Torrentio stream list (§1.6).
        "torrent|resolve|strem.fun": 1.0,
        // KKPhim API detail (§1.1), per API host. NO stream-
        // stage priors for KK — see the header note.
        "kk|detail|phimapi.com": 0.90,
        "kk|detail|free.cryboiz.workers.dev": 1.58,
    ]

    // MARK: - Host keys

    /// The stats key's host component for a URL, at the
    /// granularity where behaviour actually splits (header).
    static func hostKey(for urlString: String) -> String {
        guard let host = URL(string: urlString)?.host?.lowercased(),
              !host.isEmpty else { return "" }
        // streamvsmov splits categorically by subdomain.
        if host == "streamvsmov.com" || host.hasSuffix(".streamvsmov.com") {
            return host
        }
        // Rotating-subdomain families behave as one host.
        for family in ["blogcdn.site", "tiktokcdn.com", "kvp726.com"] {
            if host == family || host.hasSuffix("." + family) { return family }
        }
        // KK per API host. The workers.dev host must stay
        // whole: its registrable domain is a shared public
        // suffix that would merge every tenant on it.
        if host == "phimapi.com" || host == "free.cryboiz.workers.dev" {
            return host
        }
        // Everything else at registrable-domain level.
        let labels = host.split(separator: ".")
        return labels.count > 2 ? labels.suffix(2).joined(separator: ".") : host
    }

    private static func key(provider: String, stage: Stage, url: String) -> String? {
        let host = hostKey(for: url)
        return host.isEmpty ? nil : "\(provider)|\(stage.rawValue)|\(host)"
    }

    // MARK: - Recording

    /// Record one finished call. `seconds` is the call's
    /// measured wall time; for a timeout that is ≈ the fuse
    /// it burned, which is the honest sample for a hang.
    static func record(provider: String, stage: Stage, url: String,
                       seconds: Double, outcome: Outcome) {
        guard let key = key(provider: provider, stage: stage, url: url) else { return }
        let now = Date().timeIntervalSince1970
        lock.lock()
        ensureLoadedLocked()
        let isNew = snap.keys[key] == nil
        var st = snap.keys[key] ?? KeyState()
        blendLocked(&st, seconds: seconds, now: now)
        var latchChanged = false
        switch outcome {
        case .success, .instantFail:
            // An answering host is not in its hang mode.
            if st.latchedUntil != 0 { latchChanged = true }
            st.consecTimeouts = 0
            st.latchedUntil = 0
        case .timeout:
            st.consecTimeouts += 1
            if st.consecTimeouts >= latchThresholdLocked(now: now) {
                st.latchedUntil = now + latchWindow
                latchChanged = true
            }
        }
        snap.keys[key] = st
        blendBaselineLocked(seconds: seconds, now: now)
        if isNew { evictLocked(now: now) }
        saveLocked(force: latchChanged)
        lock.unlock()
    }

    /// The measured-call wrapper the clients use: computes
    /// the stage fuse, runs the operation with it, records
    /// the outcome. Cancellation is NOT evidence about the
    /// source (a race loser, a view going away) and is never
    /// recorded.
    ///
    /// CONVERGENCE (Team 6 census A8, 2026-11-15): the budget
    /// is now enforced HERE, not merely handed to the callee.
    /// Pre-fix this wrapper only passed the number into op —
    /// the call's real worst case was whatever op's own
    /// enforcement happened to be. Now op runs in an
    /// unstructured task publishing into a lock-guarded box,
    /// raced against a budget timer task (the findAlternatives
    /// pattern): whichever lands first decides, the loser is
    /// cancelled and NEVER awaited, so an op that ignores its
    /// budget cannot hold the caller past it. A budget expiry
    /// throws URLError(.timedOut) and records .timeout with
    /// the elapsed ≈ budget — the same evidence the old
    /// URLSession-driven timeout produced.
    static func run<T>(provider: String, stage: Stage, url: String,
                       cap: TimeInterval,
                       _ op: @escaping (TimeInterval) async throws -> T) async throws -> T {
        let budget = fuse(provider: provider, stage: stage, url: url, cap: cap)
        let start = Date()
        let box = RunRaceBox<T>()
        let opTask = Task {
            do {
                box.complete(try await op(budget))
            } catch {
                box.fail(error)
            }
        }
        let timerTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0, budget) * 1_000_000_000))
            box.expire()
        }
        defer {
            opTask.cancel()
            timerTask.cancel()
        }
        while true {
            if let outcome = box.outcome {
                switch outcome {
                case .value(let value):
                    record(provider: provider, stage: stage, url: url,
                           seconds: Date().timeIntervalSince(start), outcome: .success)
                    return value
                case .error(let error):
                    if error is CancellationError { throw error }
                    if let urlError = error as? URLError, urlError.code == .cancelled {
                        throw error
                    }
                    let mapped: Outcome =
                        (error as? URLError)?.code == .timedOut ? .timeout : .instantFail
                    record(provider: provider, stage: stage, url: url,
                           seconds: Date().timeIntervalSince(start), outcome: mapped)
                    throw error
                case .expired:
                    record(provider: provider, stage: stage, url: url,
                           seconds: Date().timeIntervalSince(start), outcome: .timeout)
                    throw URLError(.timedOut)
                }
            }
            if Task.isCancelled {
                throw CancellationError()
            }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    // MARK: - Consumers

    /// Consumer (a): the dynamic stage fuse. No data → the
    /// tuned cap itself. Otherwise the audit formula, which
    /// may only tighten within the cap.
    static func fuse(provider: String, stage: Stage, url: String,
                     cap: TimeInterval) -> TimeInterval {
        guard let key = key(provider: provider, stage: stage, url: url) else { return cap }
        lock.lock()
        ensureLoadedLocked()
        let ewma = snap.keys[key]?.ewma
        lock.unlock()
        guard let ewma else { return cap }
        let raw = max(3 * ewma, ewma + 4)
        return min(max(raw, fuseFloor), cap)
    }

    /// True while the key's demotion window is live. An
    /// EXPIRED latch reads false: the key is in its re-probe
    /// state and the next recorded call decides it.
    static func isLatched(provider: String, stage: Stage, url: String) -> Bool {
        guard let key = key(provider: provider, stage: stage, url: url) else { return false }
        lock.lock()
        ensureLoadedLocked()
        let until = snap.keys[key]?.latchedUntil ?? 0
        lock.unlock()
        return until > Date().timeIntervalSince1970
    }

    /// Consumer (b) at provider granularity: any live latch
    /// under this provider (any stage, any host).
    static func providerDemoted(_ provider: String) -> Bool {
        lock.lock()
        ensureLoadedLocked()
        let now = Date().timeIntervalSince1970
        let prefix = provider + "|"
        let demoted = snap.keys.contains {
            $0.key.hasPrefix(prefix) && $0.value.latchedUntil > now
        }
        lock.unlock()
        return demoted
    }

    // MARK: - Store (lock-guarded; every entry point above
    // already holds the lock when calling these)

    private struct KeyState: Codable {
        var ewma: Double? = nil
        var weight: Double = 0
        var consecTimeouts: Int = 0
        var latchedUntil: Double = 0
        var lastSeen: Double = 0
    }

    private struct Snapshot: Codable {
        var keys: [String: KeyState] = [:]
        var baselineEWMA: Double? = nil
        var baselineWeight: Double = 0
        var baselineLast: Double = 0
    }

    private static let lock = NSLock()
    private static var snap = Snapshot()
    private static var didLoad = false
    private static var lastSave: Double = 0

    private static func ensureLoadedLocked() {
        guard !didLoad else { return }
        didLoad = true
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode(Snapshot.self, from: data) {
            snap = decoded
        }
        // Seed priors only where the device has no state of
        // its own — on-device evidence always wins.
        for (k, v) in priors where snap.keys[k] == nil {
            var st = KeyState()
            st.ewma = v
            st.weight = priorWeight
            snap.keys[k] = st
        }
    }

    private static func saveLocked(force: Bool) {
        let now = Date().timeIntervalSince1970
        guard force || now - lastSave >= 2 else { return }
        lastSave = now
        if let data = try? JSONEncoder().encode(snap) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    /// One EWMA blend with the ≈10-minute half-life: the
    /// older the previous sample, the less its weight counts.
    private static func blendLocked(_ st: inout KeyState, seconds: Double, now: Double) {
        let dt = st.lastSeen > 0 ? now - st.lastSeen : 0
        let decay = dt > 0 ? pow(0.5, dt / halfLife) : 1.0
        let w = st.weight * decay
        if let e = st.ewma {
            st.ewma = (e * w + seconds) / (w + 1)
        } else {
            st.ewma = seconds
        }
        st.weight = min(w + 1, weightCap)
        st.lastSeen = now
    }

    private static func blendBaselineLocked(seconds: Double, now: Double) {
        let dt = snap.baselineLast > 0 ? now - snap.baselineLast : 0
        let decay = dt > 0 ? pow(0.5, dt / halfLife) : 1.0
        let w = snap.baselineWeight * decay
        if let b = snap.baselineEWMA {
            snap.baselineEWMA = (b * w + seconds) / (w + 1)
        } else {
            snap.baselineEWMA = seconds
        }
        snap.baselineWeight = min(w + 1, weightCap)
        snap.baselineLast = now
    }

    /// The latch threshold: normally 2 consecutive timeouts.
    /// It rises to 3 only when the pooled path baseline is
    /// degraded (>2× its cold prior) AND several keys are
    /// degrading together — the signature of a sick tunnel,
    /// not of dying sources (audit §5.1: the shared path is
    /// the dominant common factor). Kept deliberately
    /// minimal: no other adaptation reads the baseline.
    private static func latchThresholdLocked(now: Double) -> Int {
        guard let baseline = snap.baselineEWMA,
              baseline > 2 * baselinePrior else { return 2 }
        var degrading = 0
        for (_, st) in snap.keys
        where st.consecTimeouts >= 1 && now - st.lastSeen <= 300 {
            degrading += 1
        }
        return degrading >= 2 ? 3 : 2
    }

    private static func evictLocked(now: Double) {
        guard snap.keys.count > maxKeys else { return }
        // Least-recently-seen first; a live latch goes last.
        let candidates = snap.keys.sorted { a, b in
            let sa = a.value, sb = b.value
            let la = sa.latchedUntil > now, lb = sb.latchedUntil > now
            if la != lb { return lb }
            return sa.lastSeen < sb.lastSeen
        }
        var excess = snap.keys.count - maxKeys
        for k in candidates {
            if excess <= 0 { break }
            snap.keys[k.key] = nil
            excess -= 1
        }
    }
}

/// Lock-guarded outcome box for SourceHealth.run's budget race
/// (the findAlternatives pattern): the operation task and the
/// budget timer publish here; the FIRST outcome wins and later
/// publications are dropped, so a loser that finishes after
/// the race was decided records nothing and changes nothing.
private final class RunRaceBox<T> {
    enum Outcome {
        case value(T)
        case error(Error)
        case expired
    }

    private let lock = NSLock()
    private var result: Outcome?

    func complete(_ value: T) {
        lock.lock()
        if result == nil { result = .value(value) }
        lock.unlock()
    }

    func fail(_ error: Error) {
        lock.lock()
        if result == nil { result = .error(error) }
        lock.unlock()
    }

    func expire() {
        lock.lock()
        if result == nil { result = .expired }
        lock.unlock()
    }

    var outcome: Outcome? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}
