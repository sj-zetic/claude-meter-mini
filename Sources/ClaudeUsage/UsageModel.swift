import Foundation

struct Bucket: Codable {
    let id: String
    let label: String
    let utilization: Double   // 0–100, may slightly exceed 100
    let resetsAt: Date?

    var remainingPercent: Int { max(0, 100 - Int(utilization.rounded(.up))) }
}

struct Snapshot: Codable {
    let buckets: [Bucket]
    let fetchedAt: Date

    var mostConstrained: Bucket? { buckets.max(by: { $0.utilization < $1.utilization }) }

    func bucket(id: String) -> Bucket? { buckets.first { $0.id == id } }
    var session: Bucket? { bucket(id: "five_hour") }
    var weekly: Bucket? { bucket(id: "seven_day") }

    func isStale(now: Date = Date()) -> Bool {
        now.timeIntervalSince(fetchedAt) > 300
    }
}

enum UsageDecoder {
    static let friendlyLabels: [String: String] = [
        "five_hour": "5-hour limit",
        "seven_day": "Weekly limit",
        "seven_day_opus": "Weekly Opus limit",
        "seven_day_sonnet": "Weekly Sonnet limit",
        "seven_day_oauth_apps": "Weekly apps limit",
    ]

    // Any top-level value shaped {utilization: <number>, ...} is a bucket;
    // unknown keys must never crash decoding.
    static func decode(_ data: Data) -> [Bucket] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return []
        }
        var buckets: [Bucket] = []
        for (key, value) in root {
            guard let dict = value as? [String: Any],
                  let utilization = numeric(dict["utilization"]) else { continue }
            let resetsAt = (dict["resets_at"] as? String).flatMap(parseISO8601)
            let label = friendlyLabels[key] ?? key.replacingOccurrences(of: "_", with: " ").capitalized
            buckets.append(Bucket(id: key, label: label, utilization: utilization, resetsAt: resetsAt))
        }
        // Stable ordering: known buckets first in a sensible order, then alphabetical.
        let order = ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet"]
        return buckets.sorted { a, b in
            let ia = order.firstIndex(of: a.id) ?? Int.max
            let ib = order.firstIndex(of: b.id) ?? Int.max
            return ia != ib ? ia < ib : a.id < b.id
        }
    }

    private static func numeric(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }

    static func parseISO8601(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }

    static func countdown(to date: Date, now: Date = Date()) -> String {
        let seconds = Int(date.timeIntervalSince(now))
        if seconds < 60 { return "soon" }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours >= 48 { return "\(hours / 24)d \(hours % 24)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}

enum SnapshotCache {
    static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeUsage", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("last.json")
    }

    static func save(_ snapshot: Snapshot) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(snapshot) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    static func load() -> Snapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Snapshot.self, from: data)
    }
}
