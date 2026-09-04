import SwiftUI

/// The dropdown: verdict line, vendor rows, baseline row, footer.
struct PopoverView: View {
    @EnvironmentObject private var store: StateStore
    @EnvironmentObject private var settings: AppSettings
    let actions: PopoverActions

    /// Re-renders relative times once a minute while the popover is open.
    @State private var now = Date()
    private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            vendorList
            Divider()
            BaselineRow(baseline: store.baseline)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Divider()
            footer
            credit
        }
        .frame(width: 340)
        .onReceive(ticker) { now = $0 }
        .onAppear { now = Date() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            StateDot(tone: store.headline.tone, size: 10)
            Text(store.headline.text)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)
            Spacer()
            if store.isRefreshing {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var vendorList: some View {
        VStack(spacing: 0) {
            if store.enabledEntries.isEmpty {
                Text("No vendors enabled. Add some in Settings.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(12)
            }
            ForEach(store.enabledEntries) { entry in
                VendorRow(entry: entry, now: now)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                if entry.id != store.enabledEntries.last?.id {
                    Divider().padding(.leading, 12)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(lastCheckedText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: actions.refresh) {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh now")
            .disabled(store.isRefreshing)
            Button(action: actions.openSettings) {
                Image(systemName: "gearshape")
            }
            .help("Settings")
            Button(action: actions.quit) {
                Image(systemName: "power")
            }
            .help("Quit StackStatus")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var credit: some View {
        HStack {
            Spacer()
            Link("Created by @richhickson", destination: URL(string: "https://x.com/richhickson")!)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.bottom, 6)
    }

    private var lastCheckedText: String {
        guard let checked = store.lastChecked else { return "Not checked yet" }
        var text = "Checked \(Formatting.ago(checked, now: now))"
        if store.lastCycleTimedOut { text += ", some checks timed out" }
        return text
    }
}

struct VendorRow: View {
    let entry: StateStore.VendorEntry
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                StateDot(tone: VerdictEngine.tone(for: entry.displayedState), size: 9)
                Text(entry.vendor.name)
                    .font(.system(size: 13, weight: .medium))
                Text(entry.displayedState.label)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                if entry.probeFailing, !entry.displayedState.isIncident {
                    Tag(text: "probe failing", color: .orange)
                }
                Spacer()
                if let since = entry.stateSince {
                    Text(Formatting.ago(since, now: now))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .help("Time since the state last changed")
                }
            }
            if let incident = entry.incident, entry.displayedState.isIncident {
                IncidentLink(incident: incident, fallback: entry.vendor.pageURL)
                    .padding(.leading, 17)
            } else if entry.displayedState == .unknown, let error = entry.errorText {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .padding(.leading, 17)
            }
        }
    }
}

struct IncidentLink: View {
    let incident: Incident
    let fallback: URL

    var body: some View {
        Button {
            NSWorkspace.shared.open(incident.url ?? fallback)
        } label: {
            HStack(spacing: 4) {
                Text(incident.title)
                    .font(.system(size: 11))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 9))
            }
            .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
        .help("Open the incident page")
    }
}

struct BaselineRow: View {
    let baseline: BaselineResult?

    var body: some View {
        HStack(spacing: 12) {
            BaselineItem(label: "Gateway", result: baseline?.gateway)
            BaselineItem(label: "DNS", result: baseline?.dns)
            BaselineItem(label: "Internet", result: baseline?.internet)
            Spacer()
        }
    }
}

struct BaselineItem: View {
    let label: String
    let result: ProbeResult?

    var body: some View {
        HStack(spacing: 4) {
            if let result {
                Image(systemName: result.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(result.ok ? Color.green : Color.red)
                    .font(.system(size: 11))
            } else {
                Image(systemName: "circle.dotted")
                    .foregroundStyle(.tertiary)
                    .font(.system(size: 11))
            }
            Text(label)
                .font(.system(size: 11))
                .fixedSize()
            if let latency = result?.latency, result?.ok == true {
                Text(Formatting.latency(latency))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
        }
        .lineLimit(1)
        .help(result?.detail ?? "Not checked yet")
    }
}

struct StateDot: View {
    let tone: Tone
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
    }

    private var color: Color {
        switch tone {
        case .good: return .green
        case .warning: return .orange
        case .bad: return .red
        case .neutral: return .gray
        }
    }
}

struct Tag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}
