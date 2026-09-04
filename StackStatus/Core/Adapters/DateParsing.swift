import Foundation

/// Date parsing for the formats status pages actually use: ISO 8601 with and
/// without fractional seconds (JSON APIs and Atom), and RFC 822 style dates
/// (RSS), including Microsoft's non standard trailing "Z".
enum DateParsing {
    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let rfc822Formats = [
        "EEE, dd MMM yyyy HH:mm:ss zzz",
        "EEE, dd MMM yyyy HH:mm:ss Z",
        "EEE, d MMM yyyy HH:mm:ss zzz",
        "EEE, d MMM yyyy HH:mm:ss Z",
        "dd MMM yyyy HH:mm:ss zzz",
        "dd MMM yyyy HH:mm:ss Z",
    ]

    private static let rfc822Formatters: [DateFormatter] = rfc822Formats.map { format in
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = format
        return f
    }

    static func parse(_ raw: String?) -> Date? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if let d = isoFractional.date(from: s) ?? iso.date(from: s) { return d }
        // ISO without a timezone designator, treated as UTC.
        if s.count == 19, s[s.index(s.startIndex, offsetBy: 10)] == "T" {
            if let d = iso.date(from: s + "Z") { return d }
        }
        // RSS dates: "Thu, 03 Sep 2026 20:53:00 Z" is not valid RFC 822 but Microsoft emits it.
        if s.hasSuffix(" Z") { s = String(s.dropLast(2)) + " +0000" }
        for f in rfc822Formatters {
            if let d = f.date(from: s) { return d }
        }
        return nil
    }
}
