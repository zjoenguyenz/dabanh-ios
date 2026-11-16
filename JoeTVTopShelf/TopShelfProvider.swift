import Foundation
import TVServices

// Joe TV Top Shelf extension (Package B — v2.0.10).
//
// JoeTVTopShelf/TopShelfProvider.swift (its own
// app-extension target, bundle com.luun.nguyen.joetv.topshelf,
// extension point com.apple.tv-top-shelf). Applied from
// tvos-training/topshelf-staging for Package B (v2.0.10);
// not compile-verified until the first CI build.
//
// The extension is a pure reader: the Joe TV app writes
// topshelf.json + JPEG image files into the App Group container
// (group.com.luun.nguyen.joetv) via JoeTopShelfWriter; this
// provider only reads that container and builds content. No
// network, no shared code with the app target — the JSON schema
// below IS the contract (versioned; keep the two copies in
// sync: this file and JoeTV/JoeTopShelfWriter.swift).
//
// CONTENT MODEL (owner's Prime-Video spec, verbatim intent):
// the shelf background is the hottest movie's backdrop,
// full-bleed. Within the kit that is the CAROUSEL style — the
// only style whose focused item's backdrop fills the shelf —
// so the whole shelf is one TVTopShelfCarouselContent: hero
// (hot #1) first, then Continue Watching, then more hot
// titles. Every item carries a joetv:// display action that
// opens ITS OWN title in the app (the deep-link rule: never a
// generic landing). NOTE for the leader: the Package B design
// note also named TVTopShelfSectionedContent for CW/hot — one
// loadTopShelfContent call returns ONE content object, so
// carousel-vs-sectioned is an either/or; carousel is used
// because it is the only full-bleed-backdrop style. If the
// sectioned shape is preferred at apply time, the reader below
// already carries everything it needs (progress included).
//
// [UNVERIFIED — no compiler/SDK in this environment] Every
// TVServices signature in this file is from the documented
// API shape and MUST be pinned against the tvOS SDK headers
// on the first CI build (the house pattern: spelling-level
// fixes would be mechanical):
//   - TVTopShelfContentProvider.loadTopShelfContent(completionHandler:)
//   - TVTopShelfCarouselContent(style:items:)
//   - TVTopShelfCarouselItem(identifier:), .title,
//     .setImageURL(_:for:) with ImageTraits.carousel,
//     .displayAction = TVTopShelfAction(url:)
//   - file:// image URLs into the shared group container.

/// The writer's JSON contract (mirror of ShelfDoc in
/// JoeTopShelfWriter.swift — keep in sync).
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

    override func loadTopShelfContent(completionHandler: @escaping (TVTopShelfContent?) -> Void) {
        guard let container = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier:
                                "group.com.luun.nguyen.joetv"),
              let data = try? Data(contentsOf:
                container.appendingPathComponent("topshelf.json")),
              let doc = try? JSONDecoder().decode(ShelfDoc.self, from: data),
              doc.version == 1
        else {
            // No writer output yet (first run, or the App Group
            // is unavailable under the owner's signing) — return
            // nil and the system shows its default shelf. Never
            // crash, never fabricate content.
            completionHandler(nil)
            return
        }

        func carouselItem(_ item: ShelfDoc.Item) -> TVTopShelfCarouselItem? {
            guard !item.action.isEmpty else { return nil }
            let ci = TVTopShelfCarouselItem(identifier: item.id)
            ci.title = item.title
            // The backdrop is the carousel image: focused, it
            // fills the shelf full-bleed (the owner's Prime
            // shape). Poster is the fallback slot if the
            // backdrop file is missing.
            let backdropURL = container.appendingPathComponent(item.backdrop)
            let posterURL = container.appendingPathComponent(item.poster)
            if !item.backdrop.isEmpty,
               FileManager.default.fileExists(atPath: backdropURL.path) {
                ci.setImageURL(backdropURL, for: .carousel)
            } else if !item.poster.isEmpty,
                      FileManager.default.fileExists(atPath: posterURL.path) {
                ci.setImageURL(posterURL, for: .carousel)
            } else {
                return nil
            }
            if let url = URL(string: item.action) {
                ci.displayAction = TVTopShelfAction(url: url)
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

        guard !items.isEmpty else {
            completionHandler(nil)
            return
        }
        completionHandler(TVTopShelfCarouselContent(style: .carousel,
                                                    items: items))
    }
}
