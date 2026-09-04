# AppKit Shell Slice 2 (owned toolbar) Implementation Plan

**Issue:** #1699
**Status:** current

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `SiteWindow`'s SwiftUI-owned `.toolbar(id: "site")` + `.searchable` chrome with an
app-owned `NSToolbar` (delegate-driven, `NSHostingView`-backed items, `NSMenuToolbarItem` for
Insert, `NSSearchToolbarItem` for search) when the `#1699` AppKit shell flag is on, per Stage 3
slice 2 of `docs/superpowers/specs/2026-09-01-site-window-appkit-shell-design.md` §"Toolbar (slice
2)". Slice 1 (flag-gated split columns, PR #1713) already landed; this slice does **not** close
#1699 — slice 3 (flip + retire) does.

**Architecture:** All 21 `SiteToolbarItemID` items' SwiftUI content (Label/Button/Menu bodies,
already carrying their own `.help`/`.disabled`/`.accessibilityIdentifier`) is extracted verbatim
out of `SiteWindow`'s `.toolbar(id: "site")` closure into one `@ViewBuilder` switch,
`SiteWindow.toolbarItemContent(_:site:)`, called identically by the (unchanged-behavior) legacy
SwiftUI toolbar and by a new `SiteShellToolbarDelegate` (`NSToolbarDelegate`) that wraps each
item's view in an `NSHostingView`. The delegate, Insert's `NSMenuToolbarItem`, and a new
`SiteShellSearchToolbarItem` (`NSSearchToolbarItem` + suggestions menu over the same
`SiteSearchModel`) live in `Sources/AnglesiteApp/SiteShell/`, mirroring slice 1's layout.
`SiteShellSplitController` gains ownership of `NSWindow.toolbar` and two
`NSTrackingSeparatorToolbarItem`s. Everything is reached only when `SiteShellFlag.isEnabled`; flag
off is byte-for-byte the pre-slice-2 SwiftUI toolbar.

**Tech Stack:** Swift 6.4, SwiftUI + AppKit (`NSToolbar`, `NSToolbarItem`, `NSMenuToolbarItem`,
`NSSearchToolbarItem`, `NSTrackingSeparatorToolbarItem`), Swift Testing. No new dependencies.

## Global Constraints

- Apple frameworks only; no new dependencies.
- Doc comments per `docs/comment-style-guide.md`; CI fails on broken DocC links.
- Commit subjects conventional, ≤72 chars, scoped `feat(#1699)`/`test`/`docs` — **never** a
  closing type (`fix(#1699)` etc. would auto-close the tracking issue on merge per CONTRIBUTING
  "Multi-PR tracking issues"). Slice 3's PR closes #1699, not this one.
- `SiteToolbarItemID`'s raw values are frozen API (`SiteToolbarItemIDTests`) — this plan reads
  them, never renames or reorders the enum.
- No new user-visible strings (every item reuses its existing `Label`/`.help` text) → no String
  Catalog sync needed. If a step accidentally introduces new literal text, run the CONTRIBUTING
  sync recipe scoped to this worktree's own `BUILD_DIR`.
