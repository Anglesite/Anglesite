import Testing
import Foundation
@testable import AnglesiteCore

/// `WorkerCatalogPin` is generated from `scripts/worker-catalog.lock.json` by
/// `scripts/bump-worker-catalog.sh` (#1961, decision D7). These tests hold the generated
/// constants to the shape the fetchers rely on and keep them in lockstep with the lock file —
/// the Swift-side twin of `scripts/bump-worker-catalog.sh --check`, so a macOS `swift test` run
/// catches drift too, not just the Linux lane that runs the shell test.
struct WorkerCatalogPinTests {
    private static let hex40 = try! Regex("^[0-9a-f]{40}$")
    private static let hex64 = try! Regex("^[0-9a-f]{64}$")

    /// `Tests/AnglesiteCoreTests/<this file>` → repo root.
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test("the pin is a full commit SHA with 64-hex digests for both manifests")
    func pinHasWellFormedValues() throws {
        #expect(WorkerCatalogPin.repository == "davidwkeith/workers")
        #expect(WorkerCatalogPin.commit.wholeMatch(of: Self.hex40) != nil, "commit: \(WorkerCatalogPin.commit)")
        #expect(WorkerCatalogPin.catalogSHA256.wholeMatch(of: Self.hex64) != nil)
        #expect(WorkerCatalogPin.conformanceStatusSHA256.wholeMatch(of: Self.hex64) != nil)
        #expect(WorkerCatalogPin.catalogPath == "catalog.json")
        #expect(WorkerCatalogPin.conformanceStatusPath == "conformance/status.json")
    }

    @Test("URLs are commit-addressed raw.githubusercontent.com paths, never a branch ref")
    func urlsAreCommitAddressed() {
        let base = "https://raw.githubusercontent.com/davidwkeith/workers/\(WorkerCatalogPin.commit)"
        #expect(WorkerCatalogPin.catalogURL.absoluteString == "\(base)/catalog.json")
        #expect(WorkerCatalogPin.conformanceStatusURL.absoluteString == "\(base)/conformance/status.json")
        #expect(WorkerCatalogPin.url(forPath: "spec/x.json").absoluteString == "\(base)/spec/x.json")
        for url in [WorkerCatalogPin.catalogURL, WorkerCatalogPin.conformanceStatusURL] {
            #expect(!url.path.contains("/main/"), "\(url)")
            #expect(!url.path.contains("/refs/"), "\(url)")
        }
    }

    @Test("the generated Swift constants match scripts/worker-catalog.lock.json")
    func generatedConstantsMatchLockFile() throws {
        let lockURL = repoRoot.appendingPathComponent("scripts/worker-catalog.lock.json")
        let lock = try JSONSerialization.jsonObject(with: Data(contentsOf: lockURL)) as? [String: Any]
        let lockValues = try #require(lock, "lock file is a JSON object")
        #expect(lockValues["repository"] as? String == WorkerCatalogPin.repository)
        #expect(lockValues["commit"] as? String == WorkerCatalogPin.commit)
        #expect(lockValues["pinned_at"] as? String == WorkerCatalogPin.pinnedAt)
        #expect(lockValues["catalog_path"] as? String == WorkerCatalogPin.catalogPath)
        #expect(lockValues["catalog_sha256"] as? String == WorkerCatalogPin.catalogSHA256)
        #expect(lockValues["conformance_status_path"] as? String == WorkerCatalogPin.conformanceStatusPath)
        #expect(lockValues["conformance_status_sha256"] as? String == WorkerCatalogPin.conformanceStatusSHA256)
    }

    @Test("sha256Hex matches the FIPS 180-4 test vector and the lock's lowercase-hex encoding")
    func sha256HexKnownAnswer() {
        // FIPS 180-4 / RFC 6234 "abc" vector.
        #expect(
            PinnedManifestFetch.sha256Hex(Data("abc".utf8))
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        #expect(
            PinnedManifestFetch.sha256Hex(Data())
                == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
    }
}
