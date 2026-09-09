import Testing
import Foundation
import AnglesiteCore
@testable import AnglesiteAppCore

/// `PreviewModel`'s WYSIWYG edit-mode toggle (#1225 Task 8; real transport wired in #1222 Task 5).
/// `enterEditMode` now fetches a real page model through `PageModelClient`/`get_page_model`, so
/// every test here gives `UnavailableSiteRuntime` a working (fake-transport-backed) `MCPClient` via
/// `makeFakeGetPageModelClient(pageModel:)` — shared with `WYSIWYGPlumbingIntegrationTests.swift`,
/// which defines it — rather than the never-started client `UnavailableSiteRuntime.reason:` alone
/// would produce (that would make every fetch fail and `wysiwygCanvas` would never mount).
@Suite("PreviewModel WYSIWYG edit mode (#1225)")
@MainActor
struct PreviewModelWYSIWYGTests {
    /// A minimal-but-valid canned page model — an empty root fragment — matching the shape
    /// `PageModelBlockAdapter.adapt` turns into an empty `BlockModel` (`rootIds: []`,
    /// `blocks: [:]`), i.e. the same seed shape the old placeholder `seedModel` fixtures used.
    private static func cannedPageModel(version: String = "sha256:test00000000") -> PageModel {
        PageModel(
            version: version, path: "src/pages/index.astro",
            tree: .init(
                id: "root", kind: .fragment, tag: nil, attrs: [], span: .init(start: 0, end: 0),
                loc: nil, text: nil, children: [], block: nil))
    }

    private func makeModel(pageModel: PageModel = cannedPageModel()) async throws -> PreviewModel {
        let client = try await makeFakeGetPageModelClient(pageModel: pageModel)
        return PreviewModel(runtime: UnavailableSiteRuntime(
            reason: "no runtime needed for edit-mode toggle", mcpClient: client))
    }

    @Test("enterEditMode constructs a canvas controller; exitEditMode tears it down")
    func editModeLifecycle() async throws {
        let model = try await makeModel()
        #expect(model.isEditModeEnabled == false)
        #expect(model.wysiwygCanvas == nil)

        await model.enterEditMode(path: "src/pages/index.astro", undoManager: nil)
        #expect(model.isEditModeEnabled == true)
        #expect(model.wysiwygCanvas != nil)

        model.exitEditMode()
        #expect(model.isEditModeEnabled == false)
        #expect(model.wysiwygCanvas == nil)
    }

    /// #1225 final-review round 2, Finding A: `SiteWindowModel.windowUndoManager`'s `didSet` fan-out
    /// forwards to `preview.wysiwygCanvas?.undoCoordinator.undoManager`, but only fires when the
    /// environment value itself arrives/changes — which happens once, early, before the owner has
    /// ever toggled edit mode on. Without threading it through `enterEditMode` directly, the
    /// freshly-built canvas's `undoCoordinator.undoManager` stays permanently `nil`, so
    /// `WYSIWYGUndoCoordinator.register(...)`'s `guard let undoManager else { return nil }` always
    /// bails and canvas edits never register on the undo stack.
    @Test("enterEditMode seeds the canvas's undo coordinator with the passed-in undo manager")
    func editModeSeedsUndoManager() async throws {
        let model = try await makeModel()
        let undoManager = UndoManager()

        await model.enterEditMode(path: "src/pages/index.astro", undoManager: undoManager)
        #expect(model.wysiwygCanvas?.undoCoordinator.undoManager === undoManager)
    }

