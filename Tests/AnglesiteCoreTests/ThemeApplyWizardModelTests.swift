// Tests/AnglesiteCoreTests/ThemeApplyWizardModelTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

/// Stub `URLProtocol` that returns a canned status/body for every request, so the
/// freedesignmd branch of `ThemeApplyWizardModel` can be exercised without a real network
/// call. Mirrors `FreedesignmdStubURLProtocol` in FreedesignmdCatalogTests.swift, kept
/// separate/private here to avoid cross-file coupling on a `private` type.
private final class WizardFreedesignmdStubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var statusCode = 200
    nonisolated(unsafe) static var body = ""

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WizardFreedesignmdStubURLProtocol.self]
        return URLSession(configuration: config)
    }
}

// .serialized: the freedesignmd tests share WizardFreedesignmdStubURLProtocol's mutable
// static status/body, which would race under Swift Testing's default parallel execution.
@Suite(.serialized) struct ThemeApplyWizardModelTests {
    private func makeSite() throws -> AnglesitePackage {
        let packageRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let stylesDir = packageRoot.appendingPathComponent("Source/src/styles")
        try FileManager.default.createDirectory(at: stylesDir, withIntermediateDirectories: true)
        try ":root {\n  --color-primary: #000000;\n}\n".write(
            to: stylesDir.appendingPathComponent("global.css"), atomically: true, encoding: .utf8)
        return AnglesitePackage(url: packageRoot)
    }

    private var testCatalog: ThemeCatalog {
        ThemeCatalog(themes: [Theme(id: "warm", name: "Warm", blurb: "cozy", swatch: ["#a11", "#a22"],
                                    cssVars: ["color-primary": "#a11111", "color-accent": "#a22222"])])
    }

    @Test @MainActor func picksBuiltInFlowAndApplies() async throws {
        let package = try makeSite()
        let model = ThemeApplyWizardModel(catalog: testCatalog, businessType: "bakery", package: package)
        model.source = .builtIn
        await model.advance() // pickSource -> pickBuiltIn
        #expect(model.step == .pickBuiltIn)
        model.selectedBuiltInID = "warm"
        await model.advance() // pickBuiltIn -> review
        #expect(model.step == .review)
        #expect(model.canContinue)
        await model.apply()
        #expect(model.step == .applying)
        guard case .success(let applied) = model.applyResult else { Issue.record("expected success"); return }
        #expect(applied.updatedVars["color-primary"] == "#a11111")

        #expect(applied.writtenFiles.contains("DESIGN.md"))
        #expect(applied.writtenFiles.contains("PRODUCT.md"))
        let designMD = try String(contentsOf: package.sourceURL.appendingPathComponent("DESIGN.md"), encoding: .utf8)
        #expect(designMD.contains("`warm`")) // the applied theme id
        #expect(designMD.contains("`--color-primary`"))
        let productMD = try String(contentsOf: package.sourceURL.appendingPathComponent("PRODUCT.md"), encoding: .utf8)
        #expect(productMD.contains("website of a bakery"))
    }

    @Test @MainActor func canContinueRequiresSourceChoiceFirst() {
        let model = ThemeApplyWizardModel(catalog: testCatalog, businessType: "bakery",
                                          package: AnglesitePackage(url: FileManager.default.temporaryDirectory))
        #expect(model.canContinue == false)
        model.source = .builtIn
        #expect(model.canContinue)
    }

    @Test @MainActor func canContinueRequiresBuiltInSelection() async {
        let model = ThemeApplyWizardModel(catalog: testCatalog, businessType: "bakery",
                                          package: AnglesitePackage(url: FileManager.default.temporaryDirectory))
        model.source = .builtIn
        await model.advance()
        #expect(model.canContinue == false)
        model.selectedBuiltInID = "warm"
        #expect(model.canContinue)
    }

    @Test @MainActor func backReturnsToPickSource() async {
        let model = ThemeApplyWizardModel(catalog: testCatalog, businessType: "bakery",
                                          package: AnglesitePackage(url: FileManager.default.temporaryDirectory))
        model.source = .builtIn
        await model.advance()
        model.back()
        #expect(model.step == .pickSource)
    }

    // MARK: - Fix 1: apply() must not leave applyResult nil when there's nothing to apply

    @Test @MainActor func applyFailsExplicitlyWhenBuiltInSelectionMissing() async {
        let model = ThemeApplyWizardModel(catalog: testCatalog, businessType: "bakery",
                                          package: AnglesitePackage(url: FileManager.default.temporaryDirectory))
        model.source = .builtIn
        // No selectedBuiltInID set — simulate a caller reaching `.review` then clearing the
        // selection and calling apply() directly, bypassing canContinue's advance() gate.
        await model.apply()
        #expect(model.step == .applying)
        guard case .failure = model.applyResult else {
            Issue.record("expected apply() to surface a failure, not leave applyResult nil")
            return
        }
    }

