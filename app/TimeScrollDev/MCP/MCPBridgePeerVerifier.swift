import Foundation
import Security

/// Checks that a bridge client is TimeScroll's own MCP helper: same user, and either signed by
/// the same team as this app or the validly signed helper executable inside this app bundle
/// (development builds sign the helper ad hoc).
enum MCPBridgePeerVerifier {
    private static let localPeerToken: Int32 = 0x006 // LOCAL_PEERTOKEN in <sys/un.h>
    private static let solLocal: Int32 = 0           // SOL_LOCAL

    static func isTrusted(_ fd: Int32) -> Bool {
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { return false }

        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, solLocal, localPeerToken, &token, &length) == 0 else { return false }
        let tokenData = withUnsafeBytes(of: &token) { Data($0) }
        var guest: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: tokenData] as CFDictionary, [], &guest) == errSecSuccess,
              let guest else { return false }

        if let requirement = teamRequirement(), SecCodeCheckValidity(guest, [], requirement) == errSecSuccess {
            return true
        }
        guard SecCodeCheckValidity(guest, [], nil) == errSecSuccess else { return false }
        var staticCode: SecStaticCode?
        var path: CFURL?
        guard SecCodeCopyStaticCode(guest, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopyPath(staticCode, [], &path) == errSecSuccess, let peerURL = path as URL? else { return false }
        let bundledHelper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/timescroll-mcp.app")
        return peerURL.standardizedFileURL.resolvingSymlinksInPath() == bundledHelper.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// "signed by our team, as the MCP helper", when this app itself has a team identifier.
    private static let cachedTeamRequirement: SecRequirement? = {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return nil }
        var staticMe: SecStaticCode?
        guard SecCodeCopyStaticCode(me, [], &staticMe) == errSecSuccess, let staticMe else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticMe, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty else { return nil }
        var requirement: SecRequirement?
        let text = "identifier \"\(MCPBridge.helperBundleIdentifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }()

    private static func teamRequirement() -> SecRequirement? { cachedTeamRequirement }
}
