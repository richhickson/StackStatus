import AppKit

/// Entry point. The app is menubar only (LSUIElement), so there is no
/// SwiftUI App scene; AppDelegate owns the status item and popover.
@main
enum StackStatusMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
