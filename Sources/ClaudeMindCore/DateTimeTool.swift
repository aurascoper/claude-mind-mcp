import Foundation

public enum DateTimeTool {
    public static func nowJSON(now: Date = Date(), timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        let iso = ISO8601DateFormatter()
        iso.timeZone = timeZone
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = locale
        let comps = calendar.dateComponents(in: timeZone, from: now)
        let weekday = weekdayName(from: comps.weekday, locale: locale)
        let quarter = ((max((comps.month ?? 1), 1) - 1) / 3) + 1

        let payload: [String: Any] = [
            "iso8601": iso.string(from: now),
            "date": String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0),
            "time": String(format: "%02d:%02d:%02d", comps.hour ?? 0, comps.minute ?? 0, comps.second ?? 0),
            "timezone": timeZone.identifier,
            "timezone_abbreviation": timeZone.abbreviation(for: now) ?? "",
            "utc_offset_seconds": timeZone.secondsFromGMT(for: now),
            "day_of_week": weekday,
            "day_of_year": calendar.ordinality(of: .day, in: .year, for: now) ?? 0,
            "week_of_year": comps.weekOfYear ?? 0,
            "quarter": quarter,
            "unix_timestamp": Int(now.timeIntervalSince1970)
        ]
        return prettyJSON(payload)
    }

    public static func parseDateJSON(text: String, base: Date = Date(), timeZone: TimeZone = .current) -> String {
        var detected: [[String: Any]] = []
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        detector?.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            guard let match, let date = match.date else { return }
            let iso = ISO8601DateFormatter()
            iso.timeZone = timeZone
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var entry: [String: Any] = [
                "iso8601": iso.string(from: date),
                "unix_timestamp": Int(date.timeIntervalSince1970),
                "matched_text": (Range(match.range, in: text).map { String(text[$0]) }) ?? ""
            ]
            if match.duration > 0 {
                entry["duration_seconds"] = match.duration
                let endIso = ISO8601DateFormatter()
                endIso.timeZone = timeZone
                endIso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                entry["end_iso8601"] = endIso.string(from: date.addingTimeInterval(match.duration))
            }
            if let tz = match.timeZone { entry["matched_timezone"] = tz.identifier }
            detected.append(entry)
        }

        let baseIso = ISO8601DateFormatter()
        baseIso.timeZone = timeZone
        baseIso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let payload: [String: Any] = [
            "input": text,
            "base_iso8601": baseIso.string(from: base),
            "timezone": timeZone.identifier,
            "matches": detected,
            "match_count": detected.count,
            "note": detected.isEmpty
                ? "No explicit dates detected. Relative-phrase resolver (e.g., 'last Thursday') is planned for v2."
                : "NSDataDetector explicit-date matches. Relative-phrase resolver lands in v2."
        ]
        return prettyJSON(payload)
    }

    private static func weekdayName(from weekday: Int?, locale: Locale) -> String {
        guard let weekday else { return "" }
        let formatter = DateFormatter()
        formatter.locale = locale
        return formatter.weekdaySymbols[max(0, min(weekday - 1, formatter.weekdaySymbols.count - 1))]
    }

    static func prettyJSON(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}
