import Foundation

/// Club + national-team crests (TheSportsDB badges, every URL verified
/// live on 2026-11-13), shared by the iOS and tvOS apps. The
/// name→badge-URL map ships inside the app (`crests.json` in the
/// bundle) as the offline baseline, and the store refreshes it from
/// the owner's GitHub mirror at launch — a team missing from the map
/// (Moldova and Kazakhstan on 2026-11-13) is then fixed by pushing
/// one JSON file, never by rebuilding the app. Port of the Android
/// app's Crests.java; the master copy is `crests/crests.json` in the
/// repo and generates both.
enum Crests {

    /// The live-updating copy, republished with the playlist mirror.
    static let remoteURL = URL(string: "https://raw.githubusercontent.com/zjoenguyenz/dabanh-playlist/main/crests.json")!

    private static var cachedRemoteURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("crests-remote.json")
    }

    private static func decode(_ data: Data) -> [String: String]? {
        guard let dict = try? JSONDecoder().decode([String: String].self, from: data),
              dict.count >= 100
        else { return nil }
        return dict
    }

    private static func loadMap() -> [String: String] {
        if let data = try? Data(contentsOf: cachedRemoteURL),
           let dict = decode(data) {
            return dict
        }
        guard let url = Bundle.main.url(forResource: "crests", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let dict = decode(data)
        else { return [:] }
        return dict
    }

    private(set) static var map: [String: String] = loadMap()

    /// Fetch the mirror's crests.json; when it differs from what the
    /// app is using, cache it for the next launch and swap it in for
    /// this one. Returns true when the map changed.
    @MainActor
    static func refreshRemote() async -> Bool {
        guard let (data, _) = try? await URLSession.shared.data(from: remoteURL),
              let dict = decode(data),
              dict != map
        else { return false }
        try? data.write(to: cachedRemoteURL, options: .atomic)
        map = dict
        return true
    }

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
    /// Lookup tries a chain of candidate keys, exact first, because the
    /// listings decorate team names heavily (owner's live-test photos,
    /// 2026-11-13: "Tây Ban Nha U21" and "U21 Đan Mạch" showed no
    /// crests although Spain and Denmark are in the map):
    /// 1. the name as written (after the ĐTQG-prefix strip below),
    /// 2. with age markers removed — "u21" tokens anywhere, or a
    ///    split "u" + "21" pair ("U-21"),
    /// 3. with a trailing "nu" (Nữ, women's) token removed,
    /// 4. with a trailing "w" (Women in English listings) removed,
    /// 5. with a leading "nu", or a trailing reserve marker
    ///    ("reserve" / "reserves" / "b"), removed.
    /// Vietnamese listings often prefix national teams with "ĐTQG"
    /// (đội tuyển quốc gia) or its long forms — those prefixes are
    /// stripped from every candidate, same rule as Android Crests.of.
    static func url(forTeam name: String) -> URL? {
        for key in candidateKeys(forTeam: name) {
            if let s = map[key] {
                return URL(string: s)
            }
        }
        return nil
    }

    private static func candidateKeys(forTeam name: String) -> [String] {
        var base = norm(name)
        // Pure-decoration prefixes listings put in front of national
        // teams: "ĐTQG" and its long forms "Đội tuyển (bóng đá) quốc
        // gia" — e.g. "Đội tuyển bóng đá quốc gia Kenya".
        for prefix in ["dtqg ", "doi tuyen bong da quoc gia ", "doi tuyen quoc gia ",
                       "doi tuyen qg ", "doi tuyen "] {
            if base.hasPrefix(prefix) {
                base = String(base.dropFirst(prefix.count))
                break
            }
        }
        var keys = [base]
        let noAge = stripAgeTokens(base)
        if noAge != base, !keys.contains(noAge) {
            keys.append(noAge)
        }
        for variant in [dropTrailingToken(noAge, "nu"), dropTrailingToken(base, "nu"),
                        dropTrailingToken(noAge, "w"), dropTrailingToken(base, "w"),
                        dropLeadingToken(noAge, "nu"), dropLeadingToken(base, "nu"),
                        dropTrailingToken(noAge, "reserve"),
                        dropTrailingToken(noAge, "reserves"),
                        dropTrailingToken(noAge, "b")] {
            if !variant.isEmpty, !keys.contains(variant) {
                keys.append(variant)
            }
        }
        return keys
    }

    /// Remove youth-age markers from a normalised key: a glued "u21"
    /// token anywhere in the name, or a split "u" + "21" pair. The
    /// digit guard keeps real names safe (e.g. "u cluj" is untouched).
    private static func stripAgeTokens(_ key: String) -> String {
        let toks = key.split(separator: " ").map(String.init)
        var out: [String] = []
        var i = 0
        while i < toks.count {
            let t = toks[i]
            if t.count == 3, t.hasPrefix("u"),
               t.dropFirst().allSatisfy({ $0.isNumber }) {
                i += 1
                continue
            }
            if t == "u", i + 1 < toks.count, toks[i + 1].count == 2,
               toks[i + 1].allSatisfy({ $0.isNumber }) {
                i += 2
                continue
            }
            out.append(t)
            i += 1
        }
        return out.joined(separator: " ")
    }

    private static func dropTrailingToken(_ key: String, _ token: String) -> String {
        var toks = key.split(separator: " ").map(String.init)
        if toks.last == token {
            toks.removeLast()
        }
        return toks.joined(separator: " ")
    }

    private static func dropLeadingToken(_ key: String, _ token: String) -> String {
        var toks = key.split(separator: " ").map(String.init)
        if toks.first == token {
            toks.removeFirst()
        }
        return toks.joined(separator: " ")
    }

    /// Split a CLEANED match title "A vs B" into its two team names
    /// (port of Crests.teamsOf in the Android app). Decoration segments
    /// in "(...)" and "[...]" — "(BLV SAMURAI)", "[hls 2]" — are cut
    /// wherever they sit before splitting, and a "• BLV …" tail is cut
    /// from both sides; earlier, side B kept its "[flv]" tag and the
    /// crest lookup missed on the polluted name.
    static func teams(ofCleanTitle title: String) -> (String, String)? {
        var s = title
        for pattern in [#"\[[^\]]*\]"#, #"\([^)]*\)"#] {
            if let re = try? NSRegularExpression(pattern: pattern) {
                s = re.stringByReplacingMatches(
                    in: s, range: NSRange(s.startIndex..., in: s), withTemplate: " ")
            }
        }
        guard let re = try? NSRegularExpression(pattern: "\\s+vs\\.?\\s+", options: [.caseInsensitive]),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let full = Range(m.range, in: s)
        else { return nil }
        func side(_ raw: Substring) -> String {
            var t = String(raw)
            if let d = t.range(of: "•") {
                t = String(t[..<d.lowerBound])
            }
            return t.trimmingCharacters(in: .whitespaces)
        }
        let a = side(s[..<full.lowerBound])
        let b = side(s[full.upperBound...])
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
