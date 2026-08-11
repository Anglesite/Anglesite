import Testing
import Foundation
import AnglesiteCore
@testable import AnglesiteRemote

/// The helper is handed a site's `Source/` git repo, so the obvious key — that directory's last
/// path component — is the literal string `"Source"` for every site on the machine. Since the key
/// names both the `RemoteSessionRegistry` claim file and `ContainerizationControl`'s on-disk boot
/// artifacts, two sessions for two different sites would collide on both.
@Suite struct RemoteSiteIdentityTests {
    private static func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("site-identity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func usesThePackageMarkerUUIDForARealPackage() throws {
        let parent = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let packageURL = parent.appendingPathComponent("Foo.anglesite", isDirectory: true)
        let (package, marker) = try AnglesitePackage.createSkeleton(at: packageURL, displayName: "Foo")

        let id = RemoteSiteIdentity.siteID(forSourceDirectory: package.sourceURL)
        #expect(id == marker.siteID.uuidString)
        #expect(id != "Source")
    }

    /// Identity is the UUID, not the path — the whole reason the package model stores one.
    @Test func packageIdentitySurvivesAMove() throws {
        let parent = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let original = parent.appendingPathComponent("Foo.anglesite", isDirectory: true)
        let (package, marker) = try AnglesitePackage.createSkeleton(at: original, displayName: "Foo")
        #expect(RemoteSiteIdentity.siteID(forSourceDirectory: package.sourceURL) == marker.siteID.uuidString)

        let moved = parent.appendingPathComponent("Renamed.anglesite", isDirectory: true)
        try FileManager.default.moveItem(at: original, to: moved)
        let after = RemoteSiteIdentity.siteID(forSourceDirectory: AnglesitePackage(url: moved).sourceURL)
        #expect(after == marker.siteID.uuidString)
    }

    /// The fallback path — a bare directory that isn't a package, which is what
    /// `HelperContainerE2ETests`' own fixture is. Must be deterministic and distinct per site.
    @Test func fallsBackToAStablePerPathKeyForABareDirectory() throws {
        let first = try Self.makeTempDirectory()
        let second = try Self.makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        let firstID = RemoteSiteIdentity.siteID(forSourceDirectory: first)
        #expect(firstID == RemoteSiteIdentity.siteID(forSourceDirectory: first), "not deterministic")
        #expect(firstID != RemoteSiteIdentity.siteID(forSourceDirectory: second), "collides across sites")
        #expect(firstID != "Source")
        // Filesystem- and container-artifact-safe: this ends up inside `rootfs-<siteID>.ext4`.
        let bodyIsHex = firstID.hasPrefix("path-")
            && firstID.dropFirst("path-".count).allSatisfy(\.isHexDigit)
        #expect(bodyIsHex, "unexpected fallback key shape: \(firstID)")
    }

    /// The bug this exists to prevent, stated directly: two different sites, each handed as
    /// `<package>/Source`, must never produce the same key.
    @Test func twoSourceDirectoriesNeverCollideOnTheLiteralSourceComponent() throws {
        let parent = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let (a, _) = try AnglesitePackage.createSkeleton(
            at: parent.appendingPathComponent("A.anglesite", isDirectory: true), displayName: "A")
        let (b, _) = try AnglesitePackage.createSkeleton(
            at: parent.appendingPathComponent("B.anglesite", isDirectory: true), displayName: "B")
        #expect(a.sourceURL.lastPathComponent == b.sourceURL.lastPathComponent)  // both "Source"
        #expect(RemoteSiteIdentity.siteID(forSourceDirectory: a.sourceURL)
            != RemoteSiteIdentity.siteID(forSourceDirectory: b.sourceURL))
    }
}
