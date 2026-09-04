import AppKit
import SwiftUI

/// Actions the popover can trigger, injected so the view stays dumb.
struct PopoverActions {
    var refresh: () -> Void
    var openSettings: () -> Void
    var quit: () -> Void
}

/// Hosts the SwiftUI popover under the status item.
@MainActor
final class PopoverController {
    let popover: NSPopover

    init(store: StateStore, settings: AppSettings, actions: PopoverActions) {
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        let root = PopoverView(actions: actions)
            .environmentObject(store)
            .environmentObject(settings)
        let host = NSHostingController(rootView: root)
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
    }

    func toggle(relativeTo button: NSStatusBarButton) {
        if popover.isShown {
            close()
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func close() {
        popover.performClose(nil)
    }

    /// Render the popover content off screen to a PNG at 2x, for documentation.
    func writeSnapshot(to path: String) {
        guard let view = popover.contentViewController?.view else { return }
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        // The sandbox only allows writes inside the container, so a bare
        // filename lands in the app's temporary directory.
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : FileManager.default.temporaryDirectory.appendingPathComponent(path)
        do {
            try png.write(to: url)
            FileHandle.standardError.write(Data("snapshot: \(url.path)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
        }
    }
}
