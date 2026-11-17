import Foundation
import TVServices

// Joe TV Top Shelf extension (Package B — v2.0.10; fallback
// added v2.0.11; fallback REBUILT on bundled assets v2.0.12).
//
// JoeTVTopShelf/TopShelfProvider.swift (its own
// app-extension target, bundle com.luun.nguyen.joetv.topshelf,
// extension point com.apple.tv-top-shelf).
//
// CONTENT SOURCES, in order:
// 1. The App Group hand-off (the full owner spec, UNCHANGED):
//    the Joe TV app writes topshelf.json + JPEG image files
//    into the App Group container
//    (group.com.luun.nguyen.joetv) via JoeTopShelfWriter; this
//    provider reads that container and builds hero + Continue
//    Watching + hot. No network, no shared code with the app
//    target — the JSON schema below IS the contract
//    (versioned; keep the two copies in sync: this file and
//    JoeTV/JoeTopShelfWriter.swift). On the owner's device
//    this source is dead — the delivered IPA is built
//    UNSIGNED (CODE_SIGNING_ALLOWED=NO) and re-signed by him,
//    so containerURL(...) returns nil in both processes —
//    which is why source 2 exists.
// 2. The BUNDLED fallback (v2.0.12): shelf-manifest.json +
//    one backdrop JPEG per entry ship INSIDE this extension
//    (JoeTVTopShelf/bundled/, listed in the target's sources
//    in project.yml so XcodeGen bundles them as resources,
//    exactly like Đá Banh TV's mu-shelf-*.jpg). Entry 1 of
//    the manifest is the recommended hero (TMDB
//    trending/all/week #1 at manifest generation time); the
//    remaining entries are SHUFFLED on every
//    loadTopShelfContent call, so the shelf shows the
//    recommended title's backdrop first plus a few random
//    titles after it (owner's redo spec, verbatim: "làm lại
//    backdrop làm sao nó hiện lên phim đề cử và hiện lên vài
//    phim random"). Every item deep-links joetv://tmdb?id=…
//    to its own title. If the manifest is missing or empty
//    the provider returns nil — never fabricate content.
//
// WHY BUNDLED (the v2.0.11 root cause, device-proven): the
// v2.0.11 fallback fetched TMDB trending in the extension
// and downloaded backdrop JPEGs into the extension's OWN
// Caches directory, then handed the system file URLs inside
// that private sandbox. On the owner's device the shelf
// items DID appear (titles + deep links worked, the Apple
// default shelf was gone) but the backdrop image NEVER
// rendered. The control case on the same device — Đá Banh
// TV's shelf, same .actions style, same both-scales
// registration — renders fine, and its only differing
// variable is that its JPEGs are BUNDLED inside the appex
// (Bundle.main URLs). The shelf UI is rendered by a system
// process outside the extension's sandbox; Apple's own Top
// Shelf guidance puts shelf images in the shared container
// for the same reason. With no App Group available under
// the owner's signing, the bundle is the only proven-
// readable image location. Full audit:
// tvos-training/TOPSHELF-2012-AUDIT.md.
//
// DECISION — the runtime TMDB fetch is REMOVED, not kept:
// its downloaded images are exactly what did not render, it
// depended on the embedded key + network inside a
// short-lived extension, and a bundled manifest cannot pair
// a live-fetched title with a bundled image unless the title
// was frozen into the manifest at generation time anyway.
// Freshness is traded for the one image path proven to
// render on the owner's device; the manifest is regenerated
// when a new build is cut. (TMDBShelfKey.swift is therefore
// no longer referenced by this provider.)
//
// CONTENT MODEL (owner's Prime-Video spec, verbatim intent):
// the shelf background is the hottest movie's backdrop,
// full-bleed, and the whole shelf is ONE carousel: hero
// (recommended) first, then the rest. Every item
// deep-links (joetv://) to ITS OWN title in the app — never
// a generic landing.
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
//     the image's scale, not its role. A single-resolution
//     file per item is registered under BOTH scale traits:
//     the system picks the image whose traits match the
//     device, and this way every device matches.
//   - Both buttons carry the item's own deep link: playAction
//     (the primary Play button) and displayAction (More Info /
//     selecting the item) are the same TVTopShelfAction.
//   - The CW progress fraction in the JSON has no carousel
//     rendering in this API and stays unused here.
// (Doc basis: TVTopShelfCarouselContent, its Style enum page,
// TVTopShelfItem + ImageTraits + setImageURL(_:for:), and
// TVTopShelfAction in Apple's TVServices documentation.)

