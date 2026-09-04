import XCTest
@testable import StackStatus

final class SettingsAndConfigTests: XCTestCase {

    // MARK: Quiet hours

    func testQuietWindowSameDay() {
        XCTAssertTrue(AppSettings.isQuiet(minute: 13 * 60, start: 12 * 60, end: 14 * 60))
        XCTAssertFalse(AppSettings.isQuiet(minute: 14 * 60, start: 12 * 60, end: 14 * 60), "end is exclusive")
        XCTAssertFalse(AppSettings.isQuiet(minute: 11 * 60, start: 12 * 60, end: 14 * 60))
    }

    func testQuietWindowWrapsMidnight() {
        XCTAssertTrue(AppSettings.isQuiet(minute: 23 * 60, start: 22 * 60, end: 7 * 60))
        XCTAssertTrue(AppSettings.isQuiet(minute: 2 * 60, start: 22 * 60, end: 7 * 60))
        XCTAssertFalse(AppSettings.isQuiet(minute: 12 * 60, start: 22 * 60, end: 7 * 60))
        XCTAssertFalse(AppSettings.isQuiet(minute: 7 * 60, start: 22 * 60, end: 7 * 60))
    }

    func testEmptyQuietWindow() {
        XCTAssertFalse(AppSettings.isQuiet(minute: 100, start: 100, end: 100))
    }

