import Foundation

/// Short human readable durations and times for the popover and notifications.
enum Formatting {
    /// "42s", "3m", "1h 12m", "2d 4h".
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds.rounded()))
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        if hours < 24 { return remainingMinutes == 0 ? "\(hours)h" : "\(hours)h \(remainingMinutes)m" }
        let days = hours / 24
        let remainingHours = hours % 24
        return remainingHours == 0 ? "\(days)d" : "\(days)d \(remainingHours)h"
    }

    /// "just now", "3m ago", "1h 12m ago".
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let elapsed = now.timeIntervalSince(date)
        if elapsed < 30 { return "just now" }
        return duration(elapsed) + " ago"
    }

    /// "for 3m", "for 1h 12m".
    static func forDuration(since date: Date, now: Date = Date()) -> String {
        "for " + duration(now.timeIntervalSince(date))
    }

    /// "12 ms", "1.2 s".
    static func latency(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "" }
        if seconds < 1 { return "\(Int((seconds * 1000).rounded())) ms" }
        return String(format: "%.1f s", seconds)
    }

    static func clockTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    /// "22:00" style label for a minutes after midnight value.
    static func minutesLabel(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
}
