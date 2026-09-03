# Hosted Community Provisioning + Moderation Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close #907's three deferred follow-ups — a "New Community" site-creation flow, deploy wiring for the already-modeled Group actor-type/moderators fields, and a moderator UI for remove-post/ban-member — as three independently-mergeable, stacked PRs.

**Architecture:** A hosted community is an ordinary `.anglesite` package with `SiteType.community`, scaffolded through the existing `SiteScaffolder` pipeline. Its Worker gets a `Group`-typed ActivityPub actor via fields (`activityPubActorType`, `moderators`) that `WorkerComposition.generateWranglerToml` already accepts but nothing yet threads through. Moderation (ban/remove) reuses `CommunityMembershipClient`'s existing owner-outbox-POST pattern with one new method.

**Tech Stack:** Swift 6.4, SwiftUI, Swift Testing (`AnglesiteCoreTests`) and XCTest (site-creation tests, matching existing file conventions) — see each task for which convention its test file uses.

## Global Constraints

- Every `SiteSettings` field stays `Optional` (forward-compat rule, `SiteConfigStore.swift:854-858`) — new fields must follow this.
- No new third-party dependencies (CONTRIBUTING.md ▸ "Code guidelines").
- `Process()` is never called directly from a view — go through `ProcessSupervisor`/injected closures (existing pattern, all tasks below already follow it).
- Every existing non-community site must be byte-for-byte unaffected by Phase 1/2 changes — new params default to `nil`/absent.
- Commit subject ≤72 characters, conventional-commit format, reference the issue number (CONTRIBUTING.md).
- Design doc: `docs/superpowers/specs/2026-08-10-hosted-community-provisioning-moderation-design.md` — read it first; this plan implements its §3–§7.

---

## Phase 1 — New Community creation flow (Tasks 1–3, one PR)

### Task 1: Add `SiteType.community`

**Files:**
- Modify: `Sources/AnglesiteCore/NewSiteDraft.swift:349-386` (case list + `label`/`description`/`symbol` switches)
- Modify: `Sources/AnglesiteCore/ThemeCatalog.swift:61-71` (`defaultThemeID(for:)` preferred-mapping dict)
- Modify: `Sources/AnglesiteCore/HeroImage.swift:53-60` (`styleHint(for:)` switch)
- Test: `Tests/AnglesiteCoreTests/ThemeCatalogTests.swift:62-71` (extend existing test)

**Interfaces:**
- Produces: `SiteType.community` — a new case later tasks construct `NewSiteDraft(siteType: .community, ...)` with.

- [ ] **Step 1: Write the failing test**

Extend the existing `defaultThemeIDUsesPreferredMappingWhenPresent` test in `Tests/AnglesiteCoreTests/ThemeCatalogTests.swift` (currently lines 62-71):

```swift
    @Test func defaultThemeIDUsesPreferredMappingWhenPresent() {
        let ids = ["classic", "elegant", "warm", "bold", "community"]
        let catalog = ThemeCatalog(themes: ids.map {
            Theme(id: $0, name: $0, blurb: "", swatch: [], cssVars: [:])
        })
        #expect(catalog.defaultThemeID(for: .business) == "classic")
        #expect(catalog.defaultThemeID(for: .personal) == "elegant")
        #expect(catalog.defaultThemeID(for: .blog) == "warm")
        #expect(catalog.defaultThemeID(for: .portfolio) == "bold")
        #expect(catalog.defaultThemeID(for: .organization) == "community")
        #expect(catalog.defaultThemeID(for: .community) == "community")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter ThemeCatalogTests`
