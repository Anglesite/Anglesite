# Bucket 3 — Template Config Wiring Implementation Plan

**Status:** historical

> **Status:** Committed as pre-execution handoff artifact — all tasks implemented and merged to `feat/282-template-wiring` as of 2026-06-21.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the app's website template consume the `.site-config` the Bucket 3 framework writes — via a build-time `readConfig()` bridge + config-gated conditional render, with integration components copied on-demand and their import+render injected into layouts.

**Architecture:** A `readConfig(key)` helper reads `.site-config` at Astro build time. Integration components/pages live in a `Resources/Template/integrations/` staging dir that `scaffold.sh` excludes (so fresh sites carry none); the scaffolder copies them on-demand. Floating-booking and giscus inject a component `import` (Astro frontmatter, `//`-comment delimited) plus a `readConfig`-gated render (template body, `<!-- -->` delimited) into the layout — so `MarkerInjector` gains a comment style.

**Tech Stack:** Swift 6.4 / Xcode 27, Swift Testing (`@Test`), Astro template (TypeScript/`.astro`).

## Global Constraints

- All Swift; Apple frameworks only. Engine + tests in `AnglesiteCore` / `AnglesiteCoreTests`.
- Tests are Swift Testing (`@Test`/`@Suite`/`#expect`). Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path .` (default toolchain is too old).
- **Classic Foundation/Darwin APIs only in test bundles** — never `URL(filePath:)`, `.appending(path:)`, `.path(percentEncoded:)`, `SIG_IGN`, `EPIPE`. They link `libswift_DarwinFoundation3.dylib`, absent on CI runners → the whole test bundle fails to load. Use `URL(fileURLWithPath:)`, `appendingPathComponent(_:)`, `.path`.
- `tsconfig` extends `astro/tsconfigs/strict` (`noUnusedLocals`): an imported symbol must be used; a layout must not statically import a component it doesn't render.
- `.site-config` is flat `KEY=value` in the site's `Source/`. The framework writes it; the template reads it at build via `readConfig`.
- Worktree: `/Users/dwk/Developer/github.com/Anglesite/Anglesite-app/.claude/worktrees/282-template-wiring`, branch `feat/282-template-wiring`. `cd` here before any git op.
- Commit trailer on every commit: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

---

## File structure

**`Sources/AnglesiteCore/` (modify):**
- `MarkerInjector.swift` — add `CommentStyle` (`.html`/`.line`) + `style:` param.
- `IntegrationDescriptor.swift` — `Operation.injectAtAnchor` gains `style: MarkerInjector.CommentStyle`.
- `IntegrationPlan.swift` — `PlannedStep.injectAnchor` gains `style:`; `OperationPlan.summary` pattern updated.
- `IntegrationPlanner.swift` — thread `style` from op → step; update `operationReferences`.
- `IntegrationScaffolder.swift` — pass `style:` to `MarkerInjector.inject`.
- `IntegrationCatalog.swift` — descriptor data: `copyFile` from `integrations/…`, two inject ops for floating/giscus, new config keys.

**`Resources/Template/` (modify):**
- `scripts/config.ts` — new `readConfig` helper.
- `scripts/scaffold.sh` — exclude `integrations/`.
- `integrations/components/{BookingWidget,DonationButton,Comments}.astro` — moved from `src/components/`.
- `integrations/pages/{book,donate}.astro` — moved from `src/pages/`, rewritten to `readConfig`.
- `src/layouts/BaseLayout.astro`, `src/layouts/BlogPost.astro` — add `// anglesite:imports` frontmatter anchor (keep existing body anchors).
- Remove `src/components/{BookingWidget,DonationButton,Comments}.astro` and `src/pages/{book,donate}.astro`.

**Tests (modify):**
- `Tests/AnglesiteCoreTests/MarkerInjectorTests.swift`, `IntegrationCatalogTests.swift`, `IntegrationPlannerTests.swift`, `IntegrationScaffolderTests.swift`, `IntegrationTemplateAssetsTests.swift`.

---

## Task 1: `MarkerInjector` comment style

**Files:**
- Modify: `Sources/AnglesiteCore/MarkerInjector.swift`
- Test: `Tests/AnglesiteCoreTests/MarkerInjectorTests.swift`

