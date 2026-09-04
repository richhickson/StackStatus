import Foundation
import UserNotifications

/// The notification surface the state store talks to, so tests can record
/// instead of posting.
@MainActor
protocol Notifying: AnyObject {
    func notify(vendor: Vendor, transition: VendorTransition)
    func notifyConnectionDown(since: Date)
}

/// Builds and posts user notifications. Only transitions get here, never a
/// plain poll, and quiet hours or the master switch silence everything.
@MainActor
final class Notifier: Notifying {
    struct Content: Hashable {
        var title: String
        var body: String
        var url: URL?
    }

    nonisolated static let urlKey = "url"

    private let settings: AppSettings
    private let center: UNUserNotificationCenter?

    init(settings: AppSettings, center: UNUserNotificationCenter? = .current()) {
        self.settings = settings
        self.center = center
    }

    func requestAuthorization() {
        center?.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notify(vendor: Vendor, transition: VendorTransition) {
        guard let content = Self.content(for: vendor, transition: transition) else { return }
        post(content, identifier: "vendor-\(vendor.id)-\(Int(transition.at.timeIntervalSince1970))")
    }

    func notifyConnectionDown(since: Date) {
        let content = Content(
            title: "Your connection looks down",
            body: "The gateway, DNS or internet check has failed on two polls in a row.",
            url: nil
        )
        post(content, identifier: "baseline-\(Int(since.timeIntervalSince1970))")
    }

    /// Pure so it can be tested: nil means "do not notify for this transition".
    nonisolated static func content(for vendor: Vendor, transition: VendorTransition) -> Content? {
        let url = transition.incident?.url ?? vendor.pageURL
        switch transition.kind {
        case .started:
            return Content(
                title: "\(vendor.name): \(transition.to.label.lowercased())",
                body: transition.incident?.title ?? "See \(vendor.pageURL.host ?? "the status page") for details",
                url: url
            )
        case .resolved:
            let duration = transition.duration.map { Formatting.duration($0) } ?? "an unknown time"
            let what = transition.incident?.title ?? transition.from.label
            return Content(
                title: "\(vendor.name): resolved",
                body: "\(what). Back to operational after \(duration).",
                url: url
            )
        case .changed:
            guard transition.worsened else { return nil }
            return Content(
                title: "\(vendor.name): now \(transition.to.label.lowercased())",
                body: transition.incident?.title ?? "Escalated from \(transition.from.label.lowercased())",
                url: url
            )
        }
    }

    private func post(_ content: Content, identifier: String) {
        guard settings.notificationsEnabled, !settings.isQuietNow(), let center else { return }
        #if DEBUG
        print("notification: \(content.title) | \(content.body)")
        #endif
        let notification = UNMutableNotificationContent()
        notification.title = content.title
        notification.body = content.body
        notification.sound = .default
        if let url = content.url { notification.userInfo = [Self.urlKey: url.absoluteString] }
        center.add(UNNotificationRequest(identifier: identifier, content: notification, trigger: nil))
    }
}
