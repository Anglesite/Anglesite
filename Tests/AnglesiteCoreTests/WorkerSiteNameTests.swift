import Testing
import Foundation
@testable import AnglesiteCore

/// `WorkerSiteName` is the one derivation both the deploy path
/// (`DeployCoordinator.resolveWorkerSiteName`) and the local wrangler-dev path
/// (`ContainerizationControl.startWorkersDev`) run a site's identity through before it becomes a
/// wrangler `name` (#1750). The rules asserted here mirror wrangler's own config validator —
/// `name` must be lowercase alphanumerics/underscores/dashes; an R2 `bucket_name` must be
/// lowercase alphanumerics/hyphens, 3–63 characters, starting and ending alphanumeric — so a
/// regression here is caught by `swift test` rather than by a crash-looping `wrangler dev`.
@Suite("WorkerSiteName")
struct WorkerSiteNameTests {
    private let uuidSiteID = "F0EF6A17-9948-4157-98CE-A6D8234BA0AF"

    /// Every resource-name suffix `WorkerComposition.generateWranglerToml` appends to the site
    /// name. Kept in the test (not read from production) so a new suffix that outgrows the
    /// length budget fails loudly here instead of only under wrangler.
    private let resourceSuffixes = ["-social", "-media", "-pod-blobs", "-webmention", "-websub", "-microsub"]

    // MARK: - derive

    @Test("a stock uppercase UUID site id derives to its lowercased form, which wrangler accepts")
    func uuidDerivesToLowercase() {
        let name = WorkerSiteName.derive(from: uuidSiteID)
        #expect(name == "f0ef6a17-9948-4157-98ce-a6d8234ba0af")
        #expect(WorkerSiteName.isValidWorkerName(name))
    }

    @Test("every R2 bucket name derived from a UUID site id satisfies wrangler's bucket rule")
    func uuidDerivedBucketNamesAreValid() {
        let name = WorkerSiteName.derive(from: uuidSiteID)
        for suffix in resourceSuffixes {
            #expect(WorkerSiteName.isValidR2BucketName(name + suffix), "\(name + suffix)")
        }
    }

    @Test("the derived name is deterministic, so a restarted local session reuses its state")
    func deriveIsStable() {
        #expect(WorkerSiteName.derive(from: uuidSiteID) == WorkerSiteName.derive(from: uuidSiteID))
    }

    @Test("an already-valid slug passes through unchanged")
    func validSlugUnchanged() {
        #expect(WorkerSiteName.derive(from: "my-site") == "my-site")
        #expect(WorkerSiteName.derive(from: "workers-dev-e2e") == "workers-dev-e2e")
        #expect(WorkerSiteName.derive(from: "site42") == "site42")
    }

    @Test("a display name derives the same slug SiteSlug produces (deploy-path parity)")
    func displayNameMatchesSiteSlug() {
        #expect(WorkerSiteName.derive(from: "My Cool Site") == SiteSlug.derive(from: "My Cool Site"))
        #expect(WorkerSiteName.derive(from: "Café Niño") == "cafe-nino")
    }

    @Test("an empty or symbol-only identity still yields a valid name")
    func emptyFallsBackToValidName() {
        let name = WorkerSiteName.derive(from: "   ")
        #expect(name == "untitled-site")
        #expect(WorkerSiteName.isValidWorkerName(name))
        #expect(WorkerSiteName.isValidR2BucketName(name + "-media"))
    }

    @Test("a name exactly at the length budget is kept whole")
    func exactMaxLengthKept() {
        let raw = String(repeating: "a", count: WorkerSiteName.maxLength)
        #expect(WorkerSiteName.derive(from: raw) == raw)
    }

    @Test("an over-long name is truncated so its longest derived resource name still fits 63 chars")
    func overLongNameTruncated() {
        let raw = String(repeating: "ab", count: 60)  // 120 chars
        let name = WorkerSiteName.derive(from: raw)
        #expect(name.count == WorkerSiteName.maxLength)
        #expect(raw.hasPrefix(name))
        for suffix in resourceSuffixes {
            #expect(WorkerSiteName.isValidR2BucketName(name + suffix), "\(name + suffix)")
        }
    }

    @Test("truncation never leaves a trailing hyphen, which wrangler's bucket rule rejects")
    func truncationTrimsTrailingHyphen() {
        // A hyphen lands exactly at the cut point.
        let raw = String(repeating: "a", count: WorkerSiteName.maxLength - 1) + "-bcdefgh"
        let name = WorkerSiteName.derive(from: raw)
        #expect(!name.hasSuffix("-"))
        #expect(name == String(repeating: "a", count: WorkerSiteName.maxLength - 1))
        #expect(WorkerSiteName.isValidR2BucketName(name + "-media"))
    }

    // MARK: - isValidWorkerName (wrangler's `name` rule)

    @Test("worker-name rule accepts lowercase alphanumerics, underscores, and dashes")
    func workerNameAccepts() {
        #expect(WorkerSiteName.isValidWorkerName("my-site"))
        #expect(WorkerSiteName.isValidWorkerName("my_site"))
        #expect(WorkerSiteName.isValidWorkerName("42"))
        #expect(WorkerSiteName.isValidWorkerName("a"))
        #expect(WorkerSiteName.isValidWorkerName("f0ef6a17-9948-4157-98ce-a6d8234ba0af"))
    }

    @Test("worker-name rule rejects what wrangler rejects: uppercase, leading dash, empty, other chars")
    func workerNameRejects() {
        #expect(!WorkerSiteName.isValidWorkerName("F0EF6A17-9948-4157-98CE-A6D8234BA0AF"))
        #expect(!WorkerSiteName.isValidWorkerName("MySite"))
        #expect(!WorkerSiteName.isValidWorkerName("-leading"))
        #expect(!WorkerSiteName.isValidWorkerName(""))
        #expect(!WorkerSiteName.isValidWorkerName("my site"))
        #expect(!WorkerSiteName.isValidWorkerName("my.site"))
        #expect(!WorkerSiteName.isValidWorkerName("my\"site\ninjected"))
    }

    // MARK: - isValidR2BucketName (wrangler's `bucket_name` rule)

    @Test("bucket rule accepts 3–63 lowercase alphanumerics/hyphens bounded by alphanumerics")
    func bucketNameAccepts() {
        #expect(WorkerSiteName.isValidR2BucketName("abc"))
        #expect(WorkerSiteName.isValidR2BucketName("a-b"))
        #expect(WorkerSiteName.isValidR2BucketName("my-site-media"))
        #expect(WorkerSiteName.isValidR2BucketName(String(repeating: "a", count: 63)))
    }

    @Test("bucket rule rejects what wrangler rejects: too short/long, edge hyphens, uppercase, underscore")
    func bucketNameRejects() {
        #expect(!WorkerSiteName.isValidR2BucketName("ab"))
        #expect(!WorkerSiteName.isValidR2BucketName(String(repeating: "a", count: 64)))
        #expect(!WorkerSiteName.isValidR2BucketName("-abc"))
        #expect(!WorkerSiteName.isValidR2BucketName("abc-"))
        #expect(!WorkerSiteName.isValidR2BucketName("F0EF6A17-9948-4157-98CE-A6D8234BA0AF-pod-blobs"))
        #expect(!WorkerSiteName.isValidR2BucketName("my_site-media"))
        #expect(!WorkerSiteName.isValidR2BucketName(""))
    }
}
