import Foundation
import Combine

/// User preferences, backed by UserDefaults. Observed by the settings window
/// and read by the scheduler through `PollSettings` snapshots.
@MainActor
final class AppSettings: ObservableObject {
    static let allowedIntervals = [2, 5, 10, 15]
    static let defaultInternetURL = "https://www.apple.com/library/test/success.html"
    static let defaultDNSHost = "www.apple.com"

    private enum Key {
        static let pollInterval = "pollIntervalMinutes"
        static let notifications = "notificationsEnabled"
        static let quietHours = "quietHoursEnabled"
        static let quietStart = "quietStartMinutes"
        static let quietEnd = "quietEndMinutes"
        static let textBadge = "showTextBadge"
        static let internetURL = "baselineInternetURL"
        static let dnsHost = "baselineDNSHost"
    }

    private let defaults: UserDefaults

    @Published var pollIntervalMinutes: Int { didSet { defaults.set(pollIntervalMinutes, forKey: Key.pollInterval) } }
    @Published var notificationsEnabled: Bool { didSet { defaults.set(notificationsEnabled, forKey: Key.notifications) } }
    @Published var quietHoursEnabled: Bool { didSet { defaults.set(quietHoursEnabled, forKey: Key.quietHours) } }
    /// Minutes after midnight, local time.
    @Published var quietStartMinutes: Int { didSet { defaults.set(quietStartMinutes, forKey: Key.quietStart) } }
    @Published var quietEndMinutes: Int { didSet { defaults.set(quietEndMinutes, forKey: Key.quietEnd) } }
    @Published var showTextBadge: Bool { didSet { defaults.set(showTextBadge, forKey: Key.textBadge) } }
    @Published var internetURL: String { didSet { defaults.set(internetURL, forKey: Key.internetURL) } }
    @Published var dnsHost: String { didSet { defaults.set(dnsHost, forKey: Key.dnsHost) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let interval = defaults.object(forKey: Key.pollInterval) as? Int ?? 5
        pollIntervalMinutes = AppSettings.allowedIntervals.contains(interval) ? interval : 5
        notificationsEnabled = defaults.object(forKey: Key.notifications) as? Bool ?? true
        quietHoursEnabled = defaults.object(forKey: Key.quietHours) as? Bool ?? false
        quietStartMinutes = defaults.object(forKey: Key.quietStart) as? Int ?? 22 * 60
        quietEndMinutes = defaults.object(forKey: Key.quietEnd) as? Int ?? 7 * 60
        showTextBadge = defaults.object(forKey: Key.textBadge) as? Bool ?? false
        internetURL = defaults.string(forKey: Key.internetURL) ?? AppSettings.defaultInternetURL
        dnsHost = defaults.string(forKey: Key.dnsHost) ?? AppSettings.defaultDNSHost
    }

    var pollSettings: PollSettings {
        PollSettings(
            userInterval: TimeInterval(pollIntervalMinutes * 60),
            internetURL: URL(string: internetURL) ?? URL(string: AppSettings.defaultInternetURL)!,
            dnsHost: dnsHost.isEmpty ? AppSettings.defaultDNSHost : dnsHost
        )
    }

    func isQuietNow(_ date: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard quietHoursEnabled else { return false }
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let minutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        return AppSettings.isQuiet(minute: minutes, start: quietStartMinutes, end: quietEndMinutes)
    }

    /// Pure rule so it can be tested: a window that wraps past midnight is
    /// handled, and a window with start equal to end is empty.
    nonisolated static func isQuiet(minute: Int, start: Int, end: Int) -> Bool {
        if start == end { return false }
        if start < end { return minute >= start && minute < end }
        return minute >= start || minute < end
    }
}

/// The subset of settings the scheduler needs, as a value it can hold safely.
struct PollSettings: Hashable, Sendable {
    var userInterval: TimeInterval
    var internetURL: URL
    var dnsHost: String

    static let incidentInterval: TimeInterval = 2 * 60
    static let batteryMultiplier: Double = 3
}