    /// Same finding, the toggle-off/toggle-on-again half: `exitEditMode()` drops `wysiwygCanvas`
    /// entirely, so a second `enterEditMode` call must build (and seed) a brand-new canvas — not
    /// silently leave the new one's `undoCoordinator.undoManager` nil because the manager was
    /// already forwarded "once" to the first canvas.
    @Test("re-entering edit mode after exiting seeds the new canvas's undo manager again")
    func reenteringEditModeReseedsUndoManager() async throws {
        let model = try await makeModel()
        let firstUndoManager = UndoManager()

        await model.enterEditMode(path: "src/pages/index.astro", undoManager: firstUndoManager)
        let firstCanvas = model.wysiwygCanvas
        #expect(firstCanvas?.undoCoordinator.undoManager === firstUndoManager)

        model.exitEditMode()
        #expect(model.wysiwygCanvas == nil)

        let secondUndoManager = UndoManager()
        await model.enterEditMode(path: "src/pages/index.astro", undoManager: secondUndoManager)
        #expect(model.wysiwygCanvas !== nil)
        #expect(model.wysiwygCanvas !== firstCanvas)
        #expect(model.wysiwygCanvas?.undoCoordinator.undoManager === secondUndoManager)
    }

    @Test("enterEditMode builds the canvas's qualityGateContext from the open site's Source/ directory")
    func editModeBuildsQualityGateContext() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let stylesDir = root.appendingPathComponent("src/styles")
        try FileManager.default.createDirectory(at: stylesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try ":root { --color-text: #111111; }".write(to: stylesDir.appendingPathComponent("global.css"), atomically: true, encoding: .utf8)

        let model = try await makeModel()
        model.open(site: CurrentSite(id: "site-1", packageURL: root, sourceDirectory: root))

        await model.enterEditMode(path: "src/pages/index.astro", undoManager: nil)

        #expect(model.wysiwygCanvas?.qualityGateContext?.resolvedTokens["color-text"] == "#111111")
    }

    @Test("enterEditMode runs one quality-gate pass against the seed model, before any edit")
    func editModeRunsInitialQualityGatePass() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let stylesDir = root.appendingPathComponent("src/styles")
        try FileManager.default.createDirectory(at: stylesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try ":root { --color-text: #777777; --color-background: #888888; }"
            .write(to: stylesDir.appendingPathComponent("global.css"), atomically: true, encoding: .utf8)

        let model = try await makeModel()
        model.open(site: CurrentSite(id: "site-1", packageURL: root, sourceDirectory: root))

        await model.enterEditMode(path: "src/pages/index.astro", undoManager: nil)

        // Without the seed pass this stays nil until the owner's first edit, so a page that
        // already has issues opens looking clean.
        #expect(model.wysiwygCanvas?.lastQualityGateResult?.findings.contains { $0.category == .contrast } == true)
    }

    @Test("enterEditMode leaves wysiwygCanvas nil and logs when the get_page_model fetch fails")
    func editModeFetchFailureLeavesCanvasNil() async {
        // `UnavailableSiteRuntime`'s default `mcpClient` is never started — `PageModelClient
        // .fetch` throws `.notConnected` immediately, exercising the plan's design decision 4
        // (no dedicated failure UI beyond a log line) end-to-end from `PreviewModel`.
        let model = PreviewModel(runtime: UnavailableSiteRuntime(reason: "deliberately not started"))

        await model.enterEditMode(path: "src/pages/index.astro", undoManager: nil)

        #expect(model.isEditModeEnabled == false)
        #expect(model.wysiwygCanvas == nil)
    }
}

/// The block canvas as the site window's *default* state (#1957, decision D4): it mounts on its
/// own as the preview navigates, follows route changes, and only Site ▸ Edit Page turning it off
/// keeps it off. Same fake `get_page_model` client as the suite above.
@Suite("PreviewModel edit mode is the default state (#1957)")
@MainActor
struct PreviewModelDefaultEditModeTests {
    private static func cannedPageModel() -> PageModel {
        PageModel(
            version: "sha256:test00000000", path: "src/pages/index.astro",
            tree: .init(
                id: "root", kind: .fragment, tag: nil, attrs: [], span: .init(start: 0, end: 0),
                loc: nil, text: nil, children: [], block: nil))
    }

    private func makeModel() async throws -> PreviewModel {
        let client = try await makeFakeGetPageModelClient(pageModel: Self.cannedPageModel())
        return PreviewModel(runtime: UnavailableSiteRuntime(reason: "no runtime needed", mcpClient: client))
    }

