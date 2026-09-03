# Site identity h-card (personal + business) Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a single per-site representative h-card — personal (`Person`) or business (`LocalBusiness`), mutually exclusive — that renders in a site-wide footer, on a general singleton storage mechanism.

**Architecture:** A new `ContentStorage.singleton(slot)` registry case backs two descriptors (`businessProfile`, `personalProfile`) that share one slot (`"profile"`). `AnglesiteCore` gains a pure JSON renderer (`ContentScaffold.renderSingleton`) and a writer (`NativeContentOperations.createTypedSingleton`) that enforces one-per-site by refusing to overwrite the slot file `src/data/profile.json`. The template gains an `Hcard.astro` footer partial that optionally imports that JSON and renders `h-card` mf2 (or nothing when absent).

**Tech Stack:** Swift 6.4 / Swift Testing (`@Test`), Astro (template), microformats2.

## Global Constraints

- ES modules / vanilla — no new dependencies. macOS 27+, Swift 6.4.
- **mf2 only** this pass. No schema.org JSON-LD (V-1.8), no `rel=me`/IndieAuth (V-2), no SwiftUI/app-target code, no UI.
- **Template ships empty:** `src/data/profile.json` is never committed. Any test that writes it must `defer`-remove it.
- Tests are Swift Testing (`@Test`/`#expect`/`#require`), run with `swift test --package-path .` from the worktree root.
- `swift test` needs `DEVELOPER_DIR` pointed at the Xcode-beta toolchain (Xcode 27 / Swift 6.4); the default CommandLineTools `swift` is too old.
- Work entirely in the worktree `.claude/worktrees/388-site-identity/` on branch `feat/388-site-identity`. Spec: `docs/superpowers/specs/2026-06-27-site-identity-hcard-design.md`.

---

### Task 1: Registry — singleton storage + `personalProfile`

**Files:**
- Modify: `Sources/AnglesiteCore/ContentTypeRegistry.swift` (the `ContentStorage` enum ~L82-85, the `collection` computed property ~L113-116, the built-in catalog ~L164 and the Business section ~L324-361)
- Test: `Tests/AnglesiteCoreTests/ContentTypeRegistryTests.swift` (the `businessProfileType` test ~L114-122)

**Interfaces:**
- Produces: `ContentStorage.singleton(String)`; `ContentTypeDescriptor.singletonSlot -> String?`; `ContentTypeRegistry.identityTypes: [ContentTypeDescriptor]`; descriptors `businessProfile` (now `.singleton("profile")`) and `personalProfile` (`.singleton("profile")`, `h-card`/`Person`, fields `name`/`description`/`email`/`url`/`photo`).

- [ ] **Step 1: Update the existing registry test to the singleton expectation**

In `Tests/AnglesiteCoreTests/ContentTypeRegistryTests.swift`, replace the `businessProfileType` test (currently asserting `.page`) with:

```swift
    @Test("Business Profile is an h-card / LocalBusiness singleton")
    func businessProfileType() throws {
        let profile = try #require(ContentTypeRegistry().descriptor(id: "businessProfile"))
        #expect(profile.storage == .singleton("profile"))
        #expect(profile.singletonSlot == "profile")
        #expect(profile.collection == nil)
        #expect(profile.projections.microformat == "h-card")
        #expect(profile.projections.schemaType == "LocalBusiness")
        #expect(profile.projections.microformatProperties["telephone"] == "p-tel")
    }

    @Test("Personal Profile is an h-card / Person singleton sharing the profile slot")
    func personalProfileType() throws {
        let profile = try #require(ContentTypeRegistry().descriptor(id: "personalProfile"))
        #expect(profile.storage == .singleton("profile"))
        #expect(profile.singletonSlot == "profile")
        #expect(profile.collection == nil)
        #expect(profile.projections.microformat == "h-card")
        #expect(profile.projections.schemaType == "Person")
        #expect(profile.projections.microformatProperties["email"] == "u-email")
        #expect(profile.fields.first?.name == "name")
        #expect(profile.fields.first?.required == true)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path . --filter "ContentTypeRegistryTests"`
Expected: FAIL — `.singleton` is not a member of `ContentStorage`; `singletonSlot` and `personalProfile` do not exist (compile errors).

- [ ] **Step 3: Add the `.singleton` storage case and `singletonSlot`**

