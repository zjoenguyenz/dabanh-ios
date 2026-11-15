import SwiftUI
import ImageIO
import UIKit

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

final class JoeImagePipeline: @unchecked Sendable {
    static let shared = JoeImagePipeline()

    private let session: URLSession
    private let decoded = NSCache<NSString, UIImage>()
    private let lock = NSLock()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

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
    func prefetch(_ urls: [URL], targetPixels: Int) {
        let bucket = Self.bucket(forPixels: targetPixels)
        for url in urls {
            let k = key(url, bucket)
            if decoded.object(forKey: k as NSString) != nil { continue }
            lock.lock()
            if inFlight[k] == nil {
                inFlight[k] = Task.detached(priority: .background) {
                    let img = await Self.load(url: url, bucket: bucket,
                                              session: self.session, decoded: self.decoded)
                    self.removeInFlight(k)
                    return img
                }
            }
            lock.unlock()
        }
    }

    private func removeInFlight(_ key: String) {
        lock.lock()
        inFlight.removeValue(forKey: key)
        lock.unlock()
    }

    private static func load(url: URL, bucket: Int, session: URLSession,
                             decoded: NSCache<NSString, UIImage>) async -> UIImage? {
        var request = URLRequest(url: url)
        request.cachePolicy = .returnCacheDataElseLoad
        request.timeoutInterval = 30
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false,
              let image = decode(data, maxPixel: bucket) else { return nil }
        let cost = image.cgImage.map { $0.width * $0.height * 4 } ?? 0
        decoded.setObject(image, forKey: "\(url.absoluteString)|\(bucket)" as NSString, cost: cost)
        return image
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
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return UIImage(cgImage: cg)
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
struct JoeRemoteImage<Placeholder: View>: View {
    let url: URL?
    var targetPixels: Int = 480
    /// Logos and other non-poster art letterbox instead of cropping.
    var fit: Bool = false
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var loaded: UIImage?

    var body: some View {
        ZStack {
            if let image = loaded ?? JoeImagePipeline.shared.cachedImage(for: url, targetPixels: targetPixels) {
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
            loaded = await JoeImagePipeline.shared.image(for: url, targetPixels: targetPixels)
        }
    }
}