**Interfaces:**
- Produces: `MarkerInjector.CommentStyle` (`.html`, `.line`) and `inject(snippet:withID:atAnchor:into:style:)` (defaulting `.html`). Consumed by Tasks 2–4.

- [ ] **Step 1: Write the failing test** (append to `MarkerInjectorTests.swift`)

```swift
@Test func injectsLineCommentBlockInFrontmatter() {
    let anchor = "// anglesite:imports"
    let doc = "---\nconst x = 1;\n\(anchor)\n---\n<body></body>"
    let out = try! MarkerInjector.inject(
        snippet: "import Foo from \"../components/Foo.astro\";",
        withID: "booking", atAnchor: anchor, into: doc, style: .line).get()
    #expect(out.contains("// anglesite:booking:start\nimport Foo from \"../components/Foo.astro\";\n// anglesite:booking:end"))
    #expect(out.contains(anchor))
    // idempotent
    let twice = try! MarkerInjector.inject(
        snippet: "import Foo from \"../components/Foo.astro\";",
        withID: "booking", atAnchor: anchor, into: out, style: .line).get()
    #expect(twice == out)
}

@Test func lineStyleFailsWhenAnchorMissing() {
    let r = MarkerInjector.inject(snippet: "x", withID: "b", atAnchor: "// anglesite:imports",
                                  into: "---\nconst x = 1;\n---", style: .line)
    #expect(r == .failure(.anchorNotFound("// anglesite:imports")))
}

@Test func htmlStyleStillDefaults() {
    let anchor = "<!-- anglesite:body-end -->"
    let out = try! MarkerInjector.inject(snippet: "<X/>", withID: "booking", atAnchor: anchor,
                                         into: "<body>\(anchor)</body>").get()
    #expect(out.contains("<!-- anglesite:booking:start -->\n<X/>\n<!-- anglesite:booking:end -->"))
}
```

- [ ] **Step 2: Run to verify failure**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter MarkerInjectorTests`
Expected: FAIL — `extra argument 'style' in call`.

- [ ] **Step 3: Implement** — replace the body of `MarkerInjector.swift` with:

```swift
import Foundation

public enum MarkerInjector {
    public enum Failure: Error, Equatable { case anchorNotFound(String) }

    /// Delimiter syntax: `.html` for Astro template bodies (`<!-- … -->`), `.line` for Astro
    /// frontmatter / TypeScript (`// …`).
    public enum CommentStyle: Sendable, Equatable { case html, line }