- Work in this worktree; container artifacts provisioned; use `scripts/build-app.sh`, never raw
  `xcodebuild`. Toggle the shell for manual runs with `ANGLESITE_APPKIT_SHELL=1` (env) or
  `UserDefaults.standard.set(true, forKey: AppSettings.Key.appKitShellEnabled)` (persists across
  launches — `defaults write io.dwk.Anglesite experimental.appKitShell -bool YES`, check the exact
  key against `AppSettings.Key.appKitShellEnabled`'s value before using `defaults write` directly).
- Design-doc rule that binds every task: toolbar items stay **unconditional** — no `if let`
  wrapping that swaps a control's identity; state-dependent items render `.disabled` instead (this
  is already true of the extracted content, since it's moved verbatim).
- Every task that changes `SiteWindow.swift` must leave the **flag-off path behaviorally
  identical** — verify with a flag-off smoke launch (`docs/testing-macos-app.md` §"Smoke-testing
  the built app") before commit, not just a compile check.
- Windowed/AX verification (design doc §Testing, "the authority") needs Accessibility permission
  granted to the host process (`docs/testing-macos-app.md` §"Accessibility identifiers (AX
  automation)") — if a task's gate step can't get that permission in this environment, say so
  explicitly in the task's completion note rather than silently skipping it.

---

### Task 1: Extract toolbar item content into `SiteWindow.toolbarItemContent(_:site:)`

Pure refactor, no behavior change. Moves the body of every `ToolbarItem` in
`.toolbar(id: "site") { ... }` (currently `Sources/AnglesiteApp/SiteWindow.swift:627-987`) into a
single `@ViewBuilder` function keyed by `SiteToolbarItemID`, so slice 2's AppKit path can call the
exact same views later. The legacy toolbar block is rewritten to call it; `ToolbarItem`'s own
wrapper (`id:`, `placement:`, `.defaultCustomization`, `.customizationBehavior`) stays where it is
since those apply to the `ToolbarItem`, not the content.

**Files:**
- Modify: `Sources/AnglesiteApp/SiteWindow.swift:627-987` (the `.toolbar(id: "site") { ... }` block)

**Interfaces:**
- Consumes: nothing new — same `model`, `bindableModel`, `site`, `newContentActions`,
  `showWYSIWYGPalette`, `toggleWebsiteInspector()`, `toggleSelectionInspector()` the block already
  captures from `SiteWindow`'s stored properties.
- Produces: `private func toolbarItemContent(_ id: SiteToolbarItemID, site: SiteStore.Site) -> some View`
  on `SiteWindow`. Task 6 passes `{ id in AnyView(toolbarItemContent(id, site: site)) }` into the
  shell as a closure — every later task that needs an item's view calls through that closure, not
  the switch directly.

- [ ] **Step 1: Add the extracted `toolbarItemContent` function**

Insert this new function directly above `private func siteUI(for site: SiteStore.Site) -> some View`
(`SiteWindow.swift:401`):

```swift
    /// The SwiftUI content for one toolbar item — everything inside its `ToolbarItem` closure
    /// (label, help, disabled state, accessibility id), extracted verbatim from the legacy
    /// `.toolbar(id: "site")` block (#1699 slice 2) so the AppKit shell's `NSHostingView`-backed
    /// items and the legacy SwiftUI toolbar render the exact same view. `ToolbarItem`'s own
    /// wrapper (id, placement, `.defaultCustomization`, `.customizationBehavior`) is NOT part of
    /// this function — those apply to the `ToolbarItem`/`NSToolbarItem`, not its content, and
    /// each caller (legacy toolbar, `SiteShellToolbarDelegate`) supplies its own.
    @ViewBuilder
    private func toolbarItemContent(_ id: SiteToolbarItemID, site: SiteStore.Site) -> some View {
        @Bindable var bindableModel = model
        switch id {
        case .insert:
            Menu {
                Button("New Page…") { newContentActions?.newPage() }
                Button("New Post…") { newContentActions?.newPost() }
                Button("New Collection Entry…") { newContentActions?.newCollection() }
                if let canvas = model.preview.wysiwygCanvas {
                    Section("Blocks") {
                        ForEach(canvas.blockPalette) { entry in
                            Button(entry.displayName) {
                                Task { await canvas.insertBlock(entry) }
                            }
                        }
                    }
                }
            } label: {
                Label("Insert", systemImage: "plus")
            }
            .help("Add a new page, post, collection entry, or block")
            .accessibilityIdentifier(AXID.toolbar(.insert))

        case .sync:
            SyncStatusView(model: model.sync)
                .accessibilityIdentifier(AXID.toolbar(.sync))

        case .securityReports:
            SecurityReportsBadgeView(
                model: model.securityReports,
                onRecheck: { model.recheckSecurityReports() },
                onViewAll: { model.openWebsiteSettings(landOn: .securityReports) }
            )
            .accessibilityIdentifier(AXID.toolbar(.securityReports))

        case .openInBrowser:
            Button {
                model.openPreviewInBrowser()
            } label: {
                Label("Open in Browser", systemImage: "arrow.up.forward.app")
            }
            .disabled(!model.canOpenPreviewInBrowser)
            .help("Open the live preview in your default browser")
            .accessibilityIdentifier(AXID.toolbar(.openInBrowser))

        case .graph:
            Button {
                Task { await model.showGraph() }
            } label: {
                Label("Site Graph", systemImage: "point.3.connected.trianglepath.dotted")
            }
            .help("Explore pages, layouts, components, collections, and assets")
            .accessibilityIdentifier(AXID.toolbar(.graph))

        case .backup:
            Button {
                model.backupSite()
            } label: {
                Label("Backup", systemImage: "externaldrive.fill.badge.icloud")
            }
            .disabled(!model.canRunBackup)
            .help(site.isValid
                  ? "Commit and push working-tree changes to your current branch"
                  : "Site is missing required files")
            .accessibilityIdentifier(AXID.toolbar(.backup))

        case .audit:
            Button {
                model.auditSite()
            } label: {
                if model.audit.isRunning {
                    Label("Auditing…", systemImage: "magnifyingglass")
                } else {
                    Label("Audit", systemImage: "checkmark.shield.fill")
                }
            }
            .disabled(!model.canRunAudit)
            .help(site.isValid && model.preview.canDeploy
                  ? "Run the structured accessibility audit against this site"
                  : site.isValid
                    ? "Open the preview first to start the runtime before auditing"
                    : "Site is missing required files")
            .accessibilityIdentifier(AXID.toolbar(.audit))

        case .harden:
            Button {
                model.harden.openSheet()
            } label: {
                if model.harden.isRunning {
                    Label("Hardening…", systemImage: "shield.lefthalf.filled")
                } else {
                    Label("Harden", systemImage: "shield.lefthalf.filled")
                }
            }
            .disabled(!model.canRunHarden)
            .help(site.isValid
                  ? "Preview and apply Cloudflare security hardening for this site"
                  : "Site is missing required files")
            .accessibilityIdentifier(AXID.toolbar(.harden))

        case .aiSearch:
            Button {
                model.aiSearch.openSheet()
            } label: {
                if model.aiSearch.isRunning {
                    Label("Setting Up AI Search…", systemImage: "text.magnifyingglass")
                } else {
                    Label("AI Search", systemImage: "text.magnifyingglass")
                }
            }
            .disabled(!model.canRunAISearch)
            .help(site.isValid
                  ? "Provision Cloudflare AI Search for this site"
                  : "Site is missing required files")
            .accessibilityIdentifier(AXID.toolbar(.aiSearch))

        case .domainConfigAudit:
            Button {
                model.domainConfigAudit.openSheet()
            } label: {
                if model.domainConfigAudit.isRunning {
                    Label("Checking Domain Config…", systemImage: "arrow.triangle.2.circlepath")
                } else {
                    Label("Domain Config", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            .disabled(!model.canRunDomainConfigAudit)
            .help(site.isValid
                  ? "Compare anglesite.json's declared domain/DNS/edge config against live Cloudflare state"
                  : "Site is missing required files")
            .accessibilityIdentifier(AXID.toolbar(.domainConfigAudit))

        case .agentReadiness:
            Button {
                model.agentReadiness.openSheet()
            } label: {
                if model.agentReadiness.isRunning {
                    Label("Checking Agent Readiness…", systemImage: "sparkle.magnifyingglass")
                } else {
                    Label("Agent Readiness", systemImage: "sparkle.magnifyingglass")
                }
            }
            .disabled(!model.canRunAgentReadiness)
            .help(site.isValid
                  ? "Check Cloudflare's Agent Readiness score for this site's published URL"
                  : "Site is missing required files")
            .accessibilityIdentifier(AXID.toolbar(.agentReadiness))

        case .onionRouting:
            Button {
                model.onionRouting.openSheet()
            } label: {
                Label("Onion Routing", systemImage: "network")
            }
            .disabled(!model.canRunOnionRouting)
            .help(site.isValid
                  ? "Enable Tor Browser access for this site via Cloudflare's zone-level setting"
                  : "Site is missing required files")
            .accessibilityIdentifier(AXID.toolbar(.onionRouting))

        case .domain:
            Button {
                model.domain.openSheet()
            } label: {
                Label("Domain", systemImage: "globe")
            }
            .disabled(!model.canOpenDomain)
            .help("View and manage this domain's DNS records")
            .accessibilityIdentifier(AXID.toolbar(.domain))

        case .integration:
            Button {
                model.openIntegrationWizard()
            } label: {
                Label("Add Integration…", systemImage: "puzzlepiece.extension")
            }
            .disabled(!model.canOpenIntegrationWizard)
            .help("Set up a third-party integration for this site")
            .accessibilityIdentifier(AXID.toolbar(.integration))

        case .siriReadiness:
            Button {
                model.openSiriReadiness()
            } label: {
                Label("Siri AI Readiness", systemImage: "sparkles")
            }
            .disabled(!model.canOpenSiriReadiness)
            .help("Check whether Siri workflows are ready for this site")
            .accessibilityIdentifier(AXID.toolbar(.siriReadiness))

        case .relatedPages:
            Button {
                model.relatedPagesPresented.toggle()
            } label: {
                Label("Related Pages", systemImage: model.relatedPagesPresented
                      ? "link.badge.plus" : "link")
            }
            .help(model.relatedPagesPresented ? "Hide related pages" : "Show related pages")
            .accessibilityIdentifier(AXID.toolbar(.relatedPages))

        case .styleGuide:
            Button {
                model.openStyleGuide()
            } label: {
                Label("Style Guide", systemImage: "textformat.abc")
            }
            .help("See and edit this site's learned writing, image, and naming conventions")
            .accessibilityIdentifier(AXID.toolbar(.styleGuide))

        case .github:
            if let remote = model.publish.existingRemote {
                Button {
                    NSWorkspace.shared.open(remote.url)
                } label: {
                    Label("View on GitHub", systemImage: "arrow.up.forward.square")
                }
                .help("Open this site's GitHub repository")
                .accessibilityIdentifier(AXID.toolbar(.github))
            } else {
                Button {
                    model.publish.publish(source: site.sourceDirectory, repoName: site.name)
                } label: {
                    Label("Publish to GitHub", systemImage: "square.and.arrow.up.on.square")
                }
                .disabled(!model.canPublishToGitHub)
                .help(site.isValid ? "Create a private GitHub repo and push this site" : "Site is missing required files")
                .accessibilityIdentifier(AXID.toolbar(.github))
            }

        case .deploy:
            HStack(spacing: 8) {
                HealthBadgeView(
                    model: model.health,
                    onRecheck: { model.recheckHealth() },
                    onAskAssistant: {
                        guard let chat = model.chat else { return }
                        model.chatPresented = true
                        chat.send(SiteWindowModel.healthAssistantPrompt)
                    }
                )
                Button {
                    model.deploySite()
                } label: {
                    Label("Publish Site", systemImage: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canRunDeploy)
                .help(site.isValid && model.preview.canDeploy
                      ? "Build, scan, and publish this site to Cloudflare"
                      : site.isValid
                        ? "Open the preview first to start the runtime before publishing"
                        : "Site is missing required files")
                .accessibilityIdentifier(AXID.toolbar(.deploy))
            }

        case .chat:
            Button {
                model.toggleChat()
            } label: {
                Label("Chat", systemImage: model.chatPresented
                    ? "bubble.left.and.bubble.right.fill"
                    : "bubble.left.and.bubble.right")
            }
            .help(model.chatPresented ? "Hide chat panel" : "Show chat panel")
            .accessibilityIdentifier(AXID.toolbar(.chat))

        case .wysiwygPalette:
            Button {
                showWYSIWYGPalette.toggle()
            } label: {
                Label("Block Palette", systemImage: "square.grid.2x2")
            }
            .disabled(!model.preview.isEditModeEnabled)
            .help("Show or hide the block palette")
            .accessibilityIdentifier(AXID.toolbar(.wysiwygPalette))

        case .websiteInspector:
            Button {
                toggleWebsiteInspector()
            } label: {
                Label("Website Inspector", systemImage: "globe")
            }
            .help("Show or hide the website inspector")
            .accessibilityIdentifier(AXID.toolbar(.websiteInspector))

        case .inspector:
            Button {
                toggleSelectionInspector()
            } label: {
                Label("Inspector", systemImage: "sidebar.right")
            }
            .disabled(model.inspectorSelection == nil)
            .help("Show or hide the inspector")
            .accessibilityIdentifier(AXID.toolbar(.inspector))
        }
    }
```

- [ ] **Step 2: Rewrite the legacy `.toolbar(id: "site")` block to call it**

Replace `SiteWindow.swift:627-987` (from `.toolbar(id: "site") {` through the matching closing
`}`) with:

```swift
        .toolbar(id: "site") {
            ToolbarItem(id: SiteToolbarItemID.insert.rawValue, placement: .primaryAction) {
                toolbarItemContent(.insert, site: site)
            }
            ToolbarItem(id: SiteToolbarItemID.sync.rawValue, placement: .primaryAction) {
                toolbarItemContent(.sync, site: site)
            }
            ToolbarItem(id: SiteToolbarItemID.securityReports.rawValue, placement: .primaryAction) {
                toolbarItemContent(.securityReports, site: site)
            }
            ToolbarItem(id: SiteToolbarItemID.openInBrowser.rawValue, placement: .primaryAction) {
                toolbarItemContent(.openInBrowser, site: site)
            }

            // — Palette-only items (View ▸ Customize Toolbar…) —

            ToolbarItem(id: SiteToolbarItemID.graph.rawValue, placement: .primaryAction) {
                toolbarItemContent(.graph, site: site)
            }
            .defaultCustomization(SiteToolbarItemID.graph.isDefaultVisible ? .visible : .hidden)

            ToolbarItem(id: SiteToolbarItemID.backup.rawValue, placement: .primaryAction) {
                toolbarItemContent(.backup, site: site)
            }
            .defaultCustomization(SiteToolbarItemID.backup.isDefaultVisible ? .visible : .hidden)

            ToolbarItem(id: SiteToolbarItemID.audit.rawValue, placement: .primaryAction) {
                toolbarItemContent(.audit, site: site)
            }
            .defaultCustomization(SiteToolbarItemID.audit.isDefaultVisible ? .visible : .hidden)

            ToolbarItem(id: SiteToolbarItemID.harden.rawValue, placement: .primaryAction) {
                toolbarItemContent(.harden, site: site)
            }
            .defaultCustomization(SiteToolbarItemID.harden.isDefaultVisible ? .visible : .hidden)

            ToolbarItem(id: SiteToolbarItemID.aiSearch.rawValue, placement: .primaryAction) {
                toolbarItemContent(.aiSearch, site: site)
            }
            .defaultCustomization(SiteToolbarItemID.aiSearch.isDefaultVisible ? .visible : .hidden)

            ToolbarItem(id: SiteToolbarItemID.domainConfigAudit.rawValue, placement: .primaryAction) {
                toolbarItemContent(.domainConfigAudit, site: site)
            }
            .defaultCustomization(SiteToolbarItemID.domainConfigAudit.isDefaultVisible ? .visible : .hidden)

            ToolbarItem(id: SiteToolbarItemID.agentReadiness.rawValue, placement: .primaryAction) {
                toolbarItemContent(.agentReadiness, site: site)
            }
            .defaultCustomization(SiteToolbarItemID.agentReadiness.isDefaultVisible ? .visible : .hidden)

            ToolbarItem(id: SiteToolbarItemID.onionRouting.rawValue, placement: .primaryAction) {
                toolbarItemContent(.onionRouting, site: site)
            }
            .defaultCustomization(SiteToolbarItemID.onionRouting.isDefaultVisible ? .visible : .hidden)

            ToolbarItem(id: SiteToolbarItemID.domain.rawValue, placement: .primaryAction) {
                toolbarItemContent(.domain, site: site)
            }
            .defaultCustomization(SiteToolbarItemID.domain.isDefaultVisible ? .visible : .hidden)

            ToolbarItem(id: SiteToolbarItemID.integration.rawValue, placement: .primaryAction) {
                toolbarItemContent(.integration, site: site)
            }
            .defaultCustomization(SiteToolbarItemID.integration.isDefaultVisible ? .visible : .hidden)

            ToolbarItem(id: SiteToolbarItemID.siriReadiness.rawValue, placement: .primaryAction) {
                toolbarItemContent(.siriReadiness, site: site)
            }
            .defaultCustomization(SiteToolbarItemID.siriReadiness.isDefaultVisible ? .visible : .hidden)

            ToolbarItem(id: SiteToolbarItemID.relatedPages.rawValue, placement: .primaryAction) {
                toolbarItemContent(.relatedPages, site: site)
            }
            .defaultCustomization(SiteToolbarItemID.relatedPages.isDefaultVisible ? .visible : .hidden)

            ToolbarItem(id: SiteToolbarItemID.styleGuide.rawValue, placement: .primaryAction) {
                toolbarItemContent(.styleGuide, site: site)
            }
            .defaultCustomization(SiteToolbarItemID.styleGuide.isDefaultVisible ? .visible : .hidden)

            ToolbarItem(id: SiteToolbarItemID.github.rawValue, placement: .primaryAction) {
                toolbarItemContent(.github, site: site)
            }
            .defaultCustomization(SiteToolbarItemID.github.isDefaultVisible ? .visible : .hidden)

            // — Default trailing cluster —

            ToolbarItem(id: SiteToolbarItemID.deploy.rawValue, placement: .primaryAction) {
                toolbarItemContent(.deploy, site: site)
            }
            .customizationBehavior(.reorderable)

            ToolbarItem(id: SiteToolbarItemID.chat.rawValue, placement: .primaryAction) {
                toolbarItemContent(.chat, site: site)
            }

            ToolbarItem(id: SiteToolbarItemID.wysiwygPalette.rawValue, placement: .primaryAction) {
                toolbarItemContent(.wysiwygPalette, site: site)
            }

            ToolbarItem(id: SiteToolbarItemID.websiteInspector.rawValue, placement: .primaryAction) {
                toolbarItemContent(.websiteInspector, site: site)
            }

            ToolbarItem(id: SiteToolbarItemID.inspector.rawValue, placement: .primaryAction) {
                toolbarItemContent(.inspector, site: site)
            }
        }
```

Every doc comment that was attached to an individual `ToolbarItem` above (ordering rationale,
"moved ahead of the two inspector toggles", etc.) stays as a comment on its new, shorter
`ToolbarItem` block — don't drop them, they explain placement decisions `toolbarItemContent`'s
switch case ordering no longer carries.

- [ ] **Step 3: Build and smoke-test flag OFF**

```bash
scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build
```

Launch per `docs/testing-macos-app.md` §"Smoke-testing the built app" **without** setting
`ANGLESITE_APPKIT_SHELL`. Open a site window: every toolbar item must render exactly as before
(same icons, same default-visible set, Customize Toolbar… palette has the same items). This is the
regression gate for this task — the switch statement must be a lossless transcription.

- [ ] **Step 4: Run the Swift test suite**

```bash
scripts/swift-test.sh
```

Expected: same pass count as `main` (no new tests yet; this task only guards against a compile
break or a `SiteToolbarItemIDTests` regression from a typo'd case).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/SiteWindow.swift
git commit -m "$(cat <<'EOF'
feat(#1699): extract toolbar item content into toolbarItemContent

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `SiteShellToolbarDelegate` skeleton — identifiers, default/allowed sets

**Files:**
- Create: `Sources/AnglesiteApp/SiteShell/SiteShellToolbarDelegate.swift`
- Test: `Tests/AnglesiteAppTests/SiteShellToolbarDelegateTests.swift`

**Interfaces:**
- Consumes: `SiteToolbarItemID` (`AnglesiteCore`, unchanged).
- Produces: `SiteShellToolbarDelegate.itemIdentifier(for: SiteToolbarItemID) -> NSToolbarItem.Identifier`,
  `SiteShellToolbarDelegate.toolbarIdentifier: NSToolbar.Identifier` (static, value
  `"site.shell"`), `SiteShellToolbarDelegate.defaultItemIdentifiers`/`allowedItemIdentifiers:
  [NSToolbarItem.Identifier]` (computed from `SiteToolbarItemID.allCases`), and the two tracking
  separator identifiers `sidebarTrackingSeparator`/`inspectorTrackingSeparator`. Task 3 adds
  `itemView`/`itemForItemIdentifier`; Task 4 wires this into `SiteShellSplitController`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteAppTests/SiteShellToolbarDelegateTests.swift`:

```swift
import Testing
import AnglesiteCore
@testable import Anglesite

@Suite("SiteShellToolbarDelegate")
struct SiteShellToolbarDelegateTests {
    @Test("toolbar identifier is a fresh key, distinct from the legacy SwiftUI one")
    func toolbarIdentifierIsFresh() {
        #expect(SiteShellToolbarDelegate.toolbarIdentifier.rawValue == "site.shell")
    }

    @Test("item identifier round-trips SiteToolbarItemID's raw value")
    func itemIdentifierRoundTrips() {
        for id in SiteToolbarItemID.allCases {
            #expect(
                SiteShellToolbarDelegate.itemIdentifier(for: id).rawValue == id.rawValue,
                "AXID.toolbar(_:) and saved-customization compatibility both key off the raw "
                    + "SiteToolbarItemID string — the shell must reuse it verbatim, not remap it.")
        }
    }

    @Test("default item identifiers match SiteToolbarItemID.isDefaultVisible, in enum order")
    func defaultItemIdentifiersMatchIsDefaultVisible() {
        let expected = SiteToolbarItemID.allCases
            .filter(\.isDefaultVisible)
            .map { SiteShellToolbarDelegate.itemIdentifier(for: $0) }
        #expect(SiteShellToolbarDelegate.defaultItemIdentifiers == expected)
    }

    @Test("allowed item identifiers cover every SiteToolbarItemID exactly once")
    func allowedItemIdentifiersCoverAllCases() {
        let allowed = SiteShellToolbarDelegate.allowedItemIdentifiers
        let expected = Set(SiteToolbarItemID.allCases.map { SiteShellToolbarDelegate.itemIdentifier(for: $0) })
        #expect(Set(allowed) == expected)
        #expect(allowed.count == expected.count, "no duplicate identifiers")
    }

    @Test("default set is a subset of the allowed set")
    func defaultIsSubsetOfAllowed() {
        let allowed = Set(SiteShellToolbarDelegate.allowedItemIdentifiers)
        for identifier in SiteShellToolbarDelegate.defaultItemIdentifiers {
            #expect(allowed.contains(identifier))
        }
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
scripts/swift-test.sh --filter SiteShellToolbarDelegateTests
```

Expected: FAIL to build — `SiteShellToolbarDelegate` doesn't exist yet.

- [ ] **Step 3: Write the delegate skeleton**

Create `Sources/AnglesiteApp/SiteShell/SiteShellToolbarDelegate.swift`:

```swift
import AppKit
import AnglesiteCore

/// The AppKit shell's owned `NSToolbar` delegate (#1699 Stage 3 slice 2, design doc
/// §"Toolbar (slice 2)"). Item identity is `SiteToolbarItemID`'s raw value, reused verbatim —
/// `AXID.toolbar(_:)` (`toolbar.<rawValue>`, `docs/testing-macos-app.md` §"Accessibility
/// identifiers") and every user's *default* customization both key off that string, so this
/// class must never remap it. The toolbar's own identifier is a fresh key, `"site.shell"` —
/// deliberately distinct from the legacy `"NSToolbar Configuration site"` blob SwiftUI wrote,
/// which embeds Beta-7-poisoned internal identifiers (#1704) this design abandons on purpose.
@MainActor
final class SiteShellToolbarDelegate: NSObject, NSToolbarDelegate {
    static let toolbarIdentifier = NSToolbar.Identifier("site.shell")

    static let sidebarTrackingSeparator = NSToolbarItem.Identifier("site.shell.sidebarSeparator")
    static let inspectorTrackingSeparator = NSToolbarItem.Identifier("site.shell.inspectorSeparator")

    static func itemIdentifier(for id: SiteToolbarItemID) -> NSToolbarItem.Identifier {
        NSToolbarItem.Identifier(id.rawValue)
    }

    static var defaultItemIdentifiers: [NSToolbarItem.Identifier] {
        SiteToolbarItemID.allCases.filter(\.isDefaultVisible).map(itemIdentifier(for:))
    }

    static var allowedItemIdentifiers: [NSToolbarItem.Identifier] {
        SiteToolbarItemID.allCases.map(itemIdentifier(for:))
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.defaultItemIdentifiers
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.allowedItemIdentifiers
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
scripts/swift-test.sh --filter SiteShellToolbarDelegateTests
```

Expected: PASS, all 5 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/SiteShell/SiteShellToolbarDelegate.swift Tests/AnglesiteAppTests/SiteShellToolbarDelegateTests.swift
git commit -m "$(cat <<'EOF'
feat(#1699): add SiteShellToolbarDelegate identifier skeleton

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Build real `NSToolbarItem`s — hosted SwiftUI content + Insert as `NSMenuToolbarItem`

**Files:**
- Modify: `Sources/AnglesiteApp/SiteShell/SiteShellToolbarDelegate.swift`
- Test: `Tests/AnglesiteAppTests/SiteShellToolbarDelegateTests.swift` (append)

**Interfaces:**
- Consumes: `SiteShellToolbarDelegate.itemIdentifier(for:)` (Task 2).
- Produces: `SiteShellToolbarDelegate.init(itemView: @escaping @MainActor (SiteToolbarItemID) -> AnyView, insertMenuItems: @escaping @MainActor () -> [NSMenuItem])`; conforms fully to
  `toolbar(_:itemForItemIdentifier:willBeInsertedIntoToolbar:)`. Task 4 constructs the delegate
  with these two closures (supplied from `SiteWindow.shellChrome`/`toolbarItemContent` in Task 6)
  and assigns it as `NSToolbar.delegate`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/AnglesiteAppTests/SiteShellToolbarDelegateTests.swift`, inside the `@Suite` type:

```swift
    @Test("non-insert items become a plain NSToolbarItem hosting the supplied view")
    func nonInsertItemsAreHostedViewItems() {
        let delegate = SiteShellToolbarDelegate(
            itemView: { _ in AnyView(Text("stub")) },
            insertMenuItems: { [] }
        )
        let toolbar = NSToolbar(identifier: SiteShellToolbarDelegate.toolbarIdentifier)
        let item = delegate.toolbar(
            toolbar,
            itemForItemIdentifier: SiteShellToolbarDelegate.itemIdentifier(for: .backup),
            willBeInsertedIntoToolbar: true)
        #expect(item?.itemIdentifier == SiteShellToolbarDelegate.itemIdentifier(for: .backup))
        #expect(item?.view is NSHostingView<AnyView>)
    }

    @Test("insert item is an NSMenuToolbarItem carrying the supplied menu items")
    func insertItemIsMenuToolbarItem() {
        let stubItem = NSMenuItem(title: "New Page…", action: nil, keyEquivalent: "")
        let delegate = SiteShellToolbarDelegate(
            itemView: { _ in AnyView(Text("stub")) },
            insertMenuItems: { [stubItem] }
        )
        let toolbar = NSToolbar(identifier: SiteShellToolbarDelegate.toolbarIdentifier)
        let item = delegate.toolbar(
            toolbar,
            itemForItemIdentifier: SiteShellToolbarDelegate.itemIdentifier(for: .insert),
            willBeInsertedIntoToolbar: true)
        let menuItem = try #require(item as? NSMenuToolbarItem)
        #expect(menuItem.menu.items.map(\.title) == ["New Page…"])
    }

    @Test("tracking separator identifiers return an NSTrackingSeparatorToolbarItem-free nil outside a split view")
    func unknownIdentifierReturnsNil() {
        let delegate = SiteShellToolbarDelegate(itemView: { _ in AnyView(EmptyView()) }, insertMenuItems: { [] })
        let toolbar = NSToolbar(identifier: SiteShellToolbarDelegate.toolbarIdentifier)
        let item = delegate.toolbar(
            toolbar,
            itemForItemIdentifier: NSToolbarItem.Identifier("not.a.real.item"),
            willBeInsertedIntoToolbar: true)
        #expect(item == nil)
    }
```

Add `import SwiftUI` to the test file's imports.

- [ ] **Step 2: Run the tests to verify they fail**

```bash
scripts/swift-test.sh --filter SiteShellToolbarDelegateTests
```

Expected: FAIL to build — no `init(itemView:insertMenuItems:)`, no `toolbar(_:itemForItemIdentifier:willBeInsertedIntoToolbar:)`.

- [ ] **Step 3: Implement item construction**

Replace the body of `SiteShellToolbarDelegate` in
`Sources/AnglesiteApp/SiteShell/SiteShellToolbarDelegate.swift` (keep the `static` members from
Task 2 as-is) by adding:

```swift
    /// Builds the SwiftUI content for a given item, matching `SiteWindow.toolbarItemContent`
    /// (Task 1) exactly — the shell and the legacy toolbar render the same view.
    private let itemView: @MainActor (SiteToolbarItemID) -> AnyView
    /// Rebuilt fresh on every menu open (Insert's Blocks section depends on live WYSIWYG canvas
    /// state) — see `menuNeedsUpdate(_:)` below.
    private let insertMenuItems: @MainActor () -> [NSMenuItem]

    init(
        itemView: @escaping @MainActor (SiteToolbarItemID) -> AnyView,
        insertMenuItems: @escaping @MainActor () -> [NSMenuItem]
    ) {
        self.itemView = itemView
        self.insertMenuItems = insertMenuItems
        super.init()
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let id = SiteToolbarItemID.allCases.first(where: { itemIdentifier(for: $0) == itemIdentifier }) else {
            return nil
        }

        if id == .insert {
            let menuItem = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
            menuItem.menu = NSMenu()
            menuItem.menu.delegate = self
            menuItem.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Insert")
            menuItem.label = "Insert"
            menuItem.toolTip = "Add a new page, post, collection entry, or block"
            menuItem.showsIndicator = true
            return menuItem
        }

        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        let hosting = NSHostingView(rootView: itemView(id))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        item.view = hosting
        return item
    }

    private static func itemIdentifier(for id: SiteToolbarItemID) -> NSToolbarItem.Identifier {
        Self.itemIdentifier(for: id)
    }
```

Then add `NSMenuDelegate` conformance so the Insert menu rebuilds on every open (the Blocks
section depends on live WYSIWYG state, which a static menu built once at toolbar-construction
time would miss):

```swift
extension SiteShellToolbarDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.items = insertMenuItems()
    }
}
```

Add `import SwiftUI` to the top of the file (needed for `AnyView`/`NSHostingView`).

- [ ] **Step 4: Run the tests to verify they pass**

```bash
scripts/swift-test.sh --filter SiteShellToolbarDelegateTests
```

Expected: PASS, all 8 tests (5 from Task 2 + 3 new).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/SiteShell/SiteShellToolbarDelegate.swift Tests/AnglesiteAppTests/SiteShellToolbarDelegateTests.swift
git commit -m "$(cat <<'EOF'
feat(#1699): build hosted NSToolbarItems + NSMenuToolbarItem Insert

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: `SiteShellSplitController` owns the window's `NSToolbar` + tracking separators

**Files:**
- Modify: `Sources/AnglesiteApp/SiteShell/SiteShellSplitController.swift`
- Test: `Tests/AnglesiteAppTests/SiteShellSplitControllerTests.swift` (existing file from slice 1 —
  append; if it doesn't exist under this exact name, `grep -rl "SiteShellSplitController" Tests/`
  to find slice 1's test file and append there instead)

**Interfaces:**
- Consumes: `SiteShellToolbarDelegate` (Task 3).
- Produces: `SiteShellSplitController.installToolbar(itemView:insertMenuItems:)` — called once
  the controller's view is in a window (`viewDidAppear`, guarded so it only runs once). Task 6
  calls nothing here directly; `SiteShellView.makeNSViewController` (Task 6) calls
  `installToolbar` right after construction.

- [ ] **Step 1: Write the failing test**

Append to the slice-1 split-controller test suite (or create
`Tests/AnglesiteAppTests/SiteShellSplitControllerTests.swift` if Task 4's grep found none — match
the `@Suite`/import shape of the file `SiteShellFlag`/`SiteShellState` tests already use):

```swift
    @Test("installToolbar builds a toolbar with the shell's identifier and delegate")
    @MainActor
    func installToolbarSetsIdentifierAndDelegate() {
        let controller = SiteShellSplitController(
            sidebar: Text("sidebar"), content: Text("content"), inspector: Text("inspector"))
        controller.installToolbar(itemView: { _ in AnyView(EmptyView()) }, insertMenuItems: { [] })
        let toolbar = try? #require(controller.ownedToolbar)
        #expect(toolbar?.identifier == SiteShellToolbarDelegate.toolbarIdentifier)
        #expect(toolbar?.allowsUserCustomization == true)
        #expect(toolbar?.autosavesConfiguration == true)
    }

    @Test("installToolbar is idempotent — calling it twice keeps one toolbar")
    @MainActor
    func installToolbarIsIdempotent() {
        let controller = SiteShellSplitController(
            sidebar: Text("sidebar"), content: Text("content"), inspector: Text("inspector"))
        controller.installToolbar(itemView: { _ in AnyView(EmptyView()) }, insertMenuItems: { [] })
        let first = controller.ownedToolbar
        controller.installToolbar(itemView: { _ in AnyView(EmptyView()) }, insertMenuItems: { [] })
        #expect(controller.ownedToolbar === first)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
scripts/swift-test.sh --filter SiteShellSplitControllerTests
```

Expected: FAIL to build — no `installToolbar`, no `ownedToolbar`.

- [ ] **Step 3: Implement toolbar ownership + tracking separators**

Add to `SiteShellSplitController` (`Sources/AnglesiteApp/SiteShell/SiteShellSplitController.swift`),
after the `private var appliedInitialLayout = false` property:

```swift
    private(set) var ownedToolbar: NSToolbar?
    private var toolbarDelegate: SiteShellToolbarDelegate?
```

And these methods, near `applyInitialLayoutIfNeeded()`:

```swift
    /// Builds and installs this window's owned `NSToolbar` (#1699 slice 2). Idempotent — a
    /// second call is a no-op, since `SiteShellView.makeNSViewController` runs once per window
    /// but `viewDidAppear` can fire more than once (e.g. window re-key).
    func installToolbar(
        itemView: @escaping @MainActor (SiteToolbarItemID) -> AnyView,
        insertMenuItems: @escaping @MainActor () -> [NSMenuItem]
    ) {
        guard ownedToolbar == nil else { return }
        let delegate = SiteShellToolbarDelegate(itemView: itemView, insertMenuItems: insertMenuItems)
        let toolbar = NSToolbar(identifier: SiteShellToolbarDelegate.toolbarIdentifier)
        toolbar.delegate = delegate
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        delegate.splitView = splitView
        toolbarDelegate = delegate
        ownedToolbar = toolbar
        view.window?.toolbar = toolbar
        installTrackingSeparators()
    }

    /// Inserts the two tracking-separator identifiers (design doc §"Toolbar (slice 2)": "a
    /// strict chrome upgrade over today"). The items themselves are constructed by
    /// `SiteShellToolbarDelegate.toolbar(_:itemForItemIdentifier:willBeInsertedIntoToolbar:)`
    /// when the toolbar asks for them — `NSToolbar` retains only the identifier once inserted,
    /// not the instance, so there is nothing to build here beyond the identifiers themselves.
    private func installTrackingSeparators() {
        guard let toolbar = ownedToolbar else { return }
        toolbar.insertItem(withItemIdentifier: SiteShellToolbarDelegate.sidebarTrackingSeparator, at: 1)
        toolbar.insertItem(
            withItemIdentifier: SiteShellToolbarDelegate.inspectorTrackingSeparator,
            at: toolbar.items.count - 1)
    }
```

Add a `weak var splitView: NSSplitView?` stored property to `SiteShellToolbarDelegate`
(`Sources/AnglesiteApp/SiteShell/SiteShellToolbarDelegate.swift`, Task 3) next to `itemView`, and
extend `toolbar(_:itemForItemIdentifier:willBeInsertedIntoToolbar:)`'s body with two more early
returns, right after the existing `if id == .insert` branch:

```swift
        if itemIdentifier == Self.sidebarTrackingSeparator, let splitView {
            return NSTrackingSeparatorToolbarItem(
                identifier: itemIdentifier, splitView: splitView, dividerIndex: 0)
        }
        if itemIdentifier == Self.inspectorTrackingSeparator, let splitView {
            return NSTrackingSeparatorToolbarItem(
                identifier: itemIdentifier, splitView: splitView, dividerIndex: 1)
        }
```

(these must come before the `guard let id = SiteToolbarItemID.allCases.first(where: ...)` line,
since neither tracking-separator identifier matches a `SiteToolbarItemID` case and that guard
would otherwise return `nil` for them first).

- [ ] **Step 4: Run the tests to verify they pass**

```bash
scripts/swift-test.sh --filter SiteShellSplitControllerTests
scripts/swift-test.sh --filter SiteShellToolbarDelegateTests
```

Expected: PASS. Re-run the delegate suite too since this step touched
`toolbar(_:itemForItemIdentifier:willBeInsertedIntoToolbar:)`.

- [ ] **Step 5: Build**

```bash
scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build
```

Expected: succeeds (nothing calls `installToolbar` yet outside tests — Task 6 wires that — so
this is a compile-only gate).

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteApp/SiteShell/SiteShellSplitController.swift Sources/AnglesiteApp/SiteShell/SiteShellToolbarDelegate.swift Tests/AnglesiteAppTests/
git commit -m "$(cat <<'EOF'
feat(#1699): shell owns NSToolbar + tracking separators

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: `SiteShellSearchToolbarItem` — `NSSearchToolbarItem` + suggestions over `SiteSearchModel`

**Files:**
- Create: `Sources/AnglesiteApp/SiteShell/SiteShellSearchToolbarItem.swift`
- Test: `Tests/AnglesiteAppTests/SiteShellSearchToolbarItemTests.swift`

**Interfaces:**
- Consumes: `SiteSearchModel` (`Sources/AnglesiteApp/SiteSearchModel.swift`, unchanged — `query`,
  `scope`, `hits`, `hasQuery`, `isSearching`, `submit()`, `clear()`), `SiteSearchScope`
  (`AnglesiteCore`, unchanged).
- Produces: `SiteShellSearchToolbarItem.suggestionMenuItems(for hits: [SiteSearchIndex.Hit], onSelect: @escaping (SiteSearchIndex.Hit) -> Void) -> [NSMenuItem]`
  (pure, testable without a window) and the class itself, `NSSearchToolbarItem` subclass wired to
  a `SiteSearchModel`. Task 6 constructs one and passes its `itemIdentifier` into the toolbar's
  default set.

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteAppTests/SiteShellSearchToolbarItemTests.swift`:

```swift
import Testing
import AppKit
import AnglesiteCore
@testable import Anglesite

@Suite("SiteShellSearchToolbarItem")
struct SiteShellSearchToolbarItemTests {
    private func hit(path: String, title: String?) -> SiteSearchIndex.Hit {
        SiteSearchIndex.Hit(
            id: path, path: path, title: title, route: nil, matchContext: "",
            kind: .page)
    }

    @Test("empty hits produce no menu items")
    func emptyHitsProduceNoItems() {
        let items = SiteShellSearchToolbarItem.suggestionMenuItems(for: [], onSelect: { _ in })
        #expect(items.isEmpty)
    }

    @Test("each hit becomes one menu item titled by its display title")
    func hitsBecomeTitledMenuItems() {
        let hits = [hit(path: "src/pages/about.astro", title: "About"), hit(path: "src/pages/contact.astro", title: nil)]
        let items = SiteShellSearchToolbarItem.suggestionMenuItems(for: hits, onSelect: { _ in })
        #expect(items.map(\.title) == ["About", "contact.astro"])
    }

    @Test("selecting a menu item invokes onSelect with its hit")
    @MainActor
    func selectingItemInvokesOnSelect() {
        let target = hit(path: "src/pages/about.astro", title: "About")
        var selected: SiteSearchIndex.Hit?
        let items = SiteShellSearchToolbarItem.suggestionMenuItems(
            for: [target], onSelect: { selected = $0 })
        let item = try! #require(items.first)
        _ = item.target?.perform(item.action, with: item)
        #expect(selected?.path == target.path)
    }
}
```

If `SiteSearchIndex.Hit`'s initializer differs from the guess above, read its actual definition
(`grep -n "struct Hit" Sources/AnglesiteCore/SiteSearchIndex.swift`) before writing this step —
match its real parameter list and `kind` type exactly; the shape here is illustrative of what the
test needs, not a verified signature.

- [ ] **Step 2: Run the tests to verify they fail**

```bash
scripts/swift-test.sh --filter SiteShellSearchToolbarItemTests
```

Expected: FAIL to build — `SiteShellSearchToolbarItem` doesn't exist.

- [ ] **Step 3: Implement**

Create `Sources/AnglesiteApp/SiteShell/SiteShellSearchToolbarItem.swift`:

```swift
import AppKit
import AnglesiteCore

/// The AppKit shell's owned search field (#1699 Stage 3 slice 2, design doc §"Toolbar (slice
/// 2)"): an `NSSearchToolbarItem` over the same `SiteSearchModel` the legacy `.searchable`
/// modifier drives, with a suggestions `NSMenu` standing in for `.searchSuggestions`'s popover
/// list. Scope switching (`SiteSearchScope`) is exposed via the search field's own
/// `searchMenuTemplate`, matching the platform convention for a scope-bar-less search field.
@MainActor
final class SiteShellSearchToolbarItem: NSSearchToolbarItem {
    static let identifier = NSToolbarItem.Identifier("site.shell.search")

    private let model: SiteSearchModel
    private let activate: (SiteSearchIndex.Hit) -> Void
    private var searchFieldDelegateBox: SearchFieldDelegateBox?

    init(model: SiteSearchModel, activate: @escaping (SiteSearchIndex.Hit) -> Void) {
        self.model = model
        self.activate = activate
        super.init(itemIdentifier: Self.identifier)
        toolTip = "Search Site"
        searchField.placeholderString = "Search Site"
        searchField.searchMenuTemplate = Self.scopeMenuTemplate()
        let box = SearchFieldDelegateBox(owner: self)
        searchFieldDelegateBox = box
        searchField.delegate = box
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SiteShellSearchToolbarItem is code-constructed only")
    }

    /// Builds the menu items for a set of search hits — pure and testable without a window.
    /// Mirrors `SiteSearchSuggestionRow`'s title logic (`SiteSearchField.swift`): the front-matter
    /// title when there is one, else the filename.
    static func suggestionMenuItems(
        for hits: [SiteSearchIndex.Hit], onSelect: @escaping (SiteSearchIndex.Hit) -> Void
    ) -> [NSMenuItem] {
        hits.map { hit in
            let title = hit.title?.isEmpty == false ? hit.title! : (hit.path as NSString).lastPathComponent
            let item = SelectableMenuItem(title: title, hit: hit, onSelect: onSelect)
            item.target = item
            item.action = #selector(SelectableMenuItem.select)
            return item
        }
    }

    /// One `NSMenuItem` per `SiteSearchScope`, checked state mirrors `model.scope`. Rebuilt once
    /// at init — scope cases are static, unlike the suggestions menu.
    private static func scopeMenuTemplate() -> NSMenu {
        let menu = NSMenu()
        for scope in SiteSearchScope.allCases {
            menu.addItem(NSMenuItem(title: String(describing: scope), action: nil, keyEquivalent: ""))
        }
        return menu
    }

    /// Shows the suggestions menu for the model's current `hits`, positioned under the search
    /// field — called by the delegate box on every text change once results land.
    fileprivate func presentSuggestions() {
        guard !model.hits.isEmpty else { return }
        let menu = NSMenu()
        menu.items = Self.suggestionMenuItems(for: model.hits, onSelect: activate)
        let origin = NSPoint(x: 0, y: searchField.bounds.minY)
        menu.popUp(positioning: nil, at: origin, in: searchField)
    }

    fileprivate func submit() {
        if let hit = model.submit() { activate(hit) }
    }

    /// One `NSMenuItem` subclass per hit rather than an associated-object lookup — keeps
    /// `onSelect` type-safe and avoids `objc_setAssociatedObject`.
    private final class SelectableMenuItem: NSMenuItem {
        let hit: SiteSearchIndex.Hit
        private let onSelect: (SiteSearchIndex.Hit) -> Void

        init(title: String, hit: SiteSearchIndex.Hit, onSelect: @escaping (SiteSearchIndex.Hit) -> Void) {
            self.hit = hit
            self.onSelect = onSelect
            super.init(title: title, action: nil, keyEquivalent: "")
        }

        @available(*, unavailable)
        required init(coder: NSCoder) { fatalError() }

        @objc func select() { onSelect(hit) }
    }

    /// `NSSearchField`'s delegate must be an `NSObject`; this box exists only so
    /// `SiteShellSearchToolbarItem` itself (an `NSToolbarItem` subclass, not an `NSResponder`)
    /// doesn't have to conform directly.
    private final class SearchFieldDelegateBox: NSObject, NSSearchFieldDelegate {
        weak var owner: SiteShellSearchToolbarItem?
        init(owner: SiteShellSearchToolbarItem) { self.owner = owner }

        func controlTextDidChange(_ obligation: Notification) {
            owner?.presentSuggestions()
        }

        func control(
            _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
        ) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            owner?.submit()
            return true
        }
    }
}
```

Bind `model.query` to `searchField.stringValue` and back — add to `init`, right before setting
`searchField.delegate`:

```swift
        searchField.stringValue = model.query
```

and, inside `controlTextDidChange`, before calling `presentSuggestions()`:

```swift
        func controlTextDidChange(_ obligation: Notification) {
            guard let field = obligation.object as? NSSearchField else { return }
            owner?.model.query = field.stringValue
            owner?.presentSuggestions()
        }
```

(edit the method in place rather than appending a duplicate).

- [ ] **Step 4: Run the tests to verify they pass**

```bash
scripts/swift-test.sh --filter SiteShellSearchToolbarItemTests
```

Expected: PASS, all 3 tests. If `SiteSearchIndex.Hit`'s real initializer differs from Step 1's
guess, fix the test call sites now that the real type is in scope — don't change
`SiteSearchIndex.Hit` itself.

- [ ] **Step 5: Build**

```bash
scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build
```

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteApp/SiteShell/SiteShellSearchToolbarItem.swift Tests/AnglesiteAppTests/SiteShellSearchToolbarItemTests.swift
git commit -m "$(cat <<'EOF'
feat(#1699): add SiteShellSearchToolbarItem (NSSearchToolbarItem)

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Cut over `SiteWindow` — flag-on path skips the SwiftUI toolbar/search, wires the shell's

**Files:**
- Modify: `Sources/AnglesiteApp/SiteWindow.swift`
- Modify: `Sources/AnglesiteApp/SiteShell/SiteShellView.swift`
- Modify: `Sources/AnglesiteApp/SiteShell/SiteShellSplitController.swift`

**Interfaces:**
- Consumes: `toolbarItemContent` (Task 1), `SiteShellSplitController.installToolbar` (Task 4),
  `SiteShellSearchToolbarItem` (Task 5).
- Produces: nothing further downstream — this is the integration task.

- [ ] **Step 1: Let `SiteShellView` pass toolbar wiring through to the controller**

In `Sources/AnglesiteApp/SiteShell/SiteShellView.swift`, add two more `let` properties next to
`sidebar`/`content`/`inspector`:

```swift
    let itemView: @MainActor (SiteToolbarItemID) -> AnyView
    let insertMenuItems: @MainActor () -> [NSMenuItem]
    let searchItem: SiteShellSearchToolbarItem
```

Add them to the `init` parameter list (after `inspector`) and the matching `_property = property`
assignments (they're plain `let`s, not `@ViewBuilder`, so no special init syntax beyond adding the
parameters). In `makeNSViewController`, right after `let controller = SiteShellSplitController(...)`,
add:

```swift
        controller.installToolbar(itemView: itemView, insertMenuItems: insertMenuItems, searchItem: searchItem)
```

Update `SiteShellSplitController.installToolbar`'s signature (`Sources/AnglesiteApp/SiteShell/SiteShellSplitController.swift`,
Task 4) to accept and insert the search item:

```swift
    func installToolbar(
        itemView: @escaping @MainActor (SiteToolbarItemID) -> AnyView,
        insertMenuItems: @escaping @MainActor () -> [NSMenuItem],
        searchItem: SiteShellSearchToolbarItem
    ) {
        guard ownedToolbar == nil else { return }
        let delegate = SiteShellToolbarDelegate(itemView: itemView, insertMenuItems: insertMenuItems)
        delegate.splitView = splitView
        let toolbar = NSToolbar(identifier: SiteShellToolbarDelegate.toolbarIdentifier)
        toolbar.delegate = delegate
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        toolbarDelegate = delegate
        ownedToolbar = toolbar
        view.window?.toolbar = toolbar
        toolbar.insertItem(withItemIdentifier: searchItem.itemIdentifier, at: toolbar.items.count)
        installTrackingSeparators()
    }
```

`SiteShellToolbarDelegate` must hand the search item back by identity when asked for it — add,
inside `toolbar(_:itemForItemIdentifier:willBeInsertedIntoToolbar:)` (Task 3/4), a third stored
property `weak var searchItem: SiteShellSearchToolbarItem?` set alongside `splitView` in
`installToolbar`, and one more early-return branch:

```swift
        if itemIdentifier == SiteShellSearchToolbarItem.identifier {
            return searchItem
        }
```

- [ ] **Step 2: Call `installToolbar`'s new signature from tests**

Update the two `installToolbar(...)` calls added in Task 4's tests
(`Tests/AnglesiteAppTests/SiteShellSplitControllerTests.swift`) to pass a stub
`SiteShellSearchToolbarItem`:

```swift
        let searchModel = SiteSearchModel(index: SiteKnowledgeIndex())
        let searchItem = SiteShellSearchToolbarItem(model: searchModel, activate: { _ in })
```

(pass `searchItem:` as the third argument in both calls). If `SiteKnowledgeIndex()`'s real
initializer takes required arguments, `grep -n "init(" Sources/AnglesiteApp/SiteKnowledgeIndex.swift`
(or wherever it lives) and use whatever stub construction the existing `SiteSearchModel`-consuming
tests already use — don't invent a fake initializer.

- [ ] **Step 3a: `windowModifiers` skips `.toolbar`/`.searchable` when the shell owns them**

In `Sources/AnglesiteApp/SiteWindow.swift`, the function that wraps `.toolbar(id: "site") { ... }`
(Task 1) and `.modifier(SiteSearchFieldModifier(...))` needs those two modifiers applied only when
`!SiteShellFlag.isEnabled` — when the flag is on, `SiteShellSplitController` (Task 4) owns the
window's toolbar instead, and a second, SwiftUI-owned one would either be silently dropped or
fight it for `window.toolbar`. Follow the exact idiom `siteUI(for:)` already uses one function up
(`SiteWindow.swift:434-441`, `Group { if SiteShellFlag.isEnabled { shellChrome(...) } else {
legacyChrome(...) } }`) rather than introducing a new type: wrap the segment in a `Group`, branch
on the same flag, and put the toolbar/search modifiers only on the `else` branch's copy of
`chrome`:

```swift
        Group {
            if SiteShellFlag.isEnabled {
                chrome
            } else {
                chrome
                    .toolbar(id: "site") {
                        // Task 1 Step 2's ToolbarItem block, unchanged — still calls
                        // toolbarItemContent(_:site:), which stays a SiteWindow method.
                    }
                    .modifier(SiteSearchFieldModifier(
                        model: model.search,
                        siteID: site.id,
                        inspectorPresented: inspectorPresented,
                        activate: { hit in model.openSearchHit(hit) }
                    ))
            }
        }
        .navigationTitle(model.preview.editingPageTitle ?? site.name)
        // ... every modifier from `.navigationTitle` onward (title, subtitle, document,
        // toolbarRole, sheets, alerts) stays exactly as-is, unconditional, attached after the
        // `Group` — none of it is toolbar/search machinery, so none of it needs the flag check.
```

`toolbarItemContent` stays a plain method on `SiteWindow` (Task 1) — this branch doesn't move it
or change its signature, so nothing here re-threads `model`/`inspectorPresented`/`newContentActions`
through a new type.

- [ ] **Step 3b: Add the `NSObject` shim for the shell's Insert menu**

The shell's Insert menu (Task 3's `NSMenuToolbarItem`) needs `NSMenuItem` targets, and
`NSMenuItem.target` must be an `NSObject` — `SiteWindow` is a `struct View` and can't be one. Add
a small dedicated shim just above `toolbarItemContent` (Task 1) in `SiteWindow.swift`:

```swift
    /// `NSMenuItem.target` for the shell's Insert menu (#1699 slice 2) — exists only because
    /// `SiteWindow` (a `struct View`) can't itself be an `NSMenuItem` target. Closures are
    /// re-pointed on every `body` evaluation (`shellChrome`, below) rather than the instance
    /// being recreated, so a menu that's open across a re-render keeps working.
    @MainActor
    private final class ShellInsertMenuActions: NSObject {
        var onNewPage: () -> Void = {}
        var onNewPost: () -> Void = {}
        var onNewCollection: () -> Void = {}
        var onInsertBlock: (WYSIWYGBlockPaletteEntry) -> Void = { _ in }

        @objc func newPage() { onNewPage() }
        @objc func newPost() { onNewPost() }
        @objc func newCollection() { onNewCollection() }
        @objc func insertBlock(_ sender: NSMenuItem) {
            guard let entry = sender.representedObject as? WYSIWYGBlockPaletteEntry else { return }
            onInsertBlock(entry)
        }
    }
```

Store one instance on `SiteWindow` next to `showWYSIWYGPalette` (`SiteWindow.swift:30`):

```swift
    @State private var shellInsertActions = ShellInsertMenuActions()
```

- [ ] **Step 3c: Wire `shellChrome` to pass toolbar items, Insert menu, and search into the shell**

Rewrite `shellChrome(for:inspectorPresented:)` (`SiteWindow.swift:501-512`):

```swift
    private func shellChrome(for site: SiteStore.Site, inspectorPresented: Binding<Bool>) -> some View {
        shellInsertActions.onNewPage = { newContentActions?.newPage() }
        shellInsertActions.onNewPost = { newContentActions?.newPost() }
        shellInsertActions.onNewCollection = { newContentActions?.newCollection() }
        shellInsertActions.onInsertBlock = { entry in
            guard let canvas = model.preview.wysiwygCanvas else { return }
            Task { await canvas.insertBlock(entry) }
        }
        if shellSearchItem == nil {
            shellSearchItem = SiteShellSearchToolbarItem(
                model: model.search,
                activate: { hit in model.openSearchHit(hit) })
        }

        return SiteShellView(
            sidebarVisible: $sidebarVisible,
            inspectorPresented: inspectorPresented,
            itemView: { [self] id in AnyView(self.toolbarItemContent(id, site: site)) },
            insertMenuItems: { [shellInsertActions] in
                let actions = shellInsertActions
                let newPage = NSMenuItem(title: "New Page…", action: #selector(ShellInsertMenuActions.newPage), keyEquivalent: "")
                let newPost = NSMenuItem(title: "New Post…", action: #selector(ShellInsertMenuActions.newPost), keyEquivalent: "")
                let newCollection = NSMenuItem(title: "New Collection Entry…", action: #selector(ShellInsertMenuActions.newCollection), keyEquivalent: "")
                for item in [newPage, newPost, newCollection] { item.target = actions }
                var items = [newPage, newPost, newCollection]
                if let canvas = model.preview.wysiwygCanvas, !canvas.blockPalette.isEmpty {
                    let header = NSMenuItem(title: "Blocks", action: nil, keyEquivalent: "")
                    header.isEnabled = false
                    items.append(header)
                    for entry in canvas.blockPalette {
                        let blockItem = NSMenuItem(
                            title: entry.displayName,
                            action: #selector(ShellInsertMenuActions.insertBlock(_:)),
                            keyEquivalent: "")
                        blockItem.target = actions
                        blockItem.representedObject = entry
                        items.append(blockItem)
                    }
                }
                return items
            },
            searchItem: shellSearchItem!
        ) {
            sidebarColumn(for: site)
        } content: {
            detailColumn(for: site)
        } inspector: {
            inspectorContent
        }
    }
```

Add the lazily-created search item storage next to `shellInsertActions`, following the exact
pattern `newContentActions` already uses for lazy per-window construction
(`SiteWindow.swift:239-243`):

```swift
    @State private var shellSearchItem: SiteShellSearchToolbarItem?
```

Constructing exactly one `SiteShellSearchToolbarItem` per window (not per `body` evaluation)
matters: SwiftUI re-evaluates `body` often, and a fresh `NSSearchToolbarItem` on every call would
drop the field's current text and first-responder state.

- [ ] **Step 4: Build**

```bash
scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build
```

Fix whatever the type checker flags — this step is where (a)/(b)'s exact shape gets locked in by
what actually compiles.

- [ ] **Step 5: Smoke-test BOTH flag states**

Flag off (`docs/testing-macos-app.md` §"Smoke-testing the built app", no env var): toolbar and
search must look and behave exactly as before Task 1.

Flag on (`ANGLESITE_APPKIT_SHELL=1 open "$APP"` or launch the binary directly with the env var
set): toolbar items render (icons visible, default set matches `SiteToolbarItemID.isDefaultVisible`),
clicking Backup/Audit/etc. fires the same actions as before, Insert shows a native menu with New
Page…/New Post…/New Collection Entry…, the search field appears and accepts typed text, and the
window doesn't crash on open (the #1696 regression this whole epic exists to fix).

- [ ] **Step 6: Run the full test suite**

```bash
scripts/swift-test.sh
```

Expected: same pass count as before this task, plus the tests Tasks 2/3/4/5 already added,
0 failures.

- [ ] **Step 7: Commit**

```bash
git add Sources/AnglesiteApp/SiteWindow.swift Sources/AnglesiteApp/SiteShell/
git commit -m "$(cat <<'EOF'
feat(#1699): cut the shell over to its own toolbar + search

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Slice 2 exit gate — windowed AX verification + toolbar customization round-trip

Matches the design doc's slice-2 exit criteria verbatim (§"Rollout: flag-gated slices", item 2):
"toolbar customization round-trips (palette, reorder, remove, restore-default), AX ids verified
via the `AXIdentifier` probe, tracking separators behave, ⇧⌘F focuses search." This task is manual
verification, not new code — it's the reviewer's gate before this slice's PR, the same role
slice 1's plan gave its own final gate step.

**Files:** none (verification only).

- [ ] **Step 1: Build and launch with the shell flag on**

```bash
scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build
APP="$(xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR =/{print $3}')/Anglesite.app"
ANGLESITE_APPKIT_SHELL=1 "$APP/Contents/MacOS/Anglesite" &
```

- [ ] **Step 2: Toolbar customization round-trip**

View ▸ Customize Toolbar…: drag an item from the palette into the bar, drag one out, reorder two,
click Restore Default. Quit and relaunch (still with the env var set) — the customization must
persist (it's `autosavesConfiguration`-backed, keyed by `"site.shell"`).

- [ ] **Step 3: AX identifier probe**

With Accessibility permission granted to the host process (`docs/testing-macos-app.md`
§"Accessibility identifiers"):

```bash
osascript -e 'tell application "System Events" to tell process "Anglesite" to get value of attribute "AXIdentifier" of buttons of toolbar 1 of window 1'
```

Expected: the same `toolbar.<SiteToolbarItemID>` strings the legacy chrome exposes (e.g.
`toolbar.deploy`, `toolbar.chat`) — `AXIDTests` already freezes the format, this step confirms the
live shell toolbar actually surfaces it (an `NSToolbarItem.view`'s `accessibilityIdentifier` isn't
automatically the same as a SwiftUI view's `.accessibilityIdentifier` modifier — if this step finds
it missing, set `hosting.view.setAccessibilityIdentifier(...)` explicitly in Task 3's
`itemForItemIdentifier`, reading it off the identifier passed in, and re-run this step).

If Accessibility permission isn't available in this environment, say so explicitly here rather than
skipping silently — flag it in the task's completion note and in the eventual PR's test plan as a
check that needs a human's machine.

- [ ] **Step 4: Tracking separators**

Resize the sidebar and inspector columns by dragging their dividers. The corresponding
`NSTrackingSeparatorToolbarItem` must track — toolbar items on either side of the separator should
visually align with the column boundary as it moves, not lag or jump.

- [ ] **Step 5: Search focus**

Press ⇧⌘F. The search field must gain keyboard focus (same mitigation-free path as
`SiteSearchActions.focusSearchField`, `SiteSearchField.swift:70-90`, still applies here since that
logic lives outside the shell). Type a query that matches content in the open site; the suggestions
menu must appear under the field with matching rows; press ↓ then Return to select one and confirm
`activate(hit)` fires (the same page-open behavior as the legacy `.searchCompletion` path).

- [ ] **Step 6: Record the gate result**

In the PR body's Design notes section, record pass/fail for each of Steps 2-5 with the exact OS
build (`sw_vers -productVersion`/`-buildVersion`) — mirroring PR #1713's "Gate evidence" section
format, so slice 3's PR can cite this one the same way slice 2 cited slice 1.

No commit for this task — it's verification only, feeding the PR body.
