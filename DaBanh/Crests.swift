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

    /// The live map, behind a lock box: refreshRemote swaps it from
    /// the main actor while cards read it from wherever they render.
    /// (Swift 6 language mode: a bare mutable static var is not
    /// concurrency-safe; the box keeps every target's reads safe.)
    private final class MapBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [String: String]
        init(_ value: [String: String]) { self.value = value }
        func get() -> [String: String] {
            lock.lock(); defer { lock.unlock() }
            return value
        }
        func set(_ newValue: [String: String]) {
            lock.lock(); value = newValue; lock.unlock()
        }
    }

    private static let mapBox = MapBox(loadMap())

    private(set) static var map: [String: String] {
        get { mapBox.get() }
        set { mapBox.set(newValue) }
    }

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

/// Fixture identity, shared by the cards (FixtureEntry on iOS,
/// TVFixtureEntry on tvOS) and by the player's source ladder
/// (PlaylistStore.sources(for:)), so the two can never disagree
/// about what "the same match" means.
///
/// The 2026-11-14 redesign grouped by MatchTitle.fixtureKey +
/// exact kickoff instant, and the owner's live test that night
/// showed one match split across cards whenever sources wrote it
/// differently: reversed team order ("Latvia Vs Armenia" vs
/// "Armenia vs Latvia"), filler prefixes ("Ca Banfield" vs
/// "Banfield", "CD Tondela", "FK Chelyabinsk", "Queretaro FC"),
/// punctuation drift ("Yokohama F. Marinos" vs "Yokohama F
/// Marinos"), small stamp disagreements (the same match at 10:00
/// and 10:10) — and one La Paz vs Piratas pair whose stamps
/// disagreed by ~60 minutes while both listings were live. The
/// identity below is the fix (iOS 1.13 / tvOS 1.3.1):
///
/// - Pair key: the two team names of the cleaned title, each
///   normalised (Crests.norm, then standalone filler tokens
///   dropped), then sorted — team order never matters.
/// - Two stamped listings with the same pair key are one fixture
///   when their stamps name the same calendar date (the dd/mm as
///   written, read back from the parsed instant in ICT) and their
///   kickoffs chain within 45 minutes of each other (sorted by
///   kickoff, single-linkage from the earliest).
/// - Live merge: clusters of the same pair + date whose earliest
///   stamp is inside the live window right now merge into one
///   fixture regardless of the stamp gap; the merged fixture's
///   kickoff is its earliest stamp. (Every list the apps group is
///   sorted bucket-then-kickoff by the store, so a live-merged
///   fixture's representative — its first member in list order —
///   is that earliest-stamp member, and the cards render its
///   kickoff.)
/// - Listings this identity does not cover — no recognisable
///   pair, or no kickoff stamp — keep the previous identity
///   verbatim (fixture key + exact kickoff instant, URL when the
///   title yields no fixture key) and never merge into pair
///   fixtures.
enum FixtureGrouping {

    /// One fixture group: a stable id plus its member channels in
    /// the caller's list order (first member = representative).
    struct Group {
        let id: String
        let members: [Channel]
    }

    /// Standalone tokens dropped from team names for the pair key.
    private static let fillerTokens: Set<String> = [
        "fc", "cf", "sc", "afc", "ca", "cd", "fk", "sk",
        "club", "ac", "as", "sd", "us", "ec",
    ]

    /// How far apart two stamps of one pair + date may chain and
    /// still be read as the same fixture.
    private static let chainWindow: TimeInterval = 45 * 60

    /// Normalise one team name for the pair key: lowercase,
    /// diacritics stripped, punctuation removed, spaces collapsed
    /// (all of that is Crests.norm), then standalone filler tokens
    /// dropped — "Ca Banfield" and "Banfield" both become
    /// "banfield", "CD Tondela" becomes "tondela".
    static func normalizedTeam(_ name: String) -> String {
        Crests.norm(name)
            .split(separator: " ")
            .filter { token in
                let t = String(token)
                // Filler words, plus standalone all-numeric tokens
                // ("Sydney United 58 FC" vs "Sydney United" — the old
                // fixtureKey dropped numeric tokens too; amendment
                // 2026-11-14 after Team Swift's live-playlist sweep).
                return !fillerTokens.contains(t)
                    && !t.allSatisfy({ $0.isNumber })
            }
            .joined(separator: " ")
    }

    /// Order-independent pair key for a channel, or nil when its
    /// cleaned title has no recognisable "A vs B" pair, or a side
    /// normalises away to nothing.
    static func pairKey(of channel: Channel) -> String? {
        guard let (a, b) = Crests.teams(ofCleanTitle: MatchTitle.clean(channel.title))
        else { return nil }
        let na = normalizedTeam(a)
        let nb = normalizedTeam(b)
        guard !na.isEmpty, !nb.isEmpty else { return nil }
        return [na, nb].sorted().joined(separator: " vs ")
    }

