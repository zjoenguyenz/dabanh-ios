import Foundation

/// Per-provider reachability probe for the Settings diagnostics
/// surface (owner law: a failure must be visible and explained,
/// never a silent spinner). Each provider is exercised through
/// literally the SAME call the Phim home makes at launch —
/// Providers.newest for its newest rail, via the FRESH raw
/// variant (Providers.newestFresh → fetchListRawFresh) — so a
/// green probe means the home's first rail for that provider
/// really can load from this device, on this network, right
/// now: the probe matches the app's runtime path instead of
/// testing a lookalike URL. The fresh variant is what keeps
/// the probe an honest REAL network measurement (it bypasses
/// the Providers raw memo's read); its result still lands in
/// that memo, so the launch gate's phase 2 reuses it instead
/// of fetching the same endpoints a second time (Idea 17).
enum SourceProbe {
    struct Result {
        var name: String
        var ok: Bool
        var millis: Int
        var note: String
    }

    /// Probe all four providers concurrently; results come back
    /// in the fixed display order KK / F4K / VS / TP.
    ///
    /// v2.0.22: the probes run in a task group and `onEach`
    /// fires as EACH provider answers (completion order, not
    /// display order) — the launch gate's progress bar counts
    /// those completions. Callers that pass no callback (the
    /// Settings diagnostics button) observe no change: same
    /// probes, same order, same results.
    static func run(onEach: (@Sendable (Result) -> Void)? = nil) async -> [Result] {
        await withTaskGroup(of: (Int, Result).self) { group in
            group.addTask {
                (0, await probe(name: "KKPhim") {
                    try await Providers.newestFresh(Providers.KK, page: 1).count
                })
            }
            group.addTask {
                (1, await probe(name: "Film4K") {
                    try await Providers.newestFresh(Providers.F4K, page: 1).count
                })
            }
            group.addTask {
                (2, await probe(name: "VSMOV") {
                    try await Providers.newestFresh(Providers.VS, page: 1).count
                })
            }
            group.addTask {
                (3, await probe(name: "Tủ Phim") {
                    try await Providers.newestFresh(Providers.TP, page: 1).count
                })
            }
            var landed: [(Int, Result)] = []
            for await item in group {
                landed.append(item)
                onEach?(item.1)
            }
            return landed.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
    }

    /// 1.9.2 (Team 9 item 5): single-target KK reachability
    /// for the Settings tunnel-status row, with a SHORT ~6 s
    /// fuse. The KK list call's own budget is 12 s — far
    /// too long to leave a status row spinning — so the call
    /// races a 6 s timer in the codebase's box pattern: the
    /// first outcome wins, the loser is cancelled and never
    /// awaited. The verdict is an INFERENCE by design (KK
    /// answering ⇒ the Vietnam route is reachable ⇒ the
    /// tunnel profile is likely on); the Settings copy says
    /// exactly that and nothing stronger.
    static func probeKK(timeout: TimeInterval = 6) async -> Result {
        let start = Date()
        let box = KKProbeBox()
        let fetch = Task {
            do {
                let count = try await Providers.newestFresh(Providers.KK, page: 1).count
                box.complete(count)
            } catch {
                box.fail()
            }
        }
        let timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            box.expire()
        }
        defer {
            fetch.cancel()
            timer.cancel()
        }
        while true {
            if let outcome = box.outcome {
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                switch outcome {
                case .count(let n):
                    return Result(name: "KKPhim", ok: n > 0, millis: ms,
                                  note: n > 0 ? "\(n) mục mới nhất" : "Trả về rỗng")
                case .failed, .expired:
                    return Result(name: "KKPhim", ok: false, millis: ms,
                                  note: "Không trả lời")
                }
            }
            if Task.isCancelled {
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                return Result(name: "KKPhim", ok: false, millis: ms,
                                  note: "Đã huỷ")
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private static func probe(name: String,
                              _ fetch: () async throws -> Int) async -> Result {
        let start = Date()
        do {
            let count = try await fetch()
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            return Result(name: name, ok: count > 0, millis: ms,
                          note: count > 0 ? "\(count) mục mới nhất"
                                          : "Trả về rỗng")
        } catch {
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            return Result(name: name, ok: false, millis: ms,
                          note: error.localizedDescription)
        }
    }
}

/// Lock-guarded outcome box for probeKK's fuse race (the
/// findAlternatives pattern): the fetch task and the fuse
/// timer publish here; the FIRST outcome wins and later
/// publications are dropped.
private final class KKProbeBox {
    enum Outcome {
        case count(Int)
        case failed
        case expired
    }

    private let lock = NSLock()
    private var result: Outcome?

    func complete(_ n: Int) {
        lock.lock()
        if result == nil { result = .count(n) }
        lock.unlock()
    }

    func fail() {
        lock.lock()
        if result == nil { result = .failed }
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
