import AppKit

/// Downloads a release zip, verifies it is signed by this app's Developer ID
/// team, then asks the embedded installer XPC service to replace the bundle
/// and relaunch. The service is the only unsandboxed code in the app; see
/// StackStatusInstaller/main.swift for why it has to exist.
@MainActor
final class UpdateInstaller: ObservableObject {
    enum State: Equatable {
        case idle
        case downloading
        case verifying
        case installing
        case relaunching
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private let session: URLSession

    init(session: URLSession) {
        self.session = session
    }

    var isBusy: Bool {
        switch state {
        case .idle, .failed: return false
        default: return true
        }
    }

    func reset() {
        state = .idle
    }

    func install(_ release: ReleaseInfo) async {
        guard !isBusy else { return }
        guard let downloadURL = release.downloadURL else {
            state = .failed("This release has no \(UpdateChecker.assetName) attached")
            return
        }
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("StackStatusUpdate-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: workDir) }

        do {
            state = .downloading
            try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
            let (tmpZip, response) = try await session.download(from: downloadURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.downloadFailed }
            let zip = workDir.appendingPathComponent("StackStatus.zip")
            try fm.moveItem(at: tmpZip, to: zip)

            // Verify here as well as in the helper, so nothing unsigned is even handed over.
            state = .verifying
            try Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, workDir.path])
            let extracted = workDir.appendingPathComponent("StackStatus.app")
            guard fm.fileExists(atPath: extracted.path) else { throw UpdateError.badArchive }
            try UpdateVerification.verifySignature(at: extracted)
            try UpdateVerification.verifyIdentity(at: extracted, bundleID: Self.bundleID, version: release.version)
            try? fm.removeItem(at: extracted)

            state = .installing
            try await Self.installViaHelper(zip: zip, destination: Bundle.main.bundleURL, version: release.version)

            state = .relaunching
            // The helper has already launched the new copy.
            try? await Task.sleep(nanoseconds: 500_000_000)
            NSApp.terminate(nil)
        } catch {
            state = .failed((error as? UpdateError)?.errorDescription ?? error.localizedDescription)
        }
    }

    nonisolated static var bundleID: String { Bundle.main.bundleIdentifier ?? "com.helpfullyit.stackstatus" }

    private static func installViaHelper(zip: URL, destination: URL, version: String) async throws {
        let connection = NSXPCConnection(serviceName: StackStatusInstallerService.name)
        connection.remoteObjectInterface = NSXPCInterface(with: StackStatusInstallerProtocol.self)
        connection.resume()
        defer { connection.invalidate() }

        let box = ContinuationBox<Result<Void, UpdateError>>()
        let result: Result<Void, UpdateError> = await withCheckedContinuation { continuation in
            box.store(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                box.resume(.failure(.helperUnavailable(error.localizedDescription)))
            } as? StackStatusInstallerProtocol
            guard let proxy else {
                box.resume(.failure(.helperUnavailable("no proxy")))
                return
            }
            proxy.install(
                zipPath: zip.path,
                destinationAppPath: destination.path,
                expectedTeamID: UpdateVerification.teamID,
                expectedBundleID: bundleID,
                expectedVersion: version
            ) { message in
                if let message {
                    box.resume(.failure(.installFailed(message)))
                } else {
                    box.resume(.success(()))
                }
            }
        }
        try result.get()
    }

    @discardableResult
    private static func run(_ path: String, _ args: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError.commandFailed(path) }
        return process.terminationStatus
    }
}
