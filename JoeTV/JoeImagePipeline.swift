import SwiftUI
import ImageIO
import UIKit
import libwebp

// MARK: - Joe TV image pipeline (Team UI-5, per UI-1 Part B)
//
// Replaces AsyncImage on every poster/logo/photo path:
//  - app-owned URLSession, 8 connections per host (the system default of 6
//    and AsyncImage's shared session were part of the measured slowness)
//  - in-flight dedupe: one network task per (URL, size bucket), shared by
//    every view asking for it; a view disappearing NEVER cancels the load —
//    the task lives in the pipeline, so the poster is cached for the next
//    appearance instead of restarting
//  - explicit URLCache use: the session is configured with URLCache.shared
//    (the 64 MB / 512 MB "joetv-images" cache installed in JoeTVApp.init)
//    and every request uses .returnCacheDataElseLoad, so a cached poster
//    renders on cold open with no network wait
//  - decoded-bitmap NSCache (~120 MB cost cap): decoded posters are kept
//    downscaled, never as full-size originals (a 2000×3000 poster is
//    ~24 MB decoded — it is decoded ONCE at display size via ImageIO)
//  - rail-ordered prefetch: PhimStore warms each rail's posters as the rail
//    lands (rails land in home order, so the next rail is always warming
//    while the owner reads the current one); the root warms Continue
//    Watching / favourites posters at launch.
//  - v2.0.2 (P1): loads retry transient failures with a bounded
//    policy (a single failure no longer fossilises a placeholder
//    for a view's life), and prefetch drains through a
//    3-worker cap instead of one detached task per URL.

final class JoeImagePipeline: @unchecked Sendable {
    static let shared = JoeImagePipeline()

    private let session: URLSession
    private let decoded = NSCache<NSString, UIImage>()
    private let lock = NSLock()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    /// Prefetch backlog + running-worker count (v2.0.2, P1),
    /// both guarded by `lock`. See prefetch(_:targetPixels:).
    private var prefetchBacklog: [(url: URL, bucket: Int, key: String)] = []
    private var prefetchActive = 0
    /// How many prefetch-originated loads may be inside the
    /// network at once. The session allows 8 connections per
    /// host; capping warm-up at 3 leaves the rest of the pool
    /// to the loads the owner is actually looking at.
    private static let prefetchWorkers = 3

    private init() {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 8
        config.urlCache = URLCache.shared
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        session = URLSession(configuration: config)
        decoded.totalCostLimit = 120 * 1024 * 1024
        decoded.countLimit = 600
    }

    /// Size buckets (pixels) keep cache keys stable across call sites that
    /// ask for near-identical sizes.
    static func bucket(forPixels px: Int) -> Int {
        for b in [240, 480, 720, 960, 1440, 1920] where px <= b { return b }
        return 1920
    }

    private func key(_ url: URL, _ bucket: Int) -> String {
        "\(url.absoluteString)|\(bucket)"
    }

    /// Synchronous decoded-cache read — a warm poster is available to the
    /// view's first render, with no task hop and no network wait.
    func cachedImage(for url: URL?, targetPixels: Int) -> UIImage? {
        guard let url else { return nil }
        return decoded.object(forKey: key(url, Self.bucket(forPixels: targetPixels)) as NSString)
    }

    /// Synchronous decoded-cache read at ANY size bucket, largest
    /// first (v2.0.1 — the Android FIX4 peek, tvOS form). The band
    /// layers ask for a full-size decode, but a smaller decode of
    /// the same URL — the tapped card's 720, the header's 960 —
    /// is already on the device and can paint the band's first
    /// frame instantly; the layer's own load then upgrades it
    /// once when the full decode lands.
    func cachedImageAnySize(for url: URL?) -> UIImage? {
        guard let url else { return nil }
        for b in [1920, 1440, 960, 720, 480, 240] {
            if let hit = decoded.object(forKey: key(url, b) as NSString) {
                return hit
            }
        }
        return nil
    }