    @Test("the canvas is wanted by default, before anything has been mounted")
    func desiredByDefault() async throws {
        let model = try await makeModel()
        #expect(model.isEditModeDesired == true)
        #expect(model.isEditModeEnabled == false)
        #expect(model.editModePath == nil)
    }

    @Test("syncEditMode mounts a canvas for the navigated page when none is mounted")
    func syncMountsFirstCanvas() async throws {
        let model = try await makeModel()
        await model.syncEditMode(toPath: "src/pages/index.astro")
        #expect(model.isEditModeEnabled == true)
        #expect(model.editModePath == "src/pages/index.astro")
    }

    @Test("syncEditMode keeps the existing canvas for a navigation to the same page (HMR reload, ⌘R)")
    func syncSamePageKeepsCanvas() async throws {
        let model = try await makeModel()
        await model.syncEditMode(toPath: "src/pages/index.astro")
        let first = model.wysiwygCanvas
        await model.syncEditMode(toPath: "src/pages/index.astro")
        #expect(model.wysiwygCanvas === first)
    }

    @Test("syncEditMode replaces the canvas when the preview lands on a different page")
    func syncDifferentPageReplacesCanvas() async throws {
        let model = try await makeModel()
        await model.syncEditMode(toPath: "src/pages/index.astro")
        let first = model.wysiwygCanvas
        await model.syncEditMode(toPath: "src/pages/about.astro")
        #expect(model.wysiwygCanvas != nil)
        #expect(model.wysiwygCanvas !== first)
        #expect(model.editModePath == "src/pages/about.astro")
    }

    @Test("syncEditMode seeds each canvas with the window's undo manager")
    func syncSeedsWindowUndoManager() async throws {
        let model = try await makeModel()
        let undoManager = UndoManager()
        model.windowUndoManager = undoManager
        await model.syncEditMode(toPath: "src/pages/index.astro")
        #expect(model.wysiwygCanvas?.undoCoordinator.undoManager === undoManager)
    }

    @Test("Site ▸ Edit Page off tears the canvas down and stops navigations from remounting it")
    func toggleOffSticks() async throws {
        let model = try await makeModel()
        await model.syncEditMode(toPath: "src/pages/index.astro")
        #expect(model.isEditModeEnabled == true)

        await model.setEditMode(enabled: false, path: "src/pages/index.astro", undoManager: nil)
        #expect(model.isEditModeDesired == false)
        #expect(model.isEditModeEnabled == false)
        #expect(model.editModePath == nil)

        await model.syncEditMode(toPath: "src/pages/about.astro")
        #expect(model.isEditModeEnabled == false)
    }

    @Test("Site ▸ Edit Page on again remounts for the current page and records the undo manager")
    func toggleOnRemounts() async throws {
        let model = try await makeModel()
        await model.setEditMode(enabled: false, path: "src/pages/index.astro", undoManager: nil)
        let undoManager = UndoManager()

        await model.setEditMode(enabled: true, path: "src/pages/about.astro", undoManager: undoManager)
        #expect(model.isEditModeDesired == true)
        #expect(model.editModePath == "src/pages/about.astro")
        #expect(model.windowUndoManager === undoManager)
        #expect(model.wysiwygCanvas?.undoCoordinator.undoManager === undoManager)
    }

    @Test("exitEditMode from a runtime teardown leaves the owner's preference alone")
    func exitKeepsPreference() async throws {
        let model = try await makeModel()
        await model.syncEditMode(toPath: "src/pages/index.astro")
        model.exitEditMode()
        #expect(model.isEditModeDesired == true)
        #expect(model.isEditModeEnabled == false)
        await model.syncEditMode(toPath: "src/pages/index.astro")
        #expect(model.isEditModeEnabled == true)
    }

    @Test("a fetch that fails leaves no canvas and no recorded path, so the next navigation retries")
    func failedFetchLeavesNothingBehind() async {
        let model = PreviewModel(runtime: UnavailableSiteRuntime(reason: "deliberately not started"))
        await model.syncEditMode(toPath: "src/pages/index.astro")
        #expect(model.isEditModeEnabled == false)
        #expect(model.editModePath == nil)
    }
}
