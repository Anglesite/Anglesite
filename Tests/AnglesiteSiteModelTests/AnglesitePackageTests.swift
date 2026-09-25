import Testing
import Foundation
@testable import AnglesiteSiteModel

/// Tests for `AnglesitePackage` (#242, P1): the `.anglesite` package on-disk format —
/// layout URLs and the `Info.plist` marker round-trip.
struct AnglesitePackageTests {
    /// A fresh temp directory per test; caller removes it.
    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("anglesite-pkg-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("layout URLs resolve under the package directory")
    func layoutURLs() throws {
        let pkgURL = URL(fileURLWithPath: "/tmp/Acme.anglesite", isDirectory: true)
        let pkg = AnglesitePackage(url: pkgURL)
        #expect(pkg.infoPlistURL.lastPathComponent == "Info.plist")
        #expect(pkg.sourceURL.lastPathComponent == "Source")
        #expect(pkg.configURL.lastPathComponent == "Config")
        #expect(pkg.sourceURL.deletingLastPathComponent().path == pkgURL.path)
    }

    @Test("packageRoot(fromSourceURL:) is the inverse of sourceURL")
    func packageRootFromSourceURLRoundTrips() {
        let root = URL(fileURLWithPath: "/tmp/my-site.anglesite", isDirectory: true)
        let pkg = AnglesitePackage(url: root)
        #expect(AnglesitePackage.packageRoot(fromSourceURL: pkg.sourceURL) == root)
    }

    @Test("wranglerConfigURL is Config/wrangler.toml — app-owned provisioning state, never inside Source/ (#1960)")
    func wranglerConfigURLResolvesUnderConfig() {
        let pkg = AnglesitePackage(url: URL(fileURLWithPath: "/tmp/Site.anglesite"))
        #expect(pkg.wranglerConfigURL == pkg.configURL.appendingPathComponent("wrangler.toml"))
        #expect(!pkg.wranglerConfigURL.path.hasPrefix(pkg.sourceURL.path))
        #expect(AnglesitePackage.wranglerConfigFilename == "wrangler.toml")
    }

    @Test("quickLookThumbnailURL resolves under Config/")
    func quickLookThumbnailURLResolves() throws {
        let pkgURL = URL(fileURLWithPath: "/tmp/Acme.anglesite", isDirectory: true)
        let pkg = AnglesitePackage(url: pkgURL)
        #expect(pkg.quickLookThumbnailURL.lastPathComponent == "quicklook-thumbnail.png")
        #expect(pkg.quickLookThumbnailURL.deletingLastPathComponent().path == pkg.configURL.path)
    }

    @Test("liveRepositoryURL is Config/repo.nosync — never uploaded by iCloud, never inside Source/")
    func liveRepositoryURLLayout() {
        let pkg = AnglesitePackage(url: URL(fileURLWithPath: "/tmp/Foo.anglesite"))
        #expect(pkg.liveRepositoryURL.path == "/tmp/Foo.anglesite/Config/repo.nosync")
        #expect(pkg.liveRepositoryURL.path.hasPrefix(pkg.configURL.path))
        #expect(!pkg.liveRepositoryURL.path.hasPrefix(pkg.sourceURL.path))
    }

    @Test("marker written to Info.plist round-trips through read")
    func markerRoundTrips() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pkg = AnglesitePackage(url: dir.appendingPathComponent("Acme.anglesite", isDirectory: true))

        let marker = AnglesitePackage.Marker(
            siteID: UUID(),
            displayName: "Acme",
            createdDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try pkg.writeMarker(marker)

        #expect(FileManager.default.fileExists(atPath: pkg.infoPlistURL.path))
        let read = try pkg.readMarker()
        #expect(read == marker)
        #expect(read.formatVersion == AnglesitePackage.currentFormatVersion)
    }

    @Test("Info.plist uses the spec's exact marker keys")
    func markerUsesSpecKeys() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pkg = AnglesitePackage(url: dir.appendingPathComponent("Acme.anglesite", isDirectory: true))
        try pkg.writeMarker(.init(displayName: "Acme"))

        let plist = try #require(NSDictionary(contentsOf: pkg.infoPlistURL))
        #expect(plist["AnglesiteFormatVersion"] != nil)
        #expect(plist["AnglesiteSiteID"] != nil)
        #expect(plist["AnglesiteDisplayName"] as? String == "Acme")
        #expect(plist["AnglesiteCreatedDate"] != nil)
    }

