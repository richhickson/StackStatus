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
}
