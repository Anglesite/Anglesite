// Tests/AnglesiteCoreTests/SolidOidcKeyProvisioningTests.swift
import Testing
import Foundation
@testable import AnglesiteCore
import AnglesiteTestSupport

@Suite("SolidOidcKeyProvisioning")
struct SolidOidcKeyProvisioningTests {
    @Test("signingKeyJWK generates a private EC P-256 JWK with the expected members")
    func generatesJWK() throws {
        let store = InMemorySecretStore()
        let jwk = try SolidOidcKeyProvisioning.signingKeyJWK(siteID: "site-1", secretStore: store)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(jwk.utf8)) as? [String: String])
        #expect(object["kty"] == "EC")
        #expect(object["crv"] == "P-256")
        #expect(object["x"]?.isEmpty == false)
        #expect(object["y"]?.isEmpty == false)
        #expect(object["d"]?.isEmpty == false)
    }

    @Test("signingKeyJWK returns the same key on a second call — never regenerated")
    func neverRegenerates() throws {
        let store = InMemorySecretStore()
        let first = try SolidOidcKeyProvisioning.signingKeyJWK(siteID: "site-1", secretStore: store)
        let second = try SolidOidcKeyProvisioning.signingKeyJWK(siteID: "site-1", secretStore: store)
        #expect(first == second)
    }

    @Test("signingKeyJWK generates independent keys for different sites")
    func independentPerSite() throws {
        let store = InMemorySecretStore()
        let siteA = try SolidOidcKeyProvisioning.signingKeyJWK(siteID: "site-a", secretStore: store)
        let siteB = try SolidOidcKeyProvisioning.signingKeyJWK(siteID: "site-b", secretStore: store)
        #expect(siteA != siteB)
    }

    @Test("webdavPepper generates a non-empty secret and never regenerates")
    func webdavPepperStable() throws {
        let store = InMemorySecretStore()
        let first = try SolidOidcKeyProvisioning.webdavPepper(siteID: "site-1", secretStore: store)
        let second = try SolidOidcKeyProvisioning.webdavPepper(siteID: "site-1", secretStore: store)
        #expect(!first.isEmpty)
        #expect(first == second)
    }
}
