import Foundation
import UIKit

// Joe TV Top Shelf — the app-side writer (Package B, v2.0.10).
//
// JoeTV/JoeTopShelfWriter.swift (JoeTV target; in the
// target's sources in project.yml). Applied from
// tvos-training/topshelf-staging for Package B (v2.0.10);
// not compile-verified until the first CI build.
//
// The Top Shelf extension (JoeTVTopShelf/TopShelfProvider.swift)
// reads what this writer produces. THIS writer is the only
// producer of the hand-off: it writes
// topshelf.json + JPEG image files into the App Group container
// (group.com.luun.nguyen.joetv). (v2.0.11: on the owner's
// device the group is unavailable under his re-signing — the
// delivered IPA is unsigned — so the provider additionally
// carries a TMDB fallback of its own for hero + hot; this
// hand-off remains the only source of Continue Watching.) Posters/backdrops are fetched
// through JoeImagePipeline (which decodes WebP via libwebp) and
// RE-ENCODED to JPEG — provider art can be WebP, and the shelf
// must never depend on the system's WebP support.
//
// Content (owner's Prime-Video spec): hero = the #1 hottest
// title's w1280 backdrop, full-bleed; then Continue Watching;
// then more hot titles. "Hottest" = TMDB trending/week order,
// resolved against the app's own catalogue (PhimStore.merged,
// matched on tmdbId) — every shelf item deep-links to a title
// the app can actually open (the deep-link rule). If trending
// fails or resolves nothing, the fallback is the catalogue's
// own first thumb-bearing titles, hero backdrop via the TMDB
// enrichment the detail screen already uses.
//
// Fail-soft like every other subsystem here: no key, no
// network, no container (App Group unavailable under the
// owner's signing) → write nothing; the extension then returns
// nil and the system shows its default shelf. No crash path.

/// The extension's JSON contract (mirror of ShelfDoc in
/// TopShelfProvider.swift — keep in sync).
private struct ShelfDoc: Codable {
    struct Item: Codable {
        var id = ""
        var title = ""
        var backdrop = ""   // file name inside the container
        var poster = ""     // file name inside the container
        var action = ""     // joetv:// deep link
        var progress: Double = -1
    }
    var version = 0
    var hero: Item?
    var continueWatching: [Item] = []
    var hot: [Item] = []
}

enum JoeTopShelfWriter {

    private static let groupID = "group.com.luun.nguyen.joetv"
    private static let docName = "topshelf.json"
    private static let minRewriteInterval: TimeInterval = 120

    /// One trending title from TMDB (popularity order kept).
    struct TrendingTitle {
        var tmdbId = ""
        var type = ""          // "movie" | "tv"
        var title = ""
        var backdropURL = ""   // w1280
        var posterURL = ""     // w500
    }

    // MARK: - Entry point

    /// Rebuild the shelf payload. Called from JoeRootView's
    /// launch task (force = false) and whenever the CW store
    /// changes (force = true). Cheap when throttled: a stat of
    /// the existing doc is the only work.
    ///
    /// @MainActor (run-34 fix): the body reads PhimStore.merged
    /// and PhimStore is a @MainActor store, so the writer's
    /// entry point carries the same isolation. Both call sites
    /// (JoeTVApp's .task and its .onChange-spawned Task) already
    /// run on the main actor and already await this call — the
    /// annotation costs no hop and changes no behaviour.
    @MainActor
    static func refresh(watch: WatchStore, phim: PhimStore,
                        force: Bool = false) async {
        guard let container = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: groupID)
        else { return }   // App Group unavailable — inert.

        let docURL = container.appendingPathComponent(docName)
        if !force,
           let attrs = try? FileManager.default
                .attributesOfItem(atPath: docURL.path),
           let mtime = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(mtime) < minRewriteInterval {
            return
        }

