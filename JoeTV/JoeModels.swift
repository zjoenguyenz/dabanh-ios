import Foundation

/// Shared movie shapes for the Joe TV Phim library — a direct port
/// of the Android app's KkApi.Movie / Detail / Server / Episode
/// (verified on device in Joe TV Android v1.5.1). Every provider
/// client maps its API onto these shapes so rails, search, detail
/// and the player are provider-agnostic; the provider code travels
/// WITH the movie because aggregation moves titles from several
/// providers through one rail.

struct Movie: Identifiable, Hashable, Codable {
    var name = ""
    var slug = ""
    var originName = ""
    var poster = ""
    /// Landscape art (KK's thumb_url; VS's poster_url — the
    /// VS field names are swapped vs content, see VsClient),
    /// kept apart from the portrait poster: the detail
    /// screen's full-width backdrop strip shows it instantly,
    /// before the TMDB backdrop lands.
    var thumb = ""
    var year = ""
    var type = ""
    var episodeCurrent = ""
    var quality = ""
    var lang = ""
    /// List-payload extras the KK/VS catalogues already carry
    /// (UI-6 defect D-2): genre names, country, runtime and the
    /// total episode count. The Billboard hero's full meta line,
    /// genres line and "Tập x / y tập" are built from these.
    /// Additive + tolerant: payloads lacking them (Film4K, Tủ
    /// Phim) simply leave the defaults, and every older parse
    /// path is unchanged.
    var categories: [String] = []
    var country = ""
    var time = ""
    var episodeTotal = ""
    /// KK/VS theatrical flag (owner source-priority policy,
    /// 2026-11-15 — IN v2.0.0 per the owner's 16:08 ruling):
    /// the payloads carry a `chieurap` bool on every item;
    /// the Auto source rule reads it (with the single-type
    /// signal) to recognise US theatrical films. Additive +
    /// tolerant like the fields above.
    var chieurap = false
    /// Tủ Phim extras (parity with the Android KkApi.Movie):
    /// the IMDb id keys the CacheVideo probe on TP details.
    var imdbId = ""
    var tmdbId = ""
    var tmdbType = ""
    var tmdbSeason = 0
    /// "kk" | "f4k" | "vsmov" | "tp" (see Providers).
    var provider = ""

    var id: String { provider + "|" + slug }
    var posterURL: URL? { poster.isEmpty ? nil : URL(string: poster) }
    var thumbURL: URL? { thumb.isEmpty ? nil : URL(string: thumb) }

    /// Short card meta line: year · episode/quality fragments.
    var cardMeta: String {
        var parts: [String] = []
        let y = Providers.yearOf(year)
        if !y.isEmpty { parts.append(y) }
        if !episodeCurrent.isEmpty { parts.append(episodeCurrent) }
        return parts.joined(separator: " · ")
    }
}

struct Episode: Hashable, Codable {
    var name = ""
    var m3u8 = ""
    var embed = ""
}

struct Server: Hashable, Codable {
    var name = ""
    var episodes: [Episode] = []
}

/// Codable (v2.0.1) so the detail payload can ride the disk
/// cache (JoeDetailCache) — the shapes are plain value types,
/// so the conformance is synthesized and changes no parsing.
struct Detail: Codable {
    var movie = Movie()
    var content = ""
    var metaLine = ""
    var categories = ""
    var servers: [Server] = []
}

/// v1.5.1 null guard (ported from the Android clients): a JSON null
/// that arrives as the literal text "null", and blanks, are missing
/// data — normalize to "" so joined display lines omit the field
/// instead of ever printing "null".
func cleanField(_ s: String) -> String {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return (t.isEmpty || t.lowercased() == "null") ? "" : s
}

/// Join display parts, dropping blanks and literal "null"s.
func joinParts(_ parts: [String], _ sep: String) -> String {
    parts.filter {
        let t = $0.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && t.lowercased() != "null"
    }.joined(separator: sep)
}

/// Strip the small HTML the catalogues embed in descriptions.
func stripHTML(_ html: String) -> String {
    var s = html.replacingOccurrences(of: "<[^>]*>", with: " ",
                                      options: .regularExpression)
    s = s.replacingOccurrences(of: "&nbsp;", with: " ")
        .replacingOccurrences(of: "&amp;", with: "&")
        .replacingOccurrences(of: "&quot;", with: "\"")
        .replacingOccurrences(of: "&#39;", with: "'")
    return s.replacingOccurrences(of: "\\s+", with: " ",
                                   options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Loose JSON field readers — the provider APIs are parsed exactly
/// like the Android org.json code (optString/optInt semantics:
/// numbers stringify, missing/null become the fallback).
enum JSON {
    static func str(_ obj: [String: Any]?, _ key: String, _ fallback: String = "") -> String {
        guard let obj, let v = obj[key], !(v is NSNull) else { return fallback }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return fallback
    }

    static func int(_ obj: [String: Any]?, _ key: String, _ fallback: Int = 0) -> Int {
        guard let obj, let v = obj[key], !(v is NSNull) else { return fallback }
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String { return Int(s) ?? fallback }
        return fallback
    }

    static func double(_ obj: [String: Any]?, _ key: String, _ fallback: Double = 0) -> Double {
        guard let obj, let v = obj[key], !(v is NSNull) else { return fallback }
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) ?? fallback }
        return fallback
    }

    static func bool(_ obj: [String: Any]?, _ key: String, _ fallback: Bool = false) -> Bool {
        guard let obj, let v = obj[key], !(v is NSNull) else { return fallback }
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.boolValue }
        return fallback
    }

    static func obj(_ obj: [String: Any]?, _ key: String) -> [String: Any]? {
        obj?[key] as? [String: Any]
    }

    static func arr(_ obj: [String: Any]?, _ key: String) -> [[String: Any]]? {
        guard let a = obj?[key] as? [Any] else { return nil }
        return a.compactMap { $0 as? [String: Any] }
    }
}
