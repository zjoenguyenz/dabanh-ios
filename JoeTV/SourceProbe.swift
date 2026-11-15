import Foundation

/// Per-provider reachability probe for the Settings diagnostics
/// surface (owner law: a failure must be visible and explained,
/// never a silent spinner). Each provider is exercised through
/// the SAME client call the Phim home makes at launch — its
/// newest rail, racing and all — so a green probe means the
/// home's first rail for that provider really can load from
/// this device, on this network, right now: the probe matches
/// the app's runtime path instead of testing a lookalike URL.
enum SourceProbe {
    struct Result {
        var name: String
        var ok: Bool
        var millis: Int
        var note: String
    }

    /// Probe all four providers concurrently; results come back
    /// in the fixed display order KK / F4K / VS / TP.
    static func run() async -> [Result] {
        async let kk = probe(name: "KKPhim") {
            try await KkClient.newest(page: 1).count
        }
        async let f4k = probe(name: "Film4K") {
            try await F4kClient.newest(page: 1).count
        }
        async let vs = probe(name: "VSMOV") {
            try await VsClient.newest(page: 1).count
        }
        async let tp = probe(name: "Tủ Phim") {
            try await TpClient.newest(page: 1).count
        }
        return await [kk, f4k, vs, tp]
    }

    /// 1.9.2 (Team 9 item 5): single-target KK reachability
    /// for the Settings tunnel-status row, with a SHORT ~6 s
    /// fuse. KkClient.newest's own list budget is 12 s — far
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
                let count = try await KkClient.newest(page: 1).count
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
