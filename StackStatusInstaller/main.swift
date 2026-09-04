import Foundation

/// StackStatusInstaller: the one part of the app that is not sandboxed.
///
/// A sandboxed process cannot produce a launchable app bundle: everything it
/// writes carries a quarantine flag that LaunchServices refuses to execute.
/// So the sandboxed app downloads and verifies the update, then hands the zip
/// to this helper, which verifies it again, strips the quarantine flag,
/// replaces the bundle and launches the new copy. It does nothing else and
/// only accepts connections from the app it is embedded in.
final class InstallerService: NSObject, StackStatusInstallerProtocol {
    func install(
        zipPath: String,
        destinationAppPath: String,
        expectedTeamID: String,
        expectedBundleID: String,
        expectedVersion: String,
        reply: @escaping (String?) -> Void
    ) {
        do {
            try Self.perform(
                zip: URL(fileURLWithPath: zipPath),
                destination: URL(fileURLWithPath: destinationAppPath),
                teamID: expectedTeamID,
                bundleID: expectedBundleID,
                version: expectedVersion
            )
            reply(nil)
        } catch {
            reply((error as? UpdateError)?.errorDescription ?? error.localizedDescription)
        }
    }

    static func perform(zip: URL, destination: URL, teamID: String, bundleID: String, version: String) throws {
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("StackStatusInstall-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        try run("/usr/bin/ditto", ["-x", "-k", zip.path, workDir.path])
        let newApp = workDir.appendingPathComponent("StackStatus.app")
        guard fm.fileExists(atPath: newApp.path) else { throw UpdateError.badArchive }

        // The zip was written by a sandboxed process, so everything inside it
        // is quarantined. Remove that only after the signature checks pass.
        try UpdateVerification.verifySignature(at: newApp, teamID: teamID)
        try UpdateVerification.verifyIdentity(at: newApp, bundleID: bundleID, version: version)
        try run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])
        try UpdateVerification.verifySignature(at: newApp, teamID: teamID)

        let folder = destination.deletingLastPathComponent()
        guard fm.isWritableFile(atPath: folder.path) else {
            throw UpdateError.installFailed("No permission to replace the app in \(folder.lastPathComponent). Move StackStatus to a folder you can write to, or install the update by hand.")
        }
        let backup = folder.appendingPathComponent(".StackStatus-previous-\(UUID().uuidString.prefix(6)).app")
        if fm.fileExists(atPath: destination.path) {
            try fm.moveItem(at: destination, to: backup)
        }
        do {
            try fm.moveItem(at: newApp, to: destination)
        } catch {
            if fm.fileExists(atPath: backup.path) { try? fm.moveItem(at: backup, to: destination) }
            throw UpdateError.installFailed("Could not move the new app into place: \(error.localizedDescription)")
        }
        try? fm.removeItem(at: backup)

        // Launch the new copy as a fresh instance; the old one quits on reply.
        try run("/usr/bin/open", ["-n", destination.path])
    }

    private static func run(_ path: String, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError.commandFailed(path) }
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Only the app this service is embedded in may talk to it.
        connection.setCodeSigningRequirement(
            "anchor apple generic and identifier \"com.helpfullyit.stackstatus\" and certificate leaf[subject.OU] = \"\(UpdateVerification.teamID)\""
        )
        connection.exportedInterface = NSXPCInterface(with: StackStatusInstallerProtocol.self)
        connection.exportedObject = InstallerService()
        connection.resume()
        return true
    }
}

let delegate = ListenerDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
