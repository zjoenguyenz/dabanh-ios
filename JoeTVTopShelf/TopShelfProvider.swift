import Foundation
import TVServices

// Joe TV Top Shelf extension (Package B — v2.0.10; fallback
// added v2.0.11).
//
// JoeTVTopShelf/TopShelfProvider.swift (its own
// app-extension target, bundle com.luun.nguyen.joetv.topshelf,
// extension point com.apple.tv-top-shelf). Applied from
// tvos-training/topshelf-staging for Package B (v2.0.10).
//
// CONTENT SOURCES, in order:
// 1. The App Group hand-off (the full owner spec): the Joe TV
//    app writes topshelf.json + JPEG image files into the App
//    Group container (group.com.luun.nguyen.joetv) via
//    JoeTopShelfWriter; this provider reads that container and
//    builds hero + Continue Watching + hot. No network, no
//    shared code with the app target — the JSON schema below
//    IS the contract (versioned; keep the two copies in sync:
//    this file and JoeTV/JoeTopShelfWriter.swift).
// 2. The self-sufficient fallback (v2.0.11 — the fix for the
//    owner's "Lỗi backdrop ko hiện cho JoeTV"): the delivered
//    IPA is UNSIGNED (build-joetv.yml builds with
//    CODE_SIGNING_ALLOWED=NO) and the owner re-signs it
//    himself, so no App Group entitlement for
//    group.com.luun.nguyen.joetv can be provisioned into the
//    installed app — containerURL(...) returns nil in BOTH
//    processes on his device and source 1 is dead there
//    (device-proven: the shelf was completely empty while
//    Đá Banh TV's group-free shelf worked). When no usable
//    group doc exists, this provider therefore fetches TMDB
//    trending itself, downloads the artwork into its OWN
//    caches directory (no group needed) and builds hero +
//    hot from that. Continue Watching lives only in the app's
//    sandbox, so it can only ever arrive via source 1 — the
//    fallback carries hero + hot, which is the part the owner
//    reported missing. Fallback items deep-link as
//    joetv://tmdb?id=… (the app resolves the id against its
//    own catalogue on open; see JoeRootView.handleDeepLink).
//
// CONTENT MODEL (owner's Prime-Video spec, verbatim intent):
// the shelf background is the hottest movie's backdrop,
// full-bleed, and the whole shelf is ONE carousel: hero
// (hot #1) first, then Continue Watching, then more hot
// titles. Every item deep-links (joetv://) to ITS OWN title
// in the app — never a generic landing.
//
// API SHAPE — pinned against Apple's TVServices documentation
// after CI run 33 rejected the staged guesses (there is no
// Style.carousel and no ImageTraits.carousel in the SDK):
//   - TVTopShelfCarouselContent.Style has exactly two cases:
//     .actions and .details. The Prime shape is .actions:
//     full-bleed art with the item's title and its Play /
//     More Info buttons, driven by the item's playAction and
//     displayAction. (.details would render a metadata panel
//     — summary/genre/duration — that the JSON contract does
//     not carry.)
//   - A carousel item has ONE image, registered with
//     setImageURL(_:for:). ImageTraits is an OptionSet whose
//     only documented members are the screen scales
//     .screenScale1x and .screenScale2x — the traits describe
//     the image's scale, not its role. The writer produces a
//     single-resolution file per item, so the same file is
//     registered under BOTH scale traits: the system picks
//     the image whose traits match the device, and this way
//     every device matches. The item's backdrop (16:9) is the
//     image; the poster is only the fallback when no backdrop
//     file exists.
//   - Both buttons carry the item's own deep link: playAction
//     (the primary Play button) and displayAction (More Info /
//     selecting the item) are the same TVTopShelfAction.
//   - The CW progress fraction in the JSON has no carousel
//     rendering in this API and stays unused here, exactly as
//     in the staged version.
// (Doc basis: TVTopShelfCarouselContent, its Style enum page,
// TVTopShelfItem + ImageTraits + setImageURL(_:for:), and
// TVTopShelfAction in Apple's TVServices documentation.)

/// The writer's JSON contract (mirror of ShelfDoc in
/// JoeTopShelfWriter.swift — keep in sync). The fallback path
/// writes the same shape into the extension's own caches, so
/// one builder serves both sources.
private struct ShelfDoc: Codable {
    struct Item: Codable {
        var id = ""
        var title = ""
        var backdrop = ""   // file name inside the container
        var poster = ""     // file name inside the container
        var action = ""     // joetv:// deep link
        var progress: Double = -1   // 0...1 CW fraction; -1 = none
    }
    var version = 0
    var hero: Item?
    var continueWatching: [Item] = []
    var hot: [Item] = []
}

final class TopShelfProvider: TVTopShelfContentProvider {

    private static let groupID = "group.com.luun.nguyen.joetv"
    private static let fallbackDocName = "topshelf-fallback.json"
    /// A fetched fallback doc is reused for half an hour, so
    /// repeated shelf loads are instant and TMDB is not
    /// hammered every time the owner passes the icon.
    private static let fallbackMaxAge: TimeInterval = 1800
    private static let fetchTimeout: TimeInterval = 6

