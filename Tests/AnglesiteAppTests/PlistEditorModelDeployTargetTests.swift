import Foundation
import Testing
@testable import AnglesiteAppCore
@testable import AnglesiteCore

/// Tests for the Website Settings deploy-target picker (#1682) — where the site publishes to,
/// persisted to `anglesite.json`'s `deployTarget`. Immediate-persist (like the Workers tab's
/// toggles), deliberately not part of the tab's dirty-tracked save aggregation: it's one
/// declared value with no partially-typed intermediate state to protect.
@Suite("PlistEditorModel deploy target (#1682)")
@MainActor
struct PlistEditorModelDeployTargetTests {
    private static let emptyPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict/></plist>
        """

    private func makeModel() throws -> PlistEditorModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlistEditorModelDeployTargetTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let plistURL = directory.appendingPathComponent("Info.plist")
        try Self.emptyPlist.write(to: plistURL, atomically: true, encoding: .utf8)
        return PlistEditorModel(
            file: FileRef(url: plistURL, group: .metadata, name: "Info.plist"),
            websiteTitle: "Test Site", sourceDirectory: directory)
    }

    @Test("a site with no declaration loads as Cloudflare")
    func undeclaredSiteLoadsAsCloudflare() async throws {
        let model = try makeModel()
        await model.load()
        #expect(model.deployTargetID == CloudflareDeployTarget.id)
    }

    @Test("choosing GitHub Pages persists deployTarget and is reflected on the next open")
    func choosingGitHubPagesRoundTrips() async throws {
        let model = try makeModel()
        await model.load()
        model.setDeployTarget(GitHubPagesDeployTarget.id)

        let onDisk = try DomainConfigStore(sourceDirectory: model.sourceDirectory).load()
        #expect(onDisk.deployTarget == GitHubPagesDeployTarget.id)
        #expect(model.deployTargetID == GitHubPagesDeployTarget.id)

        // …and the deploy path agrees about which conformer that means.
        #expect(DeployTargetSelection.target(sourceDirectory: model.sourceDirectory) is GitHubPagesDeployTarget)

        let reopened = PlistEditorModel(
            file: model.file, websiteTitle: "Test Site", sourceDirectory: model.sourceDirectory)
        await reopened.load()
        #expect(reopened.deployTargetID == GitHubPagesDeployTarget.id)
    }

    @Test("switching back to Cloudflare writes the choice explicitly, not an absent key")
    func switchingBackToCloudflarePersists() async throws {
        let model = try makeModel()
        await model.load()
        model.setDeployTarget(GitHubPagesDeployTarget.id)
        model.setDeployTarget(CloudflareDeployTarget.id)

        let onDisk = try DomainConfigStore(sourceDirectory: model.sourceDirectory).load()
        #expect(
            onDisk.deployTarget == CloudflareDeployTarget.id,
            "clearing the key instead of writing it would leave the site reading as GitHub Pages if a future default ever changed")
        #expect(DeployTargetSelection.target(sourceDirectory: model.sourceDirectory) is CloudflareDeployTarget)
    }

    @Test("a hand-edited value this app version doesn't recognize loads as Cloudflare")
    func unrecognizedDeclarationLoadsAsCloudflare() async throws {
        let model = try makeModel()
        DomainConfigStore.update(sourceDirectory: model.sourceDirectory) { $0.deployTarget = "netlify" }
        await model.load()
        #expect(
            model.deployTargetID == CloudflareDeployTarget.id,
            "the picker must show the target the deploy path would actually use")
    }
}