    /// Inserts `snippet` (wrapped in `anglesite:<id>:start/end` delimiters in the given `style`)
    /// immediately before the `atAnchor` comment; the anchor is preserved. Idempotent: an existing
    /// delimited block is replaced in place. Lone orphan markers are stripped before insertion.
    public static func inject(snippet: String, withID id: String, atAnchor anchor: String,
                              into content: String, style: CommentStyle = .html) -> Result<String, Failure> {
        let (start, end): (String, String)
        switch style {
        case .html: (start, end) = ("<!-- anglesite:\(id):start -->", "<!-- anglesite:\(id):end -->")
        case .line: (start, end) = ("// anglesite:\(id):start", "// anglesite:\(id):end")
        }
        let block = "\(start)\n\(snippet)\n\(end)"

        if let r = content.range(of: start), let e = content.range(of: end), r.lowerBound < e.lowerBound {
            return .success(content.replacingCharacters(in: r.lowerBound..<e.upperBound, with: block))
        }
        guard content.range(of: anchor) != nil else { return .failure(.anchorNotFound(anchor)) }
        let stripped = content
            .components(separatedBy: "\n")
            .filter { $0.trimmingCharacters(in: .whitespaces) != start && $0.trimmingCharacters(in: .whitespaces) != end }
            .joined(separator: "\n")
        guard let a2 = stripped.range(of: anchor) else { return .failure(.anchorNotFound(anchor)) }
        return .success(stripped.replacingCharacters(in: a2.lowerBound..<a2.lowerBound, with: "\(block)\n"))
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `DEVELOPER_DIR=… swift test --package-path . --filter MarkerInjectorTests`
Expected: PASS (existing `.html` cases + 3 new).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/MarkerInjector.swift Tests/AnglesiteCoreTests/MarkerInjectorTests.swift
git commit -m "feat(#282): MarkerInjector comment style (.html body / .line frontmatter)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Thread `style` through the engine

**Files:**
- Modify: `Sources/AnglesiteCore/IntegrationDescriptor.swift` (the `Operation` enum), `Sources/AnglesiteCore/IntegrationPlan.swift` (`PlannedStep` + `summary`), `Sources/AnglesiteCore/IntegrationPlanner.swift`, `Sources/AnglesiteCore/IntegrationScaffolder.swift`
- Test: `Tests/AnglesiteCoreTests/IntegrationScaffolderTests.swift`

**Interfaces:**
- Consumes: `MarkerInjector.CommentStyle` (Task 1).
- Produces: `Operation.injectAtAnchor(file:anchor:snippet:when:style:)` and `PlannedStep.injectAnchor(relativeFile:anchor:id:snippet:style:)`. Consumed by Task 4.

- [ ] **Step 1: Write the failing test** (append to `IntegrationScaffolderTests.swift`)

```swift
@Test func appliesLineStyleInjectIntoFrontmatter() async {
    let src = makeSource()  // existing helper that returns a temp dir
    let rel = "src/layouts/BaseLayout.astro"
    let url = src.appendingPathComponent(rel)
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! "---\n// anglesite:imports\n---\n<body><!-- anglesite:body-end --></body>".write(to: url, atomically: true, encoding: .utf8)
    let plan = OperationPlan(integrationID: .booking, steps: [
        .injectAnchor(relativeFile: rel, anchor: "// anglesite:imports", id: "booking",
                      snippet: "import BookingWidget from \"../components/BookingWidget.astro\";", style: .line),
    ], warnings: [])
    var last: IntegrationScaffolder.SetupStep?
    for await s in IntegrationScaffolder().apply(plan, in: src) { last = s }
    #expect(last == .done(integrationID: "booking"))
    let out = try! String(contentsOf: url, encoding: .utf8)
    #expect(out.contains("// anglesite:booking:start\nimport BookingWidget"))
}
```

(If `makeSource()` doesn't exist in this suite, add `func makeSource() -> URL { let u = FileManager.default.temporaryDirectory.appendingPathComponent("scaf-\(UUID().uuidString)"); try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true); return u }`.)

- [ ] **Step 2: Run to verify failure**

Run: `DEVELOPER_DIR=… swift test --package-path . --filter IntegrationScaffolderTests`
Expected: FAIL — `.injectAnchor` has no `style:` argument.

- [ ] **Step 3: Implement the threading**

In `IntegrationDescriptor.swift`, change the `Operation` case:
```swift
    case injectAtAnchor(file: Template, anchor: String, snippet: Template, when: Condition, style: MarkerInjector.CommentStyle)
```

In `IntegrationPlan.swift`, change the `PlannedStep` case and the `summary`:
```swift
    case injectAnchor(relativeFile: String, anchor: String, id: String, snippet: String, style: MarkerInjector.CommentStyle)
```
```swift
            case .injectAnchor(let file, _, _, _, _): lines.append("Add a component to \(file)")
```

In `IntegrationPlanner.swift`, the `.injectAtAnchor` resolution and `operationReferences`:
```swift
            case .injectAtAnchor(let file, let anchor, let snippet, let when, let style):
                guard isVisible(when, answers: effective, providerID: providerID) else { continue }
                steps.append(.injectAnchor(
                    relativeFile: file.resolve(tokens), anchor: anchor,
                    id: descriptor.id.rawValue, snippet: snippet.resolve(tokens), style: style))
```
```swift
        case .injectAtAnchor(let file, _, let snippet, _, _): return file.raw.contains(needle) || snippet.raw.contains(needle)
```

In `IntegrationScaffolder.swift`, the `.injectAnchor` step:
```swift
            case .injectAnchor(let rel, let anchor, let id, let snippet, let style):
                let url = source.appendingPathComponent(rel)
                do {
                    let content = try String(contentsOf: url, encoding: .utf8)
                    switch MarkerInjector.inject(snippet: snippet, withID: id, atAnchor: anchor, into: content, style: style) {
                    case .success(let updated): try updated.write(to: url, atomically: true, encoding: .utf8)
                    case .failure(let f): return emit(.failed(step: "writingFiles", message: "\(rel): \(f)"))
                    }
                } catch { return emit(.failed(step: "writingFiles", message: humanize(error))) }
```

**Keep the package compiling:** changing the `Operation`/`PlannedStep` arity breaks `IntegrationCatalog.swift`'s existing `injectAtAnchor(...)` calls immediately — and SwiftPM compiles the whole package even for a `--filter` run, so Task 2's own test can't run until they compile. So in THIS task, also add `, style: .html` to the **two existing** `injectAtAnchor(...)` calls in `IntegrationCatalog.swift` (booking-floating and giscus — both currently inject into HTML body anchors, so `.html` preserves behavior). Task 4 then redesigns those descriptors wholesale.

- [ ] **Step 4: Run to verify pass**

Run: `DEVELOPER_DIR=… swift test --package-path . --filter IntegrationScaffolderTests`
Expected: PASS. With the `, style: .html` stopgap added to `IntegrationCatalog`'s two existing inject calls, the package compiles and the full suite stays green here too (Task 4 later redesigns those descriptors).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/IntegrationDescriptor.swift Sources/AnglesiteCore/IntegrationPlan.swift Sources/AnglesiteCore/IntegrationPlanner.swift Sources/AnglesiteCore/IntegrationScaffolder.swift Sources/AnglesiteCore/IntegrationCatalog.swift Tests/AnglesiteCoreTests/IntegrationScaffolderTests.swift
git commit -m "feat(#282): thread MarkerInjector style through Operation/PlannedStep/planner/scaffolder

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Template restructure — `readConfig`, on-demand staging, layout anchors

**Files:**
- Create: `Resources/Template/scripts/config.ts`
- Modify: `Resources/Template/scripts/scaffold.sh`
- Move: `Resources/Template/src/components/{BookingWidget,DonationButton,Comments}.astro` → `Resources/Template/integrations/components/…`
- Move + rewrite: `Resources/Template/src/pages/{book,donate}.astro` → `Resources/Template/integrations/pages/…`
- Modify: `Resources/Template/src/layouts/BaseLayout.astro`, `Resources/Template/src/layouts/BlogPost.astro`
- Test: `Tests/AnglesiteCoreTests/IntegrationTemplateAssetsTests.swift`

**Interfaces:**
- Produces: `integrations/{components,pages}/…` source files (read by Task 4's `copyFile` ops), `scripts/config.ts`, and layout `// anglesite:imports` anchors.

- [ ] **Step 1: Write the failing test** (rewrite `IntegrationTemplateAssetsTests.swift` body; keep the classic-URL `templateRoot()` helper)

```swift
@Test func configHelperExists() {
    #expect(FileManager.default.fileExists(atPath: templateRoot().appendingPathComponent("scripts/config.ts").path))
}

@Test func onDemandAssetsAreStagedNotInSrc() {
    let root = templateRoot()
    // staged (copied on-demand):
    for p in ["integrations/components/BookingWidget.astro", "integrations/components/DonationButton.astro",
              "integrations/components/Comments.astro", "integrations/pages/book.astro", "integrations/pages/donate.astro"] {
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(p).path), "missing staged \(p)")
    }
    // NOT base-scaffolded:
    for p in ["src/components/BookingWidget.astro", "src/pages/book.astro", "src/pages/donate.astro"] {
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(p).path), "should be staged, not in src: \(p)")
    }
}

@Test func layoutsHaveImportAndBodyAnchors() throws {
    let root = templateRoot()
    let base = try String(contentsOf: root.appendingPathComponent("src/layouts/BaseLayout.astro"), encoding: .utf8)
    #expect(base.contains("// anglesite:imports"))
    #expect(base.contains("<!-- anglesite:body-end -->"))
    let blog = try String(contentsOf: root.appendingPathComponent("src/layouts/BlogPost.astro"), encoding: .utf8)
    #expect(blog.contains("// anglesite:imports"))
    #expect(blog.contains("<!-- anglesite:comments -->"))
}

@Test func onDemandPagesUseReadConfigNotImportMetaEnv() throws {
    let root = templateRoot()
    for p in ["integrations/pages/book.astro", "integrations/pages/donate.astro"] {
        let s = try String(contentsOf: root.appendingPathComponent(p), encoding: .utf8)
        #expect(s.contains("readConfig("), "\(p) should use readConfig")
        #expect(!s.contains("import.meta.env"), "\(p) must not use import.meta.env")
    }
}

@Test func scaffoldExcludesIntegrationsDir() throws {
    let s = try String(contentsOf: templateRoot().appendingPathComponent("scripts/scaffold.sh"), encoding: .utf8)
    #expect(s.contains("--exclude='integrations/'"))
}
```

- [ ] **Step 2: Run to verify failure**

Run: `DEVELOPER_DIR=… swift test --package-path . --filter IntegrationTemplateAssetsTests`
Expected: FAIL — staged files absent, anchors missing.

- [ ] **Step 3: Make the changes**

1. `scripts/config.ts`:
```ts
import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";

export function readConfigFromString(content: string, key: string): string | undefined {
  return content.match(new RegExp(`^${key}=(.+)$`, "m"))?.[1]?.trim();
}

export function readConfig(
  key: string,
  configPath: string = resolve(process.cwd(), ".site-config"),
): string | undefined {
  if (!existsSync(configPath)) return undefined;
  return readConfigFromString(readFileSync(configPath, "utf-8"), key);
}
```

2. `scripts/scaffold.sh` — add an exclude to the `rsync` block (after the `themes.ts` exclude line):
```sh
    --exclude='integrations/' \
```

3. `git mv` the components and pages into the staging dir:
```bash
mkdir -p Resources/Template/integrations/components Resources/Template/integrations/pages
git mv Resources/Template/src/components/BookingWidget.astro  Resources/Template/integrations/components/BookingWidget.astro
git mv Resources/Template/src/components/DonationButton.astro Resources/Template/integrations/components/DonationButton.astro
git mv Resources/Template/src/components/Comments.astro       Resources/Template/integrations/components/Comments.astro
git mv Resources/Template/src/pages/book.astro               Resources/Template/integrations/pages/book.astro
git mv Resources/Template/src/pages/donate.astro             Resources/Template/integrations/pages/donate.astro
```

4. Rewrite `integrations/pages/book.astro` (import paths are relative to the page's **destination** `src/pages/`, where the scaffolder copies it):
```astro
---
import BaseLayout from "../layouts/BaseLayout.astro";
import BookingWidget from "../components/BookingWidget.astro";
import { readConfig } from "../../scripts/config";
---

<BaseLayout title="Book a time">
  <BookingWidget
    provider={readConfig("BOOKING_PROVIDER")}
    username={readConfig("BOOKING_USERNAME")}
    eventSlug={readConfig("BOOKING_EVENT_SLUG")}
    style="inline"
  />
</BaseLayout>
```

5. Rewrite `integrations/pages/donate.astro`:
```astro
---
import BaseLayout from "../layouts/BaseLayout.astro";
import DonationButton from "../components/DonationButton.astro";
import { readConfig } from "../../scripts/config";
---

<BaseLayout title="Donate">
  <DonationButton
    href={readConfig("DONATIONS_LINK")}
    label={readConfig("DONATIONS_BUTTON_TEXT")}
    provider={readConfig("DONATIONS_PROVIDER")}
  />
</BaseLayout>
```

6. `src/layouts/BaseLayout.astro` — add the frontmatter import anchor. The frontmatter currently ends after `const { title, description } = Astro.props;`. Insert a blank line + anchor before the closing `---`:
```astro
const { title, description } = Astro.props;
// anglesite:imports
---
```
(Leave the existing `<!-- anglesite:body-end -->` body anchor as-is.)

7. `src/layouts/BlogPost.astro` — add the frontmatter anchor before its closing `---` (after `const { title, description } = Astro.props;`):
```astro
const { title, description } = Astro.props;
// anglesite:imports
---
```
(Leave the existing `<!-- anglesite:comments -->` body anchor.)

- [ ] **Step 4: Run to verify pass**

Run: `DEVELOPER_DIR=… swift test --package-path . --filter IntegrationTemplateAssetsTests`
Expected: PASS (5 tests). (The `pageEnvKeysAreWrittenByDescriptors` test, if present, may now reference moved paths — update it to read `integrations/pages/…` and to extract `readConfig("KEY")` instead of `import.meta.env.KEY`; assert ⊆ descriptor-written keys.)

- [ ] **Step 5: Commit**

```bash
git add Resources/Template Tests/AnglesiteCoreTests/IntegrationTemplateAssetsTests.swift
git commit -m "feat(#282): readConfig helper, on-demand integrations staging, layout import anchors

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Descriptor changes (`IntegrationCatalog`)

**Files:**
- Modify: `Sources/AnglesiteCore/IntegrationCatalog.swift`
- Test: `Tests/AnglesiteCoreTests/IntegrationCatalogTests.swift`, `Tests/AnglesiteCoreTests/IntegrationPlannerTests.swift`

**Interfaces:**
- Consumes: `Operation.injectAtAnchor(..., style:)` (Task 2); `integrations/…` staging paths (Task 3).
- Produces: the final trio descriptors.

- [ ] **Step 1: Write the failing tests**

In `IntegrationCatalogTests.swift`, add:
```swift
@Test func bookingWritesEventSlugAndButtonText() {
    let keys = writtenConfigKeys(for: IntegrationCatalog.descriptor(for: .booking))
    #expect(keys.isSuperset(of: ["BOOKING_PROVIDER","BOOKING_USERNAME","BOOKING_STYLE","BOOKING_EVENT_SLUG","BOOKING_BUTTON_TEXT"]))
}
@Test func giscusWritesAllIds() {
    let keys = writtenConfigKeys(for: IntegrationCatalog.descriptor(for: .giscus))
    #expect(keys.isSuperset(of: ["GISCUS_REPO","GISCUS_CATEGORY","GISCUS_REPO_ID","GISCUS_CATEGORY_ID","GISCUS_MAPPING"]))
}
// helper (add if not present):
private func writtenConfigKeys(for d: IntegrationDescriptor) -> Set<String> {
    var k = Set<String>()
    for case .writeConfig(let entries, _) in d.operations { for e in entries { k.insert(e.key) } }
    return k
}
```

In `IntegrationPlannerTests.swift`, replace the floating-booking expectation: it now produces **two** `injectAnchor` steps (frontmatter `.line` + body `.html`), no `import.meta.env`:
```swift
@Test func bookingFloatingInjectsFrontmatterImportAndBodyRender() {
    let r = plan(.booking, ["provider":"cal","username":"jane","style":"floating"])  // your suite's plan helper
    let injects = r.steps.compactMap { step -> (String, MarkerInjector.CommentStyle)? in
        if case .injectAnchor(let file, _, _, _, let style) = step { return (file, style) }; return nil
    }
    #expect(injects.contains { $0.0.contains("BaseLayout") && $0.1 == .line })   // frontmatter import
    #expect(injects.contains { $0.0.contains("BaseLayout") && $0.1 == .html })   // body render
}
```
(Adapt `plan(_:_:)` to the suite's existing planner-call helper, building source+template temp dirs as the other planner tests do; the template dir must contain `integrations/components/BookingWidget.astro` for the `copyFile` to resolve.)

- [ ] **Step 2: Run to verify failure**

Run: `DEVELOPER_DIR=… swift test --package-path . --filter "IntegrationCatalogTests|IntegrationPlannerTests"`
Expected: FAIL — missing keys / old single-inject shape.

- [ ] **Step 3: Implement the descriptors** — in `IntegrationCatalog.swift` set the trio's `operations` to:

```swift
// booking
operations: [
    .copyFile(from: TemplateRef("integrations/components/BookingWidget.astro"),
              to: "src/components/BookingWidget.astro",
              when: .fieldEquals(key: "style", value: "floating")),   // copied when floating…
    .copyFile(from: TemplateRef("integrations/components/BookingWidget.astro"),
              to: "src/components/BookingWidget.astro",
              when: .fieldEquals(key: "style", value: "inline")),     // …or inline
    .copyFile(from: TemplateRef("integrations/pages/book.astro"),
              to: "src/pages/book.astro", when: .fieldEquals(key: "style", value: "inline")),
    .injectAtAnchor(file: "src/layouts/BaseLayout.astro", anchor: "// anglesite:imports",
        snippet: "import BookingWidget from \"../components/BookingWidget.astro\";\nimport { readConfig } from \"../../scripts/config\";",
        when: .fieldEquals(key: "style", value: "floating"), style: .line),
    .injectAtAnchor(file: "src/layouts/BaseLayout.astro", anchor: "<!-- anglesite:body-end -->",
        snippet: "{readConfig(\"BOOKING_STYLE\") === \"floating\" && (<BookingWidget provider={readConfig(\"BOOKING_PROVIDER\")} username={readConfig(\"BOOKING_USERNAME\")} eventSlug={readConfig(\"BOOKING_EVENT_SLUG\")} buttonText={readConfig(\"BOOKING_BUTTON_TEXT\")} style=\"floating\" />)}",
        when: .fieldEquals(key: "style", value: "floating"), style: .html),
    .writeConfig([
        ConfigEntry(key: "BOOKING_PROVIDER", value: "{{provider}}"),
        ConfigEntry(key: "BOOKING_USERNAME", value: "{{username}}"),
        ConfigEntry(key: "BOOKING_STYLE", value: "{{style}}"),
        ConfigEntry(key: "BOOKING_EVENT_SLUG", value: "{{eventSlug}}"),
        ConfigEntry(key: "BOOKING_BUTTON_TEXT", value: "{{buttonText}}"),
    ], when: .always),
    .addCSPDomains(fromProvider: true, extra: [], when: .always),
]
```
(`button` style is treated as inline for v1 — keep the choice but the inline-gated `/book` copy + config covers it; no distinct op.)

```swift
// giscus
operations: [
    .copyFile(from: TemplateRef("integrations/components/Comments.astro"),
              to: "src/components/Comments.astro", when: .always),
    .injectAtAnchor(file: "src/layouts/BlogPost.astro", anchor: "// anglesite:imports",
        snippet: "import Comments from \"../components/Comments.astro\";\nimport { readConfig } from \"../../scripts/config\";",
        when: .always, style: .line),
    .injectAtAnchor(file: "src/layouts/BlogPost.astro", anchor: "<!-- anglesite:comments -->",
        snippet: "{!!readConfig(\"GISCUS_REPO\") && (<Comments repo={readConfig(\"GISCUS_REPO\")} repoId={readConfig(\"GISCUS_REPO_ID\")} category={readConfig(\"GISCUS_CATEGORY\")} categoryId={readConfig(\"GISCUS_CATEGORY_ID\")} mapping={readConfig(\"GISCUS_MAPPING\")} />)}",
        when: .always, style: .html),
    .writeConfig([
        ConfigEntry(key: "GISCUS_REPO", value: "{{repo}}"),
        ConfigEntry(key: "GISCUS_CATEGORY", value: "{{category}}"),
        ConfigEntry(key: "GISCUS_REPO_ID", value: "{{repoId}}"),
        ConfigEntry(key: "GISCUS_CATEGORY_ID", value: "{{categoryId}}"),
        ConfigEntry(key: "GISCUS_MAPPING", value: "{{mapping}}"),
    ], when: .always),
    .addCSPDomains(fromProvider: false, extra: ["giscus.app"], when: .always),
]
```

```swift
// donations
operations: [
    .copyFile(from: TemplateRef("integrations/components/DonationButton.astro"),
              to: "src/components/DonationButton.astro", when: .always),
    .copyFile(from: TemplateRef("integrations/pages/donate.astro"),
              to: "src/pages/donate.astro", when: .always),
    .writeConfig([
        ConfigEntry(key: "DONATIONS_PROVIDER", value: "{{provider}}"),
        ConfigEntry(key: "DONATIONS_LINK", value: "{{link}}"),
        ConfigEntry(key: "DONATIONS_BUTTON_TEXT", value: "{{buttonText}}"),
    ], when: .always),
    .addCSPDomains(fromProvider: true, extra: [], when: .always),
]
```

- [ ] **Step 4: Run to verify pass**

Run: `DEVELOPER_DIR=… swift test --package-path . --filter "IntegrationCatalogTests|IntegrationPlannerTests"`
Expected: PASS. Update any now-stale assertions in these suites (e.g. an old `injectedSnippetsCarryNoClientDirective` test should now scan both inject ops' snippets and still find no `client:` directive; a planner test asserting a single inject for floating).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/IntegrationCatalog.swift Tests/AnglesiteCoreTests/IntegrationCatalogTests.swift Tests/AnglesiteCoreTests/IntegrationPlannerTests.swift
git commit -m "feat(#282): trio descriptors — on-demand staging, frontmatter+body inject, new config keys

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Full verification + remaining test fixups

**Files:**
- Modify (as needed): any `AnglesiteCoreTests` / `AnglesiteIntentsTests` suite left stale by the descriptor/engine changes.

- [ ] **Step 1: Full Swift suite**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path .`
Expected: all green. Fix any stale assertions (e.g. `IntegrationScaffolderTests`/`IntegrationOperationsTests` that referenced the old single-inject layout behavior, or any test asserting `book`/`donate` live in `src/pages/`). Report per-product totals.

- [ ] **Step 2: Build both app schemes** (they consume the engine via `AnglesiteCore`)

Run:
```bash
DEVELOPER_DIR=… xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build
DEVELOPER_DIR=… xcodebuild -project Anglesite.xcodeproj -scheme AnglesiteMAS -configuration Debug build
```
(Run `xcodegen generate` first if the worktree's `Anglesite.xcodeproj` is stale.) Expected: BUILD SUCCEEDED for both.

- [ ] **Step 3: Manual build-smoke (acceptance, documented in the PR — not CI)**

In a throwaway dir, scaffold + configure + `npm run build` to confirm a configured site renders and an un-configured site still builds:
```bash
# scaffold a site, write a .site-config with BOOKING_STYLE=floating + provider/username,
# run the booking floating injects manually OR via the app, then `npm install && npm run build`.
```
Record the result in the PR description. (A template-build CI lane is a separate follow-up.)

- [ ] **Step 4: Commit any test fixups**

```bash
git add -A
git commit -m "test(#282): reconcile suites with on-demand staging + dual-inject descriptors

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

**1. Spec coverage:**
- §3 MarkerInjector comment style → Task 1. ✓
- §3 Operation/PlannedStep/planner/scaffolder threading → Task 2. ✓
- §4 `config.ts`, on-demand staging (`integrations/` + scaffold exclude), layouts with both anchors, pages via `readConfig` → Task 3. ✓
- §5 descriptor changes (copyFile from staging, dual inject for floating/giscus, new keys, button-as-inline) → Task 4. ✓
- §6 error handling (un-configured site builds clean; idempotent inject) → covered by Task 1 idempotency + Task 3 layouts shipping anchors only. ✓
- §7 testing (MarkerInjector `.line`, catalog keys, planner dual-inject, asset tests, build smoke scoped) → Tasks 1,3,4,5. ✓
- §8 out-of-scope honored (no blog-collection wiring, button=inline, no CSP→_headers). ✓

**2. Placeholder scan:** No "TBD/handle errors" — each step carries concrete code or exact commands. The "adapt to the suite's plan helper" notes in Task 4 are explicit (build temp dirs like sibling tests), not vague.

**3. Type consistency:** `MarkerInjector.CommentStyle` used identically in `Operation.injectAtAnchor(...,style:)`, `PlannedStep.injectAnchor(...,style:)`, planner, scaffolder, and tests. `injectAnchor` association arity is 5 everywhere (relativeFile, anchor, id, snippet, style) — `summary` and scaffolder updated to the 5-tuple. `writtenConfigKeys` helper defined in the catalog test. Staging paths (`integrations/components/…`, `integrations/pages/…`) match between Task 3 (files created) and Task 4 (`copyFile from:`).

(One consistency fix applied: Task 2 explicitly notes `IntegrationCatalog` won't compile until Task 4 — sequence them back-to-back; the full suite runs only at Task 4+.)

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-06-21-bucket3-template-wiring.md`. Two execution options:

1. **Subagent-Driven (recommended)** — fresh subagent per task, review between tasks.
2. **Inline Execution** — execute here with checkpoints.
