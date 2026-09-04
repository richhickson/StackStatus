import SwiftUI

/// Add or edit one vendor: name, base URL, platform with Detect, feed URL,
/// and the optional probes.
struct VendorEditorView: View {
    @EnvironmentObject private var vendors: VendorsModel
    @Environment(\.dismiss) private var dismiss

    let existing: Vendor?
    let detector: PlatformDetector

    @State private var name: String
    @State private var baseURL: String
    @State private var incidentURL: String
    @State private var platform: Platform
    @State private var feedURL: String
    @State private var probes: [ProbeDraft]
    @State private var detecting = false
    @State private var detectMessage: String?

    init(vendor: Vendor?, detector: PlatformDetector) {
        existing = vendor
        self.detector = detector
        _name = State(initialValue: vendor?.name ?? "")
        _baseURL = State(initialValue: vendor?.baseURL.absoluteString ?? "https://")
        _incidentURL = State(initialValue: vendor?.incidentURL?.absoluteString ?? "")
        _platform = State(initialValue: vendor?.platform ?? .statuspage)
        _feedURL = State(initialValue: vendor?.feedURL?.absoluteString ?? "")
        _probes = State(initialValue: (vendor?.probes ?? []).map(ProbeDraft.init))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(existing == nil ? "Add vendor" : "Edit \(existing?.name ?? "vendor")")
                .font(.headline)
                .padding()
            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("Status page URL", text: $baseURL, prompt: Text("https://status.example.com"))
                    HStack {
                        Picker("Platform", selection: $platform) {
                            ForEach(Platform.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        Button(detecting ? "Detecting" : "Detect") { detect() }
                            .disabled(detecting || URL(string: baseURL)?.host == nil)
                    }
                    if let detectMessage {
                        Text(detectMessage).font(.caption).foregroundStyle(.secondary)
                    }
                    if platform == .feed {
                        TextField("Feed URL", text: $feedURL, prompt: Text("https://status.example.com/history.atom"))
                    }
                    TextField("Incident page URL (optional)", text: $incidentURL)
                }

                Section("Probes") {
                    ForEach($probes) { $probe in
                        ProbeDraftRow(probe: $probe) {
                            probes.removeAll { $0.id == probe.id }
                        }
                    }
                    Menu("Add probe") {
                        Button("HTTPS HEAD") { probes.append(ProbeDraft(kind: .httpsHead)) }
                        Button("TCP connect") { probes.append(ProbeDraft(kind: .tcp)) }
                        Button("DNS lookup") { probes.append(ProbeDraft(kind: .dns)) }
                    }
                    .fixedSize()
                    Text("Probes check the service itself, so the app can tell \"not posted yet\" from \"your connection\".")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            HStack {
                if existing != nil {
                    Button("Remove", role: .destructive) {
                        if let existing { vendors.remove(id: existing.id) }
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
            .padding()
        }
        .frame(width: 520, height: 560)
    }

    private var isValid: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty, let base = URL(string: baseURL), base.host != nil else { return false }
        if platform == .feed, URL(string: feedURL)?.host == nil { return false }
        return probes.allSatisfy { $0.spec != nil }
    }

    private func detect() {
        guard let base = URL(string: baseURL) else { return }
        detecting = true
        detectMessage = nil
        Task {
            let result = await detector.detect(baseURL: base)
            detecting = false
            if let result {
                platform = result.platform
                if let url = result.feedURL { feedURL = url.absoluteString }
                detectMessage = "Detected \(result.platform.label)."
            } else {
                detectMessage = "No known platform or feed found. Pick one by hand, or enter a feed URL."
            }
        }
    }

    private func save() {
        guard let base = URL(string: baseURL) else { return }
        let id = existing?.id ?? vendors.makeID(from: name)
        let vendor = Vendor(
            id: id,
            name: name.trimmingCharacters(in: .whitespaces),
            enabled: existing?.enabled ?? true,
            platform: platform,
            baseURL: base,
            incidentURL: URL(string: incidentURL).flatMap { $0.host == nil ? nil : $0 },
            feedURL: platform == .feed ? URL(string: feedURL) : nil,
            probes: probes.compactMap(\.spec),
            notes: existing?.notes
        )
        vendors.upsert(vendor)
        dismiss()
    }
}

/// A probe being edited: kind plus the free text fields for that kind.
struct ProbeDraft: Identifiable {
    enum Kind: String, CaseIterable {
        case httpsHead = "HTTPS HEAD"
        case tcp = "TCP"
        case dns = "DNS"
    }

    let id = UUID()
    var kind: Kind
    var url = ""
    var host = ""
    var port = "443"
    var resolver = ""

    init(kind: Kind) {
        self.kind = kind
    }

    init(_ spec: ProbeSpec) {
        switch spec {
        case .httpsHead(let url):
            kind = .httpsHead
            self.url = url.absoluteString
        case .tcp(let host, let port):
            kind = .tcp
            self.host = host
            self.port = String(port)
        case .dns(let host, let resolver):
            kind = .dns
            self.host = host
            self.resolver = resolver ?? ""
        }
    }

    var spec: ProbeSpec? {
        switch kind {
        case .httpsHead:
            guard let url = URL(string: url), url.scheme == "https", url.host != nil else { return nil }
            return .httpsHead(url: url)
        case .tcp:
            guard !host.isEmpty, let port = Int(port), (1...65535).contains(port) else { return nil }
            return .tcp(host: host, port: port)
        case .dns:
            guard !host.isEmpty else { return nil }
            let resolver = resolver.trimmingCharacters(in: .whitespaces)
            return .dns(host: host, resolver: resolver.isEmpty ? nil : resolver)
        }
    }
}

struct ProbeDraftRow: View {
    @Binding var probe: ProbeDraft
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Picker("", selection: $probe.kind) {
                ForEach(ProbeDraft.Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .frame(width: 110)
            switch probe.kind {
            case .httpsHead:
                TextField("https://api.example.com/", text: $probe.url)
            case .tcp:
                TextField("host", text: $probe.host)
                TextField("port", text: $probe.port).frame(width: 60)
            case .dns:
                TextField("name to resolve", text: $probe.host)
                TextField("resolver (optional)", text: $probe.resolver).frame(width: 130)
            }
            Button(role: .destructive, action: onRemove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
        }
        .textFieldStyle(.roundedBorder)
    }
}
