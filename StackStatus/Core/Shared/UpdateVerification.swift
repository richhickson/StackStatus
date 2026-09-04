import Foundation
import Security

/// Signature and identity checks for a downloaded StackStatus.app. Compiled
/// into both the app and the installer XPC service so both sides verify.
enum UpdateVerification {
    static let teamID = "DFL38M27U3"

    /// Anchor to Apple's Developer ID chain and require our team on the leaf.
    static func verifySignature(at appURL: URL, teamID: String = UpdateVerification.teamID) throws {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, [], &staticCode) == errSecSuccess, let code = staticCode else {
            throw UpdateError.unsigned
        }
        var requirement: SecRequirement?
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else {
            throw UpdateError.unsigned
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckNestedCode | kSecCSCheckAllArchitectures | kSecCSStrictValidate)
        guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else {
            throw UpdateError.wrongSigner
        }
    }

    static func verifyIdentity(at appURL: URL, bundleID: String, version expectedVersion: String) throws {
        guard let bundle = Bundle(url: appURL),
              bundle.bundleIdentifier == bundleID,
              let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            throw UpdateError.badArchive
        }
        guard normalise(version) == normalise(expectedVersion) else {
            throw UpdateError.versionMismatch(version)
        }
    }

    /// "v0.1.0" and "0.1.0" compare equal.
    static func normalise(_ version: String) -> String {
        var v = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.hasPrefix("v") || v.hasPrefix("V") { v.removeFirst() }
        return v
    }
}

enum UpdateError: LocalizedError {
    case downloadFailed
    case badArchive
    case unsigned
    case wrongSigner
    case versionMismatch(String)
    case helperUnavailable(String)
    case installFailed(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .downloadFailed: return "Download failed"
        case .badArchive: return "The archive did not contain StackStatus.app"
        case .unsigned: return "The update is not code signed"
        case .wrongSigner: return "The update is not signed by the expected developer"
        case .versionMismatch(let v): return "The archive contains version \(v), not the one announced"
        case .helperUnavailable(let why): return "Could not reach the installer helper: \(why)"
        case .installFailed(let why): return why
        case .commandFailed(let path): return "Update step failed (\(URL(fileURLWithPath: path).lastPathComponent))"
        }
    }
}