In `Sources/AnglesiteCore/ContentTypeRegistry.swift`, extend the enum:

```swift
public enum ContentStorage: Sendable, Equatable {
    case page
    case collection(String)
    /// One record per site, stored as a data module (not a route, not a collection). The
    /// associated value is the shared slot name; descriptors that share a slot are mutually
    /// exclusive (one identity file per site).
    case singleton(String)
}
```

Add the computed property next to `collection` (after the existing `collection` var, ~L116):

```swift
    /// The shared slot name for `.singleton`-stored types; `nil` otherwise.
    public var singletonSlot: String? {
        if case let .singleton(name) = storage { return name }
        return nil
    }
```

- [ ] **Step 4: Add `personalProfile`, flip `businessProfile` to a singleton, and regroup**

In `Sources/AnglesiteCore/ContentTypeRegistry.swift`, change the catalog aggregate (~L164):

```swift
    public static let builtIns: [ContentTypeDescriptor] = personalTypes + identityTypes + businessTypes
```

Replace the `// MARK: Business (#345 / §4.1)` section header + `businessTypes` line + the `businessProfile` declaration so the section reads:

```swift
    // MARK: Site identity (h-card singletons, #388)

    /// The two representative-h-card types. They share the `"profile"` slot, so a site has at most
    /// one identity — personal or business — enforced at scaffold time by the single slot file.
    static let identityTypes: [ContentTypeDescriptor] = [businessProfile, personalProfile]

    static let businessProfile = ContentTypeDescriptor(
        id: "businessProfile",
        displayName: "Business Profile",
        storage: .singleton("profile"),
        fields: [
            ContentTypeField("name", .string, required: true),
            ContentTypeField("description", .text),
            ContentTypeField("telephone", .string),
            ContentTypeField("email", .string),
            ContentTypeField("streetAddress", .string),
            ContentTypeField("locality", .string),
            ContentTypeField("region", .string),
            ContentTypeField("postalCode", .string),
            ContentTypeField("hours", .stringArray),
            ContentTypeField("url", .url),
        ],
        // `hours` is intentionally unmapped: h-card has no normative opening-hours property, so
        // hours are carried by schema.org (`LocalBusiness.openingHours`) only, not microformats2.
        projections: ContentTypeProjections(
            microformat: "h-card",
            microformatProperties: [
                "name": "p-name",
                "description": "p-note",
                "telephone": "p-tel",
                "email": "u-email",
                "streetAddress": "p-street-address",
                "locality": "p-locality",
                "region": "p-region",
                "postalCode": "p-postal-code",
                "url": "u-url",
            ],
            schemaType: "LocalBusiness"
        )
    )

    static let personalProfile = ContentTypeDescriptor(
        id: "personalProfile",
        displayName: "Personal Profile",
        storage: .singleton("profile"),
        fields: [
            ContentTypeField("name", .string, required: true),
            ContentTypeField("description", .text),
            ContentTypeField("email", .string),
            ContentTypeField("url", .url),
            ContentTypeField("photo", .image),
        ],
        projections: ContentTypeProjections(
            microformat: "h-card",
            microformatProperties: [
                "name": "p-name",
                "description": "p-note",
                "email": "u-email",
                "url": "u-url",
                "photo": "u-photo",
            ],
            schemaType: "Person"
        )
    )

    // MARK: Business (collection types, #345 / §4.1)

    static let businessTypes: [ContentTypeDescriptor] = [announcement, event, review]
```

(The `announcement`, `event`, `review` declarations stay exactly where they are, below this.)

- [ ] **Step 5: Run the full registry suite to verify it passes**

Run: `swift test --package-path . --filter "ContentTypeRegistryTests"`
Expected: PASS — including `builtInInvariants` (validates `personalProfile`: `h-card` prefix, all mapped fields exist, singleton skipped by the `.collection` switch) and `defaultRegistry` (tautological id checks).

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteCore/ContentTypeRegistry.swift Tests/AnglesiteCoreTests/ContentTypeRegistryTests.swift
git commit -m "feat(#388): singleton storage + personalProfile h-card descriptor"
```

---

### Task 2: Scaffold — `renderSingleton` + path + JSON escaping

**Files:**
- Modify: `Sources/AnglesiteCore/ContentScaffold.swift` (add path builder near `postRelativePath` ~L49-51, add `renderSingleton` after `renderEntry` ~L172, add `escapeJSON` near the other escapers ~L174-190)
- Test: `Tests/AnglesiteCoreTests/ContentScaffoldTests.swift`

**Interfaces:**
- Consumes: `ContentTypeDescriptor`, `ContentTypeField.Kind` (Task 1).
- Produces: `ContentScaffold.singletonRelativePath(slot: String) -> String` → `"src/data/<slot>.json"`; `ContentScaffold.renderSingleton(descriptor: ContentTypeDescriptor, name: String?) -> String` → a JSON object string, `"type"` first, one key per non-`markdown` field in descriptor order, deterministic, trailing newline.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/AnglesiteCoreTests/ContentScaffoldTests.swift` (inside the `ContentScaffoldTests` struct):

