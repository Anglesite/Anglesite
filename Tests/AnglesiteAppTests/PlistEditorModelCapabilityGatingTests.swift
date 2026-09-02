import Testing
import Foundation
import AnglesiteTestSupport
@testable import AnglesiteAppCore
@testable import AnglesiteCore

/// Tests for the Workers-capability gate on a non-Cloudflare deploy target (#1683).
///
/// The view stops exposing either control once the gate trips, so these tests drive the *action*
/// layer directly — the defense-in-depth half of the gate, matching `PreDeployCheck`'s
/// non-bypassable posture. Both entry points must refuse before touching anything that would
/// provision: `setWorkerActive` before `SiteConfigStore.save`/`onActiveWorkersChanged` (whose
/// runtime notification is what a later deploy acts on), and `setInboxCaptureEnabled` before the
/// Cloudflare token read and the KV capability probe.
@Suite("PlistEditorModel Workers capability gating (#1683)")
@MainActor
struct PlistEditorModelCapabilityGatingTests {
    private static let emptyPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict/></plist>
        """

    /// Thread-safe capture box for the `onActiveWorkersChanged` runtime notification.
    final class NotifiedSettings: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [SiteSettings] = []
        func append(_ settings: SiteSettings) {
            lock.lock()
            defer { lock.unlock() }
            values.append(settings)
        }
        var all: [SiteSettings] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    private struct Fixture {
        let model: PlistEditorModel
        let configDirectory: URL
        let notified: NotifiedSettings
        let keychainCleanup: () -> Void
    }

    /// `deployTarget` is written into `Source/anglesite.json` exactly as a hand edit (or #1682's
    /// picker) would leave it — the model resolves the site's kind by reading that file, so
    /// there is no seam to inject here and no way for the test to disagree with production.
    private func makeFixture(deployTarget: String?) async throws -> Fixture {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlistEditorModelCapabilityGatingTests-\(UUID().uuidString)", isDirectory: true)
        let sourceDir = dir.appendingPathComponent("Source", isDirectory: true)
        let configDir = dir.appendingPathComponent("Config", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let plistURL = sourceDir.appendingPathComponent("Info.plist")
        try Self.emptyPlist.write(to: plistURL, atomically: true, encoding: .utf8)
        if let deployTarget {
            try DomainConfigStore(sourceDirectory: sourceDir).save(DomainConfig(deployTarget: deployTarget))
        }
        let scratchKeychain = TemporaryKeychainStore()
        try scratchKeychain.store.writeCloudflareToken("test-token")
        let notified = NotifiedSettings()
        let model = PlistEditorModel(
            file: FileRef(url: plistURL, group: .metadata, name: "Info.plist"),
            websiteTitle: "My Test Site",
            sourceDirectory: sourceDir,
            configDirectory: configDir,
            workerCatalogProvider: { [] },
            onActiveWorkersChanged: { notified.append($0) },
            keychain: scratchKeychain.store,
            capabilityProber: CloudflareCapabilityProber(transport: { request in
                Issue.record("the Cloudflare capability probe must not run on a gated site: \(request.url?.absoluteString ?? "?")")
                return (Data(#"{"success":true,"result":[]}"#.utf8),
                        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }))
        return Fixture(model: model, configDirectory: configDir, notified: notified, keychainCleanup: scratchKeychain.cleanup)
    }

    @Test("a GitHub Pages site resolves to .githubPages and reports no Workers support")
    func githubPagesSiteHasNoWorkerSupport() async throws {
        let fixture = try await makeFixture(deployTarget: GitHubPagesDeployTarget.id)
        defer { fixture.keychainCleanup() }
        #expect(fixture.model.deployTargetKind == .githubPages)
        #expect(fixture.model.supportsWorkers == false)
    }

    @Test("a site with no declared target still supports Workers")
    func undeclaredSiteSupportsWorkers() async throws {
        let fixture = try await makeFixture(deployTarget: nil)
        defer { fixture.keychainCleanup() }
        #expect(fixture.model.deployTargetKind == .cloudflare)
        #expect(fixture.model.supportsWorkers == true)
    }

    @Test("setWorkerActive on a GitHub Pages site explains instead of activating")
    func workerToggleGated() async throws {
        let fixture = try await makeFixture(deployTarget: GitHubPagesDeployTarget.id)
        defer { fixture.keychainCleanup() }

        await fixture.model.setWorkerActive("solid-pod", isOn: true)

        #expect(fixture.model.workersError == PlistEditorModel.workersUnavailableExplanation)
        // Nothing reached `Config/settings.plist`, so no later deploy can pick the worker up…
        let saved = try await SiteConfigStore(configDirectory: fixture.configDirectory).load()
        #expect(saved.activeWorkerIDs == nil)
        // …and the live runtime was never told to restart with a new active set.
        #expect(fixture.notified.all.isEmpty)
    }

    @Test("setInboxCaptureEnabled on a GitHub Pages site explains instead of enabling")
    func inboxCaptureGated() async throws {
        let fixture = try await makeFixture(deployTarget: GitHubPagesDeployTarget.id)
        defer { fixture.keychainCleanup() }

        await fixture.model.setInboxCaptureEnabled(true)

        #expect(fixture.model.inboxCaptureError == PlistEditorModel.workersUnavailableExplanation)
        #expect(fixture.model.inboxCaptureEnabled == false)
        let saved = try await SiteConfigStore(configDirectory: fixture.configDirectory).load()
        #expect(saved.inboxCaptureEnabled == nil)
    }

    @Test("turning Inbox Capture off on a GitHub Pages site is gated too")
    func inboxCaptureTurnOffGated() async throws {
        // The off path writes to `Config/` as well, so it can't be exempted from the gate: an
        // ungated `false` write on a site that never had the feature would still be a write the
        // owner can't explain, and it would clear a value a re-Cloudflare'd site had set.
        let fixture = try await makeFixture(deployTarget: GitHubPagesDeployTarget.id)
        defer { fixture.keychainCleanup() }
        try await SiteConfigStore(configDirectory: fixture.configDirectory)
            .save(SiteSettings(inboxCaptureEnabled: true))

        await fixture.model.setInboxCaptureEnabled(false)

        #expect(fixture.model.inboxCaptureError == PlistEditorModel.workersUnavailableExplanation)
        let saved = try await SiteConfigStore(configDirectory: fixture.configDirectory).load()
        #expect(saved.inboxCaptureEnabled == true)
    }

    @Test("an undeclared site still activates a worker normally")
    func workerToggleUngated() async throws {
        let fixture = try await makeFixture(deployTarget: nil)
        defer { fixture.keychainCleanup() }

        await fixture.model.setWorkerActive("solid-pod", isOn: true)

        #expect(fixture.model.workersError == nil)
        let saved = try await SiteConfigStore(configDirectory: fixture.configDirectory).load()
        #expect(saved.activeWorkerIDs == ["solid-pod"])
        #expect(fixture.notified.all.count == 1)
    }
}