/// The writer's JSON contract (mirror of ShelfDoc in
/// JoeTopShelfWriter.swift — keep in sync). Source 1 only.
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

/// One entry of the bundled shelf-manifest.json (source 2).
/// Entry order in the file is TMDB trending/all/week order
/// at generation time; entry 1 is the recommended hero.
private struct BundledEntry: Codable {
    var tmdbId = ""
    var type = ""       // "movie" | "tv"
    var title = ""
    var image = ""      // bundled JPEG file name, e.g. shelf-1.jpg
}

final class TopShelfProvider: TVTopShelfContentProvider {

    private static let groupID = "group.com.luun.nguyen.joetv"

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
        // Source 2 — the bundled manifest (recommended hero +
        // shuffled random titles). Reached whenever the group
        // is unavailable under the owner's signing, or the
        // writer has not produced a usable doc yet.
        completionHandler(Self.bundledContent())
    }

    // MARK: - Source 1: doc reading + content building

    private static func readDoc(_ url: URL) -> ShelfDoc? {
        guard let data = try? Data(contentsOf: url),
              let doc = try? JSONDecoder().decode(ShelfDoc.self,
                                                  from: data),
              doc.version == 1
        else { return nil }
        return doc
    }

    /// Build the carousel for a doc whose image files live in
    /// `base` (the App Group container). Nil when the doc
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

    // MARK: - Source 2: bundled manifest (v2.0.12)

    /// Build the carousel from the bundled shelf-manifest.json
    /// + bundled backdrop JPEGs (the proven-readable image
    /// location — see the header note). Item 1 is the
    /// manifest's first entry (the recommended hero); the
    /// remaining entries are shuffled per call ("vài phim
    /// random"). Nil when the manifest is missing/empty or no
    /// entry has a loadable bundled image — never fabricate.
    private static func bundledContent() -> TVTopShelfContent? {
        guard let manifestURL = Bundle.main.url(
                forResource: "shelf-manifest", withExtension: "json"),
              let data = try? Data(contentsOf: manifestURL),
              let entries = try? JSONDecoder().decode(
                [BundledEntry].self, from: data),
              !entries.isEmpty
        else { return nil }

        func carouselItem(_ entry: BundledEntry)
            -> TVTopShelfCarouselItem? {
            guard !entry.tmdbId.isEmpty else { return nil }
            let name = (entry.image as NSString)
                .deletingPathExtension
            let ext = (entry.image as NSString).pathExtension
            guard !name.isEmpty, !ext.isEmpty,
                  let imageURL = Bundle.main.url(forResource: name,
                                                 withExtension: ext)
            else { return nil }
            let ci = TVTopShelfCarouselItem(
                identifier: "tmdb|" + entry.tmdbId)
            ci.title = entry.title
            // One bundled file, registered for both screen
            // scales — the exact shape of the working Đá Banh
            // provider.
            ci.setImageURL(imageURL, for: .screenScale1x)
            ci.setImageURL(imageURL, for: .screenScale2x)
            if let url = URL(string: tmdbLink(id: entry.tmdbId,
                                              type: entry.type,
                                              name: entry.title)) {
                let action = TVTopShelfAction(url: url)
                ci.playAction = action
                ci.displayAction = action
            }
            return ci
        }

        var items: [TVTopShelfCarouselItem] = []
        // Recommended hero first (manifest entry 1)…
        if let hero = entries.first, let ci = carouselItem(hero) {
            items.append(ci)
        }
        // …then the remaining titles in random order.
        items += entries.dropFirst().shuffled()
            .compactMap(carouselItem)
        // De-duplicate by identifier, hero order preserved.
        var seen = Set<String>()
        items = items.filter { seen.insert($0.identifier).inserted }

        guard !items.isEmpty else { return nil }
        return TVTopShelfCarouselContent(style: .actions,
                                         items: items)
    }

    /// Deep link: the app resolves the TMDB id against its
    /// own catalogue on open (the extension has no catalogue
    /// access, so it cannot mint provider/slug links the way
    /// the writer does). Parsed by the "tmdb" host case in
    /// JoeRootView.handleDeepLink.
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