```swift
    @Test("singletonRelativePath maps a slot to a data-module json path")
    func singletonPath() {
        #expect(ContentScaffold.singletonRelativePath(slot: "profile") == "src/data/profile.json")
    }

    @Test("renderSingleton emits a business profile with type, filled name, and empty defaults")
    func renderSingletonBusiness() throws {
        let biz = try #require(ContentTypeRegistry().descriptor(id: "businessProfile"))
        let out = ContentScaffold.renderSingleton(descriptor: biz, name: "Acme \"Co\"")
        #expect(out == """
        {
          "type": "businessProfile",
          "name": "Acme \\"Co\\"",
          "description": "",
          "telephone": "",
          "email": "",
          "streetAddress": "",
          "locality": "",
          "region": "",
          "postalCode": "",
          "hours": [],
          "url": ""
        }
        """ + "\n")
    }

    @Test("renderSingleton for a personal profile omits business-only keys")
    func renderSingletonPersonal() throws {
        let person = try #require(ContentTypeRegistry().descriptor(id: "personalProfile"))
        let out = ContentScaffold.renderSingleton(descriptor: person, name: "Ada")
        #expect(out.contains("\"type\": \"personalProfile\""))
        #expect(out.contains("\"name\": \"Ada\""))
        #expect(out.contains("\"photo\": \"\""))
        #expect(!out.contains("streetAddress"))
        #expect(!out.contains("hours"))
        #expect(out.hasSuffix("}\n"))
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path . --filter "ContentScaffold"`
Expected: FAIL — `singletonRelativePath` and `renderSingleton` are undefined.

- [ ] **Step 3: Implement the path builder, JSON escaper, and renderer**

In `Sources/AnglesiteCore/ContentScaffold.swift`, add the path builder next to `postRelativePath`:

```swift
    public static func singletonRelativePath(slot: String) -> String {
        "src/data/\(slot).json"
    }
```

Add `escapeJSON` next to the other escapers (after `escapeYAML`):

```swift
    static func escapeJSON(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "\n", with: "\\n")
         .replacingOccurrences(of: "\r", with: "\\r")
         .replacingOccurrences(of: "\t", with: "\\t")
    }
```

Add the renderer after `renderEntry`:

