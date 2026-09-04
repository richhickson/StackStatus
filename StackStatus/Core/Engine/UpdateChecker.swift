import Foundation
import Combine

/// A published GitHub release that is newer than the running app.
struct ReleaseInfo: Hashable, Sendable {
    var version: String
    var tag: String
    var pageURL: URL
    var downloadURL: URL?
    var size: Int?
    var notes: String?
}

/// Pure parsing and comparison for the GitHub releases API.
enum UpdateChecker {
    static let repository = "richhickson/StackStatus"
    static let latestReleaseURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!

    /// STACKSTATUS_DEBUG_UPDATE_URL points the checker at a local fixture for end to end tests.
    static var effectiveReleaseURL: URL {
        if let raw = ProcessInfo.processInfo.environment["STACKSTATUS_DEBUG_UPDATE_URL"], let url = URL(string: raw) { return url }
        return latestReleaseURL
    }
    static let assetName = "StackStatus.zip"

    static func parse(_ data: Data) throws -> ReleaseInfo {
        let json = try data.jsonObject()
        guard let tag = json.string("tag_name"), let page = json.url("html_url") else {
            throw AdapterError.malformed("GitHub release")
        }
        let asset = json.array("assets").first { $0.string("name") == assetName }
        return ReleaseInfo(
            version: normalise(tag),
            tag: tag,
            pageURL: page,
            downloadURL: asset?.url("browser_download_url"),
            size: asset?["size"] as? Int,
            notes: json.string("body")
        )
    }

    /// "v0.1.0" and "0.1.0" compare equal; "0.2" is 0.2.0.
    static func normalise(_ version: String) -> String {
        var v = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.hasPrefix("v") || v.hasPrefix("V") { v.removeFirst() }
        return v
    }

    static func components(_ version: String) -> [Int] {
        normalise(version).split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }

    static func isNewer(_ remote: String, than current: String) -> Bool {
        let r = components(remote)
        let c = components(current)
        let count = max(r.count, c.count)
        for i in 0..<count {
            let a = i < r.count ? r[i] : 0
            let b = i < c.count ? c[i] : 0
            if a != b { return a > b }
        }
        return false
    }
}

/// Checks for a newer release once a day, but only when the user has turned
/// it on, and on demand from the Check now button. The only thing sent is a
/// conditional GET to the GitHub releases API.
@MainActor
final class UpdateMonitor: ObservableObject {
    static let interval: TimeInterval = 24 * 60 * 60

    @Published private(set) var available: ReleaseInfo?
    @Published private(set) var lastChecked: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var isChecking = false

    let settings: AppSettings
    let currentVersion: String
    private let http: HTTPFetching
    private var loop: Task<Void, Never>?
    private var observation: AnyCancellable?

    init(settings: AppSettings, http: HTTPFetching, currentVersion: String = HTTPClient.version) {
        self.settings = settings
        self.http = http
        self.currentVersion = currentVersion
    }

    /// Follow the setting: run the daily loop while it is on, stop when off.
    func start() {
        observation = settings.$checkForUpdates
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled { self.startLoop() } else { self.stopLoop() }
            }
    }

    var isAutomatic: Bool { loop != nil }

    private func startLoop() {
        loop?.cancel()
        loop = Task { [weak self] in
            // First check a little after launch so it never competes with the first poll.
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            while !Task.isCancelled {
                guard let self else { return }
                await self.check(reason: "automatic")
                try? await Task.sleep(nanoseconds: UInt64(Self.interval * 1_000_000_000))
            }
        }
    }

    private func stopLoop() {
        loop?.cancel()
        loop = nil
    }

    /// The Check now button: explicit consent for this one request.
    func checkNow() async {
        await check(reason: "manual")
    }

    private func check(reason: String) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        do {
            switch try await http.get(UpdateChecker.effectiveReleaseURL, conditional: available != nil || lastChecked != nil) {
            case .notModified:
                break
            case .success(let data, _, _):
                let release = try UpdateChecker.parse(data)
                available = UpdateChecker.isNewer(release.version, than: currentVersion) ? release : nil
            }
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
        lastChecked = Date()
    }

    var statusText: String {
        if isChecking { return "Checking" }
        if let lastError { return "Check failed: \(lastError)" }
        guard let lastChecked else { return "Not checked yet" }
        let when = Formatting.ago(lastChecked)
        if let available { return "Version \(available.version) is available (checked \(when))" }
        return "Up to date, checked \(when)"
    }
}