        // -- Hot list: TMDB trending resolved into the catalogue.
        var hero: ShelfDoc.Item?
        var hot: [ShelfDoc.Item] = []
        let trending = await TMDBClient.trendingWeek()
        var resolved: [(TrendingTitle, Movie)] = []
        for t in trending {
            if let m = phim.merged.first(where: {
                $0.tmdbId == t.tmdbId &&
                ($0.tmdbType.isEmpty || $0.tmdbType == t.type)
            }) {
                resolved.append((t, m))
            }
            if resolved.count >= 9 { break }
        }
        if let first = resolved.first {
            let backdrop = await writeImage(first.0.backdropURL,
                                            pixels: 1280,
                                            name: "ts-hero.jpg",
                                            into: container)
            let poster = await writeImage(first.0.posterURL,
                                          pixels: 500,
                                          name: "ts-hero-poster.jpg",
                                          into: container)
            if !backdrop.isEmpty || !poster.isEmpty {
                hero = ShelfDoc.Item(
                    id: "hot|" + first.1.id,
                    title: first.1.name,
                    backdrop: backdrop, poster: poster,
                    action: movieLink(first.1))
            }
            for (i, pair) in resolved.dropFirst().enumerated() {
                let poster = await writeImage(pair.0.posterURL,
                                              pixels: 500,
                                              name: "ts-hot-\(i).jpg",
                                              into: container)
                let backdrop = await writeImage(pair.0.backdropURL,
                                                pixels: 1280,
                                                name: "ts-hot-\(i)-bg.jpg",
                                                into: container)
                guard !poster.isEmpty || !backdrop.isEmpty else { continue }
                hot.append(ShelfDoc.Item(
                    id: "hot|" + pair.1.id,
                    title: pair.1.name,
                    backdrop: backdrop, poster: poster,
                    action: movieLink(pair.1)))
            }
        }

        // -- Fallback: the catalogue's own order (the app's
        // editorial first titles), when trending gave nothing.
        if hero == nil {
            let thumbs = phim.merged.filter { !$0.thumb.isEmpty }
            if let first = thumbs.first {
                var backdropURL = first.thumb
                if !first.tmdbId.isEmpty,
                   let info = await TMDBClient.fetchInfo(
                       tmdbId: first.tmdbId, type: first.tmdbType),
                   !info.backdropURL.isEmpty {
                    backdropURL = info.backdropURL
                }
                let backdrop = await writeImage(backdropURL,
                                                pixels: 1280,
                                                name: "ts-hero.jpg",
                                                into: container)
                let poster = await writeImage(first.poster,
                                              pixels: 500,
                                              name: "ts-hero-poster.jpg",
                                              into: container)
                if !backdrop.isEmpty || !poster.isEmpty {
                    hero = ShelfDoc.Item(
                        id: "hot|" + first.id,
                        title: first.name,
                        backdrop: backdrop, poster: poster,
                        action: movieLink(first))
                }
                for (i, m) in thumbs.dropFirst().prefix(8).enumerated() {
                    let poster = await writeImage(m.poster,
                                                  pixels: 500,
                                                  name: "ts-hot-\(i).jpg",
                                                  into: container)
                    guard !poster.isEmpty else { continue }
                    hot.append(ShelfDoc.Item(
                        id: "hot|" + m.id,
                        title: m.name,
                        backdrop: "", poster: poster,
                        action: movieLink(m)))
                }
            }
        }

        // -- Continue Watching (the store's own order, newest
        // first; both provider and torrent entries).
        var cw: [ShelfDoc.Item] = []
        for (i, e) in watch.progress().prefix(10).enumerated() {
            let poster = await writeImage(e.poster,
                                          pixels: 500,
                                          name: "ts-cw-\(i).jpg",
                                          into: container)
            let backdrop = e.background.isEmpty ? "" :
                await writeImage(e.background,
                                 pixels: 1280,
                                 name: "ts-cw-\(i)-bg.jpg",
                                 into: container)
            guard !poster.isEmpty || !backdrop.isEmpty else { continue }
            let action: String
            if e.kind == WatchStore.kindTor {
                action = torrentLink(e)
            } else {
                action = movieLink(provider: e.source, slug: e.slug,
                                   name: e.title, poster: e.poster,
                                   year: e.year, ep: e.ep)
            }
            guard !action.isEmpty else { continue }
            cw.append(ShelfDoc.Item(
                id: "cw|" + e.key,
                title: e.title,
                backdrop: backdrop, poster: poster,
                action: action,
                progress: e.fraction))
        }

        guard hero != nil || !cw.isEmpty || !hot.isEmpty else { return }