```swift
    /// Render a per-site singleton (e.g. the representative h-card) as a JSON data module:
    /// `"type"` first, then one key per non-`markdown` field in descriptor order, with empty/zero
    /// defaults and the name-like field filled from `name`. Pure; hand-rendered for deterministic
    /// key order (unlike `JSONEncoder`). The template imports this file to render the identity.
    public static func renderSingleton(descriptor: ContentTypeDescriptor, name: String?) -> String {
        var entries: [String] = ["\"type\": \"\(escapeJSON(descriptor.id))\""]
        for field in descriptor.fields {
            let value: String
            switch field.kind {
            case .markdown:
                continue // a data record has no body
            case .bool:
                value = "false"
            case .number:
                value = "0"
            case .stringArray, .imageArray:
                value = "[]"
            case .string, .text, .url, .image, .date, .datetime:
                let filled = titleLikeFieldNames.contains(field.name) ? (name ?? "") : ""
                value = "\"\(escapeJSON(filled))\""
            }
            entries.append("\"\(field.name)\": \(value)")
        }
        return "{\n" + entries.map { "  \($0)" }.joined(separator: ",\n") + "\n}\n"
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path . --filter "ContentScaffold"`
Expected: PASS (all three new tests plus the existing scaffold tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/ContentScaffold.swift Tests/AnglesiteCoreTests/ContentScaffoldTests.swift
git commit -m "feat(#388): ContentScaffold.renderSingleton + singleton path"
```

---

### Task 3: Operations — `createTypedSingleton` + generalized `createTyped` rejection

**Files:**
- Modify: `Sources/AnglesiteCore/NativeContentOperations.swift` (the `createTyped` guard ~L124-126 and its doc comment ~L107-116; add `createTypedSingleton` after `createTyped` ~L149)
- Modify: `Sources/AnglesiteCore/ContentOperationsService.swift` (doc comment ~L12 referencing "page-stored types (e.g. `businessProfile`)")
- Test: `Tests/AnglesiteCoreTests/NativeContentOperationsTests.swift` (replace `createTypedPageStored` ~L124-129; add new tests)

**Interfaces:**
- Consumes: `ContentTypeDescriptor.singletonSlot`, `ContentScaffold.singletonRelativePath`, `ContentScaffold.renderSingleton` (Tasks 1-2); the existing private `write(_:to:)` and `gitCommit` closure.
- Produces: `NativeContentOperations.createTypedSingleton(siteID:typeID:name:registry:onProgress:) async -> ContentCreateResult`. On success: `.created(filePath: "src/data/<slot>.json", identifier: <slot>)`. Refuses a second identity with `.failed(reason: "A site identity already exists at src/data/<slot>.json")`.

- [ ] **Step 1: Update the obsolete test and add the new behavior tests**

In `Tests/AnglesiteCoreTests/NativeContentOperationsTests.swift`, replace the `createTypedPageStored` test with:

```swift
    @Test("createTyped rejects singleton types with a pointer to createTypedSingleton")
    func createTypedRejectsSingleton() async {
        let (ops, _, _) = makeOps()
        let result = await ops.createTyped(siteID: "s1", typeID: "businessProfile", title: "x")
        #expect(result == .failed(reason: "businessProfile is not a collection type; use createTypedSingleton"))
    }

    @Test("createTypedSingleton writes the slot data file and commits")
    func createTypedSingletonWrites() async throws {
        let (ops, root, spy) = makeOps()
        let result = await ops.createTypedSingleton(siteID: "s1", typeID: "businessProfile", name: "Acme")
        #expect(result == .created(filePath: "src/data/profile.json", identifier: "profile"))
        let written = try String(
            contentsOf: root.appendingPathComponent("src/data/profile.json"), encoding: .utf8)
        #expect(written.contains("\"type\": \"businessProfile\""))
        #expect(written.contains("\"name\": \"Acme\""))
        let calls = await spy.calls
        #expect(calls.count == 1)
        #expect(calls.first?.1 == "src/data/profile.json")
        #expect(calls.first?.2 == "anglesite: add businessProfile")
    }

    @Test("createTypedSingleton enforces one identity per site across kinds")
    func createTypedSingletonMutuallyExclusive() async {
        let (ops, _, _) = makeOps()
        _ = await ops.createTypedSingleton(siteID: "s1", typeID: "businessProfile", name: "Acme")
        let second = await ops.createTypedSingleton(siteID: "s1", typeID: "personalProfile", name: "Ada")
        #expect(second == .failed(reason: "A site identity already exists at src/data/profile.json"))
    }

    @Test("createTypedSingleton rejects collection types and unknown ids")
    func createTypedSingletonRejectsCollection() async {
        let (ops, _, _) = makeOps()
        let coll = await ops.createTypedSingleton(siteID: "s1", typeID: "note", name: "x")
        #expect(coll == .failed(reason: "note is not a singleton type"))
        let unknown = await ops.createTypedSingleton(siteID: "s1", typeID: "nope", name: "x")
        #expect(unknown == .failed(reason: "Unknown content type: nope"))
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path . --filter "NativeContentOperations"`
Expected: FAIL — `createTypedSingleton` is undefined; `createTyped` still returns the old "Page-stored type…" message.

- [ ] **Step 3: Generalize the `createTyped` rejection and add `createTypedSingleton`**

In `Sources/AnglesiteCore/NativeContentOperations.swift`, change the `createTyped` guard (currently returns the "Page-stored type … is not supported by createTyped yet" message):

```swift
        guard let collection = descriptor.collection else {
            return .failed(reason: "\(typeID) is not a collection type; use createTypedSingleton")
        }
```

Update the `createTyped` doc comment's last sentence from "page-stored types (e.g. `businessProfile`) are #345." to: "Singleton-stored types (e.g. the `profile` identity) go through `createTypedSingleton`."

Add the new method immediately after `createTyped`:

```swift
    /// Create a per-site singleton (V-1.3 follow-up, #388) — e.g. the representative h-card.
    /// Looks the type up, resolves its `singletonSlot`, renders the JSON data module via
    /// `ContentScaffold.renderSingleton`, and writes it — refusing if the slot file already exists,
    /// which enforces one identity per site across both `businessProfile` and `personalProfile`
    /// (they share the `"profile"` slot). Same write/commit path as `createTyped`.
    public func createTypedSingleton(
        siteID: String,
        typeID: String,
        name: String,
        registry: ContentTypeRegistry = ContentTypeRegistry(),
        onProgress: ProgressHandler? = nil
    ) async -> ContentCreateResult {
        onProgress?(.createResolvingRuntime)
        guard let root = await siteDirectory(siteID) else { return .siteNotFound }
        guard let descriptor = registry.descriptor(id: typeID) else {
            return .failed(reason: "Unknown content type: \(typeID)")
        }
        guard let slot = descriptor.singletonSlot else {
            return .failed(reason: "\(typeID) is not a singleton type")
        }

        let relPath = ContentScaffold.singletonRelativePath(slot: slot)
        let abs = root.appendingPathComponent(relPath)
        if fileManager.fileExists(atPath: abs.path) {
            return .failed(reason: "A site identity already exists at \(relPath)")
        }

        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let contents = ContentScaffold.renderSingleton(
            descriptor: descriptor, name: cleanName.isEmpty ? nil : cleanName)
        do { try write(contents, to: abs) }
        catch { return .failed(reason: "\(error)") }

        onProgress?(.createFinalizing)
        _ = await gitCommit(root, relPath, "anglesite: add \(descriptor.id)")
        return .created(filePath: relPath, identifier: slot)
    }
```

In `Sources/AnglesiteCore/ContentOperationsService.swift`, update the `createTyped` doc comment (~L12) from "page-stored types (e.g. `businessProfile`) report `.failed`." to "non-collection types (e.g. the `profile` identity singleton) report `.failed` — use `createTypedSingleton`."

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path . --filter "NativeContentOperations"`
Expected: PASS (the four new/updated tests plus the existing operation tests).

- [ ] **Step 5: Confirm the MCP-path tests are unaffected**

The MCP-routed tests (`ContentOperationsTests`, `CreateContentEndToEndTests`) assert the *plugin's* "Page-stored type businessProfile…" message via a mock/real plugin that is **not** modified in this repo, so they must still pass unchanged.

Run: `swift test --package-path . --filter "ContentOperationsTests"`
Expected: PASS (no changes needed). If `CreateContentEndToEndTests` is enabled in your env (needs `ANGLESITE_PLUGIN_PATH` + node), it also passes unchanged.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteCore/NativeContentOperations.swift Sources/AnglesiteCore/ContentOperationsService.swift Tests/AnglesiteCoreTests/NativeContentOperationsTests.swift
git commit -m "feat(#388): NativeContentOperations.createTypedSingleton with one-per-site gate"
```

---

### Task 4: Template — footer `Hcard.astro` + render smoke test

**Files:**
- Create: `Resources/Template/src/components/Hcard.astro`
- Modify: `Resources/Template/src/layouts/BaseLayout.astro` (add the import in frontmatter ~L8 and `<Hcard />` after the `<slot />` ~L25)
- Create: `Tests/AnglesiteCoreTests/SiteIdentityRenderSmokeTests.swift`

**Interfaces:**
- Consumes: nothing from Swift at runtime — the partial reads `src/data/profile.json` itself. The smoke test writes fixture JSON shaped like `ContentScaffold.renderSingleton` output but with **populated** values (the scaffold writes empty placeholders; the renderer only emits fields that are non-empty, so a populated fixture is required to assert address/contact mf2).

- [ ] **Step 1: Ensure the worktree template can build**

The worktree has no `node_modules` (gitignored). Install Astro so the smoke test runs instead of skipping:

Run: `npm install --prefix Resources/Template`
Expected: completes; `Resources/Template/node_modules/astro/astro.js` now exists.

- [ ] **Step 2: Write the failing render smoke test**

Create `Tests/AnglesiteCoreTests/SiteIdentityRenderSmokeTests.swift`:

```swift
import Testing
import Foundation
import AnglesiteTestSupport
@testable import AnglesiteCore

@Suite("Site identity h-card render smoke")
struct SiteIdentityRenderSmokeTests {

    static var templateDir: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("Resources/Template", isDirectory: true)
    }

    /// True when the template can actually be built: a Node binary plus an installed Astro.
    static var buildable: Bool {
        guard E2EPrerequisites.locateNode() != nil else { return false }
        return FileManager.default.isReadableFile(
            atPath: templateDir.appendingPathComponent("node_modules/astro/astro.js").path)
    }

    @Test("footer h-card renders per profile kind, and nothing when unconfigured",
          .enabled(if: SiteIdentityRenderSmokeTests.buildable))
    func rendersFooterHcard() async throws {
        let node = try #require(E2EPrerequisites.locateNode())
        let dataDir = Self.templateDir.appendingPathComponent("src/data", isDirectory: true)
        let profile = dataDir.appendingPathComponent("profile.json")
        let dist = Self.templateDir.appendingPathComponent("dist", isDirectory: true)

        func build() async throws {
            try? FileManager.default.removeItem(at: dist)
            let result = try await ProcessSupervisor.shared.run(
                executable: node,
                arguments: ["node_modules/astro/astro.js", "build"],
                currentDirectoryURL: Self.templateDir)
            try #require(result.exitCode == 0, "astro build failed: \(result.stdout)\n\(result.stderr)")
        }
        func indexHTML() throws -> String {
            try String(contentsOf: dist.appendingPathComponent("index.html"), encoding: .utf8)
        }
        func writeProfile(_ json: String) throws {
            try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
            try json.write(to: profile, atomically: true, encoding: .utf8)
        }

        try await TemplateBuildSerializer.shared.serialize {
            // Keep the template ship-empty no matter how this test exits.
            defer {
                try? FileManager.default.removeItem(at: dataDir)
                try? FileManager.default.removeItem(at: dist)
            }

            // 1. Unconfigured: no profile.json → no h-card in the footer.
            try? FileManager.default.removeItem(at: dataDir)
            try await build()
            #expect(!(try indexHTML().contains("h-card")))

            // 2. Business profile → h-card with contact + address mf2.
            try writeProfile("""
            {"type":"businessProfile","name":"Acme Co","telephone":"+1-555-0100",\
            "email":"hi@acme.test","streetAddress":"1 Main St","locality":"Springfield",\
            "region":"IL","postalCode":"62701","hours":["Mon-Fri 9-5"],"url":"https://acme.test"}
            """)
            try await build()
            let biz = try indexHTML()
            #expect(biz.contains("h-card"))
            #expect(biz.contains("p-name"))
            #expect(biz.contains("p-tel"))
            #expect(biz.contains("p-street-address"))

            // 3. Personal profile → h-card without business-only address mf2.
            try writeProfile("""
            {"type":"personalProfile","name":"Ada Lovelace","description":"Mathematician",\
            "email":"ada@example.test","url":"https://ada.example.test"}
            """)
            try await build()
            let person = try indexHTML()
            #expect(person.contains("h-card"))
            #expect(person.contains("p-name"))
            #expect(person.contains("u-email"))
            #expect(!person.contains("p-street-address"))
        }
    }
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `swift test --package-path . --filter "SiteIdentityRenderSmokeTests"`
Expected: FAIL — the build succeeds but no `h-card` is emitted (no `Hcard.astro`, no footer wiring), so the business/personal `#expect`s fail. (If it reports *skipped*, Step 1 did not install Astro — fix that first; a skipped test is not a passing test.)

- [ ] **Step 4: Create the `Hcard.astro` footer partial**

Create `Resources/Template/src/components/Hcard.astro`:

```astro
---
// Site representative h-card (#388). Optional: renders only when src/data/profile.json exists.
// The glob returns {} when the file is absent, so an unconfigured site shows no footer identity.
// microformats2 only — the Person vs LocalBusiness schema.org @type is V-1.8.
const mods = import.meta.glob<{ default: Record<string, any> }>("../data/profile.json", { eager: true });
const profile = Object.values(mods)[0]?.default;
const hasAddress = profile && (profile.streetAddress || profile.locality || profile.region || profile.postalCode);
const hours: string[] = Array.isArray(profile?.hours) ? profile.hours : [];
---

{profile && (
  <footer class="site-identity">
    <div class="h-card">
      {profile.name && <p class="p-name">{profile.name}</p>}
      {profile.description && <p class="p-note">{profile.description}</p>}
      {profile.photo && <img class="u-photo" src={profile.photo} alt={profile.name ?? ""} />}
      {profile.telephone && <a class="p-tel" href={`tel:${profile.telephone}`}>{profile.telephone}</a>}
      {profile.email && <a class="u-email" href={`mailto:${profile.email}`}>{profile.email}</a>}
      {hasAddress && (
        <p class="p-adr h-adr">
          {profile.streetAddress && <span class="p-street-address">{profile.streetAddress}</span>}
          {profile.locality && <span class="p-locality">{profile.locality}</span>}
          {profile.region && <span class="p-region">{profile.region}</span>}
          {profile.postalCode && <span class="p-postal-code">{profile.postalCode}</span>}
        </p>
      )}
      {profile.url && <a class="u-url" href={profile.url}>{profile.url}</a>}
      {hours.length > 0 && (
        <ul class="hours">{hours.map((h) => <li>{h}</li>)}</ul>
      )}
    </div>
  </footer>
)}
```

- [ ] **Step 5: Wire the partial into the site-wide layout**

In `Resources/Template/src/layouts/BaseLayout.astro`, add the import in the frontmatter (above the `// anglesite:imports` comment):

```astro
import Hcard from "../components/Hcard.astro";
```

And render it after the `<slot />` in the body:

```astro
  <body>
    <slot />
    <Hcard />
    <!-- anglesite:body-end -->
  </body>
```

- [ ] **Step 6: Run the render smoke test to verify it passes**

Run: `swift test --package-path . --filter "SiteIdentityRenderSmokeTests"`
Expected: PASS — unconfigured build has no `h-card`; business build has `p-tel` + `p-street-address`; personal build has `u-email` and no `p-street-address`.

- [ ] **Step 7: Confirm the template is still ship-empty**

Run: `git status --short Resources/Template/src/data`
Expected: no output (the test's `defer` removed `src/data`; nothing staged or untracked there).

- [ ] **Step 8: Commit**

```bash
git add Resources/Template/src/components/Hcard.astro Resources/Template/src/layouts/BaseLayout.astro Tests/AnglesiteCoreTests/SiteIdentityRenderSmokeTests.swift
git commit -m "feat(#388): site-wide footer h-card partial + render smoke"
```

---

### Task 5: Full-suite verification

**Files:** none (verification only).

- [ ] **Step 1: Run the whole AnglesiteCore suite**

Run: `swift test --package-path .`
Expected: PASS — all suites green, including `ContentConfigDriftTests` (unchanged — both singletons have `collection == nil` and are skipped), `BusinessTypeRenderSmokeTests`, and the new `SiteIdentityRenderSmokeTests`. No suite regressed.

- [ ] **Step 2: Confirm the working tree is clean and ship-empty**

Run: `git status --short`
Expected: clean (all task commits made; no stray `Resources/Template/src/data/profile.json`, no `dist/`).

---

## Self-Review

**Spec coverage:**
- Singleton storage kind + `personalProfile` + shared slot → Task 1. ✓
- `renderSingleton` (pure JSON) + path → Task 2. ✓
- `createTypedSingleton` with one-per-site gate + generalized `createTyped` → Task 3. ✓
- Footer `Hcard.astro` (optional import, mf2, hours unmapped) + `BaseLayout` wiring → Task 4. ✓
- All five test groups in the spec (registry, scaffold, operations, render smoke incl. empty state, drift untouched) → Tasks 1-5. ✓
- Decisions: one-per-site (Task 3 gate), footer-only data module (Task 4), ship-empty (Task 4 Steps 7 + test `defer`), no UI (no app-target files touched). ✓
- Coordination risk (no exhaustive `ContentStorage` switch) verified pre-plan; computed properties only. ✓

**Placeholder scan:** No TBD/TODO; every code step has complete code; every command has expected output. ✓

**Type consistency:** `singletonSlot` (Task 1) ← `createTypedSingleton`/tests (Task 3); `singletonRelativePath`/`renderSingleton` signatures (Task 2) ← consumed verbatim in Task 3; `.created(filePath:identifier:)` matches existing `ContentCreateResult`; fixture JSON shape matches `Hcard.astro` field reads (Task 4). ✓
