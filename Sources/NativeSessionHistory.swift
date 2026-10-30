import Foundation

enum NativeSessionHistory {
    struct Group: Identifiable {
        let id: String
        let title: String
        var sessions: [PiSession]
    }

    static func date(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = parser.date(from: value) { return date }
        parser.formatOptions = [.withInternetDateTime]
        return parser.date(from: value)
    }

    static func groups(_ sessions: [PiSession], search: String = "", now: Date = Date(), calendar: Calendar = .current) -> [Group] {
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let week = calendar.date(byAdding: .day, value: -7, to: today)!
        let month = calendar.date(byAdding: .day, value: -30, to: today)!
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = sessions.filter {
            $0.relation?["kind"].string != "subagent" &&
            (query.isEmpty || ($0.title + " " + $0.cwd).localizedCaseInsensitiveContains(query))
        }.map { (session: $0, date: date($0.modified)) }.sorted {
            if $0.date != $1.date { return ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            return $0.session.id < $1.session.id
        }
        var result: [Group] = []
        for item in matching {
            let id: String
            let title: String
            if let date = item.date {
                if date >= today { id = "today"; title = "今天" }
                else if date >= yesterday { id = "yesterday"; title = "昨天" }
                else if date >= week { id = "week"; title = "过去 7 天" }
                else if date >= month { id = "month"; title = "过去 30 天" }
                else {
                    let parts = calendar.dateComponents([.year, .month], from: date)
                    id = "\(parts.year!)-\(parts.month!)"
                    title = "\(parts.year!)年\(parts.month!)月"
                }
            } else { id = "unknown"; title = "时间未知" }
            if let index = result.firstIndex(where: { $0.id == id }) { result[index].sessions.append(item.session) }
            else { result.append(Group(id: id, title: title, sessions: [item.session])) }
        }
        return result
    }
}
