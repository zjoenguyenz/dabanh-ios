import Foundation

/// Club + national-team crests (TheSportsDB badges, every URL verified
/// live on 2026-11-13), shared by the iOS and tvOS apps. The
/// name→badge-URL map ships inside the app (`crests.json` in the bundle,
/// 301 normalized keys) — no runtime API calls, no key. Port of the
/// Android app's Crests.java; the master copy is `crests/crests.json`
/// in the repo and generates both.
enum Crests {

    private static let map: [String: String] = {
        guard let url = Bundle.main.url(forResource: "crests", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return dict
    }()

    /// Lowercase, diacritics stripped (đ→d), only [a-z0-9 ] kept, spaces
    /// collapsed — must produce exactly the keys the generator wrote
    /// into crests.json (same algorithm as the Android/Python side).
    static func norm(_ s: String) -> String {
        var t = s.lowercased().folding(options: [.diacriticInsensitive], locale: nil)
        t = t.replacingOccurrences(of: "đ", with: "d")
        var out = ""
        out.reserveCapacity(t.count)
        var lastWasSpace = true
        for sc in t.unicodeScalars {
            if (sc >= "a" && sc <= "z") || (sc >= "0" && sc <= "9") {
                out.unicodeScalars.append(sc)
                lastWasSpace = false
            } else if !lastWasSpace {
                out.unicodeScalars.append(" ")
                lastWasSpace = true
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Badge URL for one team name as written in a match title.
    static func url(forTeam name: String) -> URL? {
        guard let s = map[norm(name)] else { return nil }
        return URL(string: s)
    }

    /// Split a CLEANED match title "A vs B" into its two team names
    /// (port of Crests.teamsOf in the Android app).
    static func teams(ofCleanTitle title: String) -> (String, String)? {
        var s = title
        if let r = s.range(of: "(") {
            s = String(s[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        guard let re = try? NSRegularExpression(pattern: "\\s+vs\\.?\\s+", options: [.caseInsensitive]),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let full = Range(m.range, in: s)
        else { return nil }
        let a = String(s[..<full.lowerBound]).trimmingCharacters(in: .whitespaces)
        var b = String(s[full.upperBound...]).trimmingCharacters(in: .whitespaces)
        if let d = b.range(of: "•") {
            b = String(b[..<d.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        if a.isEmpty || b.isEmpty { return nil }
        return (a, b)
    }

    /// Both crests for a channel's raw playlist title; either side is
    /// nil when that team is not in the map. Returns nil when the title
    /// is not an "A vs B" fixture at all.
    static func crests(forTitle title: String) -> (URL?, URL?)? {
        guard let (a, b) = teams(ofCleanTitle: MatchTitle.clean(title)) else { return nil }
        return (url(forTeam: a), url(forTeam: b))
    }
}

/// Title helpers ported from the Android app (MainActivity.cleanTitle
/// and FixtureKey.of) so all three apps read titles the same way.
enum MatchTitle {

    private static let timePattern = "\\d{1,2}:\\d{2}\\s+\\d{1,2}/\\d{1,2}"

    /// Strip the leading "HH:mm dd/MM" kickoff stamp and the ⚽🟢🔴
    /// markers from a playlist title.
    static func clean(_ title: String) -> String {
        var s = title
        if let re = try? NSRegularExpression(pattern: timePattern),
           let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
           let r = Range(m.range, in: s),
           s.distance(from: s.startIndex, to: r.lowerBound) < 12 {
            s = String(s[r.upperBound...])
        }
        s = s.replacingOccurrences(of: "⚽", with: "")
            .replacingOccurrences(of: "🟢", with: "")
            .replacingOccurrences(of: "🔴", with: "")
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// "Same fixture" key (port of FixtureKey.of): two listings of one
    /// match on different CDNs produce the same key, so the player can
    /// line up fallback sources and the hero can count them.
    static func fixtureKey(_ title: String) -> String {
        var s = title.lowercased()
        if let re = try? NSRegularExpression(pattern: timePattern) {
            s = re.stringByReplacingMatches(
                in: s, range: NSRange(s.startIndex..., in: s), withTemplate: " ")
        }
        if let re = try? NSRegularExpression(pattern: "\\s*\\([^)]*\\)\\s*$") {
            for _ in 0..<2 {
                s = re.stringByReplacingMatches(
                    in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
            }
        }
        s = s.replacingOccurrences(of: "câu lạc bộ", with: " ")
        let stops: Set<String> = ["fc", "afc", "sc", "cf", "clb", "hd", "fhd", "sd"]
        let parts = s.components(separatedBy: CharacterSet.alphanumerics.inverted)
        let keep = parts.filter {
            !$0.isEmpty && !stops.contains($0) && !$0.allSatisfy { $0.isNumber }
        }
        return keep.joined(separator: " ")
    }
}
