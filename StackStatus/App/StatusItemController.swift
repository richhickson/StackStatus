import AppKit
import Combine

/// The menubar item: one filled circle, template rendered, tinted by tone.
/// Grey before the first poll and while the baseline is failing.
@MainActor
final class StatusItemController {
    let statusItem: NSStatusItem
    private let store: StateStore
    private let settings: AppSettings
    private var cancellables = Set<AnyCancellable>()
    private let onClick: () -> Void

    init(store: StateStore, settings: AppSettings, onClick: @escaping () -> Void) {
        self.store = store
        self.settings = settings
        self.onClick = onClick
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = Self.circleImage()
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(clicked)
            button.setAccessibilityLabel("StackStatus")
        }

        store.$headline
            .combineLatest(store.$entries, settings.$showTextBadge)
            .receive(on: RunLoop.main)
            .sink { [weak self] headline, entries, badge in
                self?.render(headline: headline, entries: entries, showBadge: badge)
            }
            .store(in: &cancellables)
    }

    @objc private func clicked() {
        onClick()
    }

    private func render(headline: Headline, entries: [StateStore.VendorEntry], showBadge: Bool) {
        guard let button = statusItem.button else { return }
        button.contentTintColor = Self.color(for: headline.tone)
        button.toolTip = headline.text

        let incidents = entries.filter { $0.vendor.enabled && $0.displayedState.isIncident }.count
        if showBadge, incidents > 0 {
            button.title = " \(incidents)"
        } else {
            button.title = ""
        }
    }

    static func color(for tone: Tone) -> NSColor {
        switch tone {
        case .good: return .systemGreen
        case .warning: return .systemOrange
        case .bad: return .systemRed
        case .neutral: return .systemGray
        }
    }

    /// A 12 point filled circle drawn as a template so the tint applies cleanly.
    static func circleImage() -> NSImage {
        let size = NSSize(width: 12, height: 12)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
