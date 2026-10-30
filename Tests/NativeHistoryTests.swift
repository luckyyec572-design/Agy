import Foundation

@main struct NativeHistoryTests {
    static func main() {
        var checks = 0
        func check(_ value: Bool, _ label: String) { precondition(value, label); checks += 1 }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = NativeSessionHistory.date("2026-10-24T00:30:00Z")!
        func session(_ id: String, _ date: String?, relation: WireValue? = nil) -> PiSession {
            PiSession(id: id, cwd: "/workspace", name: id, firstMessage: nil, modified: date, relation: relation)
        }
        let samples = [
            session("old", "2026-08-10T00:00:00Z"), session("unknown", nil),
            session("yesterday", "2026-10-23T15:59:59Z"), session("month", "2026-10-01T00:00:00Z"),
            session("today", "2026-10-23T16:00:00.000Z"), session("week", "2026-10-17T00:00:00Z"),
            session("newest", "2026-10-24T00:29:00Z")
        ]
        let groups = NativeSessionHistory.groups(samples, now: now, calendar: calendar)
        check(groups.map(\.id) == ["today", "yesterday", "week", "month", "2026-8", "unknown"], "Newest groups first, unknown last")
        check(groups.first?.sessions.map(\.id) == ["newest", "today"], "Newest sessions first within each group")
        check(groups[1].sessions.first?.id == "yesterday", "Day boundary uses device timezone, not UTC")
        check(groups.flatMap(\.sessions).count == samples.count, "Each session appears exactly once")
        check(NativeSessionHistory.date("bad") == nil, "Malformed date remains unknown")
        check(NativeSessionHistory.groups(samples, search: "  NEWEST ", now: now, calendar: calendar).flatMap(\.sessions).map(\.id) == ["newest"], "Search before grouping and trim whitespace")
        check(NativeSessionHistory.groups(samples, search: "none", now: now, calendar: calendar).isEmpty, "No empty sections after filtering")
        let child = session("child", "2026-10-24T00:30:00Z", relation: .object(["kind": .string("subagent")]))
        check(NativeSessionHistory.groups([child], now: now, calendar: calendar).isEmpty, "Subagent sessions excluded")
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let dstNow = NativeSessionHistory.date("2026-11-02T08:30:00Z")!
        let dstSessions = [session("yesterday", "2026-11-01T07:30:00Z"), session("today", "2026-11-02T08:00:00Z")]
        check(NativeSessionHistory.groups(dstSessions, now: dstNow, calendar: calendar).map(\.id) == ["today", "yesterday"], "Calendar day grouping across 25-hour DST day")
        print("Passed \(checks) history grouping checks")
    }
}