Expected: **build failure** — `type 'SiteType' has no member 'community'` (the case doesn't exist yet; this is the correct "fails" signal for a new-enum-case step).

- [ ] **Step 3: Add the case and update every exhaustive switch/dict over `SiteType`**

In `Sources/AnglesiteCore/NewSiteDraft.swift`, change the case list (line 349):

```swift
    case business, personal, blog, portfolio, organization, community, blank
```

Add a case to each of the three switches immediately below it (`label`, `description`, `symbol`):

```swift
        case .business:     return "Business website"
        case .personal:     return "Personal website"
        case .blog:         return "Blog"
        case .portfolio:    return "Portfolio"
        case .organization: return "Organization website"
        case .community:    return "Hosted community"
        case .blank:        return "Blank website"
```

```swift
        case .business:     return "Promote a company, service, or local shop."
        case .personal:     return "Create a home for your bio, links, and projects."
        case .blog:         return "Publish posts, articles, or updates over time."
        case .portfolio:    return "Showcase selected work, case studies, or creative projects."
        case .organization: return "Share a group mission, programs, events, and ways to get involved."
        case .community:    return "Host a fediverse community others can join and post to."
        case .blank:        return "Start with a simple empty website you can shape yourself."
```

```swift
        case .business:     return "building.2"
        case .personal:     return "person.crop.circle"
        case .blog:         return "text.alignleft"
        case .portfolio:    return "square.grid.2x2"
        case .organization: return "person.3"
        case .community:    return "person.3.sequence"
        case .blank:        return "doc"
```

In `Sources/AnglesiteCore/ThemeCatalog.swift`, add an entry to the preferred-mapping dict (`defaultThemeID(for:)`, currently lines 61-71):

```swift
    public func defaultThemeID(for type: SiteType) -> String {
        let preferred: [SiteType: String] = [
            .business: "classic", .personal: "elegant", .blog: "warm",
            .portfolio: "bold", .organization: "community", .community: "community",
            .blank: "classic",
        ]
        let want = preferred[type] ?? "classic"
        if theme(id: want) != nil { return want }
        return themes.first?.id ?? want
    }
```

In `Sources/AnglesiteCore/HeroImage.swift`, add a case to `styleHint(for:)` (currently lines 53-60) — the string must be distinct from every other case's, since `Tests/AnglesiteCoreTests/HeroImageTests.swift:46-49`'s `styleHintPerType` asserts uniqueness across `SiteType.allCases`:

```swift
    static func styleHint(for siteType: SiteType) -> String {
        switch siteType {
        case .business:     return "modern professional abstract illustration"
        case .personal:     return "warm friendly personal abstract illustration"
        case .blog:         return "editorial abstract header illustration"
        case .portfolio:    return "creative abstract portfolio illustration"
        case .organization: return "welcoming community abstract illustration"
        case .community:    return "collaborative group abstract illustration"
        case .blank:        return "simple abstract geometric illustration"
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter ThemeCatalogTests`
Run: `swift test --package-path . --filter HeroImageTests`
Expected: PASS — `HeroImageTests.styleHintPerType` and `ThemeCatalogTests.defaultThemeIDResolvesForEverySiteType` both iterate `SiteType.allCases` already, so they exercise `.community` automatically with no further test changes needed.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/NewSiteDraft.swift Sources/AnglesiteCore/ThemeCatalog.swift Sources/AnglesiteCore/HeroImage.swift Tests/AnglesiteCoreTests/ThemeCatalogTests.swift
git commit -m "feat(#907): add SiteType.community"
```

---

### Task 2: `NewCommunityWizardModel`

**Files:**
- Create: `Sources/AnglesiteCore/NewCommunityWizardModel.swift`
- Test: Create `Tests/AnglesiteCoreTests/NewCommunityWizardModelTests.swift`

**Interfaces:**
- Consumes: `SiteScaffolder.scaffold(_ draft: NewSiteDraft) -> AsyncStream<SiteScaffolder.ScaffoldStep>` (existing, `Sources/AnglesiteCore/SiteScaffolder.swift:620`); `SiteType.community` (Task 1).
- Produces: `NewCommunityWizardModel` — `step: Step` (`.chooser`/`.building`), `communityName: String` (bound to a text field), `canCreate: Bool`, `progress: [SiteScaffolder.ScaffoldStep]`, `fatal: SiteScaffolder.ScaffoldStep?`, `completedSiteID: String?`, `hasWarnings: Bool`, `didCompleteCleanly: Bool`, `func build(using scaffolder: SiteScaffolder) async -> String?`. Task 3's `NewCommunityWizard` view binds directly to this model, mirroring how `NewSiteWizard` binds to `NewSiteWizardModel`.

- [ ] **Step 1: Write the failing test**

Create `Tests/AnglesiteCoreTests/NewCommunityWizardModelTests.swift`:

```swift
import XCTest
@testable import AnglesiteCore

@MainActor
final class NewCommunityWizardModelTests: XCTestCase {

    func testStartsOnChooserWithEmptyNameAndCannotCreate() {
        let m = NewCommunityWizardModel(isNameTaken: { _ in false })
        XCTAssertEqual(m.step, .chooser)
        XCTAssertEqual(m.communityName, "")
        XCTAssertFalse(m.canCreate)
    }

    func testCanCreateOnceNameIsNonEmptyAndNotTaken() {
        let m = NewCommunityWizardModel(isNameTaken: { _ in false })
        m.communityName = "Birding Club"
        XCTAssertTrue(m.canCreate)
    }

    func testCannotCreateWhenNameIsTaken() {
        let m = NewCommunityWizardModel(isNameTaken: { $0 == "Birding Club" })
        m.communityName = "Birding Club"
        XCTAssertFalse(m.canCreate)
    }

    func testCannotCreateWithWhitespaceOnlyName() {
        let m = NewCommunityWizardModel(isNameTaken: { _ in false })
        m.communityName = "   "
        XCTAssertFalse(m.canCreate)
    }

    func testBuildDrivesScaffolderWithCommunitySiteTypeAndFixedTheme() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let m = NewCommunityWizardModel(isNameTaken: { _ in false })
        m.communityName = "Birding Club"

        var seenDraft: NewSiteDraft?
        let scaffolder = SiteScaffolder(
            sitesRoot: root,
            templateURL: URL(fileURLWithPath: "/template"),
            catalog: ThemeCatalog(themes: [Theme(id: "community", name: "Community", blurb: "", swatch: [], cssVars: [:])]),
            run: { _, args, cwd in
                if args.contains(where: { $0.hasSuffix("scaffold.sh") }), let cwd {
                    let astro = cwd.appendingPathComponent("src/pages/index.astro")
                    try? FileManager.default.createDirectory(at: astro.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? "<h1>Welcome</h1>".write(to: astro, atomically: true, encoding: .utf8)
                    try? "ANGLESITE_VERSION=1.0.0".write(to: cwd.appendingPathComponent(".site-config"), atomically: true, encoding: .utf8)
                }
                return ProcessSupervisor.RunResult(stdout: "", stderr: "", exitCode: 0)
            },
            gitInit: { _ in },
            gitCommit: { _ in },
            register: { pkg in
                SiteStore.Site(id: pkg.url.path, name: pkg.url.lastPathComponent, packageURL: pkg.url, isValid: true, missingSentinels: [])
            }
        )

        let id = await m.build(using: scaffolder)

        XCTAssertNotNil(id)
        XCTAssertTrue(m.didCompleteCleanly)
        XCTAssertEqual(m.draft.siteType, .community)
        XCTAssertEqual(m.draft.name, "Birding Club")
        XCTAssertEqual(m.draft.themeID, "community")
        XCTAssertEqual(m.draft.headline, "")   // skip homepage write, matches NewSiteWizardModel's convention
        seenDraft = m.draft
        XCTAssertNotNil(seenDraft)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter NewCommunityWizardModelTests`
Expected: FAIL — `cannot find 'NewCommunityWizardModel' in scope` (type doesn't exist yet).

- [ ] **Step 3: Write the implementation**

Create `Sources/AnglesiteCore/NewCommunityWizardModel.swift`:

```swift
import Foundation
import Observation

/// Observable state behind the New Community wizard (V-5.1b, #907, design doc §3) — a
/// distinct flow from ``NewSiteWizardModel``: a hosted community is a different site kind
/// (own Worker, own Group actor, moderators), not a cosmetic theme pick, so it asks for a
/// name only and skips the theme grid entirely, reusing the "community" catalog theme
/// (the same palette `ThemeCatalog.defaultThemeID(for: .organization)` already maps to) as
/// its one consistent look.
@MainActor
@Observable
public final class NewCommunityWizardModel {
    /// Mirrors ``NewSiteWizardModel/Step`` — the chooser (name entry) and building (scaffold
    /// progress) states.
    public enum Step: Int, CaseIterable {
        case chooser
        case building
    }

    public private(set) var step: Step = .chooser
    /// The owner-entered community name; bound to the wizard's text field.
    public var communityName: String = ""
    /// Every ``SiteScaffolder/ScaffoldStep`` emitted so far, in order.
    public private(set) var progress: [SiteScaffolder.ScaffoldStep] = []
    /// The `.failed` step, if any.
    public private(set) var fatal: SiteScaffolder.ScaffoldStep?
    /// The new site's registered id once scaffolding reaches `.done`; `nil` until then.
    public private(set) var completedSiteID: String?

    /// Availability check for a candidate site name — same contract as
    /// ``NewSiteWizardModel/init(catalog:isNameTaken:)``'s parameter.
    private let isNameTaken: (String) -> Bool

    public init(isNameTaken: @escaping (String) -> Bool) {
        self.isNameTaken = isNameTaken
    }

    /// The draft `build(using:)` will scaffold, computed fresh from ``communityName`` each
    /// time it's read — there's no per-field mutation to track separately, unlike
    /// ``NewSiteWizardModel/draft``, since a community draft has exactly one owner-set field.
    public var draft: NewSiteDraft {
        var draft = NewSiteDraft(siteType: .community, name: trimmedName,
                                 saveFileName: "\(trimmedName).anglesite", headline: "")
        draft.themeID = "community"
        return draft
    }

    private var trimmedName: String {
        communityName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Gate for the chooser's Create button: a non-empty, not-already-taken name, and no
    /// build running.
    public var canCreate: Bool {
        step == .chooser && !trimmedName.isEmpty && !isNameTaken(trimmedName)
    }

    public var warnings: [String] {
        progress.compactMap { if case .warning(_, let message) = $0 { return message } else { return nil } }
    }

    public var hasWarnings: Bool { !warnings.isEmpty }

    public var didCompleteCleanly: Bool { completedSiteID != nil && !hasWarnings }

    /// Runs the scaffolder against ``draft``, accumulating progress. Returns the new site id
    /// on success. Mirrors ``NewSiteWizardModel/build(using:)`` exactly.
    public func build(using scaffolder: SiteScaffolder) async -> String? {
        step = .building
        for await s in scaffolder.scaffold(draft) {
            progress.append(s)
            if case .failed = s { fatal = s }
            if case .done(let id) = s { completedSiteID = id }
        }
        return completedSiteID
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter NewCommunityWizardModelTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/NewCommunityWizardModel.swift Tests/AnglesiteCoreTests/NewCommunityWizardModelTests.swift
git commit -m "feat(#907): add NewCommunityWizardModel"
```

---

### Task 3: `NewCommunityWizard` view, File menu entry, launcher wiring

**Files:**
- Create: `Sources/AnglesiteApp/NewCommunityWizard.swift`
- Modify: `Sources/AnglesiteApp/FocusedSite.swift:63-72` (`NewContentCommands` — add the menu item)
- Modify: `Sources/AnglesiteApp/SitesLauncherView.swift` (extract shared scaffolding-context setup, add `presentNewCommunity()`, a `newCommunitySession` sheet, `.onChange`/first-appear wiring)
- Modify: `Sources/AnglesiteIntents/WindowRouter.swift:65-77` (add `newCommunityRequested`/`requestNewCommunity()`/`clearNewCommunityRequest()`, mirroring the `newSiteRequested` trio)

**Interfaces:**
- Consumes: `NewCommunityWizardModel` (Task 2), `SiteScaffolder` (existing).
- Produces: a working `File ▸ New Community…` menu command, ⇧⌘ mnemonic-free (no reserved shortcut assigned — Cmd+Shift+N is already New Site's).

This task is UI/app-layer wiring with no unit-testable business logic of its own (the model it drives was already tested in Task 2) — verify by running the app and using the menu command, per the Testing section at the end of this task.

- [ ] **Step 1: Add the WindowRouter request trio**

In `Sources/AnglesiteIntents/WindowRouter.swift`, immediately after the existing `newSiteRequested` block (currently lines 65-77), add:

```swift
    /// Set by File ▸ New Community (which can't host the wizard sheet itself). Mirrors
    /// ``newSiteRequested``'s set-then-consume contract exactly — see that property's doc
    /// comment (#907, design doc §3, a distinct flow from New Site since a hosted community
    /// is a different site kind, not a theme pick).
    public private(set) var newCommunityRequested = false

    /// Flags a pending File ▸ New Community request for the "Sites" launcher to consume.
    public func requestNewCommunity() { newCommunityRequested = true }

    /// Called by the launcher once it has consumed the request.
    public func clearNewCommunityRequest() { newCommunityRequested = false }
```

- [ ] **Step 2: Add the menu command**

In `Sources/AnglesiteApp/FocusedSite.swift`, inside `NewContentCommands`'s `CommandGroup(replacing: .newItem)` (currently lines 63-72), add a new button after "New Site…":

```swift
                CommandGroup(replacing: .newItem) {
                    Button("New Site…") {
                        openWindow(id: "sites")
                        WindowRouter.shared.requestNewSite()
                    }
                    .keyboardShortcut("n", modifiers: [.command, .shift])

                    Button("New Community…") {
                        openWindow(id: "sites")
                        WindowRouter.shared.requestNewCommunity()
                    }

                    Button("Open Site…") { ... }
                    .keyboardShortcut("o")
                }
```

(Keep the existing "Open Site…" button and its shortcut unchanged — only the new "New Community…" button is inserted between it and "New Site…".)

- [ ] **Step 3: Extract the shared scaffolding-context helper in `SitesLauncherView`**

`presentNewSite()` (`SitesLauncherView.swift:406-486`) builds a `ThemeCatalog`, resolves the sites root (with MAS security-scope handling), and constructs a `SiteScaffolder` — all of which a community flow needs identically. Extract the shared part into a new private helper so Step 4 doesn't duplicate ~60 lines. Replace the body of `presentNewSite()` (keep its signature) with a call into a new `resolveScaffoldingContext()`:

```swift
    private struct ScaffoldingContext {
        let catalog: ThemeCatalog
        let scaffolder: SiteScaffolder
        let isNameTaken: (String) -> Bool
    }

    /// Everything both `presentNewSite()` and `presentNewCommunity()` need before they can
    /// construct their own wizard model: template/theme catalog, sites-root resolution (with
    /// MAS security-scope handling), name-uniqueness check, and a ready `SiteScaffolder`.
    /// Extracted so the two flows (#907, design doc §3) don't duplicate this setup.
    @MainActor
    private func resolveScaffoldingContext() async -> ScaffoldingContext? {
        let resolution = TemplateRuntime.resolve()
        guard let templateURL = resolution.url else {
            loadError = "Template not found — can't create a site. Reinstall the app."
            return nil
        }
        let catalog: ThemeCatalog
        do { catalog = try ThemeCatalog.load(templateURL: templateURL) }
        catch { loadError = "Couldn't load themes: \(error.localizedDescription)"; return nil }

        let sitesRoot = AppSettings.shared.sitesRoot

        #if ANGLESITE_MAS
        if AppSettings.shared.sitesRootSource != .iCloudContainer {
            guard let rootScope = await SiteActions.ensureSitesRootAccess(sitesRoot) else { return nil }
            sitesRootScopedURL = rootScope
        }
        #endif
        try? FileManager.default.createDirectory(at: sitesRoot, withIntermediateDirectories: true)

        try? await SiteStore.shared.load()
        let knownSites = await SiteStore.shared.sites
        let takenSlugs = Set(knownSites.map { SiteSlug.derive(from: $0.name) })
        let isNameTaken: (String) -> Bool = { name in
            takenSlugs.contains(SiteSlug.derive(from: name))
                || FileManager.default.fileExists(atPath: sitesRoot.appendingPathComponent("\(name).anglesite").path)
        }

        let scaffolder = SiteScaffolder(
            sitesRoot: sitesRoot,
            templateURL: templateURL,
            catalog: catalog,
            run: { exe, args, cwd in
                try await ProcessSupervisor.shared.run(executable: exe, arguments: args, currentDirectoryURL: cwd)
            },
            gitInit: { sourceDir in try GitInitRunner.run(in: sourceDir) },
            gitCommit: { sourceDir in try await RepoBootstrap.live().commitAll(source: sourceDir) },
            register: { package in
                let site = try await SiteStore.shared.record(package)
                #if ANGLESITE_MAS
                let bm = try SecurityScopedBookmark.create(for: site.packageURL)
                try await SiteStore.shared.setBookmark(bm, for: site.id)
                #endif
                return site
            }
        )
        return ScaffoldingContext(catalog: catalog, scaffolder: scaffolder, isNameTaken: isNameTaken)
    }

    @MainActor
    private func presentNewSite() async {
        guard newSiteSession == nil, !preparingNewSite else { return }
        preparingNewSite = true
        defer { preparingNewSite = false }
        guard let context = await resolveScaffoldingContext() else { return }
        let model = NewSiteWizardModel(catalog: context.catalog, isNameTaken: context.isNameTaken)
        newSiteSession = NewSiteSession(model: model, scaffolder: context.scaffolder)
    }
```

- [ ] **Step 4: Add `presentNewCommunity()`, its session state, and the sheet**

Add alongside `newSiteSession`'s declaration (find `@State private var newSiteSession: NewSiteSession?`):

```swift
    @State private var newCommunitySession: NewCommunitySession?
    @State private var preparingNewCommunity = false
```

Add the session struct alongside `NewSiteSession`'s existing definition:

```swift
struct NewCommunitySession: Identifiable {
    let id = UUID()
    let model: NewCommunityWizardModel
    let scaffolder: SiteScaffolder
}
```

Add the presenter, alongside `presentNewSite()`:

```swift
    @MainActor
    private func presentNewCommunity() async {
        guard newCommunitySession == nil, !preparingNewCommunity else { return }
        preparingNewCommunity = true
        defer { preparingNewCommunity = false }
        guard let context = await resolveScaffoldingContext() else { return }
        let model = NewCommunityWizardModel(isNameTaken: context.isNameTaken)
        newCommunitySession = NewCommunitySession(model: model, scaffolder: context.scaffolder)
    }
```

Add the `.onChange` and `.sheet` in `body`, mirroring the existing New Site wiring (`SitesLauncherView.swift:74-106`) — add immediately after the existing `.onChange(of: router.newSiteRequested)` block:

```swift
        .onChange(of: router.newCommunityRequested) { _, requested in
            guard requested else { return }
            router.clearNewCommunityRequest()
            Task { await presentNewCommunity() }
        }
```

and immediately after the existing `.sheet(item: $newSiteSession)` block:

```swift
        .sheet(item: $newCommunitySession) { session in
            NewCommunityWizard(
                model: session.model,
                scaffolder: session.scaffolder,
                onComplete: { siteID in
                    newCommunitySession = nil
                    Task {
                        await refreshSites()
                        openWindow(value: siteID)
                        dismissWindow()
                    }
                },
                onCancel: {
                    newCommunitySession = nil
                    deciding = false
                }
            )
            .onDisappear {
                sitesRootScopedURL?.stopAccessingSecurityScopedResource()
                sitesRootScopedURL = nil
            }
        }
```

Add the matching first-appear consume (find `onFirstAppear()`, which currently consumes `router.newSiteRequested` — see `SitesLauncherView.swift:490-498`), adding the community equivalent right after:

```swift
        if router.newCommunityRequested {
            router.clearNewCommunityRequest()
            await presentNewCommunity()
        }
```

- [ ] **Step 5: Write `NewCommunityWizard`**

Create `Sources/AnglesiteApp/NewCommunityWizard.swift`, a minimal single-question analog of `NewSiteWizard.swift` — a name field instead of a theme grid:

```swift
import SwiftUI
import AnglesiteCore

/// The New Community wizard (V-5.1b, #907, design doc §3) — one question (the community's
/// name), then it scaffolds into the default location and opens in the preview. A distinct
/// flow from ``NewSiteWizard``: a hosted community is a different site kind, not a theme
/// pick, so there is no template grid here.
struct NewCommunityWizard: View {
    @Bindable var model: NewCommunityWizardModel
    let scaffolder: SiteScaffolder
    let onComplete: (String) -> Void
    let onCancel: () -> Void

    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            content
            Divider()
            footer
        }
        .frame(width: 420, height: 220)
        .interactiveDismissDisabled(model.step == .building)
    }

    @ViewBuilder private var content: some View {
        switch model.step {
        case .chooser:  chooserStep
        case .building: buildingStep
        }
    }

    private var chooserStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Name Your Community").font(.title2.bold())
            Text("Others will be able to join and post to it from any fediverse account.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Community Name", text: $model.communityName)
                .textFieldStyle(.roundedBorder)
                .focused($nameFieldFocused)
                .onSubmit(create)
                .task { nameFieldFocused = true }
        }.padding(24)
    }

    private var buildingStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Building your community\u{2026}").font(.title2.bold())
            ForEach(Array(model.progress.enumerated()), id: \.offset) { _, s in
                Text(label(for: s)).font(.callout)
                    .accessibilityLabel(accessibilityLabel(for: s))
            }
            if case .failed(_, let msg) = model.fatal {
                Text(msg).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    .accessibilityLabel("Build failed")
                    .accessibilityValue(msg)
            }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func label(for step: SiteScaffolder.ScaffoldStep) -> String {
        switch step {
        case .creatingFolder: return "\u{2705} Created the community file"
        case .copyingTemplate: return "\u{2705} Copied the template"
        case .applyingTheme: return "\u{2705} Applied the community theme"
        case .writingContent: return "\u{2705} Prepared the starter content"
        case .installing: return "\u{23F3} Installing\u{2026}"
        case .registering: return "\u{2705} Registering"
        case .warning(_, let m): return "\u{26A0}\u{FE0F} \(m)"
        case .failed(_, let m): return "\u{274C} \(m)"
        case .done: return "\u{2705} Done"
        }
    }

    private func accessibilityLabel(for step: SiteScaffolder.ScaffoldStep) -> String {
        switch step {
        case .creatingFolder:    return "Created the community file"
        case .copyingTemplate:   return "Copied the template"
        case .applyingTheme:     return "Applied the community theme"
        case .writingContent:    return "Prepared the starter content"
        case .installing:        return "Installing…"
        case .registering:       return "Registering"
        case .warning(_, let m): return "Warning: \(m)"
        case .failed(_, let m):  return "Failed: \(m)"
        case .done:              return "Done"
        }
    }

    @ViewBuilder private var footer: some View {
        HStack {
            Spacer()
            if model.step == .chooser {
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction).disabled(!model.canCreate)
            } else if model.completedSiteID == nil && model.fatal != nil {
                Button("Close") { onCancel() }
            }
        }.padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func create() {
        guard model.canCreate else { return }
        Task {
            _ = await model.build(using: scaffolder)
            if model.didCompleteCleanly, let id = model.completedSiteID { onComplete(id) }
        }
    }
}
```

- [ ] **Step 6: Manual verification (no automated test — SwiftUI view + app-layer wiring)**

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: builds clean.

Then launch the app (`open Anglesite.xcodeproj`, ⌘R), and:
1. `File ▸ New Community…` opens a sheet asking only for a name.
2. Typing a name enables Create; Create is disabled while the field is empty.
3. Clicking Create scaffolds a new `.anglesite` package and opens it.
4. In the new site's `Source/.site-config`, confirm `SITE_TYPE=community` and `THEME=community` are present.

- [ ] **Step 7: Commit**

```bash
git add Sources/AnglesiteApp/NewCommunityWizard.swift Sources/AnglesiteApp/FocusedSite.swift Sources/AnglesiteApp/SitesLauncherView.swift Sources/AnglesiteIntents/WindowRouter.swift
git commit -m "feat(#907): add File > New Community… creation flow"
```

**This completes Phase 1 — open a PR here** (per CONTRIBUTING.md's PR template; see the design doc §1 for phase boundaries).

---

## Phase 2 — Deploy wiring (Tasks 4–5, one PR)

### Task 4: Thread `activityPubActorType`/`moderators` through `SocialWorkerProvisionCommand`

**Files:**
- Modify: `Sources/AnglesiteCore/SocialWorkerProvisionCommand.swift` (`provision()` signature at lines 153-201, `persistConfig` signature at lines 600-609, all 10 `persistConfig(...)` call sites at lines 266, 293, 313, 336, 375, 388, 478, 503, 528, 538)
- Test: `Tests/AnglesiteCoreTests/SocialWorkerProvisionCommandTests.swift`

**Interfaces:**
- Consumes: `WorkerComposition.generateWranglerToml(..., activityPubActorType: String?, moderators: [String]?, ...)` (already exists, `WorkerComposition.swift:195-198,218`).
- Produces: `SocialWorkerProvisionCommand.provision(..., activityPubActorType: String? = nil, moderators: [String]? = nil)` — Task 5 calls this with real values.

- [ ] **Step 1: Write the failing test**

Add to `Tests/AnglesiteCoreTests/SocialWorkerProvisionCommandTests.swift`, following the exact fixture pattern `provisionsV2Worker` uses (lines 67-109):

```swift
    @Test("threads activityPubActorType and moderators into the deployed wrangler.toml")
    func provisionsGroupActorWithModerators() async throws {
        let site = try temporaryDirectory()
        let recorder = WranglerRecorder([:])
        let deployer = DeployRecorder(result: .succeeded(url: URL(string: "https://my-site.example.workers.dev")!, duration: 1))
        let command = SocialWorkerProvisionCommand(tokenSource: { "token" }, runner: recorder.runner, deployer: deployer.deployer)

        let result = await command.provision(
            siteID: "site-1", siteDirectory: site, siteName: "my-site", workers: [],
            activityPubActorType: "Group", moderators: ["https://mod.example/actor"]
        )

        guard case .succeeded = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        let toml = try String(contentsOf: site.appendingPathComponent("wrangler.toml"), encoding: .utf8)
        #expect(toml.contains("AP_ACTOR_TYPE = \"Group\""))
        #expect(toml.contains("AP_MODERATORS = \"https://mod.example/actor\""))
    }

    @Test("omitting activityPubActorType leaves an ordinary Person actor, unaffected")
    func provisionsWithoutActorTypeStaysUnaffected() async throws {
        let site = try temporaryDirectory()
        let recorder = WranglerRecorder([:])
        let deployer = DeployRecorder(result: .succeeded(url: URL(string: "https://my-site.example.workers.dev")!, duration: 1))
        let command = SocialWorkerProvisionCommand(tokenSource: { "token" }, runner: recorder.runner, deployer: deployer.deployer)

        let result = await command.provision(siteID: "site-1", siteDirectory: site, siteName: "my-site", workers: [])

        guard case .succeeded = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        let toml = try String(contentsOf: site.appendingPathComponent("wrangler.toml"), encoding: .utf8)
        #expect(!toml.contains("AP_ACTOR_TYPE"))
        #expect(!toml.contains("AP_MODERATORS"))
    }
```

Note: this test uses an activitypub-less `workers: []` list deliberately — `WorkerComposition`'s `AP_ACTOR_TYPE`/`AP_MODERATORS` branch is gated on `hasActivityPub` (`WorkerComposition.swift:512`, `workers.contains(where: { $0.id == activitypubWorkerID })`). If the first test fails because the vars aren't emitted without an activitypub worker present, add the same `worker(WorkerComposition.activitypubWorkerID, d1: false, kv: false, r2: false)` fixture `WorkerCompositionTests.swift:6-11` uses, and pass it in `workers:` for the first test only (the second test's whole point is confirming no vars leak in *without* Group actor type, so it should keep `workers: []`).

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter SocialWorkerProvisionCommandTests`
Expected: **build failure** — `provision(...)` has no parameters `activityPubActorType`/`moderators` yet.

- [ ] **Step 3: Thread the two new parameters through**

In `Sources/AnglesiteCore/SocialWorkerProvisionCommand.swift`, add two new trailing optional parameters to `provision()` (currently ending at line 200-201 with `inboxCaptureEnabled: Bool = false`):

```swift
        inboxCaptureEnabled: Bool = false,
        /// This site's ActivityPub actor type (V-5.1b, #907; `SiteSettings`'s sibling concept
        /// to `communityActorURL`) — `"Group"` for a hosted community, `nil` for an ordinary
        /// Person actor. Forwarded verbatim to `WorkerComposition.generateWranglerToml`, which
        /// already only emits a var when this is exactly `"Group"`.
        activityPubActorType: String? = nil,
        /// Actor IRIs authorized to moderate this site's Group actor (`SiteSettings.moderators`).
        /// Ignored for a Person actor, same as `WorkerComposition.generateWranglerToml`'s own
        /// `moderators` parameter.
        moderators: [String]? = nil
    ) async -> Result {
```

Add matching parameters to `persistConfig` (currently lines 600-609):

```swift
    private func persistConfig(
        siteDirectory: URL,
        siteName: String,
        workers: [WorkerDescriptor],
        routeClaims: [WorkerRouteClaim],
        resources: WorkerComposition.ProvisionedResources,
        siteURL: String? = nil,
        displayName: String? = nil,
        apUsername: String? = nil,
        inboxCaptureEnabled: Bool = false,
        activityPubActorType: String? = nil,
        moderators: [String]? = nil
    ) -> Result? {
```

Thread them into the `generateWranglerToml` call inside `persistConfig` (currently lines 613-622):

```swift
            let toml = try WorkerComposition.generateWranglerToml(
                siteName: siteName,
                workers: workers,
                routeClaims: routeClaims,
                resources: resources,
                inboxCaptureEnabled: inboxCaptureEnabled,
                inboxKVNamespaceID: resources.inboxKVNamespaceID,
                siteURL: siteURL,
                displayName: displayName,
                activityPubActorType: activityPubActorType,
                moderators: moderators,
                apUsername: apUsername
            )
```

Finally, add `activityPubActorType: activityPubActorType, moderators: moderators` as trailing named arguments to every one of the 10 `persistConfig(...)` call sites inside `provision()` (grep to find them: `grep -n "persistConfig(" Sources/AnglesiteCore/SocialWorkerProvisionCommand.swift` → lines 266, 293, 313, 336, 375, 388, 478, 503, 528, 538). Every call site already passes `inboxCaptureEnabled: inboxCaptureEnabled` as its last argument — add the two new arguments immediately after it at each site, e.g. line 266 becomes:

```swift
                if let failure = persistConfig(siteDirectory: siteDirectory, siteName: siteName, workers: workers, routeClaims: routeClaims, resources: resources, siteURL: siteURL, displayName: displayName, apUsername: apUsername, inboxCaptureEnabled: inboxCaptureEnabled, activityPubActorType: activityPubActorType, moderators: moderators) {
```

(and identically for the other 9 sites — the two new arguments read the same `provision()`-scope parameters by the same names everywhere, since Swift resolves `activityPubActorType`/`moderators` to `provision()`'s own parameters at every call site inside its body.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter SocialWorkerProvisionCommandTests`
Expected: PASS, including all pre-existing tests in this file (confirms the 10 call-site edits didn't break any of them).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/SocialWorkerProvisionCommand.swift Tests/AnglesiteCoreTests/SocialWorkerProvisionCommandTests.swift
git commit -m "feat(#907): thread Group actor-type/moderators into provision()"
```

---

### Task 5: `DeployModel` call site — pass the fields, write back `communityActorURL`

**Files:**
- Modify: `Sources/AnglesiteApp/DeployModel.swift:840-885`
- Modify: `Sources/AnglesiteCore/DeployCoordinator.swift:234-238` (new `resolveIsHostedCommunity`), `:374-396` (`persistProvisionedResources` — add `communityActorURL` param)
- Test: `Tests/AnglesiteCoreTests/DeployCoordinatorTests.swift` (or wherever `persistProvisionedResources`/`resolveWorkerSiteName` are already tested — grep `grep -rln "persistProvisionedResources\|resolveWorkerSiteName" Tests/` to confirm the exact file before adding)

**Interfaces:**
- Consumes: `ActivityPubActor.actorURL(siteURL: URL) -> URL` (existing, `Sources/AnglesiteCore/ActivityPubFollowers.swift:19`); `SiteConfigFile.value(forKey:in:)` (existing, used identically by `resolveWorkerSiteName`).
- Produces: `DeployCoordinator.resolveIsHostedCommunity(siteDirectory: URL) -> Bool`; `persistProvisionedResources(..., communityActorURL: URL? = nil)`.

- [ ] **Step 1: Write the failing test**

First run `grep -rln "persistProvisionedResources" Tests/AnglesiteCoreTests/` to find the existing test file covering it, then add (adjust the `#Test`/`XCTest` style to match whatever that file already uses):

```swift
    @Test("resolveIsHostedCommunity reads SITE_TYPE=community from .site-config")
    func resolveIsHostedCommunityReadsSiteType() throws {
        let dir = try temporaryDirectory()
        try "SITE_TYPE=community\n".write(to: dir.appendingPathComponent(".site-config"), atomically: true, encoding: .utf8)
        #expect(DeployCoordinator.resolveIsHostedCommunity(siteDirectory: dir))
    }

    @Test("resolveIsHostedCommunity is false for every other site kind, including no .site-config at all")
    func resolveIsHostedCommunityFalseOtherwise() throws {
        let dir = try temporaryDirectory()
        #expect(!DeployCoordinator.resolveIsHostedCommunity(siteDirectory: dir))
        try "SITE_TYPE=business\n".write(to: dir.appendingPathComponent(".site-config"), atomically: true, encoding: .utf8)
        #expect(!DeployCoordinator.resolveIsHostedCommunity(siteDirectory: dir))
    }

    @Test("persistProvisionedResources writes communityActorURL when given one")
    func persistProvisionedResourcesWritesCommunityActorURL() async throws {
        let dir = try temporaryDirectory()
        let configStore = SiteConfigStore(configDirectory: dir)
        let actorURL = URL(string: "https://my-community.example/users/site")!

        await DeployCoordinator.persistProvisionedResources(
            configStore: configStore, settings: SiteSettings(), effectiveActiveIDs: [],
            resources: .init(), communityActorURL: actorURL
        )

        let saved = try await configStore.load()
        #expect(saved.communityActorURL == actorURL)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter DeployCoordinatorTests` (substitute the actual file name found above)
Expected: build failure — `resolveIsHostedCommunity` doesn't exist yet, and `persistProvisionedResources` has no `communityActorURL` parameter.

- [ ] **Step 3: Implement**

In `Sources/AnglesiteCore/DeployCoordinator.swift`, add a new function next to `resolveWorkerSiteName` (currently lines 234-238), following its exact read pattern:

```swift
    /// Whether this site is a hosted community (V-5.1b, #907) — read from `.site-config`'s
    /// `SITE_TYPE`, the same key `SiteScaffolder.appendSiteConfig` writes from
    /// `NewSiteDraft.siteType` at creation time. There's no `SiteSettings` field for site kind
    /// (`SiteType` is a creation-time-only concept), so this is the one read-through-the-file
    /// check the deploy path needs to decide whether to compose a Group actor.
    public static func resolveIsHostedCommunity(siteDirectory: URL) -> Bool {
        let existingConfig = (try? WebsiteAnalyticsAsset.loadConfig(siteDirectory: siteDirectory)) ?? ""
        return SiteConfigFile.value(forKey: "SITE_TYPE", in: existingConfig) == SiteType.community.rawValue
    }
```

Extend `persistProvisionedResources` (currently lines 374-396) with a new parameter and write:

```swift
    public static func persistProvisionedResources(
        configStore: SiteConfigStore,
        settings: SiteSettings,
        effectiveActiveIDs: Set<String>,
        resources: WorkerComposition.ProvisionedResources,
        apUsername: String? = nil,
        /// This deploy's resolved ActivityPub actor IRI (`ActivityPubActor.actorURL(siteURL:)`),
        /// passed only when this site is a hosted community (V-5.1b, #907) whose Worker was just
        /// composed with a Group actor. Advances `settings.communityActorURL` — the field
        /// `CommunityMembersSync`/the Moderation section gate on — from inert to live. `nil` for
        /// every other site, leaving the field untouched (it's already `nil` there).
        communityActorURL: URL? = nil
    ) async {
        var updated = settings
        updated.lastDeployedWorkerIDs = Array(effectiveActiveIDs).sorted()
        updated.provisionedWorkerResources = resources
        if let apUsername {
            updated.lastDeployedAPUsername = apUsername
        }
        if let communityActorURL {
            updated.communityActorURL = communityActorURL
        }
        try? await configStore.save(updated)
    }
```

In `Sources/AnglesiteApp/DeployModel.swift`, extend the `provision()` call (currently lines 840-852) with the two new fields, computed from `resolveIsHostedCommunity`:

```swift
        let isHostedCommunity = DeployCoordinator.resolveIsHostedCommunity(siteDirectory: siteDirectory)
        let provisionResult = await socialCommand.provision(
            siteID: siteID,
            siteDirectory: siteDirectory,
            siteName: workerSiteName,
            workers: workers,
            routeClaims: routeClaims.map(\.claim),
            knownResources: settings.provisionedWorkerResources ?? .init(),
            siteURL: siteURL,
            displayName: settings.displayName,
            apUsername: apUsername,
            acknowledgesPaidPlan: acknowledgesPaidPlan,
            inboxCaptureEnabled: settings.inboxCaptureEnabled ?? false,
            activityPubActorType: isHostedCommunity ? "Group" : nil,
            moderators: isHostedCommunity ? settings.moderators : nil
        )
```

And extend the post-success `persistProvisionedResources` call (currently lines 880-885) to pass the resolved actor IRI, computed from the deploy's own successful `url`:

```swift
        if case .succeeded(let deployedURL, let resources, _) = provisionResult {
            await DeployCoordinator.persistProvisionedResources(
                configStore: configStore, settings: settings,
                effectiveActiveIDs: effectiveActiveIDs, resources: resources,
                apUsername: activitypubProvisioned ? resolvedApUsername : nil,
                communityActorURL: (isHostedCommunity && activitypubProvisioned)
                    ? ActivityPubActor.actorURL(siteURL: deployedURL) : nil
            )
            websubProvisioned = workers.contains(where: { $0.id == WorkerComposition.websubWorkerID })
                && resources.websubQueueName != nil
        } else {
            websubProvisioned = false
        }
```

(Note the original code used `_` for the succeeded-case URL binding at line 880 — renaming it to `deployedURL` here since this is now consumed. Nothing else in that branch used it before.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter DeployCoordinatorTests` (or the actual file name)
Expected: PASS.

Run the full suite to catch any other caller of `persistProvisionedResources`/`provision()` that needs updating: `swift test --package-path . --skip Domain` (per this repo's known-flaky-suite convention — see `CLAUDE.md`).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/DeployCoordinator.swift Sources/AnglesiteApp/DeployModel.swift Tests/AnglesiteCoreTests/*.swift
git commit -m "feat(#907): deploy Group actor config, write back communityActorURL"
```

**This completes Phase 2 — open a PR here, stacked on Phase 1's branch.**

---

## Phase 3 — Moderator UI (Tasks 6–9, one PR)

### Task 6: `CommunityMembershipClient.remove(target:)`

**Files:**
- Modify: `Sources/AnglesiteCore/CommunityMembershipClient.swift:57-107` (add the new method after `unfollow`)
- Test: `Tests/AnglesiteCoreTests/CommunityMembershipClientTests.swift`

**Interfaces:**
- Produces: `CommunityMembershipClient.remove(target: URL) async throws -> Void` — POSTs `Remove` to the owner's own outbox. Task 9's `ModerationView` calls this for both ban-member and remove-post (workers#473's "one primitive, two moderation effects").

- [ ] **Step 1: Write the failing test**

Add to `Tests/AnglesiteCoreTests/CommunityMembershipClientTests.swift`, mirroring `postsUndoWithActivityID` exactly:

```swift
    @Test("POSTs a Remove activity to this site's own outbox")
    func postsRemove() async throws {
        let fake = FakeTransport()
        let target = try #require(URL(string: "https://lemmy.ml/u/spammer"))

        try await Self.client(fake).remove(target: target)

        let body = await fake.requestedBodies.first
        #expect(body?["type"] as? String == "Remove")
        #expect(body?["object"] as? String == "https://lemmy.ml/u/spammer")
        #expect(body?["actor"] as? String == "https://example.com/users/site")
        let headers = await fake.requestedHeaders.first
        #expect(headers?["Authorization"] == "Bearer secret-token")
    }

    @Test("remove maps a non-2xx status to requestFailed")
    func removeMapsNon2xx() async throws {
        let fake = FakeTransport(status: 403, body: "forbidden")
        let target = try #require(URL(string: "https://lemmy.ml/u/spammer"))
        await #expect(throws: CommunityMembershipError.requestFailed(status: 403, body: "forbidden")) {
            try await Self.client(fake).remove(target: target)
        }
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter CommunityMembershipClientTests`
Expected: build failure — `value of type 'CommunityMembershipClient' has no member 'remove'`.

- [ ] **Step 3: Implement**

In `Sources/AnglesiteCore/CommunityMembershipClient.swift`, add after `unfollow` (currently ending at line 86):

```swift
    /// Bans a member or un-announces a member post — one primitive, two moderation effects, per
    /// workers#473: the Worker's `Remove` handler treats `object` as either a member actor IRI
    /// (ban) or an announced post's IRI (un-announce), authorized by the owner's bearer
    /// `publishToken` alone — no `config.moderators` membership required, since the owner is
    /// implicitly the top moderator of their own actor. `target` is whichever IRI the caller
    /// wants removed; there's no separate "kind" parameter because the Worker itself dispatches
    /// on what `target` resolves to, not on anything this client declares up front.
    public func remove(target: URL) async throws {
        let body: [String: Any] = [
            "@context": "https://www.w3.org/ns/activitystreams",
            "type": "Remove",
            "actor": ownActorURL.absoluteString,
            "object": target.absoluteString,
        ]
        _ = try await post(body)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter CommunityMembershipClientTests`
Expected: PASS, including the four pre-existing tests in this file.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/CommunityMembershipClient.swift Tests/AnglesiteCoreTests/CommunityMembershipClientTests.swift
git commit -m "feat(#907): add CommunityMembershipClient.remove for ban/un-announce"
```

---

### Task 7: `MainPaneMode.moderation`, `presentModeration()`, `canOpenModeration`

**Files:**
- Modify: `Sources/AnglesiteApp/SiteWindowModel.swift:11-19` (`MainPaneMode` enum), add `presentModeration()` near `presentCommunities()` (lines 429-437), add `canOpenModeration` near the other `canOpenX` properties (lines 496-557)
- Test: none — `SiteWindowModel`'s existing `canOpenX`/`presentX` properties have no dedicated unit tests in the codebase (they're thin `@MainActor` view-model glue over `site`/settings state); Task 9's manual-verification step covers this behaviorally, matching how Communities/Followers are verified.

**Interfaces:**
- Consumes: `SiteSettings.communityActorURL` (existing).
- Produces: `SiteWindowModel.canOpenModeration: Bool`, `presentModeration()`, `MainPaneMode.moderation` — Task 8 wires a button to these; Task 9's `ModerationView` is what `.moderation` renders.

- [ ] **Step 1: Add the case**

In `Sources/AnglesiteApp/SiteWindowModel.swift`, extend `MainPaneMode` (currently lines 11-19):

```swift
enum MainPaneMode: Equatable {
    case preview
    case editor(FileRef)
    case graph
    case cleanup        // Site ▸ Cleanup… (#714 moved it out of the sidebar)
    case reader         // Website ▸ Reader… (V-4.3, #365)
    case followers      // Website ▸ Followers… (V-4.2, #364)
    case communities    // Website ▸ Communities… (V-5.1a, #368)
    case moderation     // Website ▸ Moderation… (V-5.1b/V-5.3, #907/#370)
}
```

- [ ] **Step 2: Add the presenter**

Immediately after `presentCommunities()` (currently lines 429-437):

```swift
    /// Switches the main pane to Moderation (Website ▸ Moderation…, V-5.1b/V-5.3 #907/#370).
    /// Mirrors `presentCommunities()`'s leave-current-surface-first guard. Unlike Communities,
    /// this is gated (`canOpenModeration`) — see that property's doc comment.
    func presentModeration() {
        Task {
            guard await leaveCurrentEditor(), await leaveCurrentInspector() else { return }
            activeEditor = nil
            await clearInspectorThenSwitchPane(to: .moderation)
        }
    }
```

- [ ] **Step 3: Cache `isHostedCommunity` and add the gate**

`SiteWindowModel` doesn't currently cache `SiteSettings` anywhere (confirmed: no `SiteSettings`/`SiteConfigStore` reference exists in `SiteWindowModel.swift` today) — every other `canOpenX` property gates on cheaper state (`site != nil`, etc.). `canOpenModeration` needs `SiteSettings.communityActorURL`, and `SiteConfigStore.load()` is `async`, while `SiteConfigStore.read(from:fileManager:)`'s doc comment explicitly warns it must not be called from a `@MainActor` context (blocking disk I/O). So this needs a cached field, refreshed asynchronously — not a synchronous read at gate-check time.

Add a stored property near `communities`/`followers` (`SiteWindowModel.swift:166` area):

```swift
    /// Cached `SiteSettings.communityActorURL != nil`, refreshed once per site open in
    /// `loadAndStart()` — the gate for Website ▸ Moderation… (#907/#370). A cached `Bool`
    /// rather than a live synchronous read: `SiteConfigStore.read(from:fileManager:)` is
    /// documented as unsafe to call from `@MainActor` (it blocks on disk I/O), and
    /// `canOpenModeration` must be synchronous for `.disabled(...)` to read. Known limitation:
    /// this doesn't live-update if a deploy completes while the window stays open — reopening
    /// the site picks up the new value. Acceptable for v1 (design doc §5); revisit only if it
    /// proves confusing in practice.
    private(set) var isHostedCommunity = false
```

In `loadAndStart(siteID:openSitesWindow:dismissSiteWindow:)`, immediately after `site = resolved` (currently `SiteWindowModel.swift:1965`), add:

```swift
        site = resolved
        isHostedCommunity = ((try? await SiteConfigStore(configDirectory: resolved.configDirectory).load())?.communityActorURL) != nil
```

Then add the gate alongside the other `canOpenX` computed properties (e.g. near `canOpenSocialPlan`/`canOpenDesignInterview`, currently around lines 536-551):

```swift
    /// Website ▸ Moderation… (#907/#370) is only meaningful once this site is a *deployed*
    /// hosted community — `communityActorURL` is set by `DeployCoordinator.persistProvisionedResources`
    /// after a successful deploy with a Group actor (Phase 2), not at creation time. Unlike
    /// Communities/Followers (always enabled once a site is focused), a personal site or an
    /// undeployed community never enables this — there's nothing to moderate yet.
    var canOpenModeration: Bool { isHostedCommunity }
```

- [ ] **Step 4: Build to verify it compiles**

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: **build failure** at this point, since `SiteWindow.swift`'s `mainPaneContent(for:)` switch (Task 8) isn't exhaustive yet — that's the correct "fails" signal confirming the new case is live. Proceed to Task 8 before trying to get a clean build.

- [ ] **Step 5: Commit** (after Task 8 makes the build succeed — see Task 8's own commit step; don't commit Task 7 in isolation, since it leaves the switch non-exhaustive)

---

### Task 8: "Moderation…" menu button + `SiteWindow` switch case

**Files:**
- Modify: `Sources/AnglesiteApp/WebsiteCommands.swift:65-70` (add the button after "Communities…")
- Modify: `Sources/AnglesiteApp/SiteWindow.swift:1032-1037` (add the `.moderation` case)

**Interfaces:**
- Consumes: `SiteWindowModel.canOpenModeration`/`presentModeration()` (Task 7), `ModerationView` (Task 9 — this task references it before it exists, so build won't succeed until Task 9 lands; that's expected, matching how Task 7→8 was sequenced).

- [ ] **Step 1: Add the button**

In `Sources/AnglesiteApp/WebsiteCommands.swift`, immediately after the existing "Communities…" button (currently lines 65-66... adjust to the button's actual current line number after Task 3 may have shifted nearby files — this file is untouched by Tasks 1-7, so lines 65-70 should still be accurate):

```swift
            Button("Communities…") { model?.presentCommunities() }
                .disabled(model == nil)

            Button("Moderation…") { model?.presentModeration() }
                .disabled(model?.canOpenModeration != true)
```

- [ ] **Step 2: Add the switch case**

In `Sources/AnglesiteApp/SiteWindow.swift`, extend `mainPaneContent(for:)`'s switch (currently lines 1032-1037):

```swift
        case .communities:
            CommunitiesView(communities: model.communities)
        case .moderation:
            ModerationView(moderation: model.moderation)
        case .preview:
            previewPane(for: site)
```

(The exact shape of what `model.moderation` is — a sub-model `SiteWindowModel` owns, mirroring `model.communities`/`model.followers` — is defined in Task 9, which creates it. This task's edit won't compile standalone; that's expected and gets resolved by Task 9.)

- [ ] **Step 3: Commit only after Task 9 lands and the build is clean** — fold this task's two edits into Task 9's commit rather than committing broken intermediate state (see Task 9's Step 6).

---

### Task 9: `ModerationView` — moderators, members, posts, reports

**Files:**
- Create: `Sources/AnglesiteApp/ModerationModel.swift` — mirrors `Sources/AnglesiteApp/CommunitiesModel.swift`'s exact shape: no-arg-defaulted `init`, a `configure(site: CurrentSite)` called once from `loadAndStart()`, injected `CommunityMembershipClient.Transport`, `secretStore` for the publish token, `DeployCoordinator.resolveSiteURL` + `ActivityPubActor.actorURL(siteURL:)` for `ownActorURL` — same four pieces `CommunitiesModel.configure(site:)`/`resolveSite()` already use (`CommunitiesModel.swift:106-135`).
- Create: `Sources/AnglesiteApp/ModerationView.swift`
- Modify: `Sources/AnglesiteApp/SiteWindowModel.swift` — add `var moderation = ModerationModel()` alongside `var communities = CommunitiesModel()` (line 166), and a `moderation.configure(site: currentSite)` call in `loadAndStart()` alongside wherever `communities.configure(site:)` is called (grep `grep -n "communities.configure" Sources/AnglesiteApp/SiteWindowModel.swift` to find that exact line and add the `moderation` call immediately after it).
- Test: Create `Tests/AnglesiteAppTests/ModerationModelTests.swift`, mirroring `Tests/AnglesiteAppTests/CommunitiesModelTests.swift`'s exact conventions (Swift Testing, `@testable import AnglesiteAppCore` — the app-layer sources under `Sources/AnglesiteApp` build as module `AnglesiteAppCore` for testing purposes, confirmed by that file's own import).

**Interfaces:**
- Consumes: `CommunityMembershipClient.remove(target:)` (Task 6), `CommunityMember`/`AnnouncedPost` (existing, both `Codable`), `SiteSettings.moderators` (existing), `CurrentSite` (existing — the same type `CommunitiesModel.configure(site:)` takes).
- Produces: `ModerationView(moderation: ModerationModel)` — the view Task 8's switch case renders.

- [ ] **Step 1: Write the failing test for the ban action**

Create `Tests/AnglesiteAppTests/ModerationModelTests.swift`, matching `CommunitiesModelTests.swift`'s exact conventions — Swift Testing, a locally-nested `InMemorySecretStore`, and the `(config, source)` directory-pair fixture:

```swift
// Tests/AnglesiteAppTests/ModerationModelTests.swift
import Testing
import Foundation
import AnglesiteCore
@testable import AnglesiteAppCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite("ModerationModel")
@MainActor
struct ModerationModelTests {
    final class InMemorySecretStore: SecretStore, @unchecked Sendable {
        var values: [String: String] = [:]
        func read(account: String) throws -> String? { values[account] }
        func write(_ value: String, account: String) throws { values[account] = value }
        func delete(account: String) throws { values.removeValue(forKey: account) }
    }

    private static func site(configDirectory: URL, sourceDirectory: URL) -> CurrentSite {
        CurrentSite(
            id: "site-1", name: "Test Community",
            packageURL: sourceDirectory.deletingLastPathComponent(),
            sourceDirectory: sourceDirectory, configDirectory: configDirectory)
    }

    /// Mirrors `CommunitiesModelTests.makeSiteDirectories(domain:)` — a fixture site with a
    /// public URL (so `DeployCoordinator.resolveSiteURL` resolves) and one member snapshot file.
    private static func makeSiteDirectories() throws -> (config: URL, source: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("moderation-model-test-\(UUID().uuidString)")
        let config = root.appendingPathComponent("Config")
        let source = root.appendingPathComponent("Source")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "DOMAIN=my-community.example\n".write(
            to: source.appendingPathComponent(".site-config"), atomically: true, encoding: .utf8)
        let member = try CommunityMember(
            id: "abc123", actorURL: URL(string: "https://lemmy.ml/u/spammer")!, name: "Spammer", photo: nil)
        let memberPath = source.appendingPathComponent(member.gitPath)
        try FileManager.default.createDirectory(at: memberPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(member).write(to: memberPath)
        return (config, source)
    }

    @Test("banning a member POSTs Remove and drops them from the visible list")
    func banRemovesMember() async throws {
        let (config, source) = try Self.makeSiteDirectories()
        defer { try? FileManager.default.removeItem(at: config.deletingLastPathComponent()) }
        let secretStore = InMemorySecretStore()
        secretStore.values[SecretAccounts.activityPubPublishToken(siteID: "site-1")] = "token"
        actor Recorder {
            private(set) var bodies: [[String: Any]] = []
            func record(_ body: [String: Any]) { bodies.append(body) }
        }
        let recorder = Recorder()

        let model = ModerationModel(secretStore: secretStore, membershipTransport: { request in
            if let data = request.httpBody, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                await recorder.record(json)
            }
            let http = HTTPURLResponse(url: request.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!
            return (Data("{}".utf8), http)
        })
        model.configure(site: Self.site(configDirectory: config, sourceDirectory: source))

        #expect(model.members.count == 1)
        try await model.ban(model.members[0])

        let body = await recorder.bodies.first
        #expect(body?["type"] as? String == "Remove")
        #expect(body?["object"] as? String == "https://lemmy.ml/u/spammer")
        #expect(model.members.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter ModerationModelTests`
Expected: build failure — `ModerationModel` doesn't exist.

- [ ] **Step 3: Implement `ModerationModel`**

```swift
import Foundation
import Observation
import AnglesiteCore

/// Backs the Moderation section (V-5.1b/V-5.3, #907/#370, design doc §5): moderator-list
/// display, and ban/remove actions over this site's own `CommunityMember`/`AnnouncedPost`
/// snapshot files. App glue only, mirroring `CommunitiesModel`'s shape — protocol logic
/// (`Remove`) lives in `AnglesiteCore`'s `CommunityMembershipClient`. Approval-queue and
/// report-review are explicitly out of scope (design doc D4/D5) — no state for either here.
@MainActor
@Observable
final class ModerationModel {
    private(set) var members: [CommunityMember] = []
    private(set) var posts: [AnnouncedPost] = []
    private(set) var moderators: [String] = []
    var errorMessage: String?
    /// Cleared by whichever confirmation-dialog button runs — same no-op-setter/
    /// clear-in-button-action contract `SiteWindow.swift:898-916`'s delete confirmation uses
    /// (#968/#969), and `CommunitiesModel.leaveConfirmation`'s sibling pattern.
    var banConfirmation: CommunityMember?
    var removeConfirmation: AnnouncedPost?

    private var siteID: String?
    private var sourceDirectory: URL?
    private var ownActorURL: URL?
    private let secretStore: any SecretStore
    private let membershipTransport: CommunityMembershipClient.Transport

    init(
        secretStore: any SecretStore = PlatformSecretStore.make(),
        membershipTransport: @escaping CommunityMembershipClient.Transport
            = CommunityMembershipClient.defaultTransport
    ) {
        self.secretStore = secretStore
        self.membershipTransport = membershipTransport
    }

    /// Records which site this pane talks to, resolves `ownActorURL`, and reads the moderator
    /// list plus every member/post snapshot from disk. No network I/O — mirrors
    /// `CommunitiesModel.configure(site:)`/`resolveSite()`'s split, collapsed into one method
    /// here since Moderation has no `.noSiteURL`-retry surface of its own (Website ▸
    /// Moderation… is disabled by `canOpenModeration` whenever there's no site URL yet, so this
    /// method only ever runs once that's already true).
    func configure(site: CurrentSite) {
        siteID = site.id
        sourceDirectory = site.sourceDirectory
        if let siteURLString = DeployCoordinator.resolveSiteURL(siteDirectory: site.sourceDirectory),
           let siteURL = URL(string: siteURLString) {
            ownActorURL = ActivityPubActor.actorURL(siteURL: siteURL)
        }
        let settings = (try? SiteConfigStore.read(from: site.configDirectory)) ?? SiteSettings()
        moderators = settings.moderators ?? []
        members = Self.decodeAll(CommunityMember.self, from: site.sourceDirectory.appendingPathComponent("data/community-members"))
        posts = Self.decodeAll(AnnouncedPost.self, from: site.sourceDirectory.appendingPathComponent("data/community-posts"))
    }

    /// Reads every `.json` file in `directory` and decodes it as `T`, skipping (not throwing on)
    /// any file that fails to decode — a malformed or in-progress-write snapshot must never make
    /// the whole Moderation pane unusable, matching `SiteConfigStore.load()`'s "a bad file falls
    /// back to a safe default" philosophy rather than propagating the failure.
    private static func decodeAll<T: Decodable>(_ type: T.Type, from directory: URL) -> [T] {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        return entries.filter { $0.pathExtension == "json" }.compactMap { url in
            (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
        }
    }

    private var publishToken: String? {
        guard let siteID else { return nil }
        return try? secretStore.read(account: SecretAccounts.activityPubPublishToken(siteID: siteID))
    }

    func ban(_ member: CommunityMember) async throws {
        guard let ownActorURL, let publishToken else {
            errorMessage = "This site has no known public URL yet — deploy it at least once first."
            return
        }
        let client = CommunityMembershipClient(ownActorURL: ownActorURL, publishToken: publishToken, transport: membershipTransport)
        try await client.remove(target: member.actorURL)
        members.removeAll { $0.id == member.id }
    }

    func confirmBan() async {
        guard let member = banConfirmation else { return }
        banConfirmation = nil
        do { try await ban(member) }
        catch { errorMessage = "Couldn't ban \(member.name ?? member.actorURL.absoluteString): \(error.localizedDescription)" }
    }

    func removePost(_ post: AnnouncedPost) async throws {
        guard let ownActorURL, let publishToken else {
            errorMessage = "This site has no known public URL yet — deploy it at least once first."
            return
        }
        let client = CommunityMembershipClient(ownActorURL: ownActorURL, publishToken: publishToken, transport: membershipTransport)
        try await client.remove(target: post.sourceURL)
        posts.removeAll { $0.id == post.id }
        // Deletes the local snapshot file too, mirroring the C.3 deletion flow
        // (docs/specs/2026-06-29-c3-received-interaction-canonicality.md's "owner deletes the
        // JSON file from their repo" convention) — the Worker's `Remove` above handles the
        // federation side (un-announce), this handles the git side, so the post disappears from
        // the rebuilt timeline on the next deploy without waiting for a full-set reconcile.
        if let sourceDirectory {
            try? FileManager.default.removeItem(at: sourceDirectory.appendingPathComponent(post.gitPath))
        }
    }

    func confirmRemove() async {
        guard let post = removeConfirmation else { return }
        removeConfirmation = nil
        do { try await removePost(post) }
        catch { errorMessage = "Couldn't remove this post: \(error.localizedDescription)" }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter ModerationModelTests`
Expected: PASS.

- [ ] **Step 5: Write `ModerationView`**

Following `CommunitiesView.swift`'s structural pattern (list-with-selection sidebar, `.confirmationDialog`/`.alert` for destructive actions per `SiteWindow.swift:898-916`'s convention):

```swift
import SwiftUI
import AnglesiteCore

/// The Moderation section (V-5.1b/V-5.3, #907/#370, design doc §5): moderators, members
/// (with ban), posts (with remove), and an inert reports placeholder (D5 — no report-handling
/// exists upstream yet).
struct ModerationView: View {
    @Bindable var moderation: ModerationModel

    var body: some View {
        List {
            Section("Moderators") {
                if moderation.moderators.isEmpty {
                    Text("Only you can moderate this community.").foregroundStyle(.secondary)
                } else {
                    ForEach(moderation.moderators, id: \.self) { Text($0) }
                }
            }
            Section("Members") {
                ForEach(moderation.members) { member in
                    HStack {
                        Text(member.name ?? member.actorURL.absoluteString)
                        Spacer()
                        Button("Ban", role: .destructive) { moderation.banConfirmation = member }
                    }
                }
            }
            Section("Posts") {
                ForEach(moderation.posts) { post in
                    HStack {
                        Text(post.content ?? post.sourceURL.absoluteString).lineLimit(1)
                        Spacer()
                        Button("Remove", role: .destructive) { moderation.removeConfirmation = post }
                    }
                }
            }
            Section("Reports") {
                Text("No report handling yet.").foregroundStyle(.secondary)
            }
        }
        .navigationSubtitle("Moderation")
        .alert("Error", isPresented: Binding(get: { moderation.errorMessage != nil }, set: { _ in moderation.errorMessage = nil })) {
            Button("OK") { moderation.errorMessage = nil }
        } message: {
            Text(moderation.errorMessage ?? "")
        }
        .confirmationDialog(
            "Ban this member?",
            isPresented: Binding(get: { moderation.banConfirmation != nil }, set: { _ in }),
            titleVisibility: .visible
        ) {
            Button("Ban", role: .destructive) { Task { await moderation.confirmBan() } }
            Button("Cancel", role: .cancel) { moderation.banConfirmation = nil }
        } message: {
            Text("This member's posts will stop appearing. Existing posts stay unless you also remove them.")
        }
        .confirmationDialog(
            "Remove this post?",
            isPresented: Binding(get: { moderation.removeConfirmation != nil }, set: { _ in }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) { Task { await moderation.confirmRemove() } }
            Button("Cancel", role: .cancel) { moderation.removeConfirmation = nil }
        } message: {
            Text("This removes the post from the community timeline. The author's own copy on their own site is unaffected.")
        }
    }
}
```

- [ ] **Step 6: Build, run the full suite, manually verify, then commit Tasks 7-9 together**

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: clean build (this is what finally makes Task 7/8's intermediate non-exhaustive-switch state compile).

Run: `swift test --package-path . --skip Domain`
Expected: PASS.

Manually verify: open a hosted community site created via Task 3's wizard and deployed via Phase 2 — `Website ▸ Moderation…` is enabled; on a personal site, it's disabled. Ban a member and confirm they disappear from the list; the confirmation dialog reads as designed (§5, D5's consequence-phrased copy).

```bash
git add Sources/AnglesiteApp/SiteWindowModel.swift Sources/AnglesiteApp/WebsiteCommands.swift Sources/AnglesiteApp/SiteWindow.swift Sources/AnglesiteApp/ModerationModel.swift Sources/AnglesiteApp/ModerationView.swift Tests/AnglesiteCoreTests/*.swift Tests/AnglesiteAppTests/*.swift
git commit -m "feat(#907,#370): add Moderation section with ban/remove"
```

**This completes Phase 3 — open a PR here, stacked on Phase 2's branch. Once merged, comment on #370 to scope it down to report-review + approval-queue (per the design doc §8), and on #907 to close it (Phase 1-3 close out every deferred item from PR #1258's commit message).**

---

## Self-review notes

- **Spec coverage:** §3 (Task 1-3), §4 (Task 4-5), §5 (Task 6-9), §6 (already filed as workers#487, no app-side task), §7 testing strategy (folded into each task's own test steps), §8 (closing comment noted at the end of Phase 3).
- **Task 7/8 sequencing gap:** flagged explicitly above — `MainPaneMode.moderation` (Task 7) leaves `SiteWindow.swift`'s switch non-exhaustive until Task 8 adds the case, and Task 8 in turn references `ModerationView`/`model.moderation` that don't exist until Task 9. This is a deliberate three-task chain with one build-clean point (end of Task 9), called out at each task's commit step so an executor doesn't mistake the intermediate non-building state for an error.
- **Placeholder scan:** the two soft spots from the first draft (`canOpenModeration`'s settings-access mechanism, and `ModerationModel`'s file-loading shape) were re-researched and replaced with concrete code — `SiteWindowModel.isHostedCommunity` cached in `loadAndStart()`, and `ModerationModel` mirroring `CommunitiesModel.configure(site:)`'s exact init/transport/secretStore pattern, including a real `decodeAll<T: Decodable>` directory reader. `removePost` deletes the local snapshot file directly (matching the C.3 "owner deletes the JSON file" convention) rather than routing through an undetermined committer call.
- **Known minor gap, stated rather than hidden:** `isHostedCommunity` refreshes only on site open (Task 7 Step 3), not live after a deploy completes mid-session — reopening the site picks up a newly-deployed community's Moderation button. Acceptable for v1 per the design doc's minimalism (D3); called out at the point it's introduced so it isn't mistaken for an oversight.
