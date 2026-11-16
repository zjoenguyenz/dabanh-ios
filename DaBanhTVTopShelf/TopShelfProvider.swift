import Foundation
import TVServices

// Đá Banh TV Top Shelf extension (Package C — v1.3.3).
//
// DaBanhTVTopShelf/TopShelfProvider.swift (its own app-extension
// target, bundle com.luun.nguyen.dabanhtv.topshelf, extension
// point com.apple.tv-top-shelf). Applied from
// tvos-training/topshelf-staging for Package C (v1.3.3).
//
// The owner's spec: the shelf background is Manchester United's
// 2007–08 glory — the Moscow 2008 Champions League win and the
// 2007–08 Premier League title. FIVE bundled photos (owner:
// "Tầm 5 hình nó random là đc" — random rotation is fine), all
// leader-sourced and visually verified:
//   mu-shelf-1.jpg (1212×708) Ronaldo kissing the C1 trophy
//   mu-shelf-2.jpg (1200×675) Van der Sar + team, FINAL 2008
//   mu-shelf-3.jpg (890×530)  squad on the podium, confetti
//   mu-shelf-4.jpg (960×711)  Premier League trophy celebration
//   mu-shelf-5.jpg (802×621)  Ronaldo + Ferdinand, C1 trophy
// The five JPEGs ship INSIDE this extension (listed in the
// target's sources in project.yml so XcodeGen bundles them as
// resources). No network, no App Group, no entitlements — the
// shelf works under any signing.
//
// CONTENT MODEL: ONE carousel item whose image is picked at
// random on every loadTopShelfContent call — each time the
// system asks for shelf content, one of the five photos fills
// the shelf full-bleed. (The kit's content model has no timed
// rotation; a random pick per presentation is the faithful
// shape.)
//
// API SHAPE — pinned against Apple's TVServices documentation
// (the staged draft used two symbols that do not exist in the
// SDK — Style.carousel and ImageTraits.carousel — the same
// guesses CI run 33 rejected in the Joe TV extension; the
// corrected shape below is the one that compiled there):
//   - TVTopShelfCarouselContent is the only content type whose
//     image fills the shelf full-screen: Apple's Top Shelf HIG
//     describes the carousel layouts as "a carousel of
//     full-screen video and images", while the sectioned
//     content row is "a single labeled row" of poster/square/
//     16:9 items — a row of thumbnails, not a background — so
//     it cannot express this shelf.
//   - Style has exactly two cases, .actions and .details.
//     .actions is the fit: per the HIG it "focuses on
//     full-screen video and images" and expects a title (plus
//     optional subtitle). .details EXTENDS .actions with a
//     content-information panel (plot summary, cast list and
//     other metadata) — this shelf carries no such metadata,
//     so .details would add an empty panel and nothing else.
//   - A carousel item has ONE image, registered with
//     setImageURL(_:for:). ImageTraits is an OptionSet whose
//     only documented members are the screen scales
//     .screenScale1x and .screenScale2x — the traits describe
//     the image's scale, not its role. The bundled photo is a
//     single-resolution file, so it is registered under BOTH
//     scale traits: the system picks the image whose traits
//     match the device, and this way every device matches.
// (Doc basis: TVTopShelfCarouselContent, its Style enum page,
// TVTopShelfItem + ImageTraits + setImageURL(_:for:) in
// Apple's TVServices documentation, and the Top Shelf page of
// Apple's Human Interface Guidelines.)
//
// Deep link: NONE — the DaBanhTV tree has no URL scheme and
// no .onOpenURL anywhere (verified by grep over DaBanhTV/ +
// project.yml), so the item carries no playAction/displayAction
// and selecting it simply launches the app, the system's
// default.

final class TopShelfProvider: TVTopShelfContentProvider {

    private static let imageNames = [
        "mu-shelf-1", "mu-shelf-2", "mu-shelf-3",
        "mu-shelf-4", "mu-shelf-5",
    ]

    override func loadTopShelfContent(completionHandler: @escaping (TVTopShelfContent?) -> Void) {
        // Random pick per presentation (owner-approved).
        let candidates = Self.imageNames.compactMap {
            Bundle.main.url(forResource: $0, withExtension: "jpg")
        }
        guard let pick = candidates.randomElement() else {
            completionHandler(nil)
            return
        }
        let item = TVTopShelfCarouselItem(identifier: "dabanh-mu-2008")
        item.title = "Manchester United — Champions League 2008"
        // One bundled photo, registered for both screen scales
        // (see the header note).
        item.setImageURL(pick, for: .screenScale1x)
        item.setImageURL(pick, for: .screenScale2x)
        completionHandler(TVTopShelfCarouselContent(style: .actions,
                                                    items: [item]))
    }
}
