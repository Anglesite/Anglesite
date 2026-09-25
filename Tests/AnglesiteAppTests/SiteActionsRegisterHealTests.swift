import Testing
import Foundation
import AnglesiteCore
import AnglesiteSiteModel
@testable import AnglesiteAppCore

/// `registerPackage` is the single chokepoint every open path shares (Finder-open, launcher
/// drag-drop, Dock menu, File ▸ Open Site…, Import) — so it's where heal-on-open belongs (#877).
/// Uses a throwaway `SiteStore` (its own `persistenceURL`), never `.shared`, so this test can't
/// pollute or race a developer's real recents.json.
@Suite("SiteActions register heal-on-open")
@MainActor
struct SiteActionsRegisterHealTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("site-actions-heal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    private func git(_ arguments: [String], in dir: URL) async throws -> ProcessSupervisor.RunResult {
        try await ProcessSupervisor.shared.run(
            source: "test",
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["git"] + arguments,
            currentDirectoryURL: dir
        )
    }

    @Test("registering a package with an embedded Source/.git migrates it to the split layout")
    func registerHealsEmbeddedRepo() async throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let pkgURL = root.appendingPathComponent("Test.anglesite", isDirectory: true)
        let (pkg, _) = try AnglesitePackage.createSkeleton(at: pkgURL, displayName: "Test")
        try await git(["init"], in: pkg.sourceURL)
        try await git(["config", "user.email", "t@t.io"], in: pkg.sourceURL)
        try await git(["config", "user.name", "t"], in: pkg.sourceURL)
        try "seed".write(to: pkg.sourceURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try await git(["add", "-A"], in: pkg.sourceURL)
        try await git(["commit", "-m", "seed"], in: pkg.sourceURL)

        let store = SiteStore(persistenceURL: root.appendingPathComponent("recents.json"))
        let site = try await SiteActions.registerPackage(pkg, siteStore: store)

        var isDir: ObjCBool = false
        let gitPath = pkg.sourceURL.appendingPathComponent(".git")
        #expect(FileManager.default.fileExists(atPath: gitPath.path, isDirectory: &isDir) && !isDir.boolValue, "Source/.git is now a gitfile")
        #expect(FileManager.default.fileExists(atPath: pkg.liveRepositoryURL.appendingPathComponent("HEAD").path))
        #expect(await store.find(id: site.id) != nil, "the site was still recorded after healing")
    }

    @Test("registering an already-split package is a no-op for the repository layout")
    func registerNoOpOnAlreadySplit() async throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let pkgURL = root.appendingPathComponent("Test.anglesite", isDirectory: true)
        let (pkg, _) = try AnglesitePackage.createSkeleton(at: pkgURL, displayName: "Test")
        try await git(["init"], in: pkg.sourceURL)
        try await git(["config", "user.email", "t@t.io"], in: pkg.sourceURL)
        try await git(["config", "user.name", "t"], in: pkg.sourceURL)
        try "seed".write(to: pkg.sourceURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try await git(["add", "-A"], in: pkg.sourceURL)
        try await git(["commit", "-m", "seed"], in: pkg.sourceURL)

        let store = SiteStore(persistenceURL: root.appendingPathComponent("recents.json"))
        _ = try await SiteActions.registerPackage(pkg, siteStore: store)
        let gitPath = pkg.sourceURL.appendingPathComponent(".git")
        let contentsAfterFirstOpen = try String(contentsOf: gitPath, encoding: .utf8)

        // Re-open (e.g. Open Recent on a second launch).
        _ = try await SiteActions.registerPackage(pkg, siteStore: store)
        #expect(try String(contentsOf: gitPath, encoding: .utf8) == contentsAfterFirstOpen)
    }
}