        let doc = ShelfDoc(version: 1, hero: hero,
                           continueWatching: cw, hot: hot)
        guard let data = try? JSONEncoder().encode(doc) else { return }
        try? data.write(to: docURL, options: .atomic)
        pruneStaleImages(in: container, keeping: doc)
    }

    // MARK: - Deep links (joetv:// — parsed by JoeRootView's
    // .onOpenURL handler; see the apply notes)

    private static func movieLink(_ m: Movie) -> String {
        movieLink(provider: m.provider, slug: m.slug, name: m.name,
                  poster: m.poster, year: m.year, ep: "")
    }

    private static func movieLink(provider: String, slug: String,
                                  name: String, poster: String,
                                  year: String, ep: String) -> String {
        guard !provider.isEmpty, !slug.isEmpty else { return "" }
        var c = URLComponents()
        c.scheme = "joetv"
        c.host = "movie"
        c.queryItems = [
            URLQueryItem(name: "provider", value: provider),
            URLQueryItem(name: "slug", value: slug),
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "poster", value: poster),
            URLQueryItem(name: "year", value: year),
            URLQueryItem(name: "ep", value: ep),
        ]
        return c.url?.absoluteString ?? ""
    }

    /// Torrent CW entries rebuild their TorMeta on the app
    /// side, so the link carries the meta's fields verbatim
    /// (the same fields WatchStore.Entry already stores).
    private static func torrentLink(_ e: WatchStore.Entry) -> String {
        guard !e.metaId.isEmpty else { return "" }
        var c = URLComponents()
        c.scheme = "joetv"
        c.host = "torrent"
        c.queryItems = [
            URLQueryItem(name: "id", value: e.metaId),
            URLQueryItem(name: "type", value: e.metaType),
            URLQueryItem(name: "name", value: e.title),
            URLQueryItem(name: "poster", value: e.poster),
            URLQueryItem(name: "background", value: e.background),
            URLQueryItem(name: "year", value: e.year),
            URLQueryItem(name: "desc", value: e.desc),
            URLQueryItem(name: "base", value: e.metaBase),
            URLQueryItem(name: "stream", value: e.streamId),
        ]
        return c.url?.absoluteString ?? ""
    }

    // MARK: - Images

    /// Fetch through the app pipeline (WebP-safe), re-encode
    /// to JPEG, write into the container. Returns the file
    /// NAME (not a path) or "" on any failure.
    private static func writeImage(_ urlString: String, pixels: Int,
                                   name: String, into dir: URL) async -> String {
        guard !urlString.isEmpty, let url = URL(string: urlString),
              let img = await JoeImagePipeline.shared.image(
                  for: url, targetPixels: pixels),
              let data = img.jpegData(compressionQuality: 0.82)
        else { return "" }
        do {
            try data.write(to: dir.appendingPathComponent(name),
                           options: .atomic)
            return name
        } catch {
            return ""
        }
    }

    /// Remove ts-*.jpg files the current doc no longer
    /// references, so the container cannot grow stale art.
    private static func pruneStaleImages(in dir: URL, keeping doc: ShelfDoc) {
        var keep = Set<String>()
        for item in [doc.hero].compactMap({ $0 }) + doc.continueWatching + doc.hot {
            keep.insert(item.backdrop)
            keep.insert(item.poster)
        }
        let files = (try? FileManager.default
            .contentsOfDirectory(atPath: dir.path)) ?? []
        for f in files where f.hasPrefix("ts-") && f.hasSuffix(".jpg")
            && !keep.contains(f) {
            try? FileManager.default.removeItem(
                at: dir.appendingPathComponent(f))
        }
    }
}

// MARK: - TMDB trending (the writer's hot source)

extension TMDBClient {
    /// Trending this week, TMDB's own popularity order —
    /// movie + tv mixed, exactly the chart the owner's "phim
    /// hot nhất" points at. Fail-soft: [] on no key / failure.
    /// (Lives in this file — same module as TMDBClient.swift
    /// proper.)
    static func trendingWeek() async -> [JoeTopShelfWriter.TrendingTitle] {
        let key = apiKey
        guard !key.isEmpty else { return [] }
        guard let root = try? await JoeHTTP.getJSON(
            "https://api.themoviedb.org/3/trending/all/week?api_key=\(key)&language=vi-VN",
            timeout: 8)
        else { return [] }
        var out: [JoeTopShelfWriter.TrendingTitle] = []
        for item in JSON.arr(root, "results") ?? [] {
            let type = JSON.str(item, "media_type")
            guard type == "movie" || type == "tv" else { continue }
            let backdrop = JSON.str(item, "backdrop_path")
            let poster = JSON.str(item, "poster_path")
            guard !backdrop.isEmpty else { continue }
            var t = JoeTopShelfWriter.TrendingTitle()
            t.tmdbId = JSON.str(item, "id")
            t.type = type
            t.title = JSON.str(item, type == "tv" ? "name" : "title")
            t.backdropURL = "https://image.tmdb.org/t/p/w1280" + backdrop
            t.posterURL = poster.isEmpty
                ? "" : "https://image.tmdb.org/t/p/w500" + poster
            out.append(t)
        }
        return out
    }
}
