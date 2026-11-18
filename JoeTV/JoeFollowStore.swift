import Foundation
import UserNotifications

/// Follow & remind data layer — Idea 7 (follow / theo dõi,
/// new-episode badges, match reminders, pinned teams).
///
/// Three small stores, one per concern, each persisted as one
/// JSON document in UserDefaults and rewritten whole on every
/// mutation. Loading is fail-soft in the codebase's style: a
/// missing or corrupt payload loads as empty, never crashes.
///
/// No background work and no timers live in this file: episode
/// checks and match revalidation are driven by callers when
/// they already have fresh catalogue / fixture data in hand.

@MainActor
final class FollowStore: ObservableObject {
    static let shared = FollowStore()

    struct FollowedTitle: Codable, Identifiable, Equatable {
        var provider: String
        var slug: String
        var title: String
        var poster: String
        var baselineEpisodes: Int
        var latestEpisodes: Int

        var id: String { provider + "|" + slug }
        var hasNewEpisodes: Bool { latestEpisodes > baselineEpisodes }
    }

    @Published private(set) var followed: [FollowedTitle]

    private static let defaultsKey = "joetv.follow.titles.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([FollowedTitle].self, from: data) {
            followed = decoded
        } else {
            followed = []
        }
    }

    func isFollowing(provider: String, slug: String) -> Bool {
        let key = provider + "|" + slug
        return followed.contains { $0.id == key }
    }

    /// Returns the NEW state (true = now following). On follow,
    /// baseline and latest both start at the current episode
    /// count, so only episodes arriving AFTER the follow count
    /// as new.
    @discardableResult
    func toggle(provider: String, slug: String, title: String, poster: String, currentEpisodes: Int) -> Bool {
        let key = provider + "|" + slug
        if let index = followed.firstIndex(where: { $0.id == key }) {
            followed.remove(at: index)
            save()
            return false
        }
        followed.append(FollowedTitle(
            provider: provider, slug: slug, title: title, poster: poster,
            baselineEpisodes: currentEpisodes, latestEpisodes: currentEpisodes))
        save()
        return true
    }

    /// Record a fresh episode count seen for a followed title.
    /// Latest only ever moves up; baseline is untouched (it
    /// moves only via markSeen).
    func applyEpisodeCheck(provider: String, slug: String, currentEpisodes: Int) {
        let key = provider + "|" + slug
        guard let index = followed.firstIndex(where: { $0.id == key }) else { return }
        let newLatest = max(followed[index].latestEpisodes, currentEpisodes)
        if newLatest != followed[index].latestEpisodes {
            followed[index].latestEpisodes = newLatest
            save()
        }
    }

    /// The owner has seen the title's current episodes: the
    /// new-episode badge clears by lifting baseline to latest.
    func markSeen(provider: String, slug: String) {
        let key = provider + "|" + slug
        guard let index = followed.firstIndex(where: { $0.id == key }) else { return }
        if followed[index].baselineEpisodes != followed[index].latestEpisodes {
            followed[index].baselineEpisodes = followed[index].latestEpisodes
            save()
        }
    }

    /// Parse a provider `episodeCurrent` string into a count.
    /// Shapes seen from providers: "Tập 12", "12",
    /// "Hoàn Tất (12/12)", "Tập 12/20", "Full".
    /// For a "current/total" pair the CURRENT count is the
    /// number immediately before the first "/" (12/20 → 12,
    /// not 20); with no "/", the largest integer wins; with no
    /// digits at all ("Full") the count is 0.
    nonisolated static func episodeCount(from episodeCurrent: String) -> Int {
        // Collect every integer with its end position.
        var numbers: [(value: Int, end: Int)] = []
        var current = ""
        var currentEnd = episodeCurrent.startIndex
        func flush() {
            if let value = Int(current) {
                numbers.append((value, episodeCurrent.distance(from: episodeCurrent.startIndex, to: currentEnd)))
            }
            current = ""
        }
        for index in episodeCurrent.indices {
            let ch = episodeCurrent[index]
            if ch.isNumber {
                current.append(ch)
                currentEnd = episodeCurrent.index(after: index)
            } else {
                flush()
            }
        }
        flush()
        guard !numbers.isEmpty else { return 0 }
        if let slash = episodeCurrent.firstIndex(of: "/") {
            let slashOffset = episodeCurrent.distance(from: episodeCurrent.startIndex, to: slash)
            // The integer closest before the first "/".
            if let before = numbers.filter({ $0.end <= slashOffset }).last {
                return before.value
            }
        }
        return numbers.map(\.value).max() ?? 0
    }

    private func save() {
        if let data = try? JSONEncoder().encode(followed) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}

@MainActor
final class MatchReminderStore: ObservableObject {
    static let shared = MatchReminderStore()

    struct Reminder: Codable, Identifiable, Equatable {
        var matchKey: String
        var title: String
        var kickoff: Date

        var id: String { matchKey }
    }

    @Published private(set) var reminders: [Reminder]