    /// The calendar date a kickoff stamp names (the dd/mm as
    /// written), recovered by reading the parsed instant back in
    /// ICT — the parser built it from exactly those components.
    static func stampDateKey(of kickoff: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh") ?? .current
        let c = cal.dateComponents([.year, .month, .day], from: kickoff)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }

    /// Inside the live window (−10 … +125 minutes around kickoff) —
    /// the same bounds as LeagueClassifier bucket 0.
    private static func isLive(kickoff: Date, now: Date) -> Bool {
        let since = now.timeIntervalSince(kickoff)
        return since >= -10 * 60 && since <= 125 * 60
    }

    /// The pre-1.13 identity, kept verbatim for every listing the
    /// pair identity does not cover: fixture key + exact kickoff
    /// instant, URL when the title yields no fixture key.
    private static func legacyGroupKey(for ch: Channel) -> String {
        let fk = MatchTitle.fixtureKey(ch.title)
        if fk.isEmpty { return "url:" + ch.url }
        let ko = ch.kickoff.map { String(Int($0.timeIntervalSince1970)) } ?? "none"
        return "fx:" + fk + "|" + ko
    }

    /// Group a channel list into fixtures, preserving the incoming
    /// order: a group's slot, its representative and its member
    /// order all follow the first occurrence in the list.
    static func group(_ channels: [Channel], now: Date = Date()) -> [Group] {
        var clusterOf: [Int: Int] = [:]        // channel index → cluster
        var clusterIDs: [String] = []          // cluster → group id
        func register(_ id: String, _ members: [Int]) {
            let serial = clusterIDs.count
            clusterIDs.append(id)
            for i in members { clusterOf[i] = serial }
        }

        // — Pair identity: stamped listings with a recognisable pair,
        // bucketed by pair key + stamp date.
        struct Bucket {
            let pairKey: String
            let dateKey: String
            var idxs: [Int] = []
        }
        var buckets: [Bucket] = []
        var bucketPos: [String: Int] = [:]
        for (i, ch) in channels.enumerated() {
            guard let kickoff = ch.kickoff, let pk = pairKey(of: ch) else { continue }
            let dk = stampDateKey(of: kickoff)
            let bkey = pk + "|" + dk
            if let pos = bucketPos[bkey] {
                buckets[pos].idxs.append(i)
            } else {
                bucketPos[bkey] = buckets.count
                buckets.append(Bucket(pairKey: pk, dateKey: dk, idxs: [i]))
            }
        }
        for bucket in buckets {
            func earliest(of cluster: [Int]) -> Date {
                cluster.map { channels[$0].kickoff! }.min()!
            }
            // Chain from the earliest: sorted by kickoff, a listing
            // joins the running cluster when its stamp is within
            // 45 minutes of the cluster's latest stamp so far.
            let byKickoff = bucket.idxs.sorted {
                channels[$0].kickoff! < channels[$1].kickoff!
            }
            var clusters: [[Int]] = []
            for i in byKickoff {
                let ko = channels[i].kickoff!
                if let last = clusters.last,
                   let latest = last.map({ channels[$0].kickoff! }).max(),
                   ko.timeIntervalSince(latest) <= chainWindow {
                    clusters[clusters.count - 1].append(i)
                } else {
                    clusters.append([i])
                }
            }
            // Live merge: clusters of this pair + date whose earliest
            // stamp is live right now collapse into one fixture,
            // however far apart their stamps are.
            let liveIdx = Set(clusters.indices.filter {
                isLive(kickoff: earliest(of: clusters[$0]), now: now)
            })
            if liveIdx.count > 1 {
                let merged = clusters.indices
                    .filter { liveIdx.contains($0) }
                    .flatMap { clusters[$0] }
                clusters = clusters.indices
                    .filter { !liveIdx.contains($0) }
                    .map { clusters[$0] } + [merged]
            }
            for cluster in clusters {
                let id = "fx2:" + bucket.pairKey + "|" + bucket.dateKey + "|"
                    + String(Int(earliest(of: cluster).timeIntervalSince1970))
                register(id, cluster)
            }
        }

        // — Everything the pair identity does not cover keeps the
        // previous identity verbatim and never merges into a pair
        // fixture.
        var legacy: [String: [Int]] = [:]
        var legacyKeys: [String] = []
        for (i, ch) in channels.enumerated() where clusterOf[i] == nil {
            let key = legacyGroupKey(for: ch)
            if legacy[key] == nil { legacyKeys.append(key) }
            legacy[key, default: []].append(i)
        }
        for key in legacyKeys {
            register(key, legacy[key]!)
        }

        // — Emit in first-occurrence order, members in list order.
        var membersOf: [[Int]] = Array(repeating: [], count: clusterIDs.count)
        for i in channels.indices {
            if let serial = clusterOf[i] {
                membersOf[serial].append(i)
            }
        }
        var emitted = Set<Int>()
        var out: [Group] = []
        for i in channels.indices {
            guard let serial = clusterOf[i], emitted.insert(serial).inserted
            else { continue }
            out.append(Group(
                id: clusterIDs[serial],
                members: membersOf[serial].map { channels[$0] }
            ))
        }
        return out
    }
}
