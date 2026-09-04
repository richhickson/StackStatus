import Foundation

/// Reads and writes vendors.json in Application Support. On first run the
/// bundled default list is copied there, and from then on the user's copy is
/// the only one consulted.
struct ConfigStore: Sendable {
    static let fileName = "vendors.json"
    static let bundledResourceName = "vendors"

    let directory: URL
    let bundledURL: URL?

    var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    init(directory: URL? = nil, bundledURL: URL? = Bundle.main.url(forResource: ConfigStore.bundledResourceName, withExtension: "json")) {
        self.directory = directory ?? Self.defaultDirectory()
        self.bundledURL = bundledURL
    }

    static func defaultDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("StackStatus", isDirectory: true)
    }

    static func decode(_ data: Data) throws -> VendorConfig {
        try JSONDecoder().decode(VendorConfig.self, from: data)
    }

    static func encode(_ config: VendorConfig) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(config)
    }

    func bundledConfig() -> VendorConfig {
        guard let bundledURL, let data = try? Data(contentsOf: bundledURL), let config = try? Self.decode(data) else {
            return VendorConfig(vendors: [])
        }
        return config
    }

    /// Load the user's list, seeding it from the bundle on first run.
    func load() throws -> VendorConfig {
        if let data = try? Data(contentsOf: fileURL) {
            return try Self.decode(data)
        }
        let seed = bundledConfig()
        try? save(seed)
        return seed
    }

    func save(_ config: VendorConfig) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encode(config).write(to: fileURL, options: .atomic)
    }

    /// Bundled vendors the user does not have yet, so a newer build can offer
    /// them without overwriting the user's edits.
    func newBundledVendors(comparedTo config: VendorConfig) -> [Vendor] {
        let existing = Set(config.vendors.map(\.id))
        return bundledConfig().vendors.filter { !existing.contains($0.id) }
    }
}