    private static let defaultsKey = "joetv.follow.reminders.v1"
    private static let notificationPrefix = "joetv.match."

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([Reminder].self, from: data) {
            reminders = decoded
        } else {
            reminders = []
        }
    }

    /// Stable key for a fixture title: trimmed, lowercased.
    nonisolated static func matchKey(forTitle title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func reminder(forKey key: String) -> Reminder? {
        reminders.first { $0.matchKey == key }
    }

    /// Store (or replace) a reminder for the
    /// 15-minutes-before-kickoff reminder. Replacing an
    /// existing key refreshes it with the new kickoff. On
    /// tvOS the reminder is in-app only (see schedule()).
    func setReminder(matchKey: String, title: String, kickoff: Date) {
        let reminder = Reminder(matchKey: matchKey, title: title, kickoff: kickoff)
        if let index = reminders.firstIndex(where: { $0.matchKey == matchKey }) {
            reminders[index] = reminder
        } else {
            reminders.append(reminder)
        }
        save()
        schedule(reminder)
    }

    func cancelReminder(matchKey: String) {
        let before = reminders.count
        reminders.removeAll { $0.matchKey == matchKey }
        if reminders.count != before { save() }
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [Self.notificationID(for: matchKey)])
    }

    /// Reconcile stored reminders against a freshly loaded
    /// fixture list. A reminder whose match moved by more than
    /// 60 s is updated and rescheduled; a reminder whose
    /// kickoff is now in the past is removed together with its
    /// pending request. A reminder whose match is simply
    /// ABSENT from this list is left alone — the catalogue page
    /// may just not include it this time.
    func revalidate(matches: [(key: String, title: String, kickoff: Date)]) {
        let byKey = Dictionary(matches.map { ($0.key, $0) },
                               uniquingKeysWith: { first, _ in first })
        let now = Date()
        // Iterate over a snapshot copy: the loop mutates `reminders`.
        let snapshot = reminders
        for stored in snapshot {
            if let match = byKey[stored.matchKey],
               abs(match.kickoff.timeIntervalSince(stored.kickoff)) > 60 {
                if let index = reminders.firstIndex(where: { $0.matchKey == stored.matchKey }) {
                    reminders[index].kickoff = match.kickoff
                    reminders[index].title = match.title
                    save()
                    schedule(reminders[index])
                }
            }
            // Expiry is judged on the (possibly updated) kickoff.
            let effective = reminder(forKey: stored.matchKey)?.kickoff ?? stored.kickoff
            if effective <= now {
                cancelReminder(matchKey: stored.matchKey)
            }
        }
    }

    private static func notificationID(for matchKey: String) -> String {
        notificationPrefix + matchKey
    }

    /// (Re)schedule the 15-minutes-before reminder for one
    /// reminder. Any previous pending request for the same
    /// match is replaced. If the fire date is already past,
    /// nothing is scheduled (the reminder stays stored;
    /// revalidate cleans expired reminders up).
    ///
    /// tvOS reality (compile fix, v2.0.27): there is NO
    /// tvOS-supported way to present this alert. Apple's
    /// documentation for UNMutableNotificationContent lists
    /// the title, body and sound properties for iOS, iPadOS,
    /// macOS, visionOS and watchOS only — in the tvOS Swift
    /// SDK all three are unavailable, so the content object
    /// for a presentable notification cannot even be built.
    /// Scheduling therefore deliberately NO-OPS on tvOS:
    /// the reminder itself stays stored and surfaced in-app
    /// (the follow/reminder surfaces read this store), and
    /// any stale pending request is still cleaned up below.
    /// Do not "fix" this by restoring the iOS-shaped code —
    /// it does not compile here, by the platform's design.
    private func schedule(_ reminder: Reminder) {
        let center = UNUserNotificationCenter.current()
        let identifier = Self.notificationID(for: reminder.matchKey)
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        let fireDate = reminder.kickoff.addingTimeInterval(-15 * 60)
        guard fireDate > Date() else { return }
        // Deliberate no-op beyond the cleanup above: see the
        // tvOS note in this method's doc comment. The
        // reminder lives in the store and in the app's own
        // surfaces; no system notification is scheduled.
    }

    private func save() {
        if let data = try? JSONEncoder().encode(reminders) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}

@MainActor
final class PinnedTeamsStore: ObservableObject {
    static let shared = PinnedTeamsStore()

    /// Normalized team names: trimmed, original case kept for
    /// display; all matching is case-insensitive.
    @Published private(set) var teams: [String]

    private static let defaultsKey = "joetv.follow.teams.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            teams = decoded
        } else {
            teams = []
        }
    }

    func isPinned(_ team: String) -> Bool {
        let needle = Self.normalize(team)
        guard !needle.isEmpty else { return false }
        return teams.contains { $0.lowercased() == needle.lowercased() }
    }

    func toggle(_ team: String) {
        let trimmed = Self.normalize(team)
        guard !trimmed.isEmpty else { return }
        if let index = teams.firstIndex(where: { $0.lowercased() == trimmed.lowercased() }) {
            teams.remove(at: index)
        } else {
            teams.append(trimmed)
        }
        save()
    }

    /// True when the title mentions any pinned team
    /// (case-insensitive substring match).
    func matches(title: String) -> Bool {
        let haystack = title.lowercased()
        return teams.contains { !$0.isEmpty && haystack.contains($0.lowercased()) }
    }

    private static func normalize(_ team: String) -> String {
        team.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(teams) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
