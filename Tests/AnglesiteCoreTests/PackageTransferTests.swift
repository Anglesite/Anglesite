import Testing
import Foundation
import AnglesiteSiteModel
@testable import AnglesiteCore

struct PackageTransferTests {
    private func tempDir() throws -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("pkg-transfer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test("import copies the dir tree into Source/, preserves .git, migrates .anglesite/ to Config/, writes a fresh marker, leaves the original untouched")
    func importCopiesIntoSource() throws {
        let fm = FileManager.default
        let root = try tempDir(); defer { try? fm.removeItem(at: root) }

        // A plain Anglesite site dir with a git repo, sentinels, and a legacy .anglesite/ history.
        let src = root.appendingPathComponent("legacy-site", isDirectory: true)
        try fm.createDirectory(at: src.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try Data("[core]".utf8).write(to: src.appendingPathComponent(".git/config"))
        for s in ProjectValidator.requiredSentinels {
            try Data("{}".utf8).write(to: src.appendingPathComponent(s))
        }
        try fm.createDirectory(at: src.appendingPathComponent(".anglesite"), withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: src.appendingPathComponent(".anglesite/chat-history.jsonl"))

        let pkgURL = root.appendingPathComponent("Imported.anglesite", isDirectory: true)
        let pkg = try PackageTransfer.importDirectory(src, toPackageAt: pkgURL, displayName: "Imported", fileManager: fm)

        // Source/ holds the copied tree incl. .git; sentinels present.
        #expect(fm.fileExists(atPath: pkg.sourceURL.appendingPathComponent(".git/config").path))
        #expect(pkg.sourceValidation(fileManager: fm).isValid)
        // Legacy .anglesite/ migrated to Config/, and removed from Source/.
        #expect(fm.fileExists(atPath: pkg.configURL.appendingPathComponent("chat-history.jsonl").path))
        #expect(!fm.fileExists(atPath: pkg.sourceURL.appendingPathComponent(".anglesite").path))
        // Fresh marker.
        #expect((try? pkg.readMarker().displayName) == "Imported")
        // Original untouched.
        #expect(fm.fileExists(atPath: src.appendingPathComponent(".anglesite/chat-history.jsonl").path))
    }

    @Test("import throws when the source is not a directory")
    func importRejectsNonDirectory() throws {
        let fm = FileManager.default
        let root = try tempDir(); defer { try? fm.removeItem(at: root) }
        let file = root.appendingPathComponent("not-a-dir.txt")
        try Data("x".utf8).write(to: file)
        #expect(throws: PackageTransfer.TransferError.sourceNotADirectory(file)) {
            _ = try PackageTransfer.importDirectory(file, toPackageAt: root.appendingPathComponent("X.anglesite"), displayName: "X", fileManager: fm)
        }
    }

    private func makePackageWithSource(in root: URL) throws -> AnglesitePackage {
        let fm = FileManager.default
        let (pkg, _) = try AnglesitePackage.createSkeleton(at: root.appendingPathComponent("Acme.anglesite", isDirectory: true), displayName: "Acme")
        try Data("// astro".utf8).write(to: pkg.sourceURL.appendingPathComponent("astro.config.ts"))
        try fm.createDirectory(at: pkg.sourceURL.appendingPathComponent("node_modules/foo"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: pkg.sourceURL.appendingPathComponent("node_modules/foo/index.js"))
        try fm.createDirectory(at: pkg.sourceURL.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try Data("[core]".utf8).write(to: pkg.sourceURL.appendingPathComponent(".git/config"))
        return pkg
    }

    @Test("export copies Source/ out, always excluding node_modules; .git excluded by default")
    func exportExcludesByDefault() throws {
        let fm = FileManager.default
        let root = try tempDir(); defer { try? fm.removeItem(at: root) }
        let pkg = try makePackageWithSource(in: root)
        let dest = root.appendingPathComponent("exported", isDirectory: true)

        try PackageTransfer.exportSource(of: pkg, to: dest, includeGit: false, fileManager: fm)

        #expect(fm.fileExists(atPath: dest.appendingPathComponent("astro.config.ts").path))
        #expect(!fm.fileExists(atPath: dest.appendingPathComponent("node_modules").path))
        #expect(!fm.fileExists(atPath: dest.appendingPathComponent(".git").path))
    }

    @Test("export keeps .git when includeGit is true")
    func exportKeepsGitWhenRequested() throws {
        let fm = FileManager.default
        let root = try tempDir(); defer { try? fm.removeItem(at: root) }
        let pkg = try makePackageWithSource(in: root)
        let dest = root.appendingPathComponent("exported-git", isDirectory: true)

        try PackageTransfer.exportSource(of: pkg, to: dest, includeGit: true, fileManager: fm)

        #expect(fm.fileExists(atPath: dest.appendingPathComponent(".git/config").path))
        #expect(!fm.fileExists(atPath: dest.appendingPathComponent("node_modules").path))
    }

    @Test("export throws .destinationExists when the destination already exists")
    func exportThrowsDestinationExists() throws {
        let fm = FileManager.default
        let root = try tempDir(); defer { try? fm.removeItem(at: root) }
        let pkg = try makePackageWithSource(in: root)
        let dest = root.appendingPathComponent("already-here", isDirectory: true)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        #expect(throws: PackageTransfer.TransferError.destinationExists(dest)) {
            try PackageTransfer.exportSource(of: pkg, to: dest, includeGit: false, fileManager: fm)
        }
    }

    @Test("import throws .destinationExists when package URL already exists")
    func importThrowsDestinationExists() throws {
        let fm = FileManager.default
        let root = try tempDir(); defer { try? fm.removeItem(at: root) }

        let src = root.appendingPathComponent("source-dir", isDirectory: true)
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        for s in ProjectValidator.requiredSentinels {
            try Data("{}".utf8).write(to: src.appendingPathComponent(s))
        }

        let pkgURL = root.appendingPathComponent("Collision.anglesite", isDirectory: true)
        try fm.createDirectory(at: pkgURL, withIntermediateDirectories: true)

        #expect(throws: PackageTransfer.TransferError.destinationExists(pkgURL)) {
            _ = try PackageTransfer.importDirectory(src, toPackageAt: pkgURL, displayName: "Collision", fileManager: fm)
        }
    }

    @Test("export re-embeds a real .git directory when Source/.git has been migrated to a gitfile")
    func exportReembedsMigratedRepo() async throws {
        let fm = FileManager.default
        let root = try tempDir(); defer { try? fm.removeItem(at: root) }

        let pkgURL = root.appendingPathComponent("Migrated.anglesite", isDirectory: true)
        let (pkg, _) = try AnglesitePackage.createSkeleton(at: pkgURL, displayName: "Migrated")
        try await gitFixture(["init"], in: pkg.sourceURL)
        try await gitFixture(["config", "user.email", "t@t.io"], in: pkg.sourceURL)
        try await gitFixture(["config", "user.name", "t"], in: pkg.sourceURL)
        try "seed".write(to: pkg.sourceURL.appendingPathComponent("index.md"), atomically: true, encoding: .utf8)
        try await gitFixture(["add", "-A"], in: pkg.sourceURL)
        try await gitFixture(["commit", "-m", "seed"], in: pkg.sourceURL)
        #if canImport(Darwin)
        _ = try RepoRelocator.migrate(package: pkg)
        #endif

        let dest = root.appendingPathComponent("exported", isDirectory: true)
        try PackageTransfer.exportSource(of: pkg, to: dest, includeGit: true, fileManager: fm)

        var isDir: ObjCBool = false
        #expect(fm.fileExists(atPath: dest.appendingPathComponent(".git").path, isDirectory: &isDir) && isDir.boolValue,
                "the exported .git is a real directory, not the package's gitfile")
        #expect(fm.fileExists(atPath: dest.appendingPathComponent(".git/HEAD").path))
        #expect(fm.fileExists(atPath: dest.appendingPathComponent("index.md").path))
    }

