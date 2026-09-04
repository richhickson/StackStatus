import Foundation

/// The contract between the sandboxed app and its unsandboxed installer
/// XPC service. Shared source, compiled into both targets.
@objc protocol StackStatusInstallerProtocol {
    /// Extract `zipPath`, strip quarantine, verify the Developer ID signature,
    /// bundle identifier and version, replace the app at `destinationAppPath`,
    /// and launch the new copy. `reply` gets nil on success or an error message.
    func install(
        zipPath: String,
        destinationAppPath: String,
        expectedTeamID: String,
        expectedBundleID: String,
        expectedVersion: String,
        reply: @escaping (String?) -> Void
    )
}

enum StackStatusInstallerService {
    static let name = "com.helpfullyit.stackstatus.installer"
}
