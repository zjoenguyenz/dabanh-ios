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
