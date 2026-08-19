import Testing
import Foundation
@testable import AnglesiteAppCore
@testable import AnglesiteCore

@Suite("PlistEditorModel Inbox Capture toggle (#764)")
@MainActor
struct PlistEditorModelInboxCaptureTests {
    private static let emptyPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict/></plist>
        """

    private struct Fixture {
        let model: PlistEditorModel
        let configDirectory: URL
        let keychainService: String
    }

    private func makeFixture(
        settings: SiteSettings? = nil,
        token: String? = "test-token",
        proberTransport: @escaping CloudflareTransport = { _ in
            (Data(#"{"success":true,"result":[]}"#.utf8), HTTPURLResponse(url: URL(string: "https://api.cloudflare.com/")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    ) async throws -> Fixture {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlistEditorModelInboxCaptureTests-\(UUID().uuidString)", isDirectory: true)
        let sourceDir = dir.appendingPathComponent("Source", isDirectory: true)
        let configDir = dir.appendingPathComponent("Config", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let plistURL = sourceDir.appendingPathComponent("Info.plist")
        try Self.emptyPlist.write(to: plistURL, atomically: true, encoding: .utf8)
        if let settings {
            try await SiteConfigStore(configDirectory: configDir).save(settings)
        }
        let keychainService = "io.dwk.anglesite.test-\(UUID().uuidString)"
        let keychain = KeychainStore(service: keychainService)
        if let token {
            try keychain.writeCloudflareToken(token)
        }
        let model = PlistEditorModel(
            file: FileRef(url: plistURL, group: .metadata, name: "Info.plist"),
            websiteTitle: "My Test Site",
            sourceDirectory: sourceDir,
            configDirectory: configDir,
            keychain: keychain,
            capabilityProber: CloudflareCapabilityProber(transport: proberTransport)
        )
        return Fixture(model: model, configDirectory: configDir, keychainService: keychainService)
    }

    @Test("turning on with a KV-capable token persists inboxCaptureEnabled")
    func turnOnWithCapableToken() async throws {
        let fixture = try await makeFixture(proberTransport: { request in
            let url = request.url!.absoluteString
            let body = url.contains("storage/kv/namespaces")
                ? #"{"success":true,"result":[]}"#
                : #"{"success":true,"result":[{"id":"acc1"}]}"#
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })

        await fixture.model.setInboxCaptureEnabled(true)

        #expect(fixture.model.inboxCaptureEnabled == true)
        #expect(fixture.model.inboxCaptureError == nil)
        let saved = try await SiteConfigStore(configDirectory: fixture.configDirectory).load()
        #expect(saved.inboxCaptureEnabled == true)
    }

    @Test("turning on with a KV-incapable token surfaces a friendly error and does not persist")
    func turnOnWithIncapableToken() async throws {
        let fixture = try await makeFixture(proberTransport: { request in
            let url = request.url!.absoluteString
            let (status, body): (Int, String) = url.contains("storage/kv/namespaces")
                ? (403, #"{"success":false}"#)
                : (200, #"{"success":true,"result":[{"id":"acc1"}]}"#)
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        })

        await fixture.model.setInboxCaptureEnabled(true)

        #expect(fixture.model.inboxCaptureEnabled == false)
        #expect(fixture.model.inboxCaptureError != nil)
        let saved = try await SiteConfigStore(configDirectory: fixture.configDirectory).load()
        #expect(saved.inboxCaptureEnabled == nil)
    }

    @Test("turning off persists false and leaves provisionedWorkerResources untouched")
    func turnOff() async throws {
        let fixture = try await makeFixture(
            settings: SiteSettings(
                provisionedWorkerResources: .init(inboxKVNamespaceID: "ns-1", inboxAccountID: "acct-1"),
                inboxCaptureEnabled: true
            ))
        await fixture.model.loadWorkers()

        await fixture.model.setInboxCaptureEnabled(false)

        #expect(fixture.model.inboxCaptureEnabled == false)
        let saved = try await SiteConfigStore(configDirectory: fixture.configDirectory).load()
        #expect(saved.inboxCaptureEnabled == false)
        #expect(saved.provisionedWorkerResources?.inboxKVNamespaceID == "ns-1")
        #expect(saved.provisionedWorkerResources?.inboxAccountID == "acct-1")
    }

    @Test("a save failure on turn-off surfaces an error and leaves the toggle state unchanged")
    func turnOffSaveFailure() async throws {
        let fixture = try await makeFixture(settings: SiteSettings(inboxCaptureEnabled: true))
        await fixture.model.loadWorkers()
        #expect(fixture.model.inboxCaptureEnabled == true)

        // Strip write permission from Config/ so `store.save`'s atomic write fails — same
        // technique NativeContentOperationsTests uses to force a real I/O failure rather than a
        // mocked one.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: fixture.configDirectory.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: fixture.configDirectory.path)
        }

        await fixture.model.setInboxCaptureEnabled(false)

        #expect(fixture.model.inboxCaptureError != nil)
        #expect(fixture.model.inboxCaptureEnabled == true)
    }

    @Test("without a token, leaves the toggle off with an error and makes no capability-probe call")
    func turnOnWithoutToken() async throws {
        // `cloudflareToken()` falls back to the process-wide `CLOUDFLARE_API_TOKEN` env var when
        // the keychain is empty, and sibling suites (DomainConfigAuditModelTests, HardenModelTests,
        // OnionRoutingModelTests) legitimately hold that var *set* while their own tests run, via
        // `CloudflareAPITokenTestEnvironment`. Claim the exclusive "cleared" state through that
        // same coordinator rather than calling `unsetenv` directly: a raw unset yanks the var out
        // from under a concurrent setter's claim, and a snapshot/restore `defer` can re-plant a
        // stale value after that setter has released — both were real cross-suite flakes (#1375).
        let cfToken = await CloudflareAPITokenTestEnvironment.shared.claimClear()
        defer { cfToken.release() }

        let fixture = try await makeFixture(token: nil, proberTransport: { _ in
            Issue.record("capability prober must not be called without a token")
            struct Unexpected: Error {}
            throw Unexpected()
        })

        await fixture.model.setInboxCaptureEnabled(true)

        #expect(fixture.model.inboxCaptureEnabled == false)
        #expect(fixture.model.inboxCaptureError != nil)
    }

    // MARK: - inboxForwardEmail (#1570)

    @Test("loadWorkers pre-fills inboxForwardEmail from anglesite.json's email.inboxForwardAddress")
    func loadWorkersPreFillsForwardEmail() async throws {
        let fixture = try await makeFixture()
        try DomainConfigStore(sourceDirectory: fixture.model.sourceDirectory).save(
            DomainConfig(email: .init(inboxForwardAddress: "owner@example.com")))

        await fixture.model.loadWorkers()

        #expect(fixture.model.inboxForwardEmail == "owner@example.com")
    }

    @Test("saveInboxForwardEmail trims and persists a valid address without disturbing dmarcReportEmail")
    func saveInboxForwardEmailPersists() async throws {
        let fixture = try await makeFixture()
        try DomainConfigStore(sourceDirectory: fixture.model.sourceDirectory).save(
            DomainConfig(email: .init(provider: "fastmail", dmarcReportEmail: "dmarc@example.com")))
        await fixture.model.loadWorkers()

        fixture.model.saveInboxForwardEmail("  owner@example.com  ")

        #expect(fixture.model.inboxForwardEmail == "owner@example.com")
        #expect(fixture.model.inboxForwardEmailError == nil)
        let saved = try DomainConfigStore(sourceDirectory: fixture.model.sourceDirectory).load()
        #expect(saved.email?.inboxForwardAddress == "owner@example.com")
        #expect(saved.email?.dmarcReportEmail == "dmarc@example.com")
        #expect(saved.email?.provider == "fastmail")
    }

    @Test("saveInboxForwardEmail rejects a value with no @ and leaves the prior address on disk")
    func saveInboxForwardEmailRejectsInvalid() async throws {
        let fixture = try await makeFixture()
        try DomainConfigStore(sourceDirectory: fixture.model.sourceDirectory).save(
            DomainConfig(email: .init(inboxForwardAddress: "owner@example.com")))
        await fixture.model.loadWorkers()

        fixture.model.saveInboxForwardEmail("not-an-email")

        #expect(fixture.model.inboxForwardEmailError != nil)
        let saved = try DomainConfigStore(sourceDirectory: fixture.model.sourceDirectory).load()
        #expect(saved.email?.inboxForwardAddress == "owner@example.com")
    }

    @Test("saveInboxForwardEmail with a blank value clears a previously-set address")
    func saveInboxForwardEmailClears() async throws {
        let fixture = try await makeFixture()
        try DomainConfigStore(sourceDirectory: fixture.model.sourceDirectory).save(
            DomainConfig(email: .init(inboxForwardAddress: "owner@example.com")))
        await fixture.model.loadWorkers()

        fixture.model.saveInboxForwardEmail("   ")

        #expect(fixture.model.inboxForwardEmail == "")
        #expect(fixture.model.inboxForwardEmailError == nil)
        #expect(DeployCoordinator.resolveInboxForwardEmail(sourceDirectory: fixture.model.sourceDirectory) == nil)
    }
}