    @MainActor
    func testSettingsDefaultsAndPersistence() {
        let suite = "com.helpfullyit.stackstatus.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.pollIntervalMinutes, 5)
        XCTAssertTrue(settings.notificationsEnabled)
        XCTAssertFalse(settings.quietHoursEnabled)
        XCTAssertFalse(settings.showTextBadge)
        XCTAssertEqual(settings.pollSettings.userInterval, 300)
        XCTAssertEqual(settings.pollSettings.internetURL.absoluteString, AppSettings.defaultInternetURL)

        settings.pollIntervalMinutes = 10
        settings.notificationsEnabled = false
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.pollIntervalMinutes, 10)
        XCTAssertFalse(reloaded.notificationsEnabled)
    }

    @MainActor
    func testInvalidStoredIntervalFallsBackToDefault() {
        let suite = "com.helpfullyit.stackstatus.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(7, forKey: "pollIntervalMinutes")
        XCTAssertEqual(AppSettings(defaults: defaults).pollIntervalMinutes, 5)
    }

    // MARK: Vendor config

    private func tempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stackstatus-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private let sampleJSON = """
    {
      "version": 1,
      "vendors": [
        {
          "id": "cloudflare",
          "name": "Cloudflare",
          "platform": "statuspage",
          "baseURL": "https://www.cloudflarestatus.com",
          "incidentURL": "https://www.cloudflarestatus.com",
          "probes": [
            { "type": "https_head", "url": "https://1.1.1.1/" },
            { "type": "dns", "host": "cloudflare.com", "resolver": "1.1.1.1" },
            { "type": "tcp", "host": "cloudflare.com", "port": 443 }
          ]
        },
        { "id": "broken", "name": "Missing platform" },
        { "id": "future", "name": "Future platform", "platform": "instatus", "baseURL": "https://x.test" },
        { "id": "m365", "name": "Microsoft 365", "enabled": false, "platform": "feed", "baseURL": "https://status.cloud.microsoft", "feedURL": "https://status.cloud.microsoft/api/feed/mac" }
      ]
    }
    """

    func testDecodeSkipsBadEntriesAndDefaultsEnabled() throws {
        let config = try ConfigStore.decode(Data(sampleJSON.utf8))
        XCTAssertEqual(config.version, 1)
        XCTAssertEqual(config.vendors.map(\.id), ["cloudflare", "m365"])
        let cf = config.vendors[0]
        XCTAssertTrue(cf.enabled)
        XCTAssertEqual(cf.platform, .statuspage)
        XCTAssertEqual(cf.probes, [
            .httpsHead(url: URL(string: "https://1.1.1.1/")!),
            .dns(host: "cloudflare.com", resolver: "1.1.1.1"),
            .tcp(host: "cloudflare.com", port: 443),
        ])
        XCTAssertFalse(config.vendors[1].enabled)
        XCTAssertEqual(config.vendors[1].feedURL?.absoluteString, "https://status.cloud.microsoft/api/feed/mac")
    }

    func testEncodeRoundTrip() throws {
        let config = try ConfigStore.decode(Data(sampleJSON.utf8))
        let data = try ConfigStore.encode(config)
        let again = try ConfigStore.decode(data)
        XCTAssertEqual(again.vendors, config.vendors)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"type\" : \"https_head\""))
        XCTAssertTrue(text.contains("\"resolver\" : \"1.1.1.1\""))
        XCTAssertFalse(text.contains("\\/"), "slashes are not escaped")
    }

    func testFirstRunSeedsFromBundledFile() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundled = dir.appendingPathComponent("bundled.json")
        try Data(sampleJSON.utf8).write(to: bundled)

        let store = ConfigStore(directory: dir.appendingPathComponent("support"), bundledURL: bundled)
        let config = try store.load()
        XCTAssertEqual(config.vendors.map(\.id), ["cloudflare", "m365"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL.path), "user copy written on first run")

        // Edits survive and the bundled file is no longer consulted.
        var edited = config
        edited.vendors.removeAll { $0.id == "m365" }
        try store.save(edited)
        XCTAssertEqual(try store.load().vendors.map(\.id), ["cloudflare"])
        XCTAssertEqual(store.newBundledVendors(comparedTo: edited).map(\.id), ["m365"])
    }

    func testMissingBundledFileGivesEmptyList() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(directory: dir, bundledURL: nil)
        XCTAssertTrue(try store.load().vendors.isEmpty)
    }

    func testBundledDefaultListInTheApp() throws {
        // The build merges vendors/*.json into the app bundle. This proves the
        // merge ran and every bundled vendor decodes.
        let config = ConfigStore().bundledConfig()
        XCTAssertEqual(config.vendors.map(\.id), ["anthropic", "cloudflare", "github", "microsoft365", "openai"])
        XCTAssertTrue(config.vendors.allSatisfy(\.enabled))
        XCTAssertEqual(config.vendors.first(where: { $0.id == "anthropic" })?.baseURL.host, "status.claude.com")
        XCTAssertEqual(config.vendors.first(where: { $0.id == "openai" })?.platform, .incidentio)
        XCTAssertEqual(config.vendors.first(where: { $0.id == "microsoft365" })?.platform, .feed)
        XCTAssertNotNil(config.vendors.first(where: { $0.id == "microsoft365" })?.feedURL)
    }

    // MARK: Formatting

    func testDurationFormatting() {
        XCTAssertEqual(Formatting.duration(5), "5s")
        XCTAssertEqual(Formatting.duration(59.4), "59s")
        XCTAssertEqual(Formatting.duration(60), "1m")
        XCTAssertEqual(Formatting.duration(40 * 60), "40m")
        XCTAssertEqual(Formatting.duration(3600), "1h")
        XCTAssertEqual(Formatting.duration(3600 + 12 * 60), "1h 12m")
        XCTAssertEqual(Formatting.duration(26 * 3600), "1d 2h")
        XCTAssertEqual(Formatting.latency(0.0123), "12 ms")
        XCTAssertEqual(Formatting.latency(1.26), "1.3 s")
        XCTAssertEqual(Formatting.minutesLabel(22 * 60 + 5), "22:05")
    }

    // MARK: Notification content

    func testNotificationContent() {
        let vendor = makeVendor("cloudflare", platform: .statuspage, base: "https://status.cf.test")
        let incident = Incident(id: "i", title: "API errors", url: URL(string: "https://status.cf.test/incidents/i"))
        let now = Date()

        let started = Notifier.content(for: vendor, transition: VendorTransition(kind: .started, from: .operational, to: .partialOutage, incident: incident, duration: nil, at: now))
        XCTAssertEqual(started?.title, "Cloudflare: partial outage")
        XCTAssertEqual(started?.body, "API errors")
        XCTAssertEqual(started?.url?.absoluteString, "https://status.cf.test/incidents/i")

        let resolved = Notifier.content(for: vendor, transition: VendorTransition(kind: .resolved, from: .partialOutage, to: .operational, incident: incident, duration: 40 * 60, at: now))
        XCTAssertEqual(resolved?.title, "Cloudflare: resolved")
        XCTAssertEqual(resolved?.body, "API errors. Back to operational after 40m.")

        let worse = Notifier.content(for: vendor, transition: VendorTransition(kind: .changed, from: .degraded, to: .majorOutage, incident: nil, duration: nil, at: now))
        XCTAssertEqual(worse?.title, "Cloudflare: now major outage")

        let better = Notifier.content(for: vendor, transition: VendorTransition(kind: .changed, from: .majorOutage, to: .degraded, incident: nil, duration: nil, at: now))
        XCTAssertNil(better, "de-escalation is silent")

        let noIncident = Notifier.content(for: vendor, transition: VendorTransition(kind: .started, from: .operational, to: .degraded, incident: nil, duration: nil, at: now))
        XCTAssertEqual(noIncident?.body, "See status.cf.test for details")
        XCTAssertEqual(noIncident?.url, vendor.pageURL)
    }
}