    @Test("export -> re-import round-trips: the re-imported package has a real embedded .git again")
    func exportThenReimportRoundTrips() async throws {
        let fm = FileManager.default
        let root = try tempDir(); defer { try? fm.removeItem(at: root) }

        let pkgURL = root.appendingPathComponent("Migrated.anglesite", isDirectory: true)
        let (pkg, _) = try AnglesitePackage.createSkeleton(at: pkgURL, displayName: "Migrated")
        try await gitFixture(["init"], in: pkg.sourceURL)
        try await gitFixture(["config", "user.email", "t@t.io"], in: pkg.sourceURL)
        try await gitFixture(["config", "user.name", "t"], in: pkg.sourceURL)
        try "seed".write(to: pkg.sourceURL.appendingPathComponent("index.md"), atomically: true, encoding: .utf8)
        try await gitFixture(["add", "-A"], in: pkg.sourceURL)
        try await gitFixture(["commit", "-m", "seed"], in: pkg.sourceURL)
        #if canImport(Darwin)
        _ = try RepoRelocator.migrate(package: pkg)
        #endif

        let exported = root.appendingPathComponent("exported", isDirectory: true)
        try PackageTransfer.exportSource(of: pkg, to: exported, includeGit: true, fileManager: fm)

        let reimportedURL = root.appendingPathComponent("Reimported.anglesite", isDirectory: true)
        let reimported = try PackageTransfer.importDirectory(exported, toPackageAt: reimportedURL, displayName: "Reimported", fileManager: fm)

        var isDir: ObjCBool = false
        #expect(fm.fileExists(atPath: reimported.sourceURL.appendingPathComponent(".git").path, isDirectory: &isDir) && isDir.boolValue)
        #expect(fm.fileExists(atPath: reimported.sourceURL.appendingPathComponent("index.md").path))
    }

    @discardableResult
    private func gitFixture(_ arguments: [String], in dir: URL) async throws -> ProcessSupervisor.RunResult {
        try await ProcessSupervisor.shared.run(
            source: "test",
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["git"] + arguments,
            currentDirectoryURL: dir
        )
    }
}
