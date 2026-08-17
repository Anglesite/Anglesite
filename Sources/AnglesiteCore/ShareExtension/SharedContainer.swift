import Foundation
#if canImport(Security)
import Security
#endif

/// Resolves the App Group container both the main app and the share extension are members of
/// (#1450). `nil` whenever the App Group entitlement/capability isn't present — every ad-hoc/
/// no-Team Debug build, and any environment (including `swift test`) without the real
/// provisioning profile this needs. Every caller treats `nil` as "sharing is unavailable right
/// now", never a crash — matches this codebase's established best-effort rule for optional
/// capabilities.
public enum SharedContainer {
    /// Must match `com.apple.security.application-groups` in both
    /// `Resources/Anglesite*.entitlements` and
    /// `Resources/ShareExtension/AnglesiteShareExtension*.entitlements`.
    public static let appGroupIdentifier = "group.io.dwk.anglesite"

    /// The directory the shared site manifest lives in, or `nil` if the App Group isn't
    /// available to this process.
    public static func url(fileManager: FileManager = .default) -> URL? {
        #if os(macOS)
        guard hasAppGroupEntitlement else { return nil }
        return fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent("Library/Application Support/Anglesite", isDirectory: true)
        #else
        return nil          // No App Group consumer off macOS (#1450 ships a macOS share extension only).
        #endif
    }

    /// `true` only when this process's own code signature carries `appGroupIdentifier` in its
    /// `com.apple.security.application-groups` entitlement. Queried via `SecTask`, mirroring this
    /// codebase's established entitlement-check shape (`VirtualizationEntitlement.isPresent`,
    /// `anglesite-remote-helper`'s `processCarriesCloudKitEntitlement`) — not inferred from
    /// `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`'s own return value.
    /// Outside an App Sandbox (every `swift test` run, and any ad-hoc/no-Team Debug build), that
    /// API happily synthesizes a container path for a group identifier the process was never
    /// entitled to — sandbox enforcement, not the API itself, is what normally blocks that, so an
    /// unsandboxed caller with no entitlement at all still gets a non-nil URL back. Checking the
    /// signed entitlement directly is the only way to get an honest answer in that case.
    private static var hasAppGroupEntitlement: Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let groups = SecTaskCopyValueForEntitlement(
            task, "com.apple.security.application-groups" as CFString, nil) as? [String]
        return groups?.contains(appGroupIdentifier) == true
        #else
        return false
        #endif
    }
}