    @Test("readMarker throws markerMissing when Info.plist is absent")
    func readMarkerMissing() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pkg = AnglesitePackage(url: dir.appendingPathComponent("Empty.anglesite", isDirectory: true))
        #expect(throws: AnglesitePackage.PackageError.markerMissing(pkg.infoPlistURL)) {
            try pkg.readMarker()
        }
    }

    @Test("readMarker throws markerUnreadable (carrying the cause) when Info.plist is corrupt")
    func readMarkerCorrupt() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pkg = AnglesitePackage(url: dir.appendingPathComponent("Bad.anglesite", isDirectory: true))
        try FileManager.default.createDirectory(at: pkg.url, withIntermediateDirectories: true)
        try Data("not a plist".utf8).write(to: pkg.infoPlistURL)
        do {
            _ = try pkg.readMarker()
            Issue.record("expected readMarker to throw")
        } catch let AnglesitePackage.PackageError.markerUnreadable(url, underlying) {
            #expect(url == pkg.infoPlistURL)
            #expect(!(underlying is AnglesitePackage.PackageError), "underlying should be the real decode/read error")
        }
    }

    @Test("compatibility: equal or older format is current; newer is read-only")
    func compatibilityGate() {
        let current = AnglesitePackage.Marker(
            formatVersion: AnglesitePackage.currentFormatVersion, displayName: "A")
        let future = AnglesitePackage.Marker(
            formatVersion: AnglesitePackage.currentFormatVersion + 1, displayName: "B")
        // An older format opened by a newer build stays editable (guards against a `>=` typo).
        let past = AnglesitePackage.Marker(formatVersion: 0, displayName: "C")
        #expect(AnglesitePackage.compatibility(for: current) == .current)
        #expect(AnglesitePackage.compatibility(for: past) == .current)
        #expect(AnglesitePackage.compatibility(for: future) == .readOnlyTooNew)
    }

    @Test("createSkeleton lays down Source/, Config/, and a stamped marker")
    func createSkeletonLaysDownLayout() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pkgURL = dir.appendingPathComponent("Acme.anglesite", isDirectory: true)

        let (pkg, marker) = try AnglesitePackage.createSkeleton(at: pkgURL, displayName: "Acme")

        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: pkg.sourceURL.path, isDirectory: &isDir) && isDir.boolValue)
        #expect(FileManager.default.fileExists(atPath: pkg.configURL.path, isDirectory: &isDir) && isDir.boolValue)
        #expect(marker.displayName == "Acme")
        #expect(try pkg.readMarker() == marker)
    }

    @Test("isPackage is true only for an .anglesite dir with a readable marker")
    func isPackageDetection() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = dir.appendingPathComponent("Good.anglesite", isDirectory: true)
        _ = try AnglesitePackage.createSkeleton(at: good, displayName: "Good")
        let wrongExt = dir.appendingPathComponent("Plain", isDirectory: true)
        try FileManager.default.createDirectory(at: wrongExt, withIntermediateDirectories: true)
        let noMarker = dir.appendingPathComponent("Hollow.anglesite", isDirectory: true)
        try FileManager.default.createDirectory(at: noMarker, withIntermediateDirectories: true)
        // A regular file with the package extension is not a package.
        let fileNotDir = dir.appendingPathComponent("File.anglesite", isDirectory: false)
        try Data("x".utf8).write(to: fileNotDir)

        #expect(AnglesitePackage.isPackage(at: good))
        #expect(!AnglesitePackage.isPackage(at: wrongExt))
        #expect(!AnglesitePackage.isPackage(at: noMarker))
        #expect(!AnglesitePackage.isPackage(at: fileNotDir))
    }

    @Test("createSkeleton refuses to overwrite an existing path (protects the site UUID)")
    func createSkeletonRejectsExisting() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pkgURL = dir.appendingPathComponent("Dupe.anglesite", isDirectory: true)
        let (_, first) = try AnglesitePackage.createSkeleton(at: pkgURL, displayName: "Dupe")

        #expect(throws: AnglesitePackage.PackageError.alreadyExists(pkgURL)) {
            _ = try AnglesitePackage.createSkeleton(at: pkgURL, displayName: "Dupe2")
        }
        // The original marker (and its UUID) is untouched.
        #expect(try AnglesitePackage(url: pkgURL).readMarker().siteID == first.siteID)
    }

    /// A FileManager that fails when asked to create the `Config/` directory, to exercise the
    /// mid-creation rollback in `createSkeleton` (Source/ created, then Config/ throws).
    private final class FailOnConfigFileManager: FileManager, @unchecked Sendable {
        override func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool,
                                      attributes: [FileAttributeKey: Any]? = nil) throws {
            if url.lastPathComponent == "Config" { throw CocoaError(.fileWriteNoPermission) }
            try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
        }
    }

    @Test("createSkeleton rolls back the half-written package when a later step fails")
    func createSkeletonRollsBackOnFailure() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pkgURL = dir.appendingPathComponent("Boom.anglesite", isDirectory: true)

        #expect(throws: (any Error).self) {
            _ = try AnglesitePackage.createSkeleton(at: pkgURL, displayName: "Boom", fileManager: FailOnConfigFileManager())
        }
        // Source/ was created before Config/ failed; the defer must have removed the whole package.
        #expect(!FileManager.default.fileExists(atPath: pkgURL.path))
    }

    @Test("sourceValidation distinguishes missing-required from a partially-populated Source/")
    func sourceValidationPartialRequired() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (pkg, _) = try AnglesitePackage.createSkeleton(
            at: dir.appendingPathComponent("Partial.anglesite", isDirectory: true), displayName: "Partial")

        // Write only the first required sentinel; at least one required remains missing → invalid.
        let first = try #require(ProjectValidator.requiredSentinels.first)
        try Data("{}".utf8).write(to: pkg.sourceURL.appendingPathComponent(first))
        let result = pkg.sourceValidation()
        #expect(!result.isValid)
        #expect(!result.missingRequired.isEmpty)
        #expect(!result.missingRequired.contains(first))
    }

    @Test("sourceValidation reports missing sentinels in Source/")
    func sourceValidationReportsMissing() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pkgURL = dir.appendingPathComponent("Acme.anglesite", isDirectory: true)
        let (pkg, _) = try AnglesitePackage.createSkeleton(at: pkgURL, displayName: "Acme")

        // Empty Source/: invalid (all required sentinels missing).
        #expect(!pkg.sourceValidation().isValid)

        // Drop the required sentinels into Source/: now valid.
        for name in ProjectValidator.requiredSentinels {
            try Data("{}".utf8).write(to: pkg.sourceURL.appendingPathComponent(name))
        }
        #expect(pkg.sourceValidation().isValid)
    }
}
