import Foundation

/// M3U parsing, ported from MainActivity.parse / titleOf / kickoffOf in the
/// Android app:
/// - An #EXTINF line sets a pending entry: logo from `tvg-logo="…"`,
///   group from `group-title="…"` (trimmed), title = the text after the
///   first comma that sits OUTSIDE quotes (fallback "Kênh").
/// - The next line starting with "http" completes the entry.
/// - An empty group falls back to "Kênh".
enum M3UParser {

    private static let logoRegex = try! NSRegularExpression(pattern: #"tvg-logo="([^"]*)""#)
    private static let groupRegex = try! NSRegularExpression(pattern: #"group-title="([^"]*)""#)

    static func parse(_ text: String) -> [Channel] {
        var out: [Channel] = []
        var pendingTitle: String? = nil
        var pendingLogo = ""
        var pendingGroup = ""
        var pendingReferrer = ""
        var pendingUserAgent = ""
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#EXTINF") {
                pendingLogo = capture(logoRegex, in: line) ?? ""
                pendingGroup = TitleEscapes.decode((capture(groupRegex, in: line) ?? "")
                    .trimmingCharacters(in: .whitespaces))
                pendingTitle = title(of: line)
                pendingReferrer = ""
                pendingUserAgent = ""
            } else if line.hasPrefix("#EXTVLCOPT:http-referrer=") {
                pendingReferrer = String(line.dropFirst("#EXTVLCOPT:http-referrer=".count))
                    .trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("#EXTVLCOPT:http-user-agent=") {
                pendingUserAgent = String(line.dropFirst("#EXTVLCOPT:http-user-agent=".count))
                    .trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("http"), let title = pendingTitle {
                out.append(Channel(
                    title: title,
                    logo: pendingLogo,
                    group: pendingGroup.isEmpty ? "Kênh" : pendingGroup,
                    url: line,
                    kickoff: KickoffParser.parse(from: title),
                    leagueRank: LeagueClassifier.leagueRank(of: title),
                    referrer: pendingReferrer,
                    userAgent: pendingUserAgent
                ))
                pendingTitle = nil
            }
        }
        return out
    }

    private static func capture(_ regex: NSRegularExpression, in line: String) -> String? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              let r = Range(match.range(at: 1), in: line) else { return nil }
        return String(line[r])
    }

    /// Title = text after the first comma that sits outside quotes
    /// (Android titleOf). Falls back to "Kênh" when there is no such comma.
    /// Literal "\uXXXX" escapes some sources ship un-decoded are decoded
    /// here, at the single choke point every title flows through.
    static func title(of extinf: String) -> String {
        var inQuotes = false
        for (offset, ch) in extinf.enumerated() {
            if ch == "\"" {
                inQuotes.toggle()
            } else if ch == "," && !inQuotes {
                let idx = extinf.index(extinf.startIndex, offsetBy: offset + 1)
                return TitleEscapes.decode(String(extinf[idx...]).trimmingCharacters(in: .whitespaces))
            }
        }
        return "Kênh"
    }
}

/// Some sources ship titles with literal JSON-style escapes still in
/// them — "BLV C\U00D4Ng Ch\U1Ea4T" instead of "BLV Công Chật" (41 of
/// 699 entries in the live list on 2026-11-13; the owner saw the raw
/// escapes on his TV). Decode `\uXXXX` / `\UXXXX` sequences, combining
/// UTF-16 surrogate pairs, and leave everything else untouched.
enum TitleEscapes {

    private static let regex = try! NSRegularExpression(pattern: #"\\[uU]([0-9a-fA-F]{4})"#)

    static func decode(_ s: String) -> String {
        guard s.contains("\\u") || s.contains("\\U") else { return s }
        let matches = regex.matches(in: s, range: NSRange(s.startIndex..., in: s))
        guard !matches.isEmpty else { return s }
        var out = ""
        var cursor = s.startIndex
        var pendingHigh: UInt32? = nil
        func flushPending() {
            if pendingHigh != nil {
                out.append("\u{FFFD}")
                pendingHigh = nil
            }
        }
        for m in matches {
            guard let r = Range(m.range, in: s),
                  let hr = Range(m.range(at: 1), in: s),
                  let v = UInt32(s[hr], radix: 16) else { continue }
            if r.lowerBound > cursor {
                flushPending()
                out += s[cursor..<r.lowerBound]
            }
            cursor = r.upperBound
            if (0xD800...0xDBFF).contains(v) {
                flushPending()
                pendingHigh = v
            } else if (0xDC00...0xDFFF).contains(v), let hi = pendingHigh {
                let cp = 0x10000 + ((hi - 0xD800) << 10) + (v - 0xDC00)
                if let scalar = Unicode.Scalar(cp) {
                    out.unicodeScalars.append(scalar)
                }
                pendingHigh = nil
            } else {
                flushPending()
                if let scalar = Unicode.Scalar(v) {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        flushPending()
        out += s[cursor...]
        return out
    }
}

/// The year for a playlist "DD/MM HH:MM" stamp, which carries no
/// year (H1, AUDIT.md). The stamp is read in Asia/Ho_Chi_Minh and
/// placed in whichever of the years y−1, y, y+1 (y = the current
/// ICT year) puts it nearest to `now`. Shared by KickoffParser and
/// PlaylistStore's UpdatedStamp so the two can never disagree.
///
/// It replaces the Android-port rule "current year, rolled forward
/// 365 days when more than 30 days in the past", which read a
/// 23:00 31/12 kickoff as next December once the clock passed
/// midnight on 1/1, landed New Year fixtures a day early when the
/// 365 days spanned 29 February, and read an Updated stamp more
/// than 30 days old as a stamp in the future (always fresh).
/// Whenever the current-year reading lies within 30 days either
/// side of `now`, both rules give the same instant.
enum StampYear {

    static func resolve(month: Int, day: Int, hour: Int, minute: Int,
                        now: Date) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh") ?? .current
        let year = calendar.component(.year, from: now)
        var best: Date?
        // Current year first, so an exact tie keeps the current year.
        for candidate in [year, year - 1, year + 1] {
            var comps = DateComponents()
            comps.year = candidate
            comps.month = month
            comps.day = day
            comps.hour = hour
            comps.minute = minute
            comps.second = 0
            guard let date = calendar.date(from: comps) else { continue }
            if let current = best,
               abs(current.timeIntervalSince(now)) <= abs(date.timeIntervalSince(now)) {
                continue
            }
            best = date
        }
        return best
    }
}

/// Kickoff extraction, ported from Android kickoffOf: the first
/// "HH:MM DD/MM" pattern anywhere in the title, interpreted in
/// Asia/Ho_Chi_Minh, in the year StampYear picks (nearest to now).
enum KickoffParser {

    private static let regex = try! NSRegularExpression(pattern: #"(\d{1,2}):(\d{2})\s+(\d{1,2})/(\d{1,2})"#)

    static func parse(from title: String, now: Date = Date()) -> Date? {
        let range = NSRange(title.startIndex..., in: title)
        guard let match = regex.firstMatch(in: title, range: range) else { return nil }
        func intAt(_ index: Int) -> Int? {
            guard let r = Range(match.range(at: index), in: title) else { return nil }
            return Int(title[r])
        }
        guard let hour = intAt(1), let minute = intAt(2),
              let day = intAt(3), let month = intAt(4) else { return nil }
        return StampYear.resolve(month: month, day: day, hour: hour, minute: minute, now: now)
    }
}
