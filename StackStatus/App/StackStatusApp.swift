import AppKit

/// Entry point. The app is menubar only (LSUIElement), so there is no
/// SwiftUI App scene; AppDelegate owns the status item and popover.
///
/// `--once` runs a single poll cycle headlessly, prints it, and exits.
@main
enum StackStatusMain {
    static func main() {
        if CommandLine.arguments.contains("--once") {
            Task.detached {
                let code = await HeadlessRunner.runOnce()
                exit(code)
            }
            RunLoop.main.run()
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
