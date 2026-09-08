import Testing
import Foundation
@testable import AnglesiteCore

@Suite("DomainConfigStore")
struct DomainConfigStoreTests {
    private func tempSourceDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DomainConfigStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("load on a missing file returns a default config, not a throw")
    func loadMissingReturnsDefault() throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DomainConfigStore(sourceDirectory: dir)
        #expect(try store.load() == DomainConfig())
    }

    @Test("save then load round-trips a fully populated config")
    func saveLoadRoundTrips() throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DomainConfigStore(sourceDirectory: dir)
        let config = DomainConfig(
            version: 1,
            domain: .init(
                hostname: "example.com", choice: "transfer", attach: true,
                registrar: "Example Registrar, LLC", expiresAt: "2027-08-13T04:00:00Z"),
            dns: .init(managedRecords: [
                .init(type: "MX", name: "@", content: "mx01.mail.icloud.com", priority: 10, purpose: "email:icloud"),
            ]),
            edge: .init(
                dnssec: true,
                alwaysUseHTTPS: true,
                hsts: .init(maxAge: 31536000, includeSubdomains: true, preload: false),
                cloudflare: .init(botFightMode: true, wafRules: [
                    .init(description: "Block bad bots", expression: "cf.client.bot", action: "block"),
                ])
            ),
            email: .init(provider: "icloud", dmarcReportEmail: "postmaster@example.com"),
            workers: .init(active: ["webmention-receive", "micropub"]),
            deployTarget: "cloudflare",
            githubPages: .init(owner: "example-owner", repo: "example-site-pages")
        )
        try store.save(config)
        let fileURL = dir.appendingPathComponent("anglesite.json")
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        #expect(try store.load() == config)
        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(contents.hasSuffix("\n"), "anglesite.json should end with a trailing newline")
    }

    @Test("load throws on malformed JSON")
    func loadThrowsOnMalformedJSON() throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "not json {".write(to: dir.appendingPathComponent("anglesite.json"), atomically: true, encoding: .utf8)
        let store = DomainConfigStore(sourceDirectory: dir)
        #expect(throws: (any Error).self) { try store.load() }
    }

    @Test("load defaults version to 1 when the file omits it")
    func loadDefaultsMissingVersion() throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try #"{"domain":{"hostname":"example.com"}}"#.write(
            to: dir.appendingPathComponent("anglesite.json"), atomically: true, encoding: .utf8
        )
        let store = DomainConfigStore(sourceDirectory: dir)
        let config = try store.load()
        #expect(config.version == 1)
        #expect(config.domain?.hostname == "example.com")
    }

    @Test("save preserves an unrecognized top-level key")
    func savePreservesUnknownTopLevelKey() throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("anglesite.json")
        try #"{"version":1,"futureSection":{"foo":"bar"}}"#.write(to: fileURL, atomically: true, encoding: .utf8)

        let store = DomainConfigStore(sourceDirectory: dir)
        try store.save(DomainConfig(domain: .init(hostname: "example.com")))

        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        let future = raw?["futureSection"] as? [String: Any]
        #expect(future?["foo"] as? String == "bar")
        #expect((raw?["domain"] as? [String: Any])?["hostname"] as? String == "example.com")
    }

    @Test("save preserves an unrecognized key nested inside a known section")
    func savePreservesUnknownNestedKey() throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("anglesite.json")
        try #"{"version":1,"domain":{"hostname":"old.example.com","futureField":"x"}}"#.write(
            to: fileURL, atomically: true, encoding: .utf8
        )

        let store = DomainConfigStore(sourceDirectory: dir)
        try store.save(DomainConfig(domain: .init(hostname: "new.example.com")))

        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        let domain = raw?["domain"] as? [String: Any]
        #expect(domain?["hostname"] as? String == "new.example.com")
        #expect(domain?["futureField"] as? String == "x")
    }

    @Test("save does not clear a previously-saved field when the new config passes nil for it")
    func saveDoesNotClearPreviouslySavedField() throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DomainConfigStore(sourceDirectory: dir)
        try store.save(DomainConfig(domain: .init(hostname: "old.example.com", attach: true)))

        try store.save(DomainConfig(domain: .init(hostname: "new.example.com")))

        let reloaded = try store.load()
        #expect(reloaded.domain?.hostname == "new.example.com")
        #expect(reloaded.domain?.attach == true, "save() cannot clear a previously-declared field yet — see the doc comment on save(_:)")
    }

    @Test("save never downgrades a higher on-disk schema version")
    func saveDoesNotDowngradeVersion() throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("anglesite.json")
        try #"{"version":2,"domain":{"hostname":"old.example.com"}}"#.write(
            to: fileURL, atomically: true, encoding: .utf8
        )

        let store = DomainConfigStore(sourceDirectory: dir)
        try store.save(DomainConfig(domain: .init(hostname: "new.example.com")))

        let reloaded = try store.load()
        #expect(reloaded.version == 2)
        #expect(reloaded.domain?.hostname == "new.example.com")
    }

    @Test("save replaces an array wholesale rather than merging unknown elements")
    func saveReplacesArraysWholesale() throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("anglesite.json")
        try #"""
        {"version":1,"dns":{"managedRecords":[
            {"type":"TXT","name":"_atproto","content":"did=did:plc:hand-added","purpose":"verification:bluesky"}
        ]}}
        """#.write(to: fileURL, atomically: true, encoding: .utf8)

        let store = DomainConfigStore(sourceDirectory: dir)
        try store.save(DomainConfig(dns: .init(managedRecords: [
            .init(type: "MX", name: "@", content: "mx01.mail.icloud.com", priority: 10, purpose: "email:icloud"),
        ])))

        let reloaded = try store.load()
        #expect(reloaded.dns?.managedRecords?.count == 1)
        #expect(reloaded.dns?.managedRecords?.first?.type == "MX")
    }

    @Test("concurrent saves from multiple producers merge updates without losing data (#1189)")
    func concurrentSavesMergeUpdates() throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DomainConfigStore(sourceDirectory: dir)

        let initialConfig = DomainConfig(
            domain: .init(hostname: "example.com"),
            dns: .init(managedRecords: [
                .init(type: "MX", name: "@", content: "mx01.mail.icloud.com", priority: 10, purpose: "email:icloud"),
            ])
        )
        try store.save(initialConfig)

        let group = DispatchGroup()
        var saveErrors: [Error] = []
        let errorLock = NSLock()

        // Simulate concurrent producers: email setup and DNS modifications
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            do {
                let emailConfig = DomainConfig(
                    email: .init(provider: "icloud", dmarcReportEmail: "postmaster@example.com")
                )
                try store.save(emailConfig)
            } catch {
                errorLock.lock()
                saveErrors.append(error)
                errorLock.unlock()
            }
        }

        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            do {
                let edgeConfig = DomainConfig(
                    edge: .init(dnssec: true, alwaysUseHTTPS: true)
                )
                try store.save(edgeConfig)
            } catch {
                errorLock.lock()
                saveErrors.append(error)
                errorLock.unlock()
            }
        }

        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            do {
                let workersConfig = DomainConfig(
                    workers: .init(active: ["webmention-receive"])
                )
                try store.save(workersConfig)
            } catch {
                errorLock.lock()
                saveErrors.append(error)
                errorLock.unlock()
            }
        }

        group.wait()
        #expect(saveErrors.isEmpty, "No errors during concurrent saves")

        let final = try store.load()
        // Verify all sections from all concurrent producers were saved
        #expect(final.domain?.hostname == "example.com", "Initial domain config preserved")
        #expect(final.dns?.managedRecords?.count == 1, "Initial DNS records preserved")
        #expect(final.dns?.managedRecords?.first?.type == "MX", "DNS record type preserved")
        #expect(final.email?.provider == "icloud", "Email config from concurrent save")
        #expect(final.edge?.dnssec == true, "Edge config from concurrent save")
        #expect(final.workers?.active == ["webmention-receive"], "Workers config from concurrent save")
    }

    @Test("save then load round-trips a config with experiments")
    func saveLoadRoundTripsExperiments() throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DomainConfigStore(sourceDirectory: dir)
        let config = DomainConfig(
            experiments: .init(active: [
                .init(
                    id: "homepage-hero",
                    name: "Homepage headline",
                    page: "/",
                    variant: .init(id: "b", name: "Fresh eggs headline", page: "/x/homepage-hero/b/"),
                    split: 0.5,
                    goal: .init(kind: "pageview", path: "/contact/thanks/"),
                    status: "running",
                    startedAt: "2026-08-16"
                ),
            ])
        )
        try store.save(config)
        #expect(try store.load() == config)
    }

    @Test("save preserves an unrecognized key nested inside the experiments section")
    func savePreservesUnknownNestedExperimentsKey() throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("anglesite.json")
        try #"{"version":1,"experiments":{"active":[],"futureField":"x"}}"#.write(
            to: fileURL, atomically: true, encoding: .utf8
        )
        let store = DomainConfigStore(sourceDirectory: dir)
        try store.save(DomainConfig(experiments: .init(active: [])))
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        let experiments = raw?["experiments"] as? [String: Any]
        #expect(experiments?["futureField"] as? String == "x")
    }

    @Test("save then load round-trips a config with experimental.mcp")
    func saveLoadRoundTripsExperimentalMcp() throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DomainConfigStore(sourceDirectory: dir)
        let config = DomainConfig(experimental: .init(mcp: true))
        try store.save(config)
        #expect(try store.load() == config)
    }

    @Test("experimental section is nil by default")
    func experimentalNilByDefault() throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DomainConfigStore(sourceDirectory: dir)
        #expect(try store.load().experimental == nil)
    }

    /// Byte-compatibility regression guard for #1948: `DomainConfigStore.save(_:)`'s
    /// read-existing → deep-merge → `JSONSerialization` + trailing-newline re-serialization moved
    /// onto `CodableFileStore`'s `merge` hook verbatim. This reimplements that exact pre-migration
    /// algorithm independently (not by calling into `DomainConfigStore`) and checks the migrated
    /// store's actual on-disk bytes match it byte-for-byte for a save that both preserves an
    /// unknown key and floors the on-disk version.
    @Test("save through the migrated store reproduces the pre-migration byte-for-byte output")
    func saveReproducesPreMigrationBytes() throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("anglesite.json")
        let existingText = #"{"version":2,"domain":{"hostname":"old.example.com","futureField":"x"}}"#
        try existingText.write(to: fileURL, atomically: true, encoding: .utf8)

        let config = DomainConfig(domain: .init(hostname: "new.example.com"))
        let expectedBytes = try Self.legacyMergedBytes(
            existing: Data(existingText.utf8), config: config
        )

        let store = DomainConfigStore(sourceDirectory: dir)
        try store.save(config)
        let actualBytes = try Data(contentsOf: fileURL)

        #expect(actualBytes == expectedBytes)
    }

    /// A standalone reimplementation of `DomainConfigStore`'s pre-#1948 `performSave(_:)` body —
    /// deliberately independent of `DomainConfigStore` itself, so this test can catch the merge
    /// hook drifting from that original algorithm rather than just asserting it against itself.
    private static func legacyMergedBytes(existing: Data, config: DomainConfig) throws -> Data {
        func objectFields(fromJSONData data: Data) -> [String: JSONValue] {
            guard let any = try? JSONSerialization.jsonObject(with: data),
                  case .object(let fields)? = JSONValue.from(any) else {
                return [:]
            }
            return fields
        }
        func merge(_ new: [String: JSONValue], into old: [String: JSONValue]) -> [String: JSONValue] {
            var result = old
            for (key, newValue) in new {
                if case .object(let newNested) = newValue, case .object(let oldNested)? = old[key] {
                    result[key] = .object(merge(newNested, into: oldNested))
                } else {
                    result[key] = newValue
                }
            }
            return result
        }

        let newData = try JSONEncoder().encode(config)
        var newFields = objectFields(fromJSONData: newData)
        let existingFields = objectFields(fromJSONData: existing)

        if case .int(let onDiskVersion)? = existingFields["version"], onDiskVersion > config.version {
            newFields["version"] = .int(onDiskVersion)
        }

        let merged = merge(newFields, into: existingFields)
        let mergedData = try JSONSerialization.data(
            withJSONObject: JSONValue.object(merged).rawValue,
            options: [.prettyPrinted, .sortedKeys]
        )
        let mergedString = String(data: mergedData, encoding: .utf8) ?? "{}"
        let text = mergedString.hasSuffix("\n") ? mergedString : mergedString + "\n"
        return Data(text.utf8)
    }
}
