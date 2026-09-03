import Foundation
import Testing
import AnglesiteCore
import AnglesiteTestSupport
@testable import AnglesiteAppCore

/// `.timeLimit`: see #1349 — the full `AnglesiteAppTests` target has hung indefinitely under
/// local machine contention (many concurrent `swift test` runs oversubscribing the cooperative
/// thread pool), with this suite one of the observed stall points. A wedged test now fails as an
/// unambiguous time-limit violation instead of hanging the whole run forever.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct OnionRoutingModelTests {
    @MainActor
    @Test("load() ignores blank domain input")
    func loadIgnoresBlankDomain() async throws {
        // `apiToken()` checks this env var before falling back to the real Keychain — claim it set
        // so these tests are deterministic regardless of what's provisioned on the host.
        let cfToken = await CloudflareAPITokenTestEnvironment.shared.claimSet()
        defer { cfToken.release() }
        let reader = StubCloudflareReader()
        let model = OnionRoutingModel(reader: reader, writer: StubCloudflareWriter())
        model.domainInput = "   "
        model.load()
        #expect(model.phase == .idle)
        #expect(reader.resolvedDomain == nil)
    }

    @MainActor
    @Test("load() trims/lowercases the domain and reports the current zone state")
    func loadSucceeds() async throws {
        let cfToken = await CloudflareAPITokenTestEnvironment.shared.claimSet()
        defer { cfToken.release() }
        let state = CloudflareZoneState(
            dnssecActive: false, sslMode: "flexible", alwaysUseHTTPS: false, hsts: nil,
            caaRecords: [], mxRecords: [], spfRecords: [], dmarcRecords: [], onionRouting: true)
        let reader = StubCloudflareReader(zoneID: "z1", state: state)
        let model = OnionRoutingModel(reader: reader, writer: StubCloudflareWriter())

        model.domainInput = "  Example.com "
        model.load()
        while model.isRunning { await Task.yield() }

        #expect(reader.resolvedDomain == "example.com")
        #expect(model.phase == .configured(domain: "example.com", enabled: true))
    }

    @MainActor
    @Test("load() surfaces a clear error when the zone isn't found")
    func loadZoneNotFound() async throws {
        let cfToken = await CloudflareAPITokenTestEnvironment.shared.claimSet()
        defer { cfToken.release() }
        let reader = StubCloudflareReader(zoneID: nil)
        let model = OnionRoutingModel(reader: reader, writer: StubCloudflareWriter())

        model.domainInput = "missing.com"
        model.load()
        while model.isRunning { await Task.yield() }

        guard case .error(let message) = model.phase else {
            Issue.record("expected .error phase, got \(model.phase)")
            return
        }
        #expect(message.contains("missing.com"))
    }

    @MainActor
    @Test("toggle() flips the loaded setting and writes through the zone that was resolved")
    func toggleFlipsAndWrites() async throws {
        let cfToken = await CloudflareAPITokenTestEnvironment.shared.claimSet()
        defer { cfToken.release() }
        let state = CloudflareZoneState(
            dnssecActive: false, sslMode: "flexible", alwaysUseHTTPS: false, hsts: nil,
            caaRecords: [], mxRecords: [], spfRecords: [], dmarcRecords: [], onionRouting: false)
        let reader = StubCloudflareReader(zoneID: "z1", state: state)
        let writer = StubCloudflareWriter()
        let model = OnionRoutingModel(reader: reader, writer: writer)

        model.domainInput = "example.com"
        model.load()
        while model.isRunning { await Task.yield() }

        model.toggle()
        while model.isRunning { await Task.yield() }

        #expect(writer.lastOnionRoutingZoneID == "z1")
        #expect(writer.lastOnionRoutingEnabled == true)
        #expect(model.phase == .configured(domain: "example.com", enabled: true))
    }

    @MainActor
    @Test("toggle() is a no-op before a zone has been loaded")
    func toggleNoopWhenIdle() async throws {
        let cfToken = await CloudflareAPITokenTestEnvironment.shared.claimSet()
        defer { cfToken.release() }
        let writer = StubCloudflareWriter()
        let model = OnionRoutingModel(reader: StubCloudflareReader(), writer: writer)

        model.toggle()
        while model.isRunning { await Task.yield() }

        #expect(writer.lastOnionRoutingEnabled == nil)
        #expect(model.phase == .idle)
    }

    @MainActor
    @Test("openSheet() resets phase and clears any previously entered domain")
    func openSheetResets() {
        // No CloudflareAPITokenTestEnvironment claim needed: openSheet() never calls apiToken().
        let model = OnionRoutingModel(reader: StubCloudflareReader(), writer: StubCloudflareWriter())
        model.domainInput = "leftover.com"

        model.openSheet()

        #expect(model.sheetPresented == true)
        #expect(model.domainInput == "")
        #expect(model.phase == .idle)
    }

    @MainActor
    @Test("dismissSheet() clears the presented flag")
    func dismissSheetClearsPresented() {
        // No CloudflareAPITokenTestEnvironment claim needed: neither method calls apiToken().
        let model = OnionRoutingModel(reader: StubCloudflareReader(), writer: StubCloudflareWriter())
        model.openSheet()

        model.dismissSheet()

        #expect(model.sheetPresented == false)
    }
}