    /// TMDB poster-path resolutions for the slot fallback
    /// ladder (JoeRemoteImage): tmdbId|type → poster path,
    /// cached for the session, NEGATIVES included ("" = TMDB
    /// has no poster for this identity — a card must not
    /// re-ask on every appearance). Guarded by `lock`, like
    /// the rest of the pipeline's mutable state.
    private var tmdbPosterPaths: [String: String] = [:]

    /// The record's TMDB poster as a w500 URL (the house
    /// poster size — F4K posters already ARE TMDB w500), or
    /// nil when TMDB carries no poster for the identity.
    /// The path lookup rides TMDBClient.posterPath; the
    /// bitmap itself then loads through the normal pipeline
    /// (dedupe + both caches) at the caller's bucket.
    func tmdbPosterURL(tmdbId: String, type: String) async -> URL? {
        guard !tmdbId.isEmpty else { return nil }
        let k = "\(tmdbId)|\(type)"
        lock.lock()
        let hit = tmdbPosterPaths[k]
        lock.unlock()
        if let hit {
            return hit.isEmpty ? nil
                : URL(string: "https://image.tmdb.org/t/p/w500" + hit)
        }
        let path = await TMDBClient.posterPath(tmdbId: tmdbId, type: type)
        lock.lock()
        if tmdbPosterPaths[k] == nil { tmdbPosterPaths[k] = path ?? "" }
        lock.unlock()
        guard let path, !path.isEmpty else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w500" + path)
    }

    func image(for url: URL?, targetPixels: Int) async -> UIImage? {
        guard let url else { return nil }
        let bucket = Self.bucket(forPixels: targetPixels)
        let k = key(url, bucket)
        if let hit = decoded.object(forKey: k as NSString) { return hit }
        lock.lock()
        let task: Task<UIImage?, Never>
        if let existing = inFlight[k] {
            task = existing
        } else {
            let created = Task.detached(priority: .userInitiated) {
                let img = await Self.load(url: url, bucket: bucket,
                                          session: self.session, decoded: self.decoded)
                self.removeInFlight(k)
                return img
            }
            inFlight[k] = created
            task = created
        }
        lock.unlock()
        return await task.value
    }

    /// Fire-and-forget warm-up at background priority; shares the in-flight
    /// dedupe and both caches with visible loads.
    ///
    /// Bounded concurrency (v2.0.2, P1): pre-fix, EVERY URL
    /// spawned its own detached task at once — one rail
    /// landing pushed ~24 requests, several rails hundreds,
    /// all competing for the session's 8 per-host connections
    /// against the visible cards (HERO-FORENSICS §D). URLs
    /// now join a FIFO backlog (home order preserved across
    /// rails) drained by at most `prefetchWorkers` loads at a
    /// time. Visible loads never touch the backlog: a URL a
    /// view asks for directly starts (or joins) its own
    /// full-priority load immediately, and a backlog entry
    /// for it is dropped when its turn comes.
    func prefetch(_ urls: [URL], targetPixels: Int) {
        let bucket = Self.bucket(forPixels: targetPixels)
        lock.lock()
        for url in urls {
            let k = key(url, bucket)
            if decoded.object(forKey: k as NSString) != nil { continue }
            if inFlight[k] != nil { continue }
            if prefetchBacklog.contains(where: { $0.key == k }) { continue }
            prefetchBacklog.append((url, bucket, k))
        }
        pumpPrefetchLocked()
        lock.unlock()
    }

    /// Start backlog loads up to the worker cap. MUST be
    /// called with `lock` held. Entries already decoded or
    /// already in flight (a visible load got there first)
    /// are dropped without consuming a worker slot.
    private func pumpPrefetchLocked() {
        while prefetchActive < Self.prefetchWorkers,
              !prefetchBacklog.isEmpty {
            let item = prefetchBacklog.removeFirst()
            if decoded.object(forKey: item.key as NSString) != nil { continue }
            if inFlight[item.key] != nil { continue }
            prefetchActive += 1
            let k = item.key
            inFlight[k] = Task.detached(priority: .background) {
                let img = await Self.load(url: item.url, bucket: item.bucket,
                                          session: self.session, decoded: self.decoded)
                self.prefetchTaskFinished(k)
                return img
            }
        }
    }

