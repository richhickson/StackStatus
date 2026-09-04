import SwiftUI

/// The settings window: General and Vendors tabs.
struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var vendors: VendorsModel
    let detector: PlatformDetector

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            VendorsSettingsView(detector: detector)
                .tabItem { Label("Vendors", systemImage: "list.bullet") }
        }
        .frame(width: 560, height: 520)
    }
}

struct GeneralSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var updates: UpdateMonitor
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Polling") {
                Picker("Check every", selection: $settings.pollIntervalMinutes) {
                    ForEach(AppSettings.allowedIntervals, id: \.self) { minutes in
                        Text("\(minutes) minutes").tag(minutes)
                    }
                }
                Text("Drops to 2 minutes while any vendor has an incident, and stretches to three times this on battery when everything is fine.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Notifications") {
                Toggle("Notify on incident start and resolution", isOn: $settings.notificationsEnabled)
                Toggle("Quiet hours", isOn: $settings.quietHoursEnabled)
                    .disabled(!settings.notificationsEnabled)
                HStack {
                    MinutePicker(label: "From", minutes: $settings.quietStartMinutes)
                    MinutePicker(label: "to", minutes: $settings.quietEndMinutes)
                }
                .disabled(!settings.notificationsEnabled || !settings.quietHoursEnabled)
                Text("Quiet hours silence notifications. The menubar icon still updates.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Menubar") {
                Toggle("Show a count of vendors with incidents next to the icon", isOn: $settings.showTextBadge)
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        loginError = LoginItem.setEnabled(enabled)
                        if loginError != nil { launchAtLogin = LoginItem.isEnabled }
                    }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            }

            Section("Updates") {
                Toggle("Check for updates once a day", isOn: $settings.checkForUpdates)
                HStack {
                    Button("Check now") { Task { await updates.checkNow() } }
                        .disabled(updates.isChecking)
                    Text(updates.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text("Off by default. When on, the only thing sent is one GET to api.github.com for the latest release. Installing an update downloads the signed zip from GitHub, checks the Developer ID signature, then replaces the app in its folder and relaunches.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Baseline checks") {
                TextField("Known good HTTPS URL", text: $settings.internetURL)
                    .textFieldStyle(.roundedBorder)
                TextField("Known good DNS name", text: $settings.dnsHost)
                    .textFieldStyle(.roundedBorder)
                Text("Used to tell your connection apart from a vendor problem. Leave the defaults unless one of them is blocked on your network.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Text("StackStatus \(HTTPClient.version)")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Link("GitHub", destination: URL(string: HTTPClient.repositoryURL)!)
                }
                .font(.caption)
            }
        }
        .formStyle(.grouped)
    }
}

/// A time of day as minutes after midnight, edited through a DatePicker.
struct MinutePicker: View {
    let label: String
    @Binding var minutes: Int

    private var date: Binding<Date> {
        Binding(
            get: {
                let start = Calendar.current.startOfDay(for: Date())
                return start.addingTimeInterval(TimeInterval(minutes * 60))
            },
            set: { newValue in
                let components = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                minutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
            }
        )
    }

    var body: some View {
        DatePicker(label, selection: date, displayedComponents: .hourAndMinute)
            .datePickerStyle(.field)
            .labelsHidden()
            .overlay(alignment: .leading) {
                Text(label).offset(x: -40)
            }
            .padding(.leading, 40)
    }
}

struct VendorsSettingsView: View {
    @EnvironmentObject private var vendors: VendorsModel
    let detector: PlatformDetector

    @State private var editing: Vendor?
    @State private var addingNew = false
    @State private var confirmReset = false

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(vendors.vendors) { vendor in
                    HStack(spacing: 10) {
                        Toggle("", isOn: Binding(
                            get: { vendor.enabled },
                            set: { vendors.setEnabled($0, for: vendor.id) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(vendor.name).font(.system(size: 13, weight: .medium))
                            Text("\(vendor.platform.label) · \(vendor.baseURL.host ?? vendor.baseURL.absoluteString)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !vendor.probes.isEmpty {
                            Text("\(vendor.probes.count) probe\(vendor.probes.count == 1 ? "" : "s")")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                        Button("Edit") { editing = vendor }
                            .buttonStyle(.link)
                            .font(.system(size: 11))
                    }
                    .padding(.vertical, 2)
                    .contextMenu {
                        Button("Edit") { editing = vendor }
                        Button("Remove", role: .destructive) { vendors.remove(id: vendor.id) }
                    }
                }
                .onMove { vendors.move(from: $0, to: $1) }
                .onDelete { indices in
                    for index in indices { vendors.remove(id: vendors.vendors[index].id) }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))

            if let error = vendors.loadError {
                Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal)
            }

            HStack {
                Button("Add vendor") { addingNew = true }
                if !vendors.availableBundledVendors.isEmpty {
                    Menu("Add bundled") {
                        ForEach(vendors.availableBundledVendors) { vendor in
                            Button(vendor.name) { vendors.addBundled(vendor) }
                        }
                    }
                    .fixedSize()
                }
                Spacer()
                Button("Reveal vendors.json") {
                    NSWorkspace.shared.activateFileViewerSelecting([vendors.fileURL])
                }
                Button("Reset to bundled") { confirmReset = true }
            }
            .padding(12)
        }
        .sheet(isPresented: $addingNew) {
            VendorEditorView(vendor: nil, detector: detector)
        }
        .sheet(item: $editing) { vendor in
            VendorEditorView(vendor: vendor, detector: detector)
        }
        .confirmationDialog("Replace your vendor list with the bundled defaults?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { vendors.resetToBundled() }
        } message: {
            Text("Your edits and any vendors you added will be removed.")
        }
    }
}
