import Foundation
import Testing
@testable import AnglesiteCore

@Suite("SocialWorkerProvisionTarget.authorize")
struct SocialWorkerProvisionTargetAuthorizeTests {
    @Test("delegates to CloudflareDeployTarget's full authorize, including domain-drift")
    func delegatesFullAuthorize() async throws {
        let tmpDir = try temporaryDirectory()
        let inner = CloudflareDeployTarget(
            tokenSource: { "tok" },
            domainConfigDriftSource: { _, _, _ in
                [DomainConfigAudit.Finding(category: .dns, title: "dns", detail: "drift", remediation: .informational)]
            })
        try DomainConfigStore(sourceDirectory: tmpDir).save(DomainConfig(domain: .init(hostname: "example.com")))
        let target = SocialWorkerProvisionTarget(
            cloudflareTarget: inner, siteName: "site", workers: [], knownResources: .init())
        let result = await target.authorize(siteDirectory: tmpDir)
        guard case .blocked(.domainConfigDrift) = result else {
            Issue.record("expected .blocked(.domainConfigDrift), got \(result)")
            return
        }
    }

    @Test("persists CF_WORKER_PROVISIONED on a successful authorize")
    func persistsWorkerProvisionedOnSuccess() async throws {
        let tmpDir = try temporaryDirectory()
        let inner = CloudflareDeployTarget(tokenSource: { "tok" })
        let target = SocialWorkerProvisionTarget(
            cloudflareTarget: inner, siteName: "site", workers: [], knownResources: .init())
        let result = await target.authorize(siteDirectory: tmpDir)
        guard case .ready = result else {
            Issue.record("expected .ready, got \(result)")
            return
        }
        let config = try String(contentsOf: tmpDir.appendingPathComponent(".site-config"), encoding: .utf8)
        #expect(SiteConfigFile.value(forKey: "CF_WORKER_PROVISIONED", in: config) == "true")
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SocialWorkerProvisionTargetTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
