# Bot Preference Sync Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a site owner choose, per site, whether Anglesite's own named-bot blocklist or Cloudflare's Bot Preference Sync manages AI-bot blocking in `robots.txt`, behind a feature flag that's off by default.

**Architecture:** A new `botBlocklistManagedBy: "anglesite" | "cloudflare"` field on `AIUsage` (mirrored in TS and Swift) that `edge-artifacts.ts` reads defensively to suppress the existing 17-bot `Disallow` block when Cloudflare is in charge. On the app side, `PlistEditorModel` lazily resolves the site's Cloudflare zone (only when a new `AppSettings` flag is on) and `ContentLicensingTab` shows a "Bot blocklist managed by" control only once that zone resolves, swapping the existing blocklist toggle for a Cloudflare dashboard deep link in Cloudflare mode.

**Tech Stack:** Swift 6.4 / SwiftUI (`AnglesiteCore`, `AnglesiteApp`), TypeScript (`Resources/Template`, `npx tsx --test` / `node:test`), Swift Testing (`Tests/AnglesiteCoreTests`, `Tests/AnglesiteAppTests`).

**Spec:** [docs/superpowers/specs/2026-08-23-bot-preference-sync-design.md](../specs/2026-08-23-bot-preference-sync-design.md)

**Issue:** [#1628](https://github.com/Anglesite/Anglesite/issues/1628)

## Global Constraints

- Feature flag `AppSettings.Key.botPreferenceSyncUIEnabled` defaults to `false` — every task must leave default (flag-off) behavior byte-for-byte identical to today.
- `botBlocklistManagedBy` is the exact field name on both sides (TS `licensing.ts`, Swift `LicensingStore.swift`); `BotBlocklistManager` is the exact type/enum name on both sides; values are the lowercase strings `"anglesite"` / `"cloudflare"`.
- `Content-Signal` emission is never gated by `botBlocklistManagedBy` — only the 17-bot `Disallow` block is.
- No new dependencies. No changes to `NO_USAGE`'s meaning — only its literal shape (one new key).
- Every task ends with tests passing and a commit; see each task's exact commit message.
- Work happens in a git worktree per this repo's `CLAUDE.md` (`.claude/worktrees/<name>/`), with `xcodegen generate` run once before any Swift build/test in that worktree.

---

### Task 1: TS schema — `AIUsage.botBlocklistManagedBy`

**Files:**
- Modify: `Resources/Template/src/lib/licensing.ts:31-52` (the `AIUsage` interface, `NO_USAGE`, `normalizeUsage`)
- Test: `Resources/Template/src/lib/licensing.test.ts`

**Interfaces:**
- Produces: `BotBlocklistManager` (TS type alias, `"anglesite" | "cloudflare"`), `AIUsage.botBlocklistManagedBy?: BotBlocklistManager` (optional — existing object literals throughout the template that construct an `AIUsage` without this key must keep compiling unchanged), `normalizeUsage(raw: unknown): AIUsage` now always populates a concrete `botBlocklistManagedBy` value (`"anglesite"` unless the raw input says exactly `"cloudflare"`).

- [ ] **Step 1: Write the failing tests**

Add to `Resources/Template/src/lib/licensing.test.ts`, right after the existing `test("normalizeUsage: reads a well-formed block", ...)` block (around line 229):

```ts
test("normalizeUsage: botBlocklistManagedBy defaults to anglesite when absent", () => {
  assert.equal(normalizeUsage({ search: "yes" }).botBlocklistManagedBy, "anglesite");
});

test("normalizeUsage: botBlocklistManagedBy reads cloudflare when explicitly requested", () => {
  assert.equal(normalizeUsage({ botBlocklistManagedBy: "cloudflare" }).botBlocklistManagedBy, "cloudflare");
});

test("normalizeUsage: an unrecognized botBlocklistManagedBy value degrades to anglesite", () => {
  assert.equal(normalizeUsage({ botBlocklistManagedBy: "bogus" }).botBlocklistManagedBy, "anglesite");
});
```

Also update the existing `test("normalizeUsage: reads a well-formed block", ...)` expected object (lines 222-229) to include the new key, since `normalizeUsage`'s output will now always carry it:

```ts
test("normalizeUsage: reads a well-formed block", () => {
  assert.deepEqual(normalizeUsage({ search: "yes", aiInput: "no", aiTrain: "no", blockAICrawlers: true }), {
    search: "yes",
    aiInput: "no",
    aiTrain: "no",
    blockAICrawlers: true,
    botBlocklistManagedBy: "anglesite",
  });
});
```

- [ ] **Step 2: Run tests to verify the new ones fail**

Run: `npx tsx --test Resources/Template/src/lib/licensing.test.ts`
Expected: the 3 new tests FAIL with "botBlocklistManagedBy" being `undefined`, not `"anglesite"`/`"cloudflare"`; the updated "reads a well-formed block" test FAILS on the extra expected key.

- [ ] **Step 3: Implement the schema change**

In `Resources/Template/src/lib/licensing.ts`, add the type alias right before the `AIUsage` interface (before line 31):

```ts
/**
 * Who blocks named AI crawlers in `robots.txt`: Anglesite's own hardcoded list
 * (`blockAICrawlers`), or Cloudflare's Bot Preference Sync — a zone-level dashboard setting with
 * no public API (see docs/superpowers/specs/2026-08-23-bot-preference-sync-design.md). Mirrors
 * `BotBlocklistManager` in `LicensingStore.swift`.
 */
export type BotBlocklistManager = "anglesite" | "cloudflare";
```

Add the field to `AIUsage` (after the existing `blockAICrawlers: boolean;` line):

```ts
  blockAICrawlers: boolean;
  /**
   * Optional so every existing `AIUsage` object literal in this template keeps compiling
   * unchanged. Absent (`undefined`) means the same thing as an explicit `"anglesite"` everywhere
   * this field is read — see `edge-artifacts.ts`'s gate. `normalizeUsage` below always populates
   * a concrete value on its *output*, even though the type stays optional for callers.
   */
  botBlocklistManagedBy?: BotBlocklistManager;
```

Update `NO_USAGE` (the `emptyRobotsConfig`-style frozen constant) to include the new key explicitly:

```ts
const emptyUsage: AIUsage = {
  search: "unset",
  aiInput: "unset",
  aiTrain: "unset",
  blockAICrawlers: false,
  botBlocklistManagedBy: "anglesite",
};
```

(If `NO_USAGE` is declared inline rather than via an `emptyUsage` intermediate — check the actual current declaration at `licensing.ts:49` before editing; add the one new key to whatever form it takes, keeping everything else unchanged.)

Update `normalizeUsage` to destructure and set the new field:

```ts
export function normalizeUsage(raw: unknown): AIUsage {
  if (!raw || typeof raw !== "object") return { ...NO_USAGE };
  const { search, aiInput, aiTrain, blockAICrawlers, botBlocklistManagedBy } = raw as Record<string, unknown>;
  const usage: AIUsage = {
    search: toPermission(search),
    aiInput: toPermission(aiInput),
    aiTrain: toPermission(aiTrain),
    blockAICrawlers: false,
    botBlocklistManagedBy: botBlocklistManagedBy === "cloudflare" ? "cloudflare" : "anglesite",
  };
  usage.blockAICrawlers = blockAICrawlers === true && mayBlockAICrawlers(usage);
  return usage;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npx tsx --test Resources/Template/src/lib/licensing.test.ts`
Expected: PASS, including every pre-existing test in the file (the `NO_USAGE`-based `deepEqual` assertions in this file and in `edge-artifacts.test.ts` still match because `NO_USAGE` itself was updated).

- [ ] **Step 5: Run the full template test suite to confirm no other file broke**

Run: `cd Resources/Template && npx tsx --test src/lib/*.test.ts scripts/*.test.ts`
Expected: PASS. This is the check that the other 41 `blockAICrawlers`-touching object literals across `rsl.test.ts`, `feeds.test.ts`, `edge-artifacts.test.ts` still compile and pass unmodified (the field being optional means they never needed to change).

- [ ] **Step 6: Commit**

```bash
git add Resources/Template/src/lib/licensing.ts Resources/Template/src/lib/licensing.test.ts
git commit -m "feat(#1628): add AIUsage.botBlocklistManagedBy field"
```

---

### Task 2: TS build-time gating — `edge-artifacts.ts`

**Files:**
- Modify: `Resources/Template/scripts/edge-artifacts.ts` (inside `buildRobotsTxt`, the `if (usage.blockAICrawlers && mayBlockAICrawlers(usage))` block)
- Test: `Resources/Template/scripts/edge-artifacts.test.ts`

**Interfaces:**
- Consumes: `AIUsage.botBlocklistManagedBy` from Task 1.
- Produces: no new exports — `buildRobotsTxt`'s existing signature and behavior are unchanged except for the new suppression condition.

- [ ] **Step 1: Write the failing tests**

Add to `Resources/Template/scripts/edge-artifacts.test.ts`, right after the existing `test("buildRobotsTxt: gates the blocklist on mayBlockAICrawlers even given an unclamped usage directly", ...)` block (around line 108):

```ts
test("buildRobotsTxt: cloudflare-managed mode suppresses the blocklist even when requested", () => {
  const out = buildRobotsTxt({ ...BLOCKING, botBlocklistManagedBy: "cloudflare" });
  assert.doesNotMatch(out, /User-agent: GPTBot/);
});

test("buildRobotsTxt: cloudflare-managed mode still emits Content-Signal", () => {
  const out = buildRobotsTxt({ ...BLOCKING, botBlocklistManagedBy: "cloudflare" });
  assert.match(out, /Content-Signal: search=yes, ai-input=no, ai-train=no/);
});

test("buildRobotsTxt: an absent botBlocklistManagedBy behaves exactly like anglesite-managed", () => {
  const withField = buildRobotsTxt({ ...BLOCKING, botBlocklistManagedBy: "anglesite" });
  const withoutField = buildRobotsTxt(BLOCKING);
  assert.equal(withField, withoutField);
  assert.match(withoutField, /User-agent: GPTBot/);
});
```

- [ ] **Step 2: Run tests to verify the new ones fail**

Run: `npx tsx --test Resources/Template/scripts/edge-artifacts.test.ts`
Expected: the first two new tests FAIL (the blocklist still appears / nothing suppresses it yet); the third PASSES already (it's a regression guard for behavior that doesn't change).

- [ ] **Step 3: Implement the gate**

In `Resources/Template/scripts/edge-artifacts.ts`, find the block (originally around line 169-171):

```ts
  if (usage.blockAICrawlers && mayBlockAICrawlers(usage)) {
    body += `\n# AI crawler / training bot directives (usage.blockAICrawlers in src/data/licensing.json)\n`;
    for (const bot of aiCrawlers) {
```

Change the condition to:

```ts
  if (usage.blockAICrawlers && mayBlockAICrawlers(usage) && usage.botBlocklistManagedBy !== "cloudflare") {
    body += `\n# AI crawler / training bot directives (usage.blockAICrawlers in src/data/licensing.json)\n`;
    for (const bot of aiCrawlers) {
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npx tsx --test Resources/Template/scripts/edge-artifacts.test.ts`
Expected: PASS, including every pre-existing test in the file.

- [ ] **Step 5: Commit**

```bash
git add Resources/Template/scripts/edge-artifacts.ts Resources/Template/scripts/edge-artifacts.test.ts
git commit -m "feat(#1628): suppress the named-bot blocklist when Cloudflare manages it"
```

---

### Task 3: Swift schema — `LicensingStore.swift`

**Files:**
- Modify: `Sources/AnglesiteCore/LicensingStore.swift:118-195` (`AIUsage`, its `Codable` extension)
- Test: `Tests/AnglesiteCoreTests/LicensingStoreTests.swift`

**Interfaces:**
- Produces: `public enum BotBlocklistManager: String, Sendable, Equatable, CaseIterable, Identifiable { case anglesite, cloudflare }`; `AIUsage.botBlocklistManagedBy: BotBlocklistManager` (non-optional in Swift — every existing `AIUsage(...)` call site keeps compiling because the new initializer parameter is trailing with a default of `.anglesite`).

- [ ] **Step 1: Write the failing tests**

Add to `Tests/AnglesiteCoreTests/LicensingStoreTests.swift`, right after the existing `@Test("save() then load() round-trips every rule kind and the usage block")` test (around line 49):

```swift
@Test("botBlocklistManagedBy defaults to .anglesite when absent from the document")
func botBlocklistManagedByDefaultsWhenAbsent() throws {
    let dir = try makeTempDir()
    try write(#"{"usage":{"blockAICrawlers":false}}"#, to: dir)
    #expect(try LicensingStore(sourceDirectory: dir).load().usage.botBlocklistManagedBy == .anglesite)
}

@Test("botBlocklistManagedBy round-trips through save() and load()")
func botBlocklistManagedByRoundTrips() throws {
    let dir = try makeTempDir()
    var policy = LicensingPolicy()
    policy.usage = AIUsage(botBlocklistManagedBy: .cloudflare)
    try LicensingStore(sourceDirectory: dir).save(policy)
    #expect(try LicensingStore(sourceDirectory: dir).load().usage.botBlocklistManagedBy == .cloudflare)
}

@Test("an unrecognized botBlocklistManagedBy value degrades to .anglesite")
func botBlocklistManagedByUnrecognizedDegrades() throws {
    let dir = try makeTempDir()
    try write(#"{"usage":{"botBlocklistManagedBy":"bogus"}}"#, to: dir)
    #expect(try LicensingStore(sourceDirectory: dir).load().usage.botBlocklistManagedBy == .anglesite)
}
```

Check the existing file for its exact `makeTempDir()`/`write(_:to:)` helper names before pasting — mirror whatever the file already calls its own directory/write helpers (the existing tests at lines 22-90 already exercise this exact pattern; match their names verbatim rather than inventing new ones).

- [ ] **Step 2: Run tests to verify the new ones fail**

Run: `swift test --package-path . --filter LicensingStoreTests`
Expected: FAIL to compile — `AIUsage` has no member `botBlocklistManagedBy` yet, and no `BotBlocklistManager` type exists.

- [ ] **Step 3: Implement the schema change**

In `Sources/AnglesiteCore/LicensingStore.swift`, add the enum right before `public struct AIUsage` (before line 121):

```swift
/// Who blocks named AI crawlers in `robots.txt`: Anglesite's own hardcoded list
/// (`blockAICrawlers`), or Cloudflare's Bot Preference Sync — a zone-level dashboard setting with
/// no public API (see docs/superpowers/specs/2026-08-23-bot-preference-sync-design.md). Mirrors
/// `BotBlocklistManager` in `licensing.ts`.
public enum BotBlocklistManager: String, Sendable, Equatable, CaseIterable, Identifiable {
    case anglesite
    case cloudflare
    public var id: Self { self }
}
```

Add the stored property and initializer parameter to `AIUsage` (after the existing `blockAICrawlers` property/parameter):

```swift
    /// Whether the named-agent blocklist is emitted into `robots.txt`. Only honored when
    /// ``mayBlockAICrawlers`` allows it — ``clamped`` enforces that on every load and save.
    public var blockAICrawlers: Bool
    /// Who acts on ``blockAICrawlers``. `.cloudflare` suppresses Anglesite's own blocklist at
    /// build time regardless of ``blockAICrawlers``'s value, deferring to Cloudflare's own
    /// dashboard-managed Bot Preference Sync instead. Defaults to `.anglesite`, matching an
    /// absent key in `licensing.json` — every site created before this field existed behaves
    /// identically to before.
    public var botBlocklistManagedBy: BotBlocklistManager

    /// All parameters default to the most conservative state — no preference stated, no
    /// blocklist — so a zero-argument `AIUsage()` equals a document with no `usage` key at all.
    public init(
        search: UsagePermission = .unset,
        aiInput: UsagePermission = .unset,
        aiTrain: UsagePermission = .unset,
        blockAICrawlers: Bool = false,
        botBlocklistManagedBy: BotBlocklistManager = .anglesite
    ) {
        self.search = search
        self.aiInput = aiInput
        self.aiTrain = aiTrain
        self.blockAICrawlers = blockAICrawlers
        self.botBlocklistManagedBy = botBlocklistManagedBy
    }
```

Update the `Codable` extension:

```swift
extension AIUsage: Codable {
    private enum CodingKeys: String, CodingKey {
        case search, aiInput, aiTrain, blockAICrawlers, botBlocklistManagedBy
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func permission(_ key: CodingKeys) -> UsagePermission {
            let raw = (try? container.decodeIfPresent(String.self, forKey: key)) ?? nil
            return UsagePermission(rawValue: raw ?? "") ?? .unset
        }
        let rawManager = (try? container.decodeIfPresent(String.self, forKey: .botBlocklistManagedBy)) ?? nil
        self.init(
            search: permission(.search),
            aiInput: permission(.aiInput),
            aiTrain: permission(.aiTrain),
            blockAICrawlers: ((try? container.decodeIfPresent(Bool.self, forKey: .blockAICrawlers)) ?? nil) ?? false,
            botBlocklistManagedBy: BotBlocklistManager(rawValue: rawManager ?? "") ?? .anglesite
        )
        self = clamped
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let usage = clamped
        if usage.search != .unset { try container.encode(usage.search.rawValue, forKey: .search) }
        if usage.aiInput != .unset { try container.encode(usage.aiInput.rawValue, forKey: .aiInput) }
        if usage.aiTrain != .unset { try container.encode(usage.aiTrain.rawValue, forKey: .aiTrain) }
        try container.encode(usage.blockAICrawlers, forKey: .blockAICrawlers)
        try container.encode(usage.botBlocklistManagedBy.rawValue, forKey: .botBlocklistManagedBy)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter LicensingStoreTests`
Expected: PASS, including every pre-existing test in the suite (all existing `AIUsage(search:aiInput:aiTrain:blockAICrawlers:)` call sites keep compiling since the new parameter is trailing with a default).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/LicensingStore.swift Tests/AnglesiteCoreTests/LicensingStoreTests.swift
git commit -m "feat(#1628): add AIUsage.botBlocklistManagedBy to the Swift mirror"
```

---

### Task 4: Feature flag — `AppSettings` + Advanced settings toggle

**Files:**
- Modify: `Sources/AnglesiteCore/AppSettings.swift` (add `Key.botPreferenceSyncUIEnabled` and the `botPreferenceSyncUIEnabled` computed property, following `debugPaneEnabled`'s exact shape at lines 226-229)
- Modify: `Sources/AnglesiteApp/SettingsView.swift` (`AdvancedSettingsView`, `Section("Diagnostics")` at lines 395-396 and 495-496)
- Test: `Tests/AnglesiteCoreTests/AppSettingsTests.swift`

**Interfaces:**
- Produces: `AppSettings.Key.botPreferenceSyncUIEnabled: String`, `AppSettings.botPreferenceSyncUIEnabled: Bool` (default `false`) — this is what Task 6 reads to gate zone resolution.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/AnglesiteCoreTests/AppSettingsTests.swift`, right after the existing `debugPaneEnabledRoundTrip` test (around line 189):

```swift
@Test("Bot Preference Sync UI defaults to false") func botPreferenceSyncUIEnabledDefaultsToFalse() {
    let settings = AppSettings(defaults: defaults)
    #expect(!settings.botPreferenceSyncUIEnabled)
}

@Test("Bot Preference Sync UI round trip") func botPreferenceSyncUIEnabledRoundTrip() {
    let settings = AppSettings(defaults: defaults)
    settings.botPreferenceSyncUIEnabled = true
    #expect(settings.botPreferenceSyncUIEnabled)
    settings.botPreferenceSyncUIEnabled = false
    #expect(!settings.botPreferenceSyncUIEnabled)
}
```

(Match whichever exact local-variable name the surrounding `debugPaneEnabled` tests use for the `AppSettings` instance — the file's own convention at line 179-189 is the source of truth; copy it verbatim rather than guessing.)

- [ ] **Step 2: Run tests to verify the new ones fail**

Run: `swift test --package-path . --filter AppSettingsTests`
Expected: FAIL to compile — `AppSettings` has no member `botPreferenceSyncUIEnabled` yet.

- [ ] **Step 3: Implement the flag**

In `Sources/AnglesiteCore/AppSettings.swift`, add the key inside `enum Key` (after the existing `debugPaneEnabled` key, around line 30):

```swift
        /// Backs ``AppSettings/botPreferenceSyncUIEnabled``.
        public static let botPreferenceSyncUIEnabled = "anglesite.botPreferenceSyncUIEnabled"
```

Add the computed property (after the existing `debugPaneEnabled` property, around line 229):

```swift
    /// Opt-in toggle (Settings → Advanced) that reveals the "Bot blocklist managed by" control in
    /// Content Licensing. Off by default: Cloudflare's Bot Preference Sync isn't GA yet and its
    /// dashboard settings path isn't documented (docs/superpowers/specs/2026-08-23-bot-preference-sync-design.md).
    /// See #1627 for flipping this default once Cloudflare ships.
    public var botPreferenceSyncUIEnabled: Bool {
        get { defaults.bool(forKey: Key.botPreferenceSyncUIEnabled) }
        set { defaults.set(newValue, forKey: Key.botPreferenceSyncUIEnabled) }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter AppSettingsTests`
Expected: PASS.

- [ ] **Step 5: Add the Advanced settings toggle**

In `Sources/AnglesiteApp/SettingsView.swift`, add the `@AppStorage` declaration to `AdvancedSettingsView` (after the existing `debugPaneEnabled` one at line 396):

```swift
    @AppStorage(AppSettings.Key.botPreferenceSyncUIEnabled) private var botPreferenceSyncUIEnabled: Bool = false
```

Add a toggle to the existing `Section("Diagnostics")` (after the `debugPaneEnabled` `Toggle`/`Text` pair, i.e. after line ~504's closing of that conditional):

```swift
                Toggle("Show Cloudflare bot management option in Content Licensing", isOn: $botPreferenceSyncUIEnabled)
                Text("Lets you choose, per site, whether Anglesite's own AI-bot blocklist or Cloudflare's Bot Preference Sync (a Cloudflare dashboard setting) manages named-bot blocking in robots.txt. Off by default — Cloudflare's feature isn't generally available yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
```

- [ ] **Step 6: Build the app target to confirm the SwiftUI changes compile**

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: BUILD SUCCEEDED. (`AdvancedSettingsView`/`SettingsView` have no dedicated unit tests in this codebase — a SwiftUI `View`'s correctness here is verified by compiling and, later, in Task 8's manual pass.)

- [ ] **Step 7: Commit**

```bash
git add Sources/AnglesiteCore/AppSettings.swift Sources/AnglesiteApp/SettingsView.swift Tests/AnglesiteCoreTests/AppSettingsTests.swift
git commit -m "feat(#1628): add botPreferenceSyncUIEnabled feature flag"
```

---

### Task 5: Cloudflare dashboard deep link — `BotPreferenceSyncDashboardLinks`

**Files:**
- Create: `Sources/AnglesiteCore/BotPreferenceSyncDashboardLinks.swift`
- Test: `Tests/AnglesiteCoreTests/BotPreferenceSyncDashboardLinksTests.swift`

**Interfaces:**
- Produces: `public enum BotPreferenceSyncDashboardLinks { public static func settingsURL(zoneID: String) -> URL }` — consumed by Task 7's `ContentLicensingTab`.

- [ ] **Step 1: Write the failing test**

Create `Tests/AnglesiteCoreTests/BotPreferenceSyncDashboardLinksTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite("BotPreferenceSyncDashboardLinks (#1628)")
struct BotPreferenceSyncDashboardLinksTests {
    @Test("settings deep link targets the zone's security settings, keyed by zoneID")
    func settingsURL() {
        #expect(
            BotPreferenceSyncDashboardLinks.settingsURL(zoneID: "z1").absoluteString
                == "https://dash.cloudflare.com/?to=/:account/:zone/security/settings")
    }
}
```

(The URL is a fixed template string — `zoneID` isn't interpolated into the path today because Cloudflare's own `?to=` resolver fills in `:zone` from dashboard context, the same way `:account` already works for every other link in `WorkerDashboardLinks`. The parameter exists so a future, more specific path — once Cloudflare documents one — can use it without changing this function's signature or every call site.)

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter BotPreferenceSyncDashboardLinksTests`
Expected: FAIL to compile — `BotPreferenceSyncDashboardLinks` doesn't exist yet.

- [ ] **Step 3: Implement the helper**

Create `Sources/AnglesiteCore/BotPreferenceSyncDashboardLinks.swift`:

```swift
import Foundation

/// Cloudflare-dashboard deep link for a zone's Bot Preference Sync settings (#1628, design doc
/// `docs/superpowers/specs/2026-08-23-bot-preference-sync-design.md`). Uses the dashboard's `?to=`
/// deep-link resolver with its `:account`/`:zone` placeholders — the same mechanism as
/// `WorkerDashboardLinks` — so the app never needs to know the account or zone name, only that a
/// zone exists.
///
/// **Provisional path.** Cloudflare's Bot Preference Sync blog post doesn't name the exact
/// dashboard settings location — the feature isn't GA yet ("keep an eye on our changelog for
/// availability"). `security/settings` is a best guess. A wrong path degrades to the zone
/// overview (one more click), never a dead end — same resilience `WorkerDashboardLinks` documents
/// for its own paths. Fix here, in one place, once Cloudflare documents the real path — tracked
/// in #1627.
public enum BotPreferenceSyncDashboardLinks {
    /// `zoneID` isn't interpolated today (the `:zone` placeholder is filled in by the dashboard
    /// itself from account context), but is part of the signature so a future path that does need
    /// it — a per-zone deep link Cloudflare hasn't documented yet — doesn't require a call-site
    /// change.
    public static func settingsURL(zoneID: String) -> URL {
        URL(string: "https://dash.cloudflare.com/?to=/:account/:zone/security/settings")!
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --filter BotPreferenceSyncDashboardLinksTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/BotPreferenceSyncDashboardLinks.swift Tests/AnglesiteCoreTests/BotPreferenceSyncDashboardLinksTests.swift
git commit -m "feat(#1628): add BotPreferenceSyncDashboardLinks"
```

---

### Task 6: Zone resolution + default-selection algorithm — `PlistEditorModel`

**Files:**
- Modify: `Sources/AnglesiteApp/PlistEditorModel.swift` (init at lines 246-299, new stored properties near line 75-78, `load()`'s licensing block at lines 347-358, new private helpers near line 1033-1039)
- Test: Create `Tests/AnglesiteAppTests/PlistEditorModelBotPreferenceSyncTests.swift`

**Interfaces:**
- Consumes: `CloudflareReading.resolveZoneID(domain:apiToken:) async throws -> String?` (existing protocol, `Sources/AnglesiteCore/CloudflareReading.swift:69`), `CloudflareAPICredentials.resolve(secretStore:diagnosticSource:)` (existing), `DeployCoordinator.resolveSiteURL(siteDirectory:) -> String?` (existing), `AppSettings.botPreferenceSyncUIEnabled` (Task 4), `AIUsage.botBlocklistManagedBy`/`BotBlocklistManager` (Task 3).
- Produces: `PlistEditorModel.botPreferenceSyncZoneID: String?` (read-only, `nil` until/unless resolved) — consumed by Task 7's `ContentLicensingTab` both to gate visibility and to build the dashboard link.

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteAppTests/PlistEditorModelBotPreferenceSyncTests.swift`, following the exact `Fixture`/`makeFixture` shape already established in `Tests/AnglesiteAppTests/PlistEditorModelInboxCaptureTests.swift` (temp `Source`/`Config` dirs, an isolated `KeychainStore(service:)`, a `.site-config` with `DOMAIN=` for `DeployCoordinator.resolveSiteURL` to read):

```swift
import Testing
import Foundation
@testable import AnglesiteAppCore
@testable import AnglesiteCore

private final class StubReader: CloudflareReading, @unchecked Sendable {
    private let zoneID: String?
    init(zoneID: String?) { self.zoneID = zoneID }
    func resolveZoneID(domain: String, apiToken: String) async throws -> String? { zoneID }
    func zoneState(zoneID: String, domain: String, apiToken: String) async throws -> CloudflareZoneState {
        CloudflareZoneState(
            dnssecActive: false, sslMode: "strict", alwaysUseHTTPS: false,
            hsts: nil, caaRecords: [], mxRecords: [], spfRecords: [], dmarcRecords: [])
    }
    func listDNSRecords(zoneID: String, apiToken: String) async throws -> [DNSRecord] { [] }
    func workerScriptNames(apiToken: String) async throws -> [String] { [] }
}

@Suite("PlistEditorModel Bot Preference Sync zone gating (#1628)")
@MainActor
struct PlistEditorModelBotPreferenceSyncTests {
    private static let emptyPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict/></plist>
        """

    private func makeModel(
        licensingJSON: String? = nil,
        domain: String? = "example.com",
        token: String? = "test-token",
        zoneID: String? = "z1",
        flagEnabled: Bool = true
    ) throws -> PlistEditorModel {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlistEditorModelBotPreferenceSyncTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let plistURL = dir.appendingPathComponent("Info.plist")
        try Self.emptyPlist.write(to: plistURL, atomically: true, encoding: .utf8)
        if let domain {
            try "DOMAIN=\(domain)\n".write(
                to: dir.appendingPathComponent(".site-config"), atomically: true, encoding: .utf8)
        }
        if let licensingJSON {
            let dataDir = dir.appendingPathComponent("src/data", isDirectory: true)
            try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
            try licensingJSON.write(
                to: dataDir.appendingPathComponent("licensing.json"), atomically: true, encoding: .utf8)
        }
        let keychain = KeychainStore(service: "io.dwk.anglesite.test-\(UUID().uuidString)")
        if let token { try keychain.writeCloudflareToken(token) }
        let suiteName = "test-anglesite-\(UUID().uuidString)"
        let appSettings = AppSettings(defaults: UserDefaults(suiteName: suiteName)!)
        appSettings.botPreferenceSyncUIEnabled = flagEnabled
        let file = FileRef(url: plistURL, group: .metadata, name: "Info.plist")
        return PlistEditorModel(
            file: file, websiteTitle: "Test Site", sourceDirectory: dir,
            keychain: keychain,
            reader: StubReader(zoneID: zoneID),
            appSettings: appSettings)
    }

    @Test("flag off: never resolves a zone, even with a domain and token")
    func flagOffNeverResolves() async throws {
        let model = try makeModel(flagEnabled: false)
        await model.load()
        #expect(model.botPreferenceSyncZoneID == nil)
    }

    @Test("flag on, zone resolves, pristine usage: preselects cloudflare without marking the tab dirty")
    func pristineUsagePreselectsCloudflare() async throws {
        let model = try makeModel()
        await model.load()
        #expect(model.botPreferenceSyncZoneID == "z1")
        #expect(model.licensingPolicy.usage.botBlocklistManagedBy == .cloudflare)
        #expect(model.isLicensingDirty == false)
    }

    @Test("flag on, zone resolves, an expressed preference: never overridden")
    func expressedPreferenceIsUnchanged() async throws {
        let model = try makeModel(licensingJSON: #"{"usage":{"blockAICrawlers":false,"aiTrain":"no"}}"#)
        await model.load()
        #expect(model.botPreferenceSyncZoneID == "z1")
        #expect(model.licensingPolicy.usage.botBlocklistManagedBy == .anglesite)
    }

    @Test("flag on, no zone resolves: stays anglesite-managed and hides the option")
    func noZoneResolved() async throws {
        let model = try makeModel(zoneID: nil)
        await model.load()
        #expect(model.botPreferenceSyncZoneID == nil)
        #expect(model.licensingPolicy.usage.botBlocklistManagedBy == .anglesite)
    }

    @Test("flag on, no domain configured: never attempts resolution")
    func noDomainConfigured() async throws {
        let model = try makeModel(domain: nil)
        await model.load()
        #expect(model.botPreferenceSyncZoneID == nil)
    }

    @Test("flag on, no Cloudflare token: never attempts resolution")
    func noToken() async throws {
        let model = try makeModel(token: nil)
        await model.load()
        #expect(model.botPreferenceSyncZoneID == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter PlistEditorModelBotPreferenceSyncTests`
Expected: FAIL to compile — `PlistEditorModel` has no `reader`/`appSettings` init parameters or `botPreferenceSyncZoneID` property yet.

- [ ] **Step 3: Implement the model changes**

In `Sources/AnglesiteApp/PlistEditorModel.swift`, add two stored properties near the other private dependencies (after `private let capabilityProber: CloudflareCapabilityProber` at line 20):

```swift
    private let reader: any CloudflareReading
    private let appSettings: AppSettings
```

Add the exposed read-only property near `savedLicensingPolicy`/`licensingError` (after line 78):

```swift
    /// The site's Cloudflare zone ID, resolved lazily in `load()` only when
    /// `AppSettings.botPreferenceSyncUIEnabled` is on — `nil` until resolved, and permanently
    /// `nil` when the flag is off, no domain is configured, no Cloudflare token is available, or
    /// the domain doesn't resolve to a zone. `ContentLicensingTab` uses this both to decide
    /// whether to show the "Bot blocklist managed by" control at all, and to build the dashboard
    /// deep link once it does.
    private(set) var botPreferenceSyncZoneID: String?
```

Add two new init parameters (after `capabilityProber: CloudflareCapabilityProber = CloudflareCapabilityProber(),` at line 257):

```swift
         capabilityProber: CloudflareCapabilityProber = CloudflareCapabilityProber(),
         reader: any CloudflareReading = HTTPCloudflareClient(),
         appSettings: AppSettings = .shared,
```

Set them in the initializer body (after `self.capabilityProber = capabilityProber` at line 287):

```swift
        self.capabilityProber = capabilityProber
        self.reader = reader
        self.appSettings = appSettings
```

In `load()`, inside the existing licensing `do` block (after `licensingLoadFailed = false` at line 352, still inside the `do`), add:

```swift
                licensingLoadFailed = false
                if appSettings.botPreferenceSyncUIEnabled {
                    let zoneID = await resolvedBotPreferenceSyncZoneID()
                    botPreferenceSyncZoneID = zoneID
                    if zoneID != nil, policy.usage == AIUsage() {
                        licensingPolicy.usage.botBlocklistManagedBy = .cloudflare
                        savedLicensingPolicy.usage.botBlocklistManagedBy = .cloudflare
                    }
                } else {
                    botPreferenceSyncZoneID = nil
                }
```

Add the two new private helpers near the existing `cloudflareToken()` (after line 1039):

```swift
    /// Same resolution order as `cloudflareToken()` (env → OAuth → legacy token) but with its own
    /// `diagnosticSource` breadcrumb, since this call site is unrelated to Analytics.
    private func cloudflareTokenForBotPreferenceSync() async throws -> String? {
        try await CloudflareAPICredentials.resolve(secretStore: keychain, diagnosticSource: "botPreferenceSync")
    }

    /// Resolves the site's Cloudflare zone for the Bot Preference Sync gate — `nil` for any
    /// reason (no configured domain, no token, a thrown error, or a domain that isn't a Cloudflare
    /// zone at all) rather than surfacing an error, since an unresolved zone just means "don't
    /// show the Cloudflare-managed option," never a failure state worth reporting in this tab.
    private func resolvedBotPreferenceSyncZoneID() async -> String? {
        guard let siteURLString = DeployCoordinator.resolveSiteURL(siteDirectory: sourceDirectory),
              let domain = URL(string: siteURLString)?.host else { return nil }
        guard let tokenResult = try? await cloudflareTokenForBotPreferenceSync(),
              let token = tokenResult, !token.isEmpty else { return nil }
        return try? await reader.resolveZoneID(domain: domain, apiToken: token)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter PlistEditorModelBotPreferenceSyncTests`
Expected: PASS.

- [ ] **Step 5: Run the full PlistEditorModel + LicensingStore test suites to confirm nothing else broke**

Run: `swift test --package-path . --filter PlistEditorModel`
Expected: PASS — every pre-existing `PlistEditorModel*Tests` suite (Licensing, InboxCapture, and others) still passes with the two new init parameters defaulted.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteApp/PlistEditorModel.swift Tests/AnglesiteAppTests/PlistEditorModelBotPreferenceSyncTests.swift
git commit -m "feat(#1628): resolve the Cloudflare zone for Bot Preference Sync gating"
```

---

### Task 7: UI — `ContentLicensingTab`

**Files:**
- Modify: `Sources/AnglesiteApp/ContentLicensingTab.swift:284-349` (the `aiUsageSection` computed view)

**Interfaces:**
- Consumes: `model.botPreferenceSyncZoneID: String?` (Task 6), `model.licensingPolicy.usage.botBlocklistManagedBy: BotBlocklistManager` (Task 3), `BotPreferenceSyncDashboardLinks.settingsURL(zoneID:)` (Task 5).

- [ ] **Step 1: Implement the UI change**

In `Sources/AnglesiteApp/ContentLicensingTab.swift`, insert a new control at the top of `aiUsageSection` (right after the opening `VStack(alignment: .leading, spacing: 10) {` and its existing intro `Text(...)`, i.e. after line 290, before the `Grid` at line 292):

```swift
            if model.botPreferenceSyncZoneID != nil {
                Picker("Bot blocklist managed by", selection: $model.licensingPolicy.usage.botBlocklistManagedBy) {
                    Text("Anglesite").tag(BotBlocklistManager.anglesite)
                    Text("Cloudflare").tag(BotBlocklistManager.cloudflare)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)
                Text(model.licensingPolicy.usage.botBlocklistManagedBy == .cloudflare
                     ? "Cloudflare's Bot Preference Sync manages named-bot blocking for this site. Turn it on for this zone in the Cloudflare dashboard — Anglesite can confirm the zone exists but can't confirm the sync itself is enabled there, since Cloudflare doesn't expose that setting through an API yet."
                     : "Anglesite manages named-bot blocking below. This site is also on Cloudflare — switch to Cloudflare if you'd rather its dashboard-managed Bot Preference Sync keep the blocklist current for you.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
```

Replace the existing `blockAICrawlers` toggle block (lines 317-328) with a mode switch — Anglesite mode keeps today's toggle, Cloudflare mode shows the dashboard link instead:

```swift
            if model.licensingPolicy.usage.botBlocklistManagedBy == .cloudflare, let zoneID = model.botPreferenceSyncZoneID {
                VStack(alignment: .leading, spacing: 6) {
                    Link("Manage in Cloudflare Dashboard →", destination: BotPreferenceSyncDashboardLinks.settingsURL(zoneID: zoneID))
                    Text("Cloudflare periodically updates this zone's robots.txt with named-bot rules for the categories you choose there (Search, Agent, Training). Anglesite's own \"AI Answers\"/\"AI Training\" signals above still apply either way.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(
                        "Refuse AI crawlers in robots.txt",
                        isOn: $model.licensingPolicy.usage.blockAICrawlers)
                        .toggleStyle(.switch)
                        .disabled(!model.licensingPolicy.usage.mayBlockAICrawlers)
                    Text(model.licensingPolicy.usage.mayBlockAICrawlers
                         ? "Adds robots.txt rules refusing 17 known AI crawlers (GPTBot, ClaudeBot, and others). This reduces your site's visibility to AI assistants and AI-generated search summaries — it does not affect traditional search engines."
                         : "Available once both AI Answers and AI Training are set to Disallow. Refusing a crawler while still permitting what it does would contradict itself.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
```

Note the top-of-section control checks `model.botPreferenceSyncZoneID != nil` (it never needs the unwrapped value), while the toggle/link swap re-unwraps it with its own `if let zoneID` since `BotPreferenceSyncDashboardLinks.settingsURL(zoneID:)` needs the actual ID — two independent `if` statements over the same optional, not a shared binding.

- [ ] **Step 2: Build the app target**

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Run the full model test suite once more end-to-end**

Run: `swift test --package-path .`
Expected: PASS across every target (`AnglesiteSiteModelTests`, `AnglesiteCoreTests`, `AnglesiteBridgeTests`, `AnglesiteIntentsTests` if available) — confirms the `ContentLicensingTab` edit didn't break compilation of `AnglesiteApp`-dependent test targets.

- [ ] **Step 4: Commit**

```bash
git add Sources/AnglesiteApp/ContentLicensingTab.swift
git commit -m "feat(#1628): show the Cloudflare-managed bot blocklist option in Content Licensing"
```

---

### Task 8: Manual verification

**Files:** none (verification only)

- [ ] **Step 1: Build and launch the app**

Follow `docs/testing-macos-app.md` to build and launch a Debug build of `Anglesite`.

- [ ] **Step 2: Confirm flag-off is pixel-identical to today**

Open any site's Website Settings ▸ Licensing tab with the flag off (default). Confirm no "Bot blocklist managed by" control appears and the existing "Refuse AI crawlers in robots.txt" toggle behaves exactly as before.

- [ ] **Step 3: Enable the flag and exercise both modes on a site with a resolvable zone**

In Settings ▸ Advanced ▸ Diagnostics, enable "Show Cloudflare bot management option in Content Licensing." Open a site whose domain resolves to a Cloudflare zone (with a Cloudflare API token configured in Settings ▸ Advanced ▸ Credentials). Confirm:
- The "Bot blocklist managed by" segmented control appears.
- Anglesite mode shows the existing toggle/copy unchanged.
- Cloudflare mode replaces the toggle with the dashboard link and explanatory copy; clicking the link opens `dash.cloudflare.com`.
- Switching modes and saving persists correctly — reload the tab (close and reopen Website Settings) and confirm the choice survived.

- [ ] **Step 4: Confirm the option stays hidden on a site with no resolvable zone**

Open a site with no configured domain (or one not on Cloudflare). Confirm the "Bot blocklist managed by" control does not appear, even with the flag on.

- [ ] **Step 5: Report results**

No commit for this task — report the manual verification results (pass/fail per step above) back in the PR description per `CONTRIBUTING.md`.