    private func prefetchTaskFinished(_ key: String) {
        lock.lock()
        inFlight.removeValue(forKey: key)
        prefetchActive -= 1
        pumpPrefetchLocked()
        lock.unlock()
    }

    private func removeInFlight(_ key: String) {
        lock.lock()
        inFlight.removeValue(forKey: key)
        lock.unlock()
    }

    /// One load attempt's outcome, classified for the retry
    /// policy: a decoded image; a PERMANENT failure (an HTTP
    /// 4xx other than 429 — the CDN has no such poster, and
    /// asking again inside this view's life cannot change
    /// that); or a TRANSIENT failure (a thrown error/timeout,
    /// 429, 5xx, or an undecodable body — the truncated-
    /// transfer class), which the bounded retry may still
    /// heal.
    private enum LoadOutcome {
        case image(UIImage)
        case permanent
        case transient
    }

    private static func attempt(url: URL, bucket: Int,
                                session: URLSession) async -> LoadOutcome {
        var request = URLRequest(url: url)
        request.cachePolicy = .returnCacheDataElseLoad
        request.timeoutInterval = 30
        let fetched: (Data, URLResponse)
        do {
            fetched = try await session.data(for: request)
        } catch {
            return .transient
        }
        let (data, response) = fetched
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 429 || http.statusCode >= 500 {
                return .transient
            }
            guard (200..<300).contains(http.statusCode) else {
                return .permanent
            }
        } else {
            // Pre-P1 behaviour for a non-HTTP response was an
            // outright failure; keep it, classified permanent
            // so the retry never spins on it.
            return .permanent
        }
        guard let image = decode(data, maxPixel: bucket) else {
            return .transient
        }
        return .image(image)
    }

    /// Bounded retry (v2.0.2, P1): pre-fix, ANY load failure
    /// returned nil and the view sat on its placeholder for
    /// its entire life — one transient failure under prefetch
    /// contention fossilised an empty card (HERO-FORENSICS
    /// §D). A load now makes up to 3 attempts with short
    /// backoff (0.5 s, 1.5 s) while failures classify as
    /// transient; a permanent failure stops at once. The
    /// whole sequence lives inside the ONE in-flight task,
    /// so dedupe and cache semantics are unchanged — every
    /// view awaiting this (URL, bucket) gets the healed
    /// result, and a success is cached exactly as before.
    private static func load(url: URL, bucket: Int, session: URLSession,
                             decoded: NSCache<NSString, UIImage>) async -> UIImage? {
        let backoffs: [UInt64] = [500_000_000, 1_500_000_000]
        for i in 0...backoffs.count {
            switch await attempt(url: url, bucket: bucket, session: session) {
            case .image(let image):
                let cost = image.cgImage.map { $0.width * $0.height * 4 } ?? 0
                decoded.setObject(image, forKey: "\(url.absoluteString)|\(bucket)" as NSString, cost: cost)
                return image
            case .permanent:
                return nil
            case .transient:
                if i < backoffs.count {
                    try? await Task.sleep(nanoseconds: backoffs[i])
                }
            }
        }
        return nil
    }

    /// ImageIO thumbnail decode straight to display size — the full-size
    /// bitmap is never materialised. The thumbnail scales
    /// PROPORTIONALLY to the max-pixel bound (owner image-integrity
    /// rule): aspect ratio is preserved by construction, so no slot
    /// downstream can receive a stretched or pre-cropped bitmap.
    private static func decode(_ data: Data, maxPixel: Int) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true
        ]
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return UIImage(cgImage: cg)
        }
        // WebP fallback (v2.0.6, Team Poster): ImageIO has no
        // WebP codec, so a WebP body lands here as nil. Gated
        // on the RIFF/WEBP magic — never on a URL suffix, the
        // CDNs serve these files under opaque names — so a
        // non-WebP body keeps failing exactly as before.
        guard isWebP(data) else { return nil }
        return decodeWebP(data, maxPixel: maxPixel)
    }

    /// RIFF/WEBP magic: bytes 0–3 "RIFF", bytes 8–11 "WEBP".
    private static func isWebP(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            guard raw.count >= 12, let base = raw.baseAddress else { return false }
            let b = base.assumingMemoryBound(to: UInt8.self)
            return b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46
                && b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50
        }
    }

    /// libwebp decode for the bodies ImageIO cannot read
    /// (v2.0.6, Team Poster). Tủ Phim serves its posters
    /// ONLY as WebP (cdn.phimsrv.com — measured 2026-11-16:
    /// every variant, original and 300 alike, is .webp) and
    /// some KKPhim posters are WebP too (2 of 4 sampled the
    /// same day). Pre-fix every such slot failed the load and
    /// silently fell back to the TMDB poster — a DIFFERENT
    /// poster whose own top is cropped on Love Bound (the
    /// owner's detail-page photos, 2026-11-16: missing logo
    /// band + foreheads vs the official poster).
    ///
    /// Contract, kept as close to the ImageIO path as the C
    /// API allows: the returned bitmap's longest side is
    /// ≤ maxPixel with the aspect untouched (proportional
    /// scale — never a stretch, never a crop), so the
    /// decoded cache and the slots' aspect gates see exactly
    /// what they see for a JPEG. One honest difference:
    /// libwebp's simple API decodes at native size first, so
    /// the native bitmap exists transiently inside this call
    /// only — never cached, never returned. (The decoder
    /// config API could scale in-decoder, but its
    /// initialiser is a static-inline C function the Swift
    /// importer cannot call reliably, so it was rejected.)
    /// A sanity cap keeps a pathological file from
    /// materialising an unbounded bitmap. Any failure
    /// returns nil: the load classifies, retries and falls
    /// back exactly as it did before this path existed.
    private static func decodeWebP(_ data: Data, maxPixel: Int) -> UIImage? {
        var infoW: Int32 = 0
        var infoH: Int32 = 0
        let infoOK = data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            return WebPGetInfo(base.assumingMemoryBound(to: UInt8.self),
                               data.count, &infoW, &infoH) != 0
        }
        guard infoOK, infoW > 0, infoH > 0,
              Int64(infoW) * Int64(infoH) <= 64_000_000 else { return nil }

        var outW: Int32 = 0
        var outH: Int32 = 0
        let pixels = data.withUnsafeBytes { raw -> UnsafeMutablePointer<UInt8>? in
            guard let base = raw.baseAddress else { return nil }
            return WebPDecodeRGBA(base.assumingMemoryBound(to: UInt8.self),
                                  data.count, &outW, &outH)
        }
        guard let pixels, outW > 0, outH > 0 else { return nil }
        defer { WebPFree(pixels) }

        let w = Int(outW), h = Int(outH)
        let bytesPerRow = w * 4
        // Copy out of the libwebp buffer before it is freed:
        // the CGImage's provider retains this Data, so the
        // bitmap stays valid for the decoded cache's lifetime.
        let copy = Data(bytes: pixels, count: bytesPerRow * h)
        let space = CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let provider = CGDataProvider(data: copy as CFData),
              let full = CGImage(width: w, height: h,
                                 bitsPerComponent: 8, bitsPerPixel: 32,
                                 bytesPerRow: bytesPerRow, space: space,
                                 bitmapInfo: bitmapInfo, provider: provider,
                                 decode: nil, shouldInterpolate: true,
                                 intent: .defaultIntent) else { return nil }

        let longest = max(w, h)
        guard longest > maxPixel else { return UIImage(cgImage: full) }
        let scale = Double(maxPixel) / Double(longest)
        let tw = max(1, Int((Double(w) * scale).rounded()))
        let th = max(1, Int((Double(h) * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: tw, height: th,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: bitmapInfo.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(full, in: CGRect(x: 0, y: 0, width: tw, height: th))
        guard let scaled = ctx.makeImage() else { return nil }
        return UIImage(cgImage: scaled)
    }
}

// MARK: - Pipeline-backed image view

/// Drop-in replacement for AsyncImage. Checks the decoded cache
/// synchronously at first render (cold-open posters appear instantly when
/// warm), otherwise awaits the shared pipeline load. The load is owned by
/// the pipeline: disappearing never cancels it.
///
/// IMAGE INTEGRITY (owner rule, 2026-11-15): the pipeline's ImageIO
/// thumbnail decode scales proportionally to the size bucket — it can
/// never stretch or crop. Each slot then picks its content mode:
/// poster slots pass fit (whole poster in its exact 2:3 frame);
/// hero/backdrop slots use the default fill from the 16:9 thumb.
/// The placeholder is a painted surface, so a missing image is a
/// clean painted slot, never a broken hole.
/// The shape a slot can paint (v2.0.5 aspect gate). A slot
/// declares its class; a decoded bitmap of the WRONG shape
/// is a failed load for that slot — never painted, never
/// letterboxed into a band. This is the slot-side twin of
/// JoeBandImage's chooser, which has always branched on the
/// bitmap's own aspect; every other slot used to trust the
/// field NAME the bitmap arrived under (the Tủ Phim
/// poster/thumb name swap put a 16:9 still in every 2:3
/// card). Thresholds leave a grey zone (0.85…1.2) that only
/// .any accepts, so near-square art can't flip a gated slot
/// either way.
enum JoeImageSlotClass {
    case any
    case portrait
    case landscape

    func accepts(_ image: UIImage) -> Bool {
        let w = image.size.width, h = image.size.height
        guard w > 0, h > 0 else { return true }
        switch self {
        case .any: return true
        case .portrait: return w / h <= 0.85
        case .landscape: return w / h >= 1.2
        }
    }
}

struct JoeRemoteImage<Placeholder: View>: View {
    let url: URL?
    var targetPixels: Int = 480
    /// Logos and other non-poster art letterbox instead of cropping.
    var fit: Bool = false
    /// Aspect gate: the shape this slot can paint (default
    /// .any = the pre-gate behaviour, so untouched call sites
    /// are unchanged). A primary bitmap that fails the gate —
    /// or fails to load at all — runs the ONE-LEVEL fallback
    /// chain below instead of being displayed.
    var slotClass: JoeImageSlotClass = .any
    /// Fallback level 1a: a fixed alternate URL.
    var fallbackURL: URL? = nil
    /// Fallback level 1b: an async alternate-URL provider
    /// (the TMDB poster leg — the path lookup is cached per
    /// identity in the pipeline). Consulted only when
    /// fallbackURL is nil. The fallback bitmap must ALSO pass
    /// the gate; there is no second level — after that the
    /// placeholder paints.
    var fallbackProvider: (() async -> URL?)? = nil
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var loaded: UIImage?

    /// What paints now: the resolved bitmap, else a warm
    /// cached primary — but only when it passes the gate, so
    /// a cached wrong-shape bitmap can never flash the band
    /// for one frame before the task resolves the fallback.
    private var shown: UIImage? {
        if let loaded { return loaded }
        if let cached = JoeImagePipeline.shared.cachedImage(
               for: url, targetPixels: targetPixels),
           slotClass.accepts(cached) {
            return cached
        }
        return nil
    }

    var body: some View {
        ZStack {
            if let image = shown {
                if fit {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            loaded = nil
            loaded = await resolve()
        }
    }

    /// Primary → gate → one fallback level → gate. The first
    /// paint is never blocked on the fallback: until an
    /// accepted bitmap exists the placeholder paints, and an
    /// accepted fallback swaps in when it lands.
    private func resolve() async -> UIImage? {
        if let img = await JoeImagePipeline.shared.image(
               for: url, targetPixels: targetPixels),
           slotClass.accepts(img) {
            return img
        }
        var fb = fallbackURL
        if fb == nil { fb = await fallbackProvider?() }
        guard let fb, fb != url else { return nil }
        if let img = await JoeImagePipeline.shared.image(
               for: fb, targetPixels: targetPixels),
           slotClass.accepts(img) {
            return img
        }
        return nil
    }
}

// MARK: - Band image (v2.0.1 — Android v2.3 backdrop pipeline)

/// One image layer of a wide backdrop band (the detail band,
/// the home hero). Three behaviours, chosen by the loaded
/// bitmap's own aspect — the Android pipeline's chooser:
///
///  - LANDSCAPE art is painted as a top-anchored slice: scaled
///    to cover the band, with the visible window starting
///    `anchor` of the way down the overflow (0.16 detail band,
///    0.20 hero — the Android sliceForBand anchors). The
///    pre-fix centred fill kept only the centre slice of a
///    16:9 frame inside a 4.47:1 band, which is what cut the
///    actors' faces on the Sony; faces live in the upper
///    third, so the window opens near the top instead.
///  - PORTRAIT art (a poster is the film's only image) gets
///    the portrait treatment in .treatment mode: a blurred,
///    darkened full-bleed field of the same art, with the
///    WHOLE poster over it, fit to exactly the band height —
///    never cropped, never stretched; its foot melts through
///    the band's fade like the rest of the composite (the
///    Android FIX2 z-order rule). .blurField paints only the
///    field (the hero, whose text block owns the foreground).
///
/// First paint is the pipeline's any-size decoded cache (the
/// tapped card already decoded this poster), so the layer can
/// paint on the view's first render; its own full-size load
/// upgrades the bitmap exactly once when it lands. Until any
/// bitmap exists the layer paints nothing — the band's base
/// colour is the painted surface, never a hole.
struct JoeBandImage: View {
    let url: URL?
    var targetPixels: Int = 1920
    var anchor: CGFloat = 0.16

    enum PortraitMode { case treatment, blurField, slice }
    var portraitMode: PortraitMode = .treatment

    @State private var loaded: UIImage?

    private var image: UIImage? {
        loaded ?? JoeImagePipeline.shared.cachedImageAnySize(for: url)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let image {
                    if image.size.width >= image.size.height
                        || portraitMode == .slice {
                        slice(image, in: geo.size)
                    } else if portraitMode == .blurField {
                        field(image, in: geo.size)
                    } else {
                        field(image, in: geo.size)
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: geo.size.width,
                                   height: geo.size.height)
                    }
                }
            }
        }
        .task(id: url) {
            loaded = nil
            loaded = await JoeImagePipeline.shared.image(
                for: url, targetPixels: targetPixels)
        }
    }

    /// Cover-slice with the window anchored near the top:
    /// scale so the bitmap covers the slot, then shift it up
    /// by `anchor` × the vertical overflow (0 = the very top
    /// edge, 0.5 = the old centred slice).
    private func slice(_ image: UIImage, in size: CGSize) -> some View {
        let scale = max(size.width / image.size.width,
                        size.height / image.size.height)
        let w = image.size.width * scale
        let h = image.size.height * scale
        let overflow = max(h - size.height, 0)
        return Image(uiImage: image)
            .resizable()
            .frame(width: w, height: h)
            .offset(x: (size.width - w) / 2, y: -overflow * anchor)
    }

    /// The portrait treatment's field: the same art as a
    /// blurred, darkened full-bleed backdrop (the Android
    /// blurredBand: shrunk, blurred, darkened ~35%). The
    /// slice is computed 72 pt oversize and shifted back, so
    /// the blur's edge fringe falls outside the band's clip
    /// instead of lightening its rim.
    private func field(_ image: UIImage, in size: CGSize) -> some View {
        slice(image, in: CGSize(width: size.width + 72,
                                height: size.height + 72))
            .blur(radius: 28)
            .overlay(Color.black.opacity(0.35))
            .offset(x: -36, y: -36)
    }
}
