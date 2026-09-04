import Foundation
import Combine

/// The editable vendor list behind the settings window. Every change is
/// written to disk and announced so the scheduler and state store follow.
@MainActor
final class VendorsModel: ObservableObject {
    @Published private(set) var config: VendorConfig
    @Published private(set) var loadError: String?

    private let store: ConfigStore
    var onChange: (([Vendor]) -> Void)?

    init(store: ConfigStore) {
        self.store = store
        do {
            config = try store.load()
        } catch {
            config = VendorConfig(vendors: [])
            loadError = "Could not read vendors.json: \(error.localizedDescription)"
        }
    }

    var vendors: [Vendor] { config.vendors }

    var fileURL: URL { store.fileURL }

    /// Bundled vendors missing from the user's list, offered as one click adds.
    var availableBundledVendors: [Vendor] { store.newBundledVendors(comparedTo: config) }

    func setEnabled(_ enabled: Bool, for id: String) {
        guard let index = config.vendors.firstIndex(where: { $0.id == id }) else { return }
        config.vendors[index].enabled = enabled
        persist()
    }

    func move(from source: IndexSet, to destination: Int) {
        config.vendors.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    func remove(id: String) {
        config.vendors.removeAll { $0.id == id }
        persist()
    }

    /// Insert or replace by id.
    func upsert(_ vendor: Vendor) {
        if let index = config.vendors.firstIndex(where: { $0.id == vendor.id }) {
            config.vendors[index] = vendor
        } else {
            config.vendors.append(vendor)
        }
        persist()
    }

    func addBundled(_ vendor: Vendor) {
        upsert(vendor)
    }

    func resetToBundled() {
        config = store.bundledConfig()
        persist()
    }

    /// A slug that is unique in the current list.
    func makeID(from name: String) -> String {
        let base = name.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let candidate = base.isEmpty ? "vendor" : base
        var id = candidate
        var n = 2
        while config.vendors.contains(where: { $0.id == id }) {
            id = "\(candidate)-\(n)"
            n += 1
        }
        return id
    }

    private func persist() {
        do {
            try store.save(config)
            loadError = nil
        } catch {
            loadError = "Could not save vendors.json: \(error.localizedDescription)"
        }
        onChange?(config.vendors)
    }
}