    override func loadTopShelfContent(completionHandler: @escaping (TVTopShelfContent?) -> Void) {
        // Source 1 — the App Group hand-off (hero + CW + hot).
        if let container = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier:
                                Self.groupID),
           let doc = Self.readDoc(
                container.appendingPathComponent("topshelf.json")),
           let content = Self.content(from: doc, base: container) {
            completionHandler(content)
            return
        }
        // Source 2 — the self-sufficient fallback (hero + hot).
        // Reached whenever the group is unavailable under the
        // owner's signing, or the writer has not produced a
        // usable doc yet.
        loadFallback(completionHandler: completionHandler)
    }

    // MARK: - Doc reading + content building (both sources)

    private static func readDoc(_ url: URL) -> ShelfDoc? {
        guard let data = try? Data(contentsOf: url),
              let doc = try? JSONDecoder().decode(ShelfDoc.self,
                                                  from: data),
              doc.version == 1
        else { return nil }
        return doc
    }

    /// Build the carousel for a doc whose image files live in
    /// `base` (the App Group container for source 1, the
    /// extension's caches for source 2). Nil when the doc
    /// yields no item with a loadable image.
    private static func content(from doc: ShelfDoc,
                                base: URL) -> TVTopShelfContent? {
        func carouselItem(_ item: ShelfDoc.Item) -> TVTopShelfCarouselItem? {
            guard !item.action.isEmpty else { return nil }
            let ci = TVTopShelfCarouselItem(identifier: item.id)
            ci.title = item.title
            // The backdrop is the item's image: in the carousel
            // it is the full-bleed background (the owner's
            // Prime shape). Poster is the fallback if the
            // backdrop file is missing. One file, registered
            // for both screen scales (see the header note).
            let backdropURL = base.appendingPathComponent(item.backdrop)
            let posterURL = base.appendingPathComponent(item.poster)
            if !item.backdrop.isEmpty,
               FileManager.default.fileExists(atPath: backdropURL.path) {
                ci.setImageURL(backdropURL, for: .screenScale1x)
                ci.setImageURL(backdropURL, for: .screenScale2x)
            } else if !item.poster.isEmpty,
                      FileManager.default.fileExists(atPath: posterURL.path) {
                ci.setImageURL(posterURL, for: .screenScale1x)
                ci.setImageURL(posterURL, for: .screenScale2x)
            } else {
                return nil
            }
            if let url = URL(string: item.action) {
                // .actions style: the Play button fires
                // playAction, More Info / selection fires
                // displayAction. Both open this item's own
                // title in the app (the deep-link rule).
                let action = TVTopShelfAction(url: url)
                ci.playAction = action
                ci.displayAction = action
            }
            return ci
        }

        var items: [TVTopShelfCarouselItem] = []
        if let hero = doc.hero, let ci = carouselItem(hero) {
            items.append(ci)
        }
        items += doc.continueWatching.compactMap(carouselItem)
        items += doc.hot.compactMap(carouselItem)
        // De-duplicate by identifier, hero order preserved (a
        // title can be both hot and in CW).
        var seen = Set<String>()
        items = items.filter { seen.insert($0.identifier).inserted }

        guard !items.isEmpty else { return nil }
        return TVTopShelfCarouselContent(style: .actions,
                                         items: items)
    }

    // MARK: - Fallback: TMDB trending, fetched by the extension

    private func loadFallback(completionHandler: @escaping (TVTopShelfContent?) -> Void) {
        guard let cacheDir = FileManager.default
                .urls(for: .cachesDirectory, in: .userDomainMask).first
        else {
            completionHandler(nil)
            return
        }
        let docURL = cacheDir.appendingPathComponent(Self.fallbackDocName)
        // Fresh cached fallback — no network at all.
        if let attrs = try? FileManager.default
                .attributesOfItem(atPath: docURL.path),
           let mtime = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(mtime) < Self.fallbackMaxAge,
           let doc = Self.readDoc(docURL),
           let content = Self.content(from: doc, base: cacheDir) {
            completionHandler(content)
            return
        }
        Self.fetchFallbackDoc(into: cacheDir) { doc in
            guard let doc else {
                // No key, no network, no trending — return nil
                // and the system shows its default shelf. Never
                // crash, never fabricate content.
                completionHandler(nil)
                return
            }
            completionHandler(Self.content(from: doc, base: cacheDir))
        }
    }

    /// Fetch TMDB trending/week (the writer's hot source, same
    /// endpoint and language), download the artwork as JPEG
    /// files into `dir` (TMDB serves JPEG natively — no
    /// re-encode, unlike provider art in the writer), persist
    /// the doc next to the images, and hand it back. Nil on
    /// any failure. Bounded: one list request + at most 12
    /// image downloads, each on a short timeout.
    private static func fetchFallbackDoc(
        into dir: URL,
        completion: @escaping (ShelfDoc?) -> Void
    ) {
        let key = TMDBShelfKey.value
        guard !key.isEmpty,
              let url = URL(string: "https://api.themoviedb.org/3/trending/all/week?api_key=\(key)&language=vi-VN")
        else {
            completion(nil)
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = fetchTimeout
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data,
                  let root = try? JSONSerialization
                    .jsonObject(with: data) as? [String: Any],
                  let results = root["results"] as? [[String: Any]]
            else {
                completion(nil)
                return
            }
            // Trending order kept; only titles with a backdrop
            // can ever be a shelf image.
            struct Candidate {
                var tmdbId = ""
                var type = ""
                var title = ""
                var backdropPath = ""
                var posterPath = ""
            }
            var candidates: [Candidate] = []
            for item in results {
                let type = item["media_type"] as? String ?? ""
                guard type == "movie" || type == "tv" else { continue }
                let backdrop = item["backdrop_path"] as? String ?? ""
                guard !backdrop.isEmpty else { continue }
                var c = Candidate()
                if let n = item["id"] as? NSNumber {
                    c.tmdbId = n.stringValue
                } else if let s = item["id"] as? String {
                    c.tmdbId = s
                }
                guard !c.tmdbId.isEmpty else { continue }
                c.type = type
                c.title = (item[type == "tv" ? "name" : "title"]
                           as? String) ?? ""
                c.backdropPath = backdrop
                c.posterPath = item["poster_path"] as? String ?? ""
                candidates.append(c)
                if candidates.count >= 6 { break }
            }
            guard let first = candidates.first else {
                completion(nil)
                return
            }

            // Download the artwork. Hero takes the backdrop +
            // poster; each hot title takes its backdrop (its
            // poster rides along as the builder's fallback).
            let group = DispatchGroup()
            let lock = NSLock()
            var files: [String: String] = [:]   // name -> name, once written
            func download(_ path: String, as name: String) {
                guard !path.isEmpty,
                      let u = URL(string: "https://image.tmdb.org/t/p/"
                                    + (name.contains("poster")
                                       ? "w500" : "w1280") + path)
                else { return }
                group.enter()
                var req = URLRequest(url: u)
                req.timeoutInterval = fetchTimeout
                URLSession.shared.dataTask(with: req) { d, _, _ in
                    defer { group.leave() }
                    guard let d,
                          (try? d.write(
                            to: dir.appendingPathComponent(name),
                            options: .atomic)) != nil
                    else { return }
                    lock.lock()
                    files[name] = name
                    lock.unlock()
                }.resume()
            }
            func names(for c: Candidate, tag: String)
                -> (backdrop: String, poster: String) {
                let backdrop = "ts-fb-\(tag).jpg"
                let poster = "ts-fb-\(tag)-poster.jpg"
                download(c.backdropPath, as: backdrop)
                download(c.posterPath, as: poster)
                return (backdrop, poster)
            }
            var plan: [(Candidate, String, String)] = []
            let heroNames = names(for: first, tag: "hero")
            plan.append((first, heroNames.backdrop, heroNames.poster))
            for (i, c) in candidates.dropFirst().enumerated() {
                let n = names(for: c, tag: "hot-\(i)")
                plan.append((c, n.backdrop, n.poster))
            }

            group.notify(queue: .global()) {
                func item(_ c: Candidate, backdrop: String,
                          poster: String) -> ShelfDoc.Item? {
                    let b = files[backdrop] ?? ""
                    let p = files[poster] ?? ""
                    guard !b.isEmpty || !p.isEmpty else { return nil }
                    return ShelfDoc.Item(
                        id: "tmdb|" + c.tmdbId,
                        title: c.title,
                        backdrop: b, poster: p,
                        action: tmdbLink(id: c.tmdbId, type: c.type,
                                         name: c.title))
                }
                guard let hero = item(plan[0].0, backdrop: plan[0].1,
                                      poster: plan[0].2)
                else {
                    completion(nil)
                    return
                }
                let hot = plan.dropFirst().compactMap {
                    item($0.0, backdrop: $0.1, poster: $0.2)
                }
                let doc = ShelfDoc(version: 1, hero: hero,
                                   continueWatching: [], hot: hot)
                if let data = try? JSONEncoder().encode(doc) {
                    try? data.write(
                        to: dir.appendingPathComponent(fallbackDocName),
                        options: .atomic)
                }
                completion(doc)
            }
        }.resume()
    }

    /// Fallback deep link: the app resolves the TMDB id
    /// against its own catalogue on open (the extension has
    /// no catalogue access, so it cannot mint provider/slug
    /// links the way the writer does). Parsed by the "tmdb"
    /// host case in JoeRootView.handleDeepLink.
    private static func tmdbLink(id: String, type: String,
                                 name: String) -> String {
        var c = URLComponents()
        c.scheme = "joetv"
        c.host = "tmdb"
        c.queryItems = [
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "type", value: type),
            URLQueryItem(name: "name", value: name),
        ]
        return c.url?.absoluteString ?? ""
    }
}
