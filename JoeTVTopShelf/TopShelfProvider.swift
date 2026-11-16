import Foundation
import TVServices

// Joe TV Top Shelf extension (Package B — v2.0.10).
//
// JoeTVTopShelf/TopShelfProvider.swift (its own
// app-extension target, bundle com.luun.nguyen.joetv.topshelf,
// extension point com.apple.tv-top-shelf). Applied from
// tvos-training/topshelf-staging for Package B (v2.0.10).
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
            // The backdrop is the item's image: in the carousel
            // it is the full-bleed background (the owner's
            // Prime shape). Poster is the fallback if the
            // backdrop file is missing. One file, registered
            // for both screen scales (see the header note).
            let backdropURL = container.appendingPathComponent(item.backdrop)
            let posterURL = container.appendingPathComponent(item.poster)
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

        guard !items.isEmpty else {
            completionHandler(nil)
            return
        }
        completionHandler(TVTopShelfCarouselContent(style: .actions,
                                                    items: items))
    }
}
