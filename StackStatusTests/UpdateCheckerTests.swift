import XCTest
@testable import StackStatus

final class UpdateCheckerTests: XCTestCase {
    private let latestURL = UpdateChecker.latestReleaseURL.absoluteString

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    func testParsesRealReleaseResponse() throws {
        let release = try UpdateChecker.parse(Fixtures.data("github_release_latest.json"))
        XCTAssertEqual(release.version, "0.1.0")
        XCTAssertEqual(release.tag, "v0.1.0")
        XCTAssertEqual(release.pageURL.absoluteString, "https://github.com/richhickson/StackStatus/releases/tag/v0.1.0")
        XCTAssertEqual(release.downloadURL?.absoluteString, "https://github.com/richhickson/StackStatus/releases/download/v0.1.0/StackStatus.zip")
        XCTAssertEqual(release.size, 866479)
        XCTAssertNotNil(release.notes)
    }

    func testReleaseWithoutAssetHasNoDownload() throws {
        let json = #"{"tag_name": "v9.9.9", "html_url": "https://example.test/r", "assets": [{"name": "other.zip", "browser_download_url": "https://example.test/o.zip"}]}"#
        let release = try UpdateChecker.parse(Data(json.utf8))
        XCTAssertNil(release.downloadURL)
        XCTAssertEqual(release.version, "9.9.9")
    }

    func testNormalise() {
        XCTAssertEqual(UpdateVerification.normalise("v1.2.3"), "1.2.3")
        XCTAssertEqual(UpdateVerification.normalise(" 1.2.3 "), "1.2.3")
    }

    func testVersionComparison() {
        XCTAssertTrue(UpdateChecker.isNewer("0.2.0", than: "0.1.0"))
        XCTAssertTrue(UpdateChecker.isNewer("v0.1.1", than: "0.1.0"))
        XCTAssertTrue(UpdateChecker.isNewer("1.0", than: "0.9.9"))
        XCTAssertTrue(UpdateChecker.isNewer("0.1.0.1", than: "0.1.0"))
        XCTAssertFalse(UpdateChecker.isNewer("0.1.0", than: "0.1.0"))
        XCTAssertFalse(UpdateChecker.isNewer("v0.1.0", than: "0.1"))
        XCTAssertFalse(UpdateChecker.isNewer("0.0.9", than: "0.1.0"))
        XCTAssertFalse(UpdateChecker.isNewer("garbage", than: "0.1.0"))
        XCTAssertTrue(UpdateChecker.isNewer("0.2.0-beta", than: "0.1.0"))
    }

    @MainActor
    private func makeMonitor(currentVersion: String, enabled: Bool) -> UpdateMonitor {
        let suite = "com.helpfullyit.stackstatus.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let settings = AppSettings(defaults: defaults)
        settings.checkForUpdates = enabled
        return UpdateMonitor(settings: settings, http: makeMockClient(), currentVersion: currentVersion)
    }

    @MainActor
    func testDefaultIsOffAndNothingIsSentWithoutConsent() async throws {
        let suite = "com.helpfullyit.stackstatus.tests.\(UUID().uuidString)"
        let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        XCTAssertFalse(settings.checkForUpdates, "update checks must be opt in")

        let monitor = UpdateMonitor(settings: settings, http: makeMockClient(), currentVersion: "0.0.1")
        monitor.start()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(monitor.isAutomatic)
        XCTAssertTrue(MockURLProtocol.requests.isEmpty, "no request without the setting on or a manual check")
    }

    @MainActor
    func testManualCheckFindsNewerRelease() async {
        MockURLProtocol.stub(latestURL, headers: ["ETag": "W/\"r1\""], fixture: "github_release_latest.json")
        let monitor = makeMonitor(currentVersion: "0.0.1", enabled: false)
        await monitor.checkNow()
        XCTAssertEqual(monitor.available?.version, "0.1.0")
        XCTAssertNotNil(monitor.lastChecked)
        XCTAssertNil(monitor.lastError)
        let request = MockURLProtocol.requests.first
        XCTAssertEqual(request?.httpMethod, "GET")
        XCTAssertEqual(request?.url?.absoluteString, latestURL)
        XCTAssertTrue(monitor.statusText.contains("0.1.0"))
    }

    @MainActor
    func testSameVersionIsNotAnUpdate() async {
        MockURLProtocol.stub(latestURL, fixture: "github_release_latest.json")
        let monitor = makeMonitor(currentVersion: "0.1.0", enabled: false)
        await monitor.checkNow()
        XCTAssertNil(monitor.available)
        XCTAssertTrue(monitor.statusText.hasPrefix("Up to date"))
    }

    @MainActor
    func testNotModifiedKeepsPreviousAnswer() async {
        MockURLProtocol.stub(latestURL, headers: ["ETag": "W/\"r1\""], fixture: "github_release_latest.json")
        let monitor = makeMonitor(currentVersion: "0.0.1", enabled: false)
        await monitor.checkNow()
        MockURLProtocol.stub(latestURL, status: 304, headers: ["ETag": "W/\"r1\""])
        await monitor.checkNow()
        XCTAssertEqual(monitor.available?.version, "0.1.0")
        XCTAssertEqual(MockURLProtocol.requests.last?.value(forHTTPHeaderField: "If-None-Match"), "W/\"r1\"")
    }

    @MainActor
    func testFailureIsReportedNotFatal() async {
        MockURLProtocol.stub(latestURL, status: 503)
        let monitor = makeMonitor(currentVersion: "0.0.1", enabled: false)
        await monitor.checkNow()
        XCTAssertNil(monitor.available)
        XCTAssertNotNil(monitor.lastError)
        XCTAssertTrue(monitor.statusText.hasPrefix("Check failed"))
    }

    @MainActor
    func testTurningTheSettingOnStartsTheLoop() async throws {
        let monitor = makeMonitor(currentVersion: "0.0.1", enabled: false)
        monitor.start()
        XCTAssertFalse(monitor.isAutomatic)
        monitor.settings.checkForUpdates = true
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(monitor.isAutomatic)
        monitor.settings.checkForUpdates = false
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(monitor.isAutomatic)
    }

    func testSignatureCheckRejectsUnsignedBundle() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fake-\(UUID().uuidString).app/Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not a binary".utf8).write(to: dir.appendingPathComponent("StackStatus"))
        let app = dir.deletingLastPathComponent().deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: app) }
        XCTAssertThrowsError(try UpdateVerification.verifySignature(at: app))
        XCTAssertThrowsError(try UpdateVerification.verifyIdentity(at: app, bundleID: "com.helpfullyit.stackstatus", version: "0.2.0"))
    }
}