    @Test @MainActor func applyFailsExplicitlyWhenFreedesignmdSelectionMissing() async {
        let model = ThemeApplyWizardModel(catalog: testCatalog, businessType: "bakery",
                                          package: AnglesitePackage(url: FileManager.default.temporaryDirectory))
        model.source = .freedesignmd
        // No selectedFreedesignmdSlug set.
        await model.apply()
        #expect(model.step == .applying)
        guard case .failure = model.applyResult else {
            Issue.record("expected apply() to surface a failure, not leave applyResult nil")
            return
        }
    }

    @Test @MainActor func applyFailsExplicitlyWhenSourceMissing() async {
        let model = ThemeApplyWizardModel(catalog: testCatalog, businessType: "bakery",
                                          package: AnglesitePackage(url: FileManager.default.temporaryDirectory))
        // source is nil.
        await model.apply()
        guard case .failure = model.applyResult else {
            Issue.record("expected apply() to surface a failure, not leave applyResult nil")
            return
        }
    }

    // MARK: - Fix 2: freedesignmd branch coverage

    private let sampleListHTML = """
    <script type="application/ld+json">{"@context":"https://schema.org","@graph":[{"@type":"BreadcrumbList"},{"@type":"CollectionPage","mainEntity":{"@type":"ItemList","numberOfItems":2,"itemListElement":[{"@type":"ListItem","position":1,"url":"https://freedesignmd.com/system/linear-orbit","name":"Linear Orbit"},{"@type":"ListItem","position":2,"url":"https://freedesignmd.com/system/vinyl-noir","name":"Vinyl Noir"}]}}]}</script>
    """

    private let sampleDetailHTML = """
    <meta name="description" content="Hairline-thin product workspace."/>
    """

    @Test @MainActor func picksFreedesignmdFlowAndPopulatesCandidates() async throws {
        WizardFreedesignmdStubURLProtocol.statusCode = 200
        WizardFreedesignmdStubURLProtocol.body = sampleListHTML
        let session = WizardFreedesignmdStubURLProtocol.makeSession()
        let package = try makeSite()
        let model = ThemeApplyWizardModel(catalog: testCatalog, businessType: "bakery", package: package,
                                          session: session)
        model.source = .freedesignmd
        await model.advance() // pickSource -> browseFreedesignmd, loads candidates
        #expect(model.step == .browseFreedesignmd)
        #expect(model.fetchError == nil)
        #expect(model.freedesignmdCandidates.map(\.slug) == ["linear-orbit", "vinyl-noir"])
    }

    @Test @MainActor func loadFreedesignmdCandidatesSetsFetchErrorOnHTTPFailure() async {
        WizardFreedesignmdStubURLProtocol.statusCode = 500
        WizardFreedesignmdStubURLProtocol.body = "server error"
        let session = WizardFreedesignmdStubURLProtocol.makeSession()
        let model = ThemeApplyWizardModel(catalog: testCatalog, businessType: "bakery",
                                          package: AnglesitePackage(url: FileManager.default.temporaryDirectory),
                                          session: session)
        model.source = .freedesignmd
        await model.advance() // pickSource -> browseFreedesignmd, load fails
        #expect(model.step == .browseFreedesignmd)
        #expect(model.freedesignmdCandidates.isEmpty)
        #expect(model.fetchError != nil)
    }

    @Test @MainActor func appliesFreedesignmdSelection() async throws {
        WizardFreedesignmdStubURLProtocol.statusCode = 200
        WizardFreedesignmdStubURLProtocol.body = sampleDetailHTML
        let session = WizardFreedesignmdStubURLProtocol.makeSession()
        let package = try makeSite()
        let model = ThemeApplyWizardModel(catalog: testCatalog, businessType: "bakery", package: package,
                                          session: session)
        model.source = .freedesignmd
        model.selectedFreedesignmdSlug = "linear-orbit"
        model.step = .review
        await model.apply()
        #expect(model.step == .applying)
        guard case .success(let applied) = model.applyResult else {
            Issue.record("expected success"); return
        }
        #expect(applied.writtenFiles.isEmpty == false)
        #expect(applied.writtenFiles.contains("docs/brand.md"))
        // The freedesignmd flow writes no CSS vars — the global.css upsert step must be skipped.
        #expect(!applied.writtenFiles.contains("src/styles/global.css"))

        let brandURL = package.sourceURL.appendingPathComponent("docs/brand.md")
        let brand = try String(contentsOf: brandURL, encoding: .utf8)
        #expect(brand.contains("freedesignmd: linear-orbit"))
        #expect(brand.contains("Hairline-thin product workspace."))

        #expect(applied.writtenFiles.contains("DESIGN.md"))
        #expect(applied.writtenFiles.contains("PRODUCT.md"))
        let designMD = try String(contentsOf: package.sourceURL.appendingPathComponent("DESIGN.md"), encoding: .utf8)
        // No candidates were loaded in this test (selectedFreedesignmdSlug was set directly), so
        // the system's display name falls back to its slug — see ThemeApplyWizardModel.apply()'s
        // `freedesignmdCandidates.first { ... }?.name ?? slug` fallback.
        #expect(designMD.contains("/system/linear-orbit"))
    }
}
